#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE_FILE="${HOME}/.server-system/state.json"
LOG_DIR="${ROOT_DIR}/logs"
LOG_FILE="${LOG_DIR}/run-$(date +%Y%m%d-%H%M%S).log"
ENV_FILE="${ROOT_DIR}/.env"

mkdir -p "${LOG_DIR}" "$(dirname "${STATE_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

cleanup() {
  local status=$?
  if [[ ${status} -ne 0 ]]; then
    echo "[!] Script exited with status ${status} at line ${BASH_LINENO[0]}"
  fi
}
trap cleanup EXIT

require_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[!] Missing .env file. Copy .env.example to .env and populate required values."
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  local missing=()
  for key in DO_TOKEN SERVER_PUBLIC_IP_ADDRESS DOMAIN MYSQL_ROOT_PASSWORD MYSQL_APP_USER MYSQL_APP_PASSWORD UPTIME_API_TOKEN GITHUB_TOKEN; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("${key}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "[!] Missing required environment keys: ${missing[*]}"
    exit 1
  fi
}

retry() {
  local attempts=$1 delay=$2; shift 2
  local cmd=("$@")
  local count=0
  until "${cmd[@]}"; do
    count=$((count + 1))
    if (( count >= attempts )); then
      echo "[!] Command failed after ${attempts} attempts: ${cmd[*]}"
      return 1
    fi
    echo "[*] Retry ${count}/${attempts} for: ${cmd[*]}" && sleep "${delay}"
  done
}

init_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    cat > "${STATE_FILE}" <<'STATE'
{"stages": {}, "actions": []}
STATE
  fi
}

update_state() {
  local stage=$1 status=$2
  python - <<'PY'
import json, os
state_file = os.environ['STATE_FILE']
stage = os.environ['stage']
status = os.environ['status']
with open(state_file) as f:
    data = json.load(f)
data.setdefault('stages', {})[stage] = status
with open(state_file, 'w') as f:
    json.dump(data, f, indent=2)
PY
}

record_action() {
  local type=$1 payload=$2
  python - <<'PY'
import json, os
state_file = os.environ['STATE_FILE']
type_ = os.environ['type']
payload = os.environ['payload']
with open(state_file) as f:
    data = json.load(f)
data.setdefault('actions', []).append({'type': type_, 'payload': payload})
with open(state_file, 'w') as f:
    json.dump(data, f, indent=2)
PY
}

load_profile_defaults() {
  local profile=$1
  case "${profile}" in
    laravel)
      PROFILE_WEBROOT="/var/www/${SITE_NAME}/public"
      PROFILE_DB_NAME="${SITE_NAME//./_}_db"
      PROFILE_TYPE="php"
      ;;
    wordpress)
      PROFILE_WEBROOT="/var/www/${SITE_NAME}"
      PROFILE_DB_NAME="${SITE_NAME//./_}_db"
      PROFILE_TYPE="php"
      ;;
    static-dir)
      PROFILE_WEBROOT="/var/www/${SITE_NAME}"
      PROFILE_DB_NAME=""
      PROFILE_TYPE="static"
      ;;
    reverse-proxy)
      PROFILE_WEBROOT=""
      PROFILE_DB_NAME=""
      PROFILE_TYPE="proxy"
      ;;
    npm-app)
      PROFILE_WEBROOT="/var/www/${SITE_NAME}"
      PROFILE_DB_NAME=""
      PROFILE_TYPE="npm"
      ;;
    docker-compose)
      PROFILE_WEBROOT="/srv/${SITE_NAME}"
      PROFILE_DB_NAME=""
      PROFILE_TYPE="docker"
      ;;
    *)
      echo "[!] Unknown profile ${profile}" && exit 1
      ;;
  esac
}

ui_select() {
  local title=$1 text=$2 options=(${@:3})
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --title "${title}" --menu "${text}" 20 78 10 "${options[@]}" 3>&1 1>&2 2>&3
  else
    local choice
    echo "${text}" && select choice in "${options[@]}"; do echo "${choice}"; break; done
  fi
}

ui_input() {
  local prompt=$1 default=${2-}
  if command -v whiptail >/dev/null 2>&1; then
    whiptail --inputbox "${prompt}" 10 60 "${default}" 3>&1 1>&2 2>&3
  else
    read -rp "${prompt} [${default}]: " response
    echo "${response:-${default}}"
  fi
}

summary=()
log_stage() {
  local stage=$1 status=$2
  summary+=("${stage}:${status}")
  stage=${stage} status=${status} STATE_FILE=${STATE_FILE} update_state
}

spinner() {
  local pid=$1 msg=$2
  local chars='|/-\\'
  local i=0
  while kill -0 "${pid}" >/dev/null 2>&1; do
    printf "\r[%c] %s" "${chars:i++%${#chars}:1}" "${msg}"
    sleep 0.2
  done
  printf "\r[✓] %s\n" "${msg}"
}

run_with_spinner() {
  local message=$1; shift
  ("$@") &
  local cmd_pid=$!
  spinner "${cmd_pid}" "${message}"
  wait "${cmd_pid}"
}

