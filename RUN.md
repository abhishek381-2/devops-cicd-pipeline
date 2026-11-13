# 🚀 How to Run This Project

> Three ways to run it, from "click the preview link" to a full
> app + PostgreSQL + Nginx stack on your own machine.
>
> **It is already running right now** — see [Option 0](#option-0--already-running).

---

## Option 0 — Already running ✅

The app is live in this sandbox. Open the **live preview** panel, or hit it
directly:

| Endpoint | URL |
|---|---|
| 📊 **Dashboard** | `http://localhost:8000/` |
| Health (readiness, JSON) | `http://localhost:8000/health` |
| Dashboard data (JSON) | `http://localhost:8000/api/dashboard` |
| Deployment logs (JSON) | `http://localhost:8000/api/logs` |
| List users | `http://localhost:8000/api/users` |
| Statistics | `http://localhost:8000/api/stats` |

> Open **`/`** in a browser to see the monitoring dashboard. Panels whose data
> source is not configured on this machine (Docker, pipeline, Trivy) honestly
> show **"Not configured"** — see [Option 4](#option-4--enable-the-full-dashboard).

```bash
# From a terminal in this sandbox
curl http://localhost:8000/health
curl -X POST http://localhost:8000/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Ada Lovelace","email":"ada@example.com"}'
curl http://localhost:8000/api/users
```

### 🌐 One command to go public

```bash
cd /home/user/devops-cicd-project
./scripts/go-public.sh
```

It repairs the environment, collects real host metrics, starts Gunicorn, opens
a Cloudflare HTTPS tunnel and verifies the public URL end to end. It prints:

```
 PUBLIC URL : https://<random-words>.trycloudflare.com/
 Health     : https://<random-words>.trycloudflare.com/health
 Dashboard  : https://<random-words>.trycloudflare.com/
```

| Flag | Effect |
|---|---|
| *(none)* | app + public tunnel |
| `--no-tunnel` | local only (`http://127.0.0.1:8000/`) |
| `--stop` | stop the tunnel and the app |

> The quick-tunnel hostname **changes on every restart** and Cloudflare gives no
> uptime guarantee. For a permanent URL see [docs/GO_LIVE.md](docs/GO_LIVE.md).

### One command to repair + restart

If the environment is ever reset (a fresh sandbox, a new machine, a `git
pull` that changed the dependencies), this single command rebuilds everything
and brings the app back:

```bash
cd /home/user/devops-cicd-project
./scripts/resume-preview.sh
```

It:

1. creates `.venv` if it is missing and installs the pinned dependencies,
2. restores the executable bit on the shell scripts (often lost on copy/zip),
3. creates `instance/` and points `DATABASE_URL` at the local SQLite file,
4. starts Gunicorn on `0.0.0.0:8000`,
5. polls `/health` until it reports `"status": "healthy"` and prints the result.

Options: `--setup-only` (repair, don't start), `--foreground` (run in the
foreground, Ctrl-C to stop), `--port <n>`.

The exact command used to start the managed preview:

```bash
cd /home/user/devops-cicd-project
export APP_ENV=production APP_VERSION=1.0.0 SECRET_KEY=local-demo-secret \
       LOG_FORMAT=json DATABASE_URL="sqlite+pysqlite:///$PWD/instance/app.db"

.venv/bin/gunicorn --bind 0.0.0.0:8000 --workers 3 --threads 2 \
    --access-logfile - --error-logfile - --capture-output wsgi:app
```

> **Note:** this sandbox has no Docker and no PostgreSQL server, so the demo
> uses SQLite. The PostgreSQL path is identical — only the `DATABASE_URL`
> changes (see Option 1).

---

## Option 1 — Full stack with Docker (recommended for your machine)

**Requirements:** Docker Engine 24+ with the Compose v2 plugin.

### 1.1 Get the code

```bash
git clone https://github.com/YOUR_USERNAME/devops-cicd-project.git
cd devops-cicd-project
```

### 1.2 Configure the environment

```bash
cp .env.example .env
```

Edit `.env` and set at least these two values:

```ini
POSTGRES_PASSWORD=choose-a-real-password
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(48))")
```

### 1.3 Start everything

```bash
docker compose up -d --build
```

**Expected output:**

```
[+] Running 4/4
 ✔ Network devops-cicd-net      Created
 ✔ Container devops-cicd-db     Started
 ✔ Container devops-cicd-app    Started
 ✔ Container devops-cicd-nginx  Started
```

### 1.4 Check that it is healthy

```bash
docker compose ps          # all three services: Up (healthy)
curl http://localhost:8080/health
```

**Expected:**

```json
{"application":"devops-cicd-app",
 "checks":{"database":{"latency_ms":0.97,"status":"up"}},
 "environment":"development","status":"healthy",
 "timestamp":"2026-11-11T17:21:15+00:00","version":"1.0.0"}
```

### 1.5 Exercise the API

```bash
# Create
curl -X POST http://localhost:8080/api/users -H "Content-Type: application/json" \
     -d '{"name":"Ada Lovelace","email":"ada@example.com"}'      # -> 201

# Duplicate
curl -X POST http://localhost:8080/api/users -H "Content-Type: application/json" \
     -d '{"name":"Ada","email":"ada@example.com"}'                # -> 409

# Invalid
curl -X POST http://localhost:8080/api/users -H "Content-Type: application/json" \
     -d '{"name":"","email":"nope"}'                              # -> 400

# List & stats
curl http://localhost:8080/api/users
curl http://localhost:8080/api/stats
```

### 1.6 Stop it

```bash
docker compose down         # keeps the database volume
docker compose down -v      # deletes the database volume too
```

### 1.7 Common problems

| Problem | Fix |
|---|---|
| `service "db" is unhealthy` | The password in `.env` changed after the volume was created → `docker compose down -v && docker compose up -d --build` |
| `port is already allocated` | Change `NGINX_HTTP_PORT` in `.env` to `8081` |
| `relation "users" does not exist` | `docker compose exec app flask --app wsgi init-db` |
| Nginx returns 502 | The app container is not healthy → `docker compose logs app` |

---

## Option 2 — Python only, no Docker

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt

cp .env.example .env
set -a && . ./.env && set +a

# SQLite (no server needed)
export DATABASE_URL="sqlite+pysqlite:///$PWD/instance/app.db"

flask --app wsgi init-db      # create the schema
flask --app wsgi seed-db      # optional demo data
python wsgi.py                # http://127.0.0.1:8000
```

**With a real PostgreSQL:**

```bash
sudo apt install postgresql postgresql-contrib
sudo -u postgres psql -c "CREATE USER appuser WITH PASSWORD 'yourpassword';"
sudo -u postgres psql -c "CREATE DATABASE devops_cicd OWNER appuser;"

export DATABASE_URL="postgresql+psycopg2://appuser:yourpassword@localhost:5432/devops_cicd"
flask --app wsgi init-db
python wsgi.py
```

---

## Option 3 — Run the tests and the quality gates

```bash
cd /home/user/devops-cicd-project
source .venv/bin/activate

pytest -v                        # 84 tests
ruff check .                     # lint
black --check .                  # formatting
shellcheck -S style scripts/*.sh # shell scripts
```

Or with the Makefile:

```bash
make setup     # venv + dependencies
make test      # pytest with coverage
make lint      # ruff + black + shellcheck
make ci        # lint + test (exactly what the pipeline runs first)
make help      # every target
```

---

## Option 4 — Enable the full dashboard

The dashboard works out of the box, but the host/pipeline/Trivy panels need data
sources. Here is how each one is switched on.

### Host metrics (CPU / RAM / disk / Docker containers)

```bash
cd /home/user/devops-cicd-project

# one snapshot into a directory of your choice
mkdir -p /tmp/hoststate
STATE_DIR=/tmp/hoststate ./scripts/collect-metrics.sh
python3 -m json.tool /tmp/hoststate/metrics.json

# point the app at it and restart
HOST_STATE_DIR=/tmp/hoststate HOST_LOG_DIR=/tmp/hoststate/logs \
  ./scripts/resume-preview.sh
```

On a real EC2 host, install it as a systemd timer instead — one snapshot per
minute, forever:

```bash
sudo /opt/devops-cicd/deploy/scripts/collect-metrics.sh --install
sudo systemctl status devops-metrics.timer
```

This is already done automatically by `setup-server.sh` (step 9).

### Pipeline + Trivy panels

Nothing to do. CI stage 10 publishes `pipeline.json`, and stage 5 publishes
`security.json` into `/opt/devops-cicd/state/` on every deployment.

### Deployments + Logs

Also automatic — `deploy.sh` and `rollback.sh` write `deployments.json`,
`current-image`, `previous-image` and the log files.

### Verify

```bash
curl -s http://localhost:8000/api/dashboard | python3 -m json.tool | head -50
```

| Panel | Before any data source | After |
|---|---|---|
| Application Health | live (always works) | live |
| Server / Docker | "Not configured" | real gauges |
| Pipeline | "Not configured" | last Actions run |
| Security | "Not configured" | real Trivy counts |
| Deployments / Logs | "No deployment recorded" | real history |

---

## Option 5 — Measure the image sizes

```bash
make measure-images
# → builds both images and prints the reduction percentage
```

Without Docker, measure the components:

```bash
python3 tools/measure_images.py
# → base-image layer sizes from the Docker Hub registry API + the real
#   virtualenv footprint
```

---

## Option 6 — Rehearse the deployment + rollback locally

This exercises the **real** `deploy.sh` / `rollback.sh` / `health-check.sh`
without touching a server. A mock `docker` CLI stands in for the real one.

```bash
cd /home/user/devops-cicd-project

export MOCK_DIR=/tmp/mockdeploy MOCK_PORT=8010 PATH="/tmp/mockbin:$PATH"
mkdir -p "$MOCK_DIR"/{deploy,state,logs}
cp docker-compose.prod.yml "$MOCK_DIR/deploy/"
cp -r nginx "$MOCK_DIR/deploy/"
mkdir -p "$MOCK_DIR/deploy/scripts" && cp scripts/*.sh "$MOCK_DIR/deploy/scripts/"
printf 'POSTGRES_USER=appuser\nPOSTGRES_PASSWORD=pw\nPOSTGRES_DB=devops_cicd\nSECRET_KEY=k\nAPP_DOMAIN=localhost\n' \
  > "$MOCK_DIR/deploy/secrets.env"

cd "$MOCK_DIR/deploy"
export BASE_DIR="$MOCK_DIR" DEPLOY_DIR="$MOCK_DIR/deploy" \
       HEALTH_URL="http://127.0.0.1:8010/health" HEALTH_RETRIES=3 HEALTH_INTERVAL=2

# a good release
./scripts/deploy.sh --image ghcr.io/testuser/devops-cicd-app --tag sha-good111

# a broken release -> the health check fails -> automatic rollback
./scripts/deploy.sh --image ghcr.io/testuser/devops-cicd-app --tag sha-bad222

cat "$MOCK_DIR/state/current-image"   # -> sha-good111 (restored)
```

Expected for the broken release:

```
[health-check] Attempt 1/3 failed - HTTP 503
[health-check] Attempt 2/3 failed - HTTP 503
[health-check] Attempt 3/3 failed - HTTP 503
[health-check] FAILED - the application did not become healthy after 3 attempts.
[rollback]    Rollback SUCCESSFUL - ...:sha-good111 is serving traffic again.
[deploy]      Rollback completed successfully, but the deployment FAILED.
→ exit code 1
```

---

## What was verified in this sandbox

| Check | Command | Result |
|---|---|---|
| Test suite | `pytest -q` | **78 passed** |
| Lint | `ruff check .` | clean |
| Format | `black --check .` | clean |
| Shell lint | `shellcheck -S style scripts/*.sh` | clean |
| Syntax | `bash -n scripts/*.sh` | clean |
| All 5 endpoints | `curl` against Gunicorn | 200 / 201 / 400 / 409 / 404 |
| Health with the DB down | unreachable DSN | **503 `"status":"unhealthy"`** |
| Health-check script | healthy / dead / 503 | exit 0 / 1 / 1 |
| Deploy → validate | `deploy.sh` (good tag) | exit 0, `current-image` written |
| **Deploy → fail → rollback** | `deploy.sh` (bad tag) | **exit 1, previous image restored, healthy again** |
| `deploy.sh` guards | `--tag latest` / missing args | exit 2 with a clear message |
| Dashboard page | `curl -D- /` | **200 `text/html`**, 19 KB |
| `/health` after the change | `curl /health` | **200, identical JSON contract** |
| Dashboard payload | `curl /api/dashboard` | 200, every section present |
| Missing data sources | no host state configured | `available:false` + `reason` (no fake numbers) |
| Live host metrics | `collect-metrics.sh` | real CPU 3.8 %, RAM 32.4 %, disk 18 % |
| Deployment history | deploy → fail → rollback | 3 real records, `rank`/`kind` correct |
| Trivy summary | `build-security-summary.py` | CRITICAL=0 HIGH=1 MEDIUM=1 LOW=1 |
| **Nginx HTTP vhost** | real nginx 1.26.3, `nginx -t` + live traffic | **config OK**; `/` HTML, `/health` JSON |
| **Nginx HTTPS vhost** | rendered template + self-signed cert | **config OK**; `/` 200, `/static/` cached 1 h |
| **CSP in a real browser** | headless Chromium over HTTPS | **0 console errors**, all values rendered |
| Responsive layout | 1440 px and 390 px viewports | desktop grid / mobile drawer |
| `rollback.sh` with no history | `rollback.sh` | exit 2, "nothing to roll back to" |
| Git file modes | `git ls-files -s` | scripts recorded as `100755` |

---

## Next steps

1. Read **[docs/EXECUTION_GUIDE.md](docs/EXECUTION_GUIDE.md)** for the complete
   GitHub → GHCR → EC2 → SSL walkthrough.
2. Read **[docs/FAILURE_SIMULATION.md](docs/FAILURE_SIMULATION.md)** to rehearse
   the six failure drills.
3. Fill in **[docs/METRICS.md](docs/METRICS.md)** with your real measurements.
4. Replace every `OWNER` / `REPO` / `YOUR_USERNAME` / `app.example.com`
   placeholder before you publish.
