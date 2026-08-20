#!/bin/bash
#
# ============================================================================
#  Remnawave All-in-One Manager
#  Единый скрипт управления Remnawave: панель, нода, сертификаты, BBR,
#  IPv6, WARP, UFW, SSH-ключи, Fail2ban.
#
#  Основан на:
#    - eGamesAPI/remnawave-reverse-proxy  (MIT License)
#    - Rrezzak09VPN/remnanode-VLESS-Reality-Hysteria2 (написан заново)
#
#  Лицензия: MIT
#  Copyright (c) 2026
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#  SOFTWARE.
# ============================================================================

SCRIPT_VERSION="0.0.1 Beta"
SCRIPT_URL="https://raw.githubusercontent.com/user-levap/rw-script/main/install_remnawave.sh"

DIR_REMNAWAVE="/usr/local/remnawave_reverse/"
PANEL_DIR="/opt/remnawave"
NODE_DIR="/opt/remnanode"
CONFIG_FILE="${DIR_REMNAWAVE}panel.conf"
LANG_FILE="${DIR_REMNAWAVE}selected_language"

# ---------------------------------------------------------------------------
# Цвета и утилиты
# ---------------------------------------------------------------------------
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_WHITE="\033[1;37m"
COLOR_RED="\033[1;31m"
COLOR_GRAY='\033[0;90m'
COLOR_BLUE='\033[0;34m'

question() { echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"; }
reading() { read -rp "$(question "$1")" "$2"; }
error() { echo -e "${COLOR_RED}$*${COLOR_RESET}"; exit 1; }
log_ok() { echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $1"; }
log_info() { echo -e "${COLOR_BLUE}[•]${COLOR_RESET} $1"; }
log_warn() { echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}[✗]${COLOR_RESET} $1"; }

log_clear() { sed -i -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' "${DIR_REMNAWAVE}remnawave_manager.log" 2>/dev/null; }

log_entry() {
  mkdir -p "${DIR_REMNAWAVE}"
  LOGFILE="${DIR_REMNAWAVE}remnawave_manager.log"
  exec > >(tee -a "$LOGFILE") 2>&1
}

spinner() {
  local pid=$1
  local text=$2
  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local delay=0.1
  printf "${COLOR_GREEN}%s${COLOR_RESET}" "$text" > /dev/tty
  while kill -0 "$pid" 2>/dev/null; do
    for (( i=0; i<${#spinstr}; i++ )); do
      printf "\r${COLOR_GREEN}[%s] %s${COLOR_RESET}" "${spinstr:$i:1}" "$text" > /dev/tty
      sleep $delay
    done
  done
  printf "\r\033[K" > /dev/tty
}

generate_user() {
  local length=8
  tr -dc 'a-zA-Z' < /dev/urandom | fold -w $length | head -n 1
}

generate_password() {
  local length=24
  local password=""
  local all_chars='A-Za-z0-9!@#%^&*()_+'
  password+=$(head /dev/urandom | tr -dc 'A-Z' | head -c 1)
  password+=$(head /dev/urandom | tr -dc 'a-z' | head -c 1)
  password+=$(head /dev/urandom | tr -dc '0-9' | head -c 1)
  password+=$(head /dev/urandom | tr -dc '!@#%^&*()_+' | head -c 3)
  password+=$(head /dev/urandom | tr -dc "$all_chars" | head -c $(($length - 6)))
  echo "$password" | fold -w1 | shuf | tr -d '\n'
}

# ---------------------------------------------------------------------------
# Проверка ОС и прав
# ---------------------------------------------------------------------------
check_os() {
  if ! grep -qE "ubuntu|debian" /etc/os-release; then
    error "Поддерживаются только Ubuntu и Debian."
  fi
  local os_id=$(grep -oP '(?<=^ID=).*' /etc/os-release | tr -d '"')
  local os_codename=$(grep -oP '(?<=^VERSION_CODENAME=).*' /etc/os-release | tr -d '"')
  if [ "$os_id" = "ubuntu" ]; then
    case "$os_codename" in
      jammy|noble) : ;;
      *)
        # 26.04 пока не вышел стабильно; пропускаем мягко
        if grep -qE "26\.04" /etc/os-release; then :; else
          log_warn "Ubuntu ${os_codename} — не проверялась, продолжаем на свой риск."
        fi
        ;;
    esac
  elif [ "$os_id" = "debian" ]; then
    case "$os_codename" in
      bookworm|trixie) : ;;
      *) log_warn "Debian ${os_codename} — не проверялась, продолжаем на свой риск." ;;
    esac
  fi
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    error "Скрипт требует права root. Запустите: sudo bash $0"
  fi
}

# ---------------------------------------------------------------------------
# Установка пакетов
# ---------------------------------------------------------------------------
install_packages() {
  log_info "Установка системных пакетов..."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || error "Не удалось обновить список пакетов"

  local pkgs="ca-certificates curl jq ufw wget gnupg unzip nano dialog git certbot python3-certbot-dns-cloudflare cron dnsutils coreutils gawk python3-pip openssl"
  apt-get install -y $pkgs || error "Не удалось установить системные пакеты"

  if ! dpkg -l | grep -q '^ii.*fail2ban'; then
    apt-get install -y fail2ban || log_warn "fail2ban не установился"
  fi

  # Docker
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    log_info "Установка Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || error "Не удалось скачать Docker"
    sh /tmp/get-docker.sh || error "Ошибка установки Docker"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || error "Docker daemon не работает"

  touch "${DIR_REMNAWAVE}install_packages" 2>/dev/null
  log_ok "Пакеты установлены"
}

ensure_packages() {
  if [ ! -f "${DIR_REMNAWAVE}install_packages" ]; then
    install_packages
  fi
}

# BBR
apply_bbr_sysctl() {
  grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf || echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
  grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
  sysctl -p > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Сохранение/чтение конфигурации панели (адрес + API токен)
# ---------------------------------------------------------------------------
save_panel_config() {
  mkdir -p "${DIR_REMNAWAVE}"
  echo "PANEL_URL=$1" > "$CONFIG_FILE"
  echo "API_TOKEN=$2" >> "$CONFIG_FILE"
}

load_panel_config() {
  if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
  fi
}

get_panel_url() {
  load_panel_config
  if [ -z "$PANEL_URL" ]; then
    reading "Адрес панели Remnawave (например https://panel.example.com или http://127.0.0.1:3000):" PANEL_URL
  fi
  echo "$PANEL_URL"
}

get_api_token() {
  load_panel_config
  if [ -z "$API_TOKEN" ]; then
    reading "API ключ панели Remnawave:" API_TOKEN
    save_panel_config "$PANEL_URL" "$API_TOKEN"
  fi
  echo "$API_TOKEN"
}

# ---------------------------------------------------------------------------
# API функции панели
# ---------------------------------------------------------------------------
api_request() {
  local method=$1
  local url=$2
  local token=$3
  local data=$4
  local headers=(-H "Content-Type: application/json")
  if [ -n "$token" ]; then
    headers+=(-H "Authorization: Bearer $token")
  fi
  if [ -n "$data" ]; then
    curl -s -X "$method" "$url" "${headers[@]}" -d "$data"
  else
    curl -s -X "$method" "$url" "${headers[@]}"
  fi
}

panel_has_nginx() { [ -f "$PANEL_DIR/nginx.conf" ]; }
panel_has_caddy() { [ -f "$PANEL_DIR/Caddyfile" ]; }

# Генерация/установка рандомной заглушки в /var/www/html
randomhtml() {
  mkdir -p /var/www/html
  if [ -z "$(find /var/www/html -maxdepth 1 -name 'index.html' 2>/dev/null)" ] || [ ! -s /var/www/html/index.html ]; then
    log_info "Установка заглушки сайта..."
    cat > /var/www/html/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>npgift.ru</title>
<style>body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#fafafa;color:#333;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}.card{text-align:center;padding:40px;background:#fff;border:1px solid #eee;border-radius:12px;box-shadow:0 4px 20px rgba(0,0,0,.05)}h1{margin:0 0 8px;font-size:22px}p{color:#888;margin:0}</style>
</head>
<body>
<div class="card"><h1>npgift.ru</h1><p>Этот домен обслуживается сервером.</p></div>
</body>
</html>
EOF
    chmod 644 /var/www/html/index.html
    log_ok "Заглушка установлена"
  fi
}

get_public_key() {
  local url=$1
  local token=$2
  local resp=$(api_request "GET" "${url%/}/api/keygen" "$token")
  echo "$resp" | jq -r '.response.pubKey // empty'
}

generate_xray_keys() {
  local url=$1
  local token=$2
  local resp=$(api_request "GET" "${url%/}/api/system/tools/x25519/generate" "$token")
  echo "$resp" | jq -r '.response.keypairs[0].privateKey // empty'
}

create_config_profile() {
  local url=$1 token=$2 name=$3 domain=$4 private_key=$5
  local short_id=$(openssl rand -hex 8)
  local body
  body=$(jq -n --arg name "$name" --arg domain "$domain" --arg private_key "$private_key" --arg short_id "$short_id" '{
    name: $name,
    config: {
      log: { loglevel: "warning" },
      dns: { queryStrategy: "UseIPv4", servers: [{ address: "https://dns.google/dns-query", skipFallback: false }] },
      inbounds: [{
        tag: "vless-reality-443",
        port: 443,
        protocol: "vless",
        settings: { clients: [], decryption: "none" },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
        streamSettings: {
          network: "tcp",
          security: "reality",
          realitySettings: {
            show: false,
            xver: 1,
            dest: "/dev/shm/nginx.sock",
            spiderX: "",
            shortIds: [$short_id],
            privateKey: $private_key,
            serverNames: [$domain]
          }
        }
      }],
      outbounds: [
        { tag: "DIRECT", protocol: "freedom" },
        { tag: "BLOCK", protocol: "blackhole" }
      ],
      routing: {
        rules: [
          { ip: ["geoip:private"], type: "field", outboundTag: "BLOCK" },
          { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" }
        ]
      }
    }
  }')
  local resp=$(api_request "POST" "${url%/}/api/config-profiles" "$token" "$body")
  echo "$resp" | jq -r '.response.uuid // empty' | head -1
  echo "$resp" | jq -r '.response.inbounds[0].uuid // empty' | head -1
}

create_node() {
  local url=$1 token=$2 profile_uuid=$3 inbound_uuid=$4 address=$5 name=$6
  local body
  body=$(jq -n --arg name "$name" --arg address "$address" --arg pu "$profile_uuid" --arg iu "$inbound_uuid" '{
    name: $name,
    address: $address,
    port: 2222,
    configProfile: {
      activeConfigProfileUuid: $pu,
      activeInbounds: [$iu]
    },
    isTrafficTrackingActive: false,
    trafficLimitBytes: 0,
    notifyPercent: 0,
    trafficResetDay: 1,
    excludedInbounds: [],
    countryCode: "XX",
    consumptionMultiplier: 1.0
  }')
  local resp=$(api_request "POST" "${url%/}/api/nodes" "$token" "$body")
  echo "$resp" | jq -r '.response.uuid // empty'
}

create_host() {
  local url=$1 token=$2 inbound_uuid=$3 address=$4 profile_uuid=$5
  local body
  body=$(jq -n --arg pu "$profile_uuid" --arg iu "$inbound_uuid" --arg address "$address" '{
    inbound: { configProfileUuid: $pu, configProfileInboundUuid: $iu },
    remark: $address,
    address: $address,
    port: 443,
    path: "",
    sni: $address,
    host: "",
    alpn: null,
    fingerprint: "chrome",
    allowInsecure: false,
    isDisabled: false,
    securityLayer: "DEFAULT"
  }')
  api_request "POST" "${url%/}/api/hosts" "$token" "$body" > /dev/null
}

get_default_squads() {
  local url=$1 token=$2
  local resp=$(api_request "GET" "${url%/}/api/internal-squads" "$token")
  echo "$resp" | jq -r '.response.internalSquads[]?.uuid' 2>/dev/null
}

update_squad() {
  local url=$1 token=$2 squad_uuid=$3 inbound_uuid=$4
  local resp=$(api_request "GET" "${url%/}/api/internal-squads" "$token")
  local existing
  existing=$(echo "$resp" | jq -r --arg u "$squad_uuid" '.response.internalSquads[] | select(.uuid == $u) | .inbounds[].uuid' 2>/dev/null)
  local inbounds_array
  inbounds_array=$(echo "$existing" | jq -R . 2>/dev/null | jq -s . 2>/dev/null)
  [ -z "$inbounds_array" ] && inbounds_array="[]"
  inbounds_array=$(jq -n --argjson e "$inbounds_array" --arg n "$inbound_uuid" '$e + [$n] | unique')
  local body=$(jq -n --arg u "$squad_uuid" --argjson i "$inbounds_array" '{ uuid: $u, inbounds: $i }')
  api_request "PATCH" "${url%/}/api/internal-squads" "$token" "$body" > /dev/null
}

create_api_token() {
  local url=$1 token=$2 name=$3
  local body='{"name":"'"$name"'","expiresInDays":365,"scopes":["*"]}'
  api_request "POST" "${url%/}/api/tokens" "$token" "$body" | jq -r '.response.token // empty'
}

# ---------------------------------------------------------------------------
# Docker Compose общие операции
# ---------------------------------------------------------------------------
panel_dir_exists() { [ -d "$PANEL_DIR" ] && [ -f "$PANEL_DIR/docker-compose.yml" ]; }
node_dir_exists()  { [ -d "$NODE_DIR" ] && [ -f "$NODE_DIR/docker-compose.yml" ]; }

compose_dir() {
  local type=$1
  if [ "$type" = "panel" ]; then echo "$PANEL_DIR"; else echo "$NODE_DIR"; fi
}

compose_start() {
  local type=$1
  local dir
  dir=$(compose_dir "$type")
  if ! panel_dir_exists && [ "$type" = "panel" ]; then log_error "Панель не установлена"; return 1; fi
  if ! node_dir_exists && [ "$type" = "node" ]; then log_error "Нода не установлена"; return 1; fi
  cd "$dir" || return 1
  log_info "Запуск ${type}..."
  docker compose up -d > /dev/null 2>&1 &
  spinner $! "Ожидание..."
  log_ok "${type^} запущен"
}

compose_stop() {
  local type=$1
  local dir
  dir=$(compose_dir "$type")
  if ! panel_dir_exists && [ "$type" = "panel" ]; then log_error "Панель не установлена"; return 1; fi
  if ! node_dir_exists && [ "$type" = "node" ]; then log_error "Нода не установлена"; return 1; fi
  cd "$dir" || return 1
  log_info "Остановка ${type}..."
  docker compose down > /dev/null 2>&1 &
  spinner $! "Ожидание..."
  log_ok "${type^} остановлен"
}

compose_update() {
  local type=$1
  local dir
  dir=$(compose_dir "$type")
  if ! panel_dir_exists && [ "$type" = "panel" ]; then log_error "Панель не установлена"; return 1; fi
  if ! node_dir_exists && [ "$type" = "node" ]; then log_error "Нода не установлена"; return 1; fi
  cd "$dir" || return 1

  log_info "Проверка обновлений для ${type}..."
  local before after
  before=$(docker compose config --images | sort -u | xargs -I{} docker images -q {} 2>/dev/null | sort -u)
  local pull_out
  pull_out=$(docker compose pull 2>&1)
  after=$(docker compose config --images | sort -u | xargs -I{} docker images -q {} 2>/dev/null | sort -u)

  if [ "$before" != "$after" ] || echo "$pull_out" | grep -q "Pull complete"; then
    docker compose down > /dev/null 2>&1 &
    spinner $! "Ожидание..."
    sleep 3
    docker compose up -d > /dev/null 2>&1 &
    spinner $! "Ожидание..."
    docker image prune -f > /dev/null 2>&1
    log_ok "${type^} обновлён"
  else
    log_warn "Обновлений нет"
  fi
}

compose_reinstall() {
  local type=$1
  local dir
  dir=$(compose_dir "$type")
  if ! panel_dir_exists && [ "$type" = "panel" ]; then log_error "Панель не установлена"; return 1; fi
  if ! node_dir_exists && [ "$type" = "node" ]; then log_error "Нода не установлена"; return 1; fi
  cd "$dir" || return 1
  log_info "Переустановка ${type}..."
  docker compose down > /dev/null 2>&1 &
  spinner $! "Ожидание..."
  docker compose up -d > /dev/null 2>&1 &
  spinner $! "Ожидание..."
  log_ok "${type^} переустановлен"
}

compose_logs() {
  local type=$1
  local dir
  dir=$(compose_dir "$type")
  if ! panel_dir_exists && [ "$type" = "panel" ]; then log_error "Панель не установлена"; return 1; fi
  if ! node_dir_exists && [ "$type" = "node" ]; then log_error "Нода не установлена"; return 1; fi
  cd "$dir" || return 1
  docker compose logs -f -t --tail=200
}

compose_remove() {
  local type=$1
  local dir
  dir=$(compose_dir "$type")
  if ! panel_dir_exists && [ "$type" = "panel" ]; then log_error "Панель не установлена"; return 1; fi
  if ! node_dir_exists && [ "$type" = "node" ]; then log_error "Нода не установлена"; return 1; fi
  echo -e "${COLOR_RED}Внимание! Будет полностью удалён ${type} вместе с данными.${COLOR_RESET}"
  reading "Подтвердить удаление? (y/N):" confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_warn "Отменено"
    return 0
  fi
  cd "$dir" || return 1
  docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1 &
  spinner $! "Ожидание..."
  rm -rf "$dir"
  log_ok "${type^} удалён"
}

# ---------------------------------------------------------------------------
# Сертификаты (HTTP-01 / DNS-01)
# ---------------------------------------------------------------------------
issue_certificates() {
  # $1..$N — домены (первый основной). CERT_METHOD: 1 = HTTP-01, 2 = DNS-01(CF)
  local domains=("$@")
  local primary="${domains[0]}"
  local base_domain=$(echo "$primary" | sed -E 's/^[^.]+\.//')

  if [ -d "/etc/letsencrypt/live/$primary" ]; then
    log_ok "Сертификат для $primary уже существует"
    return 0
  fi

  mkdir -p /var/www/html
  if [ -z "$CERT_METHOD" ]; then
    echo ""
    echo -e "${COLOR_GREEN}Метод выпуска сертификата:${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1. HTTP-01 (простой, нужен порт 80)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. DNS-01 Cloudflare (wildcard)${COLOR_RESET}"
    reading "Ваш выбор (1/2):" CERT_METHOD
  fi

  local cert_args=(-d "$primary" --agree-tos -m "admin@$base_domain" --no-eff-email --keep-until-expiring)
  if [ "$CERT_METHOD" = "2" ]; then
    if [ -z "$CF_DNS_TOKEN" ]; then
      reading "Cloudflare API токен (для DNS-01):" CF_DNS_TOKEN
    fi
    mkdir -p /etc/letsencrypt/cloudflare
    cat > /etc/letsencrypt/cloudflare/credentials <<EOF
dns_cloudflare_api_token = $CF_DNS_TOKEN
EOF
    chmod 600 /etc/letsencrypt/cloudflare/credentials
    certbot certonly --non-interactive --dns-cloudflare \
      --dns-cloudflare-credentials /etc/letsencrypt/cloudflare/credentials \
      "${cert_args[@]}" || error "Не удалось выпустить сертификат DNS-01"
  else
    certbot certonly --non-interactive --webroot -w /var/www/html \
      "${cert_args[@]}" || error "Не удалось выпустить сертификат HTTP-01"
  fi
  log_ok "Сертификат выпущен: $primary"
}

# ---------------------------------------------------------------------------
# Установка панели + подписки
# ---------------------------------------------------------------------------
install_panel() {
  ensure_packages
  apply_bbr_sysctl
  mkdir -p "$PANEL_DIR" && cd "$PANEL_DIR" || exit 1

  reading "Домен панели (например panel.example.com):" PANEL_DOMAIN
  reading "Домен страницы подписки (например sub.example.com):" SUB_DOMAIN
  reading "Домен ноды (selfsteal, например cdn.example.com):" SELFSTEAL_DOMAIN

  if [ "$PANEL_DOMAIN" = "$SUB_DOMAIN" ] || [ "$PANEL_DOMAIN" = "$SELFSTEAL_DOMAIN" ] || [ "$SUB_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; then
    error "Домены должны быть уникальными"
  fi

  issue_certificates "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"

  local SUPERADMIN_USERNAME=$(generate_user)
  local SUPERADMIN_PASSWORD=$(generate_password)
  local cookies_random1=$(generate_user)
  local cookies_random2=$(generate_user)
  local METRICS_USER=$(generate_user)
  local METRICS_PASS=$(generate_user)
  local JWT_AUTH_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
  local JWT_API_TOKENS_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)

  cat > .env <<EOL
### APP ###
APP_PORT=3000
METRICS_PORT=3001
API_INSTANCES=1

### DATABASE ###
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### REDIS ###
REDIS_SOCKET=/var/run/valkey/valkey.sock

### JWT ###
JWT_AUTH_SECRET=$JWT_AUTH_SECRET
JWT_API_TOKENS_SECRET=$JWT_API_TOKENS_SECRET
JWT_AUTH_LIFETIME=168

### TELEGRAM ###
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
TELEGRAM_NOTIFY_USERS=change_me
TELEGRAM_NOTIFY_NODES=change_me
TELEGRAM_NOTIFY_CRM=change_me
TELEGRAM_NOTIFY_SERVICE=change_me
TELEGRAM_NOTIFY_TBLOCKER=change_me

### FRONT_END ###
FRONT_END_DOMAIN=$PANEL_DOMAIN

### SUBSCRIPTION ###
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN

### SWAGGER ###
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=false

### PROMETHEUS ###
METRICS_USER=$METRICS_USER
METRICS_PASS=$METRICS_PASS

### WEBHOOK ###
WEBHOOK_ENABLED=false
WEBHOOK_URL=https://your-webhook-url.com/endpoint
WEBHOOK_SECRET_HEADER=vsmu67Kmg6R8FjIOF1WUY8LWBHie4scdEqrfsKmyf4IAf8dY3nFS0wwYHkhh6ZvQ

### BANDWIDTH ###
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80]
NOT_CONNECTED_USERS_NOTIFICATIONS_ENABLED=false
NOT_CONNECTED_USERS_NOTIFICATIONS_AFTER_HOURS=[6, 24, 48]

### CLOUDFLARE ###
CLOUDFLARE_TOKEN=ey...

### DATABASE DOCKER ###
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOL

  cat > docker-compose.yml <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-networks: &networks
  networks:
    - remnawave-network

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

x-env: &env
  env_file: .env

services:
  remnawave-db:
    image: postgres:18.3
    container_name: 'remnawave-db'
    hostname: remnawave-db
    <<: [*common, *logging, *env, *networks]
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave:
    image: remnawave/backend:2
    container_name: remnawave
    hostname: remnawave
    <<: [*common, *logging, *env, *networks]
    volumes:
      - valkey-socket:/var/run/valkey
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy

  remnawave-redis:
    image: valkey/valkey:9.0.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    <<: [*common, *logging, *networks]
    volumes:
      - valkey-socket:/var/run/valkey
    command: >
      valkey-server
      --save ""
      --appendonly no
      --maxmemory-policy noeviction
      --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
      --port 0
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem:/etc/nginx/ssl/${PANEL_DOMAIN}/fullchain.pem:ro
      - /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem:/etc/nginx/ssl/${PANEL_DOMAIN}/privkey.pem:ro
      - /etc/letsencrypt/live/${SUB_DOMAIN}/fullchain.pem:/etc/nginx/ssl/${SUB_DOMAIN}/fullchain.pem:ro
      - /etc/letsencrypt/live/${SUB_DOMAIN}/privkey.pem:/etc/nginx/ssl/${SUB_DOMAIN}/privkey.pem:ro
      - /etc/letsencrypt/live/${SELFSTEAL_DOMAIN}/fullchain.pem:/etc/nginx/ssl/${SELFSTEAL_DOMAIN}/fullchain.pem:ro
      - /etc/letsencrypt/live/${SELFSTEAL_DOMAIN}/privkey.pem:/etc/nginx/ssl/${SELFSTEAL_DOMAIN}/privkey.pem:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    <<: [*common, *logging, *networks]
    depends_on:
      remnawave:
        condition: service_healthy
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=placeholder
    ports:
      - '127.0.0.1:3010:3010'

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    external: false
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
    driver: local
    external: false
EOL

  cat > nginx.conf <<EOL
server_names_hash_bucket_size 64;

upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

map \$http_cookie \$auth_cookie {
    default 0;
    "~*${cookies_random1}=${cookies_random2}" 1;
}

map \$arg_${cookies_random1} \$auth_query {
    default 0;
    "${cookies_random2}" 1;
}

map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}

map \$arg_${cookies_random1} \$set_cookie_header {
    "${cookies_random2}" "${cookies_random1}=${cookies_random2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name ${PANEL_DOMAIN};
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/${PANEL_DOMAIN}/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/${PANEL_DOMAIN}/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/${PANEL_DOMAIN}/fullchain.pem";

    add_header Set-Cookie \$set_cookie_header;

    location / {
        if (\$authorized = 0) {
            return 418;
        }
        error_page 418 = @unauthorized;
        recursive_error_pages on;

        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location @unauthorized {
        root /var/www/html;
        index index.html;
    }

    location ^~ /oauth2/ {
        if (\$http_referer !~ "^https://oauth\.telegram\.org/") {
            return 444;
        }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

server {
    server_name ${SUB_DOMAIN};
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/${SUB_DOMAIN}/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/${SUB_DOMAIN}/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/${SUB_DOMAIN}/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 444;
    }
}

server {
    server_name ${SELFSTEAL_DOMAIN};
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/${SELFSTEAL_DOMAIN}/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/${SELFSTEAL_DOMAIN}/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/${SELFSTEAL_DOMAIN}/fullchain.pem";

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    ssl_reject_handshake on;
    return 444;
}
EOL

  # randomhtml (заглушка)
  randomhtml

  ufw allow 80,443/tcp > /dev/null 2>&1
  ufw allow 443/udp > /dev/null 2>&1
  ufw allow 2222/tcp > /dev/null 2>&1
  ufw reload > /dev/null 2>&1

  log_info "Запуск контейнеров панели..."
  docker compose up -d > /dev/null 2>&1 &
  spinner $! "Ожидание..."
  sleep 20

  # Регистрация
  local domain_url="127.0.0.1:3000"
  local attempts=0
  until curl -s -f --max-time 30 "http://$domain_url/api/auth/status" --header 'X-Forwarded-For: 127.0.0.1' --header 'X-Forwarded-Proto: https' > /dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 10 ]; then
      error "Панель не поднялась за отведённое время. Смотрите docker compose logs"
    fi
    log_warn "Ожидание панели (попытка $attempts)..."
    sleep 30
  done

  local token
  token=$(api_request "POST" "http://$domain_url/api/auth/register" "" '{"username":"'"$SUPERADMIN_USERNAME"'","password":"'"$SUPERADMIN_PASSWORD"'"}')
  token=$(echo "$token" | jq -r '.response.accessToken // empty')
  if [ -z "$token" ]; then
    error "Не удалось зарегистрировать панель"
  fi

  # Получаем публичный ключ ноды
  local pubkey
  pubkey=$(get_public_key "http://$domain_url" "$token")
  if [ -z "$pubkey" ]; then
    error "Не удалось получить публичный ключ панели"
  fi

  # Создаём API-токен для страницы подписки
  local sub_token
  sub_token=$(create_api_token "http://$domain_url" "$token" "subscription-page")
  if [ -n "$sub_token" ]; then
    sed -i "s|REMNAWAVE_API_TOKEN=placeholder|REMNAWAVE_API_TOKEN=$sub_token|" docker-compose.yml
    docker compose down remnawave-subscription-page > /dev/null 2>&1 &
    spinner $! "Ожидание..."
    docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
    spinner $! "Ожидание..."
  fi

  # Сохраняем данные панели
  save_panel_config "http://$domain_url" "$token"
  echo -e "${COLOR_WHITE}SUPERADMIN_USERNAME=$SUPERADMIN_USERNAME${COLOR_RESET}" >> "$CONFIG_FILE"
  echo -e "${COLOR_WHITE}SUPERADMIN_PASSWORD=$SUPERADMIN_PASSWORD${COLOR_RESET}" >> "$CONFIG_FILE"
  echo -e "${COLOR_WHITE}COOKIE_1=$cookies_random1${COLOR_RESET}" >> "$CONFIG_FILE"
  echo -e "${COLOR_WHITE}COOKIE_2=$cookies_random2${COLOR_RESET}" >> "$CONFIG_FILE"

  clear
  echo "================================================================"
  echo -e "${COLOR_GREEN}Панель установлена!${COLOR_RESET}"
  echo "----------------------------------------------------------------"
  echo -e "${COLOR_WHITE}Адрес: https://${PANEL_DOMAIN}/auth/login?${cookies_random1}=${cookies_random2}${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}Логин: $SUPERADMIN_USERNAME${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}Пароль: $SUPERADMIN_PASSWORD${COLOR_RESET}"
  echo "----------------------------------------------------------------"
  echo -e "${COLOR_GREEN}Следующий шаг: установите ноду (раздел Remnanode)${COLOR_RESET}"
  echo "================================================================"
}

# ---------------------------------------------------------------------------
# Установка ноды (локальная/удалённая панель)
# ---------------------------------------------------------------------------
install_node() {
  ensure_packages
  apply_bbr_sysctl
  mkdir -p "$NODE_DIR" && cd "$NODE_DIR" || exit 1

  echo -e "${COLOR_RED}Панель Remnawave уже установлена на этом сервере?${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}1. Да - нода на том же сервере, что и панель${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Нет - нода на отдельном сервере${COLOR_RESET}"
  reading "Ваш выбор (1/2):" NODE_PANEL_LOCAL

  local panel_url="" api_token="" node_domain="" node_name=""
  local secret_key=""

  if [ "$NODE_PANEL_LOCAL" = "1" ]; then
    if ! panel_dir_exists && ! docker ps -q --filter "ancestor=remnawave/backend:2" | grep -q .; then
      error "Панель не установлена на этом сервере. Сначала установите панель (раздел Remnawave)"
    fi
    panel_url="http://127.0.0.1:3000"
    # Получаем токен админа из сохранённой конфигурации
    load_panel_config
    api_token="$API_TOKEN"
    if [ -z "$api_token" ]; then
      reading "API ключ панели (или админ-токен):" api_token
    fi
  else
    reading "Адрес панели (https://panel.example.com):" panel_url
    reading "API ключ панели:" api_token
  fi

  reading "Домен ноды (selfsteal, например cdn.example.com):" node_domain
  reading "Название ноды (например Russia 2):" node_name

  # Генерируем приватный ключ xray
  log_info "Генерация Xray ключей..."
  local xr_private
  xr_private=$(generate_xray_keys "$panel_url" "$api_token")
  if [ -z "$xr_private" ]; then
    error "Не удалось сгенерировать ключи. Проверьте адрес/токен панели"
  fi

  # Создаём конфиг-профиль с reality (dest /dev/shm/nginx.sock)
  log_info "Создание конфиг-профиля..."
  local profile_uuid inbound_uuid
  read profile_uuid inbound_uuid <<< $(create_config_profile "$panel_url" "$api_token" "$node_name" "$node_domain" "$xr_private")
  if [ -z "$profile_uuid" ] || [ -z "$inbound_uuid" ]; then
    error "Не удалось создать конфиг-профиль"
  fi

  # Создаём ноду в панели
  log_info "Регистрация ноды в панели..."
  local node_uuid
  node_uuid=$(create_node "$panel_url" "$api_token" "$profile_uuid" "$inbound_uuid" "$node_domain" "$node_name")
  if [ -z "$node_uuid" ]; then
    error "Не удалось создать ноду в панели"
  fi

  # Создаём host
  log_info "Создание host..."
  create_host "$panel_url" "$api_token" "$inbound_uuid" "$node_domain" "$profile_uuid"

  # Добавляем inbound в squad
  local squads
  squads=$(get_default_squads "$panel_url" "$api_token")
  if [ -n "$squads" ]; then
    for sq in $squads; do
      [ -z "$sq" ] && continue
      update_squad "$panel_url" "$api_token" "$sq" "$inbound_uuid"
    done
    log_ok "Inbound добавлен в squad"
  fi

  # Получаем public key (для кампании)
  log_info "Получение публичного ключа..."
  if [ "$NODE_PANEL_LOCAL" = "1" ]; then
    secret_key=$(get_public_key "$panel_url" "$api_token")
  else
    # Для удалённой панели берём публичный ключ из keygen
    secret_key=$(get_public_key "$panel_url" "$api_token")
  fi

  if [ -z "$secret_key" ]; then
    reading "Публичный ключ панели (из панели: Домены -> нода):" secret_key
  fi

  # Скачиваем сертификат ноды (selfsteal-домена) - нужен для ноды на этом хосте
  local node_cert=""
  if [ -d "/etc/letsencrypt/live/$node_domain" ]; then
    node_cert="$node_domain"
  else
    # Пробуем выпустить/обнаружить
    if [ "$NODE_PANEL_LOCAL" = "1" ] || command -v certbot >/dev/null 2>&1; then
      mkdir -p /var/www/html
      issue_certificates "$node_domain"
      node_cert="$node_domain"
    fi
  fi

  # dnscrypt... соберем docker-compose ноды
  cat > docker-compose.yml <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL

  # Если есть сертификат - монтируем, иначе пустая заглушка
  if [ -d "/etc/letsencrypt/live/$node_cert" ] && [ -n "$node_cert" ]; then
    cat >> docker-compose.yml <<EOL
      - /etc/letsencrypt/live/${node_cert}/fullchain.pem:/etc/nginx/ssl/${node_cert}/fullchain.pem:ro
      - /etc/letsencrypt/live/${node_cert}/privkey.pem:/etc/nginx/ssl/${node_cert}/privkey.pem:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$secret_key
    volumes:
      - /dev/shm:/dev/shm:rw
EOL
  else
    cat >> docker-compose.yml <<EOL
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$secret_key
    volumes:
      - /dev/shm:/dev/shm:rw
EOL
  fi

  cat > nginx.conf <<EOL
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name ${node_domain};
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/${node_cert}/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/${node_cert}/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/${node_cert}/fullchain.pem";

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    ssl_reject_handshake on;
    return 444;
}
EOL

  # Рандомная заглушка
  randomhtml

  ufw allow from any to any port 2222 proto tcp > /dev/null 2>&1
  ufw reload > /dev/null 2>&1

  log_info "Запуск контейнеров ноды..."
  docker compose up -d > /dev/null 2>&1 &
  spinner $! "Ожидание..."

  # Сохраняем конфигурацию ноды
  echo -e "NODE_DOMAIN=$node_domain" >> "$CONFIG_FILE"
  echo -e "NODE_UUID=$node_uuid" >> "$CONFIG_FILE"

  echo ""
  echo "================================================================"
  echo -e "${COLOR_GREEN}Нода установлена!${COLOR_RESET}"
  echo "----------------------------------------------------------------"
  echo -e "${COLOR_WHITE}Домен ноды: $node_domain${COLOR_RESET}"
  echo -e "${COLOR_WHITE}Адрес панели: $panel_url${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}В панели в профиле ноды создайте inbound'ы для нужных протоколов${COLOR_RESET}"
  echo "================================================================"
}

# ---------------------------------------------------------------------------
# Копирование сертификатов в /dev/shm (для Hysteria2)
# ---------------------------------------------------------------------------
sync_certs_to_shm() {
  local domain=$1
  if [ -z "$domain" ] || [ ! -d "/etc/letsencrypt/live/$domain" ]; then
    log_error "Сертификат для $domain не найден"
    return 1
  fi
  cp -f "/etc/letsencrypt/live/$domain/fullchain.pem" /dev/shm/hysteria_cert.pem
  cp -f "/etc/letsencrypt/live/$domain/privkey.pem" /dev/shm/hysteria_key.pem
  chmod 644 /dev/shm/hysteria_*.pem
  log_ok "Сертификаты скопированы в /dev/shm"
}

setup_cert_cron() {
  local domain="$1"
  if [ -z "$domain" ]; then
    reading "Для какого домена настраивать автообновление сертификатов:" domain
  fi
  local cron_reboot="@reboot cp /etc/letsencrypt/live/$domain/fullchain.pem /dev/shm/hysteria_cert.pem && cp /etc/letsencrypt/live/$domain/privkey.pem /dev/shm/hysteria_key.pem && chmod 644 /dev/shm/*.pem && sleep 15 && docker restart remnanode"
  local cron_daily="0 4 * * * cp /etc/letsencrypt/live/$domain/fullchain.pem /dev/shm/hysteria_cert.pem && cp /etc/letsencrypt/live/$domain/privkey.pem /dev/shm/hysteria_key.pem && chmod 644 /dev/shm/*.pem && docker restart remnanode"

  if crontab -l 2>/dev/null | grep -q "hysteria_cert.pem"; then
    log_ok "Cron для сертификатов уже настроен"
  else
    (crontab -l 2>/dev/null; echo "$cron_reboot"; echo "$cron_daily") | crontab -
    log_ok "Cron для сертификатов добавлен"
  fi
}

# ---------------------------------------------------------------------------
# Доступ к панели через порт 8443 (open/close)
# ---------------------------------------------------------------------------
open_panel_access() {
  if ! panel_dir_exists; then
    log_error "Панель не установлена"
    return 1
  fi
  cd "$PANEL_DIR" || return 1

  if panel_has_nginx; then
    local pdomain
    pdomain=$(grep -B 20 "proxy_pass http://remnawave" "$PANEL_DIR/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)
    local c1 c2
    c1=$(grep -oP '~*\K\w+(?==)' "$PANEL_DIR/nginx.conf" | head -n 1)
    c2=$(grep -oP '=\K\w+(?=")' "$PANEL_DIR/nginx.conf" | head -n 1)

    if ss -tuln | grep -q ":8443"; then
      log_error "Порт 8443 уже занят"
      return 1
    fi

    sed -i "/server_name $pdomain;/,/}/ s|listen unix:/dev/shm/nginx.sock ssl proxy_protocol;|listen unix:/dev/shm/nginx.sock ssl proxy_protocol;\n    listen 8443 ssl;|" "$PANEL_DIR/nginx.conf"
    docker compose down remnawave-nginx > /dev/null 2>&1 &
    docker compose up -d remnawave-nginx > /dev/null 2>&1 &
    ufw allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
    echo -e "${COLOR_GREEN}Панель доступна: https://${pdomain}:8443/auth/login?${c1}=${c2}${COLOR_RESET}"
  else
    sed -i "s|https://{\$PANEL_DOMAIN} {|https://{\$PANEL_DOMAIN}:8443 {|g" "$PANEL_DIR/Caddyfile"
    docker compose restart remnawave-caddy > /dev/null 2>&1 &
    ufw allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
    log_ok "Панель открыта через порт 8443"
  fi
}

close_panel() {
  if ! panel_dir_exists; then
    log_error "Панель не установлена"
    return 1
  fi
  cd "$PANEL_DIR" || return 1

  if panel_has_nginx; then
    local pdomain
    pdomain=$(grep -B 20 "proxy_pass http://remnawave" "$PANEL_DIR/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)
    sed -i "/server_name $pdomain;/,/}/ s/^    listen 8443 ssl;//" "$PANEL_DIR/nginx.conf"
    docker compose restart remnawave-nginx > /dev/null 2>&1 &
  else
    sed -i "s|https://{\$PANEL_DOMAIN}:8443 {|https://{\$PANEL_DOMAIN} {|g" "$PANEL_DIR/Caddyfile"
    docker compose restart remnawave-caddy > /dev/null 2>&1 &
  fi
  if ufw status | grep -q "8443.*ALLOW"; then
    ufw delete allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
  fi
  log_ok "Панель закрыта с порта 8443"
}

# ---------------------------------------------------------------------------
# Управление сертификатами
# ---------------------------------------------------------------------------
manage_certs_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Управление сертификатами Lets Encrypt${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Выпустить/обновить сертификаты${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Отменить все и перевыпустить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Показать список сертификатов${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}4. Скопировать сертификаты в /dev/shm (Hysteria)${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}5. Настроить автообновление сертификатов (cron)${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1)
      local domains=""
      while [ -z "$domains" ]; do
        reading "Домены через пробел (первый основной):" domains
      done
      issue_certificates $domains
      sleep 2
      manage_cert_menu
      ;;
    2)
      certbot delete --non-interactive > /dev/null 2>&1
      log_ok "Сертификаты удалены. Выпустите заново"
      manage_cert_menu
      ;;
    3)
      certbot certificates 2>/dev/null
      manage_cert_menu
      ;;
    4)
      ls /etc/letsencrypt/live/ 2>/dev/null
      reading "Домен:" dmain
      sync_certs_to_shm "$dmain"
      manage_cert_menu
      ;;
    5)
      ls /etc/letsencrypt/live/ 2>/dev/null
      reading "Домен:" dmain
      setup_cert_cron "$dmain"
      manage_cert_menu
      ;;
    0) return ;;
    *) manage_cert_menu ;;
  esac
}