ensure_packages() {
  local packages=(curl jq git nginx mysql-server certbot python3-certbot-nginx whiptail)
  retry 3 5 sudo apt-get update
  for pkg in "${packages[@]}"; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
      retry 3 5 sudo apt-get install -y "${pkg}"
    fi
  done
}

create_dns_record() {
  local name=$1
  echo "[*] Ensuring DNS record for ${name}.${DOMAIN}"
  local existing=$(curl -s -X GET -H "Authorization: Bearer ${DO_TOKEN}" "https://api.digitalocean.com/v2/domains/${DOMAIN}/records" | jq -r ".domain_records[] | select(.type==\"A\" and .name==\"${name}\") | .id")
  if [[ -n "${existing}" ]]; then
    echo "[+] DNS record already exists (id: ${existing}), skipping create"
    return
  fi
  retry 3 5 curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${DO_TOKEN}" \
    -d "{\"type\":\"A\",\"name\":\"${name}\",\"data\":\"${SERVER_PUBLIC_IP_ADDRESS}\",\"ttl\":3600}" \
    "https://api.digitalocean.com/v2/domains/${DOMAIN}/records"
  record_action dns "${name}"
}

setup_mysql() {
  local db=$1 user=$2 pass=$3
  if [[ -z "${db}" ]]; then return; fi
  echo "[*] Ensuring MySQL database ${db} and user ${user}"
  mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;" || true
  mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${pass}';" || true
  mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'%'; FLUSH PRIVILEGES;"
  record_action mysql "${db}:${user}"
}

write_nginx_config() {
  local domain=$1 type=$2 webroot=$3 proxy=$4
  local conf="/etc/nginx/sites-available/${domain}"
  if [[ -f "${conf}" ]]; then
    echo "[+] Nginx config exists for ${domain}, skipping"
  else
    case "${type}" in
      php)
        cat > "${conf}" <<CONF
server {
    listen 80;
    server_name ${domain};
    root ${webroot};
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
        ;;
      static)
        cat > "${conf}" <<CONF
server {
    listen 80;
    server_name ${domain};
    root ${webroot};
    index index.html index.htm;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
CONF
        ;;
      proxy)
        cat > "${conf}" <<CONF
server {
    listen 80;
    server_name ${domain};
    location / {
        proxy_pass http://${proxy};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
CONF
        ;;
    esac
    ln -s "${conf}" "/etc/nginx/sites-enabled/${domain}" || true
    record_action nginx "${domain}"
  fi
  nginx -t && systemctl reload nginx
}

issue_certificate() {
  local domain=$1
  echo "[*] Ensuring certificate for ${domain}"
  if sudo certbot certificates | grep -q "${domain}"; then
    echo "[+] Certificate already exists for ${domain}"
    return
  fi
  retry 2 10 sudo certbot --nginx -d "${domain}" --non-interactive --agree-tos -m "admin@${DOMAIN}" || true
}

deploy_app() {
  local profile=$1
  case "${profile}" in
    laravel)
      mkdir -p "${PROFILE_WEBROOT%/public}" && cd "${PROFILE_WEBROOT%/public}"
      if [[ ! -d .git ]]; then
        composer create-project --prefer-dist "laravel/laravel:^10.0" .
        record_action deploy "${PROFILE_WEBROOT%/public}"
      fi
      ;;
    wordpress)
      mkdir -p "${PROFILE_WEBROOT}" && cd "${PROFILE_WEBROOT}"
      if [[ ! -f wp-config.php ]]; then
        wp core download --allow-root
        wp config create --dbname="${PROFILE_DB_NAME}" --dbuser="${MYSQL_APP_USER}" --dbpass="${MYSQL_APP_PASSWORD}" --dbhost="localhost" --allow-root
        record_action deploy "${PROFILE_WEBROOT}"
      fi
      ;;
    npm-app)
      mkdir -p "${PROFILE_WEBROOT}" && record_action deploy "${PROFILE_WEBROOT}"
      ;;
    docker-compose)
      mkdir -p "${PROFILE_WEBROOT}" && record_action deploy "${PROFILE_WEBROOT}"
      ;;
    static-dir|reverse-proxy)
      mkdir -p "${PROFILE_WEBROOT:-/var/www/${SITE_NAME}}" && record_action deploy "${PROFILE_WEBROOT:-/var/www/${SITE_NAME}}"
      ;;
  esac
}

setup_uptime_robot() {
  local domain=$1
  local url="https://${domain}"
  echo "[*] Ensuring UptimeRobot monitor for ${url}"
  local payload=$(jq -n --arg name "${domain}" --arg url "${url}" '{friendly_name:$name,url:$url,type:1}')
  retry 3 5 curl -s -X POST "https://api.uptimerobot.com/v2/newMonitor" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${UPTIME_API_TOKEN}" \
    -d "${payload}" >/dev/null || true
}

setup_repo() {
  local name=$1
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then return; fi
  echo "[*] Ensuring GitHub repo ${name}"
  curl -s -H "Authorization: token ${GITHUB_TOKEN}" "https://api.github.com/repos/${GITHUB_OWNER:-artslabcreatives}/${name}" | grep -q '"id"' && return
  retry 2 5 curl -s -X POST "https://api.github.com/orgs/${GITHUB_OWNER:-artslabcreatives}/repos" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -d "{\"name\":\"${name}\",\"private\":true}"
  record_action repo "${name}"
}

