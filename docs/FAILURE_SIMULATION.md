# 💥 Failure Simulation Drills

> Six realistic failure scenarios, how to reproduce each one **safely**, what
> the pipeline should do, how to diagnose it and how to recover.
>
> **Golden rule: never break production to test this.** Use a throwaway branch,
> a local Docker Compose stack, or the `test/` environment. The drills below
> are written so that a mistake cannot reach real users.

---

## Scenario 1 — A Python syntax error

**Expected result:** the *Lint* stage fails (and the *Test* stage would fail
too). **No image is ever built.**

### Reproduce safely (local — 20 seconds)

```bash
git checkout -b drill/syntax-error
echo "def broken(:" >> app/routes.py
ruff check .
```

**Expected output:**

```
app/routes.py:300:5: E999 SyntaxError: invalid syntax
Found 1 error.
```

```bash
git checkout app/routes.py      # undo
```

### Reproduce in CI

```bash
git checkout -b drill/syntax-error
echo "def broken(:" >> app/routes.py
git commit -am "drill: introduce a syntax error"
git push origin drill/syntax-error
```

### Expected pipeline behaviour

| Stage | Result |
|---|---|
| 1 Checkout | ✅ green |
| 2 **Lint (Ruff)** | ❌ **red** — `E999 SyntaxError` |
| 3 Test | ⛔ skipped (the job stops at the failed step) |
| 4 Build | ⛔ skipped |
| 5 Trivy | ⛔ skipped |
| 6 Push | ⛔ skipped |
| 7 Deploy | ⛔ skipped |

> **Nothing is pushed to GHCR and nothing is deployed.** This is exactly what
> you want: a broken commit can never reach production.

### Diagnose

```bash
# In the Actions UI: click the failing step → the annotation points at the line.
# Locally:
ruff check . --output-format=full
python -m py_compile app/routes.py
```

### Recover

```bash
git revert <commit>          # or
git checkout main && git reset --hard <last-good-sha> && git push --force-with-lease
```

---

## Scenario 2 — A failing unit test

**Expected result:** the *Test* stage fails. The pipeline stops **before** the
Docker image is built or pushed.

### Reproduce safely (local)

```bash
git checkout -b drill/failing-test
cat >> tests/test_routes.py <<'EOF'


def test_deliberately_failing():
    """Temporary drill - must fail."""
    assert 1 == 2, "This test is intentionally broken"
EOF
pytest -k deliberately_failing -v
```

**Expected output:**

```
tests/test_routes.py::test_deliberately_failing FAILED
E       assert 1 == 2
========================= 1 failed, 41 passed =========================
```

### Reproduce in CI

Push the branch and open a PR.

### Expected pipeline behaviour

| Stage | Result |
|---|---|
| 1 Checkout | ✅ |
| 2 Lint | ✅ (the test is syntactically fine) |
| 3 **Test (Pytest)** | ❌ **red** — `1 failed, 41 passed` |
| 4 Build | ⛔ skipped |
| 5-9 | ⛔ skipped |

The **JUnit XML** report is uploaded as an artifact
(`test-reports` → `reports/junit.xml`) and the coverage XML/HTML too.

### Diagnose

```bash
# The Actions UI shows the failing assertion inline.
# Locally:
pytest -x -vv --tb=long
# Download the artifact for the full report.
```

### Recover

Fix or revert the test. To skip a test temporarily use `@pytest.mark.skip`
(not `assert False` — a skipped test is visible, a broken one is not).

---

## Scenario 3 — An invalid Docker configuration

**Expected result:** the *Build* stage fails. The image is never pushed.

### Reproduce safely (local)

```bash
git checkout -b drill/bad-dockerfile
# Break the Dockerfile: FROM a tag that does not exist
sed -i 's|^FROM \${BASE_IMAGE} AS runtime|FROM python:3.12-does-not-exist AS runtime|' Dockerfile
docker build -f Dockerfile -t broken:1 .
```

**Expected output:**

