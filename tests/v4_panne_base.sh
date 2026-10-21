#!/usr/bin/env bash
# V4 -- Panne de la base primaire : vagrant halt bdd1.
# Attendu : /sante renvoie proprement 503 (jamais une page blanche ni une erreur de connexion brute),
# puis la procédure de bascule sur bdd2 rétablit le service. On chronomètre l'ensemble.
#
# Variable à ADAPTER à la procédure écrite par l'ingénieur données :
#   BASCULE_CMD  commande (exécutée depuis la racine du dépôt) qui promeut bdd2 et réoriente les
#                serveurs applicatifs. Défaut : vagrant ssh bdd2 -c 'sudo /vagrant/scripts/bascule.sh'
# ATTENTION : ce test laisse bdd1 arrêtée. Pour revenir à l'état initial : V5 (reconstruction).
source "$(dirname "$0")/lib.sh"
start_report V4_panne_base
detect_base_url
detect_resultat 60

# Commande de bascule : vérifiée AVANT d'arrêter bdd1, pour ne jamais laisser la base à l'arrêt sans procédure.
if [ -z "${BASCULE_CMD:-}" ] && [ -f "$ROOT_DIR/scripts/bascule.sh" ]; then
  BASCULE_CMD="vagrant ssh bdd2 -c 'sudo /vagrant/scripts/bascule.sh'"
fi
if [ -z "${BASCULE_CMD:-}" ]; then
  echo "ERREUR : BASCULE_CMD n'est pas défini et scripts/bascule.sh n'existe pas."
  echo "  Voir docs/bascule.md (procédures disponibles : $(ls "$ROOT_DIR"/scripts/promouvoir.sh "$ROOT_DIR"/bascule.ps1 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' '))"
  echo "  Puis : export BASCULE_CMD=\"<commande qui promeut bdd2>\""
  exit 2
fi
verifier_bascule_cmd "$BASCULE_CMD" || exit 2
APP1_IP="$RESEAU.21"
confirm "V4 arrête bdd1 et exécute la bascule ($BASCULE_CMD). Continuer ?" || { echo "Annulé."; exit 1; }

echo "===== État initial ====="
check "/sante répond 200 avant la panne" "$([ "$(http_code "$BASE_URL/sante")" = 200 ]; echo $?)"
check "/resultat répond 200 avant la panne" "$([ "$(http_code "$BASE_URL$ROUTE")" = 200 ]; echo $?)"
echo "bdd2 en recovery (réplique) : $(vssh bdd2 "sudo -u postgres psql -Atc 'select pg_is_in_recovery()'")   (attendu : t)"

PROBE_LB="$(mktemp)"
probe_start "$BASE_URL/sante" "$PROBE_LB" 0.2
sleep 3

echo; echo "===== Panne de bdd1 ====="
T0="$(now)"
echo "[t0 = $(date +%T)]"
vm_halt bdd1
wait_http "$BASE_URL/sante" '^503$' 60
check "/sante via le répartiteur renvoie 503 après la panne" "$?"
T_503="$(now)"
echo "Délai t0 -> premier 503 constaté : $(dur "$T0" "$T_503") s"

echo; echo "--- Réponses pendant la panne (résultat brut) ---"
echo "\$ curl -si http://$APP1_IP:$APP_PORT/sante      (directement sur app1)"
RAW_APP="$(curl -si -m 3 "http://$APP1_IP:$APP_PORT/sante")"; echo "$RAW_APP"; echo
echo "\$ curl -si $BASE_URL/sante                       (via le répartiteur)"
RAW_LB="$(curl -si -m 3 "$BASE_URL/sante")"; echo "$RAW_LB"; echo
echo "\$ curl -si \"$BASE_URL$ROUTE\""
RAW_RES="$(curl -si -m 3 "$BASE_URL$ROUTE")"; echo "$RAW_RES"; echo

code_app="$(http_code "http://$APP1_IP:$APP_PORT/sante")"
corps_app="$(curl -s -m 3 "http://$APP1_IP:$APP_PORT/sante")"
check "app1 /sante renvoie 503 (reçu : $code_app)" "$([ "$code_app" = 503 ]; echo $?)"
check "app1 /sante renvoie un corps non vide (pas de page blanche)" "$([ -n "$corps_app" ]; echo $?)"
check "Aucune erreur de connexion brute côté répartiteur (code reçu : $(http_code "$BASE_URL/sante"))" \
  "$([ "$(http_code "$BASE_URL/sante")" != 000 ]; echo $?)"

echo; echo "===== Procédure de bascule ====="
T_B0="$(now)"
echo "[début bascule = $(date +%T)]"
echo "\$ $BASCULE_CMD"
bash -c "$BASCULE_CMD"
RC=$?
T_B1="$(now)"
echo "(code retour : $RC)"
check "La procédure de bascule se termine sans erreur" "$RC"

echo; echo "===== Retour du service ====="
wait_http "$BASE_URL/sante" '^200$' 120
check "/sante redevient 200" "$?"
T_OK="$(now)"
wait_http "$BASE_URL$ROUTE" '^200$' 30
check "/resultat redevient 200 (lecture sur la nouvelle primaire)" "$?"
T_DATA="$(now)"
echo "bdd2 en recovery : $(vssh bdd2 "sudo -u postgres psql -Atc 'select pg_is_in_recovery()'")   (attendu après promotion : f)"
check "bdd2 est promue (n'est plus en recovery)" "$([ "$(vssh bdd2 "sudo -u postgres psql -Atc 'select pg_is_in_recovery()'")" = f ]; echo $?)"
probe_stop

echo
echo "================ CHRONOMÈTRES V4 ================"
echo "Panne -> premier 503 constaté          : $(dur "$T0" "$T_503") s"
echo "Durée de la procédure de bascule       : $(dur "$T_B0" "$T_B1") s"
echo "Panne -> /sante de nouveau 200         : $(dur "$T0" "$T_OK") s"
echo "Panne -> /resultat de nouveau 200      : $(dur "$T0" "$T_DATA") s   (temps total de remise en service)"
echo
echo "--- Sonde /sante via le répartiteur (t0 = arrêt de bdd1) ---"
analyse_probe "$PROBE_LB" "$T0" 0
cp "$PROBE_LB" "$RESULTS_DIR/V4_sonde_brute_$(date +%Y%m%d_%H%M%S).log"; rm -f "$PROBE_LB"
echo
echo "Rappel : bdd1 reste arrêtée. Lancer V5 pour revenir à la topologie initiale."
end_summary; exit $?
