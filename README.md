# forks-autopilot

Orchestration centrale du rebase automatique des forks `PhilippeCaira/*` sur leur upstream.

## Fonctionnement

Toutes les heures (cron `0 * * * *`), le workflow `autopilot.yml` :

1. Lit `forks.yml`.
2. Pour chaque fork actif, interroge l'upstream (release la plus récente et/ou HEAD de la branche par défaut selon `trigger`).
3. Si un marqueur `oidc-base/<tag>` (release) ou `oidc-base-push/<branch>/<sha>` (push) est absent du fork, déclenche un job matrix.
4. Dans le job : clone le fork, `git rebase` la branche patches (défaut `oidc`) sur la nouvelle cible upstream.
   - **Succès** → pose le marqueur, `git push --force-with-lease origin oidc`. Le workflow `build-oidc.yml` du fork prend le relais et publie `ghcr.io/philippecaira/<service>-oidc:latest`. `company-stack` consomme au prochain `docker compose pull`.
   - **Échec** (conflit) → abort, ouvre/met à jour une issue GitHub sur le fork avec diagnostic + commandes de reprise locale.

## Setup

### 1. PAT fine-grained

Créer un Personal Access Token fine-grained sur GitHub :

- **Resource owner** : `PhilippeCaira`
- **Repositories** : sélectionner les 8 forks (chatwoot, invoiceninja, plane, twenty, docuseal, analytics, activepieces, wg-easy) **+** `forks-autopilot` lui-même.
- **Permissions** :
  - Contents : **Read and write**
  - Issues : **Read and write**
  - Metadata : Read (par défaut)

### 2. Secret

Dans Settings → Secrets and variables → Actions du repo `forks-autopilot` :

```
FORKS_AUTOPILOT_PAT = <le PAT>
```

### 3. Activer le cron

Par défaut GitHub désactive les cron workflows sur les repos inactifs après 60 jours. Un `workflow_dispatch` périodique ou un commit de temps en temps suffit à le garder actif.

## Usage manuel

```bash
# Rejouer tous les forks
gh workflow run autopilot.yml --repo PhilippeCaira/forks-autopilot

# Un seul fork
gh workflow run autopilot.yml --repo PhilippeCaira/forks-autopilot -f fork_name=chatwoot
```

## Ajouter / retirer / désactiver un fork

Éditer `forks.yml` et commit :

```yaml
- name: nouveau-fork
  upstream: upstream-org/nouveau-fork
  upstream_branch: main
  trigger: release
```

Pour désactiver temporairement (ex : patches en cours de refonte) : `enabled: false`.

Prérequis côté fork :

- Branche patches (défaut `oidc`) existante et poussée.
- Workflow `build-oidc.yml` (ou équivalent) qui écoute les pushes sur `oidc` et publie l'image — ce workflow vit **dans le fork**, pas ici.

Penser à ajouter le nouveau repo dans le scope du PAT (GitHub → Settings → Developer settings → PAT → Edit → Repository access).

## Dry-run local

```bash
export GH_TOKEN=$(gh auth token)
./scripts/detect-update.sh chatwoot        # doit imprimer <mode>\t<ref>\t<upstream> ou rien
FORKS_OWNER=PhilippeCaira \
  ./scripts/rebase-and-push.sh chatwoot release v4.2.0   # attention: push réel si succès
```

Pour tester sans push, exporter un `WORKDIR` puis commenter les lignes `git push` du script.

## État

L'état est encodé en tags git sur chaque fork :

- `oidc-base/<tag>` : marque que `oidc` a été rebased sur ce tag upstream avec succès.
- `oidc-base-push/<branch>/<sha12>` : idem pour un rebase sur un sha (mode `push`).

Lister l'état d'un fork :

```bash
gh api repos/PhilippeCaira/chatwoot/tags --paginate --jq '.[] | select(.name | startswith("oidc-base")) | .name'
```

## Limites connues

- **wg-easy** consomme actuellement l'image upstream `ghcr.io/wg-easy/wg-easy:15` dans `company-stack/internal/compose.yml` — le rebase automatique met à jour la branche `oidc` et rebuild `ghcr.io/philippecaira/wg-easy-oidc:latest`, mais le stack ne la consomme pas tant que tu n'as pas changé le pin.
- **twenty** consomme aussi `twentycrm/twenty:v1.21` (image upstream pour la migration) dans `company-stack/business/compose.yml` — pin non géré ici, bump manuel.
- **Conflits récurrents** sur le même fichier → signal pour refactoriser le patch ou pousser un PR en upstream.
- Le cron est **best-effort** (GitHub peut retarder de ~15 min). Pour une réactivité supérieure, déclencher manuellement ou ajouter un hook côté upstream (impossible si on n'est pas mainteneur — c'est le cas ici).
