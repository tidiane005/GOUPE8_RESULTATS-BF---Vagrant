#!/usr/bin/env bash
# R6 - Remet un ancien primaire en replique du nouveau primaire (ingenieur donnees).
# A lancer sur le noeud a rattacher : sudo bash /vagrant/scripts/rejoindre.sh <nom_du_primaire>
# Exemple apres une bascule : sur bdd1  ->  sudo bash /vagrant/scripts/rejoindre.sh bdd2
#
# ATTENTION : les donnees locales du noeud sont REMPLACEES par une copie du
# primaire. Les ecritures de l'ancien primaire qui n'avaient pas encore ete
# repliquees (replication asynchrone) sont perdues.
set -euo pipefail
source /vagrant/scripts/lib-donnees.sh
charger_env

CIBLE="${1:?usage : rejoindre.sh <nom_du_primaire> (ex. bdd2)}"
DB_USER="${DB_USER:-resultats}"
DB_PASS="${DB_PASS:?DB_PASS manquant (.env)}"

IP_CIBLE="$(ip_noeud "$CIBLE")"
[ -n "$IP_CIBLE" ] || { echo "ERREUR : $CIBLE absent de config/noeuds.yml"; exit 1; }
[ "$CIBLE" != "$(hostname)" ] || { echo "ERREUR : un noeud ne peut pas se repliquer lui-meme"; exit 1; }

# Le noeud vise doit etre un primaire qui repond (pas une replique)
etat="$(PGPASSWORD="$DB_PASS" psql -h "$IP_CIBLE" -U "$DB_USER" -d postgres -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || true)"
[ "$etat" = "f" ] || { echo "ERREUR : $CIBLE ($IP_CIBLE) n'est pas un primaire joignable (etat='$etat')"; exit 1; }

PG_VER="$(version_pg)"
PG_DATA="/var/lib/postgresql/${PG_VER}/main"

echo "==> [$(hostname)] Rattachement a $CIBLE ($IP_CIBLE) : copie complete (pg_basebackup)"
systemctl stop postgresql
find "$PG_DATA" -mindepth 1 -delete
sudo -u postgres env PGPASSWORD="$DB_PASS" \
  pg_basebackup -h "$IP_CIBLE" -U "$DB_USER" -D "$PG_DATA" -Xs -R
systemctl enable postgresql
systemctl restart postgresql

for i in $(seq 1 30); do
  [ "$(sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();' 2>/dev/null || true)" = "t" ] && { echo "REPLIQUE_OK"; exit 0; }
  sleep 1
done
echo "ERREUR : le noeud n'est pas passe en mode replique en 30 s"; exit 1
