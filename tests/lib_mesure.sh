#!/usr/bin/env bash
# tests/lib_mesure.sh -- mesure de l'arrêt effectif d'une VM (utilisé par V2 et V6).
# À sourcer APRÈS lib.sh : source "$(dirname "$0")/lib_mesure.sh"

# halt_mesure vm url_directe : arrête la VM et relève DEUX instants (variables globales) :
#   T0     = lancement de la commande d'arrêt
#   T_DOWN = arrêt effectif : début de la 1re sonde directe (sans répartiteur) qui échoue
# Pourquoi : `vagrant halt --force` met plusieurs secondes avant de couper vraiment la VM ; mesurer
# un temps de reprise à partir du lancement de la commande y ajouterait ce délai, qui n'est pas une
# propriété de la plateforme. Précision de T_DOWN : environ 0,1 à 1 s.
halt_mesure() {
  local vm="$1" url="$2" lim=60 tp hp
  T0="$(now)"; T_DOWN=""
  ( vm_halt "$vm" ) &
  hp=$!
  while elapsed_since "$T0" "$lim"; do
    tp="$(now)"
    if [ "$(http_code "$url" 1)" != 200 ]; then T_DOWN="$tp"; break; fi
    sleep 0.1
  done
  wait "$hp"; HALT_RC=$?
  if [ -z "$T_DOWN" ]; then
    T_DOWN="$T0"
    echo "ATTENTION : l'arrêt effectif de $vm n'a pas pu être observé sur $url ; T_DOWN = T0."
  fi
}
