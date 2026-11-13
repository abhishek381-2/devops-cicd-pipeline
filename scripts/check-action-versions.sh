#!/usr/bin/env bash
# =============================================================================
# check-action-versions.sh - verify every GitHub Action referenced by a workflow
# actually exists, BEFORE you push.
#
# Why this exists
#   GitHub resolves `uses: owner/repo@ref` at job start-up. If the ref does not
#   exist (typo, deleted tag, wrong tag scheme such as `0.28.0` vs `v0.28.0`),
#   the job fails with:
#
#       "Set up job" -> Unable to resolve action `owner/repo@ref`,
#                       unable to find version `ref`
#
#   That failure appears before a single step runs, so the log looks empty and
#   it is easy to blame your own code. Run this script first instead.
#
# Usage
#   ./scripts/check-action-versions.sh                       # all workflows
#   ./scripts/check-action-versions.sh .github/workflows/ci.yml
#   GITHUB_TOKEN=ghp_xxx ./scripts/check-action-versions.sh  # avoid rate limits
#
# Exit codes
#   0  every referenced action/ref resolved
#   1  at least one reference could not be resolved
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"

log()  { printf '\033[0;36m[actions]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[actions]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[actions]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[actions][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required."

# --------------------------------------------------------------------------- #
# Collect the `uses:` references
# --------------------------------------------------------------------------- #
if [[ $# -gt 0 ]]; then
    FILES=("$@")
else
    shopt -s nullglob
    FILES=("${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml)
    shopt -u nullglob
fi
[[ ${#FILES[@]} -gt 0 ]] || die "No workflow files found in ${WORKFLOW_DIR}"

REFS_FILE="$(mktemp)"
trap 'rm -f "${REFS_FILE}"' EXIT

for f in "${FILES[@]}"; do
    [[ -f "${f}" ]] || die "File not found: ${f}"
    # `uses: owner/repo@ref` or `uses: owner/repo/path@ref`
    # Local composite actions (`uses: ./.github/actions/x`) contain no `@`.
    grep -oE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+@[^[:space:]]+' "${f}" \
        | sed -E 's/.*uses:[[:space:]]*//' >>"${REFS_FILE}" || true
done

sort -u "${REFS_FILE}" -o "${REFS_FILE}"

TOTAL="$(grep -c . "${REFS_FILE}" || true)"
[[ "${TOTAL}" -gt 0 ]] || die "No 'uses: owner/repo@ref' entries found."

log "Checking ${TOTAL} unique action reference(s) ..."
echo

# --------------------------------------------------------------------------- #
# Resolve each one: ask the API for the tag / branch / commit
# --------------------------------------------------------------------------- #
AUTH=()
[[ -n "${GITHUB_TOKEN:-}" ]] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

FAILED=0
CHECKED=0

while IFS= read -r ref; do
    [[ -z "${ref}" ]] && continue
    CHECKED=$((CHECKED + 1))

    target="${ref%@*}"          # owner/repo or owner/repo/sub/path
    version="${ref##*@}"        # tag, branch or SHA
    owner="${target%%/*}"
    rest="${target#*/}"
    repo="${rest%%/*}"

    # A full 40-char SHA is always valid as long as the repo exists.
    if [[ "${version}" =~ ^[0-9a-f]{40}$ ]]; then
        url="https://api.github.com/repos/${owner}/${repo}"
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 20 "${AUTH[@]}" "${url}")"
        if [[ "${code}" == "200" ]]; then
            ok "  ${ref}  (commit SHA)"
        else
            printf '\033[0;31m[actions][ERROR]\033[0m  %s  (repository not reachable: HTTP %s)\n' "${ref}" "${code}"
            FAILED=$((FAILED + 1))
        fi
        continue
    fi

    # Tag or branch: /repos/{o}/{r}/git/ref/(tags|heads)/{version}
    found=""
    for refkind in tags heads; do
        url="https://api.github.com/repos/${owner}/${repo}/git/ref/${refkind}/${version}"
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 20 "${AUTH[@]}" "${url}")"
        if [[ "${code}" == "200" ]]; then
            found="${refkind}"
            break
        fi
        [[ "${code}" == "403" ]] && die "GitHub API rate limit hit. Re-run with GITHUB_TOKEN set."
    done

    if [[ -n "${found}" ]]; then
        ok "  ${ref}  (${found%s})"
    else
        printf '\033[0;31m[actions][ERROR]\033[0m  %s  -> version "%s" does NOT exist\n' "${ref}" "${version}"
        # Be helpful: show the newest real releases of that repository.
        latest="$(curl -s -m 20 "${AUTH[@]}" \
            "https://api.github.com/repos/${owner}/${repo}/releases?per_page=5" \
            | grep -oE '"tag_name": *"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | paste -sd' ' - || true)"
        if [[ -n "${latest}" ]]; then
            printf '                        available now: %s\n' "${latest}"
        fi
        FAILED=$((FAILED + 1))
    fi
done <"${REFS_FILE}"

echo
if [[ "${FAILED}" -gt 0 ]]; then
    printf '\033[0;31m[actions][ERROR]\033[0m %s of %s reference(s) are broken - GitHub would fail these jobs at "Set up job".\n' "${FAILED}" "${CHECKED}" >&2
    exit 1
fi

ok "All ${CHECKED} action reference(s) resolve. GitHub will not fail on 'Set up job'."
