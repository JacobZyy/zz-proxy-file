#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP_ROOT="/srv/zz-proxy-file"
readonly RELEASES_DIR="$APP_ROOT/releases"
readonly CURRENT_LINK="$APP_ROOT/current"
readonly LAST_GOOD_LINK="$APP_ROOT/last-good"
readonly CONFIG_DIR="/etc/clash-config-tool"
readonly ENV_FILE="$CONFIG_DIR/api.env"
readonly SYSTEMD_UNIT="/etc/systemd/system/clash-config-tool.service"
readonly SYSTEMD_UNIT_MARKER="# Managed by zz-proxy-file/scripts/deploy.sh"
readonly CADDY_FILE="/etc/caddy/Caddyfile"
readonly CADDY_STATE_FILE="$CONFIG_DIR/caddyfile.sha256"
readonly ORIGINAL_CADDY_SHA256="5e9bb4e7cccbce1ac704ab126edfc96361dedfc1901abcb0858f88d6a6d2d992"
readonly POSTGRES_DATA="/var/lib/pgsql/data"
readonly POSTGRES_CONFIG="$POSTGRES_DATA/postgresql.conf"
readonly POSTGRES_HBA="$POSTGRES_DATA/pg_hba.conf"
readonly POSTGRES_OWNER_MARKER="$POSTGRES_DATA/.zz-proxy-file-managed"
readonly POSTGRES_OWNER_MARKER_CONTENT="Managed by zz-proxy-file/scripts/deploy.sh"
readonly DB_NAME="zz_proxy_file"
readonly DB_USER="zz_proxy_file"
readonly API_URL="http://127.0.0.1:3001/clash-config-tool"
readonly PUBLIC_HOST="jacob-z.top"
readonly PNPM_VERSION="10.12.4"
readonly DEPLOY_LOCK_FILE="/run/lock/zz-proxy-file-deploy.lock"
readonly MAIN_BASHPID="${BASHPID:-$$}"

REPO_DIR="${REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
DEPLOY_CORS_ORIGIN="${DEPLOY_CORS_ORIGIN:-}"
CHECK_ONLY=0
WITH_CADDY=0
CADDY_MANAGED=0
CADDY_REQUIRED=0
CADDY_PASSWORD=""
CADDY_PASSWORD_HASH=""
DB_PASSWORD=""
SUBSCRIPTION_TOKEN=""
WRONG_SUBSCRIPTION_TOKEN=""
DEPLOY_ID=""
BACKUP_DIR=""
RELEASE_DIR=""
ROLLBACK_RELEASE=""
ORIGINAL_CURRENT_RELEASE=""
ORIGINAL_LAST_GOOD_RELEASE=""
VERIFY_SUBSCRIPTION_PATH=""

DEPLOYMENT_STARTED=0
ROLLBACK_RUNNING=0
CURRENT_CHANGED=0
LAST_GOOD_CHANGED=0
ENV_FILE_EXISTED=0
SYSTEMD_UNIT_EXISTED=0
API_WAS_ACTIVE=0
API_WAS_ENABLED=0
POSTGRES_WAS_ACTIVE=0
POSTGRES_WAS_ENABLED=0
POSTGRES_CONFIG_BACKED_UP=0
CADDY_STATE_EXISTED=0
CADDY_REPLACED=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/deploy.sh [--check] [--with-caddy]

  --check       Run preflight checks only. Corepack and package-manager metadata
                caches may be populated; no deployment files or services change.
  --with-caddy  Publish or rotate the protected HTTPS routes after ICP filing.

Default deploys PostgreSQL, API, and static assets locally. If this script already
manages Caddy, the existing routes remain in use but the Caddyfile is not changed.
USAGE
}

log() {
  printf '[deploy] %s\n' "$*"
}

die() {
  local message="$*"
  printf '[deploy] ERROR: %s\n' "$message" >&2 || true
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

while (($# > 0)); do
  case "$1" in
    --check)
      CHECK_ONLY=1
      ;;
    --with-caddy)
      WITH_CADDY=1
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ -e "$CADDY_STATE_FILE" || -L "$CADDY_STATE_FILE" ]]; then
  CADDY_MANAGED=1
fi
if [[ "$WITH_CADDY" -eq 1 || "$CADDY_MANAGED" -eq 1 ]]; then
  CADDY_REQUIRED=1
  DEPLOY_CORS_ORIGIN="${DEPLOY_CORS_ORIGIN:-https://$PUBLIC_HOST}"
  [[ "$DEPLOY_CORS_ORIGIN" == https://* ]] ||
    die "managed Caddy deployments require an https CORS origin"
else
  DEPLOY_CORS_ORIGIN="${DEPLOY_CORS_ORIGIN:-http://127.0.0.1:5173}"
fi

on_error() {
  local status=$?
  local line="${1:-unknown}"
  trap - ERR
  if [[ "${BASHPID:-$$}" != "$MAIN_BASHPID" ]]; then
    exit "$status"
  fi
  printf '[deploy] ERROR: command failed at line %s (status %s)\n' "$line" "$status" >&2 ||
    true
  exit "$status"
}

on_signal() {
  local signal="$1" status="$2"
  trap - ERR HUP INT TERM
  printf '[deploy] ERROR: received %s\n' "$signal" >&2 || true
  exit "$status"
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ "${BASHPID:-$$}" != "$MAIN_BASHPID" ]]; then
    exit "$status"
  fi
  if [[ "$DEPLOYMENT_STARTED" -eq 1 && "$ROLLBACK_RUNNING" -eq 0 ]]; then
    printf '[deploy] ERROR: shell exited before deployment committed\n' >&2 || true
    rollback_deployment ||
      printf '[deploy] ERROR: rollback incomplete; inspect %s\n' "$BACKUP_DIR" >&2 ||
      true
  fi
  exit "$status"
}

trap 'on_error "$LINENO"' ERR
trap 'on_signal HUP 129' HUP
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap on_exit EXIT

