#!/usr/bin/env bash
# Outil de demonstration de R5 (replication en flux) - ingenieur donnees.
# Usage : sudo bash /vagrant/scripts/r5-test.sh ecrire|lire|supprimer
# Ligne de test fixe : MAT999999 (jamais utilisee par le jeu de donnees).
set -euo pipefail
DB="${DB_NAME:-resultats_bf}"
psql_(){ sudo -u postgres psql -d "$DB" -tA "$@"; }
case "${1:-}" in
  ecrire)
    psql_ -c "INSERT INTO resultats VALUES ('MAT999999','Test R5','C',15.50,true) ON CONFLICT DO NOTHING;" ;;
  lire)
    psql_ -c "SELECT matricule || ' | ' || nom || ' | ' || moyenne FROM resultats WHERE matricule='MAT999999';" ;;
  supprimer)
    psql_ -c "DELETE FROM resultats WHERE matricule='MAT999999';" ;;
  *) echo "usage : ecrire | lire | supprimer"; exit 1 ;;
esac
