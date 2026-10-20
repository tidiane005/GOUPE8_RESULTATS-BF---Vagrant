#!/usr/bin/env bash
# bdd2 - replique en flux de bdd1, promouvable (R5) - ingenieur donnees
# Idempotent (R2) : si la replique existe deja, on ne refait pas la copie.
set -euo pipefail
source /vagrant/scripts/lib-donnees.sh
charger_env

DB_USER="${DB_USER:-resultats}"
DB_PASS="${DB_PASS:?DB_PASS manquant : copier .env.exemple en .env et le renseigner}"

IP_BDD1="$(ip_noeud bdd1)"
IP_BDD2="$(ip_noeud bdd2)"
[ -n "$IP_BDD1" ] && [ -n "$IP_BDD2" ] || { echo "ERREUR : bdd1/bdd2 absentes de config/noeuds.yml"; exit 1; }
RESEAU_CIDR="${IP_BDD2%.*}.0/24"

echo "==> [bdd2] Installation de PostgreSQL"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql postgresql-contrib

PG_VER="$(version_pg)"
PG_DATA="/var/lib/postgresql/${PG_VER}/main"
PG_HBA="/etc/postgresql/${PG_VER}/main/pg_hba.conf"
PG_CONFD="/etc/postgresql/${PG_VER}/main/conf.d"

echo "==> [bdd2] Configuration reseau (PostgreSQL ${PG_VER})"
mkdir -p "$PG_CONFD"
cat > "${PG_CONFD}/90-resultats-bf.conf" << CFG
# Memes reglages de replication que bdd1 : une replique doit avoir des valeurs
# au moins egales a celles de son primaire, sinon elle refuse de demarrer.
# Ainsi bdd2 peut devenir primaire et bdd1 redevenir replique (R6).
listen_addresses = '*'
hot_standby = on
wal_level = replica
max_wal_senders = 10
wal_keep_size = 256MB
CFG
# pg_hba.conf n'est pas copie par pg_basebackup : on le prepare ici, ce qui
# permet aussi a bdd2 de devenir primaire apres une bascule (R6)
sed -i '/# resultats-bf$/d' "$PG_HBA"
cat >> "$PG_HBA" << HBA
host all         all ${RESEAU_CIDR} scram-sha-256 # resultats-bf
host replication all ${RESEAU_CIDR} scram-sha-256 # resultats-bf
HBA

if [ -f "${PG_DATA}/standby.signal" ]; then
  echo "==> [bdd2] Replique deja en place, copie initiale ignoree"
else
  echo "==> [bdd2] Attente de bdd1 (${IP_BDD1}:5432)"
  for i in $(seq 1 60); do
    PGPASSWORD="$DB_PASS" psql -h "$IP_BDD1" -U "$DB_USER" -d postgres -tAc 'SELECT 1' >/dev/null 2>&1 && break
    sleep 2
    [ "$i" -lt 60 ] || { echo "ERREUR : bdd1 injoignable apres 120 s"; exit 1; }
  done

  echo "==> [bdd2] Copie initiale depuis bdd1 (pg_basebackup)"
  systemctl stop postgresql
  find "$PG_DATA" -mindepth 1 -delete
  sudo -u postgres env PGPASSWORD="$DB_PASS" \
    pg_basebackup -h "$IP_BDD1" -U "$DB_USER" -D "$PG_DATA" -Xs -R
fi

systemctl enable postgresql
systemctl restart postgresql
echo "==> [bdd2] Termine : replique en flux de ${IP_BDD1}"