check_repository() {
  [[ -d "$REPO_DIR/.git" ]] || die "not a Git repository: $REPO_DIR"
  [[ "$(git -C "$REPO_DIR" branch --show-current)" == "main" ]] ||
    die "repository must be on main"

  if [[ -n "$(git -C "$REPO_DIR" status --porcelain --untracked-files=normal)" ]]; then
    git -C "$REPO_DIR" status --short >&2
    die "repository has local changes"
  fi

  [[ "$(git -C "$REPO_DIR" rev-parse HEAD)" == "$(git -C "$REPO_DIR" rev-parse origin/main)" ]] ||
    die "main differs from origin/main; run git pull --ff-only"
}

check_release_links() {
  local current_release="" last_good_release=""

  [[ ! -e "$CURRENT_LINK" || -L "$CURRENT_LINK" ]] ||
    die "$CURRENT_LINK exists and is not a symlink"
  [[ ! -e "$LAST_GOOD_LINK" || -L "$LAST_GOOD_LINK" ]] ||
    die "$LAST_GOOD_LINK exists and is not a symlink"
  if [[ -L "$CURRENT_LINK" ]]; then
    current_release="$(readlink -f "$CURRENT_LINK" || true)"
    [[ -n "$current_release" && -d "$current_release" ]] || die "$CURRENT_LINK is broken"
  fi
  if [[ -L "$LAST_GOOD_LINK" ]]; then
    last_good_release="$(readlink -f "$LAST_GOOD_LINK" || true)"
    [[ -n "$last_good_release" && -d "$last_good_release" ]] || die "$LAST_GOOD_LINK is broken"
  fi
  if [[ -n "$current_release" && -n "$last_good_release" ]]; then
    [[ "$current_release" == "$last_good_release" ]] ||
      die "$CURRENT_LINK and $LAST_GOOD_LINK point to different releases"
  fi
}

check_systemd_unit_ownership() {
  if [[ -e "$SYSTEMD_UNIT" || -L "$SYSTEMD_UNIT" ]]; then
    [[ -f "$SYSTEMD_UNIT" && ! -L "$SYSTEMD_UNIT" ]] ||
      die "$SYSTEMD_UNIT is not a regular managed file"
    grep -Fxq "$SYSTEMD_UNIT_MARKER" "$SYSTEMD_UNIT" ||
      die "$SYSTEMD_UNIT is not managed by this deploy script"
  fi
}

check_environment_file_ownership() {
  if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] ||
      die "$ENV_FILE is not a regular managed file"
    grep -Fxq '# Managed by scripts/deploy.sh' "$ENV_FILE" ||
      die "$ENV_FILE is not managed by this deploy script"
    [[ "$(stat -c '%U:%G:%a' "$ENV_FILE")" == "root:root:600" ]] ||
      die "$ENV_FILE must be owned by root:root with mode 0600"
  fi
}

check_caddy_ownership() {
  local current_hash expected_hash

  [[ -f "$CADDY_FILE" && ! -L "$CADDY_FILE" ]] ||
    die "$CADDY_FILE is not a regular file"
  if [[ -e "$CADDY_STATE_FILE" || -L "$CADDY_STATE_FILE" ]]; then
    [[ -f "$CADDY_STATE_FILE" && ! -L "$CADDY_STATE_FILE" ]] ||
      die "$CADDY_STATE_FILE is not a regular managed file"
    [[ "$(stat -c '%U:%G:%a' "$CADDY_STATE_FILE")" == "root:root:600" ]] ||
      die "$CADDY_STATE_FILE must be owned by root:root with mode 0600"
  fi
  current_hash="$(sha256sum "$CADDY_FILE" | awk '{print $1}')"
  if [[ -s "$CADDY_STATE_FILE" ]]; then
    expected_hash="$(tr -d '[:space:]' <"$CADDY_STATE_FILE")"
  else
    expected_hash="$ORIGINAL_CADDY_SHA256"
  fi
  [[ "$current_hash" == "$expected_hash" ]] ||
    die "Caddyfile changed outside deploy script; inspect it manually before deployment"
}

check_postgres_data_ownership() {
  local version marker

  if [[ -e "$POSTGRES_DATA/PG_VERSION" ]]; then
    version="$(tr -d '[:space:]' <"$POSTGRES_DATA/PG_VERSION")"
    [[ "$version" == "16" ]] ||
      die "$POSTGRES_DATA contains PostgreSQL $version data; PostgreSQL 16 migration is required"
    [[ -f "$POSTGRES_OWNER_MARKER" && ! -L "$POSTGRES_OWNER_MARKER" ]] ||
      die "$POSTGRES_DATA is not owned by this deploy script (missing marker)"
    [[ "$(stat -c '%U:%G:%a' "$POSTGRES_OWNER_MARKER")" == "root:root:600" ]] ||
      die "$POSTGRES_OWNER_MARKER must be owned by root:root with mode 0600"
    marker="$(tr -d '\r\n' <"$POSTGRES_OWNER_MARKER")"
    [[ "$marker" == "$POSTGRES_OWNER_MARKER_CONTENT" ]] ||
      die "invalid PostgreSQL ownership marker: $POSTGRES_OWNER_MARKER"
  elif [[ -e "$POSTGRES_OWNER_MARKER" || -L "$POSTGRES_OWNER_MARKER" ]]; then
    die "PostgreSQL ownership marker exists without PG_VERSION"
  fi
}

