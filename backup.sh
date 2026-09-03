#!/usr/bin/env bash
# backup.sh — nightly n8n backup: Postgres dump + n8n data volume -> local + Cloudflare R2
# Install:  cp backup.sh /opt/n8n/ && chmod 700 /opt/n8n/backup.sh
# Cron (as the ops user):  15 3 * * * /opt/n8n/backup.sh >> /opt/n8n/backups/backup.log 2>&1
#
# Exit non-zero (and Telegram-alert, if configured) on any failure, including a dump
# that is suspiciously small. A backup that silently produces 200 bytes is worse than none.

set -euo pipefail
cd /opt/n8n
set -a; source ./.env; set +a

STAMP="$(date +%Y%m%d-%H%M%S)"
DAY_DIR="${BACKUP_DIR}/${STAMP}"
MIN_DUMP_BYTES=10240          # 10 KB — an empty n8n schema dump is already bigger than this
PROJECT=n8n                    # matches `name:` in docker-compose.yml
N8N_VOLUME="${PROJECT}_n8n_data"

alert() {
  echo "BACKUP FAILED: $*" >&2
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -fsS -m 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" -d text="🔴 n8n backup FAILED on $(hostname): $*" >/dev/null || true
  fi
  exit 1
}
trap 'alert "unexpected error at line $LINENO"' ERR

mkdir -p "$DAY_DIR"
echo "[$STAMP] starting backup -> $DAY_DIR"

# 1. Postgres logical dump (custom format: compressed, restorable with pg_restore)
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc \
  > "${DAY_DIR}/n8n-db.dump"
DUMP_BYTES=$(stat -c %s "${DAY_DIR}/n8n-db.dump")
if (( DUMP_BYTES < MIN_DUMP_BYTES )); then
  alert "pg_dump is only ${DUMP_BYTES} bytes (< ${MIN_DUMP_BYTES})"
fi
echo "  db dump: ${DUMP_BYTES} bytes"

# 2. n8n data volume (config incl. instance id, binary data, custom nodes)
docker run --rm --user "$(id -u):$(id -g)" -v "${N8N_VOLUME}:/data:ro" -v "${DAY_DIR}:/out" alpine \
  tar -czf /out/n8n-data.tgz -C /data .
echo "  volume:  $(stat -c %s "${DAY_DIR}/n8n-data.tgz") bytes"

# 3. the compose + env that produced this state (env is secret — keep the tarball private)
tar -czf "${DAY_DIR}/n8n-config.tgz" docker-compose.yml .env init-data.sh backup.sh
chmod -R go-rwx "$DAY_DIR"

# 4. ship to R2
if ! rclone lsd "${RCLONE_REMOTE}" >/dev/null 2>&1; then
  alert "rclone remote ${RCLONE_REMOTE} is not reachable — check rclone config"
fi
rclone copy "$DAY_DIR" "${RCLONE_REMOTE}/${STAMP}" --transfers 2 --checkers 2 --stats-one-line
# verify the dump actually landed and matches
REMOTE_BYTES=$(rclone size "${RCLONE_REMOTE}/${STAMP}/n8n-db.dump" --json | jq -r .bytes)
if [[ "$REMOTE_BYTES" != "$DUMP_BYTES" ]]; then
  alert "remote dump size ${REMOTE_BYTES} != local ${DUMP_BYTES}"
fi
echo "  uploaded to ${RCLONE_REMOTE}/${STAMP} (verified ${REMOTE_BYTES} bytes)"

# 5. retention
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"${LOCAL_RETENTION_DAYS}" -exec rm -rf {} +
rclone delete "${RCLONE_REMOTE}" --min-age "${REMOTE_RETENTION_DAYS}d" --rmdirs >/dev/null 2>&1 || true

echo "[$STAMP] backup OK"
