# DEPLOY.md — n8n on Hostless (free tier) + Neon Postgres

Battle-tested runbook. Every gotcha below was hit and fixed during the real
deployment on **2026-11-16**. Follow it top to bottom for a flawless deploy.

- **Status:** live and working
- **Stack:** Hostless free app (Dockerfile) + Neon Postgres (external)
- **Repo:** `github.com/revetleafing123/n8n`, branch `main`
- **Known limitation:** slow editor UI on 0.5 vCPU (see §9)

---

## 1. Architecture

```
Hostless App (free, 0.5 vCPU / 1 GB shared pool)
  image: n8nio/n8n (via Dockerfile)
  read-only root FS  →  writes only to /tmp
  N8N_ENCRYPTION_KEY = env var (write-only in dashboard)
        │
        │  DB_POSTGRESDB_*  (5 separate vars, NOT a URL)
        ▼
Neon Postgres (free 0.5 GB, always-on)
  = ALL state: workflows, credentials, executions, users
```

**Why external Postgres:** Hostless's free tier has **no persistent volumes**
(durable volumes require an eligible payment method). Nothing stateful may live
on the app's disk. The encryption key survives as an env var; everything else
lives in Neon.

---

## 2. Files and what each one does

| File | Purpose | Do not break |
|---|---|---|
| `Dockerfile` | `FROM n8nio/n8n:latest`, clears entrypoint, `N8N_USER_FOLDER=/tmp` | see §4 |
| `start.sh` | maps `$PORT` → `N8N_PORT`, then `exec n8n start` | must be LF |
| `hostless.yaml` | `scaling` + `health_check` only | **no `build:` block** |
| `.gitattributes` | forces LF for `*.sh` | required on Windows |
| `.gitignore` | blocks `.env`, `secrets/`, `*.pem`, `*.key` | required |
| `.env.example` | template with no values | safe to commit |
| `.dockerignore` | trims build context | — |
| `README.md` | Neon + env-var reference | — |

---

## 3. One-time setup

### 3.1 Neon Postgres
1. https://neon.tech → sign up (no card).
2. New project → pick the region **closest to you** (latency matters, see §9).
3. Copy the connection string:
   ```
   postgresql://USER:PASSWORD@ep-xxxx.REGION.aws.neon.tech/neondb?sslmode=require
   ```
4. ⚠️ **Use the DIRECT host — no `-pooler` in the name.** n8n runs migrations at
   boot; PgBouncer transaction pooling breaks them.
5. ⚠️ Port is **5432** even though Neon's UI omits it (it's the Postgres default).

### 3.2 GitHub repo
```bash
cd n8n
git init && git add -A && git commit -m "n8n for Hostless"
git branch -M main
git remote add origin https://github.com/<you>/n8n.git
git push -u origin main
```

### 3.3 Generate the encryption key (once, forever)
```bash
openssl rand -hex 16
```
⚠️ **Never change it.** If it changes, every stored credential becomes
permanently undecryptable. No recovery, no undo.

---

## 4. Hostless app creation

| Field | Value |
|---|---|
| App name | `n8n` |
| Repository | your repo |
| Branch | `main` |
| **Runtime** | ⬜ **leave EMPTY** |
| **Framework** | ⬜ **leave EMPTY** |
| **Build system** | ✅ **Docker** ← the only field that matters |
| **Start command** | ⬜ **leave EMPTY** |
| **Volume** | ⬜ **none** (free tier has none; needs a card) |

### Why runtime/framework must stay empty
Hostless docs: *"If your framework is not in this list, you can usually deploy it
with a Dockerfile."* Selecting a runtime triggers Nixpacks auto-detection and
**ignores your Dockerfile**.

### Why start command must stay empty
The `Dockerfile` `CMD` **is** the start command. Typing anything there overrides
it, and plain `n8n start` binds **5678** instead of Hostless's `$PORT` → health
check fails.

---

## 5. Environment variables

Paste into **Hostless → Settings → Environment variables**.

### Required

| Name | Value | Notes |
|---|---|---|
| `N8N_ENCRYPTION_KEY` | 32 hex chars | ⚠️ **write-only** |
| `DB_TYPE` | `postgresdb` | |
| `DB_POSTGRESDB_HOST` | neon direct host | **no `-pooler`** |
| `DB_POSTGRESDB_PORT` | `5432` | |
| `DB_POSTGRESDB_DATABASE` | `neondb` | |
| `DB_POSTGRESDB_USER` | `neondb_owner` | |
| `DB_POSTGRESDB_PASSWORD` | secret | ⚠️ **write-only** |
| `DB_POSTGRESDB_SSL_ENABLED` | `true` | Neon requires TLS |
| `DB_POSTGRESDB_POOL_SIZE` | `5` | Neon free connection cap |
| `N8N_PROTOCOL` | `https` | |
| `N8N_HOST` | `your-app.hostless.app` | **no `https://`, no trailing slash** |
| `WEBHOOK_URL` | `https://your-app.hostless.app/` | **with** trailing slash |
| `N8N_PROXY_HOPS` | `1` | TLS terminates at Hostless edge |

