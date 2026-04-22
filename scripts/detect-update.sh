#!/usr/bin/env bash
# detect-update.sh <fork-name>
#
# Lit forks.yml, détermine si le fork a besoin d'un rebase.
# Sortie stdout (une seule ligne): "<mode>\t<target_ref>\t<upstream_short>"
#   mode ∈ {release, push}
#   target_ref = tag upstream (release) ou sha court (push)
# Si rien à faire: pas de sortie, exit 0.
# Sur erreur: message sur stderr, exit >0.
#
# Prérequis: gh, yq (mikefarah), git.
# Variables: FORKS_OWNER (défaut PhilippeCaira), MANIFEST (défaut forks.yml).

set -euo pipefail

FORK_NAME="${1:?usage: detect-update.sh <fork-name>}"
MANIFEST="${MANIFEST:-forks.yml}"
OWNER="${FORKS_OWNER:-PhilippeCaira}"

read_field() {
  local field="$1"
  local default="${2:-}"
  local val
  val=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .$field) // (.defaults.$field // \"$default\")" "$MANIFEST")
  if [[ "$val" == "null" || -z "$val" ]]; then
    echo "$default"
  else
    echo "$val"
  fi
}

enabled=$(yq -r "(.forks[] | select(.name == \"$FORK_NAME\") | .enabled) // true" "$MANIFEST")
if [[ "$enabled" == "false" ]]; then
  echo "fork $FORK_NAME disabled in manifest" >&2
  exit 0
fi

UPSTREAM=$(read_field upstream)
UPSTREAM_BRANCH=$(read_field upstream_branch)
PATCHES_BRANCH=$(read_field patches_branch oidc)
TRIGGER=$(read_field trigger release)

if [[ -z "$UPSTREAM" ]]; then
  echo "no upstream configured for $FORK_NAME" >&2
  exit 1
fi

FORK_REPO="$OWNER/$FORK_NAME"

# ---- mode release: compare dernier tag upstream au marqueur oidc-base/* du fork
check_release() {
  local latest_tag
  latest_tag=$(gh release list --repo "$UPSTREAM" --limit 1 --json tagName --jq '.[0].tagName // ""' 2>/dev/null || echo "")
  if [[ -z "$latest_tag" ]]; then
    # Fallback: dernier tag git si pas de release GitHub
    latest_tag=$(gh api "repos/$UPSTREAM/tags?per_page=1" --jq '.[0].name // ""' 2>/dev/null || echo "")
  fi
  [[ -z "$latest_tag" ]] && return 1

  # Le marqueur est un tag sur le fork: oidc-base/<tag>
  local marker="oidc-base/$latest_tag"
  if gh api "repos/$FORK_REPO/git/ref/tags/$marker" >/dev/null 2>&1; then
    return 1  # déjà rebased sur ce tag
  fi
  printf 'release\t%s\t%s\n' "$latest_tag" "$UPSTREAM"
  return 0
}

# ---- mode push: compare HEAD upstream/<branch> au dernier marqueur oidc-base-push/<branch>/<sha>
check_push() {
  local upstream_head
  upstream_head=$(gh api "repos/$UPSTREAM/commits/$UPSTREAM_BRANCH" --jq '.sha // ""' 2>/dev/null || echo "")
  [[ -z "$upstream_head" ]] && return 1

  local short="${upstream_head:0:12}"
  local marker="oidc-base-push/$UPSTREAM_BRANCH/$short"
  if gh api "repos/$FORK_REPO/git/ref/tags/$marker" >/dev/null 2>&1; then
    return 1  # déjà rebased sur ce sha
  fi
  printf 'push\t%s\t%s\n' "$upstream_head" "$UPSTREAM"
  return 0
}

case "$TRIGGER" in
  release) check_release || true ;;
  push)    check_push    || true ;;
  both)
    # priorité au release (plus stable) puis fallback au push
    check_release || check_push || true
    ;;
  *)
    echo "unknown trigger: $TRIGGER" >&2
    exit 2
    ;;
esac
