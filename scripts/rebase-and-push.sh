#!/usr/bin/env bash
# rebase-and-push.sh <fork-name> <mode> <target_ref>
#
# Clone le fork, ajoute l'upstream, rebase <patches_branch> sur <target_ref>.
# Succès: push --force-with-lease + pose un marqueur (tag) sur le fork.
# Échec: abort + écrit diagnostic JSON dans $GITHUB_OUTPUT (ou stdout) et exit 10.
#
# Variables: FORKS_OWNER, WORKDIR (défaut /tmp/forks-autopilot), MANIFEST.
# Auth: GH_TOKEN / GITHUB_TOKEN exporté → utilisé pour https clone/push.
# Git identity: GIT_AUTHOR_NAME/EMAIL si fournis, sinon "forks-autopilot" / <noreply>.

set -euo pipefail
[[ "${DEBUG:-}" == "1" ]] && set -x

# Tous les logs d'exécution sur stderr; seul le JSON final sort sur stdout.
log() { echo "[rebase-and-push] $*" >&2; }

FORK_NAME="${1:?usage: rebase-and-push.sh <fork-name> <mode> <target_ref>}"
MODE="${2:?}"
TARGET_REF="${3:?}"

MANIFEST="${MANIFEST:-forks.yml}"
OWNER="${FORKS_OWNER:-PhilippeCaira}"
WORKDIR="${WORKDIR:-/tmp/forks-autopilot}"

UPSTREAM=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .upstream)" "$MANIFEST")
UPSTREAM_BRANCH=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .upstream_branch) // \"main\"" "$MANIFEST")
PATCHES_BRANCH=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .patches_branch) // (.defaults.patches_branch // \"oidc\")" "$MANIFEST")
STRATEGY=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .strategy) // (.defaults.strategy // \"cherry-pick\")" "$MANIFEST")

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-forks-autopilot}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-forks-autopilot@users.noreply.github.com}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "no GH_TOKEN / GITHUB_TOKEN in env" >&2
  exit 2
fi

REPO_DIR="$WORKDIR/$FORK_NAME"
rm -rf "$REPO_DIR"
mkdir -p "$WORKDIR"

log "cloning $OWNER/$FORK_NAME"
git clone --quiet "https://x-access-token:$TOKEN@github.com/$OWNER/$FORK_NAME.git" "$REPO_DIR"
cd "$REPO_DIR"

log "adding upstream $UPSTREAM and fetching $UPSTREAM_BRANCH"
git remote add upstream "https://github.com/$UPSTREAM.git"
# Pas de --tags pour éviter les conflits de tags mobiles upstream (ex: release-candidate)
# Le tag cible est fetché explicitement plus bas si MODE=release.
git fetch upstream "$UPSTREAM_BRANCH" >&2

# Résoudre target_ref en un objet commit:
#  - en mode release: TARGET_REF est un tag
#  - en mode push: TARGET_REF est un sha
if [[ "$MODE" == "release" ]]; then
  log "fetching tag $TARGET_REF from upstream"
  git fetch upstream "refs/tags/$TARGET_REF:refs/tags/$TARGET_REF" >&2
fi

if ! git rev-parse --verify "$TARGET_REF^{commit}" >/dev/null 2>&1; then
  log "ERROR: cannot resolve target_ref '$TARGET_REF'"
  exit 3
fi

# Checkout branche patches (créer la ref locale depuis origin)
if git ls-remote --exit-code --heads origin "$PATCHES_BRANCH" >/dev/null 2>&1; then
  git checkout -q -B "$PATCHES_BRANCH" "origin/$PATCHES_BRANCH"
  log "checked out $PATCHES_BRANCH ($(git rev-parse --short HEAD))"
else
  log "ERROR: patches branch '$PATCHES_BRANCH' does not exist on fork $OWNER/$FORK_NAME"
  exit 4
fi

log "strategy: $STRATEGY"

