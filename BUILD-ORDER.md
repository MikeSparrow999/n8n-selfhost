# n8n Self-Host — Build Order

Regenerated 3 Sep 2026 (the 1 Sep originals were lost). Hostname decided: **n8n.thinkrep.com** (thinkrep.com is on Cloudflare; funnelsix.com is not).
Versions pinned against live registries on 3 Sep: n8n **2.37.9** · cloudflared **2026.8.3** · Postgres **16-alpine**.
Cloud instance being replaced runs n8n 2.37.7 — same minor, so workflow JSON imports cleanly.

Each stage ends with a **gate**. Do not start the next stage until the gate passes. Stop after stage 6 on build day; migration is a separate day (21 Sep).

Files in this folder:
`01-harden-host.sh` · `docker-compose.yml` · `init-data.sh` · `env.example` · `backup.sh` · `restore.sh` · `n8n-selfhost-runbook.md`

---

## Stage 0 — Before you order anything (15 min, laptop)

- [ ] **thinkrep.com is Active on Cloudflare DNS** (it is — moved 26 Aug 2026, Email Routing catch-all lives there; the tunnel CNAME on `n8n.` does not touch the apex MX records). Decision 3 Sep: use thinkrep.com because funnelsix.com is not on Cloudflare; move funnelsix later if wanted — hostname change is a bounded job (OAuth redirect URI, Access apps, tunnel hostname, third-party webhook URLs).
- [ ] You have an SSH key pair on the Mac (`cat ~/.ssh/id_ed25519.pub`). If not: `ssh-keygen -t ed25519 -C mike@mac`.
- [ ] Generate the three secrets now and put them in your password manager under "n8n VPS" — you'll paste them into `.env` in stage 3:
  `openssl rand -hex 32` × 3 → `N8N_ENCRYPTION_KEY`, `POSTGRES_PASSWORD`, `POSTGRES_NON_ROOT_PASSWORD`
- [ ] Copy this whole folder somewhere durable (Google Drive → Atlas Infrastructure, or a private GitHub repo). It was lost once already.

**Gate:** Cloudflare zone active, key exists, secrets stored.

---

## Stage 1 — Provision (10 min + ~5 min Contabo build)

Contabo → **Core** line → **Cloud VPS 4** (4 vCPU, 8 GB, 100 GB SSD; the old "VPS 10 NVMe" tier no longer exists as of Sep 2026) → term **1 month** → Ubuntu **24.04** (Operating System tab — NOT the "n8n" 1-click app) → region EU (Germany) or UK → SSH public key in the order form if offered → no add-ons → order.
Note the IPv4, the root password from the email, and the **renewal date**.

- [ ] Add to Atlas Infrastructure → Hosting & Subscriptions now, not later (name, IP, plan, monthly cost, renewal date, purpose = "n8n automation host"). The research-engine VPS was only recorded months late — don't repeat that.

**Gate:** `ssh root@<ip>` works.

---

## Stage 2 — Harden (15 min)

Open **two** terminal windows, both `ssh root@<ip>`. In window A:

```bash
apt-get install -y curl
curl -fsSL <where-you-stored-it>/01-harden-host.sh -o /root/01-harden-host.sh   # or scp it up
bash /root/01-harden-host.sh n8nops "$(cat ~/.ssh/id_ed25519.pub on your Mac — paste the string)"
```

The script: creates `n8nops` (sudo, your key), disables root + password SSH (validated with `sshd -t` before reload), ufw allow-22-only, fail2ban, unattended security updates with 04:30 reboot, 2 GB swap, Docker CE + compose plugin, log rotation, `/opt/n8n`.

In window **B** (still root, still open): `ssh n8nops@<ip>` from a *third* window on the Mac. Only when that works, `sudo -n true` works, and `docker ps` works as n8nops, close A and B.

**Gate:** key-only login as `n8nops` works; `ssh root@<ip>` is refused; `sudo ufw status` shows only 22/tcp.

---

## Stage 3 — Cloudflare Tunnel + Access (20 min, browser; Claude in Chrome can drive this with you signed in)

Zero Trust dashboard (one.dash.cloudflare.com):

**3a. Tunnel**
Networks → Tunnels → Create tunnel → Cloudflared → name `n8n-vps` → Save. Copy the **token** from the install command (long `eyJ…` string). → Next.
Public hostname: subdomain `n8n`, domain `thinkrep.com`, service **HTTP** → `n8n:5678` (the compose service name — cloudflared runs inside the same docker network). Save.

**3b. Access — two applications, order matters**

*Application 1 (evaluated first): "n8n public endpoints"*
Access → Applications → Add → Self-hosted → name as above → domain `n8n.thinkrep.com`, path — add **all** of these as separate entries:
- `webhook` (covers `/webhook/*`)
- `webhook-test`
- `webhook-waiting`
- `form` (form triggers: Keyword Research, Logo Working, Product Photography)
- `healthz` (external uptime monitor)
- `rest/oauth2-credential/callback` (Google OAuth redirect lands here)
Policy: name `bypass`, action **Bypass**, include **Everyone**.

*Application 2: "n8n editor"*
Same domain, no path (covers everything else). Policy: action **Allow**, include **Emails** = your address(es). Session duration 24 h. Identity provider: One-time PIN is enough (or Google if already set up).

**3c. Order check:** Applications list — the Bypass app must sit **above** the editor app. Drag if needed.

**Gate:** `curl -sI https://n8n.thinkrep.com/webhook/x` returns a Cloudflare **530** or **502** (tunnel exists, origin down) — *not* a 302 to `cloudflareaccess.com`. `curl -sI https://n8n.thinkrep.com/` **does** 302 to cloudflareaccess.com. If both redirect, the Bypass app is below the editor app or the paths are wrong. Fix before stage 4 — this is the single most common way this build fails while looking healthy.

