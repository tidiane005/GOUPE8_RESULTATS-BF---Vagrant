#!/usr/bin/env bash
# R2 -- Idempotence : vagrant provision rejoué deux fois ne modifie aucun fichier de configuration.
# Compare les empreintes des fichiers de configuration clés avant / après sur chaque VM démarrée.
source "$(dirname "$0")/lib.sh"
start_report R2_idempotence

FICHIERS="/etc/hosts /etc/haproxy/haproxy.cfg /etc/keepalived/keepalived.conf /etc/postgresql/*/main/postgresql.conf /etc/postgresql/*/main/pg_hba.conf /etc/prometheus/prometheus.yml /etc/default/prometheus /etc/default/prometheus-node-exporter /etc/grafana/provisioning/datasources/prometheus.yml /etc/grafana/provisioning/dashboards/resultats-bf.yml /var/lib/grafana/dashboards/resultats-bf.json"
VMS="$(vagrant status --machine-readable 2>/dev/null | awk -F, '$3 == "state" && $4 == "running" { print $2 }')"
instantane() {
  local vm
  for vm in $VMS; do
    echo "## $vm"
    vssh "$vm" "sudo sh -c 'for f in $FICHIERS; do [ -f \"\$f\" ] && sha256sum \"\$f\"; done; true'"
  done
}
A="$(mktemp)"; B="$(mktemp)"
echo "VM testées : $(echo $VMS)"
instantane > "$A"
run vagrant provision;  check "1er rejeu de vagrant provision sans erreur" "$?"
run vagrant provision;  check "2e rejeu de vagrant provision sans erreur" "$?"
instantane > "$B"
echo; echo "--- différences avant / après (vide = idempotent) ---"
diff "$A" "$B"
check "Aucun fichier de configuration modifié par les rejeux" "$(diff -q "$A" "$B" >/dev/null; echo $?)"
rm -f "$A" "$B"
end_summary; exit $?
