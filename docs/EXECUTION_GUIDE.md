# 📘 Execution Guide — from zero to a live, auto-deployed application

> This guide assumes **nothing**. Every step has: the exact command, the
> directory to run it in, the expected output, what it does, the common errors
> and how to fix them.
>
> * [A. Local development (Ubuntu / WSL)](#a-local-development-ubuntu--wsl)
> * [B. GitHub repository setup](#b-github-repository-setup)
> * [C. GitHub Actions configuration](#c-github-actions-configuration)
> * [D. GHCR setup](#d-ghcr-setup)
> * [E. AWS EC2 configuration](#e-aws-ec2-configuration)
> * [F. Production deployment](#f-production-deployment)
> * [G. SSL configuration](#g-ssl-configuration)
> * [H. Rollback testing](#h-rollback-testing)

---

## A. Local development (Ubuntu / WSL)

### A.1 Install the tools

**Directory:** anywhere (these are system-wide installs)

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl python3.12 python3.12-venv python3-pip make
```

**Expected output:** a long list of packages; the last lines end with
`Setting up ...` entries.

**Common error:** `E: Unable to locate package python3.12`
**Fix:** Ubuntu 24.04 ships Python 3.12. On Ubuntu 22.04 add the deadsnakes PPA:

```bash
sudo add-apt-repository ppa:deadsnakes/ppa -y && sudo apt update
sudo apt install -y python3.12 python3.12-venv
```

**Common error:** `python3 --version` shows 3.10/3.11
**Fix:** it is fine — always call it explicitly as `python3.12`.

---

### A.2 Install Docker

**Directory:** anywhere

```bash
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
newgrp docker        # or log out and back in
```

**Expected output:**

```
docker --version
Docker version 27.x.x, build xxxxx

docker compose version
Docker Compose version v2.x.x
```

**Common error:** `permission denied while trying to connect to the Docker daemon socket`
**Fix:** you have not reloaded the group membership yet → `newgrp docker` (or
log out/in), then re-run the command.

**Common error:** `docker: command not found`
**Fix:** the package did not install → re-run the `apt install` line and check
`sudo apt update` output for errors.

---

### A.3 Get the code

**Directory:** `~/projects`

```bash
mkdir -p ~/projects && cd ~/projects
git clone https://github.com/YOUR_USERNAME/devops-cicd-project.git
cd devops-cicd-project
```

**Expected output:** `Cloning into 'devops-cicd-project' ...` and a list of files.

**Common error:** `Permission denied (publickey)` when pushing later
**Fix:** you have not uploaded a public key to GitHub yet → see step B.4.

---

### A.4 Create the environment file

**Directory:** `~/projects/devops-cicd-project`

```bash
cp .env.example .env
```

Now edit it:

```bash
nano .env
```

Change at least these two lines:

```ini
POSTGRES_PASSWORD=choose-a-real-password
SECRET_KEY=replace-with-a-long-random-string
```

Generate a good `SECRET_KEY`:

```bash
python3.12 -c "import secrets; print(secrets.token_urlsafe(48))"
```

**Common error:** the app refuses to start with
`SECRET_KEY must be set to a strong random value when APP_ENV=production`
**Fix:** this is the intended safety check — set a real secret, do not remove
the check.

---

### A.5 Start the stack with Docker Compose

**Directory:** `~/projects/devops-cicd-project`

```bash
docker compose up -d --build
```

**Expected output:**

```
[+] Running 4/4
 ✔ Network devops-cicd-net           Created
 ✔ Container devops-cicd-db          Started
 ✔ Container devops-cicd-app         Started
 ✔ Container devops-cicd-nginx       Started
```

Wait ~20 seconds, then check:

```bash
docker compose ps
```

**Expected output:** all three services show `healthy` (or `running` for nginx
during the first seconds):

```
NAME                  IMAGE                        STATUS
devops-cicd-app       devops-cicd-app:local         Up (healthy)
devops-cicd-db        postgres:16-alpine            Up (healthy)
devops-cicd-nginx     nginx:1.27-alpine            Up (healthy)
```

**Common error:** `service "db" is unhealthy` → the database password in
`.env` does not match the one the volume was initialised with.
**Fix:** `docker compose down -v && docker compose up -d --build` (this deletes
the old volume and starts fresh).

**Common error:** `port is already allocated` → something else uses port 8080.
**Fix:** change `NGINX_HTTP_PORT=8081` in `.env` and run
`docker compose up -d --build` again.

---

### A.6 Verify the API

**Directory:** anywhere

```bash
curl http://localhost:8080/health
```

**Expected output:**

```json
{
  "application": "devops-cicd-app",
  "checks": { "database": { "latency_ms": 0.64, "status": "up" } },
  "environment": "development",
  "status": "healthy",
  "timestamp": "2026-11-11T17:07:26.996633+00:00",
  "version": "1.0.0"
}
```

Create a user:

```bash
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Ada Lovelace", "email": "ada@example.com"}'
```

**Expected output:** `{"message": "User created successfully", "user": {...}}` and
HTTP `201`.

List the users:

```bash
curl http://localhost:8080/api/users
```

**Common error:** `{"error": "database_unavailable"}` with HTTP 503
**Fix:** the database is not ready → `docker compose logs db`; wait and retry.

---

### A.7 Run the tests

**Directory:** `~/projects/devops-cicd-project`

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
pytest -v
```

**Expected output:**

```
tests/test_database.py::TestUserModel::test_user_fields PASSED
...
========================= 41 passed in 0.85s =========================
```

**Common error:** `ModuleNotFoundError: No module named 'flask'`
**Fix:** the virtualenv is not active → `source .venv/bin/activate` (or just
use `make setup && make test`).

**Common error:** `error: unrecognized arguments: --cov=app`
**Fix:** `pytest-cov` is missing → `pip install -r requirements-dev.txt`.

---

### A.8 Run the linters (exactly like CI does)

```bash
ruff check .
black --check .
shellcheck -S style scripts/*.sh
```

**Expected output:** `All checks passed!` for each.

**Common error:** `ruff: command not found` → `pip install ruff black`.

---

### A.9 Measure the image sizes

```bash
make measure-images
```

**Expected output:** a table with both images and the reduction percentage.

---

## B. GitHub repository setup

### B.1 Create the repository

**Directory:** anywhere (browser)

1. Go to <https://github.com/new>.
2. Name: `devops-cicd-project`.
3. Visibility: **Private** (public works too, but private shows better security
   hygiene — the README works either way).
4. **Do NOT** tick "Add a README" — you already have one.
5. Click *Create repository*.

### B.2 Connect your local copy

**Directory:** `~/projects/devops-cicd-project`

```bash
git remote -v                    # check what exists
git remote add origin https://github.com/YOUR_USERNAME/devops-cicd-project.git
git branch -M main
git add .
git commit -m "Initial commit: containerised Flask app with full CI/CD pipeline"
git push -u origin main
```

**Expected output:** `branch 'main' set up to track 'origin/main'` and a GitHub
URL for the commit.

**Common error:** `remote origin already exists`
**Fix:** `git remote set-url origin https://github.com/YOUR_USERNAME/devops-cicd-project.git`

**Common error:** `Permission denied ... 403` → see B.4.

---

### B.3 Enable Actions

**Directory:** n/a (browser)

GitHub enables Actions automatically for new repositories. Verify:
**Repository → Actions → "CI/CD Pipeline"** is listed. Click it and watch the
first run — it will fail at the *push* stage only if the secrets are missing,
because the deploy job is skipped without them.

---

### B.4 (Optional but recommended) Create an SSH key for GitHub

**Directory:** `~`

```bash
ssh-keygen -t ed25519 -C "you@example.com" -f ~/.ssh/github_personal -N ""
cat ~/.ssh/github_personal.pub
```

Copy the output and paste it into
**GitHub → Settings → SSH and GPG keys → New SSH key**.

Test it:

```bash
ssh -T git@github.com
```

**Expected output:** `Hi YOUR_USERNAME! You've successfully authenticated...`

---

## C. GitHub Actions configuration

### C.1 What is already in the repository

Nothing to do — the pipeline is at `.github/workflows/ci.yml` and is picked up
automatically on every push and pull request.

### C.2 Add the secrets

**Directory:** n/a (browser)

**Repository → Settings → Secrets and variables → Actions → New repository secret**

Add each one (see the table in the main [README](README.md#8-github-secrets)):

| Name | Value |
|---|---|
| `EC2_HOST` | `203.0.113.25` (your EC2 public IP) |
| `EC2_USER` | `deployer` |
| `EC2_SSH_PRIVATE_KEY` | the whole private key, `BEGIN`…`END` |
| `GHCR_USERNAME` | `YOUR_USERNAME` |
| `GHCR_TOKEN` | a fine-grained PAT with `read:packages` |
| `APP_DOMAIN` | `app.example.com` (or `localhost` while testing) |
| `PRODUCTION_ENV` | `production` |
| `EC2_SSH_KNOWN_HOSTS` | optional but recommended |

**Expected result:** the **Secrets** tab lists seven green entries.

**Common error:** a secret added to the *Environment* instead of the *Repository*
→ the pipeline cannot read it. Use the **Repository** tab unless you are using
GitHub Environments (which the `deploy` job does use — see C.3).

### C.3 (Recommended) Use a GitHub Environment for production

**Directory:** n/a (browser)

**Repository → Environments → New environment → name it `production`**

The `deploy` job already references `environment: production`. Add the same
secrets to the environment (environment secrets override repository ones) and
optionally require approval before deployment — a nice talking point for an
interview ("we gate production deployments behind a manual approval").

---

## D. GHCR setup

### D.1 Make the package visible

**Directory:** `~/projects/devops-cicd-project`

The CI pipeline pushes to GHCR automatically, but the *first* push can be
rejected if the package is private and the token lacks access. Create a
fine-grained PAT:

1. **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
2. *Token name*: `ghcr-push`
3. *Expiration*: 90 days
4. *Repository access*: select **only** your repository
5. *Permissions → Packages*: **Read and write**
6. Generate → copy the token (shown only once!)

Log in and push manually once:

```bash
echo "$TOKEN" | docker login ghcr.io -u YOUR_USERNAME --password-stdin
docker build -f Dockerfile -t ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-local .
docker push ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-local
```

**Expected output:**

```
The push refers to repository [YOUR_USERNAME/devops-cicd-app]
...
sha-local: digest: sha256:9f2c… size: 1583
```

**Common error:** `unauthorized: authentication required`
**Fix:** the token is wrong or expired → regenerate it. Never put the token in
the URL (`https://user:token@ghcr.io`) — it ends up in the shell history.

**Common error:** `denied: requested access to the resource is denied`
**Fix:** the token is missing the `packages: write` permission, or the
repository is not selected in the token's scope.

### D.2 Verify the package

**Directory:** n/a (browser)

<https://github.com/YOUR_USERNAME?tab=packages> → you should see
`devops-cicd-app` with the `sha-local` tag.

### D.3 Create the read-only token for the server

Repeat the PAT creation with **Packages: Read-only** and name it
`gcr-readonly-server`. This is the one stored as the `GHCR_TOKEN` secret and
used by the EC2 server to pull images.

---

## E. AWS EC2 configuration

### E.1 Create the instance

**Directory:** n/a (browser)

1. **AWS console → EC2 → Instances → Launch instance**
2. *Name*: `devops-cicd-prod`
3. *AMI*: **Ubuntu Server 24.04 LTS** (x86_64)
4. *Instance type*: `t3.micro` (free tier)
5. *Key pair*: create `ec2_deploy` → **Download key pair** (`.pem` file)
6. *Network settings*: create a security group with:

   | Type | Port | Source |
   |---|---|---|
   | SSH | 22 | My IP |
   | HTTP | 80 | 0.0.0.0/0 |
   | HTTPS | 443 | 0.0.0.0/0 |

7. *Storage*: 20 GB gp3, delete on termination ✅
8. *Advanced*: leave the defaults, click **Launch instance**

**Common error:** `ssh: connect to host … port 22: Connection timed out`
**Fix:** the security group does not allow port 22 from your IP, or the
instance is in a different VPC than your network.

### E.2 Record the public IP

**Directory:** n/a (browser)

EC2 console → the instance → *Public IPv4 address* → `203.0.113.25`.
Copy it — you need it for the `EC2_HOST` secret and for DNS.

### E.3 Connect for the first time

**Directory:** `~`

```bash
chmod 600 ~/Downloads/ec2_deploy.pem
ssh -i ~/Downloads/ec2_deploy.pem ubuntu@203.0.113.25
```

**Expected output:** a prompt like `ubuntu@ip-203-0-113-25:~$`

**Common error:** `UNPROTECTED PRIVATE KEY FILE` → `chmod 600` the key.
**Common error:** `Permission denied (publickey)` → wrong user (`ubuntu` for
Ubuntu AMIs, `ec2-user` for Amazon Linux) or wrong key.

### E.4 Run the bootstrap script

**Directory:** `~` (your workstation)

```bash
scp -i ~/Downloads/ec2_deploy.pem scripts/setup-server.sh ubuntu@203.0.113.25:/tmp/
ssh -i ~/Downloads/ec2_deploy.pem ubuntu@203.0.113.25 'sudo bash /tmp/setup-server.sh'
```

**Expected output** (abbreviated):

```
[setup] 1/8 Updating the system and installing base packages ...
[setup] 2/8 Installing Docker Engine and the Compose plugin ...
[setup] 3/8 Configuring the 'deployer' user ...
[setup] 4/8 Creating the deployment directory tree ...
[setup] 5/8 Generating production secrets ...
[setup] 6/8 Hardening the Docker daemon ...
[setup] 7/8 Configuring the UFW firewall ...
[setup] 8/8 Configuring log rotation ...
[setup] Server setup complete
```

**Common error:** `This script must be run as root`
**Fix:** use `sudo bash …` (as shown above).

**Common error:** `The repository … does not have a Release file`
**Fix:** the Ubuntu codename is wrong (e.g. using a Debian script on Ubuntu).
Re-check the `docker.list` file that the script wrote.

### E.5 Authorise the deployment key for the `deployer` user

**Directory:** `~` (workstation)

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/ec2_deploy -N ""
ssh-copy-id -i ~/.ssh/ec2_deploy.pub deployer@203.0.113.25
```

You will be asked for the `deployer` user's password — but `setup-server.sh`
creates that user with a **disabled password**. So instead, copy the key as
root:

```bash
ssh -i ~/Downloads/ec2_deploy.pem ubuntu@203.0.113.25 \
  'sudo mkdir -p /home/deployer/.ssh && sudo cp /root/.ssh/authorized_keys /home/deployer/.ssh/ 2>/dev/null; \
   sudo cat /home/ubuntu/.ssh/authorized_keys >> /home/deployer/.ssh/authorized_keys && \
   sudo chown -R deployer:deployer /home/deployer/.ssh && sudo chmod 700 /home/deployer/.ssh && \
   sudo chmod 600 /home/deployer/.ssh/authorized_keys'
```

Then verify:

```bash
ssh -i ~/.ssh/ec2_deploy deployer@203.0.113.25 'echo "SSH OK as $(whoami)"'
```

**Expected output:** `SSH OK as deployer`

**Common error:** `sudo: a password is required`
**Fix:** you are not using the Ubuntu user's sudo context. Run the commands
individually while logged in as `ubuntu` (that user has passwordless sudo on
Ubuntu AMIs).

### E.6 (Important) Restrict SSH to key authentication

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

Verify: `sudo sshd -T | grep passwordauthentication` → `passwordauthentication no`.

---

## F. Production deployment

### F.1 Trigger the pipeline

**Directory:** `~/projects/devops-cicd-project`

```bash
git add -A && git commit -m "feat: initial production deployment"
git push origin main
```

**Expected output:** push confirmation, then open the Actions tab.

### F.2 Watch the run

**Directory:** n/a (browser)

**Actions → CI/CD Pipeline**. The five jobs appear in order:

```
✓ 1-3 | Checkout, Lint & Test      (≈ 1 min)
✓ 4   | Build Docker image         (≈ 1 min, faster with cache)
✓ 5   | Trivy security scan        (≈ 1 min)
✓ 6   | Push to GHCR               (≈ 30 s)
✓ 7-9 | Deploy, Validate & Rollback(≈ 1 min)
```

### F.3 Verify on the server

**Directory:** any (your workstation)

```bash
ssh -i ~/.ssh/ec2_deploy deployer@203.0.113.25 '
  cd /opt/devops-cicd/deploy &&
  docker compose -f docker-compose.prod.yml ps &&
  echo "--- current image ---" && cat /opt/devops-cicd/state/current-image &&
  echo "--- health ---" && curl -s http://localhost/health'
```

**Expected output:**

```
NAME                  IMAGE                                       STATUS
devops-cicd-app       ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-…  Up (healthy)
devops-cicd-db        postgres:16-alpine                          Up (healthy)
devops-cicd-nginx     nginx:1.27-alpine                          Up (healthy)

ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-abc123…
{"application":"devops-cicd-app","status":"healthy",...}
```

**Common error:** `WARNING: The "POSTGRES_PASSWORD" variable is not set`
**Fix:** `secrets.env` is missing → re-run `setup-server.sh` (it is idempotent
and will not overwrite existing secrets).

**Common error:** the deploy job fails with `ERROR: no previous image recorded`
**Fix:** that is the rollback script complaining during a *first* deployment
failure — check the real error in the deploy log.

---

## G. SSL configuration

### G.1 Point a domain at the server

**Directory:** n/a (your DNS provider)

Add an **A record**:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `app` | `203.0.113.25` | 300 |

Verify from your workstation:

```bash
dig +short app.example.com
```

**Expected output:** `203.0.113.25`

**Common error:** the output is empty or an old IP → DNS propagation takes up
to a few minutes; wait and retry.

### G.2 Request the certificate

**Directory:** your workstation (or the server)

```bash
ssh -i ~/.ssh/ec2_deploy deployer@203.0.113.25 \
  'sudo bash /opt/devops-cicd/deploy/scripts/setup-ssl.sh app.example.com'
```

**Expected output:**

```
[ssl] Domain        : app.example.com
[ssl] Public IP     : 203.0.113.25
[ssl] 1/4 Checking DNS resolution ...
[ssl] 2/4 Requesting the certificate from Let's Encrypt ...
[ssl] 3/4 Rendering the HTTPS virtual host ...
[ssl] 4/4 Configuring the automatic renewal timer ...
[ssl] HTTPS is configured for app.example.com
```

**Common error:** `Timeout during connect` / `The domain has no A record`
**Fix:** the A record is missing or not propagated yet.

**Common error:** `Certbot failed` → check that port 80 is open in **both** the
security group and UFW, and that the stack is running:
`curl http://app.example.com/.well-known/acme-challenge/test`

**Common error:** `nginx: [emerg] cannot load certificate …`
**Fix:** the template was rendered but the file was not copied into the
container. The `nginx` service mounts `./nginx/conf.d` — make sure the file
exists at `/opt/devops-cicd/deploy/nginx/conf.d/app-https.conf`.

### G.3 Test HTTPS

```bash
curl -I https://app.example.com/health
```

**Expected output:**

```
HTTP/2 200
server: nginx
strict-transport-security: max-age=31536000; includeSubDomains
```

**Common error:** `curl: (60) SSL certificate problem` → the certificate does
not match the domain yet → wait for the renewal to finish and reload Nginx.

### G.4 Verify automatic renewal

```bash
ssh -i ~/.ssh/ec2_deploy deployer@203.0.113.25 '
  cd /opt/devops-cicd/deploy &&
  docker compose -f docker-compose.prod.yml run --rm --entrypoint "certbot renew --dry-run" certbot &&
  systemctl list-timers certbot-renew.timer'
```

**Expected output:**

```
Congratulations, all simulated renewals succeeded
NEXT LEFT TIME LAST PASSED UNIT                    ACTIVATES
Mon 2026-11-16 03:12:31 UTC  4h 21min left  Mon 2026-11-11 15:00:00 UTC  certbot-renew.timer enabled
```

---

## H. Rollback testing

### H.1 Test the rollback script directly (safe)

**Directory:** your workstation

```bash
ssh -i ~/.ssh/ec2_deploy deployer@203.0.113.25 \
  'cd /opt/devops-cicd/deploy && ls -l /opt/devops-cicd/state/ && cat /opt/devops-cicd/state/previous-image 2>/dev/null || echo "(no previous image yet)"'
```

**Expected output after two successful deployments:**

```
-rw-r--r-- 1 deployer deployer ... current-image
-rw-r--r-- 1 deployer deployer ... previous-image
ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-firstcommit
```

Trigger it manually:

```bash
ssh -i ~/.ssh/ec2_deploy deployer@203.0.113.25 \
  'cd /opt/devops-cicd/deploy && ./scripts/rollback.sh; echo "exit code: $?"'
```

**Expected output:**

```
[rollback] Rolling back to ghcr.io/YOUR_USERNAME/devops-cicd-app:sha-firstcommit
[rollback] Health check passed
[rollback] Rollback SUCCESSFUL
exit code: 0
```

### H.2 Full pipeline rollback drill (safe, on a branch)

Do **not** do this on `main` with real traffic. Use a branch and a staging
domain:

```bash
git checkout -b test/rollback-drill
# Break the health endpoint on purpose (see FAILURE_SIMULATION.md)
git commit -am "test: simulate an unhealthy release"
git push origin test/rollback-drill
```

Open a **pull request** into `main` and merge it (the deploy only runs for
pushes to `main`, so you need to merge — use a throwaway environment).

**Expected behaviour:**

1. The pipeline builds and pushes the broken image.
2. The deploy job runs `deploy.sh`.
3. `health-check.sh` fails 10 times.
4. `deploy.sh` calls `rollback.sh` automatically.
5. The previous image is restored and becomes healthy.
6. The **job still ends in failure** — the deployment is marked as failed.

Verify on the server:

```bash
ssh -i ~/.ssh/ec2_deploy deployer@203.0.113.25 \
  'cat /opt/devops-cicd/state/current-image; ls -lt /opt/devops-cicd/logs | head -5'
```

### H.3 Rehearse a rollback after the drill

```bash
git checkout main && git revert -m 1 <merge-commit> && git push origin main
```

The pipeline redeploys the good version and everything is green again.

---

## Appendix: the 30-second command reference

```bash
# Local
make setup && make test && make lint
docker compose up -d --build && docker compose ps

# On the server
cd /opt/devops-cicd/deploy
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs -f app
cat /opt/devops-cicd/state/current-image
./scripts/deploy.sh --image ghcr.io/OWNER/devops-cicd-app --tag sha-abc123
./scripts/rollback.sh
./scripts/health-check.sh --url http://localhost/health --retries 5
```
