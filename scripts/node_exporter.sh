#!/usr/bin/env bash
# scripts/node_exporter.sh -- node_exporter sur la machine courante (CPU, mémoire, réseau, disque)
# Exécuté sur CHAQUE machine virtuelle à superviser. Idempotent.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PAQUET="prometheus-node-exporter"
CONF="/etc/default/prometheus-node-exporter"

if ! dpkg -s "$PAQUET" >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "$PAQUET"
fi

# Écoute sur 0.0.0.0:9100 (et non 127.0.0.1) pour que obs puisse collecter.
NOUVEAU="$(mktemp)"
echo 'ARGS="--web.listen-address=:9100"' > "$NOUVEAU"
if ! cmp -s "$NOUVEAU" "$CONF" 2>/dev/null; then
  install -m 0644 "$NOUVEAU" "$CONF"
  systemctl restart "$PAQUET"
fi
rm -f "$NOUVEAU"

systemctl enable --now "$PAQUET" >/dev/null 2>&1
echo "[node_exporter] OK sur $(hostname) : port 9100"
