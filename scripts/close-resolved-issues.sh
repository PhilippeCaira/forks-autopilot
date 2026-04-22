#!/usr/bin/env bash
# close-resolved-issues.sh <fork-name> <target_ref> <marker>
#
# Appelé après un rebase réussi. Cherche les issues autopilot ouvertes qui
# concernent ce fork — à la fois sur le fork (si les issues y sont activées)
# et sur le repo de fallback (typiquement forks-autopilot) — et les ferme
# avec un commentaire de résolution.
#
# Env : FORKS_OWNER, FALLBACK_REPO, GH_TOKEN.

set -euo pipefail

FORK_NAME="${1:?usage: close-resolved-issues.sh <fork-name> <target_ref> <marker>}"
TARGET_REF="${2:?}"
MARKER="${3:?}"

OWNER="${FORKS_OWNER:-PhilippeCaira}"
FORK_REPO="$OWNER/$FORK_NAME"
FALLBACK="${FALLBACK_REPO:-}"

COMMENT="✅ Résolu automatiquement par un rebase/cherry-pick ultérieur.

- Cible upstream : \`$TARGET_REF\`
- Marqueur posé : \`$MARKER\`
- Run : ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

close_issues_on() {
  local repo="$1"
  local search="$2"
  local numbers
  numbers=$(gh issue list --repo "$repo" --state open --label autopilot \
              ${search:+--search "$search"} \
              --json number --jq '.[].number' 2>/dev/null || echo "")
  for n in $numbers; do
    echo "closing #$n on $repo"
    gh issue close "$n" --repo "$repo" --comment "$COMMENT" >/dev/null
  done
}

# Sur le fork lui-même (si issues activées)
if gh api "repos/$FORK_REPO" --jq '.has_issues' 2>/dev/null | grep -q true; then
  close_issues_on "$FORK_REPO" ""
fi

# Sur le repo de fallback, on filtre par préfixe [<fork-name>] dans le titre
if [[ -n "$FALLBACK" && "$FALLBACK" != "$FORK_REPO" ]]; then
  close_issues_on "$FALLBACK" "[$FORK_NAME] in:title"
fi
