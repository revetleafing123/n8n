# n8n on Hostless (free tier) + Neon Postgres

Stateless n8n compute on Hostless's free pool; **all state lives in Neon
Postgres**. Hostless's free tier has no persistent volumes, so nothing
stateful may live on the app's disk — the encryption key is an env var and
the database is external.

## Architecture

```
Hostless App (free)            ← compute only, wiped on redeploy
  n8n image via Dockerfile
  N8N_ENCRYPTION_KEY = env var ← survives, not on disk
  N8N_USER_FOLDER=/root/.n8n   ← writable, wiped — that's OK
        └──────────┐ TLS
                   ▼
Neon Postgres      ← ALL state (workflows, executions, users, credentials)
```

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | `FROM n8n` image, clears the entrypoint, writable `/tmp`, 768 MB cap |
| `start.sh` | maps Hostless `$PORT` → `N8N_PORT`, then `exec n8n start` |
| `hostless.yaml` | docker build, 1 replica, health check on `/healthz` |
| `.dockerignore` | trims build context |

## Verified locally (Kiri/Docker, read-only root)

```
PORT=8080 + --read-only --tmpfs /tmp
  → netstat: LISTEN :::8080
  → GET /healthz  : 200
  → GET /         : 200  (title: n8n.io - Workflow Automation)
  → /tmp/.n8n     : created, owned by node
```

Three things had to be fixed to get here, worth knowing if you edit the image:

1. **`N8N_USER_FOLDER=/tmp`** — n8n appends `.n8n` itself, so setting
   `/tmp/.n8n` produced `/tmp/.n8n/.n8n` and `EACCES`. Do not pre-create the
   folder at build time; let the unprivileged `node` user do it.
2. **`ENTRYPOINT []`** — the base image's `tini -- /docker-entrypoint.sh`
   only does `exec n8n "$@"`, so a CMD of `/app/start.sh` is treated as an
   n8n subcommand (`Command "/app/start.sh" not found`).
3. **`sh -c "..."` in CMD fails** for the same reason (`Command "sh" not found`).

Harmless log noise: `Error fetching from Strapi API (api.n8n.io/mcp-servers)
connection timeout` — an outbound telemetry call, not a startup failure.

## One-time setup

### 1. Neon (free Postgres)
1. Sign up at https://neon.tech (no card).
2. Create a project (pick a region near you; free tier is always-on).
3. Copy the **connection string** from the dashboard.
4. ⚠️ Use the **direct** host, not the pooler
   (`-pooler.` in the name). n8n runs migrations at boot and needs a real
   connection, not PgBouncer transaction pooling.
5. It should look like `postgresql://neondb_owner:XXX@ep-xxxx.ap-southeast-1.aws.neon.tech/neondb`.
   Split it into the 5 fields below.

### 2. GitHub repo
```bash
cd n8n-hostless
git init && git add . && git commit -m "n8n hostless"
# create empty repo on GitHub, then:
git remote add origin git@github.com:YOUR_USER/n8n-hostless.git
git push -u origin main
```

### 3. Hostless app
1. https://hostless.cloud → create account (no card).
2. **Create resource → App**, connect GitHub, pick this repo, branch `main`.
3. Build system: **Dockerfile** (auto-detected from `hostless.yaml`).
4. Set env vars (table below) → **Deploy**.

## Environment variables

Set these in Hostless → Settings → Environment variables:

| Variable | Value | Notes |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | 32 hex chars | ⚠️ **write-only** · generate once: `openssl rand -hex 16` · **never change it** or stored credentials become undecryptable |
| `DB_TYPE` | `postgresdb` | |
| `DB_POSTGRESDB_HOST` | `ep-xxxx.ap-southeast-1.aws.neon.tech` | direct host (no pooler) |
| `DB_POSTGRESDB_PORT` | `5432` | |
| `DB_POSTGRESDB_DATABASE` | `neondb` | |
| `DB_POSTGRESDB_USER` | `neondb_owner` | |
| `DB_POSTGRESDB_PASSWORD` | `XXX` | **write-only** |
| `DB_POSTGRESDB_SSL_ENABLED` | `true` | Neon requires TLS |
| `DB_POSTGRESDB_POOL_SIZE` | `5` | Neon free connection cap |
| `N8N_PROTOCOL` | `https` | |
| `N8N_HOST` | `<your-app>.hostless.app` | your app URL |
| `WEBHOOK_URL` | `https://<your-app>.hostless.app/` | trailing slash matters |
| `N8N_PROXY_HOPS` | `1` | HTTPS terminates at Hostless edge |
| `GENERIC_TIMEZONE` | `Asia/Kolkata` | |
| `TZ` | `Asia/Kolkata` | |
| `EXECUTIONS_DATA_PRUNE` | `true` | keep DB small |
| `EXECUTIONS_DATA_MAX_AGE` | `168` | prune after 7 days |
| `N8N_RUNNERS_ENABLED` | `true` | code-node runners |
| `N8N_DIAGNOSTICS_ENABLED` | `false` | privacy |

⚠️ **Do NOT set `N8N_SECURE_COOKIE=false`** — Hostless gives real HTTPS.

⚠️ Set `N8N_HOST`/`WEBHOOK_URL` **before** creating workflows: every webhook
URL is baked into the workflow at creation time.

## Gotchas

- **Read-only root FS:** Hostless mounts the app root read-only. `/root`,
  `/tmp`, `/app/.cache` are writable but wiped on restart. That's why the
  key is an env var and the DB is on Neon.
- **One replica only:** n8n is stateful; `max_replicas: 1`.
- **Memory:** free pool is 1 GiB shared across your account (app + Neon is
  mostly on Neon, so fine). Keep `max_memory` ≤ 768 MB.
- **If the build can't reach `docker.n8n.io`:** use Docker Hub instead -
  `docker.io/n8nio/n8n:latest` resolves fine (`docker pull n8nio/n8n` works).
  The `N8N_IMAGE` build-arg exists exactly for this switch.
- **Docker DNS in a sandboxed builder:** `docker.n8n.io` timed out from one
  network here while `docker.io` worked. If the Hostless build fails at
  `load metadata`, swap the build-arg first.

## Local test (optional, with Kiri/Docker)

```bash
docker run --rm -p 5678:5678 \
  -e N8N_PORT=5678 \
  -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=<neon-host> \
  -e DB_POSTGRESDB_PORT=5432 \
  -e DB_POSTGRESDB_DATABASE=neondb \
  -e DB_POSTGRESDB_USER=neondb_owner \
  -e DB_POSTGRESDB_PASSWORD=<pw> \
  -e DB_POSTGRESDB_SSL_ENABLED=true \
  --name n8n-test n8n-hostless
# open http://localhost:5678
```