preflight() {
  [[ "$EUID" -eq 0 ]] || die "run as root"

  local command_name caddy_version="unmanaged" rust_host
  for command_name in \
    awk bash cargo corepack curl dnf file find flock git grep install journalctl node openssl \
    python3 readlink rpm rsync runuser rustc sed sha256sum ss stat systemctl; do
    require_command "$command_name"
  done

  if [[ "$CADDY_REQUIRED" -eq 1 ]]; then
    require_command caddy
    require_command getent
    getent passwd caddy >/dev/null || die "missing caddy user"
    getent group caddy >/dev/null || die "missing caddy group"
    systemctl is-active --quiet caddy.service || die "caddy.service is not active"
    check_caddy_ownership
    runuser -u caddy -- caddy validate --config "$CADDY_FILE" >/dev/null
    caddy_version="$(caddy version | awk '{print $1}')"
  fi

  check_repository
  check_release_links
  check_systemd_unit_ownership
  check_environment_file_ownership
  [[ "$(uname -s)" == "Linux" ]] || die "Linux server required"
  [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 server required"
  node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)' ||
    die "Node.js 24 or newer required"
  [[ "$(corepack pnpm@"$PNPM_VERSION" --version)" == "$PNPM_VERSION" ]] ||
    die "pnpm $PNPM_VERSION unavailable through Corepack"
  rust_host="$(rustc -vV | awk '/^host:/ { print $2 }')"
  [[ "$rust_host" == "x86_64-unknown-linux-gnu" ]] ||
    die "Rust x86_64-unknown-linux-gnu toolchain required"

  check_postgres_data_ownership
  if ! rpm -q postgresql16-server >/dev/null 2>&1; then
    dnf -q list --available postgresql16-server >/dev/null ||
      die "postgresql16-server unavailable from configured repositories"
  fi

  log "preflight passed"
  log "repo=$(git -C "$REPO_DIR" rev-parse --short=12 HEAD) node=$(node --version) rust=$(rustc --version | awk '{print $2}') caddy=$caddy_version"
}

confirm_caddy_deployment() {
  local answer password_confirm
  local LC_ALL=C

  [[ "$WITH_CADDY" -eq 1 ]] || return 0
  [[ -t 0 ]] || die "--with-caddy requires an interactive terminal"
  printf '%s\n' \
    'WARNING: This publishes HTTPS routes and rotates the management password.' \
    'Only continue after ICP filing is complete.' \
    'The frontend and CRUD API use Basic Auth; subscriptions require a token.'
  read -r -p 'Type DEPLOY to continue: ' answer
  [[ "$answer" == "DEPLOY" ]] || die "Caddy deployment cancelled"
  read -r -s -p 'Caddy management password (minimum 16 characters): ' CADDY_PASSWORD
  printf '\n'
  read -r -s -p 'Confirm Caddy management password: ' password_confirm
  printf '\n'
  [[ "$CADDY_PASSWORD" == "$password_confirm" ]] || die "Caddy passwords do not match"
  [[ "${#CADDY_PASSWORD}" -ge 16 ]] || die "Caddy password is shorter than 16 characters"
  [[ "$CADDY_PASSWORD" =~ ^[[:print:]]+$ ]] ||
    die "Caddy password must contain printable ASCII only (no CR, LF, or tab)"
  CADDY_PASSWORD_HASH="$(printf '%s\n' "$CADDY_PASSWORD" | caddy hash-password --algorithm bcrypt)"
  [[ -n "$CADDY_PASSWORD_HASH" ]] || die "failed to hash Caddy password"
  unset password_confirm answer
}

acquire_deploy_lock() {
  exec 9>"$DEPLOY_LOCK_FILE"
  flock -n 9 || die "another deployment is already running"
}

load_secrets() {
  local db_count token_count

  if [[ -f "$ENV_FILE" ]]; then
    grep -q '^# Managed by scripts/deploy.sh$' "$ENV_FILE" ||
      die "$ENV_FILE is not managed by this deploy script"
    db_count="$(grep -c '^ZZ_PROXY_DB_PASSWORD=' "$ENV_FILE" || true)"
    token_count="$(grep -c '^SUBSCRIPTION_TOKEN=' "$ENV_FILE" || true)"
    [[ "$db_count" == "1" ]] || die "managed database password is missing or duplicated"
    [[ "$token_count" == "0" || "$token_count" == "1" ]] ||
      die "managed subscription token is duplicated"
    DB_PASSWORD="$(sed -n 's/^ZZ_PROXY_DB_PASSWORD=//p' "$ENV_FILE")"
    if [[ "$token_count" == "1" ]]; then
      SUBSCRIPTION_TOKEN="$(sed -n 's/^SUBSCRIPTION_TOKEN=//p' "$ENV_FILE")"
    fi
  else
    DB_PASSWORD="$(openssl rand -hex 32)"
  fi

  if [[ -z "$SUBSCRIPTION_TOKEN" ]]; then
    SUBSCRIPTION_TOKEN="$(openssl rand -hex 32)"
  fi
  [[ "$DB_PASSWORD" =~ ^[0-9a-f]{64}$ ]] || die "invalid managed database password"
  [[ "$SUBSCRIPTION_TOKEN" =~ ^[0-9a-f]{64}$ ]] || die "invalid managed subscription token"
  if [[ "${SUBSCRIPTION_TOKEN:0:1}" == "0" ]]; then
    WRONG_SUBSCRIPTION_TOKEN="1${SUBSCRIPTION_TOKEN:1}"
  else
    WRONG_SUBSCRIPTION_TOKEN="0${SUBSCRIPTION_TOKEN:1}"
  fi
}

build_release() {
  local -a pnpm_command=(corepack "pnpm@$PNPM_VERSION")

  log "installing locked dependencies"
  cd "$REPO_DIR"
  "${pnpm_command[@]}" install --frozen-lockfile
  log "running checks and tests"
  "${pnpm_command[@]}" --filter @zz-proxy/api format
  "${pnpm_command[@]}" check
  "${pnpm_command[@]}" test
  log "building Linux API and prefixed web assets"
  VITE_API_URL=/clash-config-tool \
    VITE_SUBSCRIPTION_ORIGIN= \
    VITE_SUBSCRIPTION_TOKEN= \
    "${pnpm_command[@]}" exec turbo run build --force

  file apps/api/target/release/zz-proxy-file-api | grep 'ELF 64-bit' >/dev/null ||
    die "API output is not a Linux ELF binary"
  grep -q '/clash-config/assets/' apps/web/dist/index.html ||
    die "web output does not contain /clash-config asset prefix"
}

