# n8n Self-Host — Ops Runbook

Host: Contabo VPS, Ubuntu 24.04, `/opt/n8n`, user `n8nops`. Public: https://n8n.thinkrep.com via Cloudflare Tunnel `n8n-vps`.
Stack: n8n 2.37.9 · Postgres 16 · cloudflared 2026.8.3 (pinned in `.env`).
Backups: nightly 03:15 → `/opt/n8n/backups` (7 d) + R2 `n8n-backups` (30 d).

Calendar hooks: **Mon 09:00** weekly check (§1) · **first Tue 09:00** upgrade (§2) · **quarterly from 12 Jan 2027** restore test (§3).

---

## 1. Weekly check (Mon 09:00, 5 min)

```bash
ssh n8nops@<ip>
cd /opt/n8n
docker compose ps                         # 3 × healthy
df -h / ; free -m                         # disk < 70 %, swap not pegged
tail -3 backups/backup.log                # last line "backup OK", dated last night
docker compose logs --since 168h n8n | grep -ciE 'error|fatal'   # trend, not absolute
```
In the n8n UI: Overview → failure rate for the week. Anything > 5 % → §4.
Uptime monitor: no incidents.

Log one line in Atlas (LOG-NNN or the Infrastructure base): date, disk %, failure rate, backup OK.

---

## 2. Monthly upgrade (first Tue 09:00, 20 min)

n8n ships weekly; take one minor per month, never `latest`, never same-day releases.

```bash
cd /opt/n8n
./backup.sh                                       # always, first
# pick the version: https://github.com/n8n-io/n8n/releases — newest 2.x that is ≥ 1 week old
# read its notes for "breaking" — 2.x majors change task-runner / node behaviour occasionally
sed -i 's/^N8N_VERSION=.*/N8N_VERSION=2.XX.Y/' .env
docker compose pull n8n
docker compose up -d n8n                          # DB migrations run on start; watch them:
docker compose logs -f n8n                        # until "Editor is now accessible"
curl -s http://127.0.0.1:5678/healthz
```
Then in the UI: run one Tier-A workflow manually (Daily Digest is the cheapest) → success.

**Rollback** (if migrations fail or a workflow breaks):
```bash
sed -i 's/^N8N_VERSION=.*/N8N_VERSION=<previous>/' .env
docker compose up -d n8n
# if the DB migrated forward and the old version refuses to start:
./restore.sh /opt/n8n/backups/<the one you just took>
```
cloudflared: bump `CLOUDFLARED_VERSION` quarterly (`docker compose up -d cloudflared`); Postgres minor (16.x) is picked up automatically by `pull` — never change the major without a dump/restore.

Also monthly: `sudo apt list --upgradable` (unattended-upgrades handles security only), `sudo docker system prune -f`.

---

## 3. Quarterly restore test (from 12 Jan 2027, 30 min)

Prove the backups restore, on the real box, without breaking it:
```bash
cd /opt/n8n && ./backup.sh                         # fresh known-good
LATEST=$(ls -1d backups/*/ | tail -1)
./restore.sh "$LATEST"                             # type RESTORE
```
Then: UI loads, credentials still decrypt (open one — if it shows "could not decrypt", `N8N_ENCRYPTION_KEY` in `.env` differs from the one the backup was made under), run Daily Digest manually.
Once a year do it from **R2** instead of local: `./restore.sh r2:n8n-backups/<stamp>`.
Record the result in Atlas.

---

## 4. Fault triage

