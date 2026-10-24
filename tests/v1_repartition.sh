#!/usr/bin/env bash
# V1 -- Répartition : 20 appels successifs à /info ; les N serveurs doivent apparaître
# tour à tour, avec un écart entre le plus et le moins sollicité inférieur à 20 %.
source "$(dirname "$0")/lib.sh"
start_report V1_repartition
detect_base_url

REQ="${REQUESTS:-20}"
echo "Commande        : for i in \$(seq 1 $REQ); do curl -s $BASE_URL/info; done"
echo
TMP="$(mktemp)"
for i in $(seq 1 "$REQ"); do
  rep="$(curl -s -m 3 "$BASE_URL/info")"
  h="$(hote_de "$rep")"
  printf '%3d  %-40s -> %s\n' "$i" "$rep" "${h:-ERREUR}"
  echo "${h:-ERREUR}" >> "$TMP"
done

echo
echo "Répartition mesurée (attendu : $NB_APP serveurs applicatifs) :"
min=$REQ; max=0; vus=0
for i in $(seq 1 "$NB_APP"); do
  c="$(grep -cx "app$i" "$TMP")"
  pct="$(awk -v c="$c" -v r="$REQ" 'BEGIN { printf "%.1f", 100 * c / r }')"
  printf '  app%-3s : %3d requêtes (%s %%)\n' "$i" "$c" "$pct"
  [ "$c" -lt "$min" ] && min=$c
  [ "$c" -gt "$max" ] && max=$c
  [ "$c" -gt 0 ] && vus=$((vus + 1))
done
erreurs="$(grep -cx 'ERREUR' "$TMP")"
ecart="$(awk -v a="$max" -v b="$min" -v r="$REQ" 'BEGIN { printf "%.1f", 100 * (a - b) / r }')"
echo "  erreurs : $erreurs"
echo
echo "Écart entre le serveur le plus et le moins sollicité : $ecart % (seuil : < 20 %)"
echo
check "Les $NB_APP serveurs applicatifs ont répondu (vus : $vus)" "$([ "$vus" -eq "$NB_APP" ]; echo $?)"
check "Écart de répartition < 20 %" "$(awk -v e="$ecart" 'BEGIN { exit !(e < 20) }'; echo $?)"
check "Aucune requête en erreur" "$([ "$erreurs" -eq 0 ]; echo $?)"
rm -f "$TMP"
end_summary; exit $?
