# Production Deployment — Zeronix Frappe Stack (ERPNext + CRM)

This document covers deploying **this repository** (official `frappe_docker`,
plus the Zeronix production additions below) to the OVH VPS at
`57.131.160.147`, serving `https://zeronixos.online` and
`https://www.zeronixos.online` through an already-running, separately
managed Caddy instance.

This is **not** the local `pwd.yml` quick-start — that remains for local
testing only and is untouched by anything here.

## 1. Architecture

```
Internet
    |
    v
Caddy (already running, /srv/docker/proxy, ports 80/443)
    |
    v
proxy-net (external, shared with other apps e.g. SouqFeed)
    |
    v
zeronix-frappe-frontend  (nginx, service "frontend", internal port 8080)
    |
    +-- backend (gunicorn :8000)
    +-- websocket (:9000)
    +-- queue-short / queue-long (bench worker)
    +-- scheduler (bench schedule)
    |
    v
frappe_docker's private "default" network (this project's compose network)
    |
    +-- db (MariaDB 11.8, service "db", private only)
    +-- redis-cache / redis-queue (private only)
```

Only `frontend` joins `proxy-net`. Every other service (db, redis, backend,
workers, scheduler, websocket) is reachable only on this project's own
private network — never on `proxy-net`, never with a host port published.

**Frontend service/container:** `frontend`, reachable on `proxy-net` as
**`zeronix-frappe-frontend`** (explicit alias + `container_name`, see
`overrides/compose.proxy-net.yaml`). **Internal port: `8080`**
(`NGINX_LISTEN_PORT`, confirmed in `compose.yaml`).

## 2. Why a custom image is required

The public `frappe/erpnext` image on Docker Hub contains only `frappe` +
`erpnext`. **Frappe CRM is not in it.** To get ERPNext + CRM in one stack,
this repo builds its own image from `apps.json` using the official
`images/layered/Containerfile` pattern (documented in
`docs/02-setup/02-build-setup.md`) — this is the standard frappe_docker
"custom apps" mechanism, not a bespoke build system.

`apps.json` (committed — contains only public repo URLs/branches, no
secrets):

```json
[
  { "url": "https://github.com/frappe/erpnext", "branch": "version-16" },
  { "url": "https://github.com/frappe/crm", "branch": "v1.88.0" }
]
```

**Why CRM is pinned to `v1.88.0`, not `main`:** `main`'s current
`pyproject.toml` requires `frappe ">=16.0.0-dev,<=17.0.0-dev"` (fine), but
`crm/hooks.py` on `main` sets `required_apps = ["whatsapp"]` — an
unreleased hard dependency not part of any stable CRM release. Installing
from `main` would make `bench install-app crm` refuse to run unless the
`frappe/whatsapp` app is also built in and installed, which was never
requested. The latest stable tag, `v1.88.0` (released 2026-10-15), requires
`frappe ">=15.0.0,<17.0.0"` (compatible with `version-16`) and has
`required_apps` commented out. **Use the tag, not `main`.**