| Symptom | Check | Fix |
|---|---|---|
| Uptime alert, site down | Contabo status page **http://www.contabo-status.com** first (data-centre incident = nothing to fix), then `docker compose ps` | container restarting → `docker compose logs --tail 100 <svc>` |
| Editor loads, **webhooks return Access login page** | Zero Trust → Access → Applications order | Bypass app must be above the editor app; paths must include `webhook`, `webhook-test`, `form` |
| Editor loads, webhooks return **404** | Workflow not Published / path typo | Publish; production URL is `/webhook/<path>`, test URL is `/webhook-test/<path>` and only works while "Listen for test event" is on |
| **530 / 502** from Cloudflare | cloudflared can't reach n8n | `docker compose logs cloudflared`; usually n8n not healthy yet → wait 90 s; or tunnel token rotated |
| "Couldn't connect" on a **Google** credential | Refresh token expired | Reconnect. If it happens weekly → OAuth app still in Testing status (BUILD-ORDER §8) |
| **Airtable 401** | PAT revoked/rotated | New PAT, base-scoped (see inventory doc); update credential |
| Executions **piling up / slow** | `free -m`, `docker stats` | Cloud VPS 4 is 4 vCPU/8 GB; Gmail Core is 162 nodes — check `EXECUTIONS_DATA_PRUNE` is working: `docker compose exec postgres psql -U postgres n8n -c "select count(*) from execution_entity;"` should stay < 20 000 |
| **Disk > 85 %** | `ncdu /` | Usually `/var/lib/docker` (old images → `docker system prune -a`) or execution data (lower `EXECUTIONS_DATA_MAX_AGE`) or `backups/` (retention cron missed) |
| n8n won't start: **"encryption key mismatch"** | `.env` was regenerated | Restore the original `N8N_ENCRYPTION_KEY` from the password manager. There is no other recovery. |
| n8n: **"password authentication failed for user n8n"** on first boot | `docker compose logs postgres` shows `init-data.sh: Permission denied` | `chmod 755 init-data.sh`, then `docker compose down -v && docker compose up -d` — safe ONLY on an empty instance; `-v` destroys the database |
| backup.sh log shows **501 NotImplemented** on attempt 1, then "Attempt 2/3 succeeded" | `backups/backup.log` | Known R2 + newer-rclone quirk (checksum header on first PUT). Harmless — retries succeed and the size is verified. Only investigate if all 3 attempts fail |
| backup.sh: rclone **403 AccessDenied** intermittently | `rclone --bind <vps-ipv4> lsd r2:n8n-backups` works but plain `rclone lsd` doesn't | The R2 token is IP-filtered to the IPv4; rclone went out over IPv6. Ensure `RCLONE_BIND=<vps-ipv4>` is in `.env` (backup.sh exports it; the flag is `--bind`, so the env var is RCLONE_BIND). If the VPS IP ever changes, update BOTH the token's IP filter and `.env` |
| Postgres won't start after reboot | `docker compose logs postgres` | Corrupt WAL after hard power-off → `./restore.sh` from last night |
| Locked out of SSH | Contabo VNC console | log in as root on the console (root password from Contabo), fix `/etc/ssh/sshd_config.d/10-hardening.conf`, `systemctl reload ssh` |
| Locked out of **Access** (lost email OTP) | Cloudflare dashboard on any device | Access → Applications → editor → add a second email / temporarily set policy to Bypass |

Emergency full rebuild: new VPS → stage 2 → stage 4 with the **same `.env`** → `./restore.sh r2:n8n-backups/<latest>` → repoint tunnel (Zero Trust → Tunnels → the tunnel runs wherever the token runs; no DNS change needed). ~45 min.

---

## 5. Migration day procedure (21 Sep)

Pre-reqs: BUILD-ORDER stages 0–8 complete; box has run ≥ 5 days with no uptime incident; inventory doc to hand.

1. **Cloud:** run "Atlas Workflow Backup AC | Core" manually → confirm today's export in Drive. Also Settings → Download all workflows if the option exists on your plan. Do **not** deactivate anything on Cloud yet.
2. **New box, credentials first** (Credentials → Add). Google ones use your own client ID/secret from §8:
   - Gmail ×2 (Funnelsix, Atlas Money 16) · Drive ×2 (Funnelsix, Atlas Money 16) · Sheets (Funnelsix)
   - Airtable PATs: Atlas Finance, Email Hub — consider **new** tokens named `n8n-selfhost-…` so Cloud and self-host can be revoked independently
   - OpenAI, OpenRouter (N8N_Atlas), Gemini ×2, Telegram ×3, Apify header + query, DataForSEO, Cloudinary, S3
   - n8n API: generate on the **new** instance (Settings → n8n API) for the Workflow Backup flow
   Name them **identically** to Cloud — n8n maps imported workflows by credential ID, and when the ID is missing it offers the same-name credential, which saves a click per node.
3. **Import Tier A** (8): Receipt System, Gmail Core, Daily Digest, Monthly/Quarterly/Yearly reports, Error Logger, Workflow Backup. Import → open each → fix red credential badges → Save. Set the Error Workflow on each (Settings → Error workflow → Atlas Error Logger).
4. **Activate one at a time and test:**
   - Error Logger first (it needs to exist before others error)
   - Receipt System → send a test receipt to the Telegram bot → record lands in Airtable
   - Daily Digest → run manually → Telegram message
   - Gmail Core → activate on new box, **then immediately deactivate on Cloud** (two pollers on one inbox = duplicates) → send yourself a test email → processed
   - Financial reports: run each manually with a throwaway recipient if the flow allows; otherwise trust schedule + Error Logger
   - Workflow Backup → run manually → file in Drive
5. **Tier B** (Keyword Research ×2, Logo Working V2): import, re-map, activate, test each form URL from your phone.
6. **TikTok Social Signals** (4, webhook): import; activate; `curl` the `/webhook/...` path from the Mac → 200. Update whatever calls them (Apify webhook URLs) to the new hostname.
7. **Leave behind:** Competitor Analysis (9 — decide separately), 35 empty shells, all archived.
8. On Cloud: deactivate every workflow you migrated. Keep the account until the 20 Nov decision; **turn off auto-renew today** so the decision defaults to "cancel" not "£288".
9. Atlas: update Hosting & Subscriptions (n8n Cloud → "migrating, cancel 20 Nov"), log the migration.

Checkpoint **26 Oct**: five weeks of self-hosted runtime. Failure rate < 5 %, backups OK, no manual restarts → the 20 Nov decision is made.
