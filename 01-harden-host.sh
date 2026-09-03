#!/usr/bin/env bash
# 01-harden-host.sh — first-boot hardening for the n8n VPS
# Target: Contabo Cloud VPS, Ubuntu 24.04 LTS, run ONCE as root over SSH.
#
# SAFETY: open a SECOND SSH session as root before running this and keep it
# open until you have confirmed you can log in as the new user with your key.
# This script never restarts sshd blindly — it validates config first.
#
# Usage:  bash 01-harden-host.sh <opsuser> "<ssh-public-key>"
# e.g.    bash 01-harden-host.sh n8nops "ssh-ed25519 AAAA... mike@mac"

set -euo pipefail

OPS_USER="${1:-}"
SSH_PUBKEY="${2:-}"
TIMEZONE="Europe/London"
SWAP_GB=2

if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi
if [[ -z "$OPS_USER" || -z "$SSH_PUBKEY" ]]; then
  echo "Usage: $0 <opsuser> \"<ssh-public-key>\""; exit 1
fi
if ! grep -q 'VERSION_ID="24.04"' /etc/os-release; then
  echo "WARNING: this script was written for Ubuntu 24.04 — continuing in 10s (Ctrl-C to abort)"; sleep 10
fi

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. base
log "Timezone, hostname sanity, apt update"
timedatectl set-timezone "$TIMEZONE"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg ufw fail2ban unattended-upgrades \
  apt-listchanges jq htop ncdu git rclone

# ---------------------------------------------------------------- 2. ops user
log "Creating ops user '$OPS_USER' with sudo + your SSH key"
if ! id "$OPS_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$OPS_USER"
fi
usermod -aG sudo "$OPS_USER"
install -d -m 700 -o "$OPS_USER" -g "$OPS_USER" "/home/$OPS_USER/.ssh"
echo "$SSH_PUBKEY" > "/home/$OPS_USER/.ssh/authorized_keys"
chmod 600 "/home/$OPS_USER/.ssh/authorized_keys"
chown -R "$OPS_USER:$OPS_USER" "/home/$OPS_USER/.ssh"
# passwordless sudo for the ops user (single-operator box; revisit if shared)
echo "$OPS_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$OPS_USER"
chmod 440 "/etc/sudoers.d/90-$OPS_USER"

# ---------------------------------------------------------------- 3. sshd
log "Hardening sshd (key-only, no root) — validated before reload"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
AllowUsers $OPS_USER
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
# Contabo images sometimes ship a cloud-init drop-in that re-enables passwords
if [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]]; then
  sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf
fi
sshd -t   # abort here if config invalid — nothing has been reloaded yet
systemctl reload ssh || systemctl reload sshd

# ---------------------------------------------------------------- 4. firewall
log "ufw: deny all inbound except SSH (n8n is reached only via Cloudflare Tunnel)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH rate-limited'
ufw --force enable
ufw status verbose

# ---------------------------------------------------------------- 5. fail2ban
log "fail2ban for sshd"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 4
backend  = systemd

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban

# ---------------------------------------------------------------- 6. auto security updates
log "unattended-upgrades (security only, reboot 04:30 if required)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades

# ---------------------------------------------------------------- 7. swap
log "Swap ${SWAP_GB}G (n8n + Postgres on a small VPS; avoids OOM kills)"
if ! swapon --show | grep -q swapfile; then
  fallocate -l "${SWAP_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -w vm.swappiness=10
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf

# ---------------------------------------------------------------- 8. docker
log "Docker Engine + Compose plugin (official repo)"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$OPS_USER"
# log rotation so container logs can't fill the disk
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }
EOF
systemctl enable --now docker
systemctl restart docker

# ---------------------------------------------------------------- 9. layout
log "Creating /opt/n8n owned by $OPS_USER"
install -d -o "$OPS_USER" -g "$OPS_USER" -m 750 /opt/n8n /opt/n8n/backups

# ---------------------------------------------------------------- done
log "DONE. Now, in your SECOND terminal, test:  ssh $OPS_USER@<vps-ip>"
echo "Only when that works: close the root session. Root SSH is now disabled."
echo "Next: copy docker-compose.yml, .env, backup.sh into /opt/n8n and follow BUILD-ORDER.md stage 3."
