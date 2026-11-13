# devops-cicd-app — End-to-End CI/CD Pipeline for a Containerised Web Application

[![CI/CD Pipeline](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions-2088FF?logo=githubactions)](https://github.com/OWNER/REPO/actions/workflows/ci.yml)
[![Python 3.12](https://img.shields.io/badge/python-3.12-blue?logo=python)](https://www.python.org/)
[![Flask 3.1](https://img.shields.io/badge/flask-3.1-000000?logo=flask)](https://flask.palletsprojects.com/)
[![Docker](https://img.shields.io/badge/docker-multi--stage-2496ED?logo=docker)](https://www.docker.com/)
[![Trivy](https://img.shields.io/badge/security-trivy-214C4C?logo=aqua)](https://trivy.dev/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

> A production-style DevOps portfolio project: a Flask + PostgreSQL web application
> that is **linted, tested, containerised, security-scanned, published and deployed
> automatically** to an AWS EC2 instance — with **health-checked, automatic rollback**.
>
> Push to `main` → the pipeline does the rest. **Zero manual server-side steps.**

### 🌐 Live demo

A public URL for this exact app (temporary Cloudflare quick tunnel — the
permanent one will be your own domain):

| Path | What you get |
|---|---|
| **https://patio-excess-telescope-indicated.trycloudflare.com/** | 📊 **DevOps monitoring dashboard** (HTML) |
| **https://patio-excess-telescope-indicated.trycloudflare.com/health** | 🩺 Health probe (JSON, unchanged) |

```json
{"application":"devops-cicd-app","checks":{"database":{"latency_ms":0.52,"status":"up"}},
 "environment":"production","status":"healthy","timestamp":"...","version":"1.0.0"}
```

> The quick-tunnel URL changes on every restart. For the permanent version,
> deploy to AWS EC2 + your own domain — see **[docs/GO_LIVE.md](docs/GO_LIVE.md)**.
> Prefer to do it by hand, one small step at a time? Use
> **[docs/DEPLOY_STEP_BY_STEP.md](docs/DEPLOY_STEP_BY_STEP.md)** — AWS console
> clicks, SSH commands, expected output and fixes for every step.

#### 📊 The dashboard

`GET /` serves a dark, Grafana/Datadog-style monitoring UI — health, database,
CI/CD pipeline, deployments, Docker containers, Trivy scans, host CPU/memory/disk
and logs — with a 30-second auto-refresh and a manual refresh button. It is
fully responsive and needs **no CDN, no build step and no external font**.

![DevOps monitoring dashboard — overview](docs/images/dashboard-overview.png)

Every number is real. Where a data source is not configured the panel says
**"Not configured"** / **"Unavailable"** — it never shows invented values.

| | |
|---|---|
| ![CI/CD pipeline panel](docs/images/dashboard-pipeline.png) | ![Deployment history](docs/images/dashboard-deployments.png) |
| **CI/CD Pipeline** — the real GitHub Actions run and every stage | **Deployments** — SHA tags, durations, rollback events |
| ![Security scans](docs/images/dashboard-security.png) | ![Server monitoring](docs/images/dashboard-server.png) |
| **Security Scans** — real Trivy CVE counts and policy verdict | **Server Monitoring** — live CPU / RAM / disk gauges |

| Mobile | Mobile navigation |
|---|---|
| ![Mobile dashboard](docs/images/dashboard-mobile.png) | ![Mobile sidebar](docs/images/dashboard-mobile-nav.png) |

See **[docs/DASHBOARD.md](docs/DASHBOARD.md)** for the full design.

---

## Table of contents

1. [Project overview](#1-project-overview)
2. [Architecture](#2-architecture)
3. [Technology stack](#3-technology-stack)
4. [Project structure](#4-project-structure)
5. [Local setup](#5-local-setup)
6. [Docker setup](#6-docker-setup)
7. [GitHub Actions (the pipeline)](#7-github-actions-the-pipeline)
8. [GitHub Secrets](#8-github-secrets)
9. [GHCR setup](#9-ghcr-setup)
10. [AWS EC2 setup](#10-aws-ec2-setup)
11. [Nginx & SSL](#11-nginx--ssl)
12. [Deployment process](#12-deployment-process)
13. [Rollback process](#13-rollback-process)
14. [Testing](#14-testing)
15. [DevOps metrics](#15-devops-metrics)
16. [Image size: measured results](#16-image-size-measured-results)
17. [Troubleshooting](#17-troubleshooting)
18. [Screenshots](#18-screenshots)
19. [Future improvements](#19-future-improvements)
20. [Go-live guide](#20-go-live-guide)
21. [Interview demo script](#21-interview-demo-script)
22. [Monitoring dashboard](#22-monitoring-dashboard)

---

## 1. Project overview

**devops-cicd-app** is a small but *complete* web service used to demonstrate a
modern DevOps pipeline. It deliberately keeps the application simple so that all
the engineering effort sits where it belongs: in the **automation, security and
reliability** of the delivery pipeline.

### What it does

| Endpoint | Method | Purpose |
|---|---|---|
| `/` | GET | 📊 **DevOps monitoring dashboard** (HTML) |
| `/health` | GET | **Readiness probe** — checks PostgreSQL, returns `200` or `503` |
| `/api/users` | GET | Paginated list of users |
| `/api/users` | POST | Create a user (validation, duplicate detection) |
| `/api/stats` | GET | Application statistics (user count, uptime, DB status) |
| `/api/dashboard` | GET | Aggregated telemetry that powers the dashboard (JSON) |
| `/api/logs` | GET | Recent deployment/rollback logs from the host (JSON) |

> `/` used to return the JSON service banner. That payload now lives at
> `/api/stats` and inside `/api/dashboard`, so nothing that consumed the old
> response is broken — and `/health` is untouched, byte for byte.

### What the pipeline does

```
git push main
   └─▶ GitHub Actions
         1. Checkout + Python setup
         2. Lint        (Ruff + Black + ShellCheck)      ── fail fast on code quality
         3. Test        (Pytest × SQLite + PostgreSQL)    ── 78 tests, coverage report
         4. Build       (Docker Buildx, multi-stage)      ── tagged with the commit SHA
         5. Scan        (Trivy: CRITICAL/HIGH = fail)     ── SARIF uploaded to Security tab
         6. Push        (GHCR, using GITHUB_TOKEN)        ── ghcr.io/OWNER/devops-cicd-app:sha-abc123
         7. Deploy      (SSH → EC2 → docker compose up -d)── immutable SHA tag only
         8. Validate    (/health must return HTTP 200)    ── retried with backoff
         9. Rollback    (previous image restored)         ── runs automatically on failure
        10. Publish    (real pipeline + Trivy snapshots)  ── feeds the dashboard, read-only
```

---

## 2. Architecture

### 2.1 System architecture

```mermaid
graph TB
    subgraph "Developer workstation"
        DEV[Developer<br/>git push]
    end

    subgraph "GitHub"
        REPO[(GitHub Repository)]
        ACT[GitHub Actions Runner]
        GHCR[(GitHub Container Registry<br/>ghcr.io/OWNER/devops-cicd-app)]
        SEC[Code Scanning<br/>SARIF report]
    end

    subgraph "AWS EC2 - Ubuntu 24.04"
        subgraph "Host filesystem"
            DEP[/opt/devops-cicd/deploy<br/>compose + nginx + scripts]
            ST[(state/current-image<br/>state/previous-image)]
            LG[(logs/deploy-*.log)]
        end
        subgraph "Docker network: devops-cicd-net"
            NGINX[Nginx<br/>:80 :443<br/>TLS + reverse proxy]
            APP[Flask app<br/>Gunicorn :8000<br/>non-root user]
            DB[(PostgreSQL 16<br/>:5432 internal only)]
        end
        CERT[Certbot<br/>Let's Encrypt certs]
    end

    USER[End user / browser]

    DEV -->|git push main| REPO
    REPO -->|webhook| ACT
    ACT -->|1-3| REPO
    ACT -->|4 build| ACT
    ACT -->|5 scan| SEC
    ACT -->|6 push| GHCR
    ACT -->|7 SSH + rsync| DEP
    ACT -->|8 health check| NGINX
    ACT -->|9 rollback on failure| ST

    GHCR -.->|docker pull by SHA tag| APP
    DEP -->|docker compose up -d| APP
    DEP --> NGINX
    DEP --> DB
    ST <--> DEP
    DEP --> LG

    USER -->|HTTPS| NGINX
    NGINX -->|proxy_pass| APP
    APP -->|SQL| DB
    CERT -->|renew + reload| NGINX

    style ACT fill:#eef6ff,stroke:#2088ff
    style NGINX fill:#eefaf0,stroke:#22a06b
    style APP fill:#eefaf0,stroke:#22a06b
    style DB fill:#f5f5f5,stroke:#888
    style GHCR fill:#fff4e6,stroke:#e08c00
```

### 2.2 The deployment path in plain English

1. You push code to GitHub.
2. GitHub notices the push and starts a **runner** (a temporary Ubuntu VM).
3. The runner installs your dependencies and **checks your code**: any lint error
   or failing test stops everything *before* an image is ever built.
4. If the code is clean, the runner **builds a Docker image** and labels it with
   the commit SHA (`sha-abc123…`) — a unique, unchangeable name.
5. **Trivy** inspects every package inside the image. A Critical/High
   vulnerability stops the pipeline.
6. The image is **pushed to GHCR** (GitHub's private Docker registry).
7. The runner **SSHes into your EC2 server**, copies the Compose file and scripts
   over, and runs `deploy.sh`, which pulls the new image by its SHA tag and runs
   `docker compose up -d`.
8. The runner then **asks the application whether it is healthy** (`/health`).
   It retries for about a minute — containers need a few seconds to boot.
9. If the app never becomes healthy, **rollback.sh** restores the previous image
   automatically and the pipeline still ends in **failure** (a rollback is not a
   success).

### 2.3 Design decisions

| Decision | Why |
|---|---|
| Application factory (`create_app`) | Tests can build isolated instances with different config; no global state |
| Health endpoint checks the database | A process that is up but cannot reach PostgreSQL is **not** healthy — that is exactly what should trigger a rollback |
| Immutable `sha-<commit>` tags for deployment | `latest` is a moving target; you must always be able to say *exactly* which code is running |
| Previous image kept on disk | Rollback needs the old image to still exist — pruning happens only **after** a successful deployment |
| Secrets never in the repository | Production secrets live in `/opt/devops-cicd/deploy/secrets.env` (mode `0600`) on the server, generated by `setup-server.sh` |
| PostgreSQL has no published port | It is only reachable from the Docker network; the AWS security group also blocks 5432 |
| Gunicorn, not the Flask dev server | The dev server is single-threaded and explicitly not for production |

---

## 3. Technology stack

| Layer | Technology | Version | Purpose |
|---|---|---|---|
| Language | Python | 3.12 | Application runtime |
| Web framework | Flask | 3.1.0 | REST API |
| ORM | SQLAlchemy | 2.0.36 | Database access + models |
| ORM integration | Flask-SQLAlchemy | 3.1.1 | Session management per request |
| Database | PostgreSQL | 16-alpine | Persistent data store |
| DB driver | psycopg2-binary | 2.9.10 | PostgreSQL connector |
| WSGI server | Gunicorn | 23.0.0 | Production HTTP server |
| Tests | Pytest | 8.3.4 | Unit + integration tests |
| Coverage | pytest-cov | 6.0.0 | Coverage reporting |
| Linter | Ruff | 0.9.2 | Fast linting (pyflakes, isort, bugbear, bandit rules) |
| Formatter | Black | 24.10.0 | Consistent formatting |
| Shell lint | ShellCheck | (runner) | Validates the deployment scripts |
| Containers | Docker + Buildx | latest | Image build & cache |
| Orchestration | Docker Compose | v2 | Multi-container stack |
| Reverse proxy | Nginx | 1.27-alpine | TLS termination, proxying, security headers |
| TLS | Certbot + Let's Encrypt | latest | Free, automated certificates |
| CI/CD | GitHub Actions | — | Pipeline orchestration |
| Registry | GitHub Container Registry | — | Image storage |
| Security scan | Trivy | 0.28.0 | CVE + misconfiguration + secret scanning |
| Cloud | AWS EC2 (Ubuntu 24.04) | — | Production host |
| IaC/ops | Bash | — | Setup, deploy, rollback, health-check scripts |

---

## 4. Project structure

```
devops-cicd-project/
├── app/                          # Application package
│   ├── __init__.py               # Application factory, logging, error handlers, CLI
│   ├── config.py                 # Environment-driven configuration classes
│   ├── database.py               # SQLAlchemy engine/session + health probe
│   ├── models.py                 # ORM models (User)
│   ├── monitoring.py             # Dashboard data: host snapshots, pipeline, Trivy, logs
│   ├── routes.py                 # HTTP routes / blueprint
│   ├── templates/
│   │   └── dashboard.html        # DevOps monitoring dashboard (served at /)
│   └── static/
│       ├── css/dashboard.css     # Dark theme, responsive (no CDN)
│       └── js/dashboard.js       # Fetch + render + 30s auto-refresh + SVG charts
│
├── tests/                        # Pytest suite (84 tests)
│   ├── conftest.py               # Fixtures: app, client, sample_user
│   ├── test_routes.py            # Endpoint behaviour + status codes
│   ├── test_health.py            # Health endpoint contract
│   ├── test_dashboard.py         # Dashboard page, payload, fallbacks, container wiring
│   └── test_database.py          # Model, session and schema behaviour
│
├── nginx/                        # Reverse proxy configuration
│   ├── nginx.conf                # Main config (rate limiting, gzip, logging)
│   ├── conf.d/
│   │   └── app.conf              # Default HTTP vhost (works without a domain)
│   └── templates/
│       └── app-https.conf.template  # TLS vhost, rendered by setup-ssl.sh
│
├── scripts/                      # Automation (all ShellCheck-clean)
│   ├── go-public.sh              # One command: repair + start + public HTTPS tunnel
│   ├── resume-preview.sh         # Repair the local env + (re)start the app
│   ├── setup-server.sh           # EC2 bootstrap (Docker, user, dirs, firewall)
│   ├── deploy.sh                 # Deploy a SHA-tagged image + validate + auto-rollback
│   ├── rollback.sh               # Restore the previous known-good image
│   ├── health-check.sh           # Retrying /health validator
│   ├── setup-ssl.sh              # Let's Encrypt certificate + renewal timer
│   ├── collect-metrics.sh        # Host CPU/RAM/disk/Docker → state/metrics.json
│   ├── build-security-summary.py # Trivy JSON → state/security.json
│   ├── write-pipeline-status.py  # Actions API → state/pipeline.json
│   └── measure-image-size.sh     # Objective image-size comparison
│
├── tools/
│   └── measure_images.py         # Registry-based size measurement (no Docker needed)
│
├── .github/workflows/
│   └── ci.yml                    # The whole 9-stage pipeline
│
├── Dockerfile                    # Multi-stage production image
├── Dockerfile.unoptimized        # Baseline image (for the size comparison)
├── docker-compose.yml            # Development stack (app + db + nginx)
├── docker-compose.prod.yml       # Production stack (GHCR image, TLS, no build)
├── requirements.txt              # Pinned runtime dependencies
├── requirements-dev.txt          # Pinned development dependencies
├── pyproject.toml                # Ruff / Black configuration
├── pytest.ini                    # Pytest configuration & coverage settings
├── Makefile                      # Task shortcuts (make help)
├── .dockerignore                 # Keeps the build context small & secret-free
├── .gitignore                    # Keeps secrets & artefacts out of git
├── .env.example                  # Template for local environment variables
├── README.md
└── docs/
    ├── EXECUTION_GUIDE.md        # Step-by-step, command-by-command setup
    ├── ARCHITECTURE.md           # Deep dive into the design
    ├── TESTING_CHECKLIST.md      # 17-item manual verification checklist
    ├── FAILURE_SIMULATION.md     # 6 realistic failure drills
    ├── BRANCH_PROTECTION.md      # GitHub branch-protection walkthrough
    └── METRICS.md                # How to collect the real DevOps metrics
```

### Changes from the "suggested" structure (and why)

* **`wsgi.py` at the root** — Gunicorn needs a stable import target (`wsgi:app`).
* **`app/__init__.py` = application factory** instead of a flat module. This is
  the Flask recommended pattern and it is what makes the test-suite clean.
* **`pyproject.toml`** added — a single place for Ruff/Black configuration
  (instead of scattering it across `setup.cfg`/`tox.ini`).
* **`tools/measure_images.py`** added — lets the image-size numbers be verified
  even on a machine without Docker.
* **`docs/`** added — the README stays readable; deep guides live next to it.
* **`app/logging.py` was NOT split out** — the JSON formatter lives in
  `app/__init__.py` to avoid an import cycle with the app factory.

---

## 5. Local setup

### 5.1 Prerequisites

| Tool | Version | Install (Ubuntu/WSL) |
|---|---|---|
| Python | 3.12 | `sudo apt install python3.12 python3.12-venv` |
| Git | any | `sudo apt install git` |
| Docker | 24+ | see [docs/EXECUTION_GUIDE.md](docs/EXECUTION_GUIDE.md) |

### 5.2 Quick start (with Docker — recommended)

```bash
git clone https://github.com/OWNER/devops-cicd-project.git
cd devops-cicd-project
cp .env.example .env            # adjust POSTGRES_PASSWORD / SECRET_KEY
docker compose up -d --build    # starts app + postgres + nginx
curl http://localhost:8080/health
```

### 5.3 Quick start (without Docker — Python only)

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
cp .env.example .env && set -a && . ./.env && set +a

# A local PostgreSQL is optional for a quick smoke test - SQLite works too:
export DATABASE_URL="sqlite+pysqlite:////tmp/local.db"

flask --app wsgi init-db        # create the schema
flask --app wsgi seed-db        # optional demo data
python wsgi.py                  # http://127.0.0.1:8000
```

### 5.4 Everyday commands

```bash
make help          # list every target
make setup         # venv + dependencies
make lint          # ruff + black + shellcheck
make test          # pytest with coverage
make run           # run the app locally
make up / down     # docker compose stack
```

---

## 6. Docker setup

### 6.1 The multi-stage Dockerfile

```dockerfile
FROM python:3.12-slim AS builder          # Stage 1: build the dependencies
RUN python -m venv /opt/venv
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim AS runtime          # Stage 2: the shipped image
COPY --from=builder /opt/venv /opt/venv   # only the venv - no pip, no compilers
COPY app/ ./app/
COPY wsgi.py ./wsgi.py
RUN useradd --uid 10001 appuser           # non-root
USER appuser
HEALTHCHECK ... python -c "urllib..."
CMD ["gunicorn", "--bind", "0.0.0.0:8000", ...]
```

Why it is built this way:

* **Dependency layer is cached separately** — changing `app/routes.py` does not
  re-download Flask, so the build takes seconds instead of a minute.
* **The runtime image contains no build tools** — no `gcc`, no `pip`, no build
  cache. Fewer packages = fewer CVEs for Trivy to find.
* **Non-root user (`uid 10001`)** — a compromised process cannot write to the
  image or escalate to root.
* **No `curl` in the image** — the health check uses the Python standard
  library, removing one more package to patch.
* **`--preload` + tuned Gunicorn flags** — faster worker start, bounded memory,
  graceful shutdown.

### 6.2 Build and inspect

```bash
docker build -f Dockerfile -t devops-cicd-app:optimized .
docker images devops-cicd-app             # check the size
docker history devops-cicd-app:optimized  # inspect every layer
docker run --rm -p 8000:8000 devops-cicd-app:optimized
curl http://127.0.0.1:8000/health
```

### 6.3 Docker Compose (development)

```bash
docker compose up -d --build
docker compose ps             # all three services should be 'healthy'
docker compose logs -f app
docker compose down           # stop (the pgdata volume survives)
docker compose down -v        # stop AND delete the database
```

Services:

| Service | Image | Published port | Health check |
|---|---|---|---|
| `db` | `postgres:16-alpine` | **none** | `pg_isready` |
| `app` | built locally | **none** | `/health` via Python |
| `nginx` | `nginx:1.27-alpine` | `8080:80` | `nginx -t` |

> Only Nginx is reachable from the host. The application and the database are
> reachable **only** from inside the `devops-cicd-net` Docker network.

---

## 7. GitHub Actions (the pipeline)

The complete pipeline lives in **`.github/workflows/ci.yml`**.

```mermaid
graph LR
    J1["build-and-test<br/>checkout · lint · test"] --> J2["build-image<br/>buildx · cache"]
    J2 --> J3["security-scan<br/>trivy"]
    J3 --> J4["push-image<br/>GHCR"]
    J4 --> J5["deploy<br/>ssh · compose · health"]
    J5 -.->|on failure| J6["rollback<br/>restore previous"]
```

| Job | Stages | Runs on PRs | Runs on `main` |
|---|---|---|---|
| `build-and-test` | 1 Checkout, 2 Lint, 3 Test | ✅ | ✅ |
| `build-image` | 4 Build (Buildx + cache) | ✅ | ✅ |
| `security-scan` | 5 Trivy (image + filesystem) | ✅ | ✅ |
| `push-image` | 6 Push to GHCR | ❌ | ✅ |
| `deploy` | 7 Deploy, 8 Validate, 9 Rollback | ❌ | ✅ |

**Key details**

* **Concurrency** — `concurrency.group` prevents two deployments of the same
  branch from running at the same time. PR runs are cancelled automatically;
  `main` runs are never cancelled (that would interrupt a deployment).
* **Least privilege** — `contents: read` by default; `packages: write` is
  granted only to the job that pushes to GHCR.
* **PRs never deploy** — `push-image` and `deploy` are skipped for
  `pull_request` events.
* **GHA cache** — `cache-from/cache-to: type=gha` makes the second build
  almost instant.
* **Testing against real PostgreSQL** — a `postgres:16-alpine` service container
  runs the whole suite a second time with `TEST_DATABASE_URL` pointing at it,
  so the SQLAlchemy code is proven against the real engine, not just SQLite.

### Making a pull request

```bash
git checkout -b feature/add-pagination
git commit -am "Add pagination to /api/users"
git push origin feature/add-pagination
# Open a PR on GitHub -> the "1-3 | Checkout, Lint & Test" checks must pass
# before it can be merged (see docs/BRANCH_PROTECTION.md)
```

---

## 8. GitHub Secrets

Go to **Settings → Secrets and variables → Actions → New repository secret**.

| Secret | Example | How to create it |
|---|---|---|
| `EC2_HOST` | `203.0.113.25` | The **public IPv4** of the EC2 instance (EC2 console) |
| `EC2_USER` | `deployer` | The Linux user you created (e.g. `deployer`) |
| `EC2_SSH_PRIVATE_KEY` | `-----BEGIN OPENSSH PRIVATE KEY----- …` | `cat ~/.ssh/id_ed25519` — the **private** key, without a trailing newline issue |
| `GHCR_USERNAME` | `your-github-username` | Your GitHub login (the owner of the image) |
| `GHCR_TOKEN` | `ghp_…` | A **fine-grained PAT** with `read:packages` only (see §9) |
| `APP_DOMAIN` | `app.example.com` | The domain whose DNS A record points to the EC2 IP |
| `PRODUCTION_ENV` | `production` | Environment marker written into the deployment env file |
| `EC2_SSH_KNOWN_HOSTS` *(optional)* | `ec2-203-0-113-25 ssh-ed25519 AAAA…` | The host key from the EC2 console — **strongly recommended** |

### Detailed creation instructions

**`EC2_SSH_PRIVATE_KEY`**

```bash
# 1. Create a dedicated key pair (never reuse your personal key)
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/ec2_deploy -N ""

# 2. Authorise the PUBLIC key on the server
ssh-copy-id -i ~/.ssh/ec2_deploy.pub deployer@203.0.113.25

# 3. Copy the PRIVATE key into the GitHub secret
cat ~/.ssh/ec2_deploy
# Select all of it (including BEGIN/END lines) -> paste into the secret
```

**`GHCR_TOKEN`** — create at
*GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens*:

| Setting | Value |
|---|---|
| Token name | `gcr-push-server` |
| Expiration | 90 days |
| Repository access | *Only select repositories* → your repo |
| Permissions → **Packages** | **Read-only** |
| Permissions → **Metadata** | Read-only (automatic) |

> The CI pipeline pushes to GHCR with the built-in `GITHUB_TOKEN` (no personal
> token needed). `GHCR_TOKEN` is only used by the **server** to *pull* the
> image — that is why read-only is enough.

### Security rules this project follows

* `.env`, `secrets.env`, `*.pem`, `*.key` are in `.gitignore` **and**
  `.dockerignore` → they can never be committed *or* baked into an image.
* Secrets are passed to steps through `env:` (GitHub masks them in logs), never
  echoed with `set -x`.
* The GHCR token is piped over SSH with `--password-stdin` and the remote
  Docker config is deleted immediately afterwards.
* The pipeline uses **least privilege** (`contents: read` by default).
* SSH key-based authentication only — password login is disabled on the host.
* The EC2 security group allows only **22, 80, 443**; PostgreSQL (5432) is not
  open, and neither is the Flask container (8000).

---

## 9. GHCR setup

1. The repository must be **public** *or* the EC2 user must have access to the
   package.
2. Push the image manually once to make the package visible:

   ```bash
   echo "$CR_PAT" | docker login ghcr.io -u YOUR_USERNAME --password-stdin
   docker tag devops-cicd-app:optimized ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-local
   docker push ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-local
   ```

3. On the EC2 server, log in with the read-only token:

   ```bash
   echo "$GHCR_TOKEN" | docker login ghcr.io -u YOUR_USERNAME --password-stdin
   docker pull ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-local
   ```

4. The CI pipeline does both of these automatically.

---

## 10. AWS EC2 setup

### 10.1 Launch the instance

| Setting | Value |
|---|---|
| AMI | Ubuntu Server 24.04 LTS (`ubuntu-24.04`) |
| Instance type | `t3.micro` (free tier) or `t3.small` |
| Storage | 20 GB gp3 |
| Key pair | your `ec2_deploy` key |
| Security group | see below |

**Security group inbound rules**

| Type | Port | Source | Purpose |
|---|---|---|---|
| SSH | 22 | Your IP (e.g. `203.0.113.0/24`) — *or* `0.0.0.0/0` with key-only auth | Deployment |
| HTTP | 80 | `0.0.0.0/0` | Traffic + ACME challenge |
| HTTPS | 443 | `0.0.0.0/0` | Traffic |
| — | 5432 | **not added** | PostgreSQL stays private |

> Restrict port 22 to your own IP where possible. The script below also
> configures UFW on the host itself (defence in depth).

### 10.2 Bootstrap the server

```bash
# From your workstation
scp -i ~/.ssh/ec2_deploy scripts/setup-server.sh deployer@203.0.113.25:/tmp/
ssh -i ~/.ssh/ec2_deploy deployer@203.0.113.25 'sudo bash /tmp/setup-server.sh'
```

The script is **idempotent** — running it twice is safe. It:

1. updates the system and installs base packages (`curl`, `ufw`, `fail2ban`, …)
2. installs Docker Engine + the Compose plugin from Docker's official APT repo
3. creates the `deployer` user and adds it to the `docker` group
4. creates `/opt/devops-cicd/{deploy,state,logs,backups}`
5. **generates the production secrets** (`POSTGRES_PASSWORD`, `SECRET_KEY`) into
   `secrets.env` with mode `0600`
6. hardens the Docker daemon (log rotation, `live-restore`)
7. configures UFW: deny incoming, allow 22/80/443
8. installs log rotation for the deployment logs

### 10.3 Directory layout on the server

```
/opt/devops-cicd/
├── deploy/            # synced by CI: compose file, nginx/, scripts/
│   ├── docker-compose.prod.yml
│   ├── nginx/
│   ├── scripts/
│   ├── .env           # APP_IMAGE + APP_TAG (written by deploy.sh)
│   └── secrets.env    # POSTGRES_PASSWORD + SECRET_KEY  (mode 0600, never in git)
├── state/
│   ├── current-image  # ghcr.io/OWNER/devops-cicd-app:sha-current
│   └── previous-image # ghcr.io/OWNER/devops-cicd-app:sha-previous
├── logs/
│   └── deploy-20261111-170000.log
└── backups/
```

---

## 11. Nginx & SSL

### 11.1 Reverse proxy

`nginx/nginx.conf` (main) + `nginx/conf.d/app.conf` (default HTTP vhost).

* `proxy_pass http://devops_cicd_app;` → the `app` service on the Docker network
* `proxy_set_header` forwards `Host`, `X-Real-IP`, `X-Forwarded-For`,
  `X-Forwarded-Proto`, `X-Request-ID`
* timeouts: connect `10s`, read/send `30s`
* `limit_req_zone` is defined **in the `http` context** (it is invalid inside a
  `server` block) — `20r/s` per IP with a burst of 40
* gzip compression for JSON/text
* `server_tokens off` hides the Nginx version
* security headers: `X-Frame-Options`, `X-Content-Type-Options`,
  `Referrer-Policy`, `X-XSS-Protection` (+ HSTS/CSP once TLS is enabled)

### 11.2 TLS with Let's Encrypt

**Prerequisite:** an **A record** for your domain pointing to the EC2 public IP.

```bash
# On the EC2 server
sudo bash /opt/devops-cicd/deploy/scripts/setup-ssl.sh app.example.com
```

The script:

1. verifies that the domain resolves to this server's public IP,
2. requests the certificate via the HTTP-01 challenge (Certbot, webroot mode),
3. renders `nginx/templates/app-https.conf.template` with `envsubst` into
   `nginx/conf.d/app-https.conf` and disables the plain-HTTP vhost,
4. validates (`nginx -t`) and reloads Nginx,
5. installs a `systemd` timer that renews twice a day.

```bash
# Verify
curl -I https://app.example.com/health
docker compose -f docker-compose.prod.yml run --rm --entrypoint "certbot renew --dry-run" certbot
systemctl list-timers certbot-renew.timer
```

> **Nginx does not expand `${APP_DOMAIN}` by itself.** That is why the TLS vhost
> is a *template* rendered by `envsubst` on the host — a detail that trips up a
> lot of beginners.

### 11.3 No domain yet? Test over plain HTTP

You do not need a domain to try everything out:

```bash
# Keep the default HTTP vhost, then:
curl http://<EC2-PUBLIC-IP>/health
```

For a named host on your own machine, add a hosts-file entry:

```
203.0.113.25  app.local
```

```bash
curl -H "Host: app.local" http://203.0.113.25/health
```

---

## 12. Deployment process

### What happens on `git push main`

```
1.  GitHub Actions starts
2.  Lint  →  Test  →  Build  →  Trivy  →  Push to GHCR
3.  SSH into EC2
4.  docker login ghcr.io (read-only token, piped over SSH)
5.  rsync docker-compose.prod.yml, nginx/, scripts/ to /opt/devops-cicd/deploy
6.  ./scripts/deploy.sh --image ghcr.io/OWNER/devops-cicd-app --tag sha-abc123
        ├── save current image  -> state/previous-image
        ├── write .env (APP_IMAGE + APP_TAG)
        ├── docker compose pull app
        ├── docker compose up -d --remove-orphans
        ├── flask init-db          (idempotent schema creation)
        ├── health-check.sh        (10 attempts, 6 s apart)
        └── on failure -> rollback.sh
7.  Validate from the runner:  curl https://APP_DOMAIN/health   (HTTP 200)
8.  Verify the running image tag matches the deployed SHA tag
9.  Only now: prune old images (keeping the current + previous + N recent)
```

### Verifying a deployment

```bash
ssh deployer@203.0.113.25
cd /opt/devops-cicd/deploy
docker compose -f docker-compose.prod.yml ps        # all healthy?
cat state/current-image                              # the deployed SHA tag
docker inspect -f '{{.Config.Image}}' devops-cicd-app
curl -s http://localhost/health | jq
tail -50 /opt/devops-cicd/logs/deploy-*.log
```

---

## 13. Rollback process

### The mechanism

| File | Meaning |
|---|---|
| `state/current-image` | The image that is running **now** |
| `state/previous-image` | The last image that was verified healthy |

`deploy.sh` copies `current-image` → `previous-image` **before** touching
anything, then deploys the new image. If the health check fails, it calls
`rollback.sh`, which:

1. reads `state/previous-image` (exit `2` if there is nothing to roll back to),
2. rewrites `.env` with the old tag,
3. `docker compose pull app && docker compose up -d`,
4. runs the health check again,
5. **on success**: makes the restored image the new `current-image`, clears
   `previous-image`, keeps the failed image on disk for debugging, exits `0`;
6. **on failure**: exits `1` — the pipeline stays red and a human is needed.

> Old images are pruned **only after** a successful deployment, and the
> previous tag is explicitly excluded from pruning. Rollback can never fail
> because the image was deleted too early.

### Worked example

```
Before:  current-image = ghcr.io/o/app:sha-aaa111
         previous-image = ghcr.io/o/app:sha-zzz999

Push sha-bbb222
  → previous-image := ghcr.io/o/app:sha-aaa111     (aaa111 is now the safety net)
  → deploy sha-bbb222
  → /health returns 503 (e.g. the new code broke the DB query)
  → rollback.sh: deploys sha-aaa111 again
  → /health returns 200
  → current-image := ghcr.io/o/app:sha-aaa111
  → previous-image := (empty)
  → the CI job still ends in FAILURE (a rollback is not a success)
```

### Testing the rollback safely

```bash
# On the server - deploy the previous image manually
cd /opt/devops-cicd/deploy
./scripts/rollback.sh
echo "exit code: $?"
```

Or end-to-end from a branch (see
[docs/FAILURE_SIMULATION.md](docs/FAILURE_SIMULATION.md#scenario-5)).

---

## 14. Testing

```bash
make test                    # local
pytest -v                    # verbose
pytest --cov=app --cov-report=html   # HTML coverage in htmlcov/index.html
```

### What is covered

| File | Focus |
|---|---|
| `tests/test_routes.py` | Every endpoint, every status code (200/201/400/409/415/404/405/503) |
| `tests/test_health.py` | The health contract — including the database-down path |
| `tests/test_database.py` | Model constraints, session rollback, schema creation, CLI commands |
| `tests/test_dashboard.py` | Dashboard page, payload shape, "no fake data" fallbacks, secrets never leak, container/Nginx wiring |

**Current result: 84 tests passing, 88 % statement coverage.**

### Running the suite against real PostgreSQL

```bash
docker compose up -d db
export TEST_DATABASE_URL="postgresql+psycopg2://appuser:devpassword@localhost:5432/devops_cicd"
pytest -v
```

---

## 15. DevOps metrics

See **[docs/METRICS.md](docs/METRICS.md)** for the full table, the exact
commands to collect every number, and the placeholders to fill in. The
repository ships `reports/image-size-model.json` with the measured image sizes.

| Metric | Where it comes from |
|---|---|
| Image size (before/after) | `docker images` / `scripts/measure-image-size.sh` |
| CI duration | Actions tab → job durations |
| Build time | `docker buildx build ... --progress=plain` |
| Deployment time | `deploy-*.log` timestamps |
| Health-check latency | `curl -w '%{time_total}'` |
| Tests passed | `pytest` summary / `reports/junit.xml` |
| Vulnerabilities | Trivy SARIF (`trivy-image.sarif`) |
| Rollback time | `rollback-*.log` timestamps |

---

## 16. Image size: measured results

> These numbers were **measured**, not estimated. The base-image sizes come
> from the Docker Hub registry API (compressed download size **and** the
> uncompressed size obtained by decompressing every layer blob); the
> dependency footprint comes from building the real virtualenv from
> `requirements.txt`. Reproduce with `python3 tools/measure_images.py` or
> `make measure-images` (the latter needs Docker and gives the authoritative
> number).

| Component | Compressed | Uncompressed |
|---|---|---|
| `python:3.12` (naive base) | 392.8 MiB | 1081.3 MiB |
| `python:3.12-slim` (optimised base) | 41.3 MiB | 117.8 MiB |
| `python:3.12-alpine` (alternative) | 17.2 MiB | 48.8 MiB |
| Dependencies (`site-packages`) | — | 44.4 MiB |

| Build | Predicted size | Notes |
|---|---|---|
| **Unoptimised** (`Dockerfile.unoptimized`) | **≈ 1170 MiB** | full `python:3.12`, pip cache kept, whole context copied |
| **Optimised** (multi-stage `Dockerfile`) | **≈ 162 MiB** | `python:3.12-slim` + venv + source, non-root, no build tools |

### Reduction: **86.1 %** (≈ 1008 MiB saved)

### What actually drives the size

1. **The base image (by far the biggest factor).** `python:3.12` ships
   `build-essential`, `gcc`, `git`, `curl` and a full Debian layer set
   (1081 MiB uncompressed). `python:3.12-slim` is 117.8 MiB. That single
   choice accounts for ~90 % of the difference.
2. **The pip cache.** `pip install` without `--no-cache-dir` keeps a second
   copy of every wheel in `~/.cache/pip` — the naive build stores it, the
   optimised one does not.
3. **Build tools.** The builder stage installs dependencies and throws the
   tools away; the runtime stage never sees `gcc`.
4. **The application payload (44.4 MiB)** — dominated by `psycopg2-binary`
   (bundles its own libpq) and SQLAlchemy. Switching to the system
   `psycopg2` package (which needs `libpq-dev` at build time only) can save
   another ~8 MiB.
5. **The source tree.** With a correct `.dockerignore` only `app/` and
   `wsgi.py` are copied (~0.05 MiB). Without it, `tests/`, `.git/` and
   `htmlcov/` would be shipped too.
6. **`.pyc` files** are pre-compiled in the builder stage (`compileall`), which
   makes the cold start faster without adding a compiler to the runtime image.

> **Verify on your machine:**
> `make measure-images` → prints the real sizes of both builds and the
> reduction percentage, and writes `reports/image-size-report.txt`.

---

## 17. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Permission denied (publickey)` | Wrong SSH key / user | `ssh -i ~/.ssh/ec2_deploy deployer@EC2_IP`; re-add the public key |
| `docker: permission denied` | User not in the `docker` group | `sudo usermod -aG docker $USER && newgrp docker` (or re-login) |
| `Error response from daemon: denied` (GHCR) | Not logged in / wrong token | `echo "$TOKEN" \| docker login ghcr.io -u USER --password-stdin` |
| `manifest unknown` | The tag does not exist | The image was never pushed — check the Actions run |
| Deployment rolls back immediately | `/health` returns 503 | `docker compose logs app` — usually a database problem |
| `/health` returns 503 `database_unavailable` | PostgreSQL is down or the DSN is wrong | `docker compose ps db`; check `POSTGRES_PASSWORD` in `secrets.env` |
| `relation "users" does not exist` | The schema was never created | `docker compose exec app flask --app wsgi init-db` |
| Nginx returns 502 | The `app` container is not healthy | `docker compose ps`; `docker compose logs app` |
| `nginx: [emerg] cannot load certificate` | The domain has no certificate yet | Use the plain-HTTP vhost, or run `setup-ssl.sh` |
| The pipeline is stuck on "Pending" | A concurrency group is already running | Cancel the older run (the group is per-branch) |
| Trivy fails the build | A real CVE in a base image | `trivy image --severity HIGH,CRITICAL <image>` locally; update the base image or add an exception with a documented expiry |
| `no space left on device` | Docker filled the disk | `docker system df`; `docker image prune -a`; check the log rotation settings |

### Useful commands

```bash
# What is running right now?
docker compose -f docker-compose.prod.yml ps
docker inspect -f '{{.Config.Image}}' devops-cicd-app
cat /opt/devops-cicd/state/current-image

# Logs
docker compose -f docker-compose.prod.yml logs --tail=200 app
tail -f /opt/devops-cicd/logs/deploy-*.log

# Shell into a container
docker compose -f docker-compose.prod.yml exec app /bin/bash
docker compose -f docker-compose.prod.yml exec app flask --app wsgi shell

# Clean up
docker system prune -a --volumes      # careful: deletes the database volume
```

---

## 18. Screenshots

> Replace these placeholders with your own screenshots — recruiters *do* look at
> them, and they make the project far more convincing.

### Already captured (real screenshots, in this repo)

| File | What it shows |
|---|---|
| `docs/images/dashboard-overview.png` | The dashboard landing view with live data |
| `docs/images/dashboard-pipeline.png` | The GitHub Actions run and every pipeline stage |
| `docs/images/dashboard-deployments.png` | Deployment history including a rollback event |
| `docs/images/dashboard-security.png` | Trivy severity counts, policy verdict, CVE table |
| `docs/images/dashboard-server.png` | CPU / memory / disk gauges from the host |
| `docs/images/dashboard-logs.png` | The colour-coded deployment log tail |
| `docs/images/dashboard-mobile.png` | The responsive layout at 390 px |
| `docs/images/dashboard-mobile-nav.png` | The slide-in navigation drawer |

### Still to capture on your own AWS account

| # | What to capture | Where |
|---|---|---|
| 1 | The GitHub Actions run showing all 9+1 stages green | `docs/images/actions-success.png` |
| 2 | The Trivy scan summary (0 Critical / 0 High) | `docs/images/trivy-report.png` |
| 3 | `docker images` comparing both builds | `docs/images/image-sizes.png` |
| 4 | `curl https://app.example.com/health` returning `"status": "healthy"` | `docs/images/health.png` |
| 5 | The EC2 server terminal running `docker compose ps` | `docs/images/ec2-ps.png` |
| 6 | The rollback log showing the previous image restored | `docs/images/rollback.png` |
| 7 | The GitHub branch-protection settings | `docs/images/branch-protection.png` |
| 8 | The pytest coverage report in a browser | `docs/images/coverage.png` |
| 9 | The dashboard **after** a real EC2 deployment (real containers + CPU) | `docs/images/dashboard-live-ec2.png` |

---

## 19. Future improvements

| Idea | Why it is worth doing |
|---|---|
| **Alembic migrations** | Replace `create_all()` with versioned, reversible migrations |
| **Blue/green or canary deploys** | Zero-downtime releases with a traffic switch |
| **Terraform for the EC2 instance** | Infrastructure as code — the whole stack reproducible from a single `terraform apply` |
| **Prometheus + Grafana** | Real dashboards for latency, error rate and saturation |
| **OpenTelemetry / distributed tracing** | Follow a request across Nginx, Gunicorn and PostgreSQL |
| **ELK / Loki for log aggregation** | Search the JSON logs of every container |
| **Dependabot + Renovate** | Automatic dependency updates — a great CV line |
| **Snyk / Grype in addition to Trivy** | Two scanners catch more than one |
| **GitOps with ArgoCD** | Kubernetes manifests reconciled continuously instead of pushed by a pipeline |
| **SonarQube / SonarCloud** | Code-quality gates and a public "quality badge" |
| **API documentation (OpenAPI/Swagger)** | Auto-generated from the route decorators |
| **K6 performance tests** | Load testing as part of the pipeline |
| **Signed images (cosign) + SBOM** | Supply-chain security: `cosign sign` + SLSA provenance |
| **PostgreSQL backups to S3** | Automated `pg_dump` + rotation |
| **Multi-AZ deployment** | Two EC2 instances behind an Application Load Balancer |

---

## 20. Go-live guide

**[`docs/DEPLOY_STEP_BY_STEP.md`](docs/DEPLOY_STEP_BY_STEP.md)** — the same
journey as a hand-held, phase-by-phase manual (AWS console → EC2 → Elastic IP →
Docker → first deploy → CI/CD → domain), no one-command shortcuts.

**[`docs/GO_LIVE.md`](docs/GO_LIVE.md)** — how to take this from your laptop to
a real, running, public deployment:

| Level | Time | Cost | What you get |
|---|---|---|---|
| **1 — Instant public URL** | 2 min | ₹0 | A live HTTPS URL right now (Cloudflare quick tunnel) |
| **2 — Real AWS EC2** | 1–2 h | ₹0 (Free Tier, 12 months) | The full pipeline running against a real server |
| **3 — Domain + HTTPS** | 1 day | ~₹800/yr | `https://app.yourdomain.com` with a Let's Encrypt certificate |

It also covers the cost-reality table, billing alarms (so a forgotten instance
cannot surprise you) and the checklist for making the repository itself look
credible to a recruiter.

---

## 21. Interview demo script

**[`docs/DEMO_SCRIPT.md`](docs/DEMO_SCRIPT.md)** — a rehearsed 10-minute demo:

| Minute | Segment |
|---|---|
| 0:00 | The 30-second story + architecture diagram |
| 0:30 | One endpoint in `app/routes.py` + its test |
| 2:30 | The 5 pipeline jobs, one line each |
| 5:30 | SSH into EC2: `docker compose ps`, the state files, `/health` |
| 7:30 | The image-size comparison (1170 MiB → 162 MiB) |
| 8:30 | ⭐ **The rollback drill** — the part almost nobody can demo |

It also lists the four questions that always come up (database down, secret
handling, framework choice, scaling) with prepared answers, and what to do when
something breaks mid-demo.

---

## 22. Monitoring dashboard

`GET /` serves a dark, Grafana/Datadog-style DevOps dashboard. Full design
notes: **[`docs/DASHBOARD.md`](docs/DASHBOARD.md)**.

| Sidebar section | Data shown | Real source |
|---|---|---|
| **Overview** | 6 metric cards | live probe + host snapshots |
| **Application Health** | `/health` contract + raw JSON | live `SELECT 1` |
| **Server Monitoring** | CPU / Memory / Disk gauges | `/proc/stat`, `/proc/meminfo`, `df` |
| **CI/CD Pipeline** | last Actions run + per-stage chips | GitHub Actions REST API |
| **Deployments** | current release, duration chart, history | `state/deployments.json` |
| **Docker Monitoring** | per-container state and health | `docker ps -a` |
| **Security Scans** | Trivy C/H/M/L + CVE table | real Trivy JSON report |
| **Logs** | colour-coded deploy/rollback tail | `logs/*.log` |

**How it stays honest and safe**

- **No fake numbers.** A missing source renders **"Not configured"**; a stale
  snapshot renders **"Stale (331s old)"**. Never a placeholder value.
- **No privileged container.** The app has no Docker socket and no shell. A host
  collector writes JSON; the container mounts `state/` and `logs/` **read-only**
  as uid 10001.
- **No CDN.** Charts are hand-drawn SVG; the page works on an air-gapped server.
- **CSP enforced.** `default-src 'self'` via Nginx (both HTTP and HTTPS vhosts),
  verified in a real browser with zero console errors.
- **30-second auto-refresh** plus a manual refresh button; responsive down to 390 px.

**Enable the panels**

```bash
# host metrics (CPU/RAM/disk/Docker) - one-shot then every minute
sudo /opt/devops-cicd/deploy/scripts/collect-metrics.sh --install
sudo systemctl status devops-metrics.timer

# pipeline + Trivy panels populate automatically on the next deployment
```

---

## License

MIT — see [LICENSE](LICENSE).

## Author

*Your name here* — [GitHub](https://github.com/OWNER) · [LinkedIn](https://linkedin.com/in/OWNER)

> **Before you publish:** replace every `OWNER`, `REPO`, `your-domain.com` and
> `YOUR_USERNAME` placeholder in this README, in the workflow and in the
> compose files with your own values.
