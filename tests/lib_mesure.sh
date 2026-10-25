#!/usr/bin/env bash
# tests/lib_mesure.sh -- mesure de l'arrêt effectif d'une VM (utilisé par V2 et V6).
# À sourcer APRÈS lib.sh : source "$(dirname "$0")/lib_mesure.sh"

# halt_mesure vm url_directe : arrête la VM et relève DEUX instants (variables globales) :
#   T0     = lancement de la commande d'arrêt
#   T_DOWN = arrêt effectif : début de la 1re d'une série de 3 sondes directes (sans répartiteur) en échec
# Pourquoi : `vagrant halt --force` met plusieurs secondes avant de couper vraiment la VM ; mesurer
# un temps de reprise à partir du lancement de la commande y ajouterait ce délai, qui n'est pas une
# propriété de la plateforme. Garde-fous : (1) la sonde directe doit répondre 200 AVANT l'arrêt, sinon
# rien n'est arrêté ; (2) un échec isolé (requête perdue, lenteur passagère) ne compte pas : il faut
# 3 échecs consécutifs. Précision de T_DOWN : environ 0,1 à 1 s.
halt_mesure() {
  local vm="$1" url="$2" lim=60 tp hp essais=0 fails=0 premier=""
  # (1) la sonde directe doit fonctionner avant la panne
  until [ "$(http_code "$url" 2)" = 200 ]; do
    essais=$((essais + 1))
    if [ "$essais" -ge 5 ]; then
      echo "ERREUR : la sonde directe $url ne répond pas 200 avant l'arrêt : $vm n'est pas arrêtée."
      echo "  -> tester : curl -si $url   (réseau hôte, pare-feu, VM démarrée ?)"
      probe_stop >/dev/null 2>&1; end_summary; exit 2
    fi
    sleep 1
  done
  # (2) arrêt, puis détection de l'arrêt effectif
  T0="$(now)"; T_DOWN=""
  ( vm_halt "$vm" ) &
  hp=$!
  while elapsed_since "$T0" "$lim"; do
    tp="$(now)"
    if [ "$(http_code "$url" 1)" != 200 ]; then
      [ "$fails" -eq 0 ] && premier="$tp"
      fails=$((fails + 1))
      if [ "$fails" -ge 3 ]; then T_DOWN="$premier"; break; fi
    else
      fails=0
    fi
    sleep 0.1
  done
  wait "$hp"; HALT_RC=$?
  if [ -z "$T_DOWN" ]; then
    T_DOWN="$T0"
    echo "ATTENTION : l'arrêt effectif de $vm n'a pas pu être observé sur $url ; T_DOWN = T0."
  fi
}
