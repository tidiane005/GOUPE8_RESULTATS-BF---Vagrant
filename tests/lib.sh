#!/usr/bin/env bash
# tests/lib.sh -- fonctions communes aux scénarios V1 à V6 (à "sourcer", pas à exécuter).
#
# Prérequis sur le poste hôte : bash, curl, awk, sed, vagrant, date GNU (Linux, WSL ou Git Bash).
# ab (apache2-utils) est utilisé sur l'hôte s'il existe, sinon dans la VM obs.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$TESTS_DIR")"
cd "$ROOT_DIR" || exit 1          # vagrant doit être lancé depuis la racine du dépôt

NOEUDS_YML="$ROOT_DIR/config/noeuds.yml"
RESULTS_DIR="${RESULTS_DIR:-$ROOT_DIR/resultats}"
mkdir -p "$RESULTS_DIR"

APP_PORT="${APP_PORT:-3000}"
ROUTE_FOURNIE="${ROUTE:-}"              # route /resultat imposée par l'utilisateur (sinon détection auto)
MATRICULE="${MATRICULE:-1}"             # matricule de départ ; detect_resultat en cherche un valide si besoin
HOST_REGEX="${HOST_REGEX:-app[0-9]+}"   # motif du nom d'hôte renvoyé par /info

for outil in curl awk sed grep sort uniq; do
  command -v "$outil" >/dev/null 2>&1 || { echo "Outil manquant : $outil" >&2; exit 1; }
done
case "$(date +%s.%N)" in
  *N*) echo "Le 'date' de ce système ne gère pas %N (macOS ?). Utiliser Linux, WSL ou Git Bash." >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- paramètres de la plateforme
# GROUPE et NB_APP doivent être ceux utilisés pour `vagrant up` (sinon le Vagrantfile
# réécrirait config/noeuds.yml avec d'autres valeurs). On les déduit de noeuds.yml si absents.
if [ -z "${GROUPE:-}" ]; then
  GROUPE=1
  if [ -f "$NOEUDS_YML" ]; then
    oct="$(sed -nE 's/.*(^|[ :])ip: *"?192\.168\.([0-9]+)\..*/\2/p' "$NOEUDS_YML" | head -1)"
    [ -n "$oct" ] && GROUPE=$((oct - 55))
  fi
fi
if [ -z "${NB_APP:-}" ]; then
  NB_APP=2
  if [ -f "$NOEUDS_YML" ]; then
    n="$(grep -cE '(^|[ :])role: *"?app"?[[:space:]]*$' "$NOEUDS_YML")"
    [ "${n:-0}" -ge 1 ] && NB_APP="$n"
  fi
fi
export GROUPE NB_APP
RESEAU="192.168.$((55 + GROUPE))"
VIP="$RESEAU.5"
LB1_IP="$RESEAU.11"
OBS_IP="$RESEAU.41"

# liste "nom role" des noeuds, lue dans config/noeuds.yml
noeuds_liste() {
  # tr -d '\r' : sous Windows, Ruby écrit noeuds.yml en CRLF ; sans cela "lb1" deviendrait "lb1<CR>"
  awk '/(^|[ :-])nom:/ {gsub(/"/,""); nom=$NF} /(^|[ :])role:/ {gsub(/"/,""); print nom, $NF}' "$NOEUDS_YML" | tr -d '\r'
}

# lecture d'une clé du fichier .env (sans afficher d'autre ligne)
dotenv_get() {
  [ -f "$ROOT_DIR/.env" ] || return 1
  grep -E "^$1=" "$ROOT_DIR/.env" | head -1 | cut -d= -f2- | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']\$//"
}
e2_actif() { [ "${E2:-$(dotenv_get E2)}" = 1 ]; }   # extension E2 (machine obs) activée ?

# ---------------------------------------------------------------- affichage / rapport
PASS_COUNT=0
FAIL_COUNT=0
REPORT=""

