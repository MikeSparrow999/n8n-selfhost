# n8n-selfhost

Self-hosted n8n on a Contabo VPS behind Cloudflare Tunnel (`n8n.thinkrep.com`), replacing n8n Cloud.

Start with **BUILD-ORDER.md**. Day-2 operations are in **n8n-selfhost-runbook.md**.

| File | Purpose |
|---|---|
| `01-harden-host.sh` | one-shot Ubuntu 24.04 hardening + Docker install (run as root, once) |
| `docker-compose.yml` | n8n 2.37.9 + Postgres 16 + cloudflared 2026.8.3 |
| `init-data.sh` | creates the non-root Postgres role on first start |
| `env.example` | copy to `.env` on the VPS and fill in — `.env` is git-ignored |
| `backup.sh` | nightly pg_dump + volume tar → local + R2, size-verified |
| `restore.sh` | rebuild from a backup set (quarterly test / DR) |

Versions are pinned in `env.example`; bump only via the runbook's monthly upgrade procedure.