### Recommended

| Name | Value | Effect |
|---|---|---|
| `GENERIC_TIMEZONE` | `Asia/Kolkata` | schedule triggers |
| `TZ` | `Asia/Kolkata` | container clock |
| `EXECUTIONS_DATA_PRUNE` | `true` | keeps DB small |
| `EXECUTIONS_DATA_MAX_AGE` | `168` | drop runs > 7 days |
| `EXECUTIONS_DATA_PRUNE_MAX_COUNT` | `500` | hard cap on stored runs |
| `N8N_RUNNERS_ENABLED` | `true` | code-node runners |
| `N8N_DIAGNOSTICS_ENABLED` | `false` | privacy |

### ⚠️ Do NOT set

| Variable | Why |
|---|---|
| `N8N_SECURE_COOKIE=false` | Hostless gives real HTTPS; this would weaken it |
| `DATABASE_URL` | **n8n ignores it** — it is a Prisma/ORM convention (§6) |
| `N8N_PATH` | causes `Cannot GET /` |
| `N8N_RUNNERS_MODE=external` | needs a 2nd container; free tier cannot run it |

---

## 6. The single biggest trap: n8n does not read `DATABASE_URL`

Hostless and every managed Postgres dashboard hand you **one URL**. n8n needs
**five separate variables**. `DATABASE_URL` alone deploys fine and then fails at
boot.

Split the string yourself:

```
postgresql://neondb_owner:PASSWORD@ep-xxx.region.aws.neon.tech/neondb?sslmode=require
             └ user ──┘ └─ pw ─┘ └────── host ──────┘ └ db ┘   └ drop this ┘
```

| Piece | Env var |
|---|---|
| `neondb_owner` | `DB_POSTGRESDB_USER` |
| `PASSWORD` | `DB_POSTGRESDB_PASSWORD` |
| `ep-xxx.region.aws.neon.tech` | `DB_POSTGRESDB_HOST` |
| `neondb` | `DB_POSTGRESDB_DATABASE` |
| *(implicit)* | `DB_POSTGRESDB_PORT=5432` |

⚠️ Drop `?sslmode=require` — n8n handles TLS via `DB_POSTGRESDB_SSL_ENABLED`.
⚠️ **Percent-encode the password** if it contains `@ : / ? # [ ] %`. This is the
most common cause of "authentication failed" with a correct password.

Safe splitter (password never printed):
```bash
read -r -p "Paste full DSN: " DSN
echo "$DSN" | sed -E 's#^postgres(ql)?://([^:]+):[^@]+@([^:/]+):?([0-9]+)?/([^?]+).*#USER=\2\nHOST=\3\nPORT=\4\nDB=\5#'
unset DSN
```

---

## 7. Gotchas that cost real time — all fixed

### 7.1 `whitelistValidation: property dockerfile_path should not exist`
```yaml
build:
  system: docker
  dockerfile_path: "./Dockerfile"   # ← REJECTED by the live schema
```
Hostless's docs show this key but the validator refuses it.
✅ **Fix: delete the whole `build:` block.** The build system is chosen in the
dashboard and `./Dockerfile` at repo root is found automatically.

### 7.2 `429 Too Many Requests` from `docker.n8n.io`
n8n's own registry rate-limits anonymous manifest HEAD requests.
✅ **Fix:** default to Docker Hub.
```dockerfile
ARG N8N_IMAGE=n8nio/n8n:latest   # identical digest sha256:b4b90747...
```
Override only if needed: `--build-arg N8N_IMAGE=docker.n8n.io/n8nio/n8n:latest`

⚠️ Docker Hub carries **`latest`** plus `nightly-*` tags; it does **not** carry
stable semver tags (`3.2.2` is absent). Use `latest`.

### 7.3 `N8N_USER_FOLDER=/root/.n8n` → `EACCES: mkdir '/root/.n8n/.n8n'`
Two problems: n8n **appends** `.n8n` to the value, and the read-only root blocks
the mkdir.
✅ **Fix:** `ENV N8N_USER_FOLDER=/tmp` → n8n creates `/tmp/.n8n`.
⚠️ Do **not** pre-create the folder in the Dockerfile; let the unprivileged
`node` user do it or permissions break.

### 7.4 `Command "sh" not found` / `Command "/app/start.sh" not found`
The base image uses `ENTRYPOINT [tini -- /docker-entrypoint.sh]`, which only does
`exec n8n "$@"`. It treats CMD as **n8n subcommands**, not a program to run.
✅ **Fix:** clear the entrypoint in the child image.
```dockerfile
ENTRYPOINT []
COPY --chmod=755 start.sh /app/start.sh
CMD ["/app/start.sh"]
```