# ---------------------------------------------------------------------------
# BBR
# ---------------------------------------------------------------------------
bbr_status() {
  echo ""
  echo -e "${COLOR_GREEN}Состояние BBR:${COLOR_RESET}"
  echo "  qdisc:      $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  echo "  congestion: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    log_ok "BBR активен"
  else
    log_warn "BBR не активен"
  fi
}

bbr_enable() {
  apply_bbr_sysctl
  sysctl -p > /dev/null 2>&1
  log_ok "BBR включён"
}

bbr_disable() {
  sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
  sysctl -p > /dev/null 2>&1
  sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null 2>&1
  log_ok "BBR отключён (используется cubic)"
}

bbr_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Управление BBR${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Статус${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Включить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Отключить${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1) bbr_status; sleep 2; bbr_menu ;;
    2) bbr_enable; sleep 2; bbr_menu ;;
    3) bbr_disable; sleep 2; bbr_menu ;;
    0) return ;;
    *) bbr_menu ;;
  esac
}

# ---------------------------------------------------------------------------
# IPv6
# ---------------------------------------------------------------------------
ipv6_enable() {
  local iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)
  sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
  sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
  sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
  sed -i "/net.ipv6.conf.$iface.disable_ipv6/d" /etc/sysctl.conf
  echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
  echo "net.ipv6.conf.default.disable_ipv6 = 0" >> /etc/sysctl.conf
  echo "net.ipv6.conf.lo.disable_ipv6 = 0" >> /etc/sysctl.conf
  sysctl -p > /dev/null 2>&1
  log_ok "IPv6 включён"
}