```
ERROR: failed to solve: python:3.12-does-not-exist: failed to resolve source metadata for docker.io/library/python:3.12-does-not-exist: pull access denied
```

Other realistic ways to break it:

| Mistake | Symptom |
|---|---|
| `COPY requirements.txt` missing | `COPY failed: file not found in build context` |
| Typo in the package name | `ERROR: Could not find a version that satisfies the requirement flask==3.1.0` |
| `RUN` command that does not exist | `executor failed running [/bin/sh -c …]: not found` |
| Compose file with a bad YAML indent | `services.app.image must be a string` (from `docker compose config`) |

### Expected pipeline behaviour

| Stage | Result |
|---|---|
| 1-3 | ✅ green |
| 4 **Build** | ❌ **red** — buildx error |
| 5-9 | ⛔ skipped |

### Diagnose

```bash
docker build --progress=plain -f Dockerfile -t broken:1 .   # full log
docker compose config                                        # validates the compose files
```

### Recover

Revert the commit. Remember that the CI build uses the **cache** — after
fixing `requirements.txt` the cache is invalidated automatically; after fixing
only the source code it is reused (fast rebuild).

---

## Scenario 4 — A vulnerable dependency

**Expected result:** Trivy reports the vulnerability and **fails** the pipeline
according to the configured policy.

### Reproduce safely (on a branch — NEVER on `main`)

```bash
git checkout -b drill/vulnerable-dep
pip download flask==2.0.0 --no-deps -d /tmp/x   # just to look at old versions
# Add a known-old dependency to requirements.txt:
echo "Flask==2.0.0" >> requirements.txt
git commit -am "drill: pin an outdated Flask version"
git push origin drill/vulnerable-dep
```

> The point of the drill is to see Trivy's report, **not** to ship the
> vulnerable image. Trivy will stop the pipeline *before* the push stage.

### Expected pipeline behaviour

| Stage | Result |
|---|---|
| 1-4 | ✅ green (the old Flask still installs fine) |
| 5 **Trivy** | ❌ **red** — `exit-code: 1` on CRITICAL/HIGH |
| 6 Push | ⛔ skipped |
| 7 Deploy | ⛔ skipped |

The SARIF report is uploaded to
**Security → Code scanning alerts**, and the raw report is stored as the
`trivy-report` artifact.

### Diagnose locally

```bash
trivy image --severity CRITICAL,HIGH --exit-code 1 ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-…
trivy image --format table --severity CRITICAL,HIGH,MEDIUM ghcr.io/…:sha-…
trivy fs --severity HIGH,CRITICAL .        # secrets + misconfigurations
```

### Recover

Upgrade the dependency:

```bash
pip install -U "Flask>=3.1.0"
pip freeze > requirements.txt
pytest -v                                  # make sure the upgrade did not break anything
```

### If a finding is a false positive

Add a `.trivyignore` file (committed) with the CVE id and a justification, and
an expiry date:

```
# CVE-2023-0000 - false positive: the vulnerable code path is not reachable.
# Accepted by the security team on 2026-12-01, review by then.
CVE-2023-0000
```

---

## Scenario 5 — A release that is not healthy

**Expected result:** the health check fails → the pipeline rolls back to the
previous version automatically → the job still ends in **failure**.

### Reproduce safely (local Docker Compose — no server involved)

```bash
git checkout -b drill/unhealthy-release
# Make /health fail without touching the real code path: break the DB check.
python - <<'PY'
import pathlib
p = pathlib.Path("app/routes.py"); s = p.read_text()
s = s.replace(
    "    db_ok, db_error = check_database_connection(\n        timeout=current_app.config.get(\"HEALTH_DB_TIMEOUT\")\n    )",
    "    db_ok, db_error = False, \"simulated failure\"  # DRILL",
)
p.write_text(s)
PY
docker compose up -d --build
curl -i http://localhost:8080/health
```

**Expected output:** `HTTP/1.1 503 SERVICE UNAVAILABLE` with
`"status": "unhealthy"`.

### Reproduce the *full* rollback on the server

> Use a staging environment or a throwaway branch. Never do this on a
> production domain that real users depend on.

