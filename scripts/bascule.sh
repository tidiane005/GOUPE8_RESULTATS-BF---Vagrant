#!/usr/bin/env bash
# R6 - Bascule complète de la base (à lancer sur l'HÔTE, depuis n'importe où).
#   1. promeut bdd2 en primaire (scripts/promouvoir.sh, exécuté dans bdd2) ;
#   2. repointe DB_HOST vers bdd2 sur chaque serveur applicatif démarré
#      et redémarre le service.
# Usage : bash scripts/bascule.sh
# Idempotent : rejouable sans effet de bord (promouvoir.sh renvoie DEJA_PRIMAIRE).
set -euo pipefail
cd "$(dirname "$0")/.."

# Emplacements réels dans les serveurs applicatifs (vérifiés sur app1)
APP_ENV="/etc/resultats-bf/app.env"
APP_SERVICE="app"

NOEUDS_YML="config/noeuds.yml"
[ -f "$NOEUDS_YML" ] || { echo "ERREUR : $NOEUDS_YML introuvable (lancer d'abord vagrant up)."; exit 1; }

# IP de bdd2 lue dans la source unique de vérité : aucune adresse en dur.
IP_BDD2="$(tr -d '\r' < "$NOEUDS_YML" | awk '
  /nom:/ { cur = ($NF == "bdd2") }
  cur && /ip:/ { print $NF; exit }
')"
[ -n "$IP_BDD2" ] || { echo "ERREUR : IP de bdd2 introuvable dans $NOEUDS_YML"; exit 1; }

T0=$(date +%s)

echo "===> [1/2] Promotion de bdd2 ($IP_BDD2)"
vagrant ssh bdd2 -c 'sudo bash /vagrant/scripts/promouvoir.sh'

echo "===> [2/2] Repointage des serveurs applicatifs démarrés"
APPS="$(vagrant status --machine-readable \
  | tr -d '\r' \
  | awk -F, '$3=="state" && $2 ~ /^app[0-9]+$/ && $4=="running" {print $2}')"

# Commande exécutée dans chaque app : remplace DB_HOST (ou l'ajoute s'il est absent), puis redémarre.
REMOTE="f=$APP_ENV; if sudo grep -q '^DB_HOST=' \$f; then sudo sed -i 's|^DB_HOST=.*|DB_HOST=$IP_BDD2|' \$f; else echo 'DB_HOST=$IP_BDD2' | sudo tee -a \$f >/dev/null; fi; sudo systemctl restart $APP_SERVICE"

if [ -z "$APPS" ]; then
  echo "Aucun serveur applicatif démarré : rien à repointer."
else
  for app in $APPS; do
    echo "  - $app"
    vagrant ssh "$app" -c "$REMOTE"
  done
fi

echo "===> Bascule terminée en $(( $(date +%s) - T0 )) s"