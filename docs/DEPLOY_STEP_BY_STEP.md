# 🧭 AWS par khud se deploy karna — step-by-step, chhote-chhote steps

> Ye guide **aapke haath se** likhi gayi hai. Koi "one magic command" nahi.
> Har step ke saath: **kya type karna hai**, **kya dikhna chahiye**, aur
> **gadbad ho to kya karna hai**.
>
> Total time: 2–3 ghante (pehli baar). Cost: ₹0 (AWS Free Tier, naye account par
> 12 mahine). Final result: `http://<aapka-permanent-IP>/` par dashboard live,
> aur uske baad `git push` se automatic deploy.

---

## 🗺️ Poora plan ek nazar mein

```
PHASE 0  GitHub repo banao + code push                (20 min)
PHASE A  AWS account taiyaar + billing alarm        (15 min)
PHASE B  EC2 server banao (Ubuntu 24.04)            (15 min)
PHASE C  Elastic IP lo -> PERMANENT address         (5 min)
PHASE D  Server me SSH se ghuso                      (5 min)
PHASE E  Swap + Docker install (manual commands)     (15 min)
PHASE F  deployer user + SSH key                    (10 min)
PHASE G  Code server par laao (git clone)           (10 min)
PHASE H  secrets.env + .env banao                   (15 min)
PHASE I  Pehla deploy: image build + compose up     (20 min)
PHASE J  Dashboard ko internet par verify karo      (5 min)
PHASE K  GitHub Actions ko command do (CI/CD on)    (25 min)
PHASE L  (Optional) Domain + HTTPS                  (30 min)
PHASE M  Roz ka kaam + paise bachana + band karna   (—)
```

**Har phase ke baad ek "✅ CHECKPOINT" hai.** Agla phase tabhi shuru karo jab
checkpoint pass ho jaye. Kahin atak jao to **Phase N (Troubleshooting)** dekho
ya mujhe error paste kar do — main usi step ka exact command de dunga.

---

# PHASE 0 — GitHub repo banao aur code push karo

**Ye sabse pehla step hai.** Kyun pehle? Kyunki EC2 server par code **git clone**
se jayega (Phase G), aur pipeline GitHub par hi chalegi (Phase K). Repo pehle
banega to baaki sab aasaan ho jayega.

> ⚠️ Yahan **koi secret nahi jayega**. `.pem`, `secrets.env`, `.env`, tokens —
> sab GitHub ke bahar rahenge. Project ka `.gitignore` ye pehle se block karta hai.

### 0.1 Repo public ya private? — pehle ye decide karo

| | **Public** (recommend) | **Private** |
|---|---|---|
| Interviewer ko repo bhejna | bas link | access dena padega |
| Resume me link | ✅ dikhta hai | ❌ kaam nahi karega |
| Recruiter ko code dikhta hai | ✅ | ❌ |
| Koi risk? | Code sab dekhte hain — **is project me koi secret nahi**, safe hai | — |

**Portfolio ke liye PUBLIC banao.** Is project me koi credential commit nahi
hai (check kiya hua), aur recruiter ko code dekhna hi point hai.

### 0.2 GitHub par repo create karo

1. Browser me `https://github.com/new` kholo.
2. **Repository name:** `devops-cicd-pipeline` (ya `devops-cicd-app`)
3. **Description:** `End-to-end CI/CD pipeline for a containerized Flask app — Docker, GitHub Actions, GHCR, Trivy, AWS EC2, Nginx, auto-rollback`
4. Visibility: **Public**
5. **Bahut important — ye teen checkbox KHAALI chhodo:**

   | Checkbox | Kya rakhna hai |
   |---|---|
   | Add a README file | ❌ **untick** |
   | Add .gitignore | ❌ **untick** (project me pehle se `.gitignore` hai) |
   | Choose a license | ❌ **untick** (project me pehle se `LICENSE` hai) |

6. **Create repository**

> **Kyun khaali chhoda?** Agar GitHub apna README/`.gitignore` bana dega to aapke
> local code se **conflict** hoga aur `git push` reject ho jayega
> (`failed to push some refs / Updates were rejected`). Beginner ki sabse common
> galti yahi hai.

### 0.3 Apne laptop par git check karo

Project folder me terminal kholo (jahan `Dockerfile`, `app/`, `README.md` hain):

```bash
cd path/to/devops-cicd-project
git --version
```

**Expected:** `git version 2.3x.x` ya `2.4x.x`.

`git: command not found` aaye to install karo:
- **Windows:** `https://git-scm.com/download/win` → install → **Git Bash** kholo
- **Mac:** `xcode-select --install` ya `brew install git`
- **Ubuntu/Debian:** `sudo apt install -y git`

### 0.4 Git ko apna naam/email batao (ek baar, poore system ke liye)

```bash
git config --global user.name "Aapka Naam"
git config --global user.email "aapka@email.com"
```

> Ye email GitHub ke email se **match karna chahiye**, warna commits par aapka
> profile picture/username nahi dikhega aur contribution graph khaali rahega.

### 0.5 Repo initialise karo

```bash
git init
```

**Expected:** `Initialized empty Git repository in .../devops-cicd-project/.git/`

Branch ka naam `main` rakho (GitHub ka default aur pipeline `main` par chalti hai):

```bash
git branch -M main
```

> `fatal: not a valid object name: 'main'` aaye? Matlab abhi koi commit nahi hai.
> Ye normal hai — aage 0.7 me commit karne ke baad ye command dobara chala lena,
> ya seedha `git init -b main` use karo.

### 0.6 Sabse pehle check karo: koi secret to nahi ja raha?

**Ye step skip mat karo.** Pehle dekho git kya-kya add karne wala hai:

```bash
git add -A
git status --short
```

Ab **dhyan se** list padho. Ye cheezein is list me **nahi honi chahiye**:

```
❌ .env                ❌ secrets.env        ❌ *.pem
❌ __pycache__/        ❌ htmlcov/           ❌ coverage.xml
❌ logs/               ❌ .venv/             ❌ instance/
```

Agar inme se koi dikh gaya, matlab `.gitignore` kaam nahi kar raha — pehle usse
theek karo, phir `git rm --cached <file>` chalao. (Is project ke `.gitignore` me
ye sab already hai, to normal case me clean rahega.)