Frappe framework itself uses branch `version-16` (build arg, not listed in
`apps.json` — matches this repo's existing `v16.50.0` local dev stack).

## 3. Prerequisites on the VPS

Sections 1–9 of the existing OVH runbook (Ubuntu update, swap, SSH
hardening, UFW, Docker Engine + Compose, `/srv/docker` layout, shared Caddy
on `proxy-net`) apply unchanged and are assumed already done, since Caddy
and SouqFeed are already running there.

```bash
sudo mkdir -p /srv/docker/frappe
sudo chown -R $USER:$USER /srv/docker/frappe
sudo docker network inspect proxy-net >/dev/null 2>&1 || sudo docker network create proxy-net
```

## 4. Clone and configure

```bash
cd /srv/docker/frappe
git clone https://github.com/ismail-zeronix/zeronixos-online.git .

cp production.env.example .env
nano .env
```

Fill in `.env`:
- `DB_PASSWORD` — `openssl rand -hex 24`
- `ADMIN_PASSWORD` — `openssl rand -hex 16`
- Leave `SITE_NAME=zeronixos.online`, `CUSTOM_IMAGE=zeronix-frappe`,
  `CUSTOM_TAG=16`, `PULL_POLICY=missing` as-is.

```bash
chmod 600 .env
```

## 5. Build the custom image (ERPNext + CRM)

```bash
sudo docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --secret=id=apps_json,src=apps.json \
  --tag=zeronix-frappe:16 \
  --file=images/layered/Containerfile .
```

This takes a while the first time (clones frappe + erpnext + crm, builds
Python/JS assets). It produced an image that includes `frappe`, `erpnext`,
and `crm` apps.

## 6. Define the compose file combination

Used consistently everywhere below — define once as a shell variable:

```bash
COMPOSE="sudo docker compose --env-file .env \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.proxy-net.yaml \
  -f overrides/compose.healthcheck.yaml"
```

- `compose.mariadb.yaml` — MariaDB 11.8, private, persistent volume,
  `pg_isready`-equivalent healthcheck (`healthcheck.sh`), **no `3306:3306`
  publish**.
- `compose.redis.yaml` — `redis-cache` + `redis-queue`, private, **no
  `6379:6379` publish**.
- `compose.proxy-net.yaml` — joins only `frontend` to the shared external
  `proxy-net`, aliased `zeronix-frappe-frontend`.
- `compose.healthcheck.yaml` — adds a container healthcheck to `frontend`
  using Frappe's own `/api/method/frappe.ping` endpoint.

## 7. Start the database and Redis first

```bash
$COMPOSE up -d db redis-cache redis-queue
```

## 8. Create the site and install apps

```bash
$COMPOSE -f overrides/compose.create-site.yaml --profile tools run --rm create-site
$COMPOSE -f overrides/compose.install-crm.yaml --profile tools run --rm install-crm
```

- `create-site` runs `bench new-site` + `--install-app erpnext`, idempotent
  (skips if the site already exists).
- `install-crm` runs `bench --site zeronixos.online install-app crm`
  afterwards, as a separate explicit step.

## 9. Start the full stack

```bash
$COMPOSE -f overrides/compose.migrator.yaml up -d
```

`overrides/compose.migrator.yaml` is the **official** frappe_docker
migration mechanism: a `migrator` service that runs `bench --site all
migrate` automatically on every `up -d` (gated by `MIGRATE_SITES=true` in
`.env`), then exits. This is the Frappe/Bench equivalent of what a
Node/Prisma app would call a migration step — there is no `prisma migrate
deploy` here, this is MariaDB + Bench, not PostgreSQL + Prisma.

## 10. Caddy integration

**Do not install or configure Caddy from this repository.** Append to the
existing `/srv/docker/proxy/Caddyfile`:

```
zeronixos.online, www.zeronixos.online {
    reverse_proxy zeronix-frappe-frontend:8080
}
```

```bash
cd /srv/docker/proxy
sudo docker compose restart caddy
curl -I https://zeronixos.online
curl -I https://zeronixos.online/api/method/frappe.ping
```

Both hostnames proxy to the same single site. Since only one site exists,
`.env` sets `FRAPPE_SITE_NAME_HEADER=zeronixos.online` so nginx always
serves that site regardless of which of the two hostnames was requested
(instead of the default per-request `Host`-based site lookup, which would
otherwise fail for `www.zeronixos.online` since no site folder by that name
exists).

## 11. Health and exposure verification

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
sudo docker inspect --format='{{.State.Health.Status}}' zeronix-frappe-frontend
curl -sf http://127.0.0.1:8080/api/method/frappe.ping 2>&1 || echo "not reachable from host (expected - no host port published)"
sudo ss -tulpn | grep -E ':(3306|6379|8080)\b' || echo "No MariaDB/Redis/frontend ports exposed on host"
sudo docker network inspect proxy-net
```

Expected: only Caddy binds host ports 80/443. `frontend` is reachable
**only** via Docker's internal network (`zeronix-frappe-frontend:8080` on
`proxy-net`), not from the host directly — the `curl 127.0.0.1:8080` above
is expected to fail/connection-refuse on the host, which is correct.

Useful logs:
```bash
$COMPOSE logs -f frontend
$COMPOSE logs -f backend
$COMPOSE logs -f scheduler
$COMPOSE logs -f queue-short queue-long
$COMPOSE logs -f websocket
$COMPOSE logs -f db
```

## 12. Backups

MariaDB data persists in Docker volume `db-data` (and site files in
`sites`), but **a volume is not a backup**. Use `bench backup --with-files`,
copied out to the host:

```bash
chmod +x /srv/docker/frappe/production/backup-frappe.sh
sudo /srv/docker/frappe/production/backup-frappe.sh
```

Backups land in `/srv/docker/backups/frappe/<timestamp>/`, 14-day
retention (pruned by the script itself).

**Host-level cron** (deliberately not run from inside any container):
```bash
crontab -e
# add:
15 3 */3 * * /srv/docker/frappe/production/backup-frappe.sh >> /var/log/frappe-backup.log 2>&1
```

### Restore

```bash
cd /srv/docker/frappe
BACKUP_DIR=/srv/docker/backups/frappe/<timestamp>
CONTAINER_ID=$($COMPOSE ps -q backend)
sudo docker cp "$BACKUP_DIR/." "$CONTAINER_ID:/home/frappe/frappe-bench/sites/zeronixos.online/private/backups/"
$COMPOSE exec -T backend bash -c '
  cd sites/zeronixos.online/private/backups &&
  LATEST_SQL=$(ls -t *-database.sql.gz | head -1) &&
  LATEST_FILES=$(ls -t *-files.tar | head -1) &&
  LATEST_PRIVATE=$(ls -t *-private-files.tar | head -1) &&
  bench --site zeronixos.online restore "$LATEST_SQL" --with-public-files "$LATEST_FILES" --with-private-files "$LATEST_PRIVATE"
'
```

Confirm the backup and schema before replacing production data. Do not
improvise destructive restores.

## 13. Updates / redeploys

```bash
cd /srv/docker/frappe
./production/deploy.sh
```

`deploy.sh`:
1. Tags the current `zeronix-frappe:16` image as `zeronix-frappe:rollback`
   (not deleted on failure).
2. `git pull --ff-only origin main` (this config repo).
3. Rebuilds `zeronix-frappe:16` from `apps.json` (pulls latest from the
   pinned frappe/erpnext/crm refs).
4. `docker compose up -d` with the migrator override (runs `bench --site
   all migrate` automatically).
5. Polls `docker inspect` health status on `zeronix-frappe-frontend` for up
   to 60s; exits 0 only when healthy, exits 1 with logs guidance otherwise.

Does **not** delete volumes, does **not** run `docker system prune`, does
**not** auto-rollback a database migration.

### Rollback

Bench migrations are not auto-reversible. If a deploy fails:
```bash
sudo docker tag zeronix-frappe:rollback zeronix-frappe:16
$COMPOSE up -d
```
This restores the previous **application code**. If the failed deploy also
ran a schema migration, a code-only rollback may not match the current
schema — treat any migration as part of release design, same as the
runbook used for the SouqFeed stack. Use the most recent `bench backup` to
restore data if a migration caused data-level damage.

## 14. Storage and housekeeping

```bash
df -h
sudo docker system df
sudo docker images
```

Do not run `docker system prune` or other aggressive/automatic cleanup —
rollback images and layers shared with other builds may be removed.

## 15. Security checklist

- [x] MariaDB: no `3306:3306` (confirmed via `docker compose config` + `ss -tulpn`)
- [x] Redis: no `6379:6379`
- [x] `frontend`: no host port published — reachable only via `proxy-net`
- [x] Only `frontend` joins `proxy-net`; db/redis/backend/workers/scheduler/websocket stay on the private default network
- [x] `.env` is git-ignored (`.gitignore` already excludes `.env`); `chmod 600 .env` on the server
- [x] No credentials committed — `apps.json` contains only public repo URLs
- [x] No Docker socket mounted into any application container
- [x] Caddy (not this repo) terminates TLS and handles HTTP→HTTPS redirect
- [x] Does not touch SouqFeed's containers, volumes, database, Redis, or compose files — the only shared resource is `proxy-net`

## 16. Troubleshooting

| Symptom | Check |
|---|---|
| 502 from Caddy | `sudo docker inspect --format='{{.State.Health.Status}}' zeronix-frappe-frontend`, `$COMPOSE logs frontend backend` |
| Site not found / wrong site served | Confirm `FRAPPE_SITE_NAME_HEADER=zeronixos.online` in `.env`, confirm `sites/zeronixos.online` exists in the `sites` volume |
| CRM install fails | Re-run `install-crm` after confirming `create-site` succeeded and `erpnext` is installed first |
| Migration fails on deploy | `$COMPOSE logs migrator`; the stack still starts even if `migrator` fails (`restart: on-failure:5`) — investigate before relying on the new code path |
| Build fails fetching frappe/erpnext/crm | Transient GitHub/network issue on the VPS — re-run the build in step 5 |