capture_deployment_state() {
  local resolved

  check_release_links

  if [[ -L "$CURRENT_LINK" ]]; then
    resolved="$(readlink -f "$CURRENT_LINK" || true)"
    [[ -n "$resolved" && -d "$resolved" ]] || die "$CURRENT_LINK is broken"
    ORIGINAL_CURRENT_RELEASE="$resolved"
  fi
  if [[ -L "$LAST_GOOD_LINK" ]]; then
    resolved="$(readlink -f "$LAST_GOOD_LINK" || true)"
    [[ -n "$resolved" && -d "$resolved" ]] || die "$LAST_GOOD_LINK is broken"
    ORIGINAL_LAST_GOOD_RELEASE="$resolved"
    ROLLBACK_RELEASE="$resolved"
  else
    ROLLBACK_RELEASE="$ORIGINAL_CURRENT_RELEASE"
  fi

  if [[ -f "$ENV_FILE" ]]; then
    ENV_FILE_EXISTED=1
    cp -a "$ENV_FILE" "$BACKUP_DIR/api.env"
  fi
  if [[ -f "$SYSTEMD_UNIT" ]]; then
    SYSTEMD_UNIT_EXISTED=1
    cp -a "$SYSTEMD_UNIT" "$BACKUP_DIR/clash-config-tool.service"
  fi
  if [[ -f "$CADDY_STATE_FILE" ]]; then
    CADDY_STATE_EXISTED=1
    cp -a "$CADDY_STATE_FILE" "$BACKUP_DIR/caddyfile.sha256"
  fi
  systemctl is-active --quiet clash-config-tool.service && API_WAS_ACTIVE=1 || true
  systemctl is-enabled --quiet clash-config-tool.service && API_WAS_ENABLED=1 || true
  systemctl is-active --quiet postgresql.service && POSTGRES_WAS_ACTIVE=1 || true
  systemctl is-enabled --quiet postgresql.service && POSTGRES_WAS_ENABLED=1 || true
}

