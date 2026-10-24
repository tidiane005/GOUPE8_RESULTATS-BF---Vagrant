#!/usr/bin/env bash
# V6 -- Panne du répartiteur (extension E1) : vagrant halt lb1.
# Le service doit rester joignable à la même adresse (IP virtuelle .5), reprise en moins de 5 s.
# Variables : LB_ACTIF (lb1), LB_PASSIF (lb2), POST_DURATION (20 s), HALT_FORCE (1)
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/lib_mesure.sh"
start_report V6_panne_repartiteur

LB_ACTIF="${LB_ACTIF:-lb1}"; LB_PASSIF="${LB_PASSIF:-lb2}"
POST="${POST_DURATION:-20}"
URL="http://$VIP/info"
ACTIF_IP="$RESEAU.$((10 + ${LB_ACTIF#lb}))"                     # adresse propre du répartiteur arrêté
ACTIF_URL="${ACTIF_URL:-http://$ACTIF_IP/info}"                  # sonde directe (sans IP virtuelle)
echo "Adresse testée (IP virtuelle) : $URL"

if ! curl -s -m 2 -o /dev/null "$URL"; then
  echo "IP virtuelle $VIP injoignable : l'extension E1 (lb2 + keepalived) n'est pas démarrée."
  echo "Démarrer lb2 puis relancer : vagrant up lb2"
  exit 2
fi
vm_running "$LB_PASSIF"; check "$LB_PASSIF est démarré" "$?"
vm_running "$LB_ACTIF";  check "$LB_ACTIF est démarré" "$?"

PROBE="$(mktemp)"
probe_start "$URL" "$PROBE" 0.1
sleep 5
echo "[$(date +%T)] arrêt de $LB_ACTIF"
halt_mesure "$LB_ACTIF" "$ACTIF_URL"
echo "Arrêt effectif de $LB_ACTIF constaté $(dur "$T0" "$T_DOWN") s après le lancement de la commande."
while elapsed_since "$T_DOWN" "$POST"; do sleep 1; done
probe_stop

echo
echo "===== Résultats ====="
echo "--- Mesure A : t0 = lancement de la commande d'arrêt (inclut le délai propre à Vagrant/VirtualBox) ---"
analyse_probe "$PROBE" "$T0" 5
echo
echo "--- Mesure B (référence des contrôles) : t0 = arrêt effectif de $LB_ACTIF, observé en direct ---"
analyse_probe "$PROBE" "$T_DOWN" 5
echo "Information (mesure A) : erreurs plus de 5 s après le lancement de la commande : $(probe_errors_after "$PROBE" "$(add "$T0" 5)")"
tard="$(probe_errors_after "$PROBE" "$(add "$T_DOWN" 5)")"
succes="$(probe_success_after "$PROBE" "$(add "$T_DOWN" 5)")"
maxd="$(awk -v t0="$T0" '
  function ok(c){ return c ~ /^2[0-9][0-9]$/ }
  { if (!ok($2)) { if (!e) { e = 1; s = $1 } ; l = $1 } else if (e) { d = $1 - s; if (d > m) m = d; e = 0 } }
  END { if (e) { d = l - s; if (d > m) m = d } printf "%.2f", m }' "$PROBE")"
echo
echo "Temps de reprise après bascule VRRP (plus longue interruption) : $maxd s"
echo "Adresse VIP $VIP sur $LB_PASSIF : $(vssh "$LB_PASSIF" "ip -4 addr show | grep -c '$VIP'")   (attendu : 1)"
echo
check "Le service répond toujours à la même adresse ($succes réponses 2xx après 5 s)" "$([ "$succes" -gt 0 ]; echo $?)"
check "Reprise en moins de 5 s après l'arrêt effectif : aucune erreur au-delà de 5 s (mesure B, $tard)" "$([ "$tard" -eq 0 ]; echo $?)"
check "$LB_PASSIF porte l'IP virtuelle" "$([ "$(vssh "$LB_PASSIF" "ip -4 addr show | grep -c '$VIP'")" -ge 1 ]; echo $?)"

echo; echo "===== Remise en service de $LB_ACTIF ====="
run vagrant up "$LB_ACTIF"
wait_http "$URL" '^200$' 60; check "Service toujours joignable après le retour de $LB_ACTIF" "$?"
cp "$PROBE" "$RESULTS_DIR/V6_sonde_brute_$(date +%Y%m%d_%H%M%S).log"; rm -f "$PROBE"
end_summary; exit $?
