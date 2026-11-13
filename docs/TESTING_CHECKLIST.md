# ✅ Testing & Validation Checklist

> 17 checks, each with the exact command, the expected result and how to fix
> a failure. Tick the boxes as you go — a ticked checklist is excellent
> evidence for a portfolio or a placement interview.
>
> Print it: `code docs/TESTING_CHECKLIST.md` or open it in a Markdown viewer.

---

## Legend

| Mark | Meaning |
|---|---|
| ☐ | Not tested yet |
| ☑ | Passed |
| ☒ | Failed (write the reason below) |

---

## 1. The application runs locally

| | |
|---|---|
| **Command** | `docker compose up -d --build` then `curl http://localhost:8080/` |
| **Directory** | project root |
| **Expected** | HTTP 200; JSON with `application`, `version`, `environment`, `message` |
| **If it fails** | `docker compose logs app` → check the container actually started |

## 2. The database connection works

| | |
|---|---|
| **Command** | `curl http://localhost:8080/health` |
| **Expected** | `"status": "healthy"` and `checks.database.status == "up"` |
| **If it fails** | `docker compose ps db` (must be *healthy*), `docker compose logs db` |
| **Extra** | `docker compose exec db psql -U appuser -d devops_cicd -c '\dt'` → the `users` table must exist |

## 3. The API endpoints return correct responses

| | |
|---|---|
| **Command** | `curl -i -X POST http://localhost:8080/api/users -H 'Content-Type: application/json' -d '{"name":"Ada","email":"ada@example.com"}'` |
| **Expected** | `HTTP/1.1 201 CREATED` with the created user |
| **Also check** | duplicate e-mail → `409`; invalid e-mail → `400`; wrong content type → `415`; unknown path → `404` |
| **If it fails** | `curl -s http://localhost:8080/health` — the DB must be up |

## 4. The unit tests pass

| | |
|---|---|
| **Command** | `pytest -v` (or `make test`) |
| **Expected** | `41 passed`, coverage ≈ 87 % |
| **If it fails** | read the traceback; `pytest -k test_name -vv` for a single test |
| **Extra** | `pytest --cov=app --cov-report=html` → open `htmlcov/index.html` |

## 5. The Docker image builds

| | |
|---|---|
| **Command** | `docker build -f Dockerfile -t devops-cicd-app:optimized .` |
| **Expected** | exit code 0, image ≈ 160 MiB |
| **If it fails** | `docker build --progress=plain …` for a verbose log |
| **Extra** | `docker history devops-cicd-app:optimized` → no `gcc`/`build-essential` layers |

## 6. Docker Compose starts all services

| | |
|---|---|
| **Command** | `docker compose up -d` && `docker compose ps` |
| **Expected** | `db`, `app`, `nginx` all `Up (healthy)` |
| **If it fails** | `docker compose logs --tail=50 <service>` |
| **Extra** | `docker compose config` → renders the merged configuration (catches YAML errors) |

## 7. Nginx forwards requests correctly

| | |
|---|---|
| **Command** | `curl -i -H "Host: app.local" http://127.0.0.1:8080/health` |
| **Expected** | HTTP 200 from the Flask app, `Server: nginx` |
| **Also check** | `docker compose exec nginx nginx -t` → `syntax is ok` / `test is successful` |
| **If it fails** | `docker compose logs nginx`; confirm the `app` container is healthy |

## 8. The GHCR push works

| | |
|---|---|
| **Command** | `docker push ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-test` |
| **Expected** | `sha-test: digest: sha256:… size: …` |
| **Verify** | <https://github.com/YOUR_USERNAME?tab=packages> shows the package and tag |
| **If it fails** | `unauthorized` → `docker login ghcr.io -u USER --password-stdin` with a valid PAT |

## 9. The EC2 SSH connection works

| | |
|---|---|
| **Command** | `ssh -i ~/.ssh/ec2_deploy deployer@EC2_IP 'echo OK'` |
| **Expected** | `OK` |
| **If it fails** | wrong user → check `/etc/passwd`; wrong key → re-add the public key; timeout → security group |

## 10. The automated deployment works

| | |
|---|---|
| **Command** | `git push origin main` → watch the Actions tab |
| **Expected** | all jobs green; the deploy job prints the new SHA tag |
| **Verify on the server** | `cat /opt/devops-cicd/state/current-image` → the new `sha-…` tag |
| **If it fails** | open the deploy job → *Collect the deployment logs* step; then `cat /opt/devops-cicd/logs/deploy-*.log` |

## 11. The health check passes

