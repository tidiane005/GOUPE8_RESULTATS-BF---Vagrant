#!/usr/bin/env bash
# V3 -- Montée en charge : ab -n 2000 -c 50 avec N=2 puis N=4.
# Usage : ./tests/v3_montee_en_charge.sh [N ...]        (défaut : 2 4, ordre croissant)
# Variables : RUNS (3 mesures par N), REQUETES (2000), CONCURRENCE (50), MATRICULE,
#             ROUTE (défaut /resultat?matricule=$MATRICULE), SKIP_SCALE=1 (mesurer N courant sans toucher aux VM),
#             USE_OBS=1 (lancer ab depuis la VM obs)
source "$(dirname "$0")/lib.sh"
start_report V3_montee_en_charge
detect_base_url
detect_resultat 60          # trouve un matricule valide (ou utilise MATRICULE / ROUTE si fournis)
if [ "${USE_OBS:-0}" = 1 ] || ! command -v ab >/dev/null 2>&1; then
  vm_running obs || { echo "ERREUR : ab est absent de l'hôte et la VM obs ne tourne pas. Lancer : vagrant up obs"; exit 2; }
fi

LISTE_N="${*:-2 4}"
RUNS="${RUNS:-3}"
REQUETES="${REQUETES:-2000}"
CONC="${CONCURRENCE:-50}"
ROUTE="${ROUTE:-/resultat?matricule=$MATRICULE}"
[ "${SKIP_SCALE:-0}" = 1 ] && LISTE_N="$NB_APP"
RESUME="$(mktemp)"

mettre_a_n() {
  local n="$1" lb
  export NB_APP="$n"
  echo "--- Passage à N=$n serveurs applicatifs ---"
  run vagrant up                                   # crée / redémarre app1..appN (obs n'est pas démarré par défaut)
  for lb in $(noeuds_liste | awk '$2 ~ /^lb/ { print $1 }'); do
    run vagrant provision "$lb"                    # régénère la configuration du répartiteur depuis noeuds.yml
  done
  if vm_running obs; then run vagrant provision obs; fi   # met à jour les cibles Prometheus
  local t=0 vus
  while [ "$t" -lt 120 ]; do
    vus="$(for i in $(seq 1 $((n * 4))); do hote_de "$(curl -s -m 2 "$BASE_URL/info")"; done | sort -u | grep -c .)"
    [ "$vus" -ge "$n" ] && { echo "Répartition effective sur $vus serveurs."; return 0; }
    sleep 3; t=$((t + 3))
  done
  echo "ATTENTION : seulement $vus serveur(s) visible(s) sur $n attendus"; return 1
}

AB_BASE="$(ab_base_url)"
echo "Commande par mesure : ab -n $REQUETES -c $CONC \"$AB_BASE$ROUTE\""
echo "Mesures par configuration : $RUNS (+ 1 échauffement non compté)"
echo

serveurs_vus() {   # nombre de serveurs applicatifs distincts qui répondent via le répartiteur
  for i in $(seq 1 $(($1 * 4))); do hote_de "$(curl -s -m 2 "$BASE_URL/info")"; done | sort -u | grep -c .
}

