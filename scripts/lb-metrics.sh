#!/usr/bin/env bash
# scripts/lb-metrics.sh -- expose les métriques HAProxy pour Prometheus (extension E2)
# À exécuter sur lb1 (et lb2 si E1) APRÈS le script du répartiteur.
# Le port 8405 n'est joignable que sur le réseau privé (jamais redirigé vers l'hôte : R8).
# Idempotent : le bloc est retiré puis réécrit, et HAProxy n'est rechargé que si le fichier change.
set -euo pipefail

CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
PORT="${HAPROXY_METRICS_PORT:-8405}"
DEBUT="# BEGIN OBS-METRICS (engendre par scripts/lb-metrics.sh)"
FIN="# END OBS-METRICS"

if ! haproxy -vv 2>/dev/null | grep -qi "prometheus exporter"; then
  echo "[lb-metrics] ERREUR : cet HAProxy n'embarque pas l'exporter Prometheus (version >= 2.4 requise)." >&2
  exit 1
fi
[ -f "$CFG" ] || { echo "[lb-metrics] ERREUR : $CFG introuvable" >&2; exit 1; }

NOUVEAU="$(mktemp)"
# 1. configuration actuelle sans l'ancien bloc
sed "/^# BEGIN OBS-METRICS/,/^# END OBS-METRICS/d" "$CFG" > "$NOUVEAU"
# 2. ajout du bloc
cat >> "$NOUVEAU" <<BLOC
$DEBUT
frontend metrics_prometheus
    bind *:$PORT
    mode http
    timeout client 10s
    http-request use-service prometheus-exporter if { path /metrics }
    http-request return status 404 content-type text/plain string "utiliser /metrics" unless { path /metrics }
    no log
$FIN
BLOC

if cmp -s "$NOUVEAU" "$CFG"; then
  echo "[lb-metrics] configuration inchangée"
  rm -f "$NOUVEAU"
  exit 0
fi

# 3. validation avant de remplacer ; retour arrière en cas d'erreur
cp -a "$CFG" "$CFG.avant-metrics"
cp "$NOUVEAU" "$CFG"
if haproxy -c -f "$CFG" >/dev/null 2>&1; then
  systemctl reload haproxy
  echo "[lb-metrics] métriques exposées sur :$PORT/metrics"
else
  echo "[lb-metrics] ERREUR : configuration invalide, retour arrière" >&2
  haproxy -c -f "$CFG" >&2 || true
  cp -a "$CFG.avant-metrics" "$CFG"
  rm -f "$NOUVEAU"
  exit 1
fi
rm -f "$NOUVEAU"
