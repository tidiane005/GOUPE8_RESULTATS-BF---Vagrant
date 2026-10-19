#!/usr/bin/env bash
# bdd1 - PostgreSQL primaire (lecture et ecriture) - ingenieur donnees
# Idempotent (R2) : rejouable sans effet. Aucun secret dans le depot (R7) :
# DB_USER, DB_NAME et DB_PASS viennent de l'environnement ou de /vagrant/.env.
set -euo pipefail
source /vagrant/scripts/lib-donnees.sh
charger_env

DB_USER="${DB_USER:-resultats}"
DB_NAME="${DB_NAME:-resultats_bf}"
DB_PASS="${DB_PASS:?DB_PASS manquant : copier .env.exemple en .env et le renseigner}"

IP_BDD1="$(ip_noeud bdd1)"
[ -n "$IP_BDD1" ] || { echo "ERREUR : bdd1 absente de config/noeuds.yml"; exit 1; }
RESEAU_CIDR="${IP_BDD1%.*}.0/24"

echo "==> [bdd1] Installation de PostgreSQL"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql postgresql-contrib

PG_VER="$(version_pg)"
PG_HBA="/etc/postgresql/${PG_VER}/main/pg_hba.conf"
PG_CONFD="/etc/postgresql/${PG_VER}/main/conf.d"

echo "==> [bdd1] Configuration reseau et replication (PostgreSQL ${PG_VER})"
# Un fichier a nous, reecrit a chaque passage : pas de ligne en double
mkdir -p "$PG_CONFD"
cat > "${PG_CONFD}/90-resultats-bf.conf" << CFG
listen_addresses = '*'
wal_level = replica
max_wal_senders = 5
wal_keep_size = 256MB
CFG

# Acces depuis le reseau prive uniquement (jamais 0.0.0.0/0)
sed -i '/# resultats-bf$/d' "$PG_HBA"
cat >> "$PG_HBA" << HBA
host all         all ${RESEAU_CIDR} scram-sha-256 # resultats-bf
host replication all ${RESEAU_CIDR} scram-sha-256 # resultats-bf
HBA

systemctl enable postgresql
systemctl restart postgresql

echo "==> [bdd1] Utilisateur, base et table (idempotent)"
# Les valeurs passent par des variables psql : pas de souci de guillemets
sudo -u postgres psql -v ON_ERROR_STOP=1 -v u="$DB_USER" -v p="$DB_PASS" -v d="$DB_NAME" << 'SQL'
SELECT format('CREATE ROLE %I LOGIN REPLICATION PASSWORD %L', :'u', :'p')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'u') \gexec
SELECT format('ALTER ROLE %I LOGIN REPLICATION PASSWORD %L', :'u', :'p') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'d', :'u')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'d') \gexec
SQL

sudo -u postgres psql -v ON_ERROR_STOP=1 -v u="$DB_USER" -d "$DB_NAME" << 'SQL'
CREATE TABLE IF NOT EXISTS resultats (
  matricule text PRIMARY KEY,
  nom       text NOT NULL,
  serie     text NOT NULL,
  moyenne   numeric(4,2) NOT NULL,
  admis     boolean NOT NULL
);
SELECT format('GRANT SELECT ON resultats TO %I', :'u') \gexec
SQL

echo "==> [bdd1] Jeu de donnees : 50 000 candidats"
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME" << 'SQL'
-- Graine fixe : le jeu de donnees est identique a chaque reconstruction
SELECT setseed(0.42);
INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
SELECT 'MAT' || lpad(i::text, 6, '0'),
       'Candidat ' || i,
       (ARRAY['A','C','D','TI'])[(i % 4) + 1],
       round((random() * 20)::numeric, 2),
       random() > 0.4
FROM generate_series(1, 50000) AS i
ON CONFLICT (matricule) DO NOTHING;
SQL

NB="$(sudo -u postgres psql -d "$DB_NAME" -tAc 'SELECT count(*) FROM resultats')"
echo "==> [bdd1] Termine : ${NB} lignes, ecoute sur ${IP_BDD1}:5432"
