#!/usr/bin/env bash
# V2 -- Panne d'un serveur applicatif : vagrant halt app1 PENDANT une charge.
# Le service doit rester disponible ; plus aucune erreur au-delà de 5 s.
# Variables : CIBLE (défaut app1), PRE_DURATION (5 s), POST_DURATION (30 s), HALT_FORCE (1)
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/lib_mesure.sh"
start_report V2_panne_app
detect_base_url

CIBLE="${CIBLE:-app1}"
PRE="${PRE_DURATION:-5}"
POST="${POST_DURATION:-30}"
PROBE="$(mktemp)"
CIBLE_IP="$RESEAU.$((20 + ${CIBLE#app}))"                       # adresse directe du serveur arrêté
CIBLE_URL="${CIBLE_URL:-http://$CIBLE_IP:$APP_PORT/info}"       # sonde directe, sans répartiteur

check "Au moins 2 serveurs applicatifs déclarés (N=$NB_APP)" "$([ "$NB_APP" -ge 2 ]; echo $?)"
vm_running "$CIBLE"
check "$CIBLE est démarré avant le test" "$?"

echo
echo "Charge : une requête toutes les 0,1 s sur $BASE_URL/info pendant tout le test."
probe_start "$BASE_URL/info" "$PROBE" 0.1
sleep "$PRE"

echo "[$(date +%T)] arrêt de $CIBLE pendant la charge"
halt_mesure "$CIBLE" "$CIBLE_URL"
echo "Arrêt effectif de $CIBLE constaté $(dur "$T0" "$T_DOWN") s après le lancement de la commande."
while elapsed_since "$T_DOWN" "$POST"; do sleep 1; done
probe_stop

echo
echo "===== Résultats ====="
echo "--- Mesure A : t0 = lancement de la commande d'arrêt (inclut le délai propre à Vagrant/VirtualBox) ---"
analyse_probe "$PROBE" "$T0" 5
echo
echo "--- Mesure B (référence des contrôles) : t0 = arrêt effectif de $CIBLE, observé en direct ---"
analyse_probe "$PROBE" "$T_DOWN" 5
LIMITE="$(add "$T_DOWN" 5)"
echo
echo "Information (mesure A) : erreurs plus de 5 s après le lancement de la commande : $(probe_errors_after "$PROBE" "$(add "$T0" 5)")"
tard="$(probe_errors_after "$PROBE" "$LIMITE")"
succes="$(probe_success_after "$PROBE" "$LIMITE")"
cible_apres="$(probe_host_after "$PROBE" "$LIMITE" "$CIBLE")"
echo
check "Aucune erreur au-delà de 5 s après l'arrêt effectif (mesure B, constaté : $tard)" "$([ "$tard" -eq 0 ]; echo $?)"
check "Le service répond toujours après l'arrêt ($succes réponses 2xx)" "$([ "$succes" -gt 0 ]; echo $?)"
check "$CIBLE n'est plus sollicité 5 s après son arrêt effectif ($cible_apres requêtes)" "$([ "$cible_apres" -eq 0 ]; echo $?)"

echo
echo "===== Remise en service de $CIBLE ====="
run vagrant up "$CIBLE"
wait_host "$CIBLE" 120
check "$CIBLE est de nouveau intégré à la répartition" "$?"
cp "$PROBE" "$RESULTS_DIR/V2_sonde_brute_$(date +%Y%m%d_%H%M%S).log"
rm -f "$PROBE"
end_summary; exit $?
