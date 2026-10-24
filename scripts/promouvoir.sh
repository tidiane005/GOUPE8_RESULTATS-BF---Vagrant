#!/usr/bin/env bash
# R6 - Promotion de la replique en primaire (ingenieur donnees).
# A lancer sur la replique : sudo bash /vagrant/scripts/promouvoir.sh
# Idempotent : si le noeud est deja primaire, il ne se passe rien.
set -euo pipefail

en_recovery() { sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'; }

if [ "$(en_recovery)" = "f" ]; then
  echo "DEJA_PRIMAIRE"
  exit 0
fi

debut=$(date +%s.%N)
# wait => true : la fonction rend la main quand la promotion est terminee (30 s max)
sudo -u postgres psql -tAc "SELECT pg_promote(wait => true, wait_seconds => 30);" >/dev/null
fin=$(date +%s.%N)

[ "$(en_recovery)" = "f" ] || { echo "ERREUR : la promotion n'a pas abouti"; exit 1; }
awk -v a="$fin" -v b="$debut" 'BEGIN { printf "PROMU %.2f\n", a - b }'