ipv6_disable() {
  local iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)
  sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
  sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
  sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
  echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
  echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
  echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
  sysctl -p > /dev/null 2>&1
  log_ok "IPv6 отключён"
}

ipv6_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Управление IPv6${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Включить IPv6${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Отключить IPv6${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1) ipv6_enable; sleep 2; ipv6_menu ;;
    2) ipv6_disable; sleep 2; ipv6_menu ;;
    0) return ;;
    *) ipv6_menu ;;
  esac
}

# ---------------------------------------------------------------------------
# WARP Native
# ---------------------------------------------------------------------------
warp_menu() {
  echo ""
  echo -e "${COLOR_GREEN}WARP Native${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Установить WARP${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Удалить WARP${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Добавить warp-out в конфиг профиля${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}4. Удалить warp-out из конфига${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1)
      bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh)
      sleep 2
      warp_menu
      ;;
    2)
      bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/uninstall.sh)
      sleep 2
      warp_menu
      ;;
    3)
      warp_add_config
      sleep 2
      warp_menu
      ;;
    4)
      warp_remove_config
      sleep 2
      warp_menu
      ;;
    0) return ;;
    *) warp_menu ;;
  esac
}

warp_get_panel() {
  local url=$(get_panel_url)
  local token=$(get_api_token)
  echo "$url|$token"
}

