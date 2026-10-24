#!/usr/bin/env bash
# scripts/obs.sh -- Machine obs : Prometheus + Grafana (extension E2)
#
# - Prometheus collecte node_exporter (toutes les VM) et HAProxy (lb*).
#   Les cibles sont engendrées depuis /vagrant/config/noeuds.yml : aucune adresse en dur.
# - Grafana est provisionné par fichiers : source de données + tableau de bord.
# - Idempotent : un fichier n'est remplacé, et un service redémarré, que si le contenu change.
#
# Variable d'environnement requise (fournie par le Vagrantfile depuis .env) :
#   GRAFANA_ADMIN_PASSWORD
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

NOEUDS_YML="/vagrant/config/noeuds.yml"
SRC_GRAFANA="/vagrant/config/grafana"
HAPROXY_METRICS_PORT=8405

if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
  echo "[obs] ERREUR : GRAFANA_ADMIN_PASSWORD absent (créer .env à partir de .env.exemple)." >&2
  exit 1
fi
[ -f "$NOEUDS_YML" ] || { echo "[obs] ERREUR : $NOEUDS_YML introuvable" >&2; exit 1; }

# Copie src -> dest seulement si le contenu diffère. Code retour 0 = fichier modifié.
installer_si_change() {
  local src="$1" dest="$2" mode="${3:-0644}"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then return 1; fi
  install -D -m "$mode" "$src" "$dest"
  return 0
}

# ------------------------------------------------------------------ 1. Paquets
# Un seul apt-get update et un seul apt-get install (connexion lente).
if ! command -v curl >/dev/null || ! command -v gpg >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends curl gnupg ca-certificates
fi

if [ ! -f /etc/apt/keyrings/grafana.gpg ]; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/grafana.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /tmp/grafana.list
installer_si_change /tmp/grafana.list /etc/apt/sources.list.d/grafana.list || true

PAQUETS="grafana prometheus prometheus-node-exporter python3-yaml apache2-utils"
MANQUANTS=""
for p in $PAQUETS; do dpkg -s "$p" >/dev/null 2>&1 || MANQUANTS="$MANQUANTS $p"; done
if [ -n "$MANQUANTS" ]; then
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $MANQUANTS
fi

# ------------------------------------------------------------------ 2. node_exporter sur obs
bash /vagrant/scripts/node_exporter.sh

# ------------------------------------------------------------------ 3. Prometheus
python3 /vagrant/scripts/gen_prometheus_config.py "$NOEUDS_YML" "$HAPROXY_METRICS_PORT" > /tmp/prometheus.yml
promtool check config /tmp/prometheus.yml >/dev/null

CHANGE_PROM=0
installer_si_change /tmp/prometheus.yml /etc/prometheus/prometheus.yml && CHANGE_PROM=1

install -d -o prometheus -g prometheus /var/lib/prometheus/metrics2
cat > /tmp/prometheus.default <<'FIN_ARGS'
ARGS="--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/metrics2 --storage.tsdb.retention.time=2d --web.listen-address=0.0.0.0:9090"
FIN_ARGS
installer_si_change /tmp/prometheus.default /etc/default/prometheus && CHANGE_PROM=1

systemctl enable prometheus >/dev/null 2>&1
if [ "$CHANGE_PROM" -eq 1 ] || ! systemctl is-active --quiet prometheus; then
  systemctl restart prometheus
fi

# ------------------------------------------------------------------ 4. Grafana
# Le mot de passe administrateur ne vit que dans la VM (jamais dans le dépôt).
install -d -m 0755 /etc/systemd/system/grafana-server.service.d
printf '[Service]\nEnvironmentFile=/etc/grafana/grafana-obs.env\n' > /tmp/grafana-override.conf
CHANGE_GRAF=0
installer_si_change /tmp/grafana-override.conf /etc/systemd/system/grafana-server.service.d/override.conf && CHANGE_GRAF=1

printf 'GF_SECURITY_ADMIN_PASSWORD=%s\nGF_ANALYTICS_REPORTING_ENABLED=false\nGF_ANALYTICS_CHECK_FOR_UPDATES=false\n' \
  "$GRAFANA_ADMIN_PASSWORD" > /tmp/grafana-obs.env
installer_si_change /tmp/grafana-obs.env /etc/grafana/grafana-obs.env 0600 && CHANGE_GRAF=1

installer_si_change "$SRC_GRAFANA/datasource.yml" /etc/grafana/provisioning/datasources/prometheus.yml && CHANGE_GRAF=1
installer_si_change "$SRC_GRAFANA/dashboards.yml" /etc/grafana/provisioning/dashboards/resultats-bf.yml && CHANGE_GRAF=1
# Le tableau de bord est relu automatiquement par Grafana (pas de redémarrage nécessaire).
installer_si_change "$SRC_GRAFANA/resultats-bf.json" /var/lib/grafana/dashboards/resultats-bf.json || true
chown -R root:grafana /var/lib/grafana/dashboards

systemctl daemon-reload
systemctl enable grafana-server >/dev/null 2>&1
if [ "$CHANGE_GRAF" -eq 1 ] || ! systemctl is-active --quiet grafana-server; then
  systemctl restart grafana-server
fi

# Attente de Grafana puis vérification du mot de passe.
for _ in $(seq 1 60); do
  curl -fs http://localhost:3000/api/health >/dev/null 2>&1 && break
  sleep 1
done
if ! curl -fs -u "admin:${GRAFANA_ADMIN_PASSWORD}" http://localhost:3000/api/user >/dev/null 2>&1; then
  # Base déjà initialisée avec un autre mot de passe : on le réaligne sur .env.
  grafana cli admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" >/dev/null 2>&1 \
    || grafana-cli admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" >/dev/null 2>&1 || true
fi

IP_OBS="$(hostname -I | tr ' ' '\n' | grep -E '^192\.168\.' | head -1)"
echo "[obs] Prometheus : http://${IP_OBS}:9090   (Status > Targets)"
echo "[obs] Grafana    : http://${IP_OBS}:3000   (admin / mot de passe du .env)"
