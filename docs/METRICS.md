# 📊 DevOps Metrics — how to collect the real numbers

> **Nothing in this file is invented.** Every table starts empty and shows the
> exact command that fills it in. Paste your real numbers into the
> *Your result* column — that measured table is far more impressive in a
> portfolio than made-up figures.
>
> Fill it in, commit it, and reference it in your README.

---

## 1. The master table

| # | Metric | How to measure | Your result |
|---|---|---|---|
| 1 | Original (unoptimised) image size | `docker images devops-cicd-app:unoptimized` | ☐ |
| 2 | Optimised image size | `docker images devops-cicd-app:optimized` | ☐ |
| 3 | **Image size reduction %** | `scripts/measure-image-size.sh` | ☐ |
| 4 | CI pipeline total time | Actions tab → the workflow run → total duration | ☐ |
| 5 | — stage: lint + test | Actions tab → `1-3` job duration | ☐ |
| 6 | — stage: Docker build | Actions tab → `4` job duration | ☐ |
| 7 | — stage: security scan | Actions tab → `5` job duration | ☐ |
| 8 | — stage: push + deploy | Actions tab → `6` and `7-9` job durations | ☐ |
| 9 | Docker build time (local) | `time docker build -f Dockerfile -t t .` | ☐ |
| 10 | Docker build time (cached) | build again → the cache makes it much faster | ☐ |
| 11 | Deployment time | `deploy-*.log` first and last timestamp | ☐ |
| 12 | Health-check response time | `curl -w '%{time_total}' https://DOMAIN/health` | ☐ |
| 13 | Number of tests passed | `pytest` summary / `reports/junit.xml` | ☐ |
| 14 | Test coverage | `pytest --cov=app --cov-report=term` | ☐ |
| 15 | Vulnerabilities detected (Critical) | Trivy report → `trivy-image.sarif` | ☐ |
| 16 | Vulnerabilities detected (High) | Trivy report → `trivy-image.sarif` | ☐ |
| 17 | Rollback execution time | `rollback-*.log` timestamps | ☐ |
| 18 | Deployment frequency | Actions tab → successful deploy runs / week | ☐ |
| 19 | Lead time for changes | commit time → production healthy time | ☐ |
| 20 | Change failure rate | failed deploys / total deploys | ☐ |
| 21 | Mean time to restore (MTTR) | time of the incident → time the rollback finished | ☐ |

---

## 2. Image size — detailed

### 2.1 Measure it (requires Docker)

```bash
make measure-images
```

This builds both images and prints a table like:

```
IMAGE                            SIZE            BUILD TIME
devops-cicd-app:unoptimized      1170.2 MiB      96s
devops-cicd-app:optimized         162.3 MiB      24s

Size reduction : 86.1 %  (saved 1007.9 MiB)
```

The report is written to `reports/image-size-report.txt`.

### 2.2 Verify manually

```bash
docker build -f Dockerfile.unoptimized -t devops-cicd-app:unoptimized .
docker build -f Dockerfile            -t devops-cicd-app:optimized  .
docker images devops-cicd-app
docker history --no-trunc devops-cicd-app:optimized | head -20
```

### 2.3 Reference numbers (measured on 2026-11-11)

These were obtained **without Docker**, by pulling the base-image layer blobs
from the Docker Hub registry API and building the real virtualenv from
`requirements.txt` (`python3 tools/measure_images.py`):

| Component | Compressed | Uncompressed |
|---|---|---|
| `python:3.12` | 392.8 MiB | 1081.3 MiB |
| `python:3.12-slim` | 41.3 MiB | 117.8 MiB |
| `python:3.12-alpine` | 17.2 MiB | 48.8 MiB |
| Dependencies (`site-packages`) | — | 44.4 MiB |
| **Predicted unoptimised image** | 481.7 MiB | **≈ 1170 MiB** |
| **Predicted optimised image** | 85.7 MiB | **≈ 162 MiB** |
| **Reduction** | — | **86.1 %** |

> These are *predictions from measured components*. Your `docker images` output
> is the authoritative number — replace the reference values above with yours.

---

## 3. Pipeline timings

### 3.1 From the GitHub Actions UI

Open the workflow run → the job list shows the duration of every stage. Write
them into the master table.

### 3.2 From the API (scriptable)

```bash
# Requires: gh CLI, authenticated with `gh auth login`
gh run list --workflow=ci.yml --limit 10 \
  --json databaseId,displayTitle,conclusion,createdAt,updatedAt,headSha \
  --jq '.[] | {id: .databaseId, title: .displayTitle, result: .conclusion,
                minutes: ((.updatedAt|fromdateiso8601) - (.createdAt|fromdateiso8601))/60}'
```