wait_for_api_health() {
  local attempt health_response
  for attempt in {1..30}; do
    if health_response="$(curl -q -fsS "$API_URL/health" 2>/dev/null)" &&
      [[ "$health_response" == *'"status":"ok"'* ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

write_curl_url_config() {
  local config_file="$1" url="$2"
  printf 'url = "%s"\n' "$url" >"$config_file"
  chmod 0600 "$config_file"
}

write_curl_auth_config() {
  local config_file="$1" escaped_password="$CADDY_PASSWORD"
  escaped_password="${escaped_password//\\/\\\\}"
  escaped_password="${escaped_password//\"/\\\"}"
  printf 'user = "clashadmin:%s"\n' "$escaped_password" >"$config_file"
  chmod 0600 "$config_file"
}

verify_subscription_token_response() {
  local body_file="$1" headers_file="$2" returned_token
  returned_token="$(python3 -c 'import json, sys; value=json.load(open(sys.argv[1])); assert set(value) == {"token"}; print(value["token"])' "$body_file")" ||
    return 1
  [[ "$returned_token" == "$SUBSCRIPTION_TOKEN" ]] || return 1
  grep -Eqi '^cache-control:.*no-store' "$headers_file"
}

restore_postgresql_state() {
  local failed=0

  if [[ "$POSTGRES_CONFIG_BACKED_UP" -eq 1 ]]; then
    cp -a "$BACKUP_DIR/postgresql.conf" "$POSTGRES_CONFIG" || failed=1
    cp -a "$BACKUP_DIR/pg_hba.conf" "$POSTGRES_HBA" || failed=1
    chown postgres:postgres "$POSTGRES_CONFIG" "$POSTGRES_HBA" || failed=1
  fi
  if [[ "$POSTGRES_WAS_ACTIVE" -eq 1 ]]; then
    systemctl restart postgresql.service || failed=1
  else
    systemctl stop postgresql.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet postgresql.service; then
      failed=1
    fi
  fi
  if [[ "$POSTGRES_WAS_ENABLED" -eq 1 ]]; then
    systemctl enable postgresql.service >/dev/null || failed=1
  else
    systemctl disable postgresql.service >/dev/null 2>&1 || true
    if systemctl is-enabled --quiet postgresql.service; then
      failed=1
    fi
  fi
  return "$failed"
}

restore_caddy_state() {
  local failed=0
  [[ "$CADDY_REPLACED" -eq 1 ]] || return 0

  cp -a "$BACKUP_DIR/Caddyfile" "$CADDY_FILE" || failed=1
  if [[ "$CADDY_STATE_EXISTED" -eq 1 ]]; then
    cp -a "$BACKUP_DIR/caddyfile.sha256" "$CADDY_STATE_FILE" || failed=1
  else
    rm -f "$CADDY_STATE_FILE" || failed=1
  fi
  runuser -u caddy -- caddy validate --config "$CADDY_FILE" >/dev/null || failed=1
  systemctl reload caddy.service || failed=1
  return "$failed"
}

restore_symlink() {
  local link_path="$1" target="$2" temp_link="$1.rollback-$DEPLOY_ID"
  if [[ -n "$target" ]]; then
    ln -s "$target" "$temp_link" && mv -Tf "$temp_link" "$link_path"
  else
    rm -f "$link_path"
  fi
}

rollback_deployment() {
  local failed=0
  ROLLBACK_RUNNING=1
  trap - ERR
  trap '' HUP INT TERM

  systemctl stop clash-config-tool.service >/dev/null 2>&1 || true
  if [[ "$CURRENT_CHANGED" -eq 1 ]]; then
    restore_symlink "$CURRENT_LINK" "$ROLLBACK_RELEASE" || failed=1
  fi
  if [[ "$LAST_GOOD_CHANGED" -eq 1 ]]; then
    restore_symlink "$LAST_GOOD_LINK" "$ORIGINAL_LAST_GOOD_RELEASE" || failed=1
  fi

  if [[ "$SYSTEMD_UNIT_EXISTED" -eq 1 ]]; then
    cp -a "$BACKUP_DIR/clash-config-tool.service" "$SYSTEMD_UNIT" || failed=1
  else
    rm -f "$SYSTEMD_UNIT" || failed=1
  fi
  if [[ "$ENV_FILE_EXISTED" -eq 1 ]]; then
    cp -a "$BACKUP_DIR/api.env" "$ENV_FILE" || failed=1
  else
    rm -f "$ENV_FILE" || failed=1
  fi
  systemctl daemon-reload || failed=1
  restore_postgresql_state || failed=1

  if [[ "$API_WAS_ENABLED" -eq 1 ]]; then
    systemctl enable clash-config-tool.service >/dev/null || failed=1
  else
    systemctl disable clash-config-tool.service >/dev/null 2>&1 || true
    if systemctl is-enabled --quiet clash-config-tool.service; then
      failed=1
    fi
  fi
  if [[ "$API_WAS_ACTIVE" -eq 1 ]]; then
    if ! systemctl restart clash-config-tool.service; then
      failed=1
    elif ! wait_for_api_health; then
      journalctl -u clash-config-tool.service -n 60 --no-pager >&2 || true
      failed=1
    fi
  else
    systemctl stop clash-config-tool.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet clash-config-tool.service; then
      failed=1
    fi
  fi
  restore_caddy_state || failed=1

  DEPLOYMENT_STARTED=0
  ROLLBACK_RUNNING=0
  if [[ -f "$BACKUP_DIR/database.dump" ]]; then
    log "database dump retained at $BACKUP_DIR/database.dump; it was not restored automatically"
  fi
  if [[ "$failed" -eq 0 ]]; then
    log "deployment rolled back to last known good state"
  fi
  return "$failed"
}

install_postgresql() {
  local postgres_temp version attempt listen_addresses password_encryption

  if ! rpm -q postgresql16-server >/dev/null 2>&1; then
    log "installing PostgreSQL 16 from OpenCloudOS EPOL"
    dnf install -y postgresql16-server
  fi
  require_command pg_dump
  require_command pg_isready
  require_command postgresql-setup
  require_command psql

  if [[ ! -e "$POSTGRES_DATA/PG_VERSION" ]]; then
    [[ ! -e "$POSTGRES_OWNER_MARKER" ]] || die "ownership marker exists without PG_VERSION"
    log "initializing PostgreSQL 16 data directory"
    postgresql-setup --initdb
    version="$(tr -d '[:space:]' <"$POSTGRES_DATA/PG_VERSION")"
    [[ "$version" == "16" ]] || die "postgresql-setup initialized unexpected version: $version"
    printf '%s\n' "$POSTGRES_OWNER_MARKER_CONTENT" >"$POSTGRES_OWNER_MARKER"
    chown root:root "$POSTGRES_OWNER_MARKER"
    chmod 0600 "$POSTGRES_OWNER_MARKER"
  fi
  check_postgres_data_ownership

  cp -a "$POSTGRES_CONFIG" "$BACKUP_DIR/postgresql.conf"
  cp -a "$POSTGRES_HBA" "$BACKUP_DIR/pg_hba.conf"
  POSTGRES_CONFIG_BACKED_UP=1

  if grep -Eq '^[#[:space:]]*listen_addresses[[:space:]]*=' "$POSTGRES_CONFIG"; then
    sed -Ei "s|^[#[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = '127.0.0.1'|" "$POSTGRES_CONFIG"
  else
    printf "\nlisten_addresses = '127.0.0.1'\n" >>"$POSTGRES_CONFIG"
  fi
  if grep -Eq '^[#[:space:]]*password_encryption[[:space:]]*=' "$POSTGRES_CONFIG"; then
    sed -Ei "s|^[#[:space:]]*password_encryption[[:space:]]*=.*|password_encryption = 'scram-sha-256'|" "$POSTGRES_CONFIG"
  else
    printf "\npassword_encryption = 'scram-sha-256'\n" >>"$POSTGRES_CONFIG"
  fi

  if grep -q '^# zz-proxy-file managed access$' "$POSTGRES_HBA"; then
    awk 'previous == "# zz-proxy-file managed access" && $0 == "host zz_proxy_file zz_proxy_file 127.0.0.1/32 scram-sha-256" { found=1 } { previous=$0 } END { exit(found ? 0 : 1) }' "$POSTGRES_HBA" ||
      die "$POSTGRES_HBA managed rule was changed"
  else
    postgres_temp="$(mktemp "$POSTGRES_DATA/pg_hba.conf.XXXXXX")"
    {
      printf '%s\n' \
        '# zz-proxy-file managed access' \
        'host zz_proxy_file zz_proxy_file 127.0.0.1/32 scram-sha-256'
      cat "$POSTGRES_HBA"
    } >"$postgres_temp"
    install -o postgres -g postgres -m 0600 "$postgres_temp" "$POSTGRES_HBA"
    rm -f "$postgres_temp"
  fi
  chown postgres:postgres "$POSTGRES_CONFIG" "$POSTGRES_HBA"

  if ! systemctl restart postgresql.service; then
    journalctl -u postgresql.service -n 40 --no-pager >&2 || true
    die "PostgreSQL restart failed"
  fi
  for attempt in {1..20}; do
    pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break
    sleep 1
  done
  pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 || {
    journalctl -u postgresql.service -n 40 --no-pager >&2 || true
    die "PostgreSQL did not become ready"
  }

  listen_addresses="$(runuser -u postgres -- psql -Atqc 'SHOW listen_addresses')"
  password_encryption="$(runuser -u postgres -- psql -Atqc 'SHOW password_encryption')"
  [[ "$listen_addresses" == "127.0.0.1" ]] ||
    die "effective PostgreSQL listen_addresses is not 127.0.0.1"
  [[ "$password_encryption" == "scram-sha-256" ]] ||
    die "effective PostgreSQL password_encryption is not scram-sha-256"
  systemctl enable postgresql.service
}

prepare_database() {
  local env_temp

  install -d -o root -g root -m 0700 "$CONFIG_DIR"
  env_temp="$(mktemp "$CONFIG_DIR/api.env.XXXXXX")"
  {
    printf '%s\n' \
      '# Managed by scripts/deploy.sh' \
      "ZZ_PROXY_DB_PASSWORD=$DB_PASSWORD" \
      "DATABASE_URL=postgres://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME" \
      "SUBSCRIPTION_TOKEN=$SUBSCRIPTION_TOKEN" \
      'BIND_ADDR=127.0.0.1:3001' \
      "CORS_ORIGIN=$DEPLOY_CORS_ORIGIN" \
      'RUST_LOG=zz_proxy_file_api=info,tower_http=info'
  } >"$env_temp"
  install -o root -g root -m 0600 "$env_temp" "$ENV_FILE"
  rm -f "$env_temp"

  runuser -u postgres -- psql --dbname postgres --set=ON_ERROR_STOP=1 <<SQL
SELECT 'CREATE ROLE zz_proxy_file LOGIN'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'zz_proxy_file')\gexec
ALTER ROLE zz_proxy_file WITH LOGIN PASSWORD '$DB_PASSWORD';
SELECT 'CREATE DATABASE zz_proxy_file OWNER zz_proxy_file'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'zz_proxy_file')\gexec
SQL

  PGPASSWORD="$DB_PASSWORD" psql --host 127.0.0.1 --username "$DB_USER" \
    --dbname "$DB_NAME" --command 'SELECT 1' >/dev/null
  PGPASSWORD="$DB_PASSWORD" pg_dump --host 127.0.0.1 --username "$DB_USER" \
    --dbname "$DB_NAME" --format custom --file "$BACKUP_DIR/database.dump"
  chmod 0600 "$BACKUP_DIR/database.dump"
}

publish_release() {
  local release_temp

  install -d -o root -g root -m 0755 "$APP_ROOT" "$RELEASES_DIR"
  install -d -o root -g root -m 0755 "$RELEASE_DIR" "$RELEASE_DIR/bin"
  install -d -o root -g root -m 0755 "$RELEASE_DIR/web"
  install -o root -g root -m 0755 "$REPO_DIR/apps/api/target/release/zz-proxy-file-api" \
    "$RELEASE_DIR/bin/clash-config-tool"
  rsync -a --delete "$REPO_DIR/apps/web/dist/" "$RELEASE_DIR/web/"
  chown -R root:root "$RELEASE_DIR"
  chmod 0755 "$RELEASE_DIR" "$RELEASE_DIR/bin"

  if [[ "$CADDY_REQUIRED" -eq 1 ]]; then
    chown -R root:caddy "$RELEASE_DIR/web"
    find "$RELEASE_DIR/web" -type d -exec chmod 0750 {} +
    find "$RELEASE_DIR/web" -type f -exec chmod 0640 {} +
  else
    find "$RELEASE_DIR/web" -type d -exec chmod 0755 {} +
    find "$RELEASE_DIR/web" -type f -exec chmod 0644 {} +
  fi

  release_temp="$APP_ROOT/.current-$DEPLOY_ID"
  ln -s "$RELEASE_DIR" "$release_temp"
  CURRENT_CHANGED=1
  mv -Tf "$release_temp" "$CURRENT_LINK"
}

install_api_service() {
  local unit_temp

  unit_temp="$(mktemp /etc/systemd/system/clash-config-tool.service.XXXXXX)"
  cat >"$unit_temp" <<'UNIT'
# Managed by zz-proxy-file/scripts/deploy.sh
[Unit]
Description=Clash Config Tool API
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
DynamicUser=yes
WorkingDirectory=/srv/zz-proxy-file/current
EnvironmentFile=/etc/clash-config-tool/api.env
ExecStart=/srv/zz-proxy-file/current/bin/clash-config-tool
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictSUIDSGID=true
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
  install -o root -g root -m 0644 "$unit_temp" "$SYSTEMD_UNIT"
  rm -f "$unit_temp"
  systemctl daemon-reload
  systemctl enable clash-config-tool.service
  systemctl restart clash-config-tool.service
}

verify_api() {
  local configs_temp config_temp subscription_slug unauthenticated_status wrong_status
  local token_body token_headers token_config

  if ! wait_for_api_health; then
    journalctl -u clash-config-tool.service -n 60 --no-pager >&2 || true
    die "API health check failed"
  fi

  token_body="$(mktemp)"
  token_headers="$(mktemp)"
  if ! curl -q -fsS -D "$token_headers" -o "$token_body" "$API_URL/api/subscription-token" ||
    ! verify_subscription_token_response "$token_body" "$token_headers"; then
    rm -f "$token_body" "$token_headers"
    die "subscription token endpoint verification failed"
  fi
  rm -f "$token_body" "$token_headers"

  configs_temp="$(mktemp)"
  curl -q -fsS "$API_URL/api/configs" >"$configs_temp" || {
    rm -f "$configs_temp"
    die "API config list request failed"
  }
  python3 -c 'import json, sys; assert isinstance(json.load(open(sys.argv[1])), list)' "$configs_temp" || {
    rm -f "$configs_temp"
    die "API config list verification failed"
  }
  subscription_slug="$(python3 -c 'import json, sys; data=json.load(open(sys.argv[1])); print(data[0]["slug"] if data else "")' "$configs_temp")"
  rm -f "$configs_temp"

  if [[ -z "$subscription_slug" ]]; then
    VERIFY_SUBSCRIPTION_PATH=""
    log "subscription verification skipped: no configurations"
  else
    VERIFY_SUBSCRIPTION_PATH="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$subscription_slug")"
    unauthenticated_status="$(curl -q -sS -o /dev/null -w '%{http_code}' "$API_URL/subscriptions/$VERIFY_SUBSCRIPTION_PATH")"
    [[ "$unauthenticated_status" == "404" ]] || die "subscription without token did not return 404"

    token_config="$(mktemp)"
    write_curl_url_config "$token_config" \
      "$API_URL/subscriptions/$VERIFY_SUBSCRIPTION_PATH?token=$WRONG_SUBSCRIPTION_TOKEN"
    if ! wrong_status="$(curl -q --config "$token_config" -sS -o /dev/null -w '%{http_code}')"; then
      rm -f "$token_config"
      die "subscription request with wrong token failed"
    fi
    rm -f "$token_config"
    [[ "$wrong_status" == "404" ]] || die "subscription with wrong token did not return 404"

    config_temp="$(mktemp)"
    token_config="$(mktemp)"
    write_curl_url_config "$token_config" \
      "$API_URL/subscriptions/$VERIFY_SUBSCRIPTION_PATH?token=$SUBSCRIPTION_TOKEN"
    curl -q --config "$token_config" -fsS >"$config_temp" || {
      rm -f "$token_config"
      rm -f "$config_temp"
      die "subscription request with token failed"
    }
    rm -f "$token_config"
    [[ -s "$config_temp" ]] || {
      rm -f "$config_temp"
      die "subscription response is empty"
    }
    rm -f "$config_temp"
  fi

  ss -lntH | grep -E '127\.0\.0\.1:3001[[:space:]]' >/dev/null ||
    die "API is not listening on loopback"
  ss -lntH | grep -E '127\.0\.0\.1:5432[[:space:]]' >/dev/null ||
    die "PostgreSQL is not listening on loopback"
}

