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

## Stage 3 — Cloudflare Tunnel + Access ✅ DONE 3 Sep 2026 (Claude in Chrome)

Zero Trust account: Free plan, team name `twilight-snow-5211` (auto-assigned; rename under Settings if wanted).

**3a. Tunnel** `n8n-vps` (cloudflared, remotely managed). Published application route: `n8n.thinkrep.com` → HTTP `n8n:5678`. DNS CNAME created automatically. Token: Networks → Tunnels & Mesh → n8n-vps → Configure → copy from the install command into `.env` as `CLOUDFLARE_TUNNEL_TOKEN`.

**3b. Access** (Access controls → Applications):
- `n8n public endpoints (bypass)` — destinations `n8n.thinkrep.com/webhook`, `/webhook-test`, `/webhook-waiting`, `/form`, `/healthz`; policy `bypass-public-endpoints` = Bypass, Everyone. (Free tier caps an app at 5 hostnames; `rest/oauth2-credential/callback` is deliberately omitted — that redirect is followed by your own logged-in browser, which carries the Access cookie.)
- `n8n editor` — destination `n8n.thinkrep.com` (all other paths); policy `allow-mike` = Allow, Emails = mike@funnelsix.com; session 24 h; identity = One-time PIN.
- Ordering: the current dashboard evaluates Bypass/Service-Auth policies before Allow policies, so no manual reordering is needed.

**Gate (passed 3 Sep before the VPS existed):** `https://n8n.thinkrep.com/healthz` → Cloudflare Error 1033 (tunnel not connected, *no* login challenge); `https://n8n.thinkrep.com/` → redirect to `*.cloudflareaccess.com`. Re-run the same two checks after stage 4: healthz must then return `{"status":"ok"}`.

---

## Stage 4 — Bring the stack up ✅ DONE 3 Sep 2026 (20 min, SSH as n8nops)

```bash
cd /opt/n8n
# copy in: docker-compose.yml init-data.sh env.example backup.sh restore.sh  (scp from Mac)
cp env.example .env && chmod 600 .env
nano .env        # fill: 3 secrets, CLOUDFLARE_TUNNEL_TOKEN. Leave versions as pinned.
chmod 755 init-data.sh backup.sh restore.sh   # 755, not just +x: Postgres runs init-data.sh as an unprivileged user inside the container; a 600/700 file gives "Permission denied" and the n8n DB role is never created
mkdir -p local-files backups
docker compose pull
docker compose up -d
docker compose ps            # all three "healthy" within ~90 s
docker compose logs -f n8n   # wait for "Editor is now accessible via: https://n8n.thinkrep.com/"
```

Browser → https://n8n.thinkrep.com → Cloudflare Access login → n8n **owner account setup** (done 3 Sep; owner = mike@funnelsix.com, password in password manager 'n8n self-host owner') (this is a fresh instance; use the funnelsix address, strong password in the password manager).

Settings → check the version shows 2.37.9. Settings → Community nodes: leave off. Settings → Log streaming: n/a.

**Gate:**
- `curl -s http://127.0.0.1:5678/healthz` on the VPS → `{"status":"ok"}`
- `curl -s https://n8n.thinkrep.com/healthz` **from your Mac** → `{"status":"ok"}` (bypass working)
- `docker compose ps` → three healthy.

---

## Stage 5 — Prove a webhook end-to-end ✅ PASSED 3 Sep 2026 (15 min) ← THE REAL GATE

Result: `/webhook/smoke` returned 200 `{"message":"Workflow was started"}` from Chrome AND from a phone on mobile data (no cookies). Note: some phone browsers flag a brand-new hostname as suspicious the first time — expected for a domain with no reputation yet; it still served the JSON. Identity provider on the editor app turned out to be the Cloudflare dashboard login (not OTP) — fine, still restricted to mike@funnelsix.com by the allow policy.

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

**6a. R2 bucket** (Cloudflare dashboard → R2): Create bucket `n8n-backups`, location EU/WEUR. R2 → Manage API tokens → Create **Account** API token: `n8n-backup (VPS rclone)`, permission **Object Read & Write**, apply to specific bucket `n8n-backups` only, TTL forever, Client IP filter Include = the VPS IP (token is useless from anywhere else). Note Access Key ID, Secret, and the S3 endpoint `https://<accountid>.r2.cloudflarestorage.com`.

**6b. rclone on the VPS** (as n8nops):
```bash
# ONE line — a line break loses the later args. no_check_bucket is REQUIRED with a bucket-scoped token
# (otherwise rclone tries to create the bucket first and R2 returns 403 AccessDenied on every write).
rclone config create r2 s3 provider=Cloudflare access_key_id=<id> secret_access_key=<secret> endpoint=https://<accountid>.r2.cloudflarestorage.com acl=private no_check_bucket=true
rclone lsd r2:n8n-backups      # bucket-scoped token: `rclone lsd r2:` (account level) is EXPECTED to 403
echo test > /tmp/t.txt && rclone copy /tmp/t.txt r2:n8n-backups/_probe/ && rclone delete r2:n8n-backups/_probe/ && echo WRITE-OK
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
