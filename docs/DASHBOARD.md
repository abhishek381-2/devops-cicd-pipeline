# 📊 Monitoring Dashboard

`GET /` now serves a dark, Grafana/Datadog-inspired DevOps dashboard instead of
raw JSON. `GET /health` is **unchanged** — same JSON, same status codes — so the
Docker healthcheck, the CI validation step and the rollback logic keep working
exactly as before.

> **Design rule #1: no fake data.** Every number comes from a real source. When
> a source is missing, the panel says **"Not configured"** or **"Unavailable"**
> — it never invents a plausible-looking value.

---

## 1. Where the data comes from

| Panel | Real source | Written by |
|---|---|---|
| Application Health | Live `SELECT 1` probe against PostgreSQL | the Flask app, per request |
| Database + latency | Measured round-trip in milliseconds | the Flask app, per request |
| Version / Environment | `APP_VERSION`, `APP_ENV` env vars | deployment config |
| Docker containers | `docker ps -a` on the host | `scripts/collect-metrics.sh` (systemd timer) |
| Server CPU / RAM / Disk | `/proc/stat`, `/proc/meminfo`, `df -P` | `scripts/collect-metrics.sh` |
| Latest deployment | `state/current-image`, `state/previous-image` | `scripts/deploy.sh` |
| Deployment history | `state/deployments.json` | `scripts/deploy.sh` + `scripts/rollback.sh` |
| CI/CD pipeline status | GitHub Actions REST API | `scripts/write-pipeline-status.py` (CI stage 10) |
| Trivy scan summary | Real Trivy JSON report | `scripts/build-security-summary.py` (CI stage 5) |
| Logs | `logs/deploy-*.log`, `logs/rollback-*.log` | both deploy scripts |

### How the container reads host data without privileges

The Flask container has **no Docker socket, no shell, and no host filesystem
access**. A tiny collector runs on the host and writes plain JSON; the container
reads those files through a **read-only bind mount**:

```
HOST (/opt/devops-cicd)                CONTAINER (uid 10001)
  state/metrics.json      ───────────▶  /app/hoststate/metrics.json   :ro
  state/deployments.json                /app/hoststate/deployments.json
  state/pipeline.json                   /app/hoststate/pipeline.json
  state/security.json                   /app/hoststate/security.json
  logs/deploy-*.log       ───────────▶  /app/hostlogs/deploy-*.log    :ro
```

`docker-compose.prod.yml`:

```yaml
volumes:
  - /opt/devops-cicd/state:/app/hoststate:ro
  - /opt/devops-cicd/logs:/app/hostlogs:ro
```