start_report() {
  REPORT="$RESULTS_DIR/${1}_$(date +%Y%m%d_%H%M%S).txt"
  exec > >(tr -d '\r' | tee "$REPORT") 2>&1
  echo "=== Scénario : $1 ==="
  echo "Date            : $(date '+%F %T %z')"
  echo "Poste           : $(uname -sr)"
  echo "Groupe / réseau : $GROUPE / $RESEAU.0/24"
  echo "Serveurs app    : N=$NB_APP"
  echo
}

run() {   # affiche la commande exacte, l'exécute, affiche le résultat brut et le code retour
  echo "\$ $*"
  "$@"
  local rc=$?
  echo "(code retour : $rc)"
  return $rc
}

check() { # check "description" code_retour (0 = réussi)
  if [ "$2" -eq 0 ]; then
    echo "[ OK ]    $1"; PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "[ECHEC]   $1"; FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

end_summary() {
  echo
  echo "------------------------------------------------------------"
  if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "RÉSULTAT GLOBAL : SUCCÈS ($PASS_COUNT contrôle(s) réussi(s))"
  else
    echo "RÉSULTAT GLOBAL : ÉCHEC ($FAIL_COUNT échec(s) sur $((PASS_COUNT + FAIL_COUNT)) contrôle(s))"
  fi
  echo "Rapport enregistré : $REPORT"
  sleep 0.3
  [ "$FAIL_COUNT" -eq 0 ]
}

confirm() { # confirm "question" ; YES=1 pour passer outre
  [ "${YES:-0}" = 1 ] && return 0
  local r
  read -r -p "$1 [o/N] " r
  [[ "$r" =~ ^[oOyY] ]]
}

# ---------------------------------------------------------------- temps
now() { date +%s.%N; }
dur() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }
add() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", a + b }'; }
elapsed_since() { awk -v a="$1" -v n="$(now)" 'BEGIN { exit !(n - a < '"$2"') }'; }  # vrai tant que < $2 s

# ---------------------------------------------------------------- HTTP
detect_base_url() {
  if [ -z "${BASE_URL:-}" ]; then
    local c
    for c in "http://$VIP" "http://$LB1_IP" "http://localhost:8080"; do
      if curl -s -m 2 -o /dev/null "$c/info"; then BASE_URL="$c"; break; fi
    done
    BASE_URL="${BASE_URL:-http://localhost:8080}"
  fi
  echo "URL testée      : $BASE_URL"
}

http_code() { curl -s -m "${2:-3}" -o /dev/null -w '%{http_code}' "$1"; }

# ---------------------------------------------------------------- route /resultat
ROUTE_MODELES="${ROUTE_MODELES:-/resultat?matricule=%M /resultat/%M}"   # %M = matricule

# matricule_depuis_base : lit un matricule existant directement dans la base (schéma inconnu :
# on cherche une table qui possède une colonne "matricule"). Affiche rien si introuvable.
matricule_depuis_base() {
  local db vm tbl
  db="${DB_NAME:-$(dotenv_get DB_NAME)}"
  [ -n "$db" ] || return 1
  for vm in bdd2 bdd1; do vm_running "$vm" && break; done
  tbl="$(vssh "$vm" "sudo -u postgres psql -d $db -Atc \"select table_schema||'.'||table_name from information_schema.columns where column_name='matricule' and table_schema not in ('pg_catalog','information_schema') limit 1\"" | head -1)"
  [ -n "$tbl" ] || return 1
  vssh "$vm" "sudo -u postgres psql -d $db -Atc \"select matricule from $tbl limit 1\"" | head -1
}

_essayer_matricule() {   # _essayer_matricule m : si une route répond 200, fixe MATRICULE et ROUTE
  local m="$1" modele r
  [ -n "$m" ] || return 1
  for modele in $ROUTE_MODELES; do
    r="${modele//%M/$m}"
    if [ "$(http_code "$BASE_URL$r" 3)" = 200 ]; then MATRICULE="$m"; ROUTE="$r"; return 0; fi
  done
  return 1
}

