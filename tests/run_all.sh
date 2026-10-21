#!/usr/bin/env bash
# Enchaîne les scénarios et affiche un tableau récapitulatif.
#   ./tests/run_all.sh            V1, V2, V3 (N courant), V6 si E1 est présente      (non destructif)
#   ./tests/run_all.sh --complet  V1, V2, V3 (N=2 puis 4), V6, V4, V5                 (V5 détruit tout)
D="$(cd "$(dirname "$0")" && pwd)"
export YES="${YES:-0}"
declare_res=""
lancer() { # lancer nom script [env...]
  local nom="$1" script="$2"; shift 2
  echo; echo "################ $nom ################"
  env "$@" "$D/$script"; local rc=$?
  case $rc in 0) r="SUCCÈS";; 2) r="IGNORÉ (prérequis absent)";; *) r="ÉCHEC";; esac
  declare_res="$declare_res$nom : $r\n"
}
if [ "$1" = "--complet" ]; then
  lancer V1 v1_repartition.sh
  lancer V2 v2_panne_app.sh
  lancer V3 v3_montee_en_charge.sh
  lancer V6 v6_panne_repartiteur.sh
  lancer V4 v4_panne_base.sh
  lancer V5 v5_reconstruction.sh
else
  lancer V1 v1_repartition.sh
  lancer V2 v2_panne_app.sh
  lancer V3 v3_montee_en_charge.sh SKIP_SCALE=1
  lancer V6 v6_panne_repartiteur.sh
fi
echo; echo "================ RÉCAPITULATIF ================"; printf "%b" "$declare_res"