Ek extra safety scan:

```bash
git diff --cached | grep -iE "BEGIN OPENSSH PRIVATE KEY|password=.+|SECRET_KEY=.+[A-Za-z0-9]{20}" || echo "CLEAN — no secrets staged"
```

**Expected:** `CLEAN — no secrets staged`

> Kuch mila to **turant** `git reset` chalao aur us file ko `.gitignore` me daalo.
> Ek baar secret GitHub par chala gaya to wo hamesha ke liye leak hai (history se
> hatana painful hai) — aur Gitleaks job bhi usi build ko fail kar degi.

### 0.6b Push se pehle CI ke lint gates khud chalao (30 sec)

Ye ek extra safety hai — jo CI fail karega wo aap yahin pakad loge:

```bash
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
make lint-ci
```

**Expected (last line):** `✅ CI lint job will pass`

> `make lint-ci` wahi 4 commands chalata hai jo GitHub Actions chalata hai, aur
> `requirements-dev.txt` ke **exact pinned versions** ke saath (ruff, black,
> shellcheck). Version mismatch hi "laptop par green, CI par red" ka sabse bada
> karan hota hai.

### 0.7 Pehla commit

```bash
git commit -m "feat: containerized Flask app with full CI/CD pipeline"
```

**Expected:**

```
[main (root-commit) 1a2b3c4] feat: ...
 120 files changed, 12000 insertions(+)
```

### 0.8 GitHub ko remote ke roop me jodo

Apne repo page par **Code** button → **HTTPS** tab → URL copy karo
(`https://github.com/<username>/devops-cicd-pipeline.git`), phir:

```bash
git remote add origin https://github.com/<aapka-username>/<repo-name>.git
git remote -v
```

**Expected:**

```
origin  https://github.com/<username>/<repo-name>.git (fetch)
origin  https://github.com/<username>/<repo-name>.git (push)
```

### 0.9 Push karo

```bash
git push -u origin main
```

**Password kya daalein?** GitHub account password **kaam nahi karta**. Do options:

**Option A — HTTPS + Personal Access Token (aasaan, beginner ke liye theek)**
1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token
2. Name: `git-push-laptop`, Expiration: `90 days`
3. Repository access: **All repositories** (ya sirf ye repo)
4. Permissions → Repository permissions → **Contents: Read and write**
5. Generate → token copy (`github_pat_...`)
6. Push karte waqt username = GitHub username, password = **token paste**

**Option B — SSH key (better, ek baar setup, phir kabhi password nahi)**

```bash
ssh-keygen -t ed25519 -C "laptop-github" -f ~/.ssh/github_laptop -N ""
cat ~/.ssh/github_laptop.pub        # pura output copy karo
```

GitHub → Settings → **SSH and GPG keys** → **New SSH key** → paste → Add.
Phir remote SSH wala use karo:

```bash
git remote set-url origin git@github.com:<username>/<repo-name>.git
ssh -T git@github.com          # "Hi <username>! You've successfully authenticated"
git push -u origin main
```

**Expected (push ke end me):**

```
To https://github.com/<username>/<repo-name>.git
 * [new branch]      main -> main
branch 'main' set up to track 'origin/main'.
```

### 0.10 GitHub par confirm karo

Browser me repo refresh karo:

- ✅ Files dikh rahi hain (`Dockerfile`, `app/`, `.github/workflows/ci.yml`, `docs/`)
- ✅ README GitHub par render ho raha hai (Mermaid diagram bhi)
- ✅ **Actions** tab me ek workflow run **khud se** shuru ho gaya hai

### 0.11 Pehla Actions run — kya expect karna hai

| Job | Result |
|---|---|
| 1 Lint & Format | ✅ green |
| 2 Unit Tests & Coverage | ✅ green |
| 3 Build Docker Image | ✅ green |
| 4 Security Scans (Trivy + Gitleaks) | ✅ green |
| 5 Integration Tests | ✅ green |
| 6 Push to GHCR | ✅ green |
| **7-9 Deploy** | ❌ **FAIL — ye expected hai** |

**Deploy job fail hoga kyunki GitHub secrets abhi nahi hain** (`EC2_HOST`,
`EC2_SSH_PRIVATE_KEY`, etc.). Ye galti nahi, sequence hai: secrets Phase K me
bharo, phir us run ko **Re-run failed jobs** kar dena.

Deploy job ka pehla step ab saaf-saaf bata deta hai (`::error::Deployment
secrets missing`) — confusing SSH error nahi aayega.

### 0.11b Dependabot 12 PR ek saath khol dega — unhe band kar do

`.github/dependabot.yml` ki wajah se GitHub turant kuch PR khol deta hai
(`build(deps): bump ...`, `build(deps-dev): bump ...`). Pehli baar dekh kar
panic mat karo — ye **aapka code nahi** hai, dependency updates hain.

**Portfolio ke liye abhi unhe band kar do:**

1. GitHub repo → **Pull requests** tab
2. Har Dependabot PR ke saamne checkbox tick karo → top par **Close pull
   request**
3. Sab band hone ke baad sirf aapka `feat: containerized Flask app...` PR/commit
   bacha rahega — repo clean dikhega

**Kyun band?** Abhi aap deploy set up kar rahe ho. 12 dep bumps ke saath
debug karna confuse karega. Dependabot monthly/weekly khud dobara khol dega jab
aap ready ho (aur tab CI bhi theek chal rahi hogi).

> Agar pura Dependabot hi band karna ho: repo → **Insights** → **Dependency
> graph** → **Dependabot** → PRs band. Ya `.github/dependabot.yml` delete kar
> do (par interview me "automated dependency updates" bolne ka point chala
> jayega).

> 💡 Agar aap chahte ho ki pehle push par deploy bilkul na chale, to Phase K tak
> ruk jao — ya push karte waqt branch `dev` par kaam karo aur `main` par merge
> tab karo jab secrets ready hon.

### 0.12 Repo ko "resume-worthy" banao (5 min, worth it)

Repo page par **⚙️ (gear) icon** → About section me:

- **Description:** upar wali line paste karo
- **Website:** deployment URL (Phase J/L ke baad bharo — `http://<Elastic IP>`)
- **Topics** (comma se separated, ye recruiter search me kaam aate hain):

```
devops  ci-cd  docker  github-actions  aws  ec2  flask  python  nginx  postgresql
trivy  containers  infrastructure  deployment  automation  ghcr  portfolio-project
```

- ✅ **Releases** → Phase K ke baad ek tag banao: `git tag -a v1.0.0 -m "First production release" && git push origin v1.0.0`

### 0.13 (Phase K ke baad) Branch protection on karo

`main` par seedha push band karo — PR + green checks ke baad hi merge.

Settings → **Branches** → **Add branch protection rule** →
Pattern: `main` → ye tick karo:

- ✅ Require a pull request before merging (1 approval)
- ✅ Require status checks to pass → select: `Lint`, `Test`, `Build`, `Security`
- ✅ Require branches to be up to date before merging
- ✅ Do not allow bypassing the above settings

Poora detail: **[BRANCH_PROTECTION.md](BRANCH_PROTECTION.md)**

> **Interview point:** "`main` is protected — every change goes through a PR with
> mandatory lint, test, build and security gates."

**✅ CHECKPOINT 0:** `https://github.com/<username>/<repo-name>` khulta hai, code
dikhta hai, Actions me pehla run chala, jobs 1–6 green. **Ab Phase A par jao.**

---

# PHASE A — AWS account taiyaar + safety

### A.1 AWS account banao (agar nahi hai)

1. Browser me kholo: `https://aws.amazon.com/free/`
2. **Create a Free Account** → email, password, account name.
3. Credit/debit card maangega (**₹2 tak ka temporary hold lagta hai**, wapas aa
   jata hai). Iske bina EC2 nahi milega.
4. Phone verification (OTP).
5. Support plan me **Basic support – Free** chuno.

> ⚠️ Root account sirf bill dekhne ke liye rakho. Roz ke kaam ke liye aage
> ek IAM user banaenge (A.3). Ye interview me bhi achha bolta hai.

### A.2 Region ko Mumbai par set karo

AWS console ke top-right corner me region name dikhta hai (jaise "N. Virginia").
Us par click karo → **Asia Pacific (Mumbai) ap-south-1** chuno.

**Kyun:** India se sabse kam latency + Kam se kam ₹ pricing ke liye same region.

> Poori guide me jahan bhi console use hoga, **region hamesha Mumbai hona
> chahiye**. Galti se dusra region khula to wahan aapka instance nahi dikhega
> aur aap panic karoge. Ye sabse common beginner galti hai.

### A.3 Billing alarm lagao (2 min, ye skip mat karo)

1. Top search bar me likho: `Billing` → **Billing and Cost Management**.
2. Left menu → **Budgets** → **Create budget**.
3. **Use a template** → template me **Monthly cost budget**.
4. Budget name: `portfolio-guard`
5. Budgeted amount: `5` USD (≈ ₹420)
6. Email: apna email
7. **Create budget**.

**✅ CHECKPOINT A:** Budgets list me `portfolio-guard` dikh raha hai. Email me
confirmation aaya.

---

# PHASE B — EC2 server banao

### B.1 EC2 console kholo

Top search bar → `EC2` → **EC2** service kholo.
Left sidebar me **Instances** par click karo.

### B.2 Launch instance wizard

**Launch instance** (orange button) dabao. Ab ek-ek field bharo:

| # | Field | Kya chunna hai |
|---|---|---|
| B.2.1 | **Name** | `devops-cicd-app` |
| B.2.2 | **Application and OS Image (AMI)** | **Ubuntu** → Quick start me **Ubuntu Server 24.04 LTS (HVM), SSD Volume Type**, architecture **64-bit (x86)** |
| B.2.3 | **Instance type** | `t3.micro` (Free tier eligible likha hoga) |
| B.2.4 | **Key pair (login)** | **Create new key pair** → name: `devops-cicd-deploy` → type: **ED25519** → format: **.pem** → **Create key pair** |
| B.2.5 | **Network settings** | **Create security group** (checkbox already ticked) |
| B.2.6 | Security group name | `devops-cicd-sg` |
| B.2.7 | **Rule 1** | Type `SSH`, Source type **My IP** (ye aapka ghar/college ka IP) |
| B.2.8 | **Add security group rule** → | Type `HTTP`, Source **Anywhere (0.0.0.0/0)` |
| B.2.9 | **Add security group rule** → | Type `HTTPS`, Source **Anywhere (0.0.0.0/0)` |
| B.2.10 | **Configure storage** | `20` GiB, **gp3** |

> **B.2.4 important:** `.pem` file turant download hogi. **AWS ise dobara kabhi
> nahi deta.** Ise `Downloads` se utha kar safe jagah rakho, naam badalna mat.

> **B.2.8/B.2.9:** Port **5432 (PostgreSQL) kabhi mat kholna.** Database Docker
> ke andar private rehta hai — yahi is project ka security point hai. Interview
> me ye poochha jata hai.

### B.3 Launch

Neeche **Launch instance** → **View all instances**.

**✅ CHECKPOINT B:** Instances list me `devops-cicd-app` dikhe, **Instance state
= Running**, **Status check = 2/2 checks passed** (2–3 minute lagega, refresh
karte raho).

---

# PHASE C — Elastic IP lo (yahi "permanent" ka raaz hai)

**Problem:** EC2 ka default public IP **instance stop/start karne par badal
jata hai**. Matlab aaj ka link kal kaam nahi karega — resume/interview ke liye
bekaar.

**Solution:** **Elastic IP** = fixed public IPv4 jo aapke account me reserved
rehta hai. Instance band karke chalu karo, IP wahi rahega.

### C.1 Elastic IP allocate karo

1. EC2 left sidebar → **Network & Security** → **Elastic IPs**.
2. **Allocate Elastic IP address** (orange button).
3. Network border group: default rehne do. **Allocate**.
4. Ab list me ek IP dikhega, jaise `13.235.44.10`. **Ise kahin note kar lo.**

### C.2 Instance ke saath associate karo

1. Us IP ko select karo → **Actions** → **Associate Elastic IP address**.
2. **Resource type:** `Instance`
3. **Instance:** `devops-cicd-app` chuno
4. **Associate**.

**✅ CHECKPOINT C:** Elastic IPs list me **Associated instance** column me
`devops-cicd-app / i-0abc...` dikh raha hai.

> 💡 **Interview line:** "I associated an Elastic IP so the deployment URL is
> stable across instance restarts — the default EC2 public IP changes on stop/start."
>
> ⚠️ **Paisa:** Elastic IP **free** hai jab tak woh kisi **running** instance se
> juda hai. Instance **stop** karke IP attached chhoda → thoda charge lagta hai.
> Poori tarah band karna ho to Phase M dekho.

---

# PHASE D — Server me SSH se ghuso

### D.1 .pem file ki permission theek karo

Terminal kholo (Windows: **PowerShell** ya **Git Bash**; Mac/Linux: Terminal).

`<IP>` ki jagah **aapka Elastic IP** likhna. Pehle file wali jagah jao:

```bash
cd ~/Downloads
```

Permission set karo:

```bash
# Mac / Linux / Git Bash
chmod 400 devops-cicd-deploy.pem
```

```powershell
# Windows PowerShell (chmod nahi hota, ACL se karte hain)
icacls.exe devops-cicd-deploy.pem /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

> **Kyun?** SSH mana kar deta hai agar key file "sabke liye readable" ho:
> `WARNING: UNPROTECTED PRIVATE KEY FILE!` — ye message aaye to bas upar wala
> command chala do.

### D.2 Login karo

```bash
ssh -i ~/Downloads/devops-cicd-deploy.pem ubuntu@13.235.44.10
```

Pehli baar ye sawaal aayega:

```
The authenticity of host '13.235.44.10' can't be established.
ED25519 key fingerprint is SHA256:....
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

`yes` likho aur Enter.

**Expected output:**

```
Welcome to Ubuntu 24.04.x LTS (GNU/Linux ...)
...
ubuntu@ip-172-31-x-x:~$
```

**✅ CHECKPOINT D:** Prompt `ubuntu@ip-172-31-...:~$` dikh raha hai. Aap server
ke andar ho.

> Agar `Connection timed out` aaye: security group me SSH ka source **My IP**
> hai, aur aapka internet IP badal gaya hoga (mobile hotspot / college wifi).
> Fix: EC2 → Security Groups → `devops-cicd-sg` → Inbound rules → SSH rule edit
> → source ko **My IP** dobara chuno → Save.

---

# PHASE E — Swap + Docker install (manual, command by command)

Yahan se sab commands **server ke andar** chalani hain.

### E.1 System update

```bash
sudo apt update && sudo apt upgrade -y
```

Expected: last line me `0 upgraded, 0 newly installed...` ya packages upgrade ho
jaenge. 2–4 minute.

### E.2 Swap file banao (1 GB RAM ka Sahara)

**Kyun:** `t3.micro` me sirf 1 GB RAM hai. Docker build ke waqt memory khatam
hokar process `Killed` ho jata hai. 2 GB swap isse bacha leta hai.

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

Verify:

```bash
free -h
```

**Expected (Swap line me 2.0Gi dikhna chahiye):**

```
               total        used        free
Mem:           957Mi       180Mi       500Mi
Swap:          2.0Gi          0B       2.0Gi
```

### E.3 Docker ke liye zaroori packages

```bash
sudo apt install -y ca-certificates curl gnupg
```

### E.4 Docker ka official GPG key add karo

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

> **Kyun `curl | gpg`?** Docker ki official install docs ka exact method hai —
> Ubuntu ke purane `docker.io` package ki jagah asli Docker Engine milta hai.

### E.5 Docker ka repository add karo

```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### E.6 Docker install karo

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### E.7 Version check (yahi checkpoint hai)

```bash
docker --version
docker compose version
```

**Expected:**

```
Docker version 27.x.x, build ...
Docker Compose version v2.3x.x
```

> `docker compose` (bina hyphen) chalta hai. Purana `docker-compose` nahi
> chahiye — ye project plugin wala use karta hai.

### E.8 Docker ko bina sudo chalane do (ubuntu user ke liye)

```bash
sudo usermod -aG docker ubuntu
```

Ab **logout karke** dobara login karo (group tab lagta hai):

```bash
exit
```

```bash
ssh -i ~/Downloads/devops-cicd-deploy.pem ubuntu@13.235.44.10
```

Test:

```bash
docker run --rm hello-world
```

**Expected:** `Hello from Docker!` wala message.

**✅ CHECKPOINT E:** `hello-world` chal gaya matlab Docker engine theek hai.

---

# PHASE F — `deployer` user + SSH key

**Kyun alag user?** Pipeline ko root nahi dena chahiye. Ek limited user
`deployer` banate hain jo sirf Docker chala sakta hai — least privilege.

### F.1 User banao (password ke bina)

```bash
sudo adduser --disabled-password --gecos "Deployment user" deployer
```

### F.2 Docker group me daalo

```bash
sudo usermod -aG docker deployer
```

### F.3 deployer ke ghar me .ssh folder banao

```bash
sudo install -d -m 700 -o deployer -g deployer /home/deployer/.ssh
```

### F.4 Jo key aapko server me laayi, wahi deployer ko bhi do

```bash
sudo cp /home/ubuntu/.ssh/authorized_keys /home/deployer/.ssh/authorized_keys
sudo chown deployer:deployer /home/deployer/.ssh/authorized_keys
sudo chmod 600 /home/deployer/.ssh/authorized_keys
```

**Iska matlab:** ab **wahi .pem** `ubuntu` aur `deployer` dono ke liye chalti hai.
Isi key ko baad me GitHub secret me daalenge.

### F.5 Test karo

```bash
ssh -i ~/Downloads/devops-cicd-deploy.pem deployer@13.235.44.10 'whoami; docker ps'
```

**Expected:**

```
deployer
CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS
```

(Abhi koi container nahi, sirf header — ye normal hai.)

**✅ CHECKPOINT F:** `deployer` likha aaya aur `docker ps` ne permission error
nahi diya.

---

# PHASE G — Code server par laao

### G.1 Zaroori folders banao

`deployer` ke roop me login karo (aage ke kaam isi user se):

```bash
exit
ssh -i ~/Downloads/devops-cicd-deploy.pem deployer@13.235.44.10
```

Ab folders:

```bash
sudo mkdir -p /opt/devops-cicd/{deploy,state,logs,backups}
sudo chown -R deployer:deployer /opt/devops-cicd
```

### G.2 Repo clone karo

Rep **public** hai to (URL **Phase 0.8** wala hi hai — `git remote -v` se bhi mil
jayega):

```bash
cd /opt/devops-cicd/deploy
git clone https://github.com/<aapka-username>/<repo-name>.git .
```

> **`.` (dot) mat bhoolna** — iska matlab "is folder ke andar clone karo",
> warna ek extra nested folder ban jata hai aur saare paths bigad jate hain.

Repo **private** hai to GitHub PAT maangega (username + password ki jagah
token). Token: GitHub → Settings → Developer settings → Personal access tokens
→ **Fine-grained** → repo select → **Contents: Read-only** → generate.

### G.3 Check karo kya-kya aaya

```bash
ls
```

**Expected:**

```
Dockerfile  app  docker-compose.prod.yml  docs  nginx  scripts  tests  wsgi.py ...
```

### G.4 Scripts ko executable banao

```bash
chmod +x scripts/*.sh
ls -l scripts/setup-ssl.sh
```

**Expected:** line ke shuru me `-rwxr-xr-x` (x = executable).

**✅ CHECKPOINT G:** `/opt/devops-cicd/deploy` me poora project hai.

---

# PHASE H — secrets.env aur .env banao

Do files chahiye. Dono **server par** banti hain, GitHub par **kabhi nahi**
jaati.

| File | Kaam |
|---|---|
| `secrets.env` | passwords (DB password, Flask SECRET_KEY) — mode 0600 |
| `.env` | compose ke liye image ka naam + tag + DB username/naam |

### H.1 Random password banao

```bash
openssl rand -hex 24
```

Output ko copy karo — jaise `9f3c1a...`. Ye **DB password** hai.

### H.2 Flask ka SECRET_KEY banao

```bash
python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
```

Output copy karo. Ye **SECRET_KEY** hai.

> **Kyun random?** Flask ise session/cookie sign karne ke liye use karta hai.
> Hardcoded ya chhota key = security bug. Interview me ye question aata hai.

### H.3 secrets.env banao

```bash
cat > /opt/devops-cicd/deploy/secrets.env <<'EOF'
POSTGRES_USER=appuser
POSTGRES_PASSWORD=YAHAN_DB_PASSWORD_PASTE_KARO
POSTGRES_DB=devops_cicd
SECRET_KEY=YAHAN_SECRET_KEY_PASTE_KARO
APP_DOMAIN=13.235.44.10
CERTBOT_EMAIL=aapka@email.com
EOF
```

> `<<'EOF'` me **single quotes important hain** — warna shell `$` ko expand kar
> dega aur password kharab ho jayega.
>
> `13.235.44.10` ki jagah **aapka Elastic IP**. Abhi domain nahi hai to IP hi
> `APP_DOMAIN` hai.

### H.4 File ko lock karo

```bash
chmod 600 /opt/devops-cicd/deploy/secrets.env
ls -l /opt/devops-cicd/deploy/secrets.env
```

**Expected:** `-rw-------` (sirf owner padh sakta hai).

### H.5 .env banao

```bash
cat > /opt/devops-cicd/deploy/.env <<'EOF'
APP_IMAGE=devops-cicd-app
APP_TAG=manual
APP_NAME=devops-cicd-app
APP_VERSION=1.0.0
APP_DOMAIN=13.235.44.10
POSTGRES_USER=appuser
POSTGRES_DB=devops_cicd
EOF
```

> `APP_TAG=manual` sirf **pehle manual deploy** ke liye hai. Phase K ke baad
> pipeline ise `sha-<commit>` se replace kar degi (immutable tag — koi
> `latest` nahi, kyunki `latest` se rollback possible nahi hota).

### H.6 Check karo ki values sahi hain

```bash
grep POSTGRES_USER /opt/devops-cicd/deploy/.env
```

**✅ CHECKPOINT H:** `secrets.env` me asli password hai (placeholder text nahi),
aur `chmod 600` laga hai.

---

# PHASE I — Pehla deploy: image build + stack chalao

### I.1 Image build karo (server par, ~4–8 min)

```bash
cd /opt/devops-cicd/deploy
docker build -t devops-cicd-app:manual .
```

**Expected (last 3 lines):**

```
 => => naming to docker.io/library/devops-cicd-app:manual
 => => unpacking to docker.io/library/devops-cicd-app:manual
```

> `Killed` ya `signal: killed` aaya? **Memory khatam** ho gayi. Fix:
> `free -h` se swap check karo (E.2), phir build dobara:
> `docker build --memory=700m -t devops-cicd-app:manual .`

### I.2 Size dekho (honest number, resume ke liye)

```bash
docker images devops-cicd-app
```

**Expected:** `manual` tag, size lagbhag **160–200 MB**.

> **Kyun itna?** Base `python:3.12-slim` (≈44 MB compressed) + dependencies.
> Multi-stage build ne compilers aur pip cache hata diye. Actual aur number bhi
> dekh sakte ho: `docker image inspect` + `docker history`.

### I.3 Stack chalao

```bash
docker compose --env-file .env --env-file secrets.env \
  -f docker-compose.prod.yml up -d
```

Pehli baar images download hongi (postgres, nginx) — 1–2 min.

**Expected:**

```
 ✔ Container devops-cicd-db      Healthy
 ✔ Container devops-cicd-app     Healthy
 ✔ Container devops-cicd-nginx   Started
```

### I.4 Containers dekho

```bash
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml ps
```

**Expected:** teen containers, `db` aur `app` ka status **healthy**,
`nginx` **running**, ports me `0.0.0.0:80->80/tcp` aur `443->443`.

> `app` **starting** hi dikh raha hai to 20 second ruk kar dobara chalao —
> healthcheck ka `start_period` 20s hai.

### I.5 Andar se test karo

```bash
curl -s http://localhost/health | python3 -m json.tool
```

**Expected:**

```json
{
    "status": "healthy",
    "checks": { "database": { "status": "healthy", ... } },
    "version": "1.0.0",
    "environment": "production",
    "timestamp": "..."
}
```

### I.6 Host metrics collector chalao (dashboard ke CPU/RAM/disk ke liye)

```bash
sudo bash scripts/collect-metrics.sh --install
sudo systemctl list-timers | grep metrics
```

**Expected:** ek line jisme `collect-metrics.timer` dikhe.

> **Kyun alag script?** Container ko Docker socket ya host shell nahi dena
> chahiye (security). Host ka chhota collector JSON file likhta hai, container
> use **read-only** padhta hai.

**✅ CHECKPOINT I:** `/health` JSON me `"status": "healthy"` aur
`"database": {"status": "healthy"}`.

---

# PHASE J — Internet par verify karo (laptop se)

Ab **apne laptop** ka terminal (server wala nahi).

### J.1 Browser kholo

```
http://13.235.44.10/
```

(`<Elastic IP>` lagao.)

**Expected:** dark DevOps dashboard — sidebar, metric cards, "Application
Health", "Docker Monitoring", etc.

### J.2 curl se endpoints check karo

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://13.235.44.10/
curl -s http://13.235.44.10/health | head -c 200; echo
```

**Expected:** pehli line `200`, dusri line JSON.

### J.3 Dashboard par kuch "Unavailable" dikh raha hoga — ye sahi hai

| Card | Abhi kya dikhega | Kab bharega |
|---|---|---|
| CPU / Memory / Disk | values | I.6 ke baad (1 min) |
| Docker containers | values | I.6 ke baad |
| Latest deployment | Unavailable | Phase K ke baad (pipeline history likhti hai) |
| GitHub Actions | Not configured | Phase K |
| Trivy scan | Not configured | Phase K (CI me chalta hai) |

> **Ye jaan-boojh kar hai.** Dashboard kabhi fake data nahi banata — na ho to
> "Unavailable" likhta hai. Interview me ye honesty ka point hai.

**✅ CHECKPOINT J:** `http://<Elastic IP>/` par dashboard khul raha hai, aur
`/health` JSON de raha hai. **Yahan tak aapne manually deploy kar liya. Aage
automation hai.**

---

# PHASE K — GitHub Actions ko command do (CI/CD on)

Ab woh kaam jo interview me sabse zyada poochha jata hai: **`git push` → image
build → GHCR → server par deploy → health check → fail par rollback**.

### K.1 GHCR read-only token banao

Server ko sirf image **pull** karni hai, push nahi.

1. GitHub → apna profile photo → **Settings**
2. Left bottom → **Developer settings**
3. **Personal access tokens** → **Fine-grained tokens** → **Generate new token**
4. Name: `ghcr-read-ec2`
5. Expiration: `90 days`
6. **Repository access:** Only select repositories → apna repo
7. **Permissions → Repository permissions → Packages: Read-only**
8. **Generate token** → token copy karo (`github_pat_...`) — dobara nahi dikhega.

### K.2 GitHub secrets bharo

Repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**. Ek-ek karke ye 7 bharo:

| Secret name | Value |
|---|---|
| `EC2_HOST` | `13.235.44.10` (aapka Elastic IP) |
| `EC2_USER` | `deployer` |
| `EC2_SSH_PRIVATE_KEY` | **poore `.pem` file ka content** — `-----BEGIN OPENSSH PRIVATE KEY-----` se `-----END...` tak |
| `GHCR_USERNAME` | aapka GitHub username |
| `GHCR_TOKEN` | K.1 ka token |
| `APP_DOMAIN` | `13.235.44.10` |
| `PRODUCTION_ENV` | `production` |

**Optional (sirf link ke liye):** repo → Settings → Secrets and variables →
Actions → **Variables** tab → **New repository variable** → Name `APP_DOMAIN`,
value `13.235.44.10`.

> Isse Actions ke run page par environment ka clickable URL dikhta hai. Ye
> **variable** hai, **secret** nahi — secret rakhne se workflow invalid ho jata
> hai (`secrets` `environment.url` me allowed nahi hai).

**`.pem` ka content kaise copy karein:**

```bash
cat ~/Downloads/devops-cicd-deploy.pem
```

Pura output (BEGIN aur END line samet) copy karke paste karo.

> **Kabhi mat karo:** ye key ya token code me commit karna, `.env` push karna,
> ya screenshot me dikhana. `.gitignore` in files ko already block karta hai.

### K.3 (Optional, recommended) GitHub Environment banao

Settings → **Environments** → **New environment** → naam `production` →
**Required reviewers** me apna naam → Save.

Iska matlab: har production deploy aapki **approval** ke baad chalega. Interview
me bolne layak point: "production deploys are gated behind manual approval."

### K.4 Code push karo

**Apne laptop** par, project folder me:

```bash
git status
git add -A
git commit -m "chore: aws deployment configured"
git push origin main
```

> Agar koi change nahi hai (`nothing to commit`), koi baat nahi — **Phase 0.11**
> wala pichla run hi kaafi hai. Usko kholo → top-right **Re-run failed jobs** →
> ab deploy job bhi green hona chahiye, kyunki secrets aa gaye hain.

### K.5 Pipeline dekho

GitHub repo → **Actions** tab → latest run kholo.

**Expected jobs (green hote hue):**

```
1 | Lint & Format Check
2 | Unit Tests & Coverage
3 | Build Docker Image
4 | Security Scans (Trivy + Gitleaks)
5 | Integration Tests
6 | Push to GHCR
7-9 | Deploy, Validate & Rollback
```

Total: 6–10 minute.

### K.6 Deploy job ka log dekho — kya hota hai andar

`7-9 | Deploy, Validate & Rollback` kholo. Steps:

1. SSH key likhi
2. **EC2 host key pin hui**
3. `docker login ghcr.io`
4. `rsync` se compose/nginx/scripts server par gaye
5. `scripts/deploy.sh --image ghcr.io/... --tag sha-<commit>` chala
6. Health gate: `/health` 200 mila? → success. Nahi mila? → **auto rollback**

### K.7 Server par confirm karo

```bash
ssh -i ~/Downloads/devops-cicd-deploy.pem deployer@13.235.44.10
```

```bash
cd /opt/devops-cicd/deploy
cat /opt/devops-cicd/state/current-image
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml ps
```

**Expected:** `ghcr.io/<user>/<repo>:sha-1a2b3c4` aur teen healthy containers.

### K.8 Dashboard par ab real deployment data

`http://13.235.44.10/` refresh karo → **Latest Deployment** card me SHA + time,
**Deployments** section me history, **GitHub Actions** card me workflow status.

**✅ CHECKPOINT K:** Ek `git push` ke baad Actions sab green, aur dashboard
`sha-<commit>` dikha raha hai. **Ye poora project complete hai.**

---

# PHASE L — (Optional) Domain + HTTPS

IP-based URL (`http://13.235.44.10`) kaam karta hai, par resume par
`https://devops.yourname.in` zyada professional lagta hai. Cost ≈ ₹700–1000/saal.

### L.1 Domain lo

Namecheap / GoDaddy / Hostinger / Cloudflare Registrar — `.in` sasta padta hai.

### L.2 DNS A record banao

Domain ke DNS panel me:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `devops` (ya `@` root ke liye) | aapka Elastic IP | Automatic |

10–30 min me propagate hota hai. Check karo:

```bash
dig +short devops.yourdomain.com
```

**Expected:** aapka Elastic IP.

### L.3 Security group check

EC2 → Security Groups → `devops-cicd-sg` → Inbound me **80 aur 443 dono
0.0.0.0/0** se open hone chahiye (Let's Encrypt verification ke liye).

### L.4 UFW (server firewall) check

```bash
sudo ufw status
```

Nahi chalu hai to:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
```

### L.5 Certificate issue karo

```bash
cd /opt/devops-cicd/deploy
sudo bash scripts/setup-ssl.sh devops.yourdomain.com
```

Script ye karti hai: Certbot se certificate → nginx ka HTTPS vhost render →
HTTP vhost hatao → Nginx reload → renewal timer.

**Expected (end):**

```
[ssl] Certificate installed. https://devops.yourdomain.com is live.
```

### L.6 Verify

```bash
curl -sI https://devops.yourdomain.com/health | head -3
```

**Expected:** `HTTP/2 200` + `strict-transport-security` header.

Browser me bhi kholo — 🔒 lock icon dikhna chahiye.

### L.7 GitHub secret update karo

`APP_DOMAIN` secret ki value `devops.yourdomain.com` kar do, warna Actions ka
environment URL galat rahega.

**✅ CHECKPOINT L:** `https://devops.yourdomain.com/` par dashboard + valid
certificate.

---

# PHASE M — Roz ka kaam, paise bachana, band karna

### M.1 Rozmarra commands (server par)

```bash
cd /opt/devops-cicd/deploy

# status
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml ps

# logs (live)
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml logs -f --tail=50 app

# restart
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml restart app
```

### M.2 Manual rollback (pipeline ke bahar)

```bash
bash scripts/rollback.sh
```

Ye `/opt/devops-cicd/state/previous-image` wale image par wapas jaata hai.
Dashboard ke **Deployments** section me rollback entry bhi aa jaati hai.

### M.3 Instance stop (paisa bachao, URL na badlo)

EC2 → Instances → select → **Instance state** → **Stop instance**.

- Elastic IP **attached** rehne se woh reserved rehta hai — **IP wahi rahega**.
- Stopped instance ka compute charge **zero**, par attached EIP ka chhota IPv4
  charge lag sakta hai (approx $3.6/month).
- Wapas chalu: **Start instance** → same IP → site wapas live (containers
  `restart: unless-stopped` ki wajah se khud uth jaenge).

### M.4 Poora teardown (project khatam / naya account)

Order important hai:

1. EC2 → Instances → **Terminate instance**
2. EC2 → **Elastic IPs** → select → **Actions** → **Release Elastic IP** ← ye
   step bhoolne par charge chalta rehta hai
3. EC2 → Security Groups → `devops-cicd-sg` delete
4. EC2 → Key Pairs → `devops-cicd-deploy` delete
5. Billing → Budgets → budget delete
6. GitHub → Settings → delete secrets + PAT

---

# 🩺 Troubleshooting — jo galtiyan sabko hoti hain

### Saare runs 1–3 second me red ho gaye (`startup_failure`)

**Symptom:** Actions list me har run **0m 1s / 0m 3s** me Failure, aur log khaali
ya "Invalid workflow file" jaisa message.

**Matlab:** workflow start hi nahi hua — koi test fail nahi hua. Sabse common
wajah: `secrets` context ka aise jagah use karna jahan allowed nahi hai (jaise
`environment.url`), ya kisi job ka `outputs` define na karna jabki use ho raha
ho.

Is project me ye **already fix ho chuka hai** (v1.1 me). Agar aapke repo me
purana `ci.yml` hai, to latest `ci.yml` push karo.

**Verify karne ka local tarika** (workflow file ko GitHub par bhejne se pehle):

```bash
# actionlint — GitHub Actions ka linter
curl -fsSL https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz \
  | tar xz actionlint
./actionlint .github/workflows/ci.yml
```

Kuch output aaya = workflow galat hai. Khaali output = syntax theek hai.

### Lint job red: `Shellcheck the deployment scripts` fail

**Symptom:** jobs 1-3 fail, aur log me `SC2317 (info): Command appears to be
unreachable` — function ke andar ki har line par.

**Why:** shellcheck ko nahi pata ki `trap on_exit EXIT` se wo functions call
hote hain, isliye wo unhe "unreachable" samajh leta hai. Ye **false positive**
hai (shellcheck ne baad me is check ka naam `SC2329` kar diya).

**Fix (already applied in this repo):** function ke theek upar
`# shellcheck disable=SC2329,SC2317` — dono naam, kyunki purane aur naye
shellcheck dono chal sakte hain.

> **Sabak:** GitHub runner ka shellcheck version aapke laptop se alag ho sakta
> hai. Isliye push se pehle ye chalao:
> ```bash
> make lint-ci        # CI ka exact lint job, same pinned versions
> ```
> Isse 90% "CI red, laptop green" wale surprises khatam ho jate hain.

### Lint job red: `Run unit tests (SQLite)` fail — par tests pass hote hain

**Symptom:** lint ke 4 steps green, phir `Run unit tests (SQLite)` red. Log me:

```
ERROR: usage: __main__.py [options] [file_or_dir] [file_or_dir] [...]
__main__.py: error: argument --color: invalid choice: 'always'
```

**Why:** pytest ka `--color` flag sirf `yes` / `no` / `auto` leta hai.
`--color=always` **invalid** hai — pytest start hone se pehle hi argument parsing
me mar jata hai. Isliye ek bhi test nahi chala, aur "tests fail" jaisa dikhta hai.

**Fix (already applied in this repo):**

```yaml
pytest -v --color=yes     # ✅ pehle: --color=always ❌
```

> **Sabak:** jab CI me tests "fail" hon par laptop par `pytest -q` green ho, to
> **pehle log me `ERROR: usage:` dhoondho**. Wo argument/config error hota hai,
> test failure nahi. Aur hamesha CI wale **exact command** se local test karo
> (`make ci`), `pytest -q` se nahi.

### Job `10 | Publish the dashboard status` red ho raha hai par deploy nahi hua

**Symptom:** step `Add the EC2 host key` fail, ya `ssh-keyscan` ka error.

**Why:** `EC2_HOST` secret khaali hai, to `ssh-keyscan -H ""` fail hota hai.
Ye job `always()` par chalti hai, isliye deploy skip hone ke baad bhi try karti
hai.

**Fix (already applied):** job ke pehle step me ek **preflight** hai jo
`EC2_HOST` check karta hai; na hone par baaki steps **skip** ho jate hain aur ek
`::notice` aata hai. Sirf Phase K ke baad ye job asli kaam karega.

### "Permission denied (publickey)"
- `.pem` ki permission galat → D.1 dobara.
- User galat → `ubuntu@` ya `deployer@` check karo.
- Security group me SSH source **My IP** hai, aur aapka IP badal gaya →
  rule edit karke naya "My IP" chuno.

### "Connection timed out"
- Instance running hai? (CHECKPOINT B)
- SSH rule ka source? (upar wala fix)
- College/office wifi port 22 block karta hai → mobile hotspot try karo.

### `http://<IP>/` nahi khul raha
```bash
# server par
sudo ss -tlnp | grep -E ':80|:443'
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml ps
```
- Port 80 sun raha hai par bahar se nahi khul raha → **security group me HTTP
  (80) rule missing**.
- Container `unhealthy` → `docker compose ... logs app` dekho.

### Build ke waqt `Killed`
RAM khatam. `free -h` se swap check karo, ya:
```bash
docker build --memory=700m -t devops-cicd-app:manual .
```

### `POSTGRES_PASSWORD is required` jaisa error
`.env`/`secrets.env` me value missing, ya compose ko files nahi di gayi.
Sahi command:
```bash
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml up -d
```

### `app` container baar-baar restart ho raha hai
```bash
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml logs --tail=80 app
```
- `could not connect to server` → DB abhi healthy nahi, 30s ruko.
- `password authentication failed` → `secrets.env` ka password badal gaya par
  purana `pgdata` volume purana password yaad rakhta hai. Fix:
  ```bash
  docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml down
  docker volume rm devops-cicd-prod_pgdata   # ⚠️ data delete — demo data hi hai
  docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml up -d
  ```

### Actions me "Permission denied (publickey)" deploy job me
- `EC2_USER` = `deployer` hai? (Phase F)
- `EC2_SSH_PRIVATE_KEY` me poora key hai (BEGIN/END samet)? Aadha copy hua to fail.
- Test locally: `ssh -i key.pem deployer@IP whoami` → `deployer` aana chahiye.

### Actions me "Host key verification failed"
`EC2_SSH_KNOWN_HOSTS` secret bhara hai par IP badal gaya / mismatch. Fix: secret
ko **khaali/delete** karo — workflow phir `ssh-keyscan` se khud pin karega.

### Actions me `docker login ghcr.io` fail (denied)
- PAT expire ho gaya → naya token.
- `GHCR_USERNAME` me email nahi, **username** hona chahiye.
- Token ke permissions me **Packages: Read** hai?

### Dashboard par sab "Unavailable"
- CPU/RAM/disk: `sudo systemctl list-timers | grep metrics` — timer chalu hai?
  Nahi to `sudo bash scripts/collect-metrics.sh --install`.
- Deployments: abhi sirf manual deploy hua hai, pipeline ne history nahi likhi.
- GitHub Actions: `GITHUB_TOKEN`/repo info config nahi hai → "Not configured"
  dikhana **sahi behaviour** hai.

### Domain par site nahi khul rahi (Phase L ke baad)
1. `dig +short devops.yourdomain.com` → IP aana chahiye.
2. Security group 80/443 open?
3. `sudo bash scripts/setup-ssl.sh <domain>` ka output — Certbot error to
   `sudo docker run --rm -v devops-cicd-prod_certbot_www:/var/www/certbot nginx:alpine ls /var/www/certbot` se challenge path check.

---

# 📋 Copy-paste cheat sheet (poore server setup ka nichod)

Sirf **reference** ke liye — pehli baar upar ke phases hi follow karo.

```bash
# ---- PHASE E: system + swap + docker ----
sudo apt update && sudo apt upgrade -y
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile
sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker ubuntu

# ---- PHASE F: deployer user ----
sudo adduser --disabled-password --gecos "Deployment user" deployer
sudo usermod -aG docker deployer
sudo install -d -m 700 -o deployer -g deployer /home/deployer/.ssh
sudo cp /home/ubuntu/.ssh/authorized_keys /home/deployer/.ssh/authorized_keys
sudo chown deployer:deployer /home/deployer/.ssh/authorized_keys
sudo chmod 600 /home/deployer/.ssh/authorized_keys

# ---- PHASE G: code ----
# (deployer ke roop me)
sudo mkdir -p /opt/devops-cicd/{deploy,state,logs,backups}
sudo chown -R deployer:deployer /opt/devops-cicd
cd /opt/devops-cicd/deploy && git clone <repo-url> . && chmod +x scripts/*.sh

# ---- PHASE H: env files ---- (values apne daalo!)
# secrets.env aur .env -> upar H.3 / H.5 dekho

# ---- PHASE I: pehla deploy ----
docker build -t devops-cicd-app:manual .
docker compose --env-file .env --env-file secrets.env -f docker-compose.prod.yml up -d
curl -s http://localhost/health
sudo bash scripts/collect-metrics.sh --install
```

> 💡 `scripts/setup-server.sh` ye Phase E+F ka kaam **ek saath** kar deta hai.
> Pehli baar **manually** karna seekho (yahi asli samajh hai), uske baad
> dobara server banana ho to script use kar sakte ho.
