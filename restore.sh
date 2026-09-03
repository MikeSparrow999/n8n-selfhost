#!/usr/bin/env bash
# restore.sh — rebuild n8n from a backup set (local dir or R2 stamp). Used for the quarterly
# restore test and for real disaster recovery. DESTROYS the current database.
#
# Usage:  ./restore.sh /opt/n8n/backups/20260903-031500
#         ./restore.sh r2:n8n-backups/20260903-031500
set -euo pipefail
cd /opt/n8n
set -a; source ./.env; set +a

SRC="${1:?backup dir or rclone path}"
WORK=$(mktemp -d)
if [[ "$SRC" == *:* ]]; then rclone copy "$SRC" "$WORK"; else cp "$SRC"/* "$WORK"/; fi
ls -l "$WORK"

read -r -p "This will DROP the current n8n database and volume. Type RESTORE to continue: " ok
[[ "$ok" == "RESTORE" ]] || exit 1

docker compose stop n8n cloudflared
# database
docker compose exec -T postgres psql -U "$POSTGRES_USER" -c "DROP DATABASE IF EXISTS ${POSTGRES_DB};"
docker compose exec -T postgres psql -U "$POSTGRES_USER" -c "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_NON_ROOT_USER};"
docker compose exec -T postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --role="$POSTGRES_NON_ROOT_USER" < "$WORK/n8n-db.dump"
# data volume
docker run --rm -v n8n_n8n_data:/data -v "$WORK":/in alpine sh -c 'rm -rf /data/* && tar -xzf /in/n8n-data.tgz -C /data'
docker compose up -d
sleep 20
curl -fsS http://127.0.0.1:5678/healthz && echo " -> restore OK"
rm -rf "$WORK"