```bash
# On a drill branch, push the broken health check and merge it to main
git commit -am "drill: simulate an unhealthy release"
git push origin drill/unhealthy-release
# merge the PR -> the pipeline runs
```

### Expected pipeline behaviour

```
Stage 7  Deploy      -> deploy.sh pulls sha-BAD, starts the container
Stage 8  Validate    -> health-check.sh: attempt 1/10 fails ... 10/10 fails
Stage 7  (inside)    -> deploy.sh calls rollback.sh automatically
Stage 9  Rollback    -> the previous image is pulled, started and validated
Final                -> the job ends in FAILURE (a rollback is not a success)
```

### Diagnose

```bash
# On the server
cat /opt/devops-cicd/state/current-image     # should be the OLD sha tag
cat /opt/devops-cicd/state/previous-image    # empty after a successful rollback
ls -lt /opt/devops-cicd/logs/                # deploy-*.log and rollback-*.log
docker compose -f docker-compose.prod.yml logs --tail=200 app
```

### Recover

```bash
# The old version is already back in production - now fix the cause:
git revert <bad-commit>
git push origin main          # the pipeline redeploys the good version
```

### Verify the rollback happened (drill on the server, safe)

```bash
cd /opt/devops-cicd/deploy
./scripts/rollback.sh; echo "exit code: $?"
```

Expected: `Rollback SUCCESSFUL` and `exit code: 0`.

---

## Scenario 6 — The database is unavailable

**Expected result:** `/health` returns **503** with `database_unavailable`,
the container is marked *unhealthy*, and (in production) the deployment is
rolled back.

### Reproduce safely (local)

```bash
# Stop the database only - the app container keeps running
docker compose stop db
curl -i http://localhost:8080/health
```

**Expected output:**

```json
{
  "status": "unhealthy",
  "error": "database_unavailable",
  "checks": { "database": { "status": "down", "error": "OperationalError: ... connection refused" } }
}
```

with `HTTP/1.1 503 SERVICE UNAVAILABLE`.

```bash
docker compose ps app     # shows the app as "unhealthy"
docker compose start db   # recover
curl http://localhost:8080/health    # "healthy" again
```

### Reproduce on the server (safe)

```bash
# Stop ONLY the database container for a few seconds
docker compose -f docker-compose.prod.yml stop db
curl -s http://localhost/health | jq .status     # "unhealthy"
docker compose -f docker-compose.prod.yml start db
```

> Because the app container has `restart: unless-stopped` and its own
> health check, Docker marks it *unhealthy* but does **not** restart it —
> the app is still able to serve `/` and `/api/stats`.

### Diagnose

```bash
docker compose -f docker-compose.prod.yml ps db
docker compose -f docker-compose.prod.yml logs --tail=100 db
docker compose -f docker-compose.prod.yml exec db pg_isready -U appuser -d devops_cicd
```

Common causes:

| Cause | Fix |
|---|---|
| The `pgdata` volume is full | `docker system df` → free space; increase the volume |
| The password in `secrets.env` changed but the DB kept the old one | `ALTER USER appuser WITH PASSWORD '…'` or recreate the volume |
| The database container crashed | `docker compose logs db` → usually out of memory |
| The `POSTGRES_HOST` is wrong | it must be `db` (the Compose service name) |

### Recover

```bash
docker compose -f docker-compose.prod.yml up -d db
curl -s http://localhost/health | jq .status      # must be "healthy"
```

---

## Quick reference — what each failure teaches you

| Scenario | Gate that catches it | Lesson |
|---|---|---|
| 1 Syntax error | Lint | Fail fast, fail cheap |
| 2 Failing test | Test | The test suite is the safety net |
| 3 Bad Docker config | Build | Never deploy something that cannot be built |
| 4 Vulnerable dependency | Trivy | Supply-chain security is part of CI/CD |
| 5 Unhealthy release | Health check + rollback | **Deployments must be verifiable** |
| 6 Database down | Health check (503) | A running process is not necessarily a healthy service |