# detect_resultat [timeout_s] : trouve un matricule (et la route) qui répondent 200.
# Ordre : ROUTE imposée > MATRICULE donné/par défaut > matricule lu en base > matricules 2..20.
# Réessaie pendant timeout_s (utile juste après un démarrage). Retourne 0 si trouvé.
detect_resultat() {
  local to="${1:-20}" t0 demande="$MATRICULE" m
  if [ -n "$ROUTE_FOURNIE" ]; then ROUTE="$ROUTE_FOURNIE"; echo "Route /resultat : $ROUTE (imposée par ROUTE=)"; return 0; fi
  t0="$(now)"
  while :; do
    _essayer_matricule "$demande" && break
    m="$(matricule_depuis_base)"; _essayer_matricule "$m" && break
    for m in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 100 101 1001; do
      _essayer_matricule "$m" && break 2
    done
    elapsed_since "$t0" "$to" || break
    sleep 3
  done
  if [ -n "${ROUTE:-}" ] && [ "$(http_code "$BASE_URL$ROUTE" 3)" = 200 ]; then
    echo "Route /resultat : $ROUTE (matricule $MATRICULE)"
    [ "$MATRICULE" != "$demande" ] && echo "  NB : le matricule $demande ne donnait pas 200 ; le matricule $MATRICULE est utilisé à la place."
    return 0
  fi
  MATRICULE="$demande"; ROUTE="/resultat?matricule=$MATRICULE"
  echo "ATTENTION : aucune route /resultat ne répond 200 (matricules essayés : $demande, base, 2..20)."
  echo "  -> vérifier : curl -si \"$BASE_URL$ROUTE\"   puis définir MATRICULE=<valide> ou ROUTE=<chemin>."
  return 1
}

# verifier_bascule_cmd "commande" : refuse de continuer si un script /vagrant/... cité n'existe pas dans le dépôt
verifier_bascule_cmd() {
  local f ok=0
  for f in $(printf '%s' "$1" | grep -oE '/vagrant/[A-Za-z0-9_./-]+'); do
    [ -e "$ROOT_DIR/${f#/vagrant/}" ] || { echo "ERREUR : $f est cité par BASCULE_CMD mais n'existe pas dans le dépôt."; ok=1; }
  done
  return "$ok"
}

wait_http() { # wait_http url regex_code timeout_s
  local url="$1" re="$2" to="${3:-120}" t=0 code
  while [ "$t" -lt "$to" ]; do
    code="$(http_code "$url" 2)"
    [[ "$code" =~ $re ]] && return 0
    sleep 1; t=$((t + 1))
  done
  return 1
}

hote_de() { # nom d'hôte extrait d'une réponse /info
  printf '%s' "$1" | grep -oE "$HOST_REGEX" | head -1
}

wait_host() { # wait_host nom timeout_s : attend que ce serveur réponde sur /info
  local h="$1" to="${2:-120}" t=0 i rep
  while [ "$t" -lt "$to" ]; do
    for i in 1 2 3 4 5 6; do
      rep="$(curl -s -m 2 "$BASE_URL/info")"
      [ "$(hote_de "$rep")" = "$h" ] && return 0
    done
    sleep 2; t=$((t + 2))
  done
  return 1
}

# ---------------------------------------------------------------- sonde continue
PROBE_PIDS=""
# probe_start url fichier [intervalle_s] : écrit "timestamp code hote" à chaque requête
probe_start() {
  local url="$1" out="$2" interval="${3:-0.1}"
  : > "$out"
  (
    while true; do
      ts="$(date +%s.%N)"
      resp="$(curl -s -m 2 -w '\n%{http_code}' "$url" 2>/dev/null)"
      code="${resp##*$'\n'}"
      [ -z "$code" ] && code=000
      h="$(printf '%s' "$resp" | grep -oE "$HOST_REGEX" | head -1)"
      echo "$ts $code ${h:--}" >> "$out"
      sleep "$interval"
    done
  ) &
  PROBE_PIDS="$PROBE_PIDS $!"
}
probe_stop() {
  local p
  for p in $PROBE_PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  PROBE_PIDS=""
}
trap probe_stop EXIT