# En mode cherry-pick on identifie les commits custom (ceux présents sur la branche
# patches mais pas dans upstream/$UPSTREAM_BRANCH ni dans $TARGET_REF), on reset
# $PATCHES_BRANCH sur $TARGET_REF et on cherry-pick chaque commit custom.
# Avantage: ne réapplique pas les commits upstream-déjà-mergés qui causent des
# conflits sur des fichiers append-only (CHANGELOG.md typiquement).
if [[ "$STRATEGY" == "cherry-pick" ]]; then
  mapfile -t CUSTOM_SHAS < <(git log --reverse --no-merges --format='%H' "$PATCHES_BRANCH" "^upstream/$UPSTREAM_BRANCH" "^$TARGET_REF")
  log "custom commits to cherry-pick (${#CUSTOM_SHAS[@]}):"
  for s in "${CUSTOM_SHAS[@]}"; do log "  $(git log -1 --format='%h %s' "$s")"; done

  git checkout -q -B "$PATCHES_BRANCH" "$TARGET_REF"

  if [[ ${#CUSTOM_SHAS[@]} -eq 0 ]]; then
    log "no custom commits — fork is already identical to upstream"
    MARKER="oidc-base/$TARGET_REF"
    [[ "$MODE" == "push" ]] && MARKER="oidc-base-push/$UPSTREAM_BRANCH/${TARGET_REF:0:12}"
    git tag -f "$MARKER" "$PATCHES_BRANCH"
    git push --force-with-lease origin "$PATCHES_BRANCH" >&2
    git push --force origin "refs/tags/$MARKER" >&2
    jq -n --arg status success --arg fork "$FORK_NAME" --arg marker "$MARKER" --arg target_ref "$TARGET_REF" \
      '{status:$status, fork:$fork, marker:$marker, target_ref:$target_ref, custom_count:0}'
    exit 0
  fi

  for sha in "${CUSTOM_SHAS[@]}"; do
    log "cherry-picking $sha"
    set +e
    git cherry-pick "$sha" >/tmp/cp.log 2>&1
    cp_rc=$?
    set -e
    if [[ $cp_rc -ne 0 ]]; then
      log "cherry-pick FAILED on $sha"
      sed -n '1,40p' /tmp/cp.log >&2
      CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null | paste -sd',' - || echo "")
      FAILING_SUBJECT=$(git log -1 --format='%s' "$sha" 2>/dev/null || echo "")
      git cherry-pick --abort 2>/dev/null || true
      # Diag JSON pour open-conflict-issue.sh
      RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
      CONFLICTED_JSON=$(printf '%s\n' "$CONFLICTED" | tr ',' '\n' | jq -R . | jq -cs 'map(select(length > 0))')
      FAILING_COMMIT_JSON=$(jq -cn --arg sha "$sha" --arg subject "$FAILING_SUBJECT" '{sha:$sha, subject:$subject}')
      jq -n \
        --arg status "conflict" --arg fork "$FORK_NAME" --arg owner "$OWNER" \
        --arg upstream "$UPSTREAM" --arg upstream_branch "$UPSTREAM_BRANCH" \
        --arg patches_branch "$PATCHES_BRANCH" --arg mode "$MODE" \
        --arg target_ref "$TARGET_REF" --arg strategy "$STRATEGY" --arg run_url "$RUN_URL" \
        --argjson conflicted_files "$CONFLICTED_JSON" \
        --argjson upstream_window "[]" \
        --argjson failing_commit "$FAILING_COMMIT_JSON" \
        '{status:$status, fork:$fork, owner:$owner, upstream:$upstream,
          upstream_branch:$upstream_branch, patches_branch:$patches_branch,
          mode:$mode, target_ref:$target_ref, strategy:$strategy,
          conflicted_files:$conflicted_files, upstream_window:$upstream_window,
          failing_commit:$failing_commit, run_url:$run_url}'
      exit 10
    fi
  done

  if [[ "$MODE" == "release" ]]; then
    MARKER="oidc-base/$TARGET_REF"
  else
    MARKER="oidc-base-push/$UPSTREAM_BRANCH/${TARGET_REF:0:12}"
  fi
  log "all ${#CUSTOM_SHAS[@]} commits cherry-picked OK — tagging $MARKER and pushing"
  git tag -f "$MARKER" "$PATCHES_BRANCH"
  git push --force-with-lease origin "$PATCHES_BRANCH" >&2
  git push --force origin "refs/tags/$MARKER" >&2
  jq -n --arg status success --arg fork "$FORK_NAME" --arg marker "$MARKER" \
        --arg target_ref "$TARGET_REF" --argjson custom_count "${#CUSTOM_SHAS[@]}" \
    '{status:$status, fork:$fork, marker:$marker, target_ref:$target_ref, custom_count:$custom_count}'
  exit 0
fi

# Capture des commits upstream qu'on est sur le point d'absorber (pour diagnostic)
MERGE_BASE=$(git merge-base "$PATCHES_BRANCH" "$TARGET_REF" 2>/dev/null || echo "")
RANGE="${MERGE_BASE:+$MERGE_BASE..}$TARGET_REF"
UPSTREAM_WINDOW_JSON=$(git log --no-merges --format='%H%x00%s' "$RANGE" 2>/dev/null \
  | head -20 \
  | python3 -c '
import sys, json
items = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line: continue
    sha, _, subj = line.partition("\x00")
    items.append({"sha": sha, "subject": subj})
print(json.dumps(items))
' 2>/dev/null || echo "[]")

# Tentative de rebase
log "rebasing $PATCHES_BRANCH onto $TARGET_REF"
set +e
git rebase "$TARGET_REF" >/tmp/rebase.log 2>&1
rebase_rc=$?
set -e

if [[ $rebase_rc -eq 0 ]]; then
  if [[ "$MODE" == "release" ]]; then
    MARKER="oidc-base/$TARGET_REF"
  else
    SHORT="${TARGET_REF:0:12}"
    MARKER="oidc-base-push/$UPSTREAM_BRANCH/$SHORT"
  fi
  log "rebase OK — tagging $MARKER and pushing"
  git tag -f "$MARKER" "$PATCHES_BRANCH"
  git push --force-with-lease origin "$PATCHES_BRANCH" >&2
  git push --force origin "refs/tags/$MARKER" >&2
  # JSON succès sur stdout
  jq -n \
    --arg status success \
    --arg fork "$FORK_NAME" \
    --arg marker "$MARKER" \
    --arg target_ref "$TARGET_REF" \
    '{status:$status, fork:$fork, marker:$marker, target_ref:$target_ref}'
  exit 0
fi

# Échec: capture fichiers en conflit et abort
log "rebase FAILED (rc=$rebase_rc) — capturing diagnostic"
sed -n '1,60p' /tmp/rebase.log >&2
CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null | paste -sd',' - || echo "")
git rebase --abort 2>/dev/null || true

# JSON diagnostic sur stdout (utilisable en local ET par le workflow)
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
CONFLICTED_JSON=$(printf '%s\n' "$CONFLICTED" | tr ',' '\n' | jq -R . | jq -cs 'map(select(length > 0))')
jq -n \
  --arg status "conflict" \
  --arg fork "$FORK_NAME" \
  --arg owner "$OWNER" \
  --arg upstream "$UPSTREAM" \
  --arg upstream_branch "$UPSTREAM_BRANCH" \
  --arg patches_branch "$PATCHES_BRANCH" \
  --arg mode "$MODE" \
  --arg target_ref "$TARGET_REF" \
  --arg run_url "$RUN_URL" \
  --argjson conflicted_files "$CONFLICTED_JSON" \
  --argjson upstream_window "$UPSTREAM_WINDOW_JSON" \
  '{status:$status, fork:$fork, owner:$owner, upstream:$upstream, upstream_branch:$upstream_branch,
    patches_branch:$patches_branch, mode:$mode, target_ref:$target_ref,
    conflicted_files:$conflicted_files, upstream_window:$upstream_window, run_url:$run_url}'

exit 10