### 7.5 `bad interpreter: /bin/sh^M`
Windows CRLF in `start.sh`.
✅ **Fix:** `.gitattributes` with `*.sh text eol=lf`. Verify:
```bash
git show :start.sh | od -c | head -2   # want: # ! / b i n / s h \n
```

### 7.6 Build fails at `load metadata`
The builder cannot reach the registry. Try, in order: rebuild, then swap the
`ARG` to the other registry, then pin a tag instead of `latest`.

---

## 8. Deploy checklist

- [ ] Neon project created, **direct** host copied (no `-pooler`)
- [ ] `openssl rand -hex 16` generated, saved somewhere safe
- [ ] All 13 required env vars entered in Hostless
- [ ] `N8N_ENCRYPTION_KEY` and `DB_POSTGRESDB_PASSWORD` marked **write-only**
- [ ] Runtime + Framework + Start command left **empty**
- [ ] Build system = **Docker**
- [ ] No volume attached
- [ ] Deploy → health is **healthy**, not "unhealthy"

### Expected healthy log
```
Migrations in progress, please wait.
✔️ Migrations finished
n8n ready on ::, port 8080
Editor is now accessible via:
```

- [ ] `GET /healthz` → **200**
- [ ] `GET /` → **200**, editor renders
- [ ] Owner account created (email + password)
- [ ] ⚠️ **`N8N_HOST` + `WEBHOOK_URL` set to the real hostname, then redeploy**
- [ ] Test workflow: Manual Trigger → Set → Execute (proves Neon writes)

⚠️ Set `N8N_HOST`/`WEBHOOK_URL` **before** creating any webhook workflow. Webhook
URLs are baked in at creation time and break if the host later changes.

---

## 9. Known limitations

### Slow editor UI — expected
0.5 vCPU / 1 GB shared. Every editor action is browser → Hostless edge → n8n →
**Neon over the internet**. Order of cheap wins:
1. **Neon region closest to you** ← biggest single improvement
2. Raise `max_memory` to the free ceiling (`768`)
3. `EXECUTIONS_DATA_PRUNE_MAX_COUNT=500` (smaller tables = faster loads)

Not fixable by tuning: this tier is for **running** workflows, not snappy
authoring. For real speed you need always-on VM compute:
- **Oracle Cloud Always Free** — 2 OCPU / 12 GB ARM (10–20× this)
- **GCP e2-micro** — 1 vCPU / 1 GB, never expires

### Python Code nodes do not work
The image is a **Docker Hardened Image on Alpine 3.24 with no package manager**
(`apk` stripped), so Python 3 cannot be installed. Internal Python task runner
fails and logs:
```
Failed to start Python task runner in internal mode ... Python 3 is missing
```
- ✅ **JavaScript Code nodes work fine**
- ⚠️ External runner mode needs a **second container** — impossible on one free app

### Deprecation warnings are harmless
`N8N_UNVERIFIED_PACKAGES_ENABLED`, `N8N_RUNNERS_MODE`, `N8N_RUNNERS_TASK_TIMEOUT`,
`N8N_COMPRESSION_NODE_*`, and `[license SDK] license cert is not initialized`
(Community Edition). Optional pinning:
```
N8N_UNVERIFIED_PACKAGES_ENABLED=true
N8N_RUNNERS_TASK_TIMEOUT=300
N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES=2147483648
N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES=5000
```

### Database will fill 0.5 GB without pruning
Execution history is ~80–90% of the DB. Pruning is **mandatory**. To cut growth
further, add `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none` (keeps error debugging).

---

## 10. Troubleshooting table

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot GET /` | `N8N_HOST` includes `https://`, or `N8N_PATH` set | correct `N8N_HOST`, delete `N8N_PATH` |
| `getaddrinfo ENOTFOUND` | wrong host / used `-pooler` | direct host only |
| `password authentication failed` | password not percent-encoded | encode `@ : / ? #` |
| `no pg_hba.conf entry ... SSL off` | `DB_POSTGRESDB_SSL_ENABLED` missing | set `true` |
| Deployment stuck "unhealthy" | start command set, bound 5678 | clear start command |
| `Read-Only Filesystem` | volume over `/tmp` | detach volume |
| `bad interpreter: /bin/sh^M` | CRLF in `start.sh` | verify `.gitattributes` pushed |
| Build `429` | n8n registry throttled | use Docker Hub default |
| Build `not found` | rate-limited or unreachable registry | swap `ARG`, retry |
| `Cannot read properties ... DATABASE_URL` | only URL provided | use the 5 `DB_POSTGRESDB_*` vars |
| CSP / `cloudflareinsights` console errors | Cloudflare's own page, n8n uses `Content-Security-Policy-Report-Only` | **harmless, ignore** |
| `Chrome DevTools 404` | `/.well-known/appspecific/com.chrome.devtools.json` | **harmless, ignore** |