# analyse_probe fichier t_evenement delai_de_grace
analyse_probe() {
  awk -v t0="$2" -v g="${3:-5}" '
    function ok(c) { return (c ~ /^2[0-9][0-9]$/) }
    {
      n++; t = $1; c = $2; h = $3
      if (t < t0) { avant[h]++; if (!ok(c)) eavant++ } else { apres[h]++ }
      if (!ok(c)) {
        err++
        if (t >= t0) { if (first == "") first = t - t0; last = t - t0 }
        if (t >= t0 + g) tard++
        if (!inerr) { inerr = 1; s = t }
      } else if (inerr) { d = t - s; if (d > maxd) maxd = d; inerr = 0 }
      lastt = t
    }
    END {
      if (inerr) { d = lastt - s; if (d > maxd) maxd = d }
      printf "Requêtes envoyées par la sonde       : %d\n", n
      printf "Requêtes en erreur (code non 2xx)    : %d (%.2f %%)\n", err, (n ? 100 * err / n : 0)
      printf "  dont avant l événement             : %d\n", eavant
      if (first != "") printf "Première / dernière erreur           : t0+%.2f s / t0+%.2f s\n", first, last
      else printf "Aucune erreur observée après l événement\n"
      if (first != "") printf "Période dégradée (1re -> dernière err.) : %.2f s\n", last - first
      printf "Plus longue série d erreurs consécutives : %.2f s\n", maxd
      printf "Erreurs au-delà de %d s après t0      : %d\n", g, tard
      printf "Hôtes servis AVANT l événement       :"; for (h in avant) printf " %s=%d", h, avant[h]; printf "\n"
      printf "Hôtes servis APRÈS l événement       :"; for (h in apres) printf " %s=%d", h, apres[h]; printf "\n"
    }' "$1"
}
probe_errors_after() { awk -v l="$2" '$1 >= l && $2 !~ /^2[0-9][0-9]$/ { c++ } END { print c + 0 }' "$1"; }
probe_success_after() { awk -v l="$2" '$1 >= l && $2 ~ /^2[0-9][0-9]$/ { c++ } END { print c + 0 }' "$1"; }
probe_host_after() { awk -v l="$2" -v h="$3" '$1 >= l && $3 == h { c++ } END { print c + 0 }' "$1"; }

# ---------------------------------------------------------------- Vagrant
vm_state() { vagrant status "$1" --machine-readable 2>/dev/null | awk -F, '$3 == "state" { print $4 }' | head -1; }
vm_running() { [ "$(vm_state "$1")" = "running" ]; }
vm_halt() {   # HALT_FORCE=1 (défaut) = arrêt brutal, qui simule une vraie panne
  if [ "${HALT_FORCE:-1}" = 1 ]; then run vagrant halt --force "$1"; else run vagrant halt "$1"; fi
}
vssh() { local vm="$1"; shift; vagrant ssh "$vm" -c "$*" 2>/dev/null | tr -d '\r'; }

# ---------------------------------------------------------------- ApacheBench
# Utilise ab sur l'hôte s'il existe, sinon dans la VM obs (USE_OBS=1 pour forcer).
run_ab() {
  if [ "${USE_OBS:-0}" != 1 ] && command -v ab >/dev/null 2>&1; then
    ab "$@"
  else
    vagrant ssh obs -c "ab $*" 2>/dev/null | tr -d '\r'
  fi
}
ab_base_url() {
  if [ "${USE_OBS:-0}" = 1 ] || ! command -v ab >/dev/null 2>&1; then
    # Depuis la VM obs, localhost:8080 n'existe pas : on vise le réseau privé.
    if curl -s -m 2 -o /dev/null "http://$VIP/info"; then echo "http://$VIP"; else echo "http://$LB1_IP"; fi
  else
    echo "$BASE_URL"
  fi
}
