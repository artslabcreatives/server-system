#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing .env file. Copy .env.example to .env and fill values." && exit 1
fi
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

for key in DO_TOKEN SERVER_PUBLIC_IP_ADDRESS DOMAIN; do
  if [[ -z "${!key:-}" ]]; then
    echo "Missing required var ${key} in .env" && exit 1
  fi
done

retry() {
  local attempts=$1 delay=$2; shift 2
  local cmd=("$@")
  local tries=0
  until "${cmd[@]}"; do
    tries=$((tries+1))
    if (( tries >= attempts )); then
      return 1
    fi
    sleep "${delay}"
  done
}

create_subdomain() {
  local subdomain=$1 target_ip=$2
  echo "Ensuring DNS record for ${subdomain}.${DOMAIN}"
  local existing=$(curl -s -X GET -H "Authorization: Bearer ${DO_TOKEN}" "https://api.digitalocean.com/v2/domains/${DOMAIN}/records" | jq -r ".domain_records[] | select(.type==\"A\" and .name==\"${subdomain}\") | .id")
  if [[ -n "${existing}" ]]; then
    echo "DNS record already exists (id ${existing}), skipping"
    return
  fi
  retry 3 5 curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${DO_TOKEN}" \
    -d "{\"type\":\"A\",\"name\":\"${subdomain}\",\"data\":\"${target_ip}\",\"ttl\":3600}" \
    "https://api.digitalocean.com/v2/domains/${DOMAIN}/records"
}

prompt_value() {
  local label=$1 default=${2-}
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --inputbox "${label}" 10 60 "${default}" 3>&1 1>&2 2>&3
  else
    read -rp "${label} [${default}]: " ans
    echo "${ans:-${default}}"
  fi
}

install_log="${ROOT_DIR}/logs/nginx-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${ROOT_DIR}/logs"
exec > >(tee -a "${install_log}") 2>&1

FULL_DOMAIN=$(prompt_value "Enter full domain (e.g., app.${DOMAIN})" "app.${DOMAIN}")
DEPLOY_TYPE=$(prompt_value "Type dir or proxy" "dir")

echo "Using domain ${FULL_DOMAIN}"
SUBDOMAIN=${FULL_DOMAIN%%.${DOMAIN}}
create_subdomain "${SUBDOMAIN}" "${SERVER_PUBLIC_IP_ADDRESS}"

if [[ "${DEPLOY_TYPE}" == "dir" ]]; then
  DIR_PATH=$(prompt_value "Enter directory path" "/var/www/html")
  CONFIG_CONTENT=$(cat <<CONF
server {
    listen 80;
    server_name ${FULL_DOMAIN};
    root ${DIR_PATH};
    index index.php index.html index.htm;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }
}
CONF
)
elif [[ "${DEPLOY_TYPE}" == "proxy" ]]; then
  PROXY_PASS=$(prompt_value "Enter proxy target (host:port)" "127.0.0.1:3000")
  CONFIG_CONTENT=$(cat <<CONF
server {
    listen 80;
    server_name ${FULL_DOMAIN};
    location / {
        proxy_pass http://${PROXY_PASS};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
CONF
)
else
  echo "Invalid deploy type" && exit 1
fi

CONF_PATH="/etc/nginx/sites-available/${FULL_DOMAIN}"
echo "${CONFIG_CONTENT}" | sudo tee "${CONF_PATH}" >/dev/null
sudo ln -sf "${CONF_PATH}" "/etc/nginx/sites-enabled/${FULL_DOMAIN}"
sudo nginx -t
sudo systemctl reload nginx

echo "Nginx config written to ${CONF_PATH} (log: ${install_log})"
