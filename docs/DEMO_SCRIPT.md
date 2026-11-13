# 🎤 Interview Demo Script

> A **10-minute** live demo that proves you built this. Rehearse it until you
> can do it without thinking — the difference between "I made a project" and
> "I can explain and demo every moving part" is the whole interview.
>
> * [Before the call (5 min)](#before-the-call-5-min)
> * [The 10-minute demo](#the-10-minute-demo)
> * [The 4 questions that always come up](#the-4-questions-that-always-come-up)
> * [The rollback drill (your money shot)](#the-rollback-drill-your-money-shot)
> * [If something breaks](#if-something-breaks)

---

## Before the call (5 min)

| # | Task | Why |
|---|---|---|
| 1 | Open the repo in a browser tab | First thing they look at |
| 2 | Open the **Actions** tab with a green run loaded | Your "evidence" |
| 3 | Open a terminal in the project folder | You will run commands live |
| 4 | Start the app: `./scripts/resume-preview.sh` | Have the live URL ready |
| 5 | Note the **live URL** on a sticky note | If they ask "show me" |
| 6 | Have the EC2 SSH command ready | `ssh -i ~/.ssh/ec2_deploy deployer@<IP>` |

**Bans:** don't start with a blank terminal and type slowly. Don't apologise
for the project. Don't say "AI se banaya" — say what you *built* and *why*.

---

## The 10-minute demo

### 0:00 — The 30-second story

> "This is a Flask + PostgreSQL web app with a complete CI/CD pipeline. I push
> to `main` and GitHub Actions lints, tests, builds a Docker image, scans it
> for vulnerabilities, pushes it to GHCR, deploys it to an AWS EC2 server over
> SSH, and then **verifies the deployment with a health check**. If the new
> version isn't healthy, it **automatically rolls back** to the previous
> version. The whole thing takes about 4 minutes and I never touch the server."

Then show the architecture diagram in the README for 15 seconds. **Do not
read the README aloud.**

### 0:30 — The code (2 min)

Open `app/routes.py`. Talk about **one** endpoint, not all five:

> "Every request goes through a blueprint. Validation happens here, duplicate
> e-mails return `409`, database errors return `503` — and any unexpected
> exception is caught by a global handler that logs the traceback but never
> leaks it to the client."

Then show the test that proves it:

```bash
pytest tests/test_routes.py -v
```

> "84 tests cover every status code. The suite runs twice in CI — once on
> SQLite and once against a real PostgreSQL service container."

### 2:30 — The pipeline (3 min)

Open the Actions run. Walk the five jobs left to right:

| Job | One line |
|---|---|
| `1-3 Checkout, Lint & Test` | Ruff + Black + ShellCheck + Pytest |
| `4 Build Docker image` | Buildx, cached, tagged with the commit SHA |
| `5 Trivy security scan` | 0 Critical / 0 High, SARIF uploaded to Security |
| `6 Push to GHCR` | Uses the built-in `GITHUB_TOKEN` |
| `7-9 Deploy, Validate & Rollback` | SSH → compose → `/health` → rollback |

**The question to pre-empt:** *"Why tag with the SHA instead of `latest`?"*

> "Because `latest` is a moving target. With a SHA tag I can say exactly which
> commit is running in production, and a rollback is precise."

### 5:30 — The server (2 min)

SSH in:

```bash
ssh -i ~/.ssh/ec2_deploy deployer@<EC2_IP>
cd /opt/devops-cicd/deploy
docker compose -f docker-compose.prod.yml ps
cat /opt/devops-cicd/state/current-image
curl -s http://localhost/health
```

> "Three containers on a private Docker network. Only Nginx publishes ports —
> PostgreSQL has no published port and port 5432 isn't open in the security
> group. The state files are what make the rollback possible: `current-image`
> is what's live, `previous-image` is the safety net."

### 7:30 — The image size (1 min)

```bash
docker images devops-cicd-app
```

> "1170 MiB → 162 MiB. An 86 % reduction, because the multi-stage build keeps
> the compilers in the build stage and the runtime image is `python:3.12-slim`
> running as a non-root user with no pip and no build tools."

### 8:30 — The rollback drill (1.5 min) ⭐

**This is the differentiator.** See the next section.

---

## The rollback drill (your money shot)

Most candidates show a green pipeline. Almost none can show a **failed
deployment recovering automatically**. Do this and you are ahead of 95 % of
candidates.

### Setup (5 minutes before, on a branch — never on production traffic)

```bash
git checkout -b demo/rollback-drill
# Break the health check on purpose
python - <<'PY'
import pathlib
p = pathlib.Path("app/routes.py"); s = p.read_text()
s = s.replace(
  'db_ok, db_error = check_database_connection(\n        timeout=current_app.config.get("HEALTH_DB_TIMEOUT")\n    )',
  'db_ok, db_error = False, "simulated failure"  # DEMO')
p.write_text(s)
PY
git commit -am "demo: simulate an unhealthy release"
git push origin demo/rollback-drill
```

Merge it to `main` (or your staging branch) and let the pipeline run.

### What the interviewer sees

```
Stage 7  Deploy       → deploy.sh pulls sha-BAD, starts the container
Stage 8  Validate     → Attempt 1/10 failed - HTTP 503
                         Attempt 2/10 failed - HTTP 503
                         ...
Stage 9  Rollback     → Rollback SUCCESSFUL - sha-GOOD is serving traffic again
Final                 → the job still ends in FAILED
```

Then, on the server:

```bash
cat /opt/devops-cicd/state/current-image     # → the OLD (good) SHA tag
curl -s http://localhost/health               # → "status":"healthy"
```

### The line to say

> "The deployment is **not** considered successful until `/health` returns 200.
> When it didn't, the script restored the previous image and the pipeline
> still ended in failure — a rollback is a recovery, not a success. The old
> image is only ever deleted **after** a deployment passes its health check,
> so a rollback can never fail because the image was already gone."

---

## The 4 questions that always come up

### 1. "What if the database goes down?"

> "`/health` checks the database, not just the process. A running web server
> that can't reach PostgreSQL is not healthy — so it returns **503**, Docker
> marks the container unhealthy, and during a deployment the pipeline rolls
> back. The app itself keeps serving `/` and `/api/stats`."

### 2. "How do you keep secrets safe?"

> "Nothing is ever committed. Production secrets live on the EC2 server in
> `secrets.env` with mode `0600`, generated by the setup script. The GitHub
> Actions secrets are injected as environment variables and masked in the
> logs. The GHCR token is piped over SSH with `--password-stdin` and the
> remote Docker config is deleted right after. The database password is
> URL-encoded when the DSN is assembled, so a password with `@` or `/` can't
> break it."

### 3. "Why Flask and not FastAPI/Django?"

> "Flask keeps the app small enough that all the interesting engineering is in
> the pipeline, not the framework. The architecture is the same either way —
> a factory pattern with blueprints, an ORM layer and an env-driven config.
> The health endpoint, the container and the deployment logic don't care what
> the framework is."

### 4. "What would you do differently at scale?"

> "Right now `docker compose up -d` restarts containers in place. At scale I'd
> move to a blue/green or canary rollout with a load balancer, replace
> `create_all()` with Alembic migrations, add Prometheus and Grafana for
> metrics, and manage the infrastructure with Terraform instead of the console.
> The pipeline shape stays the same — the gates don't change, only the
> execution environment."

---

## If something breaks

| Situation | What to do |
|---|---|
| The demo URL is down | Say so calmly and fall back to the screenshots. "The tunnel is a demo convenience — here's the recorded version." Honesty beats faking. |
| The EC2 instance stopped (AWS billing) | Start it: `aws ec2 start-instances --instance-ids i-…` (or the console). Wait 1 minute. |
| The Actions run is red | That's actually useful: *"This run is red because I deliberately broke the health check for the rollback drill — let me show you the previous green one."* |
| You don't know an answer | *"I haven't built that part yet, but here's how I'd approach it…"* — then explain your reasoning. Interviewers assess how you think. |

---

## One-line closing

> "The point of the project wasn't the Flask app — it was proving I can build
> a pipeline that is **secure, verifiable and recoverable**, and that I
> understand every step of it."
