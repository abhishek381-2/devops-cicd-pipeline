# 🚀 Go-Live Guide — from a local project to a real, running deployment

> Three levels of "live". Do **Level 1** today (2 minutes, ₹0), then **Level 2**
> in one evening (₹0 for 12 months on AWS Free Tier) and **Level 3** when you
> are ready to own a domain (~₹800/year).
>
> * [Level 1 — Instant public demo (no account)](#level-1--instant-public-demo-no-account)
> * [Level 2 — Real AWS EC2 deployment](#level-2--real-aws-ec2-deployment)
> * [Level 3 — Domain + HTTPS](#level-3--domain--https)
> * [Make the repo look legit](#make-the-repo-look-legit)
> * [Cost reality](#cost-reality)

---

## Level 1 — Instant public demo (no account)

**Time: 2 minutes. Cost: ₹0. No cloud account, no domain, no credit card.**

Cloudflare's "quick tunnel" gives your locally running app a real public HTTPS
URL. The URL is what you show the interviewer.

```bash
# 1. Start the app locally
cd devops-cicd-project
./scripts/resume-preview.sh          # repairs the env + starts on :8000

# 2. Download cloudflared (static binary, no root needed)
ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; esac
curl -sL -o cloudflared \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${A}"
chmod +x cloudflared

# 3. Open the tunnel
./cloudflared tunnel --url http://localhost:8000
```

**Expected output:**

```
Your quick Tunnel has been created! Visit it at:
https://some-random-words.trycloudflare.com
```

Open that URL in your browser — your app is now on the public internet with
HTTPS.

### Honest limitations (know these before the interview)

| Limitation | Why it matters |
|---|---|
| The URL **changes every time** you restart the tunnel | Not a stable demo link — don't put it in your README permanently |
| **No uptime guarantee** | Cloudflare may kill it; it's for experimenting |
| It dies when your machine sleeps | Keep the laptop awake and plugged in |
| It proves the *app*, **not** the pipeline | You still need Level 2 for that |

### Making the tunnel survive reboots (free)

Run it as a systemd service on your laptop, or use a named (account) tunnel:

```bash
# with a free Cloudflare account + a domain, a named tunnel gives you a
# stable hostname like https://app.yourdomain.com
cloudflared tunnel login
cloudflared tunnel create devops-cicd
cloudflared tunnel route dns devops-cicd app.yourdomain.com
cloudflared tunnel run devops-cicd
```

---

## Level 2 — Real AWS EC2 deployment

> 👉 **Naya hai yahan?** Step-by-step hand-held version use karo:
> **[DEPLOY_STEP_BY_STEP.md](DEPLOY_STEP_BY_STEP.md)** — har console click,
> har command, expected output aur common error ka fix. Neeche wala section
> uska short summary hai (jo log pehle se jaante hain unke liye).

**Time: 1–2 hours (first time). Cost: ₹0 for 12 months** (AWS Free Tier
`t3.micro` = 750 hours/month free; the Free Tier is 12 months for new accounts).

> ⚠️ **Free Tier gotcha:** the 12-month Free Tier applies to *new* AWS
> accounts. If your account is older, a `t3.micro` costs roughly **₹700–1000/month**
> — still fine for a portfolio project, just budget for it. Always set a
> **Billing alarm** so a forgotten instance cannot surprise you.

### Step 1 — Launch the EC2 instance

AWS console → EC2 → **Launch instance**:

| Setting | Value |
|---|---|
| AMI | Ubuntu Server 24.04 LTS (x86_64) |
| Instance type | `t3.micro` |
| Key pair | create `ec2_deploy` → **download the .pem** |
| Security group | SSH 22 (My IP), HTTP 80 (0.0.0.0/0), HTTPS 443 (0.0.0.0/0) |
| Storage | 20 GB gp3 |

**Do NOT open 5432.** PostgreSQL stays private inside the Docker network.

### Step 2 — Bootstrap the server

```bash
# From your laptop
scp -i ~/Downloads/ec2_deploy.pem scripts/setup-server.sh ubuntu@<EC2_IP>:/tmp/
ssh -i ~/Downloads/ec2_deploy.pem ubuntu@<EC2_IP> 'sudo bash /tmp/setup-server.sh'
```

Expected: 8 steps ending with `Server setup complete`. It installs Docker,
creates the `deployer` user, makes `/opt/devops-cicd/`, generates the
production secrets, hardens the Docker daemon and turns on UFW (22/80/443).

### Step 3 — Authorise the GitHub Actions key

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/ec2_deploy -N ""
cat ~/.ssh/ec2_deploy.pub          # this is the PUBLIC key
```

On the server, as the `deployer` user, add it to `~/.ssh/authorized_keys`.
The `deployer` user has no password (created with `--disabled-password`), so do
it from the `ubuntu` user with sudo:

```bash
ssh -i ~/Downloads/ec2_deploy.pem ubuntu@<EC2_IP> '
  sudo install -d -m 700 -o deployer -g deployer /home/deployer/.ssh
  sudo tee -a /home/deployer/.ssh/authorized_keys > /dev/null <<KEY
'"$(cat ~/.ssh/ec2_deploy.pub)"'
KEY
  sudo chown deployer:deployer /home/deployer/.ssh/authorized_keys
  sudo chmod 600 /home/deployer/.ssh/authorized_keys
'
```

Verify:

```bash
ssh -i ~/.ssh/ec2_deploy deployer@<EC2_IP> 'echo "SSH OK as $(whoami)"'
```

### Step 4 — Create the GHCR read-only token

GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained**:

| Setting | Value |
|---|---|
| Repository access | Only select → your repo |
| Permissions → Packages | **Read-only** |
| Expiration | 90 days |

### Step 5 — Add the GitHub repository secrets

Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|---|---|
| `EC2_HOST` | your EC2 public IPv4 |
| `EC2_USER` | `deployer` |
| `EC2_SSH_PRIVATE_KEY` | contents of `~/.ssh/ec2_deploy` (the **private** key) |
| `GHCR_USERNAME` | your GitHub username |
| `GHCR_TOKEN` | the read-only PAT from step 4 |
| `APP_DOMAIN` | your domain (or the EC2 IP for now) |
| `PRODUCTION_ENV` | `production` |
| `EC2_SSH_KNOWN_HOSTS` | the host key from the EC2 console (optional, recommended) |

### Step 6 — Push and watch it deploy

```bash
git add -A && git commit -m "feat: production deployment pipeline"
git push origin main
```

Open the **Actions** tab. The pipeline runs 9 stages and ends with
`7-9 | Deploy, Validate & Rollback` in green.

### Step 7 — Verify on the server

```bash
ssh -i ~/.ssh/ec2_deploy deployer@<EC2_IP> '
  cd /opt/devops-cicd/deploy
  docker compose -f docker-compose.prod.yml ps
  cat /opt/devops-cicd/state/current-image
  curl -s http://localhost/health
'
```

You should see three healthy containers and your SHA tag.

### Step 8 (optional but recommended) — a GitHub Environment

Settings → Environments → New environment → `production` → add the same
secrets → enable **Required reviewers**.

Now every deployment to `main` waits for your approval — a great thing to
mention in an interview ("production deploys are gated behind a manual
approval").

---

## Level 3 — Domain + HTTPS

**Cost: ~₹700–1000/year** for a `.com`/`.in` domain (Namecheap/GoDaddy/Hostinger).

1. Buy a domain and add an **A record** → your EC2 public IP.
2. Wait for DNS to propagate (`dig +short yourdomain.com`).
3. Run the SSL script on the server:

```bash
ssh -i ~/.ssh/ec2_deploy deployer@<EC2_IP> \
  'sudo bash /opt/devops-cicd/deploy/scripts/setup-ssl.sh app.yourdomain.com'
```

It requests the Let's Encrypt certificate (HTTP-01), renders the HTTPS vhost,
validates the Nginx config, reloads Nginx and installs a renewal timer.

4. Verify:

```bash
curl -I https://app.yourdomain.com/health
# HTTP/2 200 + strict-transport-security header
```

5. Set the domain in the GitHub secret `APP_DOMAIN` and re-push so the
   deployment records it.

---

## Make the repo look legit

An interviewer will spend 2 minutes on your GitHub profile before the
interview even starts. Spend 30 minutes making it convincing.

### Must-have

| Item | How |
|---|---|
| **Live URL at the top of the README** | Add a `### 🌐 Live Demo` line with the URL + a screenshot |
| **A green pipeline screenshot** | `docs/images/actions-success.png` (the placeholder list is in the README §18) |
| **The Trivy report screenshot** | Shows 0 Critical / 0 High |
| **The image-size comparison** | `docker images` side by side → proves the 86 % reduction |
| **A 2-minute screen recording** | Of a green run **and** a rollback drill |
| **Incremental git history** | One giant "initial commit" looks like a copy-paste; 20–40 meaningful commits look like real work |

### Nice-to-have

* A `README` "Architecture" diagram (already in the repo — Mermaid renders it).
* The rollback drill video — interviewers love this, it is rare.
* A pinned GitHub profile README linking to the project.
* `docs/images/` filled with your real screenshots.

### The demo video script (2 minutes)

```
0:00  Show the repo README, scroll to the architecture diagram
0:20  Open Actions → show a green run → "push karne pe sab kuch automatically hota hai"
1:00  Show the Trivy job → 0 Critical, 0 High
1:20  Open the EC2 terminal → docker compose ps → all healthy
1:40  Show the rollback drill → health fails → previous image restored
2:00  End on the live URL
```

---

## Cost reality

| Item | Cost |
|---|---|
| AWS `t3.micro` (new account, 12 months) | **₹0** |
| AWS `t3.micro` (older account) | ~₹700–1000 / month |
| Domain (optional) | ~₹700–1000 / year |
| Let's Encrypt certificate | **₹0** |
| GHCR storage (images) | **₹0** for public, free quota for private |
| GitHub Actions | **₹0** for public repos; 2,000 min/month free for private |
| Cloudflare quick tunnel | **₹0** |
| **Minimum to go live** | **₹0** (no domain, no HTTPS yet) |

### Protect your wallet

1. AWS → Billing → **Billing alarms** → alert at ₹500 and ₹1000.
2. **Stop the EC2 instance when you are not demoing** (the disk survives when
   stopped; it keeps the same IP if you use an Elastic IP).
3. Delete the instance *and* the EBS volume when the project ends — a stopped
   instance still bills for its volume.

---

## After the interview

The infrastructure is disposable; **the repo and the video are not**. Keep the
EC2 instance alive for the placement season, then shut it down. The repo with
screenshots, a green pipeline history and a rollback demo is what gets you the
offer.
