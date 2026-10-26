#!/usr/bin/env bash
set -euo pipefail

echo "=== Installation du microservice RESULTATS-BF ==="

export DEBIAN_FRONTEND=noninteractive

APP_DIR="/opt/resultats-bf/app"
APP_ENV="/etc/resultats-bf/app.env"
PROJECT_ENV="/vagrant/.env"
NODES_FILE="/vagrant/config/noeuds.yml"
SERVICE_FILE="/etc/systemd/system/app.service"
RESTART_REQUIRED=0
UNIT_CHANGED=0
CONFIG_CHANGED=0
DEPENDENCIES_CHANGED=0
LAST_INSTALL_CHANGED=0

read_project_env() {
    local key="$1"

    if [ ! -f "$PROJECT_ENV" ]; then
        return 0
    fi

    awk -F= -v wanted="$key" '
        $0 ~ "^[[:space:]]*" wanted "[[:space:]]*=" {
            sub(/^[^=]*=/, "")
            sub(/\r$/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            value = $0
        }
        END { print value }
    ' "$PROJECT_ENV"
}

find_node_ip() {
    local node="$1"

    awk -v wanted="$node" '
        $0 ~ "^[[:space:]]*-[[:space:]]*:?[[:space:]]*nom:[[:space:]]*" wanted "[[:space:]]*$" {
            found = 1
            next
        }
        found && $0 ~ "^[[:space:]]*:?[[:space:]]*ip:[[:space:]]*" {
            sub(/^[[:space:]]*:?[[:space:]]*ip:[[:space:]]*/, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' "$NODES_FILE"
}

install_if_changed() {
    local source="$1"
    local destination="$2"
    local mode="$3"

    LAST_INSTALL_CHANGED=0
    if [ ! -f "$destination" ] || ! cmp -s "$source" "$destination"; then
        install -m "$mode" "$source" "$destination"
        RESTART_REQUIRED=1
        LAST_INSTALL_CHANGED=1
    fi
}

escape_systemd_value() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Installer uniquement les paquets absents pour accelerer les rejeux.
PACKAGES=(python3 python3-venv python3-pip)
MISSING=()
for package in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
        | grep -q "install ok installed" || MISSING+=("$package")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    apt-get update -y
    apt-get install -y "${MISSING[@]}"
    RESTART_REQUIRED=1
    DEPENDENCIES_CHANGED=1
fi

mkdir -p "$APP_DIR"
mkdir -p /etc/resultats-bf

install_if_changed /vagrant/app/main.py "$APP_DIR/main.py" 0644
install_if_changed /vagrant/app/requirements.txt "$APP_DIR/requirements.txt" 0644

if [ ! -d "$APP_DIR/venv" ]; then
    python3 -m venv "$APP_DIR/venv"
    RESTART_REQUIRED=1
    DEPENDENCIES_CHANGED=1
fi

REQUIREMENTS_HASH=$(sha256sum "$APP_DIR/requirements.txt" | awk '{print $1}')
INSTALLED_HASH=$(cat "$APP_DIR/venv/.requirements.sha256" 2>/dev/null || true)
if [ "$REQUIREMENTS_HASH" != "$INSTALLED_HASH" ]; then
    "$APP_DIR/venv/bin/pip" install --disable-pip-version-check \
        -r "$APP_DIR/requirements.txt"
    printf '%s\n' "$REQUIREMENTS_HASH" > "$APP_DIR/venv/.requirements.sha256"
    RESTART_REQUIRED=1
    DEPENDENCIES_CHANGED=1
fi

SERVICE_TMP=$(mktemp)
ENV_TMP=$(mktemp)
trap 'rm -f "$SERVICE_TMP" "$ENV_TMP"' EXIT

cat > "$SERVICE_TMP" <<'EOF'
[Unit]
Description=RESULTATS-BF Flask Application
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=vagrant
WorkingDirectory=/opt/resultats-bf/app
EnvironmentFile=/etc/resultats-bf/app.env
ExecStart=/opt/resultats-bf/app/venv/bin/gunicorn --bind 0.0.0.0:3000 --workers 2 --threads 2 --timeout 10 main:app
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=3
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

install_if_changed "$SERVICE_TMP" "$SERVICE_FILE" 0644
UNIT_CHANGED=$LAST_INSTALL_CHANGED

DB_HOST_VALUE="${DB_HOST:-$(read_project_env DB_HOST)}"
if [ -z "$DB_HOST_VALUE" ] && [ -f "$APP_ENV" ]; then
    # Rejeu apres une bascule (R6) : on garde la base deja configuree
    DB_HOST_VALUE=$(sed -n 's/^DB_HOST="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$APP_ENV" | head -n 1)
fi
if [ -z "$DB_HOST_VALUE" ] && [ -f "$NODES_FILE" ]; then
    DB_HOST_VALUE=$(find_node_ip bdd1)
fi
DB_PORT_VALUE="${DB_PORT:-$(read_project_env DB_PORT)}"
DB_USER_VALUE="${DB_USER:-$(read_project_env DB_USER)}"
DB_PASS_VALUE="${DB_PASS:-$(read_project_env DB_PASS)}"
DB_NAME_VALUE="${DB_NAME:-$(read_project_env DB_NAME)}"

DB_PORT_VALUE="${DB_PORT_VALUE:-5432}"
DB_USER_VALUE="${DB_USER_VALUE:-resultats_app}"
DB_NAME_VALUE="${DB_NAME_VALUE:-resultats_bf}"

if [ -z "$DB_HOST_VALUE" ]; then
    echo "ERREUR : adresse de bdd1 introuvable dans $NODES_FILE" >&2
    exit 1
fi

for value in "$DB_HOST_VALUE" "$DB_PORT_VALUE" "$DB_USER_VALUE" \
             "$DB_PASS_VALUE" "$DB_NAME_VALUE"; do
    case "$value" in
        *$'\n'*|*$'\r'*)
            echo "ERREUR : une variable DB contient un retour a la ligne" >&2
            exit 1
            ;;
    esac
done

umask 077
{
    printf 'DB_HOST="%s"\n' "$(escape_systemd_value "$DB_HOST_VALUE")"
    printf 'DB_PORT="%s"\n' "$(escape_systemd_value "$DB_PORT_VALUE")"
    printf 'DB_USER="%s"\n' "$(escape_systemd_value "$DB_USER_VALUE")"
    printf 'DB_PASS="%s"\n' "$(escape_systemd_value "$DB_PASS_VALUE")"
    printf 'DB_NAME="%s"\n' "$(escape_systemd_value "$DB_NAME_VALUE")"
} > "$ENV_TMP"
install_if_changed "$ENV_TMP" "$APP_ENV" 0600
CONFIG_CHANGED=$LAST_INSTALL_CHANGED

if [ -z "$DB_PASS_VALUE" ]; then
    echo "AVERTISSEMENT : DB_PASS est absent de /vagrant/.env."
    echo "L'application demarrera, mais /sante renverra 503."
fi

if [ "$RESTART_REQUIRED" -eq 1 ]; then
    systemctl daemon-reload
fi
systemctl is-enabled --quiet app.service || systemctl enable app.service

if systemctl is-active --quiet app.service; then
    if [ "$RESTART_REQUIRED" -eq 1 ]; then
        if [ "$UNIT_CHANGED" -eq 1 ] || [ "$CONFIG_CHANGED" -eq 1 ] \
            || [ "$DEPENDENCIES_CHANGED" -eq 1 ]; then
            systemctl restart app.service
        else
            # Gunicorn remplace ses workers sans couper le processus maitre.
            systemctl reload app.service
        fi
    fi
else
    systemctl start app.service
fi

echo "=== Installation terminee ==="
