# 🛡️ Branch Protection for `main`

> Goal: nobody (including you, on a tired Friday night) can change the code
> that is running in production without the pipeline saying yes first.
>
> **Note:** the exact wording of the settings screen depends on your plan and
> on whether the repository is public or private. Public repositories on the
> free plan get the classic *branch protection rules*; private repositories on
> free/team plans may only offer the newer *rulesets*. **Both paths are
> documented below** — pick the one your screen shows.

---

## What you want to achieve

| Rule | Effect |
|---|---|
| No direct pushes to `main` | Every change arrives through a pull request |
| Pull request required | A PR must exist before the branch can be updated |
| At least one approval | Somebody else (or a second pair of eyes) reviews the code |
| Required status checks | The CI pipeline must be green before merging |
| Force-push blocked | Nobody can rewrite the history of `main` |
| Deletion blocked | `main` cannot be deleted |
| Linear history *(optional)* | No merge commits — a clean, readable `git log` |

---

## Method A — Branch protection rules (classic UI)

> **Repository → Settings → Branches → Branch protection rules → Add rule**

### A.1 Create the rule

| Field | Value |
|---|---|
| **Branch name pattern** | `main` |
| **Protect matching branches** | ✅ enabled |

### A.2 Enable the rules

Tick these boxes:

#### 1. Require a pull request before merging

* ✅ **Require a pull request before merging**
* ☐ *Require approvals* — leave off if you are working alone (a repository
  cannot approve its own PR; with this on you would need a second account)
* ✅ *Dismiss stale pull request approvals when new commits are pushed*
* ✅ *Require review from Code Owners* — add a `CODEOWNERS` file (optional,
  see below)

#### 2. Require status checks to pass

* ✅ **Require status checks to pass before merging**
* **Status checks that are required** — search for and add:
  * `1-3 | Checkout, Lint & Test`
  * `4 | Build Docker image`
  * `5 | Trivy security scan`

  > Add at least the first one — it is the gate that matters most. Add all
  > three for a stricter policy.

* ✅ *Require branches to be up to date before merging*

#### 3. Block force pushes and deletions

* ✅ **Do not allow bypassing the above settings** (this prevents admins from
  pushing straight to `main`)
* ✅ **Do not allow force pushes**
* ✅ **Do not allow deletions**

#### 4. Linear history (recommended)

* ✅ **Require linear history**

### A.3 Save

Click **Create rule** / **Save changes**.

---

## Method B — Rulesets (newer UI)

> **Repository → Settings → Rules → Rulesets → New ruleset → New repository ruleset**

| Field | Value |
|---|---|
| **Ruleset Name** | `main-protection` |
| **Enforcement status** | Active |
| **Target branches** | `main` (use `refs/heads/main` or the tag `main`) |

Then click **Add rules**:

| Rule | Configuration |
|---|---|
| **Restrict deletions** | Block |
| **Require a pull request before merging** | ✅ Required; set *Required approvals* = **1** (or 0 if you work solo) and enable *Dismiss stale reviews* + *Require conversation resolution* |
| **Require status checks to pass** | ✅ Required; add `1-3 | Checkout, Lint & Test`, `4 | Build Docker image`, `5 | Trivy security scan` |
| **Require linear history** | ✅ |
| **Block force pushes** | Block |

Click **Create** and confirm the ruleset is **Active**.

---

## How to verify it works

### Test 1 — a direct push is rejected

```bash
git checkout main
echo "test" >> README.md
git commit -am "test: direct push to main"
git push origin main
```

**Expected output:**

```
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs to 'https://github.com/YOUR_USERNAME/devops-cicd-project.git'
hint: Updates were rejected because the tip of your current branch is behind
```

or

```
remote: error: GH006: Protected branch update failed for refs/heads/main.
```

### Test 2 — a pull request is required

```bash
git checkout -b feature/hello
echo "hello" > hello.txt
git add hello.txt && git commit -m "feat: add hello"
git push origin feature/hello
```

Open the PR on GitHub → the status checks run → **Merge** is only enabled once
they are green.

### Test 3 — a failing check blocks the merge

Break something on the branch:

```bash
echo "def broken(:" >> app/routes.py
git commit -am "test: broken"
git push
```

**Expected:** the `1-3 | Checkout, Lint & Test` check turns red and the
**Merge pull request** button becomes unusable (or GitHub offers
"Merge with merge queue" only after the checks pass).

### Test 4 — merging triggers the deployment

Merge the PR → the pipeline runs on the merge commit → the **deploy** job
pushes the new SHA tag to EC2.

---

## CODEOWNERS (optional but impressive)

Create `.github/CODEOWNERS`:

```
# Default owners for everything
*                       @YOUR_USERNAME

# The CI/CD pipeline needs a second pair of eyes
/.github/workflows/    @YOUR_USERNAME @SECOND-REVIEWER
/Dockerfile*           @YOUR_USERNAME
/scripts/              @YOUR_USERNAME
/nginx/                @YOUR_USERNAME
```

Then tick **Require review from Code Owners** in the protection rule.

---

## Common problems

| Symptom | Cause | Fix |
|---|---|---|
| `GH006: Protected branch update failed` | The rule is active and you pushed directly | Expected — open a PR instead |
| The merge button stays grey | A required check has not finished, or the branch is not up to date | Open the *Checks* tab; enable *Require branches to be up to date* only if you want strictness |
| "At least 1 approving review is required by reviewers with write access" | Self-approval is not possible | Add a second maintainer, or set the approval requirement to 0 |
| The checks never appear in the list | The check name does not match exactly | Copy the exact name from the *Checks* tab |
| A required check blocks every merge forever | The workflow file itself was renamed | Update the required-checks list |

---

## Optional: require a successful deployment before merging

A stricter pattern is to make the **deploy** job a required check as well.
That way a PR can only be merged after the new version has been deployed and
verified against the *staging* environment.

In this repository the deploy job only runs on `main`, so it cannot be a
required check for PRs. To implement it, add a second workflow
(`.github/workflows/deploy-staging.yml`) that deploys PRs to a staging host and
name the job consistently — then add that job name to the required checks.

---

## What to say in an interview

> *"Our `main` branch is protected: direct pushes are impossible, every change
> goes through a pull request that must pass Ruff, Black, ShellCheck, the full
> Pytest suite against both SQLite and a real PostgreSQL service container, a
> Docker build and a Trivy vulnerability scan with zero Critical/High findings.
> Only after the merge does the pipeline deploy to EC2, and the deployment is
> only considered successful once `/health` returns 200 — otherwise it
> automatically rolls back."*
