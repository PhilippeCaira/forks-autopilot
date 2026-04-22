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

FORK_NAME="${1:?usage: rebase-and-push.sh <fork-name> <mode> <target_ref>}"
MODE="${2:?}"
TARGET_REF="${3:?}"

MANIFEST="${MANIFEST:-forks.yml}"
OWNER="${FORKS_OWNER:-PhilippeCaira}"
WORKDIR="${WORKDIR:-/tmp/forks-autopilot}"

UPSTREAM=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .upstream)" "$MANIFEST")
UPSTREAM_BRANCH=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .upstream_branch) // \"main\"" "$MANIFEST")
PATCHES_BRANCH=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .patches_branch) // (.defaults.patches_branch // \"oidc\")" "$MANIFEST")

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

# clone shallow est risqué pour un rebase profond; on prend complet
git clone --quiet "https://x-access-token:$TOKEN@github.com/$OWNER/$FORK_NAME.git" "$REPO_DIR"
cd "$REPO_DIR"

git remote add upstream "https://github.com/$UPSTREAM.git"
git fetch --quiet --tags upstream "$UPSTREAM_BRANCH"

# Résoudre target_ref en un objet commit:
#  - en mode release: TARGET_REF est un tag
#  - en mode push: TARGET_REF est un sha
if [[ "$MODE" == "release" ]]; then
  git fetch --quiet upstream "refs/tags/$TARGET_REF:refs/tags/$TARGET_REF"
fi

if ! git rev-parse --verify "$TARGET_REF^{commit}" >/dev/null 2>&1; then
  echo "cannot resolve target_ref '$TARGET_REF'" >&2
  exit 3
fi

# Checkout branche patches (créer la ref locale depuis origin)
if git ls-remote --exit-code --heads origin "$PATCHES_BRANCH" >/dev/null 2>&1; then
  git checkout -q -B "$PATCHES_BRANCH" "origin/$PATCHES_BRANCH"
else
  echo "patches branch '$PATCHES_BRANCH' does not exist on fork $OWNER/$FORK_NAME" >&2
  exit 4
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
set +e
git rebase "$TARGET_REF" >/tmp/rebase.log 2>&1
rebase_rc=$?
set -e

if [[ $rebase_rc -eq 0 ]]; then
  # Pose marqueur selon le mode
  if [[ "$MODE" == "release" ]]; then
    MARKER="oidc-base/$TARGET_REF"
  else
    SHORT="${TARGET_REF:0:12}"
    MARKER="oidc-base-push/$UPSTREAM_BRANCH/$SHORT"
  fi
  git tag -f "$MARKER" "$PATCHES_BRANCH"
  git push --force-with-lease --quiet origin "$PATCHES_BRANCH"
  git push --quiet --force origin "refs/tags/$MARKER"
  echo "status=success"
  echo "marker=$MARKER"
  echo "target_ref=$TARGET_REF"
  exit 0
fi

# Échec: capture fichiers en conflit et abort
CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null | paste -sd',' - || echo "")
git rebase --abort 2>/dev/null || true

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "status=conflict"
    echo "target_ref=$TARGET_REF"
    echo "mode=$MODE"
    echo "upstream=$UPSTREAM"
    echo "upstream_branch=$UPSTREAM_BRANCH"
    echo "patches_branch=$PATCHES_BRANCH"
    echo "conflicted_files=$CONFLICTED"
    echo 'upstream_window<<AUTOPILOT_EOF'
    echo "$UPSTREAM_WINDOW_JSON"
    echo 'AUTOPILOT_EOF'
  } >> "$GITHUB_OUTPUT"
fi

# Diagnostic JSON toujours sur stdout (utile en local et pour open-conflict-issue.sh)
python3 -c '
import json, os, sys
print(json.dumps({
  "fork": os.environ.get("FORK_NAME"),
  "owner": os.environ.get("OWNER"),
  "upstream": os.environ.get("UPSTREAM"),
  "upstream_branch": os.environ.get("UPSTREAM_BRANCH"),
  "patches_branch": os.environ.get("PATCHES_BRANCH"),
  "mode": os.environ.get("MODE"),
  "target_ref": os.environ.get("TARGET_REF"),
  "conflicted_files": [f for f in os.environ.get("CONFLICTED","").split(",") if f],
  "upstream_window": json.loads(os.environ.get("UPSTREAM_WINDOW_JSON") or "[]"),
  "run_url": os.environ.get("RUN_URL",""),
}, indent=2))
' FORK_NAME="$FORK_NAME" OWNER="$OWNER" UPSTREAM="$UPSTREAM" UPSTREAM_BRANCH="$UPSTREAM_BRANCH" \
  PATCHES_BRANCH="$PATCHES_BRANCH" MODE="$MODE" TARGET_REF="$TARGET_REF" \
  CONFLICTED="$CONFLICTED" UPSTREAM_WINDOW_JSON="$UPSTREAM_WINDOW_JSON" \
  RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

exit 10