warp_add_config() {
  local wt
  wt=$(warp_get_panel)
  local url="${wt%%|*}" token="${wt##*|}"
  local resp=$(api_request "GET" "${url%/}/api/config-profiles" "$token")
  echo "$resp" | jq -e '.response.configProfiles | type == "array"' > /dev/null 2>&1 || { log_error "Не удалось получить конфиги"; return 1; }

  echo ""
  echo -e "${COLOR_GREEN}Выберите конфиг:${COLOR_RESET}"
  local i=1
  declare -A cmap
  while IFS=' ' read -r name uuid; do
    echo -e "${COLOR_YELLOW}$i. $name${COLOR_RESET}"
    cmap[$i]="$uuid"
    ((i++))
  done < <(echo "$resp" | jq -r '.response.configProfiles[] | "\(.name) \(.uuid)"')
  reading "Выбор:" sel
  local puuid="${cmap[$sel]}"
  [ -z "$puuid" ] && { log_error "Неверный выбор"; return 1; }

  local cdata
  cdata=$(api_request "GET" "${url%/}/api/config-profiles/$puuid" "$token")
  local cfg
  cfg=$(echo "$cdata" | jq -r '.response.config // .config // ""')

  if echo "$cfg" | jq -e '.outbounds[] | select(.tag == "warp-out")' > /dev/null 2>&1; then
    log_warn "warp-out уже добавлен"
    return 0
  fi

  local wo='{"tag":"warp-out","protocol":"freedom","settings":{"domainStrategy":"UseIP"},"streamSettings":{"sockopt":{"interface":"warp","tcpFastOpen":true}}}'
  cfg=$(echo "$cfg" | jq --argjson wo "$wo" '.outbounds += [$wo]')
  local wr='{"type":"field","domain":["whoer.net","browserleaks.com","2ip.io","2ip.ru"],"outboundTag":"warp-out"}'
  cfg=$(echo "$cfg" | jq --argjson wr "$wr" '.routing.rules += [$wr]')

  api_request "PATCH" "${url%/}/api/config-profiles" "$token" "{\"uuid\": \"$puuid\", \"config\": $cfg}" > /dev/null
  log_ok "warp-out добавлен в конфиг"
}

