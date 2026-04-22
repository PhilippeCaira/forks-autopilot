#!/usr/bin/env bash
# open-conflict-issue.sh <fork-name> <diagnostic.json>
#
# Ouvre (ou met à jour) une issue GitHub sur PhilippeCaira/<fork-name> décrivant
# l'échec du rebase automatique. Dédoublonnage par titre exact + label 'autopilot'.

set -euo pipefail

FORK_NAME="${1:?usage: open-conflict-issue.sh <fork-name> <diagnostic.json>}"
DIAG_FILE="${2:?}"
OWNER="${FORKS_OWNER:-PhilippeCaira}"
REPO="$OWNER/$FORK_NAME"

if [[ ! -f "$DIAG_FILE" ]]; then
  echo "diagnostic file not found: $DIAG_FILE" >&2
  exit 1
fi
export DIAG_FILE

TARGET_REF=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target_ref"])' "$DIAG_FILE")
MODE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mode"])' "$DIAG_FILE")
UPSTREAM=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream"])' "$DIAG_FILE")
PATCHES_BRANCH=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["patches_branch"])' "$DIAG_FILE")

TITLE="[autopilot] rebase $PATCHES_BRANCH onto $UPSTREAM@$TARGET_REF failed"

BODY=$(python3 <<'PYEOF'
import json, os, sys
raw = json.load(open(os.environ["DIAG_FILE"]))
# Normaliser: toute valeur null devient "" pour éviter les TypeError
d = {k: ("" if v is None else v) for k, v in raw.items()}
files = d.get("conflicted_files") or []
commits = d.get("upstream_window") or []

parts = []
parts.append(f"## Contexte\n\nRebase automatique de `{d['patches_branch']}` sur `{d['upstream']}@{d['target_ref']}` (mode `{d['mode']}`) a échoué.\n")

parts.append("## Commits upstream concernés (jusqu'à 20 derniers)\n")
if commits:
    for c in commits:
        parts.append(f"- `{c['sha'][:10]}` {c['subject']}")
else:
    parts.append("_(aucun commit listé — fenêtre vide ou historique non dispo)_")
parts.append("")

parts.append("## Fichiers en conflit\n")
if files:
    for f in files:
        parts.append(f"- `{f}`")
else:
    parts.append("_(liste vide — le rebase a peut-être échoué avant d'entrer en conflit de contenu ; vérifier le run)_")
parts.append("")

parts.append("## Reprise locale\n")
parts.append("```bash")
parts.append(f"gh repo clone {d['owner']}/{d['fork']} && cd {d['fork']}")
parts.append(f"git remote add upstream https://github.com/{d['upstream']}.git")
parts.append("git fetch upstream --tags")
parts.append(f"git checkout {d['patches_branch']}")
parts.append(f"git rebase {d['target_ref']}")
parts.append("# résoudre les conflits, puis :")
parts.append(f"git push --force-with-lease origin {d['patches_branch']}")
if d['mode'] == 'release':
    parts.append(f"git tag -f oidc-base/{d['target_ref']} && git push -f origin oidc-base/{d['target_ref']}")
else:
    short = d['target_ref'][:12]
    parts.append(f"git tag -f oidc-base-push/{d['upstream_branch']}/{short} && git push -f origin oidc-base-push/{d['upstream_branch']}/{short}")
parts.append("```")
parts.append("")

if d.get("run_url"):
    parts.append(f"Run : {d['run_url']}")

print("\n".join(parts))
PYEOF
)

# Assurer que le label 'autopilot' existe
gh label create autopilot --repo "$REPO" --color ededed --description "Created by forks-autopilot" >/dev/null 2>&1 || true

# Cherche issue ouverte avec même titre
EXISTING=$(gh issue list --repo "$REPO" --state open --label autopilot --search "in:title \"$TITLE\"" --json number --jq '.[0].number // ""' 2>/dev/null || echo "")

if [[ -n "$EXISTING" ]]; then
  gh issue comment "$EXISTING" --repo "$REPO" --body "$BODY" >/dev/null
  echo "updated existing issue #$EXISTING on $REPO"
else
  gh issue create --repo "$REPO" --title "$TITLE" --body "$BODY" --label autopilot >/dev/null
  echo "opened new issue on $REPO"
fi
