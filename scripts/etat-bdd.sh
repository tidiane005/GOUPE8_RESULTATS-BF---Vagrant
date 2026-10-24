#!/usr/bin/env bash
# Releve l'etat de PostgreSQL sur bdd1 ou bdd2 (outil de la verification R2).
# Usage : sudo bash /vagrant/scripts/etat-bdd.sh
V="$(ls /etc/postgresql | sort -V | tail -n1)"
D="/etc/postgresql/${V}/main"
echo "pg_hba.conf        : $(md5sum < "${D}/pg_hba.conf" | cut -c1-12)"
echo "conf.d resultats   : $(md5sum < "${D}/conf.d/90-resultats-bf.conf" | cut -c1-12)"
echo "lignes marquees    : $(grep -c '# resultats-bf$' "${D}/pg_hba.conf") dans pg_hba.conf"
echo "mode replique      : $(sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()')"
echo "lignes resultats   : $(sudo -u postgres psql -d "${DB_NAME:-resultats_bf}" -tAc 'SELECT count(*) FROM resultats')"