verify_caddy() {
  local frontend_status api_status subscription_status wrong_status health_response
  local frontend_temp api_temp subscription_temp auth_config token_config token_body token_headers
  local -a resolve_args=(--resolve "$PUBLIC_HOST:443:127.0.0.1")

  health_response="$(curl -q "${resolve_args[@]}" -fsS "https://$PUBLIC_HOST/clash-config-tool/health")" ||
    return 1
  [[ "$health_response" == *'"status":"ok"'* ]] || return 1
  frontend_status="$(curl -q "${resolve_args[@]}" -sS -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/clash-config/")"
  [[ "$frontend_status" == "401" ]] || return 1
  api_status="$(curl -q "${resolve_args[@]}" -sS -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/clash-config-tool/api/configs")"
  [[ "$api_status" == "401" ]] || return 1

  auth_config="$(mktemp)"
  write_curl_auth_config "$auth_config"
  frontend_temp="$(mktemp)"
  curl -q --config "$auth_config" "${resolve_args[@]}" -fsS "https://$PUBLIC_HOST/clash-config/" >"$frontend_temp" || {
    rm -f "$auth_config" "$frontend_temp"
    return 1
  }
  grep -qi '<!doctype html' "$frontend_temp" || {
    rm -f "$auth_config" "$frontend_temp"
    return 1
  }
  rm -f "$frontend_temp"

  api_temp="$(mktemp)"
  curl -q --config "$auth_config" "${resolve_args[@]}" -fsS "https://$PUBLIC_HOST/clash-config-tool/api/configs" >"$api_temp" || {
    rm -f "$auth_config" "$api_temp"
    return 1
  }
  python3 -c 'import json, sys; assert isinstance(json.load(open(sys.argv[1])), list)' "$api_temp" || {
    rm -f "$auth_config" "$api_temp"
    return 1
  }
  rm -f "$api_temp"

  token_body="$(mktemp)"
  token_headers="$(mktemp)"
  if ! curl -q --config "$auth_config" "${resolve_args[@]}" -fsS -D "$token_headers" \
    -o "$token_body" "https://$PUBLIC_HOST/clash-config-tool/api/subscription-token" ||
    ! verify_subscription_token_response "$token_body" "$token_headers"; then
    rm -f "$auth_config" "$token_body" "$token_headers"
    return 1
  fi
  rm -f "$auth_config" "$token_body" "$token_headers"

  if [[ -n "$VERIFY_SUBSCRIPTION_PATH" ]]; then
    subscription_status="$(curl -q "${resolve_args[@]}" -sS -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/clash-config-tool/subscriptions/$VERIFY_SUBSCRIPTION_PATH")"
    [[ "$subscription_status" == "404" ]] || return 1

    token_config="$(mktemp)"
    write_curl_url_config "$token_config" \
      "https://$PUBLIC_HOST/clash-config-tool/subscriptions/$VERIFY_SUBSCRIPTION_PATH?token=$WRONG_SUBSCRIPTION_TOKEN"
    if ! wrong_status="$(curl -q --config "$token_config" "${resolve_args[@]}" -sS -o /dev/null -w '%{http_code}')"; then
      rm -f "$token_config"
      return 1
    fi
    rm -f "$token_config"
    [[ "$wrong_status" == "404" ]] || return 1

    subscription_temp="$(mktemp)"
    token_config="$(mktemp)"
    write_curl_url_config "$token_config" \
      "https://$PUBLIC_HOST/clash-config-tool/subscriptions/$VERIFY_SUBSCRIPTION_PATH?token=$SUBSCRIPTION_TOKEN"
    curl -q --config "$token_config" "${resolve_args[@]}" -fsS >"$subscription_temp" || {
      rm -f "$token_config" "$subscription_temp"
      return 1
    }
    rm -f "$token_config"
    [[ -s "$subscription_temp" ]] || {
      rm -f "$subscription_temp"
      return 1
    }
    rm -f "$subscription_temp"
  fi
}

