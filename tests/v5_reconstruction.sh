#!/usr/bin/env bash
# V5 -- Reconstruction : vagrant destroy -f puis vagrant up, sans aucune intervention.
# Chronomètre la durée totale puis vérifie que la plateforme est fonctionnelle.
# DESTRUCTIF : toutes les VM du projet sont détruites. YES=1 pour ne pas demander confirmation.
source "$(dirname "$0")/lib.sh"
start_report V5_reconstruction

confirm "V5 DÉTRUIT toutes les machines virtuelles puis les reconstruit. Continuer ?" || { echo "Annulé."; exit 1; }

T0="$(now)"
run vagrant destroy -f
T1="$(now)"
run vagrant up
RC=$?
T2="$(now)"
check "vagrant up s'est terminé sans erreur" "$RC"

detect_base_url
wait_http "$BASE_URL/sante" '^200$' 180
check "/sante répond 200 sans intervention manuelle" "$?"
rep="$(curl -s -m 3 "$BASE_URL/info")"; echo "\$ curl -s $BASE_URL/info  ->  $rep"
vus="$(for i in $(seq 1 $((NB_APP * 4))); do hote_de "$(curl -s -m 2 "$BASE_URL/info")"; done | sort -u | grep -c .)"
check "Les $NB_APP serveurs applicatifs sont dans la répartition (vus : $vus)" "$([ "$vus" -eq "$NB_APP" ]; echo $?)"
detect_resultat 180          # attend la fin de l'initialisation de la base, puis trouve un matricule valide
check "Route $ROUTE répond 200 (matricule $MATRICULE)" "$?"
echo "bdd2 en recovery : $(vssh bdd2 "sudo -u postgres psql -Atc 'select pg_is_in_recovery()'")   (attendu : t)"
check "bdd2 est bien une réplique" "$([ "$(vssh bdd2 "sudo -u postgres psql -Atc 'select pg_is_in_recovery()'")" = t ]; echo $?)"
echo "Réplicas connectés à bdd1 : $(vssh bdd1 "sudo -u postgres psql -Atc 'select count(*) from pg_stat_replication'")   (attendu : 1)"
check "bdd1 voit une réplique en flux" "$([ "$(vssh bdd1 "sudo -u postgres psql -Atc 'select count(*) from pg_stat_replication'")" = 1 ]; echo $?)"
T3="$(now)"

echo
echo "================ CHRONOMÈTRES V5 ================"
echo "vagrant destroy -f            : $(dur "$T0" "$T1") s"
echo "vagrant up                    : $(dur "$T1" "$T2") s"
echo "Plateforme vérifiée prête     : $(dur "$T0" "$T3") s depuis le début (durée totale de reconstruction)"

end_summary; exit $?
