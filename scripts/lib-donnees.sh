#!/usr/bin/env bash
# Fonctions communes aux scripts de l'ingenieur donnees (bdd.sh, replique.sh).
# Source par les deux scripts : ne s'execute pas seul.

# Charge /vagrant/.env (non versionne, R7) sans ecraser une variable deja
# definie dans l'environnement. Tolere les fins de ligne Windows (CRLF).
charger_env() {
  local fichier="/vagrant/.env" ligne cle val
  [ -f "$fichier" ] || return 0
  while IFS= read -r ligne || [ -n "$ligne" ]; do
    ligne="${ligne%$'\r'}"
    [[ "$ligne" =~ ^[[:space:]]*# ]] && continue
    [[ "$ligne" == *=* ]] || continue
    cle="${ligne%%=*}"; val="${ligne#*=}"
    [[ "$cle" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -z "${!cle:-}" ] && export "$cle=$val"
  done < "$fichier"
  return 0
}

# Adresse d'un noeud lue dans config/noeuds.yml (source unique de verite,
# engendree par le Vagrantfile). Usage : ip_noeud bdd1
ip_noeud() {
  # tr : le fichier est ecrit par Ruby sous Windows, donc avec des fins de ligne CRLF
  tr -d '\r' < /vagrant/config/noeuds.yml | awk -v n="$1" '
    /nom:/ { cur = $NF }
    /ip:/  { if (cur == n) { print $NF; exit } }
  '
}

# Version de PostgreSQL installee (dossier /etc/postgresql/<version>)
version_pg() { ls /etc/postgresql | sort -V | tail -n1; }