verify_managed_caddy() {
  local frontend_status api_status subscription_status wrong_status token_config subscription_temp
  local health_response
  local -a resolve_args=(--resolve "$PUBLIC_HOST:443:127.0.0.1")

  runuser -u caddy -- test -r "$CURRENT_LINK/web/index.html" || return 1
  health_response="$(curl -q "${resolve_args[@]}" -fsS "https://$PUBLIC_HOST/clash-config-tool/health")" ||
    return 1
  [[ "$health_response" == *'"status":"ok"'* ]] || return 1
  frontend_status="$(curl -q "${resolve_args[@]}" -sS -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/clash-config/")"
  [[ "$frontend_status" == "401" ]] || return 1
  api_status="$(curl -q "${resolve_args[@]}" -sS -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/clash-config-tool/api/configs")"
  [[ "$api_status" == "401" ]] || return 1

  if [[ -n "$VERIFY_SUBSCRIPTION_PATH" ]]; then
    subscription_status="$(curl -q "${resolve_args[@]}" -sS -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/clash-config-tool/subscriptions/$VERIFY_SUBSCRIPTION_PATH")"
    [[ "$subscription_status" == "404" ]] || return 1
    token_config="$(mktemp)"
    write_curl_url_config "$token_config" \
      "https://$PUBLIC_HOST/clash-config-tool/subscriptions/$VERIFY_SUBSCRIPTION_PATH?token=$WRONG_SUBSCRIPTION_TOKEN"
    if ! wrong_status="$(curl -q --config "$token_config" "${resolve_args[@]}" -sS -o /dev/null -w '%{http_code}')"; then
      rm -f "$token_config"
      return 1
    fi
    rm -f "$token_config"
    [[ "$wrong_status" == "404" ]] || return 1
    subscription_temp="$(mktemp)"
    token_config="$(mktemp)"
    write_curl_url_config "$token_config" \
      "https://$PUBLIC_HOST/clash-config-tool/subscriptions/$VERIFY_SUBSCRIPTION_PATH?token=$SUBSCRIPTION_TOKEN"
    curl -q --config "$token_config" "${resolve_args[@]}" -fsS >"$subscription_temp" || {
      rm -f "$token_config" "$subscription_temp"
      return 1
    }
    rm -f "$token_config"
    [[ -s "$subscription_temp" ]] || {
      rm -f "$subscription_temp"
      return 1
    }
    rm -f "$subscription_temp"
  fi
}