for N in $LISTE_N; do
  if [ "${SKIP_SCALE:-0}" != 1 ]; then
    mettre_a_n "$N"; pret=$?; check "Plateforme prête avec N=$N" "$pret"
    if [ "$pret" -ne 0 ]; then echo "N=$N ignoré : la plateforme n'est pas prête, aucune mesure n'est faite."; continue; fi
  else
    # SKIP_SCALE : on ne touche pas aux VM ; le N annoncé doit correspondre à ce qui tourne réellement
    vus="$(serveurs_vus "$N")"
    check "SKIP_SCALE : $vus serveur(s) applicatif(s) répondent, $N annoncé (NB_APP)" "$([ "$vus" -eq "$N" ]; echo $?)"
    if [ "$vus" -ne "$N" ]; then
      echo "ERREUR : NB_APP=$N dans ce terminal, mais $vus serveur(s) répondent. Aucune mesure n'est faite."
      echo "  -> soit : export NB_APP=$vus   (mesurer ce qui tourne)"
      echo "  -> soit : retirer SKIP_SCALE=1 (le script démarre alors les serveurs manquants)"
      end_summary; exit 2
    fi
  fi
  code="$(http_code "$BASE_URL$ROUTE")"
  check "La route $ROUTE répond 200 (reçu : $code) -- sinon préciser MATRICULE=…" "$([ "$code" = 200 ]; echo $?)"

  echo "--- Échauffement (200 requêtes, non compté)"
  run_ab -n 200 -c 10 "$AB_BASE$ROUTE" >/dev/null 2>&1
  DEBUT="$(date +%T)"
  for r in $(seq 1 "$RUNS"); do
    echo; echo "=== N=$N -- mesure $r/$RUNS ==="
    OUT="$(mktemp)"
    echo "\$ ab -n $REQUETES -c $CONC \"$AB_BASE$ROUTE\""
    run_ab -n "$REQUETES" -c "$CONC" "$AB_BASE$ROUTE" > "$OUT" 2>&1
    cat "$OUT"
    rps="$(awk '/^Requests per second/ { print $4 }' "$OUT")"
    tpr="$(awk '/^Time per request/ && !/across/ { print $4 }' "$OUT")"
    p50="$(awk '$1 == "50%" { print $2 }' "$OUT")"
    p95="$(awk '$1 == "95%" { print $2 }' "$OUT")"
    p99="$(awk '$1 == "99%" { print $2 }' "$OUT")"
    fail="$(awk '/^Failed requests/ { print $3 }' "$OUT")"
    n2xx="$(awk '/^Non-2xx responses/ { print $3 }' "$OUT")"
    echo "$N $r ${rps:-NA} ${tpr:-NA} ${p50:-NA} ${p95:-NA} ${p99:-NA} ${fail:-NA} ${n2xx:-0}" >> "$RESUME"
    rm -f "$OUT"
    sleep 5
  done
  echo; echo "Fenêtre à capturer dans Grafana pour N=$N : de $DEBUT à $(date +%T)"
done

echo
echo "================ SYNTHÈSE V3 ================"
printf '%-4s %-7s %-10s %-12s %-8s %-8s %-8s %-8s %-8s\n' N mesure "req/s" "moy(ms)" "p50" "p95" "p99" "échecs" "non-2xx"
awk '{ printf "%-4s %-7s %-10s %-12s %-8s %-8s %-8s %-8s %-8s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9 }' "$RESUME"
echo
echo "Médiane du débit (req/s) par configuration :"
for N in $LISTE_N; do
  med="$(awk -v n="$N" '$1 == n && $3 != "NA" { print $3 }' "$RESUME" | sort -n | awk '{ a[NR] = $1 } END { if (NR) printf "%.2f", (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2 }')"
  echo "  N=$N : ${med:-NA} req/s"
  echo "$N $med" >> "$RESUME.med"
done
echo
echo "Lecture : les VM partagent le processeur d'un seul poste (et ab aussi s'il tourne sur l'hôte)."
echo "Un débit qui n'augmente pas, voire baisse, avec N est un résultat à commenter, pas un échec."

erreurs="$(awk '$8 != "NA" && $8 > 0 || $9 > 0 { c++ } END { print c + 0 }' "$RESUME")"
check "Aucune requête en échec / non-2xx pendant les mesures" "$([ "$erreurs" -eq 0 ]; echo $?)"
nb="$(awk '{ print $1 }' "$RESUME.med" | wc -l)"
if [ "$nb" -ge 2 ]; then
  premier="$(head -1 "$RESUME.med" | awk '{ print $2 }')"; dernier="$(tail -1 "$RESUME.med" | awk '{ print $2 }')"
  n1="$(head -1 "$RESUME.med" | awk '{ print $1 }')"; n2="$(tail -1 "$RESUME.med" | awk '{ print $1 }')"
  variation="$(awk -v a="$premier" -v b="$dernier" 'BEGIN { if (a > 0) printf "%+.1f", (b - a) / a * 100; else printf "NA" }')"
  echo "[ INFO ]  Débit médian N=$n1 -> N=$n2 : ${premier} -> ${dernier} req/s (${variation} %)"
  if awk -v a="$premier" -v b="$dernier" 'BEGIN { exit !(b > a) }'; then
    echo "          Le débit augmente avec N."
  else
    echo "          Le débit n'augmente pas avec N : c'est une observation à commenter, pas une erreur (le cahier des charges demande de MESURER)."
    echo "          Pistes à vérifier dans Grafana sur la fenêtre de chaque N : CPU de bdd1 (base commune à tous les serveurs),"
    echo "          CPU des VM, et mémoire disponible du PC (toutes les VM partagent le même processeur)."
  fi
fi
rm -f "$RESUME" "$RESUME.med"
end_summary; exit $?