warp_remove_config() {
  local wt
  wt=$(warp_get_panel)
  local url="${wt%%|*}" token="${wt##*|}"
  local resp=$(api_request "GET" "${url%/}/api/config-profiles" "$token")
  echo "$resp" | jq -e '.response.configProfiles | type == "array"' > /dev/null 2>&1 || { log_error "Не удалось получить конфиги"; return 1; }

  echo ""
  echo -e "${COLOR_GREEN}Выберите конфиг:${COLOR_RESET}"
  local i=1
  declare -A cmap
  while IFS=' ' read -r name uuid; do
    echo -e "${COLOR_YELLOW}$i. $name${COLOR_RESET}"
    cmap[$i]="$uuid"
    ((i++))
  done < <(echo "$resp" | jq -r '.response.configProfiles[] | "\(.name) \(.uuid)"')
  reading "Выбор:" sel
  local puuid="${cmap[$sel]}"
  [ -z "$puuid" ] && { log_error "Неверный выбор"; return 1; }

  local cdata
  cdata=$(api_request "GET" "${url%/}/api/config-profiles/$puuid" "$token")
  local cfg
  cfg=$(echo "$cdata" | jq -r '.response.config // .config // ""')
  cfg=$(echo "$cfg" | jq 'del(.outbounds[] | select(.tag == "warp-out"))')
  cfg=$(echo "$cfg" | jq 'del(.routing.rules[] | select(.outboundTag == "warp-out"))')
  api_request "PATCH" "${url%/}/api/config-profiles" "$token" "{\"uuid\": \"$puuid\", \"config\": $cfg}" > /dev/null
  log_ok "warp-out удалён из конфига"
}