install_caddy_routes() {
  local caddy_temp new_hash state_temp

  check_caddy_ownership
  cp -a "$CADDY_FILE" "$BACKUP_DIR/Caddyfile"
  caddy_temp="$(mktemp /etc/caddy/Caddyfile.XXXXXX)"
  cat >"$caddy_temp" <<'CADDY'
# Managed by zz-proxy-file/scripts/deploy.sh
jacob-z.top {
	redir /clash-config /clash-config/ 308

	@clashConfigAdmin path /clash-config/* /clash-config-tool/api/*
	basic_auth @clashConfigAdmin {
		clashadmin CLASH_CONFIG_PASSWORD_HASH
	}

	handle /clash-config-tool/* {
		reverse_proxy 127.0.0.1:3001
	}

	handle_path /clash-config/* {
		root * /srv/zz-proxy-file/current/web
		try_files {path} /index.html
		file_server
	}

	handle_path /node_cli_initializer/* {
		root * /srv/nlabtool/webserver
		file_server
	}

	handle {
		respond "Caddy is running"
	}
}

# light-harness-share:1078
:1078 {
	redir /light-harness-share /light-harness-share/ 308
	handle_path /light-harness-share/* {
		root * /srv/light-harness-share
		file_server
	}
	handle {
		respond "Not Found" 404
	}
}
CADDY

  python3 - "$caddy_temp" "$CADDY_PASSWORD_HASH" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
placeholder = "CLASH_CONFIG_PASSWORD_HASH"
if text.count(placeholder) != 1:
    raise SystemExit("unexpected Caddy password placeholder count")
path.write_text(text.replace(placeholder, sys.argv[2]))
PY
  chown root:caddy "$caddy_temp"
  chmod 0640 "$caddy_temp"
  caddy fmt --overwrite "$caddy_temp" >/dev/null
  runuser -u caddy -- caddy validate --config "$caddy_temp" >/dev/null
  CADDY_REPLACED=1
  mv -f "$caddy_temp" "$CADDY_FILE"
  systemctl reload caddy.service || die "Caddy reload failed"
  verify_caddy || die "Caddy route verification failed"

  new_hash="$(sha256sum "$CADDY_FILE" | awk '{print $1}')"
  state_temp="$(mktemp "$CONFIG_DIR/caddyfile.sha256.XXXXXX")"
  printf '%s\n' "$new_hash" >"$state_temp"
  install -o root -g root -m 0600 "$state_temp" "$CADDY_STATE_FILE"
  rm -f "$state_temp"
}

mark_release_good() {
  local good_temp="$APP_ROOT/.last-good-$DEPLOY_ID"
  ln -s "$RELEASE_DIR" "$good_temp"
  LAST_GOOD_CHANGED=1
  mv -Tf "$good_temp" "$LAST_GOOD_LINK"
}

preflight
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  log "check-only mode complete; tool or package metadata caches may have been populated"
  exit 0
fi

confirm_caddy_deployment
acquire_deploy_lock
load_secrets
build_release

DEPLOY_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DEPLOY_ID="$DEPLOY_TIMESTAMP-$(git -C "$REPO_DIR" rev-parse --short=12 HEAD)"
BACKUP_DIR="$APP_ROOT/backups/$DEPLOY_ID"
RELEASE_DIR="$RELEASES_DIR/$DEPLOY_ID"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
capture_deployment_state
DEPLOYMENT_STARTED=1

install_postgresql
prepare_database
publish_release
install_api_service
verify_api

if [[ "$WITH_CADDY" -eq 1 ]]; then
  install_caddy_routes
elif [[ "$CADDY_MANAGED" -eq 1 ]]; then
  verify_managed_caddy || die "managed Caddy route verification failed"
  log "managed Caddy routes retained without changing the Caddyfile"
else
  log "Caddy unchanged; use --with-caddy only after ICP filing is complete"
fi

mark_release_good
DEPLOYMENT_STARTED=0
unset CADDY_PASSWORD CADDY_PASSWORD_HASH DB_PASSWORD SUBSCRIPTION_TOKEN WRONG_SUBSCRIPTION_TOKEN
log "deployment complete: $DEPLOY_ID"
log "API health: $API_URL/health"
if [[ -n "$VERIFY_SUBSCRIPTION_PATH" ]]; then
  log "subscription verified with its required token (token omitted from logs)"
fi