The state directories are group-owned by **gid 10001** (the app's uid/gid) with
mode `0750`, so the container can read them and no other host user can.

### Staleness is surfaced, not hidden

Every snapshot carries `generated_at`. If it is older than `HOST_STATE_MAX_AGE`
(default 180 s) the API flags `stale: true` and the UI shows
**"Stale (331s old)"** — you can tell the difference between a healthy idle
server and a dead collector.

---

## 2. UI structure

| Sidebar section | What it shows |
|---|---|
| **Overview** | Six metric cards: health, database, version/env, DB latency, containers, latest deployment |
| **Application Health** | The live `/health` contract: status, DB, latency, checked-at, uptime, user count, raw JSON |
| **Server Monitoring** | CPU / Memory / Disk donut gauges, hostname, OS, uptime, load average, per-mount usage bars |
| **CI/CD Pipeline** | Last Actions run: workflow, conclusion, branch, commit, duration, plus a chip per pipeline stage |
| **Deployments** | Current release, rollback target, deployment-duration bar chart, full history table |
| **Docker Monitoring** | Per-container table: name, image, state, health, status |
| **Security Scans** | Trivy counts (Critical/High/Medium/Low), scanned image, policy verdict, CVE table |
| **Logs** | Colour-coded tail of the deployment and rollback logs |

### Interaction

- **Auto-refresh** every **30 seconds** (`REFRESH_MS = 30000` in `dashboard.js`).
- **Manual refresh** button in the top bar; the icon spins while the request is in flight.
- Sidebar highlights the section you are looking at (`IntersectionObserver`).
- On mobile the sidebar becomes a slide-in drawer with a scrim; `Esc` closes it.
- Respects `prefers-reduced-motion`.

### No external dependencies

No CDN, no framework, no web font, no build step. Charts are hand-drawn SVG.
This means the dashboard renders identically on an air-gapped server — and it is
verifiable in the test suite (`test_static_assets_do_not_leak_external_requests`).

---

## 3. API reference

### `GET /api/dashboard`

```json
{
  "generated_at": "2026-11-12T17:50:39+00:00",
  "app":         { "name": "...", "version": "1.0.0", "environment": "production",
                   "uptime_seconds": 2.83, "user_count": 5 },
  "health":      { "status": "healthy",
                   "checks": { "database": { "status": "up", "latency_ms": 0.86, "error": null } } },
  "host":        { "available": true, "cpu": {...}, "memory": {...}, "disk": [...],
                   "containers": [...], "stale": false, "age_seconds": 8 },
  "deployments": { "available": true, "current_tag": "sha-aaaa111",
                   "previous_tag": null, "history": [ ... ] },
  "pipeline":    { "available": true, "conclusion": "success", "stages": [ ... ] },
  "security":    { "available": true, "critical": 0, "high": 1, "vulnerabilities": [ ... ] },
  "logs":        { "available": true, "entries": [ ... ] }
}
```

Every section carries `available` and, when `false`, a `reason`
(`not_configured`, `no_logs`, `permission_denied`, `invalid_json`).

### `GET /api/logs?limit=60`

Returns `{ available, reason, files[], entries[] }`. `limit` is clamped to 1–500
and falls back to 60 on garbage input.

---

## 4. Enabling the panels on a real server

### One-time (already done by `setup-server.sh`)

`scripts/setup-server.sh` step 9 installs the collector as a systemd timer:

```bash
sudo /opt/devops-cicd/deploy/scripts/collect-metrics.sh --install
sudo systemctl status devops-metrics.timer
cat /opt/devops-cicd/state/metrics.json | python3 -m json.tool
```

The timer runs every 60 seconds and writes `state/metrics.json` atomically
(temp file + `mv`), so a reader never sees a half-written file.

### Every deployment (automatic)

| Panel | Becomes live after |
|---|---|
| Deployments / history | the first `scripts/deploy.sh` run |
| Pipeline | CI stage **10 (Publish the dashboard status)** |
| Security | CI stage **5 (Trivy)** |
| Logs | the first deploy |
| Docker / CPU / RAM / Disk | the first collector run (~60 s after setup) |

Until then the panels honestly read **"Not configured"**.

### Running the collector by hand

```bash
cd /opt/devops-cicd/deploy
./scripts/collect-metrics.sh                 # one snapshot
./scripts/collect-metrics.sh --install       # install + enable the timer
```

---

## 5. Files touched by this feature

**New**

| Path | Purpose |
|---|---|
| `app/monitoring.py` | Reads the host snapshots; builds the dashboard payload |
| `app/templates/dashboard.html` | Dashboard markup + inline SVG icons |
| `app/static/css/dashboard.css` | Dark theme, responsive layout |
| `app/static/js/dashboard.js` | Fetch + render + auto-refresh + charts |
| `scripts/collect-metrics.sh` | Host collector (CPU/RAM/disk/Docker) + systemd timer |
| `scripts/build-security-summary.py` | Trivy JSON → `security.json` |
| `scripts/write-pipeline-status.py` | Actions API → `pipeline.json` |
| `tests/test_dashboard.py` | 33 tests for the page, payload, fallbacks and security |
| `docs/DASHBOARD.md` | This document |

**Modified**

| Path | Change |
|---|---|
| `app/routes.py` | `/` renders the template; added `/api/dashboard`, `/api/logs`; **`/health` untouched** |
| `docker-compose.prod.yml` | Two read-only bind mounts + `HOST_STATE_DIR` / `HOST_LOG_DIR` |
| `scripts/deploy.sh` | Records every deployment (success/failure/rollback) into `deployments.json` |
| `scripts/rollback.sh` | Records rollbacks as distinct events |
| `scripts/setup-server.sh` | gid-10001 group ownership + collector installation (step 9) |
| `.github/workflows/ci.yml` | Trivy JSON report; new stage 10 publishing the snapshots |
| `nginx/conf.d/app.conf` | CSP, `/static/` caching, header de-duplication |
| `nginx/templates/app-https.conf.template` | Same, for the HTTPS vhost |
| `tests/test_routes.py` | `/` now asserted to be the HTML dashboard |
| `README.md` | Dashboard section, endpoint table, test count |

**Deliberately NOT changed:** the `Dockerfile`, `requirements.txt` (no new
dependency), `.env.example` secrets, the GHCR/Trivy/AWS/SSL logic, and the
`/health` response contract.

---

## 6. Verification

```bash
# 1. Routes
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" http://localhost/         # 200 text/html
curl -s http://localhost/health | python3 -m json.tool                             # unchanged JSON
curl -s http://localhost/api/dashboard | python3 -m json.tool | head -40

# 2. Collector
sudo /opt/devops-cicd/deploy/scripts/collect-metrics.sh
python3 -m json.tool /opt/devops-cicd/state/metrics.json

# 3. Tests
pytest tests/test_dashboard.py -v
pytest -q                              # 78 passed

# 4. Quality gates (the same ones CI runs)
ruff check . && black --check . && shellcheck -S style scripts/*.sh
```

Screenshots live in `docs/images/` — see the [screenshot checklist](../README.md#18-screenshots).