# ---------------------------------------------------------------------------
# UFW
# ---------------------------------------------------------------------------
ufw_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Управление UFW${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Статус / правила${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Включить UFW${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Отключить UFW${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}4. Открыть порт${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}5. Закрыть порт${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}6. Открыть порт для IP${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1) ufw status verbose; sleep 2; ufw_menu ;;
    2) ufw enable; sleep 2; ufw_menu ;;
    3) ufw disable; sleep 2; ufw_menu ;;
    4)
      reading "Порт и протокол (например 8080/tcp):" pp
      ufw allow "$pp"
      ufw reload > /dev/null 2>&1
      sleep 2
      ufw_menu
      ;;
    5)
      reading "Порт и протокол (например 8080/tcp):" pp
      ufw delete allow "$pp"
      ufw reload > /dev/null 2>&1
      sleep 2
      ufw_menu
      ;;
    6)
      reading "IP адрес:" ip
      reading "Порт и протокол (например 8080/tcp):" pp
      ufw allow from "$ip" to any port "${pp%/*}" proto "${pp#*/}"
      ufw reload > /dev/null 2>&1
      sleep 2
      ufw_menu
      ;;
    0) return ;;
    *) ufw_menu ;;
  esac
}

# ---------------------------------------------------------------------------
# SSH-ключи
# ---------------------------------------------------------------------------
ssh_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Управление SSH-ключами${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Показать авторизованные ключи${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Добавить ключ${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Удалить ключ${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}4. Отключить вход по паролю (только ключи)${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}5. Включить вход по паролю${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1)
      echo ""
      cat ~/.ssh/authorized_keys 2>/dev/null | nl || log_warn "Файл ключей пуст или не существует"
      sleep 2
      ssh_menu
      ;;
    2)
      mkdir -p ~/.ssh && chmod 700 ~/.ssh
      touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
      reading "Вставьте публичный ключ (ssh-ed25519 ...):" newkey
      echo "$newkey" >> ~/.ssh/authorized_keys
      log_ok "Ключ добавлен"
      sleep 2
      ssh_menu
      ;;
    3)
      cat ~/.ssh/authorized_keys 2>/dev/null | nl
      reading "Номер ключа для удаления:" kn
      sed -i "${kn}d" ~/.ssh/authorized_keys 2>/dev/null
      log_ok "Ключ удалён"
      sleep 2
      ssh_menu
      ;;
    4)
      sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
      grep -q "PasswordAuthentication no" /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
      systemctl restart sshd
      log_ok "Вход по паролю отключён"
      sleep 2
      ssh_menu
      ;;
    5)
      sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
      grep -q "PasswordAuthentication yes" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
      systemctl restart sshd
      log_ok "Вход по паролю включён"
      sleep 2
      ssh_menu
      ;;
    0) return ;;
    *) ssh_menu ;;
  esac
}

# ---------------------------------------------------------------------------
# Fail2ban
# ---------------------------------------------------------------------------
fail2ban_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Управление Fail2ban${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Статус (active jails)${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Включить SSH-защиту${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Отключить SSH-защиту${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}4. Список заблокированных IP${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}5. Разблокировать IP${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}6. Удалить fail2ban${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1)
      fail2ban-client status 2>/dev/null || log_warn "fail2ban не установлен"
      sleep 2
      fail2ban_menu
      ;;
    2)
      if ! command -v fail2ban-client >/dev/null 2>&1; then
        apt-get install -y fail2ban > /dev/null 2>&1
      fi
      if [ -f /etc/fail2ban/jail.local ]; then
        sed -i 's/^enabled = false/enabled = true/' /etc/fail2ban/jail.local
      else
        cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
      fi
      systemctl enable --now fail2ban
      log_ok "Fail2ban SSH-защита включена"
      sleep 2
      fail2ban_menu
      ;;
    3)
      fail2ban-client stop sshd 2>/dev/null
      sed -i 's/^enabled = true/enabled = false/' /etc/fail2ban/jail.local 2>/dev/null
      systemctl restart fail2ban 2>/dev/null
      log_ok "SSH-защита отключена"
      sleep 2
      fail2ban_menu
      ;;
    4)
      fail2ban-client status sshd 2>/dev/null | grep "Banned IP" || log_warn "Нет данных"
      sleep 2
      fail2ban_menu
      ;;
    5)
      reading "IP для разблокировки:" bip
      fail2ban-client set sshd unbanip "$bip" 2>/dev/null || log_warn "Не удалось разблокировать"
      sleep 2
      fail2ban_menu
      ;;
    6)
      systemctl stop fail2ban 2>/dev/null
      apt-get purge -y fail2ban > /dev/null 2>&1
      log_ok "fail2ban удалён"
      sleep 2
      fail2ban_menu
      ;;
    0) return ;;
    *) fail2ban_menu ;;
  esac
}