---

## 11. Local verification (Kiri / Docker)

Proves the image works before deploying.

```bash
export MSYS_NO_PATHCONV=1          # Git Bash mangles --tmpfs /tmp otherwise

docker pull n8nio/n8n:latest
docker build --build-arg N8N_IMAGE=docker.io/n8nio/n8n:latest -t n8n-local .

docker run -d --name n8n-local --read-only --tmpfs /tmp \
  -e PORT=5678 \
  -e N8N_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef \
  -e GENERIC_TIMEZONE=Asia/Kolkata -e TZ=Asia/Kolkata \
  -p 5678:5678 n8n-local

sleep 60
curl -s -o /dev/null -w "healthz=%{http_code}\n" http://127.0.0.1:5678/healthz
curl -s -o /dev/null -w "editor=%{http_code}\n"  http://127.0.0.1:5678/
docker logs n8n-local | grep -E "n8n ready|Editor is now"
```

Expected: `healthz=200`, `editor=200`, `n8n ready on ::, port 5678`.

Full-parity test (read-only FS + real Neon) — add the `DB_*` vars and run with
`--env-file .env` instead of paste-on-command-line:

```bash
docker run -d --name n8n-prod-test --read-only --tmpfs /tmp \
  -e PORT=5678 --env-file .env -p 5678:5678 n8n-local
```

⚠️ `docker compose` is not registered in Kiri (`unknown command`). Use
`docker run`, or `kiri setup --use` to install the plugin.

⚠️ Kiri's BuildKit may fail to resolve `docker.io` tags (`not found`) while a
plain `docker pull` works. That is a local buildx quirk, not a Dockerfile fault —
`docker pull` first, then build.

---

## 12. Operating notes

| Task | Command / setting |
|---|---|
| Rebuild after editing files | push to `main`; Hostless redeploys automatically |
| Redeploy without a change | Hostless → **Deploy changes** / **Redeploy latest** |
| View logs | Hostless → app → Logs |
| Rotate DB password | Neon → reset password → update `DB_POSTGRESDB_PASSWORD` → redeploy |
| Backup | `pg_dump` from Neon (Neon also keeps PITR restore) |
| Health endpoint | `/healthz` |

⚠️ **Never** delete `N8N_ENCRYPTION_KEY` or change it. Back it up in a password
manager now.

---

## 13. Platform comparison (why Hostless)

Free-tier facts gathered while choosing. Limits change — verify before relying.

| Platform | Free RAM | DB included | Volumes | Always-on | Verdict for n8n |
|---|---|---|---|---|---|
| **Hostless** | **1 GB shared** | yes | 💳 needs card | ✅ | ✅ **chosen** |
| Neon (DB only) | — | 0.5 GB | — | ✅ PITR | ✅ **chosen for DB** |
| StackShift | 512 MB | 1 DB | ✅ 1–100 GB | ✅ | ✅ good alt (compose + volumes), region Helsinki only |
| ProductEcho | unpublished | **1 GB** | ? | ? | ✅ Dockerfile works; free compute + idle behaviour unverified |
| Suga | **256 MiB / 0.1 vCPU** | — | ❌ 1 GB cap | ✅ | ❌ cannot run n8n |
| Kubeletto | 512 MiB | ❌ | ❌ | ❌ **scale-to-zero** | ❌ breaks cron/webhooks |
| Vercel | 2 GB/fn | — | — | ❌ 300 s cap | ❌ schedule triggers unreliable |
| Render (free) | 512 MB | ✅ 30-day expiry | — | ❌ sleeps 15 min | ❌ |
| **Oracle Cloud Always Free** | **12 GB ARM** | — | ✅ | ✅ | ⭐ best for speed |

⚠️ Also avoided: Supabase free (pauses after 7 days idle), Prisma Postgres free
(200k query cap kills n8n, no backups), freebase.cloud (unpublished storage).

---

## 14. Security rules learned the hard way

1. **Never paste credentials into an AI chat.** Rotation is the only remedy.
2. `.env` **must** be in `.gitignore` before it exists. Verify:
   ```bash
   git check-ignore -v .env        # must print a match
   git ls-files | grep -x .env     # must print nothing
   ```
3. Mark `N8N_ENCRYPTION_KEY` and `DB_POSTGRESDB_PASSWORD` **write-only** in the
   dashboard so they can never be revealed again.
4. Back up `N8N_ENCRYPTION_KEY` offline (password manager). It is the single
   point of no recovery.