---

## Stage 4 — Bring the stack up (20 min, SSH as n8nops)

```bash
cd /opt/n8n
# copy in: docker-compose.yml init-data.sh env.example backup.sh restore.sh  (scp from Mac)
cp env.example .env && chmod 600 .env
nano .env        # fill: 3 secrets, CLOUDFLARE_TUNNEL_TOKEN. Leave versions as pinned.
chmod +x init-data.sh backup.sh restore.sh
mkdir -p local-files backups
docker compose pull
docker compose up -d
docker compose ps            # all three "healthy" within ~90 s
docker compose logs -f n8n   # wait for "Editor is now accessible via: https://n8n.thinkrep.com/"
```

Browser → https://n8n.thinkrep.com → Access login (OTP to your email) → n8n **owner account setup** (this is a fresh instance; use the funnelsix address, strong password in the password manager).

Settings → check the version shows 2.37.9. Settings → Community nodes: leave off. Settings → Log streaming: n/a.

**Gate:**
- `curl -s http://127.0.0.1:5678/healthz` on the VPS → `{"status":"ok"}`
- `curl -s https://n8n.thinkrep.com/healthz` **from your Mac** → `{"status":"ok"}` (bypass working)
- `docker compose ps` → three healthy.

---

## Stage 5 — Prove a webhook end-to-end (15 min) ← THE REAL GATE

In the new n8n: New workflow → Webhook node, path `smoke`, method GET, Respond = "Immediately", response body `{"ok":true}` → Save → **Activate** (Publish).

From your **Mac**, not the VPS, not the browser you're logged into Access with:
```bash
curl -si https://n8n.thinkrep.com/webhook/smoke
```
Must return `HTTP/2 200` and `{"ok":true}`. Then from a phone on mobile data (different IP, no cookies) open the same URL — must show the JSON, not an Access login page.

Also test a form: Form Trigger node, activate, open `https://n8n.thinkrep.com/form/<path>` from the phone. Must render.

**Gate:** 200 from two networks with no Access challenge. If you get a login page, go back to stage 3c.

Deactivate and delete the smoke workflow afterwards.

---

## Stage 6 — Backups + R2 (20 min)

**6a. R2 bucket** (Cloudflare dashboard → R2): Create bucket `n8n-backups`, location EU/WEUR. R2 → Manage API tokens → Create token: "n8n-backup", permission **Object Read & Write**, scope to bucket `n8n-backups`. Note Access Key ID, Secret, and the S3 endpoint `https://<accountid>.r2.cloudflarestorage.com`.

**6b. rclone on the VPS** (as n8nops):
```bash
rclone config create r2 s3 provider=Cloudflare access_key_id=<id> secret_access_key=<secret> \
  endpoint=https://<accountid>.r2.cloudflarestorage.com acl=private
rclone lsd r2:            # shows n8n-backups
```

**6c. First manual backup:**
```bash
cd /opt/n8n && ./backup.sh
ls -l backups/*/         # n8n-db.dump must be > 10 KB (fresh schema is ~60–100 KB)
rclone ls r2:n8n-backups
```

**6d. Cron:** `crontab -e` → `15 3 * * * /opt/n8n/backup.sh >> /opt/n8n/backups/backup.log 2>&1`

**6e. Optional but recommended today:** fill `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` in `.env` (reuse the Error Logger bot) so a failed backup pings you.

**Gate:** dump on R2, size matches local, cron installed.

**STOP HERE on build day.** Do not import workflows. Let the box run empty for a few days — the uptime monitor (stage 7) makes that time count.

---

## Stage 7 — Monitoring (10 min, can be same day)

Pick one: **UptimeRobot** (free tier: 5-min checks, fine) or **Better Stack** (free: 3-min, nicer alerts). Monitor: HTTPS keyword check on `https://n8n.thinkrep.com/healthz`, expect `"ok"`, alert to email + Telegram/phone.
Disk: add to the crontab `0 8 * * 1 df -h / | tail -1` piped to the Telegram curl from backup.sh — or just let backup.sh's failure alert be the disk alarm (it will fail first).

**Gate:** pause the tunnel container (`docker compose stop cloudflared`) → alert arrives within 10 min → start it again → recovery notice arrives.

---

## Stage 8 — Google OAuth client (30 min, do before 21 Sep, not on build day)

Every Gmail/Drive/Sheets credential on the new box needs your own OAuth client (Cloud's "Managed OAuth" isn't available self-hosted).

1. console.cloud.google.com → project "Atlas n8n" (new or existing) → APIs & Services → enable **Gmail API, Google Drive API, Google Sheets API**.
2. OAuth consent screen → **Internal** if funnelsix.com is Google Workspace; otherwise External → **Publish app** (no verification needed for your own use, but unpublished "Testing" apps expire refresh tokens after **7 days** — this is why the Error Logger died on Cloud after six months and would die weekly here).
3. Credentials → Create OAuth client ID → Web application → Authorised redirect URI: `https://n8n.thinkrep.com/rest/oauth2-credential/callback`.
4. Note client ID + secret → password manager. You'll paste them into each Google credential in n8n on migration day.

---

## Migration day (21 Sep) — see runbook §5

Order: fix nothing on Cloud that day → export via "Atlas Workflow Backup" → create the 5 Google OAuth creds → create the 16 token creds → import Tier A (8 workflows) → re-map → activate one at a time → test → Tier B → TikTok webhooks → leave Cloud active but with the Gmail trigger **deactivated** so both aren't processing the same inbox → checkpoint 26 Oct → cancel decision 20 Nov.
