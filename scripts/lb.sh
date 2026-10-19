#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

NOEUDS=/vagrant/config/noeuds.yml
if [ ! -f "$NOEUDS" ]; then
    echo "ERREUR : $NOEUDS introuvable" >&2
    exit 1
fi

echo "===> Installation de HAProxy, Keepalived, psmisc et Ruby..."
PAQUETS="haproxy keepalived psmisc ruby"
MANQUANTS=""
for p in $PAQUETS; do
    dpkg -s "$p" >/dev/null 2>&1 || MANQUANTS="$MANQUANTS $p"
done
if [ -n "$MANQUANTS" ]; then
    apt-get update -y
    apt-get install -y $MANQUANTS
fi

echo "===> Génération de la configuration HAProxy..."
TMP_HAPROXY=$(mktemp)
trap 'rm -f "$TMP_HAPROXY"' EXIT

ruby - "$NOEUDS" > "$TMP_HAPROXY" << 'RUBY_EOF'
require 'yaml'

noeuds = YAML.load_file(ARGV[0])
champ  = ->(n, k) { n[k.to_s] || n[k.to_sym] }
apps   = noeuds.select { |n| champ.(n, :role) == 'app' }

abort "ERREUR : aucun noeud de role 'app' dans #{ARGV[0]}" if apps.empty?

puts <<~HAPROXY
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    retries 2
    option  redispatch
    timeout connect 2000ms
    timeout client  50000ms
    timeout server  50000ms

frontend http_front
    bind 0.0.0.0:80
    default_backend http_back

listen stats
    bind 0.0.0.0:8404
    stats enable
    stats uri /stats
    stats refresh 2s

backend http_back
    balance roundrobin
    option httpchk GET /sante
    http-check expect status 200
HAPROXY

apps.each do |a|
  puts "    server #{champ.(a, :nom)} #{champ.(a, :ip)}:3000 check inter 1000ms fall 2 rise 2"
end
RUBY_EOF

echo "===> Validation de la configuration HAProxy..."
haproxy -c -f "$TMP_HAPROXY"

systemctl enable haproxy >/dev/null 2>&1
if ! cmp -s "$TMP_HAPROXY" /etc/haproxy/haproxy.cfg; then
    echo "===> Configuration modifiée : rechargement de HAProxy..."
    install -m 644 "$TMP_HAPROXY" /etc/haproxy/haproxy.cfg
    systemctl restart haproxy
else
    echo "===> Configuration HAProxy inchangée."
    systemctl is-active --quiet haproxy || systemctl start haproxy
fi

echo "===> Configuration de Keepalived (VRRP)..."

HOSTNAME=$(hostname)

IFACE=$(ip -o -4 addr show | grep '192.168.' | awk '{print $2}' | head -n 1)
IFACE=${IFACE:-enp0s8}

NET_PREFIX=$(ip -o -4 addr show dev "$IFACE" | awk '{print $4}' | cut -d'.' -f1-3 | head -n 1)
VIP="${NET_PREFIX}.5"

if [ "$HOSTNAME" = "lb1" ]; then
    ROLE="MASTER"
    PRIORITY=101
else
    ROLE="BACKUP"
    PRIORITY=100
fi

VRRP_PASS="${VRRP_PASS:-secr3t_vrrp}"

TMP_KA=$(mktemp)
trap 'rm -f "$TMP_HAPROXY" "$TMP_KA"' EXIT

cat > "$TMP_KA" <<KEEPALIVED_EOF
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 1
    fall 2
    rise 2
    weight 2
}

vrrp_instance VI_1 {
    state $ROLE
    interface $IFACE
    virtual_router_id 51
    priority $PRIORITY
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass ${VRRP_PASS:0:8}
    }

    virtual_ipaddress {
        ${VIP}/24
    }

    track_script {
        chk_haproxy
    }
}
KEEPALIVED_EOF

systemctl enable keepalived >/dev/null 2>&1
if ! cmp -s "$TMP_KA" /etc/keepalived/keepalived.conf; then
    echo "===> Configuration modifiée : redémarrage de Keepalived..."
    install -m 644 "$TMP_KA" /etc/keepalived/keepalived.conf
    systemctl restart keepalived
else
    echo "===> Configuration Keepalived inchangée."
    systemctl is-active --quiet keepalived || systemctl start keepalived
fi

echo "===> Terminé : VIP = ${VIP}, rôle = ${ROLE}, interface = ${IFACE}"