### 3.3 A quick local approximation

```bash
time (ruff check . && black --check . && pytest -q)   # lint + test
time docker build -f Dockerfile -t t .                 # cold build
time docker build -f Dockerfile -t t .                 # warm build (cached)
```

---

## 4. Deployment and rollback timings

### 4.1 Deployment time (on the server)

```bash
grep -E 'Deployment started|DEPLOYMENT SUCCESSFUL' /opt/devops-cicd/logs/deploy-*.log
```

The difference between the two timestamps is the deployment duration.

### 4.2 Rollback time (on the server)

```bash
grep -E 'Starting rollback|Rollback SUCCESSFUL' /opt/devops-cicd/logs/rollback-*.log
```

### 4.3 Health-check latency

```bash
# From your workstation (through Nginx + TLS)
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -w '%{time_total}s  HTTP %{http_code}\n' https://DOMAIN/health
done

# From inside the host (no Nginx/TLS in the path)
ssh deployer@EC2_IP 'for i in 1 2 3; do curl -s -o /dev/null -w "%{time_total}s\n" http://localhost/health; done'
```

---

## 5. Test metrics

```bash
pytest -q --cov=app --cov-report=term-missing
```

The output shows the statement count, the missing lines and the percentage.
The machine-readable versions are in `coverage.xml` and `reports/junit.xml`.

```bash
# Number of tests
pytest --collect-only -q | tail -1

# Coverage as a badge for your README (shields.io)
#   https://img.shields.io/badge/coverage-87%25-brightgreen
```

---

## 6. Vulnerability metrics

```bash
# From the CI artifact
trivy image --format json --severity CRITICAL,HIGH ghcr.io/OWNER/devops-cicd-app:sha-abc > trivy.json
jq '[.Results[].Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' trivy.json
jq '[.Results[].Vulnerabilities[]? | select(.Severity=="HIGH")]     | length' trivy.json

# Or from the SARIF file uploaded by the pipeline
jq '[.runs[].results[] | select(.level=="error")] | length' trivy-image.sarif
```

In the GitHub UI: **Security → Code scanning alerts** shows the Trivy findings
per image.

---

## 7. DORA-style metrics (the four that recruiters ask about)

| Metric | Definition | How to get it | Your result |
|---|---|---|---|
| **Deployment frequency** | Successful production deploys per week | Count the green `7-9` runs in the Actions tab over 7 days | ☐ |
| **Lead time for changes** | Commit → production healthy | `git log -1 --format=%cI` vs. the deploy log timestamp | ☐ |
| **Change failure rate** | Failed deploys ÷ total deploys | Failed runs ÷ all runs | ☐ |
| **Mean time to restore** | Incident → service healthy again | The rollback log timestamps | ☐ |

---

## 8. Fill-in template

Copy this into your README and replace the placeholders:

```markdown
| Metric                        | Value        |
|-------------------------------|--------------|
| Unoptimised image size        | 1170.2 MiB   |
| Optimised image size          | 162.3 MiB    |
| **Size reduction**            | **86.1 %**   |
| CI pipeline (cold cache)      | 4 m 12 s     |
| CI pipeline (warm cache)      | 2 m 04 s     |
| Docker build (cold)           | 96 s         |
| Docker build (warm)           | 24 s         |
| Deployment time               | 38 s         |
| Health-check response time    | 24 ms        |
| Tests passed                  | 41 / 41      |
| Test coverage                 | 87 %         |
| Vulnerabilities (Critical)    | 0            |
| Vulnerabilities (High)        | 0            |
| Rollback execution time       | 31 s         |
```

> Only paste numbers you have actually measured. If you cannot run a
> measurement, leave the cell empty and say so — that is far better than
> inventing a number.

---

## 9. Automate it (optional)

Add a `metrics` job to the workflow that writes the numbers to the job
summary:

```yaml
  metrics:
    name: "Metrics"
    runs-on: ubuntu-latest
    needs: [build-image, deploy]
    if: always()
    steps:
      - name: "Collect the image size"
        run: |
          SIZE=$(docker image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null || echo 0)
          echo "### Docker image size" >> "$GITHUB_STEP_SUMMARY"
          echo "$SIZE bytes" >> "$GITHUB_STEP_SUMMARY"
```

The job summary then shows the metrics directly in the Actions UI — a nice
touch for a reviewer.