| | |
|---|---|
| **Command** | `curl -s -o /dev/null -w '%{http_code}\n' https://YOUR_DOMAIN/health` |
| **Expected** | `200` |
| **Local** | `./scripts/health-check.sh --url http://localhost/health --retries 5 --interval 3` |
| **If it fails** | `curl -s https://YOUR_DOMAIN/health \| jq` → the `error` field tells you why |

## 12. HTTPS works

| | |
|---|---|
| **Command** | `curl -I https://YOUR_DOMAIN/health` |
| **Expected** | `HTTP/2 200` + the `strict-transport-security` header |
| **Also check** | `echo | openssl s_client -connect YOUR_DOMAIN:443 2>/dev/null \| openssl x509 -noout -dates` |
| **If it fails** | `sudo tail -50 /var/log/letsencrypt/letsencrypt.log` on the server |

## 13. SSL renewal is configured

| | |
|---|---|
| **Command** | `docker compose -f docker-compose.prod.yml run --rm --entrypoint "certbot renew --dry-run" certbot` |
| **Expected** | `Congratulations, all simulated renewals succeeded` |
| **Also check** | `systemctl list-timers certbot-renew.timer` → `enabled` |
| **If it fails** | the timer is not installed → re-run `scripts/setup-ssl.sh` |

## 14. A failed deployment triggers the rollback

| | |
|---|---|
| **How** | break `/health` on a branch, merge it (see `FAILURE_SIMULATION.md`, Scenario 5) |
| **Expected** | the deploy job fails; the log shows *Rolling back to …*; the server keeps serving the old version |
| **Verify** | `cat /opt/devops-cicd/state/current-image` → the **old** SHA tag |
| **If it fails** | `cat /opt/devops-cicd/logs/rollback-*.log` |

## 15. The previous version is restored successfully

| | |
|---|---|
| **Command** | `curl -s https://YOUR_DOMAIN/health \| jq -r .version` |
| **Expected** | the version of the **previous** release |
| **Also** | `./scripts/rollback.sh; echo $?` → `0` |
| **If it fails** | `docker compose -f docker-compose.prod.yml logs --tail=100 app` |

## 16. Pull request checks work

| | |
|---|---|
| **How** | create a branch, push it, open a PR |
| **Expected** | the *1-3 | Checkout, Lint & Test* check runs and must be green to merge |
| **If it fails** | open the PR → *Checks* tab → the failing job's log |
| **Note** | the deploy job must **not** run for a PR — verify in the Actions tab |

## 17. Branch protection blocks direct pushes

| | |
|---|---|
| **How** | `git push origin feature/x` to `main` directly (with protection on) |
| **Expected** | `remote: error: GH006: Protected branch update failed` |
| **If it fails** | the rule is not enabled → see `BRANCH_PROTECTION.md` |

---

## Extra checks (nice to have)

| Check | Command | Expected |
|---|---|---|
| PostgreSQL is not reachable from the internet | `nc -zv EC2_IP 5432` | `connection refused` / timeout |
| The image runs as a non-root user | `docker inspect -f '{{.Config.User}}' devops-cicd-app` | `appuser` (not empty/root) |
| No secrets in the image | `docker history --no-trunc devops-cicd-app \| grep -i password` | no output |
| No secrets in git | `git ls-files \| grep -E '\.env$|secrets'` | only `.env.example` |
| Log rotation is active | `docker inspect -f '{{json .HostConfig.LogConfig}}' devops-cicd-app` | `max-size`/`max-file` set |
| The image has no shell as root | `docker run --rm --entrypoint id devops-cicd-app` | `uid=10001(appuser)` |
| Dependency vulnerabilities | `trivy image ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-… --severity HIGH,CRITICAL` | no Critical/High |

---

## Result summary

| # | Check | Result | Notes |
|---|---|---|---|
| 1 | App runs locally | ☐ | |
| 2 | Database connection | ☐ | |
| 3 | API endpoints | ☐ | |
| 4 | Unit tests | ☐ | |
| 5 | Docker build | ☐ | |
| 6 | Compose up | ☐ | |
| 7 | Nginx forwarding | ☐ | |
| 8 | GHCR push | ☐ | |
| 9 | EC2 SSH | ☐ | |
| 10 | Automated deployment | ☐ | |
| 11 | Health check | ☐ | |
| 12 | HTTPS | ☐ | |
| 13 | SSL renewal | ☐ | |
| 14 | Rollback triggered | ☐ | |
| 15 | Previous version restored | ☐ | |
| 16 | PR checks | ☐ | |
| 17 | Branch protection | ☐ | |