rollback() {
  local dry_run=${1:-false}
  require_env
  init_state
  echo "[!] Rollback requested. Dry run: ${dry_run}"
  read -rp "Proceed with rollback? (y/N): " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    echo "Rollback aborted." && exit 0
  fi
  python - <<'PY'
import json, subprocess, os, sys
dry_run = os.environ.get('DRY_RUN', 'false').lower() == 'true'
state_file = os.environ['STATE_FILE']
with open(state_file) as f:
    data = json.load(f)
actions = data.get('actions', [])
print(f"Planned undo steps: {len(actions)}")
if dry_run:
    for action in reversed(actions):
        print(f"DRY RUN: would rollback {action['type']} -> {action['payload']}")
    sys.exit(0)
for action in reversed(actions):
    t = action['type']
    payload = action['payload']
    if t == 'dns':
        name = payload
        print(f"Removing DNS record {name}")
        subprocess.run(["curl","-s","-X","GET","-H",f"Authorization: Bearer {os.environ['DO_TOKEN']}",f"https://api.digitalocean.com/v2/domains/{os.environ['DOMAIN']}/records"],check=False,stdout=subprocess.PIPE)
    elif t == 'nginx':
        domain = payload
        subprocess.run(["sudo","rm","-f",f"/etc/nginx/sites-enabled/{domain}",f"/etc/nginx/sites-available/{domain}"],check=False)
    elif t == 'mysql':
        db,user = payload.split(":",1)
        subprocess.run(["mysql","-u","root",f"-p{os.environ['MYSQL_ROOT_PASSWORD']}","-e",f"DROP DATABASE IF EXISTS `{db}`;"],check=False)
        subprocess.run(["mysql","-u","root",f"-p{os.environ['MYSQL_ROOT_PASSWORD']}","-e",f"DROP USER IF EXISTS '{user}'@'%';"],check=False)
    elif t == 'deploy':
        path = payload
        subprocess.run(["sudo","rm","-rf",path],check=False)
print("Rollback completed. You may reload nginx manually if needed.")
PY
  exit 0
}

main() {
  local profile=${1:-${DEFAULT_PROFILE:-laravel}}
  local dry_run=false
  if [[ "${profile}" == "--rollback" ]]; then
    if [[ "${2:-}" == "--dry-run" ]]; then
      dry_run=true
    fi
    rollback "${dry_run}"
  fi
  require_env
  init_state
  run_with_spinner "Installing prerequisites" ensure_packages
  SITE_NAME=$(ui_input "Enter site name (without domain)" "app")
  FULL_DOMAIN=$(ui_input "Enter domain (sub.example.com or leave blank for app.${DOMAIN})" "${SITE_NAME}.${DOMAIN}")
  SERVICE_PROFILE=$(ui_select "Service Profile" "Choose deployment profile" \
    laravel "Laravel" wordpress "WordPress" static-dir "Static directory" reverse-proxy "Reverse proxy" npm-app "NPM app" docker-compose "Docker compose")
  PROFILE_CHOICE=${SERVICE_PROFILE:-${profile}}
  SITE_NAME=${FULL_DOMAIN%%.${DOMAIN}}
  load_profile_defaults "${PROFILE_CHOICE}"

  log_stage packages done
  run_with_spinner "Configuring DNS" create_dns_record "${SITE_NAME}"
  log_stage dns done

  run_with_spinner "Configuring database" setup_mysql "${PROFILE_DB_NAME}" "${MYSQL_APP_USER}" "${MYSQL_APP_PASSWORD}"
  log_stage mysql done

  if [[ "${PROFILE_TYPE}" == "proxy" ]]; then
    PROXY_TARGET=$(ui_input "Enter proxy target (host:port)" "127.0.0.1:3000")
  fi
  run_with_spinner "Writing nginx config" write_nginx_config "${FULL_DOMAIN}" "${PROFILE_TYPE}" "${PROFILE_WEBROOT}" "${PROXY_TARGET:-}" && log_stage nginx done
  run_with_spinner "Issuing certificate" issue_certificate "${FULL_DOMAIN}" && log_stage certbot done
  run_with_spinner "Deploying application" deploy_app "${PROFILE_CHOICE}" && log_stage deploy done
  run_with_spinner "Registering monitor" setup_uptime_robot "${FULL_DOMAIN}" && log_stage uptime done
  run_with_spinner "Syncing repository" setup_repo "${SITE_NAME}" && log_stage repo done

  echo "\nSummary:"
  printf "%-15s | %-10s\n" "Stage" "Status"
  printf '%.0s-' {1..30}; printf "\n"
  for item in "${summary[@]}"; do
    IFS=":" read -r stage status <<<"${item}"; printf "%-15s | %-10s\n" "${stage}" "${status}"; done
  echo "Log file: ${LOG_FILE}"
  echo "State file: ${STATE_FILE}"
}

main "$@"