# ---------------------------------------------------------------------------
# Главное меню
# ---------------------------------------------------------------------------
show_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Remnawave All-in-One Manager v${SCRIPT_VERSION}${COLOR_RESET}"
  echo -e "${COLOR_GRAY}----------------------------------------------------------------${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Remnawave (панель и страница подписки)${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Remnanode${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Управление сертификатами${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}4. Дополнительно${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}5. Обновление скрипта${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}6. Удаление скрипта${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Выход${COLOR_RESET}"
  echo ""
  reading "Выберите пункт:" menu_opt
  case $menu_opt in
    1) panel_menu ;;
    2) node_menu ;;
    3) manage_cert_menu ;;
    4) extra_menu ;;
    5) update_script ;;
    6) remove_script ;;
    0) echo -e "${COLOR_GRAY}До свидания${COLOR_RESET}"; exit 0 ;;
    *) show_menu ;;
  esac
}

panel_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Remnawave (панель и страница подписки)${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Установить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Запустить / Остановить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Обновить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}4. Переустановить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}5. Логи${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}6. Доступ к панели (8443 open/close)${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}7. Удалить${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выберите пункт:" opt
  case $opt in
    1) install_panel ;;
    2)
      if docker ps -q --filter "ancestor=remnawave/backend:2" | grep -q .; then
        log_info "Панель запущена. Останавливаю..."
        compose_stop panel
      else
        log_info "Панель остановлена. Запускаю..."
        compose_start panel
      fi
      ;;
    3) compose_update panel ;;
    4) compose_reinstall panel ;;
    5) compose_logs panel ;;
    6) panel_access_menu ;;
    7)
      compose_remove panel
      log_warn "Рекомендуется также удалить записи в панели на сайте (вручную)"
      ;;
    0) show_menu ;;
    *) panel_menu ;;
  esac
  sleep 2
  panel_menu
}

panel_access_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Доступ к панели через порт 8443${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Открыть доступ (8443)${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Закрыть доступ (8443)${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1) open_panel_access ;;
    2) close_panel ;;
    0) panel_menu ;;
    *) panel_access_menu ;;
  esac
  sleep 2
  panel_access_menu
}

node_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Remnanode${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Установить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Запустить / Остановить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. Обновить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}4. Переустановить${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}5. Логи${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}6. Удалить${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выберите пункт:" opt
  case $opt in
    1) install_node ;;
    2)
      if docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q . || docker ps --format '{{.Names}}' | grep -q '^remnanode$'; then
        log_info "Нода запущена. Останавливаю..."
        compose_stop node
      else
        log_info "Нода остановлена. Запускаю..."
        compose_start node
      fi
      ;;
    3) compose_update node ;;
    4) compose_reinstall node ;;
    5) compose_logs node ;;
    6) compose_remove node ;;
    0) show_menu ;;
    *) node_menu ;;
  esac
  sleep 2
  node_menu
}

extra_menu() {
  echo ""
  echo -e "${COLOR_GREEN}Дополнительно${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}1. Управление BBR${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Управление IPv6${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}3. WARP Native${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}4. Управление UFW${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}5. Управление SSH-ключами${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}6. Управление Fail2ban${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1) bbr_menu ;;
    2) ipv6_menu ;;
    3) warp_menu ;;
    4) ufw_menu ;;
    5) ssh_menu ;;
    6) fail2ban_menu ;;
    0) show_menu ;;
    *) extra_menu ;;
  esac
}

# ---------------------------------------------------------------------------
# Обновление / удаление скрипта
# ---------------------------------------------------------------------------
update_script() {
  echo -e "${COLOR_YELLOW}Проверка обновлений скрипта...${COLOR_RESET}"
  local remote_version
  remote_version=$(curl -s "$SCRIPT_URL" | grep -m1 "SCRIPT_VERSION=" | sed -E 's/.*SCRIPT_VERSION="([^"]+)".*/\1/')
  if [ -z "$remote_version" ]; then
    log_error "Не удалось проверить версию. Проверьте SCRIPT_URL в скрипте"
    sleep 2
    show_menu
    return
  fi
  if [ "$remote_version" = "$SCRIPT_VERSION" ]; then
    log_ok "Установлена последняя версия ($SCRIPT_VERSION)"
  else
    log_info "Доступна версия $remote_version. Текущая: $SCRIPT_VERSION"
    reading "Обновить? (y/N):" confirm
    if [[ "$confirm" =~ ^[yY] ]]; then
      local tmp="${DIR_REMNAWAVE}update.sh"
      curl -sL "$SCRIPT_URL" -o "$tmp"
      chmod +x "$tmp"
      mv "$tmp" "$0" 2>/dev/null || { cp "$tmp" "$0"; chmod +x "$0"; }
      echo -e "${COLOR_GREEN}Скрипт обновлён. Перезапустите.${COLOR_RESET}"
      exit 0
    fi
  fi
  sleep 2
  show_menu
}

remove_script() {
  echo ""
  echo -e "${COLOR_RED}Удаление скрипта${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}1. Только скрипт${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}2. Скрипт + панель + нода (всё)${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_YELLOW}0. Назад${COLOR_RESET}"
  echo ""
  reading "Выбор:" opt
  case $opt in
    1)
      reading "Удалить скрипт? (y/N):" c
      if [[ "$c" =~ ^[yY] ]]; then
        rm -rf "${DIR_REMNAWAVE}"
        rm -f /usr/local/bin/remnawave_manager 2>/dev/null
        rm -f "$0"
        echo -e "${COLOR_GREEN}Скрипт удалён${COLOR_RESET}"
        exit 0
      fi
      ;;
    2)
      reading "Удалить скрипт + все данные? (y/N):" c
      if [[ "$c" =~ ^[yY] ]]; then
        if panel_dir_exists; then
          cd "$PANEL_DIR" && docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1
          rm -rf "$PANEL_DIR"
        fi
        if node_dir_exists; then
          cd "$NODE_DIR" && docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1
          rm -rf "$NODE_DIR"
        fi
        rm -rf "${DIR_REMNAWAVE}"
        rm -f /usr/local/bin/remnawave_manager 2>/dev/null
        rm -f "$0"
        echo -e "${COLOR_GREEN}Удалено.${COLOR_RESET}"
        exit 0
      fi
      ;;
    0) show_menu ;;
    *) remove_script ;;
  esac
}

# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------
install_self() {
  mkdir -p "${DIR_REMNAWAVE}"
  ln -sf "$(readlink -f "$0")" /usr/local/bin/remnawave_manager 2>/dev/null || true
}

main() {
  clear
  log_entry
  check_root
  check_os
  install_self
  show_menu
}

main "$@"
