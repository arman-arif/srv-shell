#!/usr/bin/env bash
# =============================================================================
#  srv — single-file server & site manager for Nginx-based web hosting
#  Version 4.0.0 (Phase 4)
#
#  What it does
#    • Setup wizard: system upgrade, timezone, hostname, swap, sudo user,
#      SSH hardening, UFW firewall, fail2ban, automatic security updates
#    • Stack: Nginx, PHP-FPM (any version) + Composer, MariaDB / MySQL,
#      PostgreSQL, Redis, Node.js (any version), Python 3, Supervisor, PM2,
#      Certbot (Let's Encrypt), scheduled database backups
#    • Sites: static, SPA, PHP, Laravel, Node.js apps (Next.js, Nuxt, NestJS,
#      Express …), Python apps (Django, Flask, FastAPI) and reverse proxies.
#      Each site gets its own Linux user, optional database (MySQL or
#      PostgreSQL), optional Redis and HTTPS.
#    • Apps run under systemd, PM2 or Supervisor — one set of commands for all
#    • Laravel queue workers, Horizon and Reverb via Supervisor
#    • Git deploys: releases + atomic "current" switch, shared files, build
#      hooks, migrations, health check with automatic rollback, deploy keys,
#      webhooks (GitHub / GitLab / Bitbucket), maintenance mode
#    • Backups: databases + site files, rotation, restore, remote copies
#      via rclone (S3, R2, B2, Google Drive …)
#    • Admin: Adminer / phpMyAdmin (secret URL + password + IP allowlist),
#      health checks with alerts (Telegram, Slack, Discord, webhook), a live
#      dashboard, several PHP / Node.js / Python versions, per-site cron jobs,
#      www ↔ non-www redirects, self-update
#    • Anything skipped during setup can be installed later:  srv install
#
#  Supported OS: Ubuntu 22.04+ LTS, Debian 12+
#
#  Quick start
#    sudo bash srv.sh setup     # first run — also installs the 'srv' command
#    sudo srv                   # interactive menu
#    sudo srv help              # all commands
#
#  Upgrading an existing server:  sudo bash srv.sh self-install
# =============================================================================

set -Eeuo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
SRV_VERSION="4.0.1"
SRV_DIR="/etc/srv"
SRV_STATE="$SRV_DIR/installed.conf"     # installed features
SRV_CFG="$SRV_DIR/srv.conf"             # global settings
SRV_SITES="$SRV_DIR/sites"              # one <domain>.conf per site
SRV_LOG="/var/log/srv.log"
SRV_BIN="/usr/local/bin/srv"
SRV_UPDATE_URL="https://raw.githubusercontent.com/arman-arif/srv-shell/main/srv.sh"   # srv self-update
SRV_LIB="/opt/srv"                      # runtimes and app launchers
SRV_RUN="$SRV_LIB/run"                  # <domain>.sh launchers, PM2 configs
NODE_ROOT="$SRV_LIB/node"               # <major> -> versions/vX.Y.Z
PM2_PREFIX="$SRV_LIB/pm2"
SRV_WWW="/var/www/_srv"                 # shared pages (maintenance)
HOOKS_DIR="/etc/srv-webhooks"           # per-site webhook secrets (readable by srv-hook)
DEPLOY_QUEUE="/var/lib/srv/deploy-queue"
RCLONE_CONF="$SRV_DIR/rclone.conf"
WEB_ROOT="/var/www"
ACME_ROOT="/var/www/_letsencrypt"
NGINX_CUSTOM="/etc/nginx/srv-custom"
BACKUP_DIR="/var/backups/srv"
PHP_DEFAULT="8.4"
PHP_OFFERED=(8.4 8.5 8.3 8.2 8.1)

FEATURES=(upgrade timezone hostname swap sudo-user ssh firewall fail2ban auto-updates
          nginx php composer database postgres redis node python supervisor pm2 certbot backup rclone webhook dbadmin)

# ── Runtime state ────────────────────────────────────────────────────────────
INTERACTIVE=0
if [[ -t 0 && -t 2 ]]; then INTERACTIVE=1; fi
USE_WT=0
ASSUME_YES=${SRV_YES:-0}
SRV_PLAIN=${SRV_PLAIN:-0}
MENU_MODE=0
TRY_RC=0
TMP_DIR=""
SRV_MAIN_PID=$$
OS_ID="" OS_VER="" OS_CODENAME="" OS_NAME=""
MOD_OK=() MOD_FAIL=()
NODE_LAST_MAJOR=""
DB_ENG=""
DEPLOY_SITE="" DEPLOY_NEW_REL="" DEPLOY_ACTIVATED=0 DEPLOY_MAINT_SET=0 DEPLOY_ENV_CREATED=0
TOOLS_NEW_PASS="" OPT_TOOLS="" OPT_TOOLS_HOST="" OPT_TOOLS_FILE="" OPT_PYVER=""   # OPT_TOOLS_ALLOW: unset = not given

# Answers collected by the ask_* functions, consumed by the mod_* functions
OPT_TZ="" OPT_HOSTNAME="" OPT_SWAP="" OPT_USER="" OPT_USER_KEYS="no" OPT_USER_PASS=""
OPT_SSH_PORT="" OPT_ROOT_LOGIN="" OPT_SSH_NOPASS="no" OPT_PHP="" OPT_DB_ENGINE=""
OPT_EMAIL="" OPT_BACKUP_KEEP="" OPT_BACKUP_FILES="" OPT_NODE="" OPT_PG="" OPT_REDIS_POLICY=""

# Answers collected while adding a site
S_NODE="" S_PRESET="" S_START="" S_START_SET=0 S_BUILD="" S_BUILD_SET=0 S_PM="" S_PORT=""
S_FRAMEWORK="" S_SERVER="" S_MODULE="" S_MODULE_SET=0 S_WORKERS="" S_UPSTREAM="" S_WS="" S_PRESERVE=""
S_PYVER="" S_PYVER_SET=0 S_CANON=""

# ── Output & logging ─────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[34m' C_C=$'\e[36m'
  C_D=$'\e[2m' C_BOLD=$'\e[1m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_C="" C_D="" C_BOLD="" C_0=""
fi

log()  { { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$SRV_LOG"; } 2>/dev/null || true; }
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*" >&2; log "INFO  $*"; }
ok()   { printf ' %s✓%s %s\n' "$C_G" "$C_0" "$*" >&2; log "OK    $*"; }
warn() { printf ' %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; log "WARN  $*"; }
err()  { printf ' %s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; log "ERROR $*"; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s%s▸ %s%s\n' "$C_BOLD" "$C_C" "$*" "$C_0" >&2; log "STEP  $*"; }
hr()   { printf '%s%s%s\n' "$C_D" "──────────────────────────────────────────────────────────────" "$C_0"; }

on_err()  { local rc=$?; log "TRACE rc=$rc line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND}"; }
cleanup() { if [[ $BASHPID == "$SRV_MAIN_PID" && -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf "$TMP_DIR"; fi; }

# Run a command, send its output to the log, show the log tail on failure.
run() {
  log "RUN   $*"
  local rc=0
  # 9>&- : don't let daemons started by the command inherit srv's lock
  "$@" 9>&- >>"$SRV_LOG" 2>&1 || rc=$?
  if (( rc == 0 )); then return 0; fi
  err "Command failed (exit $rc): $*"
  tail -n 12 "$SRV_LOG" 2>/dev/null | sed 's/^/     │ /' >&2 || true
  return "$rc"
}

# Run a function in a subshell with errexit, without killing the caller.
# The exit code is left in TRY_RC.
try() { set +e; ( set -e; "$@" ); TRY_RC=$?; set -e; return 0; }

# ── Key=value stores (state, config, sites) ──────────────────────────────────
kv_get() {
  local file=$1 key=$2 def=${3-} line=""
  if [[ -f $file ]]; then line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1) || true; fi
  if [[ -n $line ]]; then printf '%s' "${line#*=}"; else printf '%s' "$def"; fi
}
kv_set() {
  local file=$1 key=$2 val=$3 tmp
  mkdir -p "$(dirname "$file")"; touch "$file"
  tmp=$(mktemp "$file.XXXXXX")
  grep -vE "^${key}=" "$file" >"$tmp" || true
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$file"
}
kv_del() {
  local file=$1 key=$2 tmp
  [[ -f $file ]] || return 0
  tmp=$(mktemp "$file.XXXXXX")
  grep -vE "^${key}=" "$file" >"$tmp" || true
  chmod 600 "$tmp"; mv -f "$tmp" "$file"
}
feat_get() { kv_get "$SRV_STATE" "$1"; }
feat_has() { [[ -n $(kv_get "$SRV_STATE" "$1") ]]; }
feat_set() { kv_set "$SRV_STATE" "$1" "${2:-$(date '+%F %T')}"; }
cfg_get()  { kv_get "$SRV_CFG" "$1" "${2-}"; }
cfg_set()  { kv_set "$SRV_CFG" "$1" "$2"; }

# ── UI: whiptail dialogs with a plain-prompt fallback ────────────────────────
ui_clear() { if (( USE_WT )); then printf '\033[H\033[2J' >&2; fi; return 0; }

ui_init() {
  USE_WT=0
  if (( INTERACTIVE )) && [[ $SRV_PLAIN != 1 ]] && command -v whiptail >/dev/null 2>&1; then USE_WT=1; fi
}

ui_msg() {
  if (( ! INTERACTIVE )); then printf '%s\n' "$2" >&2; return 0; fi
  if (( USE_WT )); then whiptail --title "$1" --msgbox "$2" 20 78 || true
  else printf '\n%s%s%s\n%s\n' "$C_BOLD" "$1" "$C_0" "$2" >&2; fi
}

# ui_yesno "question" [yes|no]  → 0 = yes
ui_yesno() {
  local text=$1 def=${2:-yes} ans hint
  if (( ! INTERACTIVE || ASSUME_YES )); then
    if [[ $def == yes ]]; then return 0; else return 1; fi
  fi
  if (( USE_WT )); then
    local -a args=(--title "Confirm" --yesno "$text" 18 78)
    if [[ $def == no ]]; then args+=(--defaultno); fi
    whiptail "${args[@]}" 3>&1 1>&2 2>&3
    return
  fi
  hint="[Y/n]"; if [[ $def == no ]]; then hint="[y/N]"; fi
  while true; do
    read -r -p "$text $hint " ans </dev/tty || return 1
    ans=${ans,,}
    if [[ -z $ans ]]; then ans=${def:0:1}; fi
    case $ans in y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

# ui_input "prompt" [default] [empty]  → prints value ("empty" allows blank)
ui_input() {
  local prompt=$1 def=${2-} allow=${3-} val=""
  if (( ! INTERACTIVE || ASSUME_YES )); then
    if [[ -n $def || $allow == empty ]]; then printf '%s' "$def"; return 0; fi
    if (( ! INTERACTIVE )); then return 1; fi
  fi
  if (( USE_WT )); then
    val=$(whiptail --title "srv" --inputbox "$prompt" 11 78 "$def" 3>&1 1>&2 2>&3) || return 1
  else
    read -r -p "$prompt${def:+ [$def]}: " val </dev/tty || return 1
    if [[ -z $val ]]; then val=$def; fi
  fi
  if [[ -z $val && $allow != empty ]]; then return 1; fi
  printf '%s' "$val"
}

ui_password() {
  local p1 p2
  (( INTERACTIVE )) || return 1
  while true; do
    if (( USE_WT )); then
      p1=$(whiptail --title "srv" --passwordbox "$1" 10 78 3>&1 1>&2 2>&3) || return 1
      p2=$(whiptail --title "srv" --passwordbox "Repeat the password" 10 78 3>&1 1>&2 2>&3) || return 1
    else
      read -r -s -p "$1: " p1 </dev/tty || return 1; echo >&2
      read -r -s -p "Repeat: " p2 </dev/tty || return 1; echo >&2
    fi
    if [[ -n $p1 && $p1 == "$p2" ]]; then printf '%s' "$p1"; return 0; fi
    warn "Passwords are empty or don't match — try again."
  done
}

# ui_menu "title" "text" tag desc [tag desc ...]  → prints chosen tag
ui_menu() {
  local title=$1 text=$2; shift 2
  if (( ! INTERACTIVE )); then printf '%s' "$1"; return 0; fi
  if (( USE_WT )); then
    local h=$(( $# / 2 )); if (( h > 13 )); then h=13; fi
    whiptail --title "$title" --menu "$text" $(( h + 9 )) 78 "$h" "$@" 3>&1 1>&2 2>&3 || return 1
    return 0
  fi
  local -a tags=(); local i=1 n
  printf '\n%s%s%s — %s\n' "$C_BOLD" "$title" "$C_0" "$text" >&2
  while (( $# >= 2 )); do
    tags+=("$1"); printf '  %2d) %-12s %s\n' "$i" "$1" "$2" >&2
    shift 2; i=$(( i + 1 ))
  done
  while true; do
    read -r -p "Select [1-${#tags[@]}] (q = back): " n </dev/tty || return 1
    case $n in q|Q|"") return 1 ;; esac
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#tags[@]} )); then printf '%s' "${tags[n-1]}"; return 0; fi
    warn "Invalid choice"
  done
}

# ui_checklist "title" "text" tag desc ON|OFF ...  → prints chosen tags, one per line
ui_checklist() {
  local title=$1 text=$2; shift 2
  if (( ! INTERACTIVE || ASSUME_YES )); then
    while (( $# >= 3 )); do
      if [[ $3 == ON ]]; then printf '%s\n' "$1"; fi
      shift 3
    done
    return 0
  fi
  if (( USE_WT )); then
    local h=$(( $# / 3 )); if (( h > 15 )); then h=15; fi
    whiptail --title "$title" --separate-output --checklist "$text" $(( h + 9 )) 78 "$h" "$@" 3>&1 1>&2 2>&3 || return 1
    return 0
  fi
  printf '\n%s%s%s — %s\n' "$C_BOLD" "$title" "$C_0" "$text" >&2
  local def
  while (( $# >= 3 )); do
    def=no; if [[ $3 == ON ]]; then def=yes; fi
    if ui_yesno "  • $1 — $2?" "$def"; then printf '%s\n' "$1"; fi
    shift 3
  done
}

pause() { if (( INTERACTIVE )); then read -r -p $'\nPress Enter to continue…' </dev/tty || true; fi; }

# Called inside validation loops: re-prompt when interactive, otherwise fail.
retry_or_die() { if (( ! INTERACTIVE || ASSUME_YES )); then die "$1"; fi; }

# ── Small helpers ────────────────────────────────────────────────────────────
need_root() { [[ $EUID -eq 0 ]] || die "Run as root:  sudo srv ${*:-}"; }
need_val()  { [[ $# -ge 2 ]] || die "Option $1 needs a value."; }
in_list()   { local n=$1 x; shift; for x in "$@"; do if [[ $x == "$n" ]]; then return 0; fi; done; return 1; }
mem_mb()    { awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo; }
ver_ge()    { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1) == "$2" ]]; }
yn()        { if "$@"; then echo yes; else echo no; fi; }

gen_password() {
  local p
  p=$(openssl rand -base64 48 2>/dev/null) || p=$(head -c 48 /dev/urandom | base64)
  p=${p//[^A-Za-z0-9]/}
  printf '%s' "${p:0:${1:-24}}"
}

valid_domain()   { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; }
valid_db_ident() { [[ $1 =~ ^[A-Za-z0-9_]{1,63}$ ]]; }
valid_port()     { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 )); }
# Leading zeros would make bash read numbers as octal ("08" is an error) — normalize typed numbers
dec()            { if [[ $1 =~ ^[0-9]{1,9}$ ]]; then printf '%d' "$(( 10#$1 ))"; else printf '%s' "$1"; fi; }
valid_relpath()  { [[ $1 != *..* && $1 =~ ^[A-Za-z0-9._/-]*$ ]]; }

pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == "install ok installed" ]]; }
pkg_available() {
  local c
  c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}') || true
  [[ -n $c && $c != "(none)" ]]
}

php_versions() {
  local b
  for b in /usr/sbin/php-fpm[0-9]*; do
    if [[ -x $b ]]; then printf '%s\n' "${b#/usr/sbin/php-fpm}"; fi
  done | sort -V
}

nginx_version() { nginx -v 2>&1 | sed -n 's|^.*nginx/\([0-9.]*\).*$|\1|p'; }

ssh_port() {
  local p
  p=$(sshd -T 2>/dev/null | awk '$1=="port" && !s {print $2; s=1}') || true
  printf '%s' "${p:-22}"
}

ssh_keys_present() {
  local f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    if [[ -s $f ]]; then return 0; fi
  done
  return 1
}

svc_state() { systemctl is-active "$1" 2>/dev/null || true; }

cert_days_left() {
  local f="/etc/letsencrypt/live/$1/fullchain.pem" end
  [[ -f $f ]] || return 1
  end=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2) || return 1
  printf '%s' $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

port_in_use()       { [[ -n $(ss -Hltn "sport = :$1" 2>/dev/null) ]]; }
port_used_by_site() { grep -qsE "^(PORT|REVERB_PORT)=$1\$" "$SRV_SITES"/*.conf; }
port_alloc() {
  local p; p=$(cfg_get APP_PORT_START 3001)
  while port_used_by_site "$p" || port_in_use "$p"; do
    p=$(( p + 1 ))
    if (( p > 65000 )); then return 1; fi
  done
  printf '%s' "$p"
}

user_rss_mb() { { ps -u "$1" -o rss= 2>/dev/null || true; } | awk '{s+=$1} END {printf "%d", s/1024}'; }

# ── Core setup ───────────────────────────────────────────────────────────────
detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot detect the OS (/etc/os-release missing)."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-}; OS_VER=${VERSION_ID:-0}; OS_CODENAME=${VERSION_CODENAME:-}; OS_NAME=${PRETTY_NAME:-$OS_ID}
  local major=${OS_VER%%.*}
  [[ $major =~ ^[0-9]+$ ]] || major=0
  case $OS_ID in
    ubuntu) (( major >= 22 )) || die "Ubuntu 22.04 or newer is required (found $OS_NAME)." ;;
    debian) (( major >= 12 )) || die "Debian 12 or newer is required (found $OS_NAME)." ;;
    *) die "Unsupported OS: $OS_NAME. Supported: Ubuntu 22.04+, Debian 12+." ;;
  esac
}

init_dirs() {
  install -d -m 700 "$SRV_DIR" "$SRV_SITES"
  touch "$SRV_STATE" "$SRV_CFG" "$SRV_LOG"
  chmod 600 "$SRV_STATE" "$SRV_CFG" "$SRV_LOG"
  TMP_DIR=$(mktemp -d /tmp/srv.XXXXXX)
}

acquire_lock() {   # [seconds to wait]
  exec 9>/run/srv.lock
  if [[ -n ${1:-} ]]; then flock -w "$1" 9 || die "Timed out waiting for another srv process to finish."
  else flock -n 9 || die "Another srv process is running. Try again when it finishes."; fi
}

# Copy this script to /usr/local/bin/srv (also updates an older copy).
self_install() {
  local src
  src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || src=""
  if [[ $src == "$SRV_BIN" ]]; then return 0; fi
  if [[ -f $src ]]; then
    if [[ -f $SRV_BIN ]] && cmp -s "$src" "$SRV_BIN"; then return 0; fi
    local verb=Installed; if [[ -f $SRV_BIN ]]; then verb=Updated; fi
    install -m 0755 "$src" "$SRV_BIN"
    ok "$verb the 'srv' command ($SRV_BIN, version $SRV_VERSION)"
  else
    warn "Couldn't self-install (not run from a file). Copy the script to $SRV_BIN manually."
  fi
}

ensure_whiptail() {
  if (( INTERACTIVE )) && [[ $SRV_PLAIN != 1 ]] && ! command -v whiptail >/dev/null 2>&1; then
    info "Installing whiptail for menus"
    apt_install whiptail || true
    ui_init
  fi
}

# ── APT ──────────────────────────────────────────────────────────────────────
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

apt_update() {
  if [[ -z ${1:-} && -f $TMP_DIR/apt-updated ]]; then return 0; fi
  info "Refreshing package lists"
  run apt-get "${APT_OPTS[@]}" -q update || return 1
  touch "$TMP_DIR/apt-updated"
}

apt_install() {
  apt_update || return 1
  info "Installing: $*"
  run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "${APT_OPTS[@]}" -y -q install "$@"
}

# =============================================================================
#  FEATURES — each has an optional ask_<name> (questions) and a mod_<name>
#  (installation). Setup asks everything first, then installs unattended.
# =============================================================================
feat_desc() {
  case $1 in
    upgrade)      echo "Upgrade all system packages" ;;
    timezone)     echo "Set the server timezone" ;;
    hostname)     echo "Set the server hostname" ;;
    swap)         echo "Create a swap file" ;;
    sudo-user)    echo "Create an admin user with sudo" ;;
    ssh)          echo "Harden SSH (root login, passwords, port)" ;;
    firewall)     echo "UFW firewall (SSH, HTTP, HTTPS)" ;;
    fail2ban)     echo "fail2ban brute-force protection" ;;
    auto-updates) echo "Automatic security updates" ;;
    nginx)        echo "Nginx web server" ;;
    php)          echo "PHP-FPM (choose version)" ;;
    composer)     echo "Composer (PHP dependency manager)" ;;
    database)     echo "MariaDB or MySQL server" ;;
    postgres)     echo "PostgreSQL server (choose version)" ;;
    redis)        echo "Redis — cache, sessions, queues" ;;
    node)         echo "Node.js (choose version) + npm, pnpm, yarn" ;;
    python)       echo "Python 3 + venv for gunicorn / uvicorn apps" ;;
    supervisor)   echo "Supervisor — Laravel queues, Horizon, Reverb, apps" ;;
    pm2)          echo "PM2 process manager for apps (needs Node.js)" ;;
    certbot)      echo "Certbot — free Let's Encrypt SSL" ;;
    backup)       echo "Daily backups — databases + site files, with rotation" ;;
    rclone)       echo "rclone — copy backups to S3, R2, B2, Google Drive …" ;;
    webhook)      echo "Deploy webhook receiver (auto-deploy on git push)" ;;
    dbadmin)      echo "Adminer / phpMyAdmin behind a secret URL + password" ;;
    *)            echo "$1" ;;
  esac
}

feat_default() {
  case $1 in
    hostname|sudo-user|postgres|redis|node|python|supervisor|pm2|rclone|webhook|dbadmin) echo OFF ;;
    swap) if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then echo OFF; else echo ON; fi ;;
    *) echo ON ;;
  esac
}

# ── base (always installed first) ────────────────────────────────────────────
mod_base() {
  step "Installing base packages"
  apt_install ca-certificates curl wget gnupg git unzip zip rsync acl cron logrotate \
              openssl sudo htop whiptail xz-utils
  cat >/etc/logrotate.d/srv <<'EOF'
/var/log/srv.log /var/log/srv-backup.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    create 0600 root root
}
EOF
  feat_set base
  ok "Base packages installed"
}

# ── upgrade ──────────────────────────────────────────────────────────────────
mod_upgrade() {
  step "Upgrading system packages (this can take a few minutes)"
  apt_update force
  run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "${APT_OPTS[@]}" -y -q upgrade
  feat_set upgrade "$(date '+%F')"
  ok "System packages upgraded"
}

# ── timezone ─────────────────────────────────────────────────────────────────
ask_timezone() {
  local cur tz
  cur=$(timedatectl show -p Timezone --value 2>/dev/null) || cur=""
  cur=${cur:-UTC}
  while true; do
    tz=$(ui_input "Timezone (e.g. Asia/Dhaka, UTC, Europe/London)" "$cur") || die "Cancelled."
    if [[ -f /usr/share/zoneinfo/$tz && $tz != *..* ]]; then break; fi
    warn "Unknown timezone: $tz"; retry_or_die "Unknown timezone: $tz"
  done
  OPT_TZ=$tz
}
mod_timezone() {
  local tz=${OPT_TZ:-UTC}
  step "Setting timezone to $tz"
  run timedatectl set-timezone "$tz"
  feat_set timezone "$tz"
  ok "Timezone: $tz"
}

# ── hostname ─────────────────────────────────────────────────────────────────
ask_hostname() {
  local h
  while true; do
    h=$(ui_input "Server hostname (e.g. web1 or web1.example.com)" "$(hostname)") || die "Cancelled."
    if [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then break; fi
    warn "Invalid hostname: $h"; retry_or_die "Invalid hostname: $h"
  done
  OPT_HOSTNAME=$h
}
mod_hostname() {
  local h=${OPT_HOSTNAME:-$(hostname)} short
  short=${h%%.*}
  step "Setting hostname to $h"
  run hostnamectl set-hostname "$h"
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$h $short/" /etc/hosts
  else
    printf '127.0.1.1\t%s %s\n' "$h" "$short" >>/etc/hosts
  fi
  # Stop cloud-init from resetting the hostname on reboot
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then echo "preserve_hostname: true" >/etc/cloud/cloud.cfg.d/99-srv-hostname.cfg; fi
  feat_set hostname "$h"
  ok "Hostname: $h"
}

# ── swap ─────────────────────────────────────────────────────────────────────
ask_swap() {
  if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then OPT_SWAP=existing; return 0; fi
  local def=2G s
  if (( $(mem_mb) > 4096 )); then def=4G; fi
  while true; do
    s=$(ui_input "Swap file size (e.g. 1G, 2G, 4G)" "$def") || die "Cancelled."
    if [[ $s =~ ^[0-9]+[MmGg]$ ]]; then break; fi
    warn "Use a size like 2G or 512M"; retry_or_die "Invalid swap size: $s"
  done
  OPT_SWAP=${s^^}
}
mod_swap() {
  if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then
    ok "Swap is already active — skipped"; feat_set swap existing; return 0
  fi
  local size=${OPT_SWAP:-2G} mb
  if [[ $size == existing ]]; then size=2G; fi
  case ${size: -1} in G) mb=$(( 10#${size%?} * 1024 )) ;; *) mb=$(( 10#${size%?} )) ;; esac
  step "Creating a $size swap file"
  if ! fallocate -l "${mb}M" /swapfile 2>>"$SRV_LOG"; then
    run dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none
  fi
  chmod 600 /swapfile
  run mkswap /swapfile
  if ! swapon /swapfile 2>>"$SRV_LOG"; then
    rm -f /swapfile
    err "Could not enable swap (containers such as LXC/OpenVZ don't allow it)."
    return 1
  fi
  if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then echo '/swapfile none swap sw 0 0' >>/etc/fstab; fi
  printf 'vm.swappiness=10\nvm.vfs_cache_pressure=50\n' >/etc/sysctl.d/99-srv-swap.conf
  run sysctl -p /etc/sysctl.d/99-srv-swap.conf
  feat_set swap "$size"
  ok "Swap enabled ($size)"
}

# ── sudo-user ────────────────────────────────────────────────────────────────
ask_sudo_user() {
  local u
  while true; do
    u=$(ui_input "Admin username to create (gets sudo rights)" "admin") || die "Cancelled."
    if [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ && $u != root ]]; then break; fi
    warn "Use lowercase letters, digits, - and _ (max 32 chars)"; retry_or_die "Invalid username: $u"
  done
  OPT_USER=$u
  OPT_USER_KEYS=no
  if [[ -s /root/.ssh/authorized_keys ]] && ui_yesno "Copy root's SSH keys (authorized_keys) to $u?" yes; then
    OPT_USER_KEYS=yes
  fi
  OPT_USER_PASS=""
  if (( INTERACTIVE )) && ui_yesno "Set a password for $u? (needed to use sudo)" yes; then
    OPT_USER_PASS=$(ui_password "Password for $u") || die "Cancelled."
  fi
}
mod_sudo_user() {
  local u=${OPT_USER:-}
  [[ -n $u ]] || { err "No username given"; return 1; }
  step "Creating admin user $u"
  if id "$u" &>/dev/null; then info "User $u already exists — adding to the sudo group"
  else run useradd -m -s /bin/bash "$u"; fi
  run usermod -aG sudo "$u"
  if [[ -n $OPT_USER_PASS ]]; then
    printf '%s:%s\n' "$u" "$OPT_USER_PASS" | chpasswd || { err "Failed to set the password"; return 1; }
  fi
  if [[ $OPT_USER_KEYS == yes ]]; then
    local h g
    h=$(getent passwd "$u" | cut -d: -f6); g=$(id -gn "$u")
    install -d -m 700 -o "$u" -g "$g" "$h/.ssh"
    cat /root/.ssh/authorized_keys >>"$h/.ssh/authorized_keys"
    sort -u -o "$h/.ssh/authorized_keys" "$h/.ssh/authorized_keys"
    chown "$u:$g" "$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"
  fi
  feat_set sudo-user "$u"
  ok "Admin user $u ready"
}

# ── ssh ──────────────────────────────────────────────────────────────────────
ask_ssh() {
  local cur p
  cur=$(ssh_port)
  while true; do
    p=$(ui_input "SSH port (keep $cur unless you have a reason to change it)" "$cur") || die "Cancelled."; p=$(dec "$p")
    if [[ $p =~ ^[0-9]+$ ]] && (( p > 0 && p < 65536 )); then break; fi
    warn "Enter a port between 1 and 65535"; retry_or_die "Invalid port: $p"
  done
  OPT_SSH_PORT=$p
  OPT_ROOT_LOGIN=$(ui_menu "SSH" "Root login over SSH:" \
    prohibit-password "Keys only (recommended)" \
    no                "Disable root login completely" \
    yes               "Allow with password (not recommended)") || die "Cancelled."
  if [[ $OPT_ROOT_LOGIN == no ]]; then
    local sudoers
    sudoers=$(getent group sudo | cut -d: -f4)
    if [[ -z $sudoers && -z $OPT_USER ]]; then
      warn "No sudo user exists — disabling root login would lock you out."
      warn "Using 'prohibit-password' (key-only root login) instead."
      OPT_ROOT_LOGIN=prohibit-password
    fi
  fi
  OPT_SSH_NOPASS=no
  if ssh_keys_present || [[ $OPT_USER_KEYS == yes ]]; then
    if ui_yesno "Disable SSH password login (keys only)? Make sure your key login works first." yes; then
      OPT_SSH_NOPASS=yes
    fi
  else
    warn "No SSH keys found on this server — password login will stay enabled."
  fi
}

ssh_restart() {
  if [[ $(systemctl is-enabled ssh.socket 2>/dev/null || true) == enabled ]]; then
    # Socket-activated sshd (Ubuntu 23.04+): the port comes from a systemd generator
    run systemctl daemon-reload
    if ! systemctl restart ssh.socket >>"$SRV_LOG" 2>&1; then
      systemctl stop ssh.service >>"$SRV_LOG" 2>&1 || true
      run systemctl restart ssh.socket || return 1
    fi
    if systemctl is-active --quiet ssh.service; then run systemctl restart ssh.service || true; fi
  else
    run systemctl restart ssh
  fi
}

mod_ssh() {
  local conf=/etc/ssh/sshd_config.d/00-srv.conf port=${OPT_SSH_PORT:-$(ssh_port)} bak=""
  step "Hardening SSH"
  mkdir -p /etc/ssh/sshd_config.d
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
  if [[ -f $conf ]]; then bak="$TMP_DIR/00-srv.conf.bak"; cp -a "$conf" "$bak"; fi
  # 00- prefix: sshd uses the first value it reads, so this beats cloud-init's 50- file
  {
    echo "# Managed by srv"
    echo "Port $port"
    echo "PermitRootLogin ${OPT_ROOT_LOGIN:-prohibit-password}"
    echo "PubkeyAuthentication yes"
    if [[ $OPT_SSH_NOPASS == yes ]]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
    fi
    echo "X11Forwarding no"
    echo "MaxAuthTries 4"
    echo "LoginGraceTime 30"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
  } >"$conf"
  if ! sshd -t >>"$SRV_LOG" 2>&1; then
    if [[ -n $bak ]]; then cp -a "$bak" "$conf"; else rm -f "$conf"; fi
    err "sshd rejected the new config — reverted"; return 1
  fi
  if command -v ufw >/dev/null 2>&1 && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
    run ufw allow "$port/tcp" comment 'SSH'
  fi
  ssh_restart || true
  sleep 1
  if ! port_in_use "$port"; then
    err "SSH is not listening on port $port — reverting"
    if [[ -n $bak ]]; then cp -a "$bak" "$conf"; else rm -f "$conf"; fi
    ssh_restart || true
    return 1
  fi
  cfg_set SSH_PORT "$port"
  if feat_has fail2ban; then fail2ban_write_jail; run systemctl restart fail2ban || true; fi
  feat_set ssh "port $port, root ${OPT_ROOT_LOGIN:-prohibit-password}, passwords $([[ $OPT_SSH_NOPASS == yes ]] && echo off || echo on)"
  ok "SSH hardened (port $port)"
  warn "Keep this session open and test a NEW SSH login (port $port) before logging out."
}

# ── firewall ─────────────────────────────────────────────────────────────────
mod_firewall() {
  step "Configuring the UFW firewall"
  apt_install ufw
  local p; p=$(ssh_port)
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow "$p/tcp" comment 'SSH'
  run ufw allow 80/tcp comment 'HTTP'
  run ufw allow 443/tcp comment 'HTTPS'
  run ufw --force enable
  feat_set firewall "allow ssh:$p 80 443"
  ok "Firewall active — open ports: $p (SSH), 80, 443"
}

# ── fail2ban ─────────────────────────────────────────────────────────────────
fail2ban_write_jail() {
  cat >/etc/fail2ban/jail.d/srv.local <<EOF
# Managed by srv
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = $(ssh_port)
backend = systemd
EOF
}
mod_fail2ban() {
  step "Installing fail2ban"
  apt_install fail2ban python3-systemd
  fail2ban_write_jail
  run systemctl enable fail2ban
  run systemctl restart fail2ban
  feat_set fail2ban "sshd jail"
  ok "fail2ban protecting SSH"
}

# ── auto-updates ─────────────────────────────────────────────────────────────
mod_auto_updates() {
  step "Enabling automatic security updates"
  apt_install unattended-upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  feat_set auto-updates "security"
  ok "Automatic security updates enabled"
}

# ── nginx ────────────────────────────────────────────────────────────────────
nginx_write_global() {
  local f=/etc/nginx/conf.d/00-srv.conf main=/etc/nginx/nginx.conf line d
  local -a lines=(
    "server_tokens off;"
    "client_max_body_size 64m;"
    "server_names_hash_bucket_size 128;"
    "gzip_vary on;"
    "gzip_proxied any;"
    "gzip_comp_level 5;"
    "gzip_min_length 256;"
    "gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml application/rss+xml application/atom+xml application/manifest+json image/svg+xml font/ttf font/otf;"
  )
  {
    echo "# Managed by srv — global http{} tuning"
    for line in "${lines[@]}"; do
      d=${line%% *}
      # Skip directives already active in nginx.conf (duplicates are fatal)
      if grep -qE "^[[:space:]]*${d}[[:space:]]" "$main"; then echo "# $line  # already set in nginx.conf"
      else echo "$line"; fi
    done
  } >"$f"
}

nginx_write_snippets() {
  cat >/etc/nginx/snippets/srv-security.conf <<'EOF'
# Managed by srv
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# Block dotfiles (.env, .git …) except .well-known
location ~ /\.(?!well-known) {
    deny all;
}

# Block backups and dumps left in the web root
location ~* \.(?:sql|bak|old|orig|swp)$ {
    deny all;
}
EOF

  cat >/etc/nginx/snippets/srv-acme.conf <<EOF
# Managed by srv — Let's Encrypt HTTP-01 challenges
location ^~ /.well-known/acme-challenge/ {
    root $ACME_ROOT;
    default_type "text/plain";
    try_files \$uri =404;
}
EOF

  cat >/etc/nginx/snippets/srv-ssl.conf <<'EOF'
# Managed by srv — Mozilla "intermediate" TLS profile
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
ssl_session_timeout 1d;
ssl_session_cache shared:SrvSSL:10m;
ssl_session_tickets off;
EOF

  cat >/etc/nginx/snippets/srv-proxy.conf <<'EOF'
# Managed by srv — shared reverse-proxy settings (Host and Connection are set per site)
proxy_http_version 1.1;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;
proxy_connect_timeout 10s;
proxy_buffer_size 16k;
proxy_buffers 8 16k;
proxy_busy_buffers_size 32k;
proxy_hide_header X-Powered-By;
EOF
}

# Shared Nginx files used by site configs. Rewritten on every site change,
# so servers set up by an older srv pick up new snippets automatically.
nginx_sync_shared() {
  [[ -d /etc/nginx ]] || return 0
  install -d -m 755 "$ACME_ROOT" "$NGINX_CUSTOM" /etc/nginx/snippets /etc/nginx/conf.d
  nginx_write_snippets
  local maps=/etc/nginx/conf.d/01-srv-maps.conf
  if grep -rqsE --exclude=01-srv-maps.conf 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade' \
       /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled; then
    rm -f "$maps"   # already defined elsewhere — defining it twice is fatal
  else
    cat >"$maps" <<'EOF'
# Managed by srv — WebSocket upgrade helper
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
  fi
  install -d -m 755 "$SRV_WWW"
  if [[ ! -f $SRV_WWW/maintenance.html ]]; then
    cat >"$SRV_WWW/maintenance.html" <<'EOF'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Down for maintenance</title>
<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#f6f7f9;color:#222}
main{max-width:32rem;padding:2rem;text-align:center}h1{font-size:1.6rem}p{color:#555;line-height:1.5}</style></head>
<body><main><h1>We'll be right back</h1><p>This site is down for scheduled maintenance. Please check back in a few minutes.</p></main></body></html>
EOF
  fi
  # Site logs: PHP errors and app/worker output. copytruncate because the
  # process managers keep these files open.
  cat >/etc/logrotate.d/srv-sites <<'EOF'
/var/www/*/logs/*.log {
    su root root
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

# Catch-all for unknown hostnames / the bare IP: the connection is closed —
# except the database tools' secret path when they're served on the IP.
nginx_write_default() {
  {
    echo "# Managed by srv — catch-all for unknown hosts"
    echo "server {"
    echo "    listen 80 default_server;"
    if [[ -f /proc/net/if_inet6 ]]; then echo "    listen [::]:80 default_server;"; fi
    echo "    server_name _;"
    echo "    access_log off;"
    if [[ $(cfg_get TOOLS_HOST _) == _ && -f $TOOLS_CONF ]]; then
      echo "    include $TOOLS_CONF;"
      echo "    location / { return 444; }"
    else
      echo "    return 444;"
    fi
    echo "}"
  } >/etc/nginx/sites-available/000-srv-default.conf
  ln -sfn /etc/nginx/sites-available/000-srv-default.conf /etc/nginx/sites-enabled/000-srv-default.conf
}

mod_nginx() {
  step "Installing Nginx"
  apt_install nginx
  nginx_write_global
  nginx_sync_shared

  rm -f /etc/nginx/sites-enabled/default
  nginx_write_default

  if ! nginx -t >>"$SRV_LOG" 2>&1; then
    warn "Catch-all server conflicts with existing config — removing it"
    rm -f /etc/nginx/sites-enabled/000-srv-default.conf
    if ! nginx -t >>"$SRV_LOG" 2>&1; then err "Nginx config test failed: $(nginx -t 2>&1 | tail -n 2)"; return 1; fi
  fi
  run systemctl enable nginx
  run systemctl restart nginx
  feat_set nginx "$(nginx_version)"
  ok "Nginx $(nginx_version) running"
}

nginx_reload() {
  local out
  if ! out=$(nginx -t 2>&1); then
    err "Nginx config test failed — not reloading:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/     │ /' >&2
    return 1
  fi
  run systemctl reload nginx
}

# ── php ──────────────────────────────────────────────────────────────────────
ask_php() {
  if [[ -n $OPT_PHP ]]; then return 0; fi
  local -a items=(); local v
  for v in "${PHP_OFFERED[@]}"; do
    if [[ $v == "$PHP_DEFAULT" ]]; then items+=("$v" "PHP $v (recommended)"); else items+=("$v" "PHP $v"); fi
  done
  OPT_PHP=$(ui_menu "PHP" "Choose the PHP version to install (more can be added later):" "${items[@]}") || die "Cancelled."
}

php_repo_setup() {
  if grep -rqsE 'ondrej/php|packages\.sury\.org/php' /etc/apt/sources.list /etc/apt/sources.list.d/; then return 0; fi
  info "Adding the Ondřej Surý PHP repository"
  apt_install ca-certificates curl gnupg || return 1
  if [[ $OS_ID == ubuntu ]]; then
    local key="$TMP_DIR/ondrej-php.asc"
    run curl -fsSL -o "$key" "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x14AA40EC0831756756D7F66C4F4EA0AAE5267A6C" || return 1
    gpg --batch --yes --dearmor -o /usr/share/keyrings/srv-ondrej-php.gpg "$key" 2>>"$SRV_LOG" || { err "Could not import the PPA key"; return 1; }
    echo "deb [signed-by=/usr/share/keyrings/srv-ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu $OS_CODENAME main" \
      >/etc/apt/sources.list.d/srv-php.list
  else
    run curl -fsSL -o "$TMP_DIR/debsuryorg-archive-keyring.deb" https://packages.sury.org/debsuryorg-archive-keyring.deb || return 1
    run dpkg -i "$TMP_DIR/debsuryorg-archive-keyring.deb" || return 1
    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $OS_CODENAME main" \
      >/etc/apt/sources.list.d/srv-php.list
  fi
  if ! apt_update force; then
    rm -f /etc/apt/sources.list.d/srv-php.list
    warn "The PHP repository isn't available for $OS_CODENAME — using the distro's PHP packages."
    apt_update force || true
  fi
}

mod_php() {
  local v=${OPT_PHP:-$PHP_DEFAULT} ext tz
  step "Installing PHP $v"
  php_repo_setup || return 1
  if ! pkg_available "php$v-fpm"; then
    local avail
    avail=$(apt-cache search --names-only '^php[0-9.]+-fpm$' 2>/dev/null | awk '{print $1}' | sed 's/^php//; s/-fpm$//' | sort -V | tr '\n' ' ') || true
    err "PHP $v isn't available on $OS_NAME. Available: ${avail:-none}"
    return 1
  fi
  local -a pkgs=()
  for ext in fpm cli common mysql pgsql redis curl mbstring xml zip bcmath intl gd readline sqlite3 opcache; do
    if pkg_available "php$v-$ext"; then pkgs+=("php$v-$ext"); fi
  done
  apt_install "${pkgs[@]}"

  tz=$(timedatectl show -p Timezone --value 2>/dev/null) || tz=""
  tz=${tz:-UTC}
  cat >"/etc/php/$v/fpm/conf.d/99-srv.ini" <<EOF
; Managed by srv
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 60
max_input_vars = 3000
expose_php = Off
date.timezone = $tz

opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
EOF
  printf '; Managed by srv\ndate.timezone = %s\n' "$tz" >"/etc/php/$v/cli/conf.d/99-srv.ini"

  run systemctl enable "php$v-fpm"
  run systemctl restart "php$v-fpm"
  feat_set php "$(php_versions | tr '\n' ' ' | sed 's/ $//')"
  if [[ -z $(cfg_get PHP_DEFAULT) ]]; then cfg_set PHP_DEFAULT "$v"; fi
  ok "PHP $v installed (FPM running)"
}

# Install a PHP extension (redis, pgsql …) for every installed PHP version
php_ext_all() {
  local ext=$1 v
  for v in $(php_versions); do
    if ! pkg_installed "php$v-$ext" && pkg_available "php$v-$ext"; then
      apt_install "php$v-$ext" && run systemctl restart "php$v-fpm" || warn "Couldn't install php$v-$ext"
    fi
  done
}

# ── composer ─────────────────────────────────────────────────────────────────
mod_composer() {
  step "Installing Composer"
  command -v php >/dev/null 2>&1 || { err "PHP is required for Composer — run: srv install php"; return 1; }
  local inst="$TMP_DIR/composer-setup.php" sig act
  sig=$(curl -fsSL https://composer.github.io/installer.sig) || { err "Couldn't download the Composer signature"; return 1; }
  run curl -fsSL -o "$inst" https://getcomposer.org/installer
  act=$(php -r "echo hash_file('sha384', '$inst');")
  [[ $sig == "$act" ]] || { err "Composer installer checksum mismatch — aborting"; return 1; }
  run php "$inst" --quiet --install-dir=/usr/local/bin --filename=composer
  feat_set composer "$(COMPOSER_ALLOW_SUPERUSER=1 composer --version 2>/dev/null | awk '{print $3}')"
  ok "Composer $(feat_get composer) installed"
}

# ── database (MariaDB / MySQL) ───────────────────────────────────────────────
ask_database() {
  if [[ -n $OPT_DB_ENGINE ]]; then return 0; fi
  local -a items=(mariadb "MariaDB (recommended — MySQL compatible)")
  if [[ $OS_ID == ubuntu ]]; then items+=(mysql "MySQL (Ubuntu repository)"); fi
  OPT_DB_ENGINE=$(ui_menu "Database" "Choose the database server:" "${items[@]}") || die "Cancelled."
}

db_client()   { if command -v mariadb >/dev/null 2>&1; then echo mariadb; else echo mysql; fi; }
db_dump_bin() { command -v mariadb-dump 2>/dev/null || command -v mysqldump; }
db_run()      { "$(db_client)" --protocol=socket -u root -N -B; }       # SQL from stdin
db_sql()      { "$(db_client)" --protocol=socket -u root -N -B -e "$1"; } # non-secret SQL only
db_exists()      { [[ -n $(db_sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$1'" 2>/dev/null) ]]; }
db_user_exists() { [[ -n $(db_sql "SELECT User FROM mysql.user WHERE User='$1' AND Host='localhost'" 2>/dev/null) ]]; }
db_user_databases() {
  db_sql "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys') ORDER BY SCHEMA_NAME"
}

# db_create name user password — the password never appears in argv or the log
db_create() {
  local n=$1 u=$2 p=$3
  if ! valid_db_ident "$n" || ! valid_db_ident "$u" || (( ${#u} > 32 )); then err "Invalid database or user name"; return 1; fi
  log "SQL   create database $n, user $u"
  if ! db_run >>"$SRV_LOG" 2>&1 <<SQL
CREATE DATABASE IF NOT EXISTS \`$n\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$u'@'localhost' IDENTIFIED BY '$p';
GRANT ALL PRIVILEGES ON \`$n\`.* TO '$u'@'localhost';
FLUSH PRIVILEGES;
SQL
  then err "Failed to create database $n"; return 1; fi
}

mod_database() {
  local eng=${OPT_DB_ENGINE:-mariadb} svc cnf pool mb
  if [[ $eng == mysql && $OS_ID != ubuntu ]]; then warn "MySQL server isn't in Debian's repositories — using MariaDB."; eng=mariadb; fi
  if [[ $eng == mariadb ]] && pkg_installed mysql-server; then err "MySQL server is already installed — not installing MariaDB alongside it."; return 1; fi
  if [[ $eng == mysql ]] && pkg_installed mariadb-server; then err "MariaDB is already installed — not installing MySQL alongside it."; return 1; fi
  step "Installing $eng"
  if [[ $eng == mariadb ]]; then
    apt_install mariadb-server mariadb-client; svc=mariadb; cnf=/etc/mysql/mariadb.conf.d/99-srv.cnf
  else
    apt_install mysql-server mysql-client; svc=mysql; cnf=/etc/mysql/mysql.conf.d/99-srv.cnf
  fi
  mb=$(mem_mb); pool=$(( mb / 4 ))
  if (( pool < 128 )); then pool=128; fi
  if (( pool > 8192 )); then pool=8192; fi
  mkdir -p "$(dirname "$cnf")"
  cat >"$cnf" <<EOF
# Managed by srv
[mysqld]
bind-address            = 127.0.0.1
innodb_buffer_pool_size = ${pool}M
max_connections         = 150
EOF
  run systemctl enable "$svc"
  run systemctl restart "$svc"
  # Equivalent of mysql_secure_installation (root uses socket auth — no password needed as OS root)
  db_run >>"$SRV_LOG" 2>&1 <<'SQL' || warn "Some hardening statements failed (see log) — not critical."
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL
  cfg_set DB_ENGINE "$eng"
  feat_set database "$eng $(db_sql 'SELECT VERSION()' 2>/dev/null || true)"
  ok "$eng running (localhost only, buffer pool ${pool}M)"
}

# ── postgres ─────────────────────────────────────────────────────────────────
pg_port()  { cfg_get PG_PORT 5432; }
pg_psql()  { runuser -u postgres -- env -C / psql -X -q -v ON_ERROR_STOP=1 -p "$(pg_port)" "$@"; }
pg_sql()   { pg_psql -At -F $'\t' -d postgres -c "$1"; }   # non-secret SQL only
pg_run()   { pg_psql -d postgres; }                        # SQL from stdin
pg_exists()      { [[ $(pg_sql "SELECT 1 FROM pg_database WHERE datname='$1'" 2>/dev/null) == 1 ]]; }
pg_user_exists() { [[ $(pg_sql "SELECT 1 FROM pg_roles WHERE rolname='$1'" 2>/dev/null) == 1 ]]; }
pg_user_databases() { pg_sql "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1"; }

pg_create() {
  local n=$1 u=$2 p=$3
  if ! valid_db_ident "$n" || ! valid_db_ident "$u"; then err "Invalid database or user name"; return 1; fi
  log "SQL   create PostgreSQL database $n, role $u"
  if ! pg_run >>"$SRV_LOG" 2>&1 <<SQL
CREATE ROLE "$u" LOGIN PASSWORD '$p';
CREATE DATABASE "$n" OWNER "$u" ENCODING 'UTF8' TEMPLATE template0;
REVOKE ALL ON DATABASE "$n" FROM PUBLIC;
SQL
  then err "Failed to create PostgreSQL database $n"; return 1; fi
}

pg_available_versions() {
  { apt-cache search --names-only '^postgresql-[0-9]+$' 2>/dev/null || true; } | awk '{print $1}' | sed 's/^postgresql-//' | sort -n
}

ask_postgres() {
  if [[ -n $OPT_PG ]]; then return 0; fi
  OPT_PG=$(ui_menu "PostgreSQL" "Choose the PostgreSQL version:" \
    latest "Newest available (recommended)" \
    18     "PostgreSQL 18" \
    17     "PostgreSQL 17" \
    16     "PostgreSQL 16") || die "Cancelled."
}

pg_repo_setup() {
  if grep -rqs 'apt.postgresql.org' /etc/apt/sources.list /etc/apt/sources.list.d/; then return 0; fi
  info "Adding the official PostgreSQL (PGDG) repository"
  apt_install ca-certificates curl || return 1
  install -d -m 755 /usr/share/postgresql-common/pgdg
  run curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc || return 1
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $OS_CODENAME-pgdg main" \
    >/etc/apt/sources.list.d/srv-pgdg.list
  if ! apt_update force; then
    rm -f /etc/apt/sources.list.d/srv-pgdg.list
    warn "The PGDG repository isn't available for $OS_CODENAME — using the distro's PostgreSQL."
    apt_update force || true
  fi
}

mod_postgres() {
  step "Installing PostgreSQL"
  pg_repo_setup || return 1
  local v=${OPT_PG:-latest} existing mb sb ec dir port i
  if [[ $v == latest ]]; then v=$(pg_available_versions | tail -n 1); fi
  [[ -n $v ]] || { err "No PostgreSQL packages found"; return 1; }
  existing=$({ pg_lsclusters -h 2>/dev/null || true; } | awk '{print $1}' | sort -u | tr '\n' ' ')
  existing=${existing% }
  if [[ -n $existing && $existing != "$v" ]]; then
    err "PostgreSQL $existing is already installed. srv manages a single PostgreSQL version."
    return 1
  fi
  if ! pkg_available "postgresql-$v"; then
    err "PostgreSQL $v isn't available. Available: $(pg_available_versions | tr '\n' ' ')"
    return 1
  fi
  apt_install "postgresql-$v" "postgresql-client-$v"

  dir="/etc/postgresql/$v/main"
  [[ -d $dir ]] || { err "Cluster config $dir not found"; return 1; }
  mb=$(mem_mb)
  sb=$(( mb / 4 )); if (( sb < 128 )); then sb=128; fi; if (( sb > 8192 )); then sb=8192; fi
  ec=$(( mb / 2 )); if (( ec < 256 )); then ec=256; fi
  install -d -o postgres -g postgres "$dir/conf.d"
  if ! grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf\.d'" "$dir/postgresql.conf"; then
    echo "include_dir = 'conf.d'" >>"$dir/postgresql.conf"
  fi
  cat >"$dir/conf.d/99-srv.conf" <<EOF
# Managed by srv
listen_addresses = 'localhost'
password_encryption = scram-sha-256
max_connections = 100
shared_buffers = ${sb}MB
effective_cache_size = ${ec}MB
EOF
  if [[ ! -f $dir/pg_hba.conf.srv-orig ]]; then cp -a "$dir/pg_hba.conf" "$dir/pg_hba.conf.srv-orig"; fi
  cat >"$dir/pg_hba.conf" <<'EOF'
# Managed by srv — local connections only (original saved as pg_hba.conf.srv-orig)
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
EOF
  chown postgres:postgres "$dir/pg_hba.conf" "$dir/conf.d/99-srv.conf"
  chmod 640 "$dir/pg_hba.conf"

  run systemctl enable postgresql
  run systemctl restart "postgresql@$v-main" || run systemctl restart postgresql || return 1
  port=$({ pg_lsclusters -h 2>/dev/null || true; } | awk -v v="$v" '$1==v && $2=="main" {print $3}')
  cfg_set PG_PORT "${port:-5432}"
  cfg_set PG_VERSION "$v"
  for (( i = 0; i < 20; i++ )); do
    if runuser -u postgres -- pg_isready -q -p "$(pg_port)" 2>/dev/null; then break; fi
    sleep 1
  done
  pg_sql "SELECT 1" >/dev/null 2>>"$SRV_LOG" || { err "PostgreSQL isn't accepting connections — see $SRV_LOG"; return 1; }
  php_ext_all pgsql
  feat_set postgres "PostgreSQL $v (port $(pg_port))"
  ok "PostgreSQL $v running (localhost only, shared_buffers ${sb}MB)"
}

# ── Engine-agnostic database helpers (mysql = MySQL/MariaDB, pgsql = PostgreSQL)
norm_engine() {
  case ${1,,} in
    mysql|mariadb) echo mysql ;;
    pgsql|pg|postgres|postgresql) echo pgsql ;;
    *) return 1 ;;
  esac
}
eng_installed()    { if [[ $1 == pgsql ]]; then feat_has postgres; else feat_has database; fi; }
eng_label()        { if [[ $1 == pgsql ]]; then echo PostgreSQL; else echo "MySQL/MariaDB"; fi; }
eng_port()         { if [[ $1 == pgsql ]]; then pg_port; else echo 3306; fi; }
eng_exists()       { if [[ $1 == pgsql ]]; then pg_exists "$2"; else db_exists "$2"; fi; }
eng_user_exists()  { if [[ $1 == pgsql ]]; then pg_user_exists "$2"; else db_user_exists "$2"; fi; }
eng_create()       { if [[ $1 == pgsql ]]; then pg_create "$2" "$3" "$4"; else db_create "$2" "$3" "$4"; fi; }
eng_databases()    { if [[ $1 == pgsql ]]; then pg_user_databases; else db_user_databases; fi; }
eng_drop_db() {
  if [[ $1 == pgsql ]]; then printf 'DROP DATABASE IF EXISTS "%s" WITH (FORCE);\n' "$2" | pg_run >>"$SRV_LOG" 2>&1
  else printf 'DROP DATABASE IF EXISTS `%s`;\n' "$2" | db_run >>"$SRV_LOG" 2>&1; fi
}
eng_drop_user() {
  if [[ $1 == pgsql ]]; then printf 'DROP ROLE IF EXISTS "%s";\n' "$2" | pg_run >>"$SRV_LOG" 2>&1
  else printf "DROP USER IF EXISTS '%s'@'localhost';\n" "$2" | db_run >>"$SRV_LOG" 2>&1; fi
}
eng_set_password() {
  local e=$1 u=$2 p=$3
  if [[ $e == pgsql ]]; then
    pg_run >>"$SRV_LOG" 2>&1 <<SQL
ALTER ROLE "$u" PASSWORD '$p';
SQL
  else
    db_run >>"$SRV_LOG" 2>&1 <<SQL
ALTER USER '$u'@'localhost' IDENTIFIED BY '$p';
FLUSH PRIVILEGES;
SQL
  fi
}
db_engines() {
  if feat_has database; then echo mysql; fi
  if feat_has postgres; then echo pgsql; fi
  return 0
}

# db_pick_engine [requested] [install] → sets DB_ENG
db_pick_engine() {
  local req=${1:-} mode=${2:-}
  local -a e=()
  if [[ -n $req ]]; then
    req=$(norm_engine "$req") || die "Unknown database engine: $1 (use mysql or pgsql)"
    if [[ $req == pgsql ]]; then ensure_feature postgres; else ensure_feature database; fi
    DB_ENG=$req; return 0
  fi
  mapfile -t e < <(db_engines)
  case ${#e[@]} in
    0)
      if (( INTERACTIVE )) && [[ $mode == install ]]; then
        req=$(ui_menu "Database" "No database server is installed yet. Install:" \
          mysql "MariaDB / MySQL" pgsql "PostgreSQL") || die "Cancelled."
        db_pick_engine "$req"; return 0
      fi
      die "No database server installed. Run: srv install database   (or: srv install postgres)" ;;
    1) DB_ENG=${e[0]} ;;
    *)
      if (( ! INTERACTIVE )); then die "Both MySQL/MariaDB and PostgreSQL are installed — add --mysql or --pg."; fi
      DB_ENG=$(ui_menu "Database engine" "Which database server?" mysql "MySQL / MariaDB" pgsql "PostgreSQL") || die "Cancelled." ;;
  esac
}

# ── redis ────────────────────────────────────────────────────────────────────
ask_redis() {
  if [[ -n $OPT_REDIS_POLICY ]]; then return 0; fi
  OPT_REDIS_POLICY=$(ui_menu "Redis" "When Redis memory is full:" \
    volatile-lru "Evict cache keys (with a TTL), keep queues (recommended)" \
    allkeys-lru  "Evict any key — Redis is only a cache" \
    noeviction   "Never evict — reject writes (queues/data only)") || die "Cancelled."
}
mod_redis() {
  step "Installing Redis"
  apt_install redis-server redis-tools
  local pass mem policy=${OPT_REDIS_POLICY:-volatile-lru} f=/etc/redis/srv.conf main=/etc/redis/redis.conf i
  pass=$(cfg_get REDIS_PASSWORD); if [[ -z $pass ]]; then pass=$(gen_password 32); fi
  mem=$(( $(mem_mb) / 8 )); if (( mem < 64 )); then mem=64; fi; if (( mem > 4096 )); then mem=4096; fi
  cat >"$f" <<EOF
# Managed by srv — included at the end of $main (later values win)
bind 127.0.0.1
protected-mode yes
port 6379
requirepass $pass
maxmemory ${mem}mb
maxmemory-policy $policy
EOF
  chown redis:redis "$f"; chmod 640 "$f"
  if ! grep -qxF "include $f" "$main"; then printf '\ninclude %s\n' "$f" >>"$main"; fi
  cfg_set REDIS_PASSWORD "$pass"
  run systemctl enable redis-server
  run systemctl restart redis-server
  for (( i = 0; i < 10; i++ )); do
    if [[ $(REDISCLI_AUTH=$pass redis-cli -h 127.0.0.1 ping 2>/dev/null) == PONG ]]; then break; fi
    sleep 1
  done
  [[ $(REDISCLI_AUTH=$pass redis-cli -h 127.0.0.1 ping 2>/dev/null) == PONG ]] || { err "Redis isn't answering — see $SRV_LOG"; return 1; }
  php_ext_all redis
  feat_set redis "$(redis-server --version | sed -n 's/.*v=\([0-9.]*\).*/\1/p'), ${mem}mb, $policy"
  ok "Redis running on 127.0.0.1:6379 (password protected, ${mem}MB, $policy)"
}

# ── node ─────────────────────────────────────────────────────────────────────
# Official Node.js builds (checksum-verified) in /opt/srv/node/versions/<vX.Y.Z>,
# with a stable /opt/srv/node/<major> link that sites and services point at.
ask_node() {
  if [[ -n $OPT_NODE ]]; then return 0; fi
  OPT_NODE=$(ui_menu "Node.js" "Choose the Node.js version to install (more can be added later):" \
    lts    "Latest LTS (recommended)" \
    24     "Node.js 24" \
    22     "Node.js 22" \
    26     "Node.js 26" \
    latest "Latest current release") || die "Cancelled."
}

node_arch() {
  case $(uname -m) in
    x86_64|amd64)  echo x64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l)        echo armv7l ;;
    *) return 1 ;;
  esac
}

node_resolve() {   # lts | latest | <major>  → vX.Y.Z
  local spec=$1 idx="$TMP_DIR/node-index.tab"
  if [[ ! -s $idx ]]; then curl -fsSL -o "$idx" https://nodejs.org/dist/index.tab 2>>"$SRV_LOG" || return 1; fi
  case $spec in
    lts)    awk -F'\t' 'NR > 1 && $10 != "-" {print $1}' "$idx" ;;
    latest) awk -F'\t' 'NR > 1 {print $1}' "$idx" ;;
    *)      awk -F'\t' -v m="v$spec." 'NR > 1 && index($1, m) == 1 {print $1}' "$idx" ;;
  esac | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1
}

node_versions() {
  local l
  for l in "$NODE_ROOT"/*; do
    if [[ -L $l && -x $l/bin/node ]]; then basename "$l"; fi
  done | sort -n
}
node_full() { basename "$(readlink "$NODE_ROOT/$1")"; }

node_link_default() {
  local m=$1 b
  for b in node npm npx corepack; do
    if [[ -e $NODE_ROOT/$m/bin/$b ]]; then ln -sfn "$NODE_ROOT/$m/bin/$b" "/usr/local/bin/$b"; fi
  done
}

node_install_version() {
  local spec=$1 ver arch major dir tarball
  arch=$(node_arch) || { err "Unsupported CPU architecture: $(uname -m)"; return 1; }
  ver=$(node_resolve "$spec") || ver=""
  [[ $ver =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "Couldn't find Node.js '$spec' on nodejs.org"; return 1; }
  major=${ver#v}; major=${major%%.*}
  dir="$NODE_ROOT/versions/$ver"
  if [[ ! -x $dir/bin/node ]]; then
    tarball="node-$ver-linux-$arch.tar.xz"
    info "Downloading Node.js $ver"
    run curl -fsSL -o "$TMP_DIR/$tarball" "https://nodejs.org/dist/$ver/$tarball" || return 1
    run curl -fsSL -o "$TMP_DIR/SHASUMS256.txt" "https://nodejs.org/dist/$ver/SHASUMS256.txt" || return 1
    if ! ( cd "$TMP_DIR" && grep -E "  $tarball\$" SHASUMS256.txt | sha256sum -c --status ); then
      err "Checksum mismatch for $tarball — aborting"; return 1
    fi
    rm -rf "$dir.tmp"; mkdir -p "$dir.tmp"
    tar -xJf "$TMP_DIR/$tarball" -C "$dir.tmp" --strip-components=1 --no-same-owner || { err "Extracting $tarball failed"; return 1; }
    mv "$dir.tmp" "$dir"
  else
    info "Node.js $ver is already present"
  fi
  # pnpm / yarn through corepack (Node 25+ no longer bundles it)
  if [[ ! -x $dir/bin/corepack ]]; then
    run env PATH="$dir/bin:/usr/bin:/bin" npm install -g --no-fund --no-audit corepack || warn "Couldn't install corepack — pnpm/yarn projects won't work"
  fi
  if [[ -x $dir/bin/corepack ]]; then
    run env PATH="$dir/bin:/usr/bin:/bin" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack enable || warn "corepack enable failed"
  fi
  chmod -R a+rX "$dir"
  ln -sfn "versions/$ver" "$NODE_ROOT/$major"
  NODE_LAST_MAJOR=$major
}

mod_node() {
  local spec=${OPT_NODE:-lts}
  step "Installing Node.js ($spec)"
  apt_install xz-utils build-essential python3 || return 1
  install -d -m 755 "$NODE_ROOT/versions"
  node_install_version "$spec" || return 1
  if [[ -z $(cfg_get NODE_DEFAULT) || ! -x $NODE_ROOT/$(cfg_get NODE_DEFAULT)/bin/node ]]; then cfg_set NODE_DEFAULT "$NODE_LAST_MAJOR"; fi
  node_link_default "$(cfg_get NODE_DEFAULT)"
  feat_set node "$(node_versions | tr '\n' ' ' | sed 's/ $//') (default $(cfg_get NODE_DEFAULT))"
  ok "Node.js $(node_full "$NODE_LAST_MAJOR") installed → $NODE_ROOT/$NODE_LAST_MAJOR"
  local d n=0
  while IFS= read -r d; do
    if [[ -n $d && $(site_get "$d" TYPE) == node && $(site_get "$d" NODE) == "$NODE_LAST_MAJOR" && $(site_get "$d" APP_ACTIVE) == yes ]]; then n=$(( n + 1 )); fi
  done < <(site_list_domains)
  if (( n )); then info "$n running app(s) use Node $NODE_LAST_MAJOR — restart them to use the new version: srv app restart <domain>"; fi
}

# ── python ───────────────────────────────────────────────────────────────────
mod_python() {
  step "Installing Python"
  apt_install python3 python3-venv python3-pip python3-dev build-essential pkg-config \
              libffi-dev libssl-dev libpq-dev default-libmysqlclient-dev
  if [[ -n $OPT_PYVER ]]; then py_install_version "$OPT_PYVER" || return 1; fi
  feat_set python "$(python3 -V 2>&1 | awk '{print $2}')$(v=$(py_versions | tr '\n' ' '); [[ -n $v ]] && echo " + ${v% }")"
  ok "Python $(feat_get python) ready (each app gets its own virtualenv)"
}

# ── supervisor ───────────────────────────────────────────────────────────────
mod_supervisor() {
  step "Installing Supervisor"
  apt_install supervisor
  run systemctl enable --now supervisor
  feat_set supervisor "$(supervisord -v 2>/dev/null || echo installed)"
  ok "Supervisor running"
}

# ── pm2 ──────────────────────────────────────────────────────────────────────
mod_pm2() {
  feat_has node || { err "Node.js is required for PM2 — run: srv install node"; return 1; }
  step "Installing PM2"
  local def; def=$(cfg_get NODE_DEFAULT)
  run env PATH="$NODE_ROOT/$def/bin:/usr/bin:/bin" npm install -g --no-fund --no-audit --prefix "$PM2_PREFIX" pm2@latest || return 1
  chmod -R a+rX "$PM2_PREFIX"
  ln -sfn "$PM2_PREFIX/bin/pm2" /usr/local/bin/pm2
  feat_set pm2 "$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$PM2_PREFIX/lib/node_modules/pm2/package.json" | head -n 1)"
  ok "PM2 $(feat_get pm2) installed (each app runs in its own user's PM2)"
}

# ── certbot ──────────────────────────────────────────────────────────────────
ask_certbot() {
  local e
  while true; do
    e=$(ui_input "Email for your Let's Encrypt account (optional, blank = none)" "$(cfg_get ADMIN_EMAIL)" empty) || die "Cancelled."
    if [[ -z $e || $e =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then break; fi
    warn "That doesn't look like an email address"; retry_or_die "Invalid email: $e"
  done
  OPT_EMAIL=$e
}
mod_certbot() {
  step "Installing Certbot"
  apt_install certbot
  install -d -m 755 "$ACME_ROOT" /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/srv-reload-nginx.sh <<'EOF'
#!/bin/sh
# Managed by srv — reload Nginx after a certificate renews
nginx -t -q && systemctl reload nginx
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/srv-reload-nginx.sh
  if [[ -n $(systemctl list-unit-files --no-legend certbot.timer 2>/dev/null) ]]; then
    run systemctl enable --now certbot.timer
  fi
  if [[ -n $OPT_EMAIL ]]; then cfg_set ADMIN_EMAIL "$OPT_EMAIL"; fi
  feat_set certbot "$(certbot --version 2>&1 | awk '{print $2}')"
  ok "Certbot installed — certificates renew automatically"
}

# ── backup ───────────────────────────────────────────────────────────────────
ask_backup() {
  local d
  while true; do
    d=$(ui_input "Keep database backups for how many days?" "$(cfg_get BACKUP_KEEP_DAYS 7)") || die "Cancelled."; d=$(dec "$d")
    if [[ $d =~ ^[0-9]+$ ]] && (( d >= 1 )); then break; fi
    warn "Enter a number of days (1 or more)"; retry_or_die "Invalid number of days: $d"
  done
  OPT_BACKUP_KEEP=$d
  if ui_yesno "Also back up site files (code, uploads, .env)?" "$(cfg_get BACKUP_FILES yes)"; then OPT_BACKUP_FILES=yes; else OPT_BACKUP_FILES=no; fi
}
mod_backup() {
  step "Scheduling daily backups"
  self_install
  [[ -x $SRV_BIN ]] || { err "$SRV_BIN is missing — copy srv.sh there first"; return 1; }
  local keep=${OPT_BACKUP_KEEP:-$(cfg_get BACKUP_KEEP_DAYS 7)}
  local files=${OPT_BACKUP_FILES:-$(cfg_get BACKUP_FILES yes)}
  cfg_set BACKUP_KEEP_DAYS "$keep"
  cfg_set BACKUP_FILES "$files"
  install -d -m 700 "$BACKUP_DIR"
  cat >/etc/cron.d/srv-backup <<EOF
# Managed by srv — daily backups (databases, site files, remote copy)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 2 * * * root $SRV_BIN backup run >>/var/log/srv-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/srv-backup
  if [[ -z $(db_engines) && $files != yes ]]; then warn "No database server and file backups are off — nothing to back up yet."; fi
  feat_set backup "daily 02:30, keep ${keep}d, databases$([[ $files == yes ]] && echo " + site files")"
  ok "Daily backups at 02:30 → $BACKUP_DIR (kept $keep days)"
  info "Copy them off the server too: srv backup remote setup"
}

# ── rclone ───────────────────────────────────────────────────────────────────
mod_rclone() {
  step "Installing rclone"
  apt_install rclone || return 1
  touch "$RCLONE_CONF"; chmod 600 "$RCLONE_CONF"
  feat_set rclone "$(rclone version 2>/dev/null | head -n 1 | awk '{print $2}')"
  ok "rclone $(feat_get rclone) installed — configure it with: srv backup remote setup"
}

# ── webhook ──────────────────────────────────────────────────────────────────
# A tiny receiver (Python, unprivileged user srv-hook) checks the signature and
# drops "<domain>" into $DEPLOY_QUEUE. A systemd path unit then runs
# 'srv deploy --run-queue' as root. The receiver can only request deploys of
# sites that have a webhook secret — it never runs commands itself.
webhook_write_receiver() {
  cat >"$SRV_LIB/webhook.py" <<'PYEOF2'
#!/usr/bin/env python3
# Managed by srv — deploy webhook receiver (GitHub, GitLab, Bitbucket, generic)
import hashlib, hmac, json, os, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SECRETS = "/etc/srv-webhooks"
QUEUE = "/var/lib/srv/deploy-queue"
DOMAIN = re.compile(r"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")

class Hook(BaseHTTPRequestHandler):
    server_version = "srv-webhook"

    def reply(self, code, msg):
        body = (msg + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply(405, "send a POST")

    def do_POST(self):
        site = self.headers.get("X-Srv-Site", "")
        if not DOMAIN.match(site) or ".." in site:
            return self.reply(404, "unknown site")
        try:
            with open(os.path.join(SECRETS, site + ".json")) as f:
                cfg = json.load(f)
        except (OSError, ValueError):
            return self.reply(404, "no webhook for this site")
        length = int(self.headers.get("Content-Length") or 0)
        if length > 10_000_000:
            return self.reply(413, "payload too large")
        body = self.rfile.read(length) if length else b""
        secret = cfg["secret"].encode()
        sig = self.headers.get("X-Hub-Signature-256") or self.headers.get("X-Hub-Signature") or ""
        if sig.startswith("sha256="):            # GitHub, Bitbucket, Gitea
            good = hmac.compare_digest(sig, "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest())
        elif "X-Gitlab-Token" in self.headers:  # GitLab
            good = hmac.compare_digest(self.headers["X-Gitlab-Token"].encode(), secret)
        else:                                    # anything else: header or ?token=
            token = self.headers.get("X-Srv-Token") or (parse_qs(urlparse(self.path).query).get("token") or [""])[0]
            good = bool(token) and hmac.compare_digest(token.encode(), secret)
        if not good:
            return self.reply(403, "bad signature or token")
        event = self.headers.get("X-GitHub-Event") or self.headers.get("X-Gitea-Event") or ""
        if event == "ping":
            return self.reply(200, "pong")
        ref = ""
        try:
            data = json.loads(body or b"{}")
            ref = data.get("ref") or ""
            changes = (data.get("push") or {}).get("changes") or []     # Bitbucket
            if not ref and changes and changes[0].get("new"):
                ref = "refs/heads/" + (changes[0]["new"].get("name") or "")
        except (ValueError, AttributeError):
            pass
        branch = cfg.get("branch") or ""
        if ref and branch and ref != "refs/heads/" + branch:
            return self.reply(202, "ignored: %s is not %s" % (ref, branch))
        with open(os.path.join(QUEUE, site), "w") as f:
            f.write(str(int(time.time())))
        self.reply(202, "deploy queued")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.headers.get("X-Srv-Site", "-") if hasattr(self, "headers") else "-", fmt % args))

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Hook).serve_forever()
PYEOF2
  chmod 755 "$SRV_LIB/webhook.py"
}

mod_webhook() {
  step "Setting up the deploy webhook receiver"
  apt_install python3 || return 1
  self_install
  if ! id srv-hook &>/dev/null; then
    run useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin srv-hook || return 1
  fi
  install -d -m 750 -o root -g srv-hook "$HOOKS_DIR"
  install -d -m 755 /var/lib/srv
  install -d -m 700 -o srv-hook -g srv-hook "$DEPLOY_QUEUE"
  install -d -m 755 "$SRV_LIB"
  local port; port=$(cfg_get WEBHOOK_PORT)
  if [[ -z $port ]]; then
    port=9000
    while port_in_use "$port" || port_used_by_site "$port"; do port=$(( port + 1 )); done
    cfg_set WEBHOOK_PORT "$port"
  fi
  webhook_write_receiver
  cat >/etc/systemd/system/srv-webhook.service <<EOF
# Managed by srv
[Unit]
Description=srv deploy webhook receiver
After=network.target

[Service]
User=srv-hook
Group=srv-hook
ExecStart=/usr/bin/python3 $SRV_LIB/webhook.py $port
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DEPLOY_QUEUE

[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/srv-deploy-queue.path <<EOF
# Managed by srv
[Unit]
Description=srv — watch for webhook deploys

[Path]
DirectoryNotEmpty=$DEPLOY_QUEUE

[Install]
WantedBy=paths.target
EOF
  cat >/etc/systemd/system/srv-deploy-queue.service <<EOF
# Managed by srv
[Unit]
Description=srv — run queued webhook deploys

[Service]
Type=oneshot
Environment=SRV_TRIGGER=webhook
ExecStart=$SRV_BIN deploy --run-queue
EOF
  run systemctl daemon-reload
  run systemctl enable srv-webhook.service srv-deploy-queue.path
  run systemctl restart srv-webhook.service
  run systemctl start srv-deploy-queue.path
  local i
  for (( i = 0; i < 10; i++ )); do if port_in_use "$port"; then break; fi; sleep 1; done
  port_in_use "$port" || { err "The webhook receiver isn't listening on 127.0.0.1:$port — see: journalctl -u srv-webhook"; return 1; }
  feat_set webhook "127.0.0.1:$port"
  ok "Webhook receiver running on 127.0.0.1:$port (enable per site: srv deploy webhook <domain> on)"
}

# ── Feature orchestration ────────────────────────────────────────────────────
feature_summary() {
  local f extra
  for f in "$@"; do
    case $f in
      timezone)  extra=$OPT_TZ ;;
      hostname)  extra=$OPT_HOSTNAME ;;
      swap)      extra=$OPT_SWAP ;;
      sudo-user) extra=$OPT_USER ;;
      ssh)       extra="port $OPT_SSH_PORT, root login: $OPT_ROOT_LOGIN, passwords: $([[ $OPT_SSH_NOPASS == yes ]] && echo off || echo on)" ;;
      php)       extra="PHP $OPT_PHP" ;;
      database)  extra=$OPT_DB_ENGINE ;;
      postgres)  extra="PostgreSQL $OPT_PG" ;;
      redis)     extra="memory policy: $OPT_REDIS_POLICY" ;;
      node)      extra="Node.js $OPT_NODE" ;;
      python)    extra="${OPT_PYVER:+system + $OPT_PYVER}" ;;
      dbadmin)   extra="$OPT_TOOLS on ${OPT_TOOLS_HOST/#_/server IP}" ;;
      certbot)   extra=${OPT_EMAIL:-no email} ;;
      backup)    extra="keep $OPT_BACKUP_KEEP days, site files: $OPT_BACKUP_FILES" ;;
      *)         extra="" ;;
    esac
    printf '  • %-13s %s\n' "$f" "$extra"
  done
}

run_module() {
  local label=$1; shift
  try "$@"
  if (( TRY_RC == 0 )); then MOD_OK+=("$label"); else MOD_FAIL+=("$label"); err "$label failed (details: $SRV_LOG)"; fi
}

install_features() {
  local -a want=("$@") final=(); local f
  if in_list composer "${want[@]}" && ! in_list php "${want[@]}" && ! feat_has php; then want+=(php); info "Adding php (required by composer)"; fi
  if in_list pm2 "${want[@]}" && ! in_list node "${want[@]}" && ! feat_has node; then want+=(node); info "Adding node (required by pm2)"; fi
  for f in "${FEATURES[@]}"; do
    if in_list "$f" "${want[@]}"; then final+=("$f"); fi
  done
  (( ${#final[@]} )) || { info "Nothing selected."; return 0; }

  for f in "${final[@]}"; do
    if declare -F "ask_${f//-/_}" >/dev/null; then "ask_${f//-/_}"; fi
  done
  if (( INTERACTIVE && ! ASSUME_YES )); then
    ui_yesno "Ready to install:"$'\n\n'"$(feature_summary "${final[@]}")"$'\n\n'"Proceed?" yes || die "Cancelled."
    ui_clear
  fi

  if ! feat_has base; then
    try mod_base
    (( TRY_RC == 0 )) || die "Base packages failed to install — see $SRV_LOG"
  fi
  MOD_OK=(); MOD_FAIL=()
  for f in "${final[@]}"; do run_module "$f" "mod_${f//-/_}"; done

  echo; hr
  for f in "${MOD_OK[@]}";   do printf ' %s✓%s %s\n' "$C_G" "$C_0" "$f"; done
  for f in "${MOD_FAIL[@]}"; do printf ' %s✗%s %s\n' "$C_R" "$C_0" "$f"; done
  hr
  if (( ${#MOD_FAIL[@]} )); then warn "Some steps failed. Details in $SRV_LOG — retry with: srv install <feature>"; fi
  if [[ -f /var/run/reboot-required ]]; then warn "A reboot is required to finish the updates (run: reboot)"; fi
}

ensure_feature() {
  local f=$1 fn=${1//-/_}
  if feat_has "$f"; then return 0; fi
  if (( INTERACTIVE )) && ui_yesno "'$f' ($(feat_desc "$f")) isn't installed yet. Install it now?" yes; then
    if declare -F "ask_$fn" >/dev/null; then "ask_$fn"; fi
    if ! feat_has base; then try mod_base; (( TRY_RC == 0 )) || die "Base packages failed — see $SRV_LOG"; fi
    try "mod_$fn"
    (( TRY_RC == 0 )) || die "Installing $f failed — see $SRV_LOG"
  else
    die "'$f' is not installed. Run: srv install $f"
  fi
}

cmd_setup() {
  (( INTERACTIVE )) || die "setup is interactive. For unattended installs use: srv install <feature> --yes"
  ensure_whiptail
  self_install
  ui_msg "srv setup" "Welcome to srv $SRV_VERSION on $OS_NAME.

1. Pick the features you want.
2. Answer a few questions.
3. Everything then installs without further prompts.

Anything you skip can be added later with:  srv install"
  local -a items=() sel=(); local f state desc
  for f in "${FEATURES[@]}"; do
    state=$(feat_default "$f"); desc=$(feat_desc "$f")
    if [[ $f != upgrade ]] && feat_has "$f"; then state=OFF; desc="$desc [installed]"; fi
    items+=("$f" "$desc" "$state")
  done
  mapfile -t sel < <(ui_checklist "Server setup" "Choose what to install now (space = toggle, enter = continue):" "${items[@]}")
  (( ${#sel[@]} )) || { info "Nothing selected."; return 0; }
  install_features "${sel[@]}"
  feat_set setup
  echo
  info "Next steps"
  echo "   srv site add        create your first site"
  echo "   srv status          server overview"
  echo "   srv install         add anything you skipped"
  echo "   srv                 interactive menu"
}

cmd_install() {
  local f=${1:-}; shift || true
  local -a todo=()
  if [[ -z $f ]]; then
    (( INTERACTIVE )) || die "Usage: srv install <feature>   Features: ${FEATURES[*]}"
    ensure_whiptail
    local -a items=(); local x desc
    for x in "${FEATURES[@]}"; do
      desc=$(feat_desc "$x")
      if [[ $x == php || $x == node ]] && feat_has "$x"; then desc="$desc [installed: $(feat_get "$x") — add another]"
      elif [[ $x != upgrade ]] && feat_has "$x"; then desc="$desc [installed — reconfigure]"; fi
      items+=("$x" "$desc" OFF)
    done
    mapfile -t todo < <(ui_checklist "Install features" "Select features to install (space = toggle):" "${items[@]}")
  else
    case $f in
      mysql|mariadb)          OPT_DB_ENGINE=$f; f=database ;;
      postgresql|pgsql|pg)    f=postgres ;;
      nodejs)                 f=node ;;
      redis-server)           f=redis ;;
      ufw)                    f=firewall ;;
      ssl|letsencrypt)        f=certbot ;;
      adminer|phpmyadmin)     OPT_TOOLS=$f; f=dbadmin ;;
      tools)                  f=dbadmin ;;
    esac
    in_list "$f" "${FEATURES[@]}" || die "Unknown feature: $f. Available: ${FEATURES[*]}"
    if [[ -n ${1:-} ]]; then
      case $f in
        php)      [[ $1 =~ ^[0-9]+\.[0-9]+$ ]] || die "PHP version must look like 8.3"; OPT_PHP=$1 ;;
        node)     [[ $1 =~ ^([0-9]+|lts|latest)$ ]] || die "Node.js version must be a major version (e.g. 22), lts or latest"; OPT_NODE=$1 ;;
        postgres) [[ $1 =~ ^[0-9]+$ ]] || die "PostgreSQL version must be a number (e.g. 17)"; OPT_PG=$1 ;;
        python)   [[ $1 =~ ^3\.[0-9]+(\.[0-9]+)?$ ]] || die "Python version must look like 3.12"; OPT_PYVER=$1 ;;
        *) die "'$f' doesn't take a version." ;;
      esac
    fi
    if [[ $f != php && $f != node && $f != upgrade ]] && ! [[ $f == python && -n $OPT_PYVER ]] && feat_has "$f"; then
      ui_yesno "'$f' is already installed ($(feat_get "$f")). Run its setup again?" no || { info "Nothing to do."; return 0; }
    fi
    todo=("$f")
  fi
  install_features "${todo[@]}"
}

# =============================================================================
#  SITES
# =============================================================================
site_file()    { printf '%s/%s.conf' "$SRV_SITES" "$1"; }
site_exists()  { [[ -f $(site_file "$1") ]]; }
site_get()     { kv_get "$(site_file "$1")" "$2" "${3-}"; }
site_set()     { kv_set "$(site_file "$1")" "$2" "$3"; }
site_docroot() { local w; w=$(site_get "$1" WEBROOT); printf '%s' "$(site_get "$1" APP_DIR)${w:+/$w}"; }

is_php_type()   { [[ $1 == php || $1 == laravel ]]; }
is_app_type()   { [[ $1 == node || $1 == python ]]; }
is_proxy_type() { [[ $1 == node || $1 == python || $1 == proxy ]]; }

site_list_domains() {
  local f
  for f in "$SRV_SITES"/*.conf; do
    if [[ -f $f ]]; then basename "$f" .conf; fi
  done
}

# Prints the site that already uses this hostname (as primary or alias)
domain_in_use() {
  local n=$1 d
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ " $d $(site_get "$d" ALIASES) " == *" $n "* ]]; then printf '%s' "$d"; return 0; fi
  done < <(site_list_domains)
  return 1
}

site_user_for() {
  local u=${1//[^a-z0-9]/_} base i=2
  if [[ ! $u =~ ^[a-z] ]]; then u="s_$u"; fi
  u=${u:0:32}; base=${u:0:28}
  while id "$u" &>/dev/null; do u="${base}_$i"; i=$(( i + 1 )); done
  printf '%s' "$u"
}

laravel_conf() { printf '/etc/supervisor/conf.d/srv-%s-laravel.conf' "$(site_get "$1" SITE_USER)"; }
site_has_process() {   # node/python apps, and Laravel sites with workers
  local t; t=$(site_get "$1" TYPE)
  is_app_type "$t" || { [[ $t == laravel && -f $(laravel_conf "$1") ]]; }
}

site_runtime() {
  case $(site_get "$1" TYPE) in
    php|laravel) echo "php$(site_get "$1" PHP)" ;;
    node)        echo "node$(site_get "$1" NODE)" ;;
    python)      echo "python" ;;
    proxy)       echo "proxy" ;;
    *)           echo "-" ;;
  esac
}

# pick_site [apps]  → interactive site picker ("apps" = only sites with processes)
pick_site() {
  local filter=${1:-} d ssl
  local -a items=()
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ $filter == apps ]] && ! site_has_process "$d"; then continue; fi
    if [[ $filter == deploy ]] && ! deploy_enabled "$d"; then continue; fi
    ssl=""; if [[ $(site_get "$d" SSL) == yes ]]; then ssl=", https"; fi
    items+=("$d" "$(site_get "$d" TYPE)$ssl")
  done < <(site_list_domains)
  if (( ! ${#items[@]} )); then
    if [[ $filter == apps ]]; then warn "No apps yet — create one with: srv site add --type node|python"
    elif [[ $filter == deploy ]]; then warn "No site deploys from git yet — set one up with: srv deploy setup <domain>"
    else warn "No sites yet — create one with: srv site add"; fi
    return 1
  fi
  if (( ! INTERACTIVE )); then err "Specify the domain."; return 1; fi
  ui_menu "Sites" "Select a site:" "${items[@]}"
}

# resolve_domain [domain] [apps] → prints an existing site's domain (asks if missing)
resolve_domain() {
  local d=${1:-}
  d=${d,,}
  if [[ -z $d ]]; then d=$(pick_site "${2:-}") || die "No site selected."; fi
  site_exists "$d" || die "Site not found: $d (see: srv site list)"
  printf '%s' "$d"
}

normalize_upstream() {
  local u=$1
  if [[ $u != http://* && $u != https://* ]]; then u="http://$u"; fi
  u=${u%/}
  [[ $u =~ ^https?://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?$ ]] || return 1
  printf '%s' "$u"
}

# ── Config rendering ─────────────────────────────────────────────────────────
site_render_pool() {
  local d=$1 type user php home f v
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); php=$(site_get "$d" PHP); home=$(site_get "$d" HOME_DIR)
  local -a reload=()
  # Remove this site's pool from other PHP versions (version switch / type change)
  for f in /etc/php/*/fpm/pool.d/srv-"$user".conf; do
    [[ -f $f ]] || continue
    v=${f#/etc/php/}; v=${v%%/*}
    if [[ $v != "$php" ]] || ! is_php_type "$type"; then rm -f "$f"; reload+=("$v"); fi
  done
  if is_php_type "$type"; then
    [[ -d /etc/php/$php/fpm/pool.d ]] || { err "PHP $php-FPM is not installed (srv install php $php)"; return 1; }
    cat >"/etc/php/$php/fpm/pool.d/srv-$user.conf" <<EOF
; Managed by srv — regenerate with: srv site rebuild $d
[$user]
user = $user
group = $user
listen = /run/php/srv-$user.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 30s
pm.max_requests = 500

chdir = /
catch_workers_output = yes
php_admin_flag[log_errors] = on
php_admin_value[error_log] = $home/logs/php-error.log
php_admin_value[upload_tmp_dir] = $home/tmp
php_admin_value[sys_temp_dir] = $home/tmp
php_value[session.save_path] = $home/tmp
EOF
    reload+=("$php")
  fi
  for v in $(printf '%s\n' "${reload[@]}" | sort -u); do
    if [[ -x /usr/sbin/php-fpm$v ]]; then
      if ! "/usr/sbin/php-fpm$v" -t >>"$SRV_LOG" 2>&1; then err "PHP-FPM $v config test failed — see $SRV_LOG"; return 1; fi
      run systemctl reload "php$v-fpm" || return 1
    fi
  done
}

nginx_resolver() {
  local ns
  ns=$(awk '$1 == "nameserver" && $2 !~ /%/ {print $2}' /etc/resolv.conf 2>/dev/null | head -n 3 | sed -E 's/^(.*:.*)$/[\1]/' | tr '\n' ' ')
  ns=${ns% }
  printf '%s' "${ns:-127.0.0.53}"
}

site_nginx_proxy_body() {
  local d=$1 type=$2 app target ws timeout host_hdr body
  app=$(site_get "$d" APP_DIR)
  if [[ $type == proxy ]]; then target=$(site_get "$d" UPSTREAM); else target="http://127.0.0.1:$(site_get "$d" PORT)"; fi
  ws=$(site_get "$d" WEBSOCKET yes); timeout=$(site_get "$d" TIMEOUT 60); body=$(site_get "$d" MAX_BODY)
  # shellcheck disable=SC2016
  host_hdr='$host'
  # shellcheck disable=SC2016
  if [[ $(site_get "$d" PRESERVE_HOST yes) != yes ]]; then host_hdr='$proxy_host'; fi
  if [[ $ws == yes ]] && (( timeout < 3600 )); then timeout=3600; fi   # keep idle WebSockets open
  cat <<EOF

    access_log /var/log/nginx/$d.access.log;
    error_log  /var/log/nginx/$d.error.log warn;

    include snippets/srv-security.conf;
    include $NGINX_CUSTOM/$d/*.conf;
EOF
  if [[ -n $body ]]; then printf '    client_max_body_size %s;\n' "$body"; fi
  if [[ $type == python && $(site_get "$d" PY_FRAMEWORK) == django ]]; then
    cat <<EOF

    # Django: collectstatic output (STATIC_ROOT) and uploads (MEDIA_ROOT)
    location ^~ /static/ {
        alias $app/$(site_get "$d" STATIC_DIR staticfiles)/;
        expires 30d;
        access_log off;
    }

    location ^~ /media/ {
        alias $app/$(site_get "$d" MEDIA_DIR media)/;
        expires 7d;
    }
EOF
  fi
  # Hostname upstreams are resolved per request (via a variable + resolver), so a
  # DNS failure can't stop Nginx from starting or reloading for every other site.
  local uhost=${target#*://}; uhost=${uhost%%/*}; uhost=${uhost%:*}
  echo
  echo "    location / {"
  if [[ $type == proxy && ! $uhost =~ ^[0-9.]+$ && $uhost != localhost && $uhost != \[* ]]; then
    echo "        resolver $(nginx_resolver) valid=60s;"
    echo "        resolver_timeout 5s;"
    echo "        set \$srv_upstream $target;"
    echo "        proxy_pass \$srv_upstream;"
  else
    echo "        proxy_pass $target;"
  fi
  echo "        include snippets/srv-proxy.conf;"
  echo "        proxy_set_header Host $host_hdr;"
  if [[ $ws == yes ]]; then
    # shellcheck disable=SC2016
    printf '        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection $connection_upgrade;\n'
  else
    echo '        proxy_set_header Connection "";'
  fi
  echo "        proxy_read_timeout ${timeout}s;"
  echo "        proxy_send_timeout ${timeout}s;"
  if [[ $target == https://* ]]; then echo "        proxy_ssl_server_name on;"; fi
  echo "    }"
}

site_nginx_body() {
  local d=$1 type user root sock index tpl
  type=$(site_get "$d" TYPE)
  if is_proxy_type "$type"; then site_nginx_proxy_body "$d" "$type"; return 0; fi
  user=$(site_get "$d" SITE_USER); root=$(site_docroot "$d")
  sock="/run/php/srv-$user.sock"; index="index.html index.htm"
  if is_php_type "$type"; then index="index.php index.html"; fi
  cat <<EOF

    root $root;
    index $index;
    charset utf-8;

    access_log /var/log/nginx/$d.access.log;
    error_log  /var/log/nginx/$d.error.log warn;

    include snippets/srv-security.conf;
    include $NGINX_CUSTOM/$d/*.conf;

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
EOF
  case $type in
    static) tpl=$(cat <<'EOF'

    location / {
        try_files $uri $uri/ =404;
    }

    location ~* \.(?:css|js|mjs|map|jpe?g|png|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot|mp4|webm|pdf)$ {
        expires 30d;
        access_log off;
        try_files $uri =404;
    }
EOF
) ;;
    spa) tpl=$(cat <<'EOF'

    # Single-page app: unknown paths fall back to index.html (client-side routing)
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Never cache the HTML shell (add_header here replaces the server-level headers, so repeat them)
    location = /index.html {
        add_header Cache-Control "no-cache" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    }

    location ~* \.(?:css|js|mjs|map|jpe?g|png|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot|mp4|webm|pdf)$ {
        expires 30d;
        access_log off;
        try_files $uri =404;
    }
EOF
) ;;
    php) tpl=$(cat <<'EOF'

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~* \.(?:css|js|mjs|map|jpe?g|png|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot|mp4|webm|pdf)$ {
        expires 30d;
        access_log off;
        try_files $uri /index.php?$query_string;
    }

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:__SOCK__;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT $realpath_root;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_param HTTP_PROXY "";
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_read_timeout 60s;
    }
EOF
) ;;
    laravel) tpl=$(cat <<'EOF'

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # Assets fall back to Laravel too (e.g. /livewire/livewire.js is a route)
    location ~* \.(?:css|js|mjs|map|jpe?g|png|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot|mp4|webm|pdf)$ {
        expires 30d;
        access_log off;
        try_files $uri /index.php?$query_string;
    }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:__SOCK__;
        fastcgi_split_path_info ^(.+\.php)(/.*)$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT $realpath_root;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_param HTTP_PROXY "";
        fastcgi_hide_header X-Powered-By;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_read_timeout 60s;
    }

    # Only index.php may execute
    location ~ \.php$ {
        return 404;
    }
EOF
) ;;
  esac
  printf '%s\n' "${tpl//__SOCK__/$sock}"

  if [[ $type == laravel && $(site_get "$d" REVERB) == yes && -n $(site_get "$d" REVERB_PORT) ]]; then
    tpl=$(cat <<'EOF'

    # Laravel Reverb (srv site workers): WebSocket clients use /app/*, the HTTP API /apps/*
    location ^~ /app/ {
        proxy_pass http://127.0.0.1:__PORT__;
        include snippets/srv-proxy.conf;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ^~ /apps/ {
        proxy_pass http://127.0.0.1:__PORT__;
        include snippets/srv-proxy.conf;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
    }
EOF
)
    printf '%s\n' "${tpl//__PORT__/$(site_get "$d" REVERB_PORT)}"
  fi
}

# Maintenance mode + deploy webhook (rendered into the server{} that serves the site)
site_nginx_extras() {
  local d=$1 home ip
  home=$(site_get "$d" HOME_DIR)
  echo
  echo "    # Maintenance mode — srv site maintenance $d on|off (no reload needed)"
  # shellcheck disable=SC2016
  {
    echo '    set $srv_maint 0;'
    echo "    if (-f $home/.maintenance) { set \$srv_maint 1; }"
    echo '    if ($uri ~ ^/(\.well-known/|_srv/deploy$|__srv_maintenance|_srv-tools-)) { set $srv_maint 0; }'
    for ip in $(site_get "$d" MAINT_ALLOW); do echo "    if (\$remote_addr = $ip) { set \$srv_maint 0; }"; done
    echo '    if ($srv_maint) { rewrite ^ /__srv_maintenance last; }'
    echo '    location = /__srv_maintenance { internal; error_page 503 /__srv_maintenance.html; return 503; }'
    echo "    location = /__srv_maintenance.html { internal; alias $SRV_WWW/maintenance.html; default_type text/html; add_header Retry-After 300 always; add_header Cache-Control \"no-store\" always; }"
  }
  if [[ $(cfg_get TOOLS_HOST) == "$d" && -f $TOOLS_CONF ]]; then
    echo
    echo "    # Database tools — srv tools"
    echo "    include $TOOLS_CONF;"
  fi
  if [[ $(site_get "$d" DEPLOY_WEBHOOK) == yes && -n $(cfg_get WEBHOOK_PORT) ]]; then
    cat <<EOF

    # Deploy webhook — srv deploy webhook $d
    location = /_srv/deploy {
        proxy_pass http://127.0.0.1:$(cfg_get WEBHOOK_PORT);
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Srv-Site $d;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Connection "";
        client_max_body_size 10m;
        proxy_read_timeout 30s;
    }
EOF
  fi
}

site_render_nginx() {
  local d=$1 aliases ssl names v6=0 nv h2_listen=" http2" h2_on=0
  aliases=$(site_get "$d" ALIASES); ssl=$(site_get "$d" SSL no)
  names="$d${aliases:+ $aliases}"
  local canon=0; if [[ -n $aliases && $(site_get "$d" CANONICAL no) == yes ]]; then canon=1; names=$d; fi
  if [[ -f /proc/net/if_inet6 ]]; then v6=1; fi
  if [[ $ssl == yes && ! -f /etc/letsencrypt/live/$d/fullchain.pem ]]; then
    warn "SSL is on for $d but no certificate was found — serving HTTP only"; ssl=no
  fi
  nv=$(nginx_version)
  if [[ -n $nv ]] && ver_ge "$nv" 1.25.1; then h2_listen=""; h2_on=1; fi

  echo "# Managed by srv — regenerated by 'srv site rebuild $d'. Don't edit this file;"
  echo "# put custom directives in $NGINX_CUSTOM/$d/*.conf (included in the server block)."
  echo
  echo "server {"
  echo "    listen 80;"
  if (( v6 )); then echo "    listen [::]:80;"; fi
  echo "    server_name $names;"
  echo
  echo "    include snippets/srv-acme.conf;"
  if [[ $ssl == yes ]]; then
    echo
    echo "    location / {"
    echo "        return 301 https://\$host\$request_uri;"
    echo "    }"
    echo "}"
    echo
    echo "server {"
    echo "    listen 443 ssl${h2_listen};"
    if (( v6 )); then echo "    listen [::]:443 ssl${h2_listen};"; fi
    if (( h2_on )); then echo "    http2 on;"; fi
    echo "    server_name $names;"
    echo
    echo "    ssl_certificate     /etc/letsencrypt/live/$d/fullchain.pem;"
    echo "    ssl_certificate_key /etc/letsencrypt/live/$d/privkey.pem;"
    echo "    include snippets/srv-ssl.conf;"
  fi
  site_nginx_extras "$d"
  site_nginx_body "$d"
  echo "}"
  if (( canon )); then
    local target="http://$d"; if [[ $ssl == yes ]]; then target="https://$d"; fi
    echo
    echo "# Aliases redirect to the primary domain (CANONICAL=yes)"
    echo "server {"
    echo "    listen 80;"
    if (( v6 )); then echo "    listen [::]:80;"; fi
    echo "    server_name $aliases;"
    echo "    include snippets/srv-acme.conf;"
    echo "    location / {"
    echo "        return 301 $target\$request_uri;"
    echo "    }"
    echo "}"
    if [[ $ssl == yes ]]; then
      echo
      echo "server {"
      echo "    listen 443 ssl${h2_listen};"
      if (( v6 )); then echo "    listen [::]:443 ssl${h2_listen};"; fi
      if (( h2_on )); then echo "    http2 on;"; fi
      echo "    server_name $aliases;"
      echo "    ssl_certificate     /etc/letsencrypt/live/$d/fullchain.pem;"
      echo "    ssl_certificate_key /etc/letsencrypt/live/$d/privkey.pem;"
      echo "    include snippets/srv-ssl.conf;"
      echo "    return 301 https://$d\$request_uri;"
      echo "}"
    fi
  fi
}

# Write + enable the vhost, test it, reload; roll back if Nginx rejects it.
site_apply_nginx() {
  local d=$1 avail="/etc/nginx/sites-available/$1.conf" enabled="/etc/nginx/sites-enabled/$1.conf" bak="" out
  nginx_sync_shared
  if [[ -f $avail ]]; then bak="$TMP_DIR/$d.nginx.bak"; cp -a "$avail" "$bak"; fi
  install -d -m 755 "$NGINX_CUSTOM/$d"
  site_render_nginx "$d" >"$avail"
  if [[ $(site_get "$d" ENABLED yes) == yes ]]; then ln -sfn "$avail" "$enabled"; else rm -f "$enabled"; fi
  if ! out=$(nginx -t 2>&1); then
    err "Nginx rejected the config for $d:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/     │ /' >&2
    if [[ -n $bak ]]; then cp -a "$bak" "$avail"; else rm -f "$avail" "$enabled"; fi
    return 1
  fi
  run systemctl reload nginx
}

site_render_cron() {
  local d=$1 type user php app
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); php=$(site_get "$d" PHP); app=$(site_get "$d" APP_DIR)
  if [[ $type == laravel ]]; then
    cat >"/etc/cron.d/srv-$user" <<EOF
# Laravel scheduler for $d — managed by srv
* * * * * $user cd $app && [ -f artisan ] && /usr/bin/php$php artisan schedule:run >/dev/null 2>&1
EOF
    chmod 644 "/etc/cron.d/srv-$user"
  else
    rm -f "/etc/cron.d/srv-$user"
  fi
}

site_placeholder() {
  local dir=$1 type=$2 d=$3
  if [[ $type == php ]]; then
    cat >"$dir/index.php" <<EOF
<?php // Placeholder created by srv — replace it with your application.
echo '<h1>$d is ready</h1><p>PHP ' . PHP_VERSION . ' via srv. Upload your files to replace this page.</p>';
EOF
  else
    cat >"$dir/index.html" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>$d</title></head>
<body style="font-family:system-ui,sans-serif;margin:4rem">
<h1>$d is ready</h1><p>Served by Nginx via srv. Upload your files to replace this page.</p>
</body></html>
EOF
  fi
}

site_create_db() {
  local d=$1 eng=$2 base name user pass i=2
  base=${d//[^a-z0-9]/_}; base=${base:0:48}
  name=$base
  while eng_exists "$eng" "$name"; do name="${base}_$i"; i=$(( i + 1 )); done
  user=${name:0:32}; i=2
  while eng_user_exists "$eng" "$user"; do user="${name:0:28}_$i"; i=$(( i + 1 )); done
  pass=$(gen_password 24)
  eng_create "$eng" "$name" "$user" "$pass" || return 1
  site_set "$d" DB_ENGINE "$eng"; site_set "$d" DB_NAME "$name"; site_set "$d" DB_USER "$user"; site_set "$d" DB_PASS "$pass"
}

redis_db_alloc() {   # a separate Redis database number (1–15) for each Node/Python app
  local used i
  used=" $(grep -hsE '^REDIS_DB=' "$SRV_SITES"/*.conf | cut -d= -f2 | tr '\n' ' ') "
  for (( i = 1; i <= 15; i++ )); do
    if [[ $used != *" $i "* ]]; then printf '%s' "$i"; return 0; fi
  done
  printf '0'
}

# ── .env helpers ─────────────────────────────────────────────────────────────
env_get() { { grep -E "^${2}=" "$1" 2>/dev/null || true; } | tail -n 1 | cut -d= -f2-; }
env_set() {
  local file=$1 key=$2 val=$3 tmp
  tmp=$(mktemp)
  if grep -qE "^#?[[:space:]]*${key}=" "$file"; then
    # value passed via the environment, not argv, so secrets don't show up in ps
    SRV_K=$key SRV_V=$val awk 'BEGIN { k = ENVIRON["SRV_K"]; v = ENVIRON["SRV_V"] } !done && $0 ~ "^#?[[:space:]]*" k "=" { print k "=" v; done=1; next } { print }' "$file" >"$tmp"
  else
    cp "$file" "$tmp"
    if [[ -s $tmp && -n $(tail -c 1 "$tmp") ]]; then echo >>"$tmp"; fi
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
  fi
  cat "$tmp" >"$file"; rm -f "$tmp"
}
env_unset() { if [[ -f $1 ]]; then sed -i "/^${2}=/d" "$1"; fi; }

# app.env for Node/Python apps: DATABASE_URL, DB_*, REDIS_URL (loaded by the launcher)
app_env_sync() {
  local d=$1 user home f dbn eng scheme port
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); f="$home/app.env"
  if [[ ! -f $f ]]; then
    printf '# Environment for %s — loaded when the app starts (KEY=value, shell syntax).\n# srv manages the DATABASE_*, DB_* and REDIS_URL lines.\n' "$d" >"$f"
  fi
  dbn=$(site_get "$d" DB_NAME)
  if [[ -n $dbn ]]; then
    eng=$(site_get "$d" DB_ENGINE mysql); port=$(eng_port "$eng")
    scheme=mysql; if [[ $eng == pgsql ]]; then scheme=postgresql; fi
    env_set "$f" DATABASE_URL "$scheme://$(site_get "$d" DB_USER):$(site_get "$d" DB_PASS)@127.0.0.1:$port/$dbn"
    env_set "$f" DB_HOST 127.0.0.1
    env_set "$f" DB_PORT "$port"
    env_set "$f" DB_NAME "$dbn"
    env_set "$f" DB_USER "$(site_get "$d" DB_USER)"
    env_set "$f" DB_PASSWORD "$(site_get "$d" DB_PASS)"
  fi
  if [[ $(site_get "$d" REDIS) == yes ]]; then
    env_set "$f" REDIS_URL "redis://:$(cfg_get REDIS_PASSWORD)@127.0.0.1:6379/$(site_get "$d" REDIS_DB 0)"
  else
    env_unset "$f" REDIS_URL
  fi
  chown "$user:$user" "$f"; chmod 600 "$f"
}

# ── site add: type-specific questions ────────────────────────────────────────
site_ask_node() {
  ensure_feature node
  local -a vers=(); mapfile -t vers < <(node_versions)
  (( ${#vers[@]} )) || die "No Node.js version found — run: srv install node"
  if [[ -n $S_NODE ]]; then
    in_list "$S_NODE" "${vers[@]}" || die "Node $S_NODE isn't installed (installed: ${vers[*]}). Run: srv install node $S_NODE"
  elif (( ${#vers[@]} == 1 )); then
    S_NODE=${vers[0]}
  else
    local -a items=(); local v def; def=$(cfg_get NODE_DEFAULT "${vers[-1]}")
    if in_list "$def" "${vers[@]}"; then items+=("$def" "Node.js $(node_full "$def") (default)"); fi
    for v in "${vers[@]}"; do if [[ $v != "$def" ]]; then items+=("$v" "Node.js $(node_full "$v")"); fi; done
    S_NODE=$(ui_menu "Node.js version" "Node.js version for this app:" "${items[@]}") || die "Cancelled."
  fi
  if [[ -z $S_PRESET ]]; then
    S_PRESET=$(ui_menu "Node.js app" "What kind of app is it?" \
      next    "Next.js" \
      nuxt    "Nuxt" \
      nest    "NestJS" \
      generic "Express / Fastify / other (npm start)") || die "Cancelled."
  fi
  local def_start def_build
  case $S_PRESET in
    next)    def_start="npm start";                    def_build="npm run build" ;;
    nuxt)    def_start="node .output/server/index.mjs"; def_build="npm run build" ;;
    nest)    def_start="node dist/main";               def_build="npm run build" ;;
    generic) def_start="npm start";                    def_build="" ;;
    *) die "Unknown preset: $S_PRESET (use next, nuxt, nest or generic)" ;;
  esac
  if (( ! S_START_SET )); then
    S_START=$(ui_input "Start command — one command; your app must listen on \$PORT" "$def_start") || die "Cancelled."
  fi
  if (( ! S_BUILD_SET )); then
    S_BUILD=$(ui_input "Build command (blank = no build step)" "$def_build" empty) || die "Cancelled."
  fi
  [[ -n $S_START && $S_START != *$'\n'* && $S_BUILD != *$'\n'* ]] || die "A one-line start command is required."
}

site_ask_python() {
  ensure_feature python
  local -a pyv=(); mapfile -t pyv < <(py_versions)
  if (( S_PYVER_SET )); then
    if [[ -n $S_PYVER && $S_PYVER != system ]]; then in_list "$S_PYVER" "${pyv[@]}" || die "Python $S_PYVER isn't installed (srv python install $S_PYVER)"; else S_PYVER=""; fi
  elif (( ${#pyv[@]} )); then
    local -a items=(system "System Python $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"); local x
    for x in "${pyv[@]}"; do items+=("$x" "Python $x"); done
    S_PYVER=$(ui_menu "Python version" "Python for this app:" "${items[@]}") || die "Cancelled."
    if [[ $S_PYVER == system ]]; then S_PYVER=""; fi
  fi
  if [[ -z $S_FRAMEWORK ]]; then
    S_FRAMEWORK=$(ui_menu "Python app" "Framework:" \
      django  "Django" \
      flask   "Flask" \
      fastapi "FastAPI" \
      other   "Other WSGI / ASGI app") || die "Cancelled."
  fi
  local def_srv=gunicorn def_mod="app:app"
  case $S_FRAMEWORK in
    django)  def_mod="" ;;
    flask)   def_mod="app:app" ;;
    fastapi) def_srv=uvicorn; def_mod="main:app" ;;
    other)   def_mod="app:app" ;;
    *) die "Unknown framework: $S_FRAMEWORK (use django, flask, fastapi or other)" ;;
  esac
  if [[ -z $S_SERVER ]]; then
    if [[ $def_srv == uvicorn ]]; then
      S_SERVER=$(ui_menu "App server" "Run the app with:" uvicorn "uvicorn — ASGI (FastAPI, async)" gunicorn "gunicorn — WSGI") || die "Cancelled."
    else
      S_SERVER=$(ui_menu "App server" "Run the app with:" gunicorn "gunicorn — WSGI (Django, Flask)" uvicorn "uvicorn — ASGI (async Django, Starlette)") || die "Cancelled."
    fi
  fi
  in_list "$S_SERVER" gunicorn uvicorn || die "Unknown app server: $S_SERVER (use gunicorn or uvicorn)"
  if (( ! S_MODULE_SET )); then
    if [[ $S_FRAMEWORK == django ]]; then
      S_MODULE=$(ui_input "App module (blank = find <project>.wsgi automatically)" "" empty) || die "Cancelled."
    else
      S_MODULE=$(ui_input "App module (module:variable)" "$def_mod") || die "Cancelled."
    fi
  fi
  if [[ -n $S_MODULE && ! $S_MODULE =~ ^[A-Za-z0-9_.]+:[A-Za-z0-9_.()]+$ ]]; then die "Invalid app module: $S_MODULE (e.g. main:app)"; fi
  if [[ -z $S_MODULE && $S_FRAMEWORK != django ]]; then die "An app module is required (e.g. main:app)."; fi
  if [[ -z $S_WORKERS ]]; then
    local c; c=$(nproc 2>/dev/null || echo 1)
    S_WORKERS=$(( c * 2 + 1 )); if (( S_WORKERS > 9 )); then S_WORKERS=9; fi
  fi
  S_WORKERS=$(dec "$S_WORKERS")
  [[ $S_WORKERS =~ ^[0-9]+$ ]] && (( S_WORKERS >= 1 && S_WORKERS <= 64 )) || die "Workers must be between 1 and 64."
}

site_ask_proxy() {
  local domain=$1 u=$S_UPSTREAM n
  while true; do
    if [[ -z $u ]]; then u=$(ui_input "Forward requests to (host:port or URL, e.g. 127.0.0.1:8080)" "127.0.0.1:8080") || die "Cancelled."; fi
    if n=$(normalize_upstream "$u"); then break; fi
    warn "Invalid upstream: $u (use host:port, http://host:port or https://host:port)"
    retry_or_die "Invalid upstream: $u"; u=""
  done
  S_UPSTREAM=$n
  if [[ -z $S_PRESERVE ]]; then
    local hdef=yes
    if [[ $n =~ ^https?://(127\.0\.0\.1|localhost|\[::1\])(:|$) ]]; then hdef=local
    elif [[ ! $n =~ ^https?://[0-9.]+(:|$) ]]; then hdef=no; fi   # a hostname: usually another website
    if [[ $hdef == local ]]; then S_PRESERVE=yes
    elif ui_yesno "Pass the visitor's Host header ($domain) to the upstream? Choose No if the upstream is another website." "$hdef"; then S_PRESERVE=yes
    else S_PRESERVE=no; fi
  fi
}

site_ask_pm() {
  if [[ -z $S_PM ]]; then
    local p2="PM2" sv="Supervisor"
    feat_has pm2 || p2="PM2 (will be installed)"
    feat_has supervisor || sv="Supervisor (will be installed)"
    S_PM=$(ui_menu "Process manager" "Keep the app running with:" \
      systemd    "systemd (recommended — built in, no extra daemon)" \
      pm2        "$p2" \
      supervisor "$sv") || die "Cancelled."
  fi
  in_list "$S_PM" systemd pm2 supervisor || die "Unknown process manager: $S_PM (use systemd, pm2 or supervisor)"
  case $S_PM in
    pm2)        ensure_feature node; ensure_feature pm2 ;;
    supervisor) ensure_feature supervisor ;;
  esac
}

# ── site add ─────────────────────────────────────────────────────────────────
site_add() {
  local domain="" aliases="" aliases_set=0 type="" php="" webroot="" webroot_set=0
  local want_db="" want_ssl="" want_redis="" engine="" want_workers=no repo="" branch=""
  S_NODE="" S_PRESET="" S_START="" S_START_SET=0 S_BUILD="" S_BUILD_SET=0 S_PM="" S_PORT=""
  S_FRAMEWORK="" S_SERVER="" S_MODULE="" S_MODULE_SET=0 S_WORKERS="" S_UPSTREAM="" S_WS="" S_PRESERVE=""
  S_PYVER="" S_PYVER_SET=0 S_CANON=""
  while (( $# )); do
    case $1 in
      --domain)       need_val "$@"; domain=$2; shift 2 ;;
      --aliases)      need_val "$@"; aliases=$2; aliases_set=1; shift 2 ;;
      --type)         need_val "$@"; type=$2; shift 2 ;;
      --php)          need_val "$@"; php=$2; shift 2 ;;
      --webroot)      need_val "$@"; webroot=$2; webroot_set=1; shift 2 ;;
      --node)         need_val "$@"; S_NODE=$2; shift 2 ;;
      --preset)       need_val "$@"; S_PRESET=$2; shift 2 ;;
      --start)        need_val "$@"; S_START=$2; S_START_SET=1; shift 2 ;;
      --build)        need_val "$@"; S_BUILD=$2; S_BUILD_SET=1; shift 2 ;;
      --pm)           need_val "$@"; S_PM=$2; shift 2 ;;
      --port)         need_val "$@"; S_PORT=$2; shift 2 ;;
      --framework)    need_val "$@"; S_FRAMEWORK=$2; shift 2 ;;
      --python)       need_val "$@"; S_PYVER=$2; S_PYVER_SET=1; shift 2 ;;
      --canonical)    S_CANON=yes; shift ;;
      --no-canonical) S_CANON=no; shift ;;
      --server)       need_val "$@"; S_SERVER=$2; shift 2 ;;
      --module)       need_val "$@"; S_MODULE=$2; S_MODULE_SET=1; shift 2 ;;
      --workers)      need_val "$@"; S_WORKERS=$2; shift 2 ;;
      --upstream)     need_val "$@"; S_UPSTREAM=$2; shift 2 ;;
      --websocket)    S_WS=yes; shift ;;
      --no-websocket) S_WS=no; shift ;;
      --db)           want_db=yes; shift ;;
      --no-db)        want_db=no; shift ;;
      --engine)       need_val "$@"; engine=$2; shift 2 ;;
      --pg|--pgsql|--postgres) engine=pgsql; shift ;;
      --mysql|--mariadb)       engine=mysql; shift ;;
      --redis)        want_redis=yes; shift ;;
      --no-redis)     want_redis=no; shift ;;
      --ssl)          want_ssl=yes; shift ;;
      --repo)         need_val "$@"; repo=$2; shift 2 ;;
      --branch)       need_val "$@"; branch=$2; shift 2 ;;
      --no-ssl)       want_ssl=no; shift ;;
      -*)             die "Unknown option: $1" ;;
      *)              domain=$1; shift ;;
    esac
  done
  if [[ -n $engine ]]; then
    engine=$(norm_engine "$engine") || die "Unknown database engine (use mysql or pgsql)"
    if [[ -z $want_db ]]; then want_db=yes; fi
  fi

  ensure_feature nginx

  # Domain
  domain=${domain,,}
  until valid_domain "$domain"; do
    if [[ -n $domain ]]; then warn "Invalid domain: $domain"; fi
    (( INTERACTIVE )) || die "A valid domain is required, e.g.: srv site add example.com --type static"
    domain=$(ui_input "Primary domain for the new site (e.g. example.com)" "") || die "Cancelled."
    domain=${domain,,}
  done
  if site_exists "$domain"; then die "Site $domain already exists (see: srv site info $domain)."; fi
  local owner
  if owner=$(domain_in_use "$domain"); then die "$domain is already an alias of site $owner."; fi

  # Aliases
  if (( ! aliases_set )); then
    local def_alias=""
    if [[ $domain =~ ^[^.]+\.[^.]+$ ]]; then def_alias="www.$domain"; fi
    aliases=$(ui_input "Extra domains / aliases, space-separated (blank = none)" "$def_alias" empty) || die "Cancelled."
  fi
  local -a alias_arr=(); local a
  read -ra alias_arr <<<"${aliases,,}"
  for a in "${alias_arr[@]}"; do
    valid_domain "$a" || die "Invalid alias: $a"
    [[ $a != "$domain" ]] || die "An alias can't be the same as the primary domain."
    if owner=$(domain_in_use "$a"); then die "$a is already used by site $owner."; fi
  done
  aliases="${alias_arr[*]}"
  if [[ -n $aliases && -z $S_CANON ]]; then
    if ui_yesno "Redirect $aliases to $domain, so the site has one address? (recommended)" yes; then S_CANON=yes; else S_CANON=no; fi
  fi

  # Type
  if [[ -z $type ]]; then
    type=$(ui_menu "New site: $domain" "Application type:" \
      static  "Static HTML site" \
      spa     "Single-page app (React/Vue/Angular build)" \
      php     "Generic PHP (WordPress, custom PHP …)" \
      laravel "Laravel application" \
      node    "Node.js app (Next.js, Nuxt, NestJS, Express …)" \
      python  "Python app (Django, Flask, FastAPI …)" \
      proxy   "Reverse proxy to another server / port / container") || die "Cancelled."
  fi
  case $type in static|spa|php|laravel|node|python|proxy) ;; *) die "Unknown type: $type (use static, spa, php, laravel, node, python or proxy)" ;; esac

  # PHP version
  if is_php_type "$type"; then
    ensure_feature php
    local -a vers=(); mapfile -t vers < <(php_versions)
    (( ${#vers[@]} )) || die "No PHP-FPM version found — run: srv install php"
    if [[ -n $php ]]; then
      in_list "$php" "${vers[@]}" || die "PHP $php isn't installed (installed: ${vers[*]}). Run: srv install php $php"
    elif (( ${#vers[@]} == 1 )); then
      php=${vers[0]}
    else
      local -a items=(); local v def; def=$(cfg_get PHP_DEFAULT "${vers[-1]}")
      if in_list "$def" "${vers[@]}"; then items+=("$def" "PHP $def (default)"); fi
      for v in "${vers[@]}"; do if [[ $v != "$def" ]]; then items+=("$v" "PHP $v"); fi; done
      php=$(ui_menu "PHP version" "PHP version for $domain:" "${items[@]}") || die "Cancelled."
    fi
  else
    php=""
  fi

  # Type-specific questions
  case $type in
    node)   site_ask_node ;;
    python) site_ask_python ;;
    proxy)  site_ask_proxy "$domain" ;;
  esac

  # Web root (sites Nginx serves files for)
  if ! is_proxy_type "$type"; then
    if (( ! webroot_set )); then
      local def_wr=""
      if [[ $type == laravel ]]; then def_wr=public; fi
      webroot=$(ui_input "Web root inside the app folder (blank = app folder itself; e.g. public, dist, build)" "$def_wr" empty) || die "Cancelled."
    fi
    webroot=${webroot#/}; webroot=${webroot%/}
    valid_relpath "$webroot" || die "Invalid web root: $webroot"
  else
    webroot=""
  fi

  # WebSockets, process manager, port
  if is_proxy_type "$type" && [[ -z $S_WS ]]; then
    local wsdef=yes
    if [[ $type == python && $S_FRAMEWORK != fastapi ]]; then wsdef=no; fi
    if ui_yesno "Enable WebSocket support (socket.io, live updates, Channels …)?" "$wsdef"; then S_WS=yes; else S_WS=no; fi
  fi
  if is_app_type "$type"; then
    site_ask_pm
    if [[ -n $S_PORT ]]; then
      S_PORT=$(dec "$S_PORT")
      valid_port "$S_PORT" || die "Port must be between 1024 and 65535."
      if port_used_by_site "$S_PORT"; then die "Port $S_PORT is already assigned to another site."; fi
      if port_in_use "$S_PORT"; then warn "Something is already listening on port $S_PORT."; fi
    else
      S_PORT=$(port_alloc) || die "No free port found."
    fi
  fi

  # Database
  if is_php_type "$type" || is_app_type "$type"; then
    if [[ -z $want_db ]]; then
      local dbdef=no; if [[ $type == laravel ]]; then dbdef=yes; fi
      if ui_yesno "Create a database for $domain?" "$dbdef"; then want_db=yes; else want_db=no; fi
    fi
    if [[ $want_db == yes ]]; then db_pick_engine "$engine" install; engine=$DB_ENG; fi
  else
    want_db=no
  fi

  # Redis
  if is_php_type "$type" || is_app_type "$type"; then
    if [[ -z $want_redis ]]; then
      if feat_has redis; then
        local rdef=no; if [[ $type == laravel ]]; then rdef=yes; fi
        if ui_yesno "Use Redis for $domain (cache, sessions, queues)?" "$rdef"; then want_redis=yes; else want_redis=no; fi
      else
        want_redis=no
      fi
    fi
    if [[ $want_redis == yes ]]; then ensure_feature redis; fi
  else
    want_redis=no
  fi

  # Deploy from git?
  if [[ -z $repo && $type != proxy ]] && (( INTERACTIVE && ! ASSUME_YES )); then
    if ui_yesno "Deploy this site from a git repository? (releases, rollback, auto-deploy)" no; then
      while true; do
        repo=$(ui_input "Git repository (git@github.com:you/app.git or https://…)" "") || die "Cancelled."
        if valid_repo "$repo"; then break; fi
        warn "That doesn't look like a git URL"
      done
    fi
  fi
  if [[ -n $repo ]]; then
    valid_repo "$repo" || die "Invalid repository URL: $repo"
    [[ $type != proxy ]] || die "Proxy sites don't deploy code."
  fi

  # Laravel queue workers / Horizon / Reverb
  if [[ $type == laravel ]] && (( INTERACTIVE && ! ASSUME_YES )); then
    if ui_yesno "Set up queue workers, Horizon or Reverb now? (runs under Supervisor)" no; then want_workers=yes; fi
  fi

  # SSL
  if [[ -z $want_ssl ]]; then
    local ssldef=no; if (( INTERACTIVE )) || feat_has certbot; then ssldef=yes; fi
    if ui_yesno "Issue a free Let's Encrypt certificate now? (the domain's DNS must already point to this server)" "$ssldef"; then want_ssl=yes; else want_ssl=no; fi
  fi
  if [[ $want_ssl == yes ]]; then ensure_feature certbot; fi

  # Confirm
  local user home app docroot
  user=$(site_user_for "$domain"); home="$WEB_ROOT/$domain"; app="$home/app"; docroot="$app${webroot:+/$webroot}"
  if (( INTERACTIVE && ! ASSUME_YES )); then
    local summary detail=""
    case $type in
      php|laravel) detail=$(printf 'PHP:         %s\nWeb root:    %s' "$php" "$docroot") ;;
      static|spa)  detail=$(printf 'Web root:    %s' "$docroot") ;;
      node)        detail=$(printf 'Node.js:     %s\nStart:       %s\nBuild:       %s\nPort:        %s\nManager:     %s' "$S_NODE" "$S_START" "${S_BUILD:-none}" "$S_PORT" "$S_PM") ;;
      python)      detail=$(printf 'Framework:   %s (%s, %s workers)\nModule:      %s\nPort:        %s\nManager:     %s' "$S_FRAMEWORK" "$S_SERVER" "$S_WORKERS" "${S_MODULE:-auto-detect}" "$S_PORT" "$S_PM") ;;
      proxy)       detail=$(printf 'Upstream:    %s' "$S_UPSTREAM") ;;
    esac
    summary=$(printf 'Domain:      %s\nAliases:     %s\nType:        %s\n%s\nLinux user:  %s\nDatabase:    %s\nRedis:       %s\nHTTPS:       %s' \
      "$domain" "${aliases:-none}" "$type" "$detail" "$user" \
      "$([[ $want_db == yes ]] && eng_label "$engine" || echo no)" "$want_redis" "$want_ssl")
    ui_yesno "Create this site?"$'\n\n'"$summary" yes || die "Cancelled."
    ui_clear
  fi

  # Create
  step "Creating site $domain"
  if [[ -d $home ]]; then warn "$home already exists — reusing it"; fi
  if ! id "$user" &>/dev/null; then
    if getent group "$user" >/dev/null; then   # left over from an earlier site with this name
      run useradd --home-dir "$home" --no-create-home --shell /bin/bash -g "$user" "$user" || die "Could not create user $user"
    else
      run useradd --home-dir "$home" --no-create-home --shell /bin/bash --user-group "$user" || die "Could not create user $user"
    fi
  fi
  mkdir -p "$app" "$home/logs" "$home/tmp"
  # Laravel and apps: keep app/ empty so the project can be cloned straight into it
  case $type in
    static|spa|php)
      mkdir -p "$docroot"
      if [[ -z $(ls -A "$docroot" 2>/dev/null) ]]; then site_placeholder "$docroot" "$type" "$domain"; fi ;;
  esac
  chown -R "$user:$user" "$home"
  chmod 750 "$home" "$app" "$home/logs"; chmod 700 "$home/tmp"
  run usermod -aG "$user" www-data   # Nginx may read (not write) the site's files

  {
    echo "# srv site config — managed by srv (change settings with: srv site set $domain KEY value)"
    echo "DOMAIN=$domain"
    echo "ALIASES=$aliases"
    echo "TYPE=$type"
    echo "SITE_USER=$user"
    echo "HOME_DIR=$home"
    echo "APP_DIR=$app"
    echo "SSL=no"
    echo "ENABLED=yes"
    echo "CANONICAL=${S_CANON:-no}"
    case $type in
      static|spa) echo "WEBROOT=$webroot" ;;
      php)        printf '%s\n' "PHP=$php" "WEBROOT=$webroot" ;;
      laravel)    printf '%s\n' "PHP=$php" "WEBROOT=$webroot" "QUEUE_WORKERS=0" "HORIZON=no" "REVERB=no" ;;
      node)       printf '%s\n' "NODE=$S_NODE" "PRESET=$S_PRESET" "START_CMD=$S_START" "BUILD_CMD=$S_BUILD" "INSTALL_CMD=" \
                                "PORT=$S_PORT" "PM=$S_PM" "APP_ACTIVE=no" "WEBSOCKET=$S_WS" "TIMEOUT=60" ;;
      python)     printf '%s\n' "PY_FRAMEWORK=$S_FRAMEWORK" "PY_SERVER=$S_SERVER" "PY_APP=$S_MODULE" "WORKERS=$S_WORKERS" "BUILD_CMD=" \
                                "PORT=$S_PORT" "PM=$S_PM" "APP_ACTIVE=no" "WEBSOCKET=$S_WS" "TIMEOUT=60"
                  echo "PY_VERSION=$S_PYVER"
                  if [[ $S_FRAMEWORK == django ]]; then printf '%s\n' "STATIC_DIR=staticfiles" "MEDIA_DIR=media"; fi ;;
      proxy)      printf '%s\n' "UPSTREAM=$S_UPSTREAM" "PRESERVE_HOST=$S_PRESERVE" "WEBSOCKET=$S_WS" "TIMEOUT=60" ;;
    esac
    if is_php_type "$type" || is_app_type "$type"; then printf '%s\n' "DB_ENGINE=" "DB_NAME=" "DB_USER=" "DB_PASS=" "REDIS=no"; fi
    echo "CREATED=$(date '+%F %T')"
  } >"$(site_file "$domain")"
  chmod 600 "$(site_file "$domain")"

  site_render_pool "$domain" || die "PHP-FPM pool setup failed — see $SRV_LOG. Clean up with: srv site remove $domain"
  if is_app_type "$type"; then app_render_launcher "$domain"; pm_write "$domain"; fi
  site_apply_nginx "$domain" || die "Nginx setup failed. Clean up with: srv site remove $domain"
  site_render_cron "$domain"
  ok "Nginx${php:+ + PHP-FPM $php}${S_PM:+ + $S_PM} configured"

  if [[ $want_db == yes ]]; then
    if site_create_db "$domain" "$engine"; then ok "$(eng_label "$engine") database $(site_get "$domain" DB_NAME) created"
    else warn "Database creation failed — create one later with: srv db create"; fi
  fi
  if [[ $want_redis == yes ]]; then
    site_set "$domain" REDIS yes
    if is_app_type "$type"; then site_set "$domain" REDIS_DB "$(redis_db_alloc)"; fi
  fi
  if is_app_type "$type"; then app_env_sync "$domain"; fi
  if [[ $want_ssl == yes ]]; then
    if ! ssl_issue "$domain" 0; then warn "HTTPS isn't enabled yet — fix DNS, then run: srv ssl add $domain"; fi
  fi
  if [[ $want_workers == yes ]]; then try site_workers "$domain"; fi
  if [[ -n $repo ]]; then site_set "$domain" REPO "$repo"; site_set "$domain" BRANCH "${branch:-main}"; fi
  site_summary "$domain"
  if [[ -n $repo ]]; then
    echo
    local -a dargs=("$domain" --repo "$repo"); if [[ -n $branch ]]; then dargs+=(--branch "$branch"); fi
    deploy_setup "${dargs[@]}"
  fi
}

site_summary() {
  local d=$1 scheme=http type user app home php dbn
  if [[ $(site_get "$d" SSL) == yes ]]; then scheme=https; fi
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); app=$(site_get "$d" APP_DIR)
  home=$(site_get "$d" HOME_DIR); php=$(site_get "$d" PHP); dbn=$(site_get "$d" DB_NAME)
  echo; hr
  printf '%s%s %s is ready%s\n' "$C_G" "$C_BOLD" "$d" "$C_0"
  hr
  printf '  %-13s %s\n' "URL" "$scheme://$d" "Type" "$type" "App folder" "$app" "Linux user" "$user"
  case $type in
    static|spa|php|laravel) printf '  %-13s %s\n' "Web root" "$(site_docroot "$d")" ;;
  esac
  if [[ -n $php ]]; then printf '  %-13s %s\n' "PHP" "$php  (pool: /etc/php/$php/fpm/pool.d/srv-$user.conf)"; fi
  case $type in
    node)
      printf '  %-13s %s\n' "Node.js" "$(site_get "$d" NODE) ($(node_full "$(site_get "$d" NODE)"))" \
        "Start" "$(site_get "$d" START_CMD)" "Build" "$(b=$(site_get "$d" BUILD_CMD); echo "${b:-none}")" \
        "Port" "127.0.0.1:$(site_get "$d" PORT)" "Manager" "$(site_get "$d" PM)" "Env file" "$home/app.env" ;;
    python)
      printf '  %-13s %s\n' "Framework" "$(site_get "$d" PY_FRAMEWORK) — $(site_get "$d" PY_SERVER), $(site_get "$d" WORKERS) workers" \
        "Module" "$(m=$(site_get "$d" PY_APP); echo "${m:-auto-detect <project>.wsgi}")" "Virtualenv" "$home/venv" \
        "Port" "127.0.0.1:$(site_get "$d" PORT)" "Manager" "$(site_get "$d" PM)" "Env file" "$home/app.env" ;;
    proxy)
      printf '  %-13s %s\n' "Upstream" "$(site_get "$d" UPSTREAM)" ;;
  esac
  printf '  %-13s %s\n' "Nginx" "/etc/nginx/sites-available/$d.conf" "Custom conf" "$NGINX_CUSTOM/$d/*.conf"
  if [[ -n $dbn ]]; then
    local eng; eng=$(site_get "$d" DB_ENGINE mysql)
    printf '  %-13s %s\n' "Database" "$(eng_label "$eng")" "DB name" "$dbn" "DB user" "$(site_get "$d" DB_USER)" \
      "DB password" "$(site_get "$d" DB_PASS)" "DB host" "127.0.0.1:$(eng_port "$eng")"
  fi
  if [[ $(site_get "$d" REDIS) == yes ]]; then printf '  %-13s %s\n' "Redis" "127.0.0.1:6379$( is_app_type "$type" && echo " (database $(site_get "$d" REDIS_DB 0))")"; fi
  echo
  echo " Next steps"
  if deploy_enabled "$d"; then
    echo "   •  Deploys from $(site_get "$d" REPO) ($(site_get "$d" BRANCH main))"
    echo "   •  Deploy again: srv deploy $d   ·   auto-deploy on push: srv deploy webhook $d on"
    if [[ $type == laravel ]]; then echo "   •  Queue workers / Horizon / Reverb:  srv site workers $d"; fi
    if [[ $scheme == http ]]; then echo "   •  Enable HTTPS once DNS points here:  srv ssl add $d"; fi
    return 0
  fi
  case $type in
    static|spa|php)
      echo "   1. Upload your files into $(site_docroot "$d")   (rsync, SFTP …)"
      echo "   2. srv site fix-perms $d"
      echo "   •  Or deploy from git:  srv deploy setup $d" ;;
    laravel)
      echo "   1. Upload your project into $app   (git clone, rsync, SFTP …)"
      echo "   2. srv site fix-perms $d"
      echo "   3. runuser -u $user -- env -C $app composer install --no-dev --optimize-autoloader"
      echo "   4. srv site apply-env $d      # APP_URL, DB, Redis, Reverb → .env (+ APP_KEY)"
      echo "   5. runuser -u $user -- env -C $app php$php artisan migrate --force"
      echo "   •  Or deploy from git instead of steps 1–5:  srv deploy setup $d"
      echo "   •  Queue workers / Horizon / Reverb:  srv site workers $d" ;;
    node|python)
      echo "   1. Upload your project into $app   (git clone, rsync, SFTP …)"
      echo "   2. Put your environment variables in $home/app.env"
      echo "   3. srv app build $d       # installs dependencies, builds and starts the app"
      echo "   4. srv app logs $d"
      echo "   •  Or deploy from git instead of steps 1 and 3:  srv deploy setup $d" ;;
    proxy)
      echo "   •  Requests to $d are forwarded to $(site_get "$d" UPSTREAM)" ;;
  esac
  if [[ $scheme == http ]]; then echo "   •  Enable HTTPS once DNS points here:  srv ssl add $d"; fi
}

# ── Other site commands ──────────────────────────────────────────────────────
site_list() {
  local d any=0 ssl days dbn
  printf '%s%-34s %-8s %-9s %-6s %-9s %s%s\n' "$C_BOLD" DOMAIN TYPE RUNTIME SSL STATUS DATABASE "$C_0"
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    any=1
    ssl=no
    if [[ $(site_get "$d" SSL) == yes ]]; then
      if days=$(cert_days_left "$d"); then ssl="${days}d"; else ssl=yes; fi
    fi
    dbn=$(site_get "$d" DB_NAME)
    if [[ -n $dbn && $(site_get "$d" DB_ENGINE) == pgsql ]]; then dbn="$dbn (pg)"; fi
    printf '%-34s %-8s %-9s %-6s %-9s %s\n' "$d" "$(site_get "$d" TYPE)" "$(site_runtime "$d")" "$ssl" \
      "$([[ $(site_get "$d" ENABLED yes) == yes ]] && echo enabled || echo disabled)" "$dbn"
  done < <(site_list_domains)
  if (( ! any )); then echo "  (no sites yet — create one with: srv site add)"; fi
}

site_info() {
  local d="" secrets=0 a line k
  for a in "$@"; do case $a in --secrets) secrets=1 ;; *) d=$a ;; esac; done
  d=$(resolve_domain "$d") || exit 1
  echo; printf '%s%s%s\n' "$C_BOLD" "$d" "$C_0"; hr
  while IFS= read -r line; do
    if [[ -z $line || $line == \#* ]]; then continue; fi
    k=${line%%=*}
    if [[ ( $k == DB_PASS || $k == WEBHOOK_SECRET ) && -n ${line#*=} && $secrets -eq 0 ]]; then line="$k=******** (show with --secrets)"; fi
    printf '  %-14s %s\n' "$k" "${line#*=}"
  done <"$(site_file "$d")"
  hr
  printf '  %-14s %s\n' "Nginx" "/etc/nginx/sites-available/$d.conf" "Custom" "$NGINX_CUSTOM/$d/*.conf" \
    "Logs" "/var/log/nginx/$d.{access,error}.log, $(site_get "$d" HOME_DIR)/logs/"
  if is_app_type "$(site_get "$d" TYPE)"; then
    printf '  %-14s %s\n' "Launcher" "$SRV_RUN/$d.sh" "Env file" "$(site_get "$d" HOME_DIR)/app.env" "State" "$(pm_state "$d")"
  fi
  if deploy_enabled "$d"; then
    local cur meta; cur=$(deploy_current "$d" || echo "none yet"); meta=$(deploy_meta "$d" "$cur")
    printf '  %-14s %s\n' "Live release" "$cur$( [[ -f $meta ]] && echo " — $(kv_get "$meta" COMMIT | cut -c1-10) $(kv_get "$meta" SUBJECT)")" \
      "Deploy log" "$(site_get "$d" HOME_DIR)/logs/deploy.log"
    if [[ $(site_get "$d" DEPLOY_WEBHOOK) == yes ]]; then printf '  %-14s %s\n' "Webhook" "$(webhook_url "$d")"; fi
  fi
  printf '  %-14s %s\n' "Maintenance" "$([[ -f $(site_get "$d" HOME_DIR)/.maintenance ]] && echo ON || echo off)"
  local days
  if days=$(cert_days_left "$d"); then printf '  %-14s %s\n' "Cert" "expires in $days days"; fi
}

site_enable() {
  local d; d=$(resolve_domain "${1:-}") || exit 1
  site_set "$d" ENABLED yes
  site_apply_nginx "$d" || die "Could not enable $d"
  ok "$d enabled"
}

site_disable() {
  local d; d=$(resolve_domain "${1:-}") || exit 1
  site_set "$d" ENABLED no
  rm -f "/etc/nginx/sites-enabled/$d.conf"
  nginx_reload || die "Nginx reload failed"
  ok "$d disabled (files, database, app process and config are kept)"
}

site_rebuild() {
  local -a list=(); local d failed=0
  if [[ ${1:-} == --all ]]; then
    mapfile -t list < <(site_list_domains)
    (( ${#list[@]} )) || { info "No sites."; return 0; }
  else
    d=$(resolve_domain "${1:-}") || exit 1
    list=("$d")
  fi
  for d in "${list[@]}"; do
    info "Rebuilding $d"
    if site_render_pool "$d" && site_apply_nginx "$d"; then
      site_render_cron "$d"
      cron_render "$d"
      try site_render_processes "$d"
      if (( TRY_RC == 0 )); then ok "$d rebuilt"; else err "$d: process config failed"; failed=1; fi
    else
      err "$d failed"; failed=1
    fi
  done
  if (( failed )); then return 1; fi
}

# Re-render launcher + process-manager config (restart if running) and Laravel workers
site_render_processes() {
  local d=$1 type; type=$(site_get "$d" TYPE)
  if is_app_type "$type"; then
    app_render_launcher "$d"
    pm_write "$d"
    if [[ $(site_get "$d" APP_ACTIVE) == yes ]]; then pm_start "$d" && { app_wait "$d" || true; }; fi
  elif [[ $type == laravel ]] && { [[ -f $(laravel_conf "$d") ]] || (( $(site_get "$d" QUEUE_WORKERS 0) > 0 )); }; then
    laravel_render_workers "$d"
  fi
}

site_set_cmd() {
  local d=${1:-} k=${2:-} type allowed
  local -a _vers=()
  [[ -n $d && -n $k && $# -ge 3 ]] || die "Usage: srv site set <domain> <KEY> <value>   (see editable keys with: srv site set <domain> help x)"
  local v=$3
  d=$(resolve_domain "$d") || exit 1
  type=$(site_get "$d" TYPE); k=${k^^}
  case $type in
    static|spa)  allowed="WEBROOT" ;;
    php|laravel) allowed="WEBROOT PHP" ;;
    node)        allowed="START_CMD BUILD_CMD INSTALL_CMD NODE PORT TIMEOUT WEBSOCKET MAX_BODY" ;;
    python)      allowed="PY_APP PY_SERVER PY_VERSION WORKERS BUILD_CMD PORT TIMEOUT WEBSOCKET MAX_BODY STATIC_DIR MEDIA_DIR" ;;
    proxy)       allowed="UPSTREAM PRESERVE_HOST TIMEOUT WEBSOCKET MAX_BODY" ;;
  esac
  local deploy_keys="BRANCH DEPLOY_SHARED_DIRS DEPLOY_SHARED_FILES DEPLOY_BUILD DEPLOY_AFTER DEPLOY_KEEP DEPLOY_MIGRATE DEPLOY_COMPOSER DEPLOY_NPM DEPLOY_OPTIMIZE DEPLOY_HEALTH_PATH DEPLOY_AUTO_ROLLBACK"
  if [[ $type != proxy ]]; then allowed="$allowed $deploy_keys"; fi
  allowed="$allowed CANONICAL"
  # shellcheck disable=SC2086
  in_list "$k" $allowed || die "Editable keys for $type sites: $allowed"
  [[ $v != *$'\n'* ]] || die "The value must be a single line."
  case $k in WORKERS|TIMEOUT|DEPLOY_KEEP|PORT) v=$(dec "$v") ;; esac
  case $k in
    START_CMD)   [[ -n $v ]] || die "The start command can't be empty." ;;
    PY_APP)      [[ -z $v || $v =~ ^[A-Za-z0-9_.]+:[A-Za-z0-9_.()]+$ ]] || die "Invalid module (e.g. main:app)" ;;
    PY_SERVER)   in_list "$v" gunicorn uvicorn || die "Use gunicorn or uvicorn" ;;
    WORKERS)     [[ $v =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 64 )) || die "Workers must be 1–64" ;;
    TIMEOUT)     [[ $v =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 86400 )) || die "Timeout is in seconds (1–86400)" ;;
    WEBSOCKET|PRESERVE_HOST) in_list "$v" yes no || die "Use yes or no" ;;
    MAX_BODY)    [[ -z $v || $v =~ ^[0-9]+[kKmMgG]?$ ]] || die "Use a size like 100m" ;;
    UPSTREAM)    v=$(normalize_upstream "$v") || die "Invalid upstream (host:port or http(s)://host:port)" ;;
    WEBROOT|STATIC_DIR|MEDIA_DIR) v=${v#/}; v=${v%/}; valid_relpath "$v" || die "Invalid path" ;;
    PHP)         mapfile -t _vers < <(php_versions); in_list "$v" "${_vers[@]}" || die "PHP $v isn't installed (installed: $(php_versions | tr '\n' ' '))" ;;
    NODE)        mapfile -t _vers < <(node_versions); in_list "$v" "${_vers[@]}" || die "Node $v isn't installed (installed: $(node_versions | tr '\n' ' '))" ;;
    PORT)        valid_port "$v" || die "Port must be 1024–65535"
                 if [[ $v != "$(site_get "$d" PORT)" ]] && port_used_by_site "$v"; then die "Port $v is assigned to another site"; fi ;;
    BRANCH)      valid_ref "$v" || die "Invalid branch name" ;;
    DEPLOY_SHARED_DIRS|DEPLOY_SHARED_FILES)
                 local x; for x in $v; do valid_relpath "$x" && [[ $x != /* && $x != . ]] || die "Invalid path: $x"; done ;;
    DEPLOY_KEEP) [[ $v =~ ^[0-9]+$ ]] && (( v >= 2 && v <= 50 )) || die "Keep 2–50 releases" ;;
    DEPLOY_MIGRATE|DEPLOY_COMPOSER|DEPLOY_NPM|DEPLOY_OPTIMIZE|DEPLOY_AUTO_ROLLBACK) in_list "$v" yes no || die "Use yes or no" ;;
    DEPLOY_HEALTH_PATH) [[ $v =~ ^/[^[:space:]]*$ ]] || die "Use a path like / or /health" ;;
    CANONICAL)   in_list "$v" yes no || die "Use yes or no" ;;
    PY_VERSION)  if [[ $v == system ]]; then v=""; fi
                 if [[ -n $v ]]; then mapfile -t _vers < <(py_versions); in_list "$v" "${_vers[@]}" || die "Python $v isn't installed (srv python install $v)"; fi ;;
  esac
  site_set "$d" "$k" "$v"
  ok "$d: $k=$v"
  case $k in
    BRANCH)   if [[ $(site_get "$d" DEPLOY_WEBHOOK) == yes ]]; then webhook_write_secret "$d"; fi ;;
    PY_VERSION) info "Rebuild the virtualenv to switch: $( [[ $(site_get "$d" DEPLOY) == yes ]] && echo "srv deploy $d" || echo "srv app build $d")" ;;
    DEPLOY_*) ;;   # used by the next deploy — nothing to rebuild
    *)        site_rebuild "$d" ;;
  esac
}

site_fix_perms() {
  local d user home app
  d=$(resolve_domain "${1:-}") || exit 1
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR)
  step "Fixing ownership & permissions for $d"
  mkdir -p "$home/logs" "$home/tmp"
  run chown -R "$user:$user" "$home"
  run chmod 750 "$home" "$home/logs"
  run chmod 700 "$home/tmp"
  local -a dirs=("$app")
  if [[ $(site_get "$d" DEPLOY) == yes ]]; then dirs=("$home/releases" "$home/shared"); fi
  local x
  for x in "${dirs[@]}"; do
    if [[ -d $x ]]; then
      run chmod 750 "$x"
      # Owner read/write; group (Nginx) read-only; others nothing. Keeps exec bits.
      run chmod -R u+rwX,g+rX,g-w,o-rwx "$x"
    fi
  done
  local f
  for f in "$app/.env" "$home/shared/.env" "$home/app.env"; do if [[ -f $f ]]; then run chmod 600 "$f"; fi; done
  ok "Owner $user (read/write), Nginx read-only, others no access"
}

laravel_env_file() {   # where the site's .env lives
  local home; home=$(site_get "$1" HOME_DIR)
  if [[ $(site_get "$1" DEPLOY) == yes && -e $home/shared/.env ]]; then printf '%s/shared/.env' "$home"
  else printf '%s/.env' "$(site_get "$1" APP_DIR)"; fi
}

site_apply_env() {
  local d type user app php env
  d=$(resolve_domain "${1:-}") || exit 1
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); app=$(site_get "$d" APP_DIR); php=$(site_get "$d" PHP)
  if is_app_type "$type"; then
    app_env_sync "$d"
    ok "$(site_get "$d" HOME_DIR)/app.env updated — restart to apply: srv app restart $d"
    return 0
  fi
  is_php_type "$type" || die "apply-env is for PHP, Laravel, Node.js and Python sites."
  env=$(laravel_env_file "$d")
  if [[ ! -f $env ]]; then
    if [[ -f $app/.env.example ]]; then cp "$app/.env.example" "$env"; info "Created .env from .env.example"
    else die "No $env or .env.example found — upload your project first."; fi
  fi
  laravel_env_write "$d" "$env"
  if [[ $type == laravel && -f $app/artisan && -f $app/vendor/autoload.php ]] && ! grep -qE '^APP_KEY=.+' "$env"; then
    run runuser -u "$user" -- env -C "$app" "/usr/bin/php$php" artisan key:generate --force && ok "APP_KEY generated"
  fi
  if [[ $type == laravel && -f $(laravel_conf "$d") ]]; then info "Restart workers to load it: srv app restart $d"; fi
}

# Write APP_URL, DB, Redis and Reverb settings into a Laravel/PHP .env file
laravel_env_write() {
  local d=$1 env=$2 type user dbn scheme=http eng port
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); dbn=$(site_get "$d" DB_NAME)
  if [[ $(site_get "$d" SSL) == yes ]]; then scheme=https; fi
  local -a written=(APP_URL)
  env_set "$env" APP_URL "$scheme://$d"
  if [[ -n $dbn ]]; then
    eng=$(site_get "$d" DB_ENGINE mysql); port=$(eng_port "$eng")
    env_set "$env" DB_CONNECTION "$eng"
    env_set "$env" DB_HOST 127.0.0.1
    env_set "$env" DB_PORT "$port"
    env_set "$env" DB_DATABASE "$dbn"
    env_set "$env" DB_USERNAME "$(site_get "$d" DB_USER)"
    env_set "$env" DB_PASSWORD "$(site_get "$d" DB_PASS)"
    written+=("DB_* ($eng)")
  fi
  if [[ $(site_get "$d" REDIS) == yes ]] && feat_has redis; then
    env_set "$env" REDIS_CLIENT phpredis
    env_set "$env" REDIS_HOST 127.0.0.1
    env_set "$env" REDIS_PASSWORD "$(cfg_get REDIS_PASSWORD)"
    env_set "$env" REDIS_PORT 6379
    env_set "$env" REDIS_PREFIX "${user}_"           # keeps sites apart in the shared Redis
    env_set "$env" CACHE_PREFIX "${user}_cache_"
    env_set "$env" CACHE_STORE redis
    if grep -qE '^CACHE_DRIVER=' "$env"; then env_set "$env" CACHE_DRIVER redis; fi
    env_set "$env" SESSION_DRIVER redis
    env_set "$env" QUEUE_CONNECTION redis
    written+=("REDIS_* + cache/session/queue → redis")
    if [[ $(site_get "$d" HORIZON) == yes ]]; then env_set "$env" HORIZON_PREFIX "${user}_horizon:"; fi
  fi
  if [[ $type == laravel && $(site_get "$d" REVERB) == yes ]]; then
    env_set "$env" BROADCAST_CONNECTION reverb
    if [[ -z $(env_get "$env" REVERB_APP_ID) ]];     then env_set "$env" REVERB_APP_ID "$(( (RANDOM << 15 | RANDOM) % 900000 + 100000 ))"; fi
    if [[ -z $(env_get "$env" REVERB_APP_KEY) ]];    then env_set "$env" REVERB_APP_KEY "$(gen_password 20 | tr '[:upper:]' '[:lower:]')"; fi
    if [[ -z $(env_get "$env" REVERB_APP_SECRET) ]]; then env_set "$env" REVERB_APP_SECRET "$(gen_password 20 | tr '[:upper:]' '[:lower:]')"; fi
    env_set "$env" REVERB_SERVER_HOST 127.0.0.1
    env_set "$env" REVERB_SERVER_PORT "$(site_get "$d" REVERB_PORT)"
    env_set "$env" REVERB_HOST "$d"
    env_set "$env" REVERB_PORT "$([[ $scheme == https ]] && echo 443 || echo 80)"
    env_set "$env" REVERB_SCHEME "$scheme"
    written+=("REVERB_*")
  fi
  chown "$user:$user" "$env"; chmod 600 "$env"
  ok ".env updated for $d: ${written[*]}"
}

site_redis() {
  local d=${1:-} mode=${2:-} type
  d=$(resolve_domain "$d") || exit 1
  type=$(site_get "$d" TYPE)
  is_php_type "$type" || is_app_type "$type" || die "Redis is for PHP, Laravel, Node.js and Python sites."
  if [[ -z $mode ]]; then
    if (( INTERACTIVE )); then
      if ui_yesno "Use Redis for $d?" "$(site_get "$d" REDIS no)"; then mode=on; else mode=off; fi
    else
      echo "Redis for $d: $(site_get "$d" REDIS no)"; return 0
    fi
  fi
  case $mode in
    on|yes)
      ensure_feature redis
      site_set "$d" REDIS yes
      if is_app_type "$type" && [[ -z $(site_get "$d" REDIS_DB) ]]; then site_set "$d" REDIS_DB "$(redis_db_alloc)"; fi
      ok "Redis enabled for $d" ;;
    off|no)
      site_set "$d" REDIS no
      ok "Redis disabled for $d" ;;
    *) die "Usage: srv site redis <domain> on|off" ;;
  esac
  if is_app_type "$type"; then app_env_sync "$d"; info "REDIS_URL updated in app.env — restart to apply: srv app restart $d"
  else info "Write it into .env with: srv site apply-env $d"; fi
}

site_maintenance() {
  local d="" mode="" allow="" allow_set=0 ip home
  while (( $# )); do
    case $1 in
      --allow) need_val "$@"; allow=$2; allow_set=1; shift 2 ;;
      on|off|status) mode=$1; shift ;;
      -*) die "Unknown option: $1" ;;
      *)  d=$1; shift ;;
    esac
  done
  d=$(resolve_domain "$d") || exit 1
  home=$(site_get "$d" HOME_DIR)
  if [[ -z $mode ]]; then
    if (( INTERACTIVE )); then
      mode=$(ui_menu "Maintenance: $d" "Maintenance mode is $([[ -f $home/.maintenance ]] && echo ON || echo off):" \
        on "Turn on (visitors get a 503 page)" off "Turn off" status "Show status") || die "Cancelled."
    else mode=status; fi
  fi
  if (( allow_set )); then
    for ip in $allow; do [[ $ip =~ ^[0-9A-Fa-f:.]+$ ]] || die "Invalid IP address: $ip"; done
    site_set "$d" MAINT_ALLOW "$allow"
  fi
  if (( allow_set )) || ! grep -qs '__srv_maintenance' "/etc/nginx/sites-available/$d.conf"; then
    site_apply_nginx "$d" || die "Nginx update failed"
  fi
  case $mode in
    on)  touch "$home/.maintenance"
         ok "Maintenance mode ON for $d$( [[ -n $(site_get "$d" MAINT_ALLOW) ]] && echo " (still open for: $(site_get "$d" MAINT_ALLOW))")"
         info "Page shown: $SRV_WWW/maintenance.html (edit it to customise)" ;;
    off) rm -f "${home:?}/.maintenance"; ok "Maintenance mode off for $d" ;;
    status)
      echo "$d: maintenance $([[ -f $home/.maintenance ]] && echo ON || echo off)$( [[ -n $(site_get "$d" MAINT_ALLOW) ]] && echo " · allowed IPs: $(site_get "$d" MAINT_ALLOW)")" ;;
  esac
}

site_logs() {
  local d=${1:-} kind=${2:-} f home
  d=$(resolve_domain "$d") || exit 1
  home=$(site_get "$d" HOME_DIR)
  if [[ -z $kind ]]; then if is_app_type "$(site_get "$d" TYPE)"; then kind=app; else kind=error; fi; fi
  case $kind in
    error)   f=/var/log/nginx/$d.error.log ;;
    access)  f=/var/log/nginx/$d.access.log ;;
    php)     f=$home/logs/php-error.log ;;
    laravel) f=$(site_get "$d" APP_DIR)/storage/logs/laravel.log ;;
    app)     f=$home/logs/app.log ;;
    queue|horizon|reverb|deploy) f=$home/logs/$kind.log ;;
    *) die "Log type must be one of: error, access, php, laravel, app, queue, horizon, reverb, deploy" ;;
  esac
  [[ -f $f ]] || die "No log yet: $f"
  if (( MENU_MODE )); then tail -n 100 "$f"; else exec tail -n 100 -f "$f"; fi
}

site_remove() {
  local d="" purge=0 a
  for a in "$@"; do case $a in --purge) purge=1 ;; *) d=$a ;; esac; done
  d=$(resolve_domain "$d") || exit 1
  local user home dbn dbu eng type
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); type=$(site_get "$d" TYPE)
  dbn=$(site_get "$d" DB_NAME); dbu=$(site_get "$d" DB_USER); eng=$(site_get "$d" DB_ENGINE mysql)

  if (( INTERACTIVE && ! ASSUME_YES )); then
    local typed
    typed=$(ui_input "Type the domain to confirm removing $d" "") || die "Cancelled."
    [[ $typed == "$d" ]] || die "Confirmation didn't match — nothing was removed."
  elif (( ! ASSUME_YES )); then
    die "Refusing to remove without --yes in non-interactive mode."
  fi

  local del_files=no del_db=no del_cert=no
  if (( purge )); then
    del_files=yes; del_db=yes; del_cert=yes
  elif (( INTERACTIVE && ! ASSUME_YES )); then
    if ui_yesno "Delete the site's files in $home?" no; then del_files=yes; fi
    if [[ -n $dbn ]] && ui_yesno "Drop $(eng_label "$eng") database '$dbn' and user '$dbu'?" no; then del_db=yes; fi
    if [[ -d /etc/letsencrypt/live/$d ]] && ui_yesno "Delete the SSL certificate?" yes; then del_cert=yes; fi
  fi

  step "Removing $d"
  # Processes first, so nothing keeps running against removed config
  if is_app_type "$type"; then pm_remove "$d" "$(site_get "$d" PM systemd)"; fi
  local lconf; lconf=$(laravel_conf "$d")
  if [[ -f $lconf ]]; then
    supervisorctl stop "srv-$user-laravel:*" >>"$SRV_LOG" 2>&1 || true
    rm -f "$lconf"; sv_update || true
  fi
  rm -f "${SRV_RUN:?}/${d:?}.sh" "${SRV_RUN:?}/${d:?}.pm2.config.js" "${HOOKS_DIR:?}/${d:?}.json" "${DEPLOY_QUEUE:?}/${d:?}"
  rm -rf "${SRV_DIR:?}/releases/${d:?}"

  rm -f "/etc/nginx/sites-enabled/$d.conf" "/etc/nginx/sites-available/$d.conf"
  rm -rf "${NGINX_CUSTOM:?}/$d"
  nginx_reload || warn "Nginx reload failed — check: nginx -t"
  local f v
  for f in /etc/php/*/fpm/pool.d/srv-"$user".conf; do
    [[ -f $f ]] || continue
    v=${f#/etc/php/}; v=${v%%/*}
    rm -f "$f"; run systemctl reload "php$v-fpm" || true
  done
  rm -f "/etc/cron.d/srv-$user" "/etc/cron.d/srv-$user-jobs" "$(cron_store "$d")"
  if [[ $(cfg_get TOOLS_HOST) == "$d" ]]; then
    cfg_set TOOLS_HOST _
    if feat_has dbadmin; then nginx_write_default && nginx_reload || true; warn "The database tools moved to the server IP — choose a new host: srv tools host <domain>"; fi
  fi

  if [[ $del_db == yes && -n $dbn ]]; then
    if eng_drop_db "$eng" "$dbn"; then
      ok "Database $dbn dropped"
      if [[ -n $dbu ]]; then eng_drop_user "$eng" "$dbu" || warn "Couldn't drop user $dbu"; fi
    else warn "Couldn't drop database $dbn"; fi
  fi
  if [[ $del_cert == yes && -d /etc/letsencrypt/live/$d ]]; then
    run certbot delete --cert-name "$d" --non-interactive || warn "Couldn't delete the certificate"
  fi
  if [[ $del_files == yes ]]; then
    if [[ $home == "$WEB_ROOT"/?* && $home != *..* && $home != "$ACME_ROOT" ]]; then
      pkill -u "$user" 2>/dev/null || true
      sleep 1
      rm -rf "$home"
      rm -f "/var/log/nginx/$d."*.log*
      userdel "$user" >>"$SRV_LOG" 2>&1 || warn "Couldn't delete user $user"
      gpasswd -d www-data "$user" >>"$SRV_LOG" 2>&1 || true
      groupdel "$user" >>"$SRV_LOG" 2>&1 || true
      ok "Files and user $user deleted"
    else
      warn "Unexpected home path ($home) — files NOT deleted"
    fi
  else
    info "Files kept in $home (owner: $user)"
  fi
  rm -f "$(site_file "$d")"
  ok "Site $d removed"
}

cmd_site() {
  local sub=${1:-}; shift || true
  case $sub in
    add|new)          site_add "$@" ;;
    list|ls)          site_list ;;
    info|show)        site_info "$@" ;;
    set)              site_set_cmd "$@" ;;
    enable)           site_enable "${1:-}" ;;
    disable)          site_disable "${1:-}" ;;
    rebuild)          site_rebuild "${1:-}" ;;
    fix-perms|perms)  site_fix_perms "${1:-}" ;;
    apply-env|env)    site_apply_env "${1:-}" ;;
    workers)          site_workers "$@" ;;
    redis)            site_redis "$@" ;;
    maintenance|maint) site_maintenance "$@" ;;
    rollback)         deploy_rollback "$@" ;;
    logs|log)         site_logs "$@" ;;
    remove|rm|delete) site_remove "$@" ;;
    ""|menu)          menu_sites ;;
    *) die "Unknown site command: $sub (see: srv help)" ;;
  esac
}

# =============================================================================
#  APPS — Node.js / Python processes under systemd, PM2 or Supervisor
#
#  Each app has a launcher, /opt/srv/run/<domain>.sh, that sets PATH, PORT,
#  HOST, loads <home>/app.env and execs the start command. All three process
#  managers run that same launcher as the site's own Linux user, and write the
#  output to <home>/logs/app.log.
# =============================================================================
app_pm()   { site_get "$1" PM systemd; }
app_unit() { printf 'srv-%s' "$(site_get "$1" SITE_USER)"; }

# Python virtualenv: per release (.venv) for git deploys, otherwise <home>/venv
app_venv() {
  if [[ $(site_get "$1" DEPLOY) == yes ]]; then printf '%s/.venv' "$(site_get "$1" APP_DIR)"
  else printf '%s/venv' "$(site_get "$1" HOME_DIR)"; fi
}

node_default_bin() {
  local m; m=$(cfg_get NODE_DEFAULT)
  if [[ -n $m && -x $NODE_ROOT/$m/bin/node ]]; then printf '%s/%s/bin' "$NODE_ROOT" "$m"; fi
}

# app_path <domain> [venv]  → PATH for the site's commands
app_path() {
  local d=$1 venv=${2:-} base=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin nb
  case $(site_get "$d" TYPE) in
    node)   printf '%s/%s/bin:%s' "$NODE_ROOT" "$(site_get "$d" NODE)" "$base" ;;
    python) printf '%s/bin:%s' "${venv:-$(app_venv "$d")}" "$base" ;;
    *)      nb=$(node_default_bin); printf '%s%s' "${nb:+$nb:}" "$base" ;;   # PHP/static builds may need npm
  esac
}

py_detect_module() {   # Django: find <project>/wsgi.py next to manage.py
  local app=$1 f
  f=$(find -H "$app" -mindepth 2 -maxdepth 2 -name wsgi.py -print -quit 2>/dev/null) || true
  [[ -n $f ]] || return 1
  printf '%s.wsgi:application' "$(basename "$(dirname "$f")")"
}

app_command() {
  local d=$1 port mod server w
  port=$(site_get "$d" PORT)
  if [[ $(site_get "$d" TYPE) == node ]]; then site_get "$d" START_CMD "npm start"; return 0; fi
  server=$(site_get "$d" PY_SERVER gunicorn); w=$(site_get "$d" WORKERS 2); mod=$(site_get "$d" PY_APP)
  if [[ -z $mod && $(site_get "$d" PY_FRAMEWORK) == django ]]; then
    mod=$(py_detect_module "$(site_get "$d" APP_DIR)") || mod=""
    if [[ -n $mod && $server == uvicorn ]]; then mod=${mod/.wsgi:/.asgi:}; fi
  fi
  if [[ -z $mod ]]; then
    printf "echo 'srv: no app module found for %s — set one with: srv site set %s PY_APP project.wsgi:application' >&2; sleep 30; exit 1" "$d" "$d"
    return 0
  fi
  if [[ $server == uvicorn ]]; then
    printf "uvicorn '%s' --host 127.0.0.1 --port %s --workers %s --proxy-headers --forwarded-allow-ips 127.0.0.1" "$mod" "$port" "$w"
  else
    printf "gunicorn --bind 127.0.0.1:%s --workers %s --timeout %s --forwarded-allow-ips 127.0.0.1 --access-logfile - --error-logfile - '%s'" \
      "$port" "$w" "$(site_get "$d" TIMEOUT 60)" "$mod"
  fi
}

app_render_launcher() {
  local d=$1 type home app port extra
  type=$(site_get "$d" TYPE); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR); port=$(site_get "$d" PORT)
  extra="PYTHONUNBUFFERED=1"; if [[ $type == node ]]; then extra="NODE_ENV=production"; fi
  install -d -m 755 "$SRV_RUN"
  cat >"$SRV_RUN/$d.sh" <<EOF
#!/bin/bash
# Managed by srv — regenerated by 'srv site rebuild $d'. Don't edit:
# change settings with 'srv site set $d KEY value' and put environment
# variables in $home/app.env (KEY=value per line, shell syntax).
set -a
HOME=$home
PATH=$(app_path "$d")
$extra
if [ -f $home/app.env ]; then . $home/app.env; fi
PORT=$port
HOST=127.0.0.1
set +a
cd $app || exit 1
exec $(app_command "$d")
EOF
  chmod 755 "$SRV_RUN/$d.sh"
}

# app_exec <domain> <command> [dir] [PATH] — run a shell command as the site
# user (default dir: the app folder), with <home>/app.env loaded.
app_exec() {
  local d=$1 cmd=$2 dir=${3:-} path=${4:-} user home app rc=0
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=${dir:-$(site_get "$d" APP_DIR)}
  if [[ -z $path ]]; then path=$(app_path "$d"); fi
  log "EXEC  [$d] $cmd"
  runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" LANG=C.UTF-8 TERM=dumb \
      PATH="$path" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 npm_config_update_notifier=false COMPOSER_HOME="$home/.composer" \
      npm_config_fund=false PIP_DISABLE_PIP_VERSION_CHECK=1 \
      bash -c 'set -a; if [ -f "$HOME/app.env" ]; then . "$HOME/app.env"; fi; set +a; cd "$1" && eval "$2"' srv-exec "$app" "$cmd" 9>&- 2>&1 \
    | tee -a "$SRV_LOG" | sed 's/^/     │ /' >&2 || rc=$?
  return "$rc"
}

node_install_cmd() {
  local a=$1
  if   [[ -f $a/pnpm-lock.yaml ]]; then echo "pnpm install --frozen-lockfile"
  elif [[ -f $a/yarn.lock ]]; then echo "yarn install"
  elif [[ -f $a/package-lock.json || -f $a/npm-shrinkwrap.json ]]; then echo "npm ci --include=dev"
  else echo "npm install --include=dev"; fi
}

sv_update() { run supervisorctl reread && run supervisorctl update; }

# ── PM2 (one PM2 daemon per site user, started at boot by pm2-<user>.service)
pm2_as() {
  local d=$1; shift
  local user home; user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR)
  runuser -u "$user" -- env -i HOME="$home" USER="$user" PATH="/usr/local/bin:/usr/bin:/bin" PM2_HOME="$home/.pm2" /usr/local/bin/pm2 "$@" 9>&-
}
pm2_alive() {
  local pidf pid; pidf="$(site_get "$1" HOME_DIR)/.pm2/pm2.pid"
  [[ -f $pidf ]] || return 1
  pid=$(<"$pidf"); [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}
pm2_write_unit() {
  local d=$1 user home; user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR)
  cat >"/etc/systemd/system/pm2-$user.service" <<EOF
# Managed by srv — restores $d's PM2 processes at boot
[Unit]
Description=PM2 for $d (user $user)
After=network.target

[Service]
Type=forking
User=$user
LimitNOFILE=65535
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=HOME=$home
Environment=PM2_HOME=$home/.pm2
PIDFile=$home/.pm2/pm2.pid
Restart=on-failure
ExecStart=/usr/local/bin/pm2 resurrect
ExecReload=/usr/local/bin/pm2 reload all
ExecStop=/usr/local/bin/pm2 kill

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
}

# Write the process-manager config (does not start anything)
pm_write() {
  local d=$1 pm user home app unit
  pm=$(app_pm "$d"); user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR)
  unit=$(app_unit "$d")
  install -d -m 750 -o "$user" -g "$user" "$home/logs"
  touch "$home/logs/app.log"; chown "$user:$user" "$home/logs/app.log"
  case $pm in
    systemd)
      cat >"/etc/systemd/system/$unit.service" <<EOF
# Managed by srv — app process for $d (srv app start|stop|restart $d)
[Unit]
Description=srv app $d
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=$user
Group=$user
WorkingDirectory=$app
ExecStart=$SRV_RUN/$d.sh
Restart=always
RestartSec=3
KillMode=mixed
TimeoutStopSec=30
StandardOutput=append:$home/logs/app.log
StandardError=append:$home/logs/app.log
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
      run systemctl daemon-reload ;;
    supervisor)
      local autostart=false
      if [[ $(site_get "$d" APP_ACTIVE) == yes ]]; then autostart=true; fi
      cat >"/etc/supervisor/conf.d/$unit.conf" <<EOF
; Managed by srv — app process for $d (srv app start|stop|restart $d)
[program:$unit]
command=$SRV_RUN/$d.sh
directory=$app
user=$user
autostart=$autostart
autorestart=true
startsecs=3
startretries=5
stopwaitsecs=30
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=$home/logs/app.log
stdout_logfile_maxbytes=0
environment=HOME="$home",USER="$user"
EOF
      ;;
    pm2)
      cat >"$SRV_RUN/$d.pm2.config.js" <<EOF
// Managed by srv — PM2 config for $d (srv app start|stop|restart $d)
module.exports = {
  apps: [{
    name: "$d",
    script: "$SRV_RUN/$d.sh",
    interpreter: "none",
    cwd: "$app",
    out_file: "$home/logs/app.log",
    error_file: "$home/logs/app.log",
    merge_logs: true,
    time: true,
    autorestart: true,
    restart_delay: 3000,
    max_restarts: 15,
    kill_timeout: 10000
  }]
};
EOF
      chmod 644 "$SRV_RUN/$d.pm2.config.js"
      pm2_write_unit "$d" ;;
  esac
}

# Start, or restart with the latest config
pm_start() {
  local d=$1 unit; unit=$(app_unit "$d")
  case $(app_pm "$d") in
    systemd)
      run systemctl enable "$unit.service" && run systemctl restart "$unit.service" ;;
    supervisor)
      sv_update || return 1
      supervisorctl stop "$unit" >>"$SRV_LOG" 2>&1 || true
      run supervisorctl start "$unit" ;;
    pm2)
      run systemctl enable "pm2-$(site_get "$d" SITE_USER).service" || true
      run pm2_as "$d" startOrRestart "$SRV_RUN/$d.pm2.config.js" && run pm2_as "$d" save --force ;;
  esac
}

pm_stop() {
  local d=$1 unit; unit=$(app_unit "$d")
  case $(app_pm "$d") in
    systemd)    run systemctl disable --now "$unit.service" ;;
    supervisor) supervisorctl stop "$unit" >>"$SRV_LOG" 2>&1 || true; sv_update ;;
    pm2)
      if pm2_alive "$d"; then
        pm2_as "$d" delete "$d" >>"$SRV_LOG" 2>&1 || true
        run pm2_as "$d" save --force
      fi ;;
  esac
}

pm_state() {
  local d=$1 unit s pid; unit=$(app_unit "$d")
  case $(app_pm "$d") in
    systemd)
      s=$(svc_state "$unit.service")
      case $s in active) echo running ;; inactive|"") echo stopped ;; activating) echo starting ;; *) echo "$s" ;; esac ;;
    supervisor)
      s=$({ supervisorctl status "$unit" 2>/dev/null || true; } | awk 'NR==1 {print tolower($2)}')
      echo "${s:-not loaded}" ;;
    pm2)
      if pm2_alive "$d"; then
        pid=$({ pm2_as "$d" pid "$d" 2>/dev/null || true; } | tail -n 1)
        if [[ $pid =~ ^[1-9][0-9]*$ ]]; then echo running; else echo stopped; fi
      else
        echo stopped
      fi ;;
  esac
}

# pm_remove domain manager — stop the process and delete that manager's config
pm_remove() {
  local d=$1 pm=$2 unit user; unit=$(app_unit "$d"); user=$(site_get "$d" SITE_USER)
  case $pm in
    systemd)
      systemctl disable --now "$unit.service" >>"$SRV_LOG" 2>&1 || true
      rm -f "/etc/systemd/system/$unit.service"
      run systemctl daemon-reload || true ;;
    supervisor)
      supervisorctl stop "$unit" >>"$SRV_LOG" 2>&1 || true
      rm -f "/etc/supervisor/conf.d/$unit.conf"
      if command -v supervisorctl >/dev/null 2>&1; then sv_update || true; fi ;;
    pm2)
      if pm2_alive "$d"; then
        pm2_as "$d" delete "$d" >>"$SRV_LOG" 2>&1 || true
        pm2_as "$d" save --force >>"$SRV_LOG" 2>&1 || true
        pm2_as "$d" kill >>"$SRV_LOG" 2>&1 || true
      fi
      systemctl disable "pm2-$user.service" >>"$SRV_LOG" 2>&1 || true
      rm -f "/etc/systemd/system/pm2-$user.service" "$SRV_RUN/$d.pm2.config.js"
      run systemctl daemon-reload || true ;;
  esac
}

app_wait() {
  local d=$1 port i; port=$(site_get "$d" PORT)
  for (( i = 0; i < 20; i++ )); do
    if port_in_use "$port"; then ok "$d is up on 127.0.0.1:$port"; return 0; fi
    sleep 1
  done
  warn "$d isn't listening on port $port yet — check: srv app logs $d"
  return 1
}

laravel_ctl() {   # start|stop|restart the Laravel worker group
  local d=$1 action=$2 user; user=$(site_get "$d" SITE_USER)
  [[ -f $(laravel_conf "$d") ]] || die "$d has no workers configured — set them up with: srv site workers $d"
  run supervisorctl "$action" "srv-$user-laravel:*" || die "supervisorctl $action failed — see $SRV_LOG"
  ok "$d workers: $action done ($(laravel_state "$d"))"
}

laravel_state() {
  local out total run
  out=$(supervisorctl status "srv-$(site_get "$1" SITE_USER)-laravel:*" 2>/dev/null) || true
  total=$(grep -c . <<<"$out" || true); run=$(awk '$2=="RUNNING"' <<<"$out" | grep -c . || true)
  if [[ -z $out ]]; then echo "not loaded"; else echo "$run/$total running"; fi
}

app_start() {
  local d=$1 type app pm
  type=$(site_get "$d" TYPE)
  if [[ $type == laravel ]]; then laravel_ctl "$d" start; return 0; fi
  is_app_type "$type" || die "$d is a $type site — it has no app process."
  app=$(site_get "$d" APP_DIR); pm=$(app_pm "$d")
  [[ -n $(ls -A "$app" 2>/dev/null) ]] || die "$app is empty — upload your project, then run: srv app build $d"
  if [[ $type == python && ! -x $(app_venv "$d")/bin/$(site_get "$d" PY_SERVER gunicorn) ]]; then
    if [[ $(site_get "$d" DEPLOY) == yes ]]; then die "The live release has no virtualenv — redeploy: srv deploy $d"; fi
    die "The virtualenv isn't ready — run: srv app build $d"
  fi
  case $pm in pm2) ensure_feature pm2 ;; supervisor) ensure_feature supervisor ;; esac
  site_set "$d" APP_ACTIVE yes
  app_render_launcher "$d"
  pm_write "$d"
  pm_start "$d" || die "Couldn't start $d — see $SRV_LOG and: srv app logs $d"
  app_wait "$d" || true
}

app_stop() {
  local d=$1 type; type=$(site_get "$d" TYPE)
  if [[ $type == laravel ]]; then laravel_ctl "$d" stop; return 0; fi
  is_app_type "$type" || die "$d is a $type site — it has no app process."
  site_set "$d" APP_ACTIVE no
  pm_write "$d"
  pm_stop "$d" || die "Couldn't stop $d — see $SRV_LOG"
  ok "$d stopped (stays stopped after reboot — start with: srv app start $d)"
}

app_restart() {
  local d=$1 type; type=$(site_get "$d" TYPE)
  if [[ $type == laravel ]]; then laravel_ctl "$d" restart; return 0; fi
  app_start "$d"
}

# Install Node dependencies and run the build in <dir>
node_build() {   # domain dir PATH
  local d=$1 dir=$2 path=$3 cmd
  [[ -f $dir/package.json ]] || die "No package.json in $dir."
  cmd=$(site_get "$d" INSTALL_CMD)
  if [[ -z $cmd ]]; then cmd=$(node_install_cmd "$dir"); fi
  info "Installing dependencies: $cmd"
  app_exec "$d" "$cmd" "$dir" "$path" || die "Dependency install failed (see the output above)"
  cmd=$(site_get "$d" BUILD_CMD)
  if [[ -n $cmd ]]; then
    info "Building: $cmd"
    app_exec "$d" "$cmd" "$dir" "$path" || die "Build failed (see the output above)"
  fi
}

# Create/refresh a virtualenv and install the app into it
py_build() {   # domain dir venv
  local d=$1 dir=$2 venv=$3 user path server pkg
  user=$(site_get "$d" SITE_USER); path=$(app_path "$d" "$venv")
  local py want have; py=$(py_interpreter "$d")
  want=$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || die "Python interpreter not found: $py"
  if [[ -x $venv/bin/python ]]; then
    have=$("$venv/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || have=""
    if [[ $have != "$want" ]]; then
      info "The virtualenv uses Python ${have:-?}, the app wants $want — recreating it"
      [[ $venv == */venv || $venv == */.venv ]] || die "Unexpected virtualenv path: $venv"
      rm -rf "${venv:?}"
    fi
  fi
  if [[ ! -x $venv/bin/python ]]; then
    info "Creating the virtualenv in $venv (Python $want)"
    run runuser -u "$user" -- env -C "$(site_get "$d" HOME_DIR)" "$py" -m venv "$venv" || die "Couldn't create the virtualenv"
  fi
  app_exec "$d" "python -m pip install -q --upgrade pip wheel" "$dir" "$path" || die "pip upgrade failed"
  if [[ -f $dir/requirements.txt ]]; then
    info "Installing requirements.txt"
    app_exec "$d" "pip install -r requirements.txt" "$dir" "$path" || die "pip install failed (see the output above)"
  elif [[ -f $dir/pyproject.toml ]]; then
    info "Installing from pyproject.toml"
    app_exec "$d" "pip install ." "$dir" "$path" || die "pip install failed (see the output above)"
  else
    warn "No requirements.txt or pyproject.toml — skipping dependency install"
  fi
  server=$(site_get "$d" PY_SERVER gunicorn)
  if [[ ! -x $venv/bin/$server ]]; then
    pkg=gunicorn; if [[ $server == uvicorn ]]; then pkg='uvicorn[standard]'; fi
    info "Installing $pkg"
    app_exec "$d" "pip install '$pkg'" "$dir" "$path" || die "Installing $pkg failed"
  fi
  if [[ $(site_get "$d" PY_FRAMEWORK) == django && -f $dir/manage.py ]]; then
    info "Collecting static files"
    app_exec "$d" "python manage.py collectstatic --noinput" "$dir" "$path" || warn "collectstatic failed — check STATIC_ROOT in settings.py"
  fi
  local cmd; cmd=$(site_get "$d" BUILD_CMD)
  if [[ -n $cmd ]]; then info "Running: $cmd"; app_exec "$d" "$cmd" "$dir" "$path" || die "Build command failed"; fi
}

app_build() {
  local d type home app
  d=$(resolve_domain "${1:-}" apps) || exit 1
  type=$(site_get "$d" TYPE)
  is_app_type "$type" || die "build is for Node.js and Python apps ($d is a $type site)."
  if [[ $(site_get "$d" DEPLOY) == yes ]]; then die "$d deploys from git — run: srv deploy $d"; fi
  home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR)
  [[ -n $(ls -A "$app" 2>/dev/null) ]] || die "$app is empty — upload your project first (git clone, rsync, SFTP …), or deploy from git: srv deploy setup $d"
  site_fix_perms "$d" 2>/dev/null
  step "Building $d"
  if [[ $type == node ]]; then node_build "$d" "$app" "$(app_path "$d")"
  else py_build "$d" "$app" "$home/venv"; fi
  site_fix_perms "$d" 2>/dev/null
  ok "Build finished"
  app_start "$d"
  if [[ $type == python && $(site_get "$d" PY_FRAMEWORK) == django ]]; then
    info "Run migrations with: srv app exec $d 'python manage.py migrate'"
  fi
}

app_exec_cmd() {
  local d=${1:-} cmd=${2:-}
  d=$(resolve_domain "$d" apps) || exit 1
  is_app_type "$(site_get "$d" TYPE)" || die "exec is for Node.js and Python apps."
  [[ -n $cmd ]] || die "Usage: srv app exec <domain> '<command>'   e.g. srv app exec $d 'python manage.py migrate'"
  app_exec "$d" "$cmd"
}

app_list() {
  local d any=0 type state port pm mem star=0
  printf '%s%-34s %-8s %-11s %-6s %-14s %s%s\n' "$C_BOLD" DOMAIN TYPE MANAGER PORT STATE MEMORY "$C_0"
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    site_has_process "$d" || continue
    any=1; type=$(site_get "$d" TYPE)
    if is_app_type "$type"; then
      pm=$(app_pm "$d"); port=$(site_get "$d" PORT); state=$(pm_state "$d")
      if [[ $state == running ]] && ! port_in_use "$port"; then state="running*"; star=1; fi
    else
      pm=supervisor; port=$(site_get "$d" REVERB_PORT -); state=$(laravel_state "$d")
    fi
    mem="$(user_rss_mb "$(site_get "$d" SITE_USER)") MB"
    printf '%-34s %-8s %-11s %-6s %-14s %s\n' "$d" "$type" "$pm" "$port" "$state" "$mem"
  done < <(site_list_domains)
  if (( ! any )); then echo "  (no apps — create one with: srv site add --type node|python)"; fi
  if (( star )); then echo "  ${C_D}running* = process is up but not listening on its port yet${C_0}"; fi
}

app_manager() {
  local d=${1:-} new=${2:-} old active
  d=$(resolve_domain "$d" apps) || exit 1
  is_app_type "$(site_get "$d" TYPE)" || die "Only Node.js and Python apps have a process manager."
  old=$(app_pm "$d")
  if [[ -z $new ]]; then
    new=$(ui_menu "Process manager" "$d currently uses $old. Switch to:" \
      systemd "systemd" pm2 "PM2" supervisor "Supervisor") || die "Cancelled."
  fi
  in_list "$new" systemd pm2 supervisor || die "Use systemd, pm2 or supervisor."
  if [[ $new == "$old" ]]; then info "$d already uses $old."; return 0; fi
  case $new in pm2) ensure_feature node; ensure_feature pm2 ;; supervisor) ensure_feature supervisor ;; esac
  active=$(site_get "$d" APP_ACTIVE no)
  pm_remove "$d" "$old"
  site_set "$d" PM "$new"
  if [[ $active == yes ]]; then app_start "$d"; else pm_write "$d"; fi
  ok "$d now runs under $new"
}

# ── Laravel: queue workers, Horizon, Reverb (Supervisor) ─────────────────────
sv_program() {   # name command log stopwait numprocs dir user home
  local name=$1 cmd=$2 logf=$3 stopwait=$4 n=$5 dir=$6 user=$7 home=$8 pname='%(program_name)s'
  if (( n > 1 )); then pname='%(program_name)s_%(process_num)02d'; fi
  cat <<EOF

[program:$name]
command=$cmd
directory=$dir
user=$user
numprocs=$n
process_name=$pname
autostart=true
autorestart=true
startsecs=1
startretries=10
stopasgroup=true
killasgroup=true
stopwaitsecs=$stopwait
redirect_stderr=true
stdout_logfile=$logf
stdout_logfile_maxbytes=0
environment=HOME="$home",USER="$user"
EOF
}

laravel_render_workers() {
  local d=$1 user home app php q h r rp conf
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR); php=$(site_get "$d" PHP)
  q=$(site_get "$d" QUEUE_WORKERS 0); h=$(site_get "$d" HORIZON no); r=$(site_get "$d" REVERB no); rp=$(site_get "$d" REVERB_PORT)
  conf=$(laravel_conf "$d")
  if (( q == 0 )) && [[ $h != yes && $r != yes ]]; then
    if [[ -f $conf ]]; then
      supervisorctl stop "srv-$user-laravel:*" >>"$SRV_LOG" 2>&1 || true
      rm -f "$conf"; sv_update || true
    fi
    return 0
  fi
  feat_has supervisor || { err "Supervisor isn't installed — run: srv install supervisor"; return 1; }
  local -a progs=()
  {
    echo "; Managed by srv — Laravel processes for $d (change with: srv site workers $d)"
    if [[ $h == yes ]]; then
      progs+=("srv-$user-horizon")
      sv_program "srv-$user-horizon" "/usr/bin/php$php $app/artisan horizon" "$home/logs/horizon.log" 3600 1 "$app" "$user" "$home"
    elif (( q > 0 )); then
      progs+=("srv-$user-queue")
      sv_program "srv-$user-queue" "/usr/bin/php$php $app/artisan queue:work --sleep=3 --tries=3 --max-time=3600" \
        "$home/logs/queue.log" 3600 "$q" "$app" "$user" "$home"
    fi
    if [[ $r == yes ]]; then
      progs+=("srv-$user-reverb")
      sv_program "srv-$user-reverb" "/usr/bin/php$php $app/artisan reverb:start --host=127.0.0.1 --port=$rp" \
        "$home/logs/reverb.log" 30 1 "$app" "$user" "$home"
    fi
    echo
    echo "[group:srv-$user-laravel]"
    echo "programs=$(IFS=,; echo "${progs[*]}")"
  } >"$conf"
  sv_update || return 1
}

site_workers() {
  local d="" q="" h="" r=""
  while (( $# )); do
    case $1 in
      --queue)      need_val "$@"; q=$2; shift 2 ;;
      --horizon)    h=yes; shift ;;
      --no-horizon) h=no; shift ;;
      --reverb)     r=yes; shift ;;
      --no-reverb)  r=no; shift ;;
      -*)           die "Unknown option: $1" ;;
      *)            d=$1; shift ;;
    esac
  done
  d=$(resolve_domain "$d") || exit 1
  [[ $(site_get "$d" TYPE) == laravel ]] || die "Workers are for Laravel sites ($d is $(site_get "$d" TYPE))."
  local cq ch cr
  cq=$(site_get "$d" QUEUE_WORKERS 0); ch=$(site_get "$d" HORIZON no); cr=$(site_get "$d" REVERB no)
  if [[ -z $q && -z $h && -z $r ]]; then
    if (( ! INTERACTIVE )); then
      echo "$d — queue workers: $cq · Horizon: $ch · Reverb: $cr"
      echo "Change with: srv site workers $d [--queue N] [--horizon|--no-horizon] [--reverb|--no-reverb]"
      return 0
    fi
    if ui_yesno "Use Laravel Horizon to run the queues? (needs Redis and the laravel/horizon package)" "$ch"; then h=yes; q=0; else h=no; fi
    if [[ $h == no ]]; then
      while true; do
        q=$(ui_input "Number of queue:work processes (0 = none)" "$(( cq > 0 ? cq : 1 ))") || die "Cancelled."
        q=$(dec "$q"); if [[ $q =~ ^[0-9]+$ ]] && (( q <= 32 )); then break; fi
        warn "Enter a number from 0 to 32"
      done
    fi
    if ui_yesno "Run Laravel Reverb (WebSockets)? Nginx will send /app/* and /apps/* to it." "$cr"; then r=yes; else r=no; fi
  fi
  q=${q:-$cq}; h=${h:-$ch}; r=${r:-$cr}
  q=$(dec "$q")
  [[ $q =~ ^[0-9]+$ ]] && (( q <= 32 )) || die "Queue workers must be 0–32."
  if [[ $h == yes ]]; then q=0; fi
  if (( q > 0 )) || [[ $h == yes || $r == yes ]]; then ensure_feature supervisor; fi
  if [[ $h == yes && $(site_get "$d" REDIS no) != yes ]]; then warn "Horizon needs Redis — enable it with: srv site redis $d on"; fi
  if [[ $r == yes && -z $(site_get "$d" REVERB_PORT) ]]; then site_set "$d" REVERB_PORT "$(port_alloc)"; fi
  site_set "$d" QUEUE_WORKERS "$q"; site_set "$d" HORIZON "$h"; site_set "$d" REVERB "$r"
  laravel_render_workers "$d" || die "Worker setup failed — see $SRV_LOG"
  if [[ $r != "$cr" ]]; then site_apply_nginx "$d" || die "Nginx update failed"; fi
  ok "$d — queue workers: $q · Horizon: $h · Reverb: $r$([[ $r == yes ]] && echo " (port $(site_get "$d" REVERB_PORT))")"
  if [[ ! -f $(site_get "$d" APP_DIR)/artisan ]] && { (( q > 0 )) || [[ $h == yes || $r == yes ]]; }; then
    warn "No artisan file yet — after uploading your app run: srv app restart $d"
  fi
  if [[ $r == yes ]]; then info "Write the Reverb settings into .env: srv site apply-env $d"; fi
}

cmd_app() {
  local sub=${1:-}; shift || true
  local d
  case $sub in
    list|ls|status) if [[ -z ${1:-} ]]; then app_list; return 0; fi ;;
  esac
  case $sub in
    list|ls)        app_list ;;
    status)         d=$(resolve_domain "$1" apps) || exit 1
                    if is_app_type "$(site_get "$d" TYPE)"; then echo "$d: $(pm_state "$d") ($(app_pm "$d"), port $(site_get "$d" PORT))"
                    else echo "$d: workers $(laravel_state "$d")"; fi ;;
    build|deploy)   app_build "${1:-}" ;;
    start)          d=$(resolve_domain "${1:-}" apps) || exit 1; app_start "$d" ;;
    stop)           d=$(resolve_domain "${1:-}" apps) || exit 1; app_stop "$d" ;;
    restart)        d=$(resolve_domain "${1:-}" apps) || exit 1; app_restart "$d" ;;
    logs|log)
      d=$(resolve_domain "${1:-}" apps) || exit 1
      if [[ -n ${2:-} ]]; then site_logs "$d" "$2"
      elif is_app_type "$(site_get "$d" TYPE)"; then site_logs "$d" app
      else
        local k; for k in horizon queue reverb; do
          if [[ -f $(site_get "$d" HOME_DIR)/logs/$k.log ]]; then site_logs "$d" "$k"; return 0; fi
        done
        site_logs "$d" laravel
      fi ;;
    manager|pm)     app_manager "$@" ;;
    exec|run)       app_exec_cmd "$@" ;;
    ""|menu)        menu_apps ;;
    *) die "Unknown app command: $sub (see: srv help)" ;;
  esac
}

# =============================================================================
#  DEPLOY — git releases with an atomic "current" switch
#
#  /var/www/<domain>/
#    repo.git/                 bare mirror of the repository
#    releases/<id>/            one folder per deploy (id = UTC timestamp)
#    shared/                   kept between releases (.env, storage/, media/ …)
#    current -> releases/<id>  what Nginx, PHP-FPM and the app serve
#
#  A deploy: fetch → export the commit into a new release → link shared files →
#  build (composer / npm / pip / collectstatic / your command) → migrations →
#  switch "current" → reload/restart → health check (rollback if it fails) →
#  delete old releases. Until the switch, the live site is untouched.
# =============================================================================
deploy_enabled() { [[ -n $(site_get "$1" REPO) ]]; }
deploy_current() {
  local l; l=$(readlink "$(site_get "$1" HOME_DIR)/current" 2>/dev/null) || return 1
  [[ -n $l ]] || return 1
  basename "$l"
}
deploy_meta() { printf '%s/releases/%s/%s' "$SRV_DIR" "$1" "$2"; }
deploy_releases_desc() {
  find "$(site_get "$1" HOME_DIR)/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}
site_has_key() { grep -qE "^$2=" "$(site_file "$1")"; }
is_ssh_repo()  { [[ $1 =~ ^ssh:// || $1 =~ ^[A-Za-z0-9._-]+@[^:/]+: ]]; }
valid_repo()   { [[ $1 =~ ^(ssh|https?|git|file)://[^[:space:]]+$ || $1 =~ ^/[^[:space:]]+$ || $1 =~ ^[A-Za-z0-9._-]+@[^:/[:space:]]+:[^[:space:]]+$ ]]; }
valid_ref()    { [[ $1 =~ ^[A-Za-z0-9._/@^~-]+$ && $1 != -* ]]; }

deploy_ssh_cmd() {
  local home=$1 c
  c="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$home/.ssh/known_hosts"
  if [[ -f $home/.ssh/deploy_key ]]; then c="$c -i $home/.ssh/deploy_key -o IdentitiesOnly=yes"; fi
  printf '%s' "$c"
}

deploy_git() {   # deploy_git <domain> <git args…> — runs git as the site user
  local d=$1; shift
  local user home; user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR)
  runuser -u "$user" -- env -i HOME="$home" USER="$user" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(deploy_ssh_cmd "$home")" git "$@" 9>&-
}

# A repository on this server owned by another user: let the site user read it
deploy_trust_local() {
  local d=$1 repo=$2 path
  case $repo in
    file://*) path=${repo#file://} ;;
    /*)       path=$repo ;;
    *)        return 0 ;;
  esac
  if ! deploy_git "$d" config --global --get-all safe.directory 2>/dev/null | grep -qxF "$path"; then
    deploy_git "$d" config --global --add safe.directory "$path" || true
  fi
}

deploy_ensure_dirs() {
  local d=$1 user home; user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR)
  install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
  install -d -m 750 -o "$user" -g "$user" "$home/releases" "$home/shared" "$home/logs"
  install -d -m 700 "$SRV_DIR/releases" "$SRV_DIR/releases/$d"
}

deploy_key() {
  local d user home
  d=$(resolve_domain "${1:-}") || exit 1
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR)
  install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
  if [[ ! -f $home/.ssh/deploy_key ]]; then
    run runuser -u "$user" -- ssh-keygen -q -t ed25519 -N "" -C "srv-deploy-$d@$(hostname -s)" -f "$home/.ssh/deploy_key" \
      || die "ssh-keygen failed"
    ok "Deploy key created: $home/.ssh/deploy_key"
  fi
  echo
  echo " Add this public key to the repository as a read-only deploy key:"
  echo "   GitHub     Settings → Deploy keys → Add deploy key"
  echo "   GitLab     Settings → Repository → Deploy keys"
  echo "   Bitbucket  Repository settings → Access keys"
  echo
  cat "$home/.ssh/deploy_key.pub"
  echo
}

deploy_default_shared() {   # → "dirs|files"
  case $(site_get "$1" TYPE) in
    laravel) echo "storage|.env" ;;
    python)  if [[ $(site_get "$1" PY_FRAMEWORK) == django ]]; then echo "$(site_get "$1" MEDIA_DIR media)|"; else echo "|"; fi ;;
    *)       echo "|" ;;
  esac
}

deploy_setup() {
  local d="" repo="" branch="" now="" keep="" build="" build_set=0
  while (( $# )); do
    case $1 in
      --repo)      need_val "$@"; repo=$2; shift 2 ;;
      --branch)    need_val "$@"; branch=$2; shift 2 ;;
      --keep)      need_val "$@"; keep=$2; shift 2 ;;
      --build)     need_val "$@"; build=$2; build_set=1; shift 2 ;;
      --deploy)    now=yes; shift ;;
      --no-deploy) now=no; shift ;;
      -*)          die "Unknown option: $1" ;;
      *)           d=$1; shift ;;
    esac
  done
  d=$(resolve_domain "$d") || exit 1
  local type user home app
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR)
  [[ $type != proxy ]] || die "Proxy sites don't have code to deploy."
  command -v git >/dev/null 2>&1 || apt_install git || die "git is required"

  while true; do
    if [[ -z $repo ]]; then repo=$(ui_input "Git repository (git@github.com:you/app.git or https://…)" "$(site_get "$d" REPO)") || die "Cancelled."; fi
    if valid_repo "$repo"; then break; fi
    warn "That doesn't look like a git URL: $repo"; retry_or_die "Invalid repository: $repo"; repo=""
  done
  if [[ -z $branch ]]; then branch=$(ui_input "Branch to deploy" "$(site_get "$d" BRANCH main)") || die "Cancelled."; fi
  valid_ref "$branch" || die "Invalid branch name: $branch"
  if [[ $repo =~ ://[^/@]+:[^/@]+@ ]]; then warn "The URL contains a password/token. It's stored root-only, but a deploy key is safer."; fi

  # Static / SPA: build step (e.g. Vite) and the folder it writes to
  if [[ $type == static || $type == spa ]] && (( ! build_set )); then
    build=$(ui_input "Build command for each release (blank = none, e.g. npm ci && npm run build)" "$(site_get "$d" DEPLOY_BUILD)" empty) || die "Cancelled."
    build_set=1
    if [[ -n $build && -z $(site_get "$d" WEBROOT) ]]; then
      local wr; wr=$(ui_input "Folder the build writes to — it becomes the web root (blank = repository root)" "dist" empty) || die "Cancelled."
      wr=${wr#/}; wr=${wr%/}
      if [[ -n $wr ]]; then valid_relpath "$wr" || die "Invalid folder: $wr"; site_set "$d" WEBROOT "$wr"; fi
    fi
  fi
  if (( build_set )); then site_set "$d" DEPLOY_BUILD "$build"; fi
  if is_php_type "$type"; then ensure_feature composer; fi

  deploy_ensure_dirs "$d"
  if is_ssh_repo "$repo"; then
    local had_key=0; if [[ -f $home/.ssh/deploy_key ]]; then had_key=1; fi
    deploy_key "$d"
    if (( ! had_key && INTERACTIVE && ! ASSUME_YES )); then
      read -r -p "Add the key to the repository, then press Enter to continue… " _ </dev/tty || true
    fi
  fi

  deploy_trust_local "$d" "$repo"
  info "Checking access to $repo"
  local out
  if out=$(deploy_git "$d" ls-remote --heads "$repo" "$branch" 2>&1); then
    if [[ -n $out ]]; then ok "Repository reachable, branch '$branch' found"
    else warn "The repository is reachable but has no branch '$branch'."; fi
  else
    warn "Couldn't reach the repository:"
    printf '%s\n' "$out" | tail -n 3 | sed 's/^/     │ /' >&2
    if is_ssh_repo "$repo"; then warn "Check that the deploy key above is added to the repository."; fi
  fi

  if [[ -n $(site_get "$d" REPO) && $(site_get "$d" REPO) != "$repo" ]]; then rm -rf "${home:?}/repo.git"; fi
  site_set "$d" REPO "$repo"
  site_set "$d" BRANCH "$branch"
  if [[ -n $keep ]]; then
    keep=$(dec "$keep"); [[ $keep =~ ^[0-9]+$ ]] && (( keep >= 2 && keep <= 50 )) || die "--keep must be 2–50"
    site_set "$d" DEPLOY_KEEP "$keep"
  elif ! site_has_key "$d" DEPLOY_KEEP; then site_set "$d" DEPLOY_KEEP 5; fi
  local sh x; sh=$(deploy_default_shared "$d")
  site_has_key "$d" DEPLOY_SHARED_DIRS   || site_set "$d" DEPLOY_SHARED_DIRS "${sh%%|*}"
  site_has_key "$d" DEPLOY_SHARED_FILES  || site_set "$d" DEPLOY_SHARED_FILES "${sh#*|}"
  site_has_key "$d" DEPLOY_AUTO_ROLLBACK || site_set "$d" DEPLOY_AUTO_ROLLBACK yes
  site_has_key "$d" DEPLOY_HEALTH_PATH   || site_set "$d" DEPLOY_HEALTH_PATH /
  if ! site_has_key "$d" DEPLOY_MIGRATE; then
    if [[ $type == laravel || ( $type == python && $(site_get "$d" PY_FRAMEWORK) == django ) ]]; then site_set "$d" DEPLOY_MIGRATE yes
    else site_set "$d" DEPLOY_MIGRATE no; fi
  fi

  # Seed shared/ from files already on the server so the first release keeps them
  if [[ $(site_get "$d" DEPLOY) != yes ]]; then
    for x in $(site_get "$d" DEPLOY_SHARED_DIRS); do
      if [[ -d $app/$x && ! -e $home/shared/$x ]]; then mkdir -p "$(dirname "$home/shared/$x")"; cp -a "$app/$x" "$home/shared/$x"; info "Copied $x/ into shared/"; fi
    done
    for x in $(site_get "$d" DEPLOY_SHARED_FILES); do
      if [[ -f $app/$x && ! -e $home/shared/$x ]]; then mkdir -p "$(dirname "$home/shared/$x")"; cp -a "$app/$x" "$home/shared/$x"; info "Copied $x into shared/"; fi
    done
    chown -R "$user:$user" "$home/shared"
  fi
  if [[ $(site_get "$d" DEPLOY_WEBHOOK) == yes ]]; then webhook_write_secret "$d"; fi

  ok "Deploys set up for $d: $repo ($branch)"
  printf '  %-14s %s\n' "Shared dirs" "$(x=$(site_get "$d" DEPLOY_SHARED_DIRS); echo "${x:-none}")" \
    "Shared files" "$(x=$(site_get "$d" DEPLOY_SHARED_FILES); echo "${x:-none}")" \
    "Migrations" "$(site_get "$d" DEPLOY_MIGRATE)" "Keep" "$(site_get "$d" DEPLOY_KEEP) releases" >&2
  info "Change these with e.g.: srv site set $d DEPLOY_SHARED_DIRS \"storage public/uploads\""
  if [[ -z $now ]]; then if ui_yesno "Deploy '$branch' now?" yes; then now=yes; else now=no; fi; fi
  if [[ $now == yes ]]; then deploy_now "$d"; else info "Deploy with: srv deploy $d"; fi
  info "Auto-deploy on every push: srv deploy webhook $d on"
}

deploy_now() {
  local d="" ref="" maint=no migrate=""
  while (( $# )); do
    case $1 in
      --ref)         need_val "$@"; ref=$2; shift 2 ;;
      --maintenance) maint=yes; shift ;;
      --no-migrate)  migrate=no; shift ;;
      -*)            die "Unknown option: $1" ;;
      *)             d=$1; shift ;;
    esac
  done
  d=$(resolve_domain "$d" deploy) || exit 1
  deploy_enabled "$d" || die "Deploys aren't set up for $d — run: srv deploy setup $d"
  if [[ -n $ref ]] && ! valid_ref "$ref"; then die "Invalid ref: $ref"; fi
  if is_php_type "$(site_get "$d" TYPE)"; then ensure_feature composer; fi   # ask now, not mid-deploy
  migrate=${migrate:-$(site_get "$d" DEPLOY_MIGRATE no)}
  local user home log rc=0
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); log="$home/logs/deploy.log"
  deploy_ensure_dirs "$d"
  printf '\n===== %s  deploy %s  (%s) =====\n' "$(date '+%F %T')" "${ref:-$(site_get "$d" BRANCH main)}" "${SRV_TRIGGER:-cli}" >>"$log"
  # The deploy runs in a subshell, so a failure cleans up after itself (EXIT trap)
  { trap deploy_on_exit EXIT; INTERACTIVE=0; deploy_run "$d" "$ref" "$maint" "$migrate"; } 2>&1 \
    | tee >(sed -u 's/\x1b\[[0-9;]*m//g' >>"$log") >&2 || rc=$?
  sleep 0.2
  chown "$user:$user" "$log" 2>/dev/null || true
  if [[ $(cfg_get NOTIFY_DEPLOYS yes) == yes ]]; then
    local cur; cur=$(deploy_current "$d" || true)
    if (( rc != 0 )); then notify_send "❌ Deploy of $d failed — live release: ${cur:-none}. Log: $log" || true
    elif [[ ${SRV_TRIGGER:-cli} == webhook ]]; then
      notify_send "🚀 $d deployed: $(kv_get "$(deploy_meta "$d" "$cur")" COMMIT | cut -c1-8) $(kv_get "$(deploy_meta "$d" "$cur")" SUBJECT)" || true
    fi
  fi
  return "$rc"
}

deploy_on_exit() {
  local h; h=$(site_get "$DEPLOY_SITE" HOME_DIR)
  if (( DEPLOY_MAINT_SET )) && [[ -n $h ]]; then rm -f "${h:?}/.maintenance"; info "Maintenance mode off"; fi
  if [[ -n $DEPLOY_NEW_REL && $DEPLOY_ACTIVATED == 0 && -d $DEPLOY_NEW_REL ]]; then
    rm -rf "${DEPLOY_NEW_REL:?}"
    rm -f "$(deploy_meta "$DEPLOY_SITE" "$(basename "$DEPLOY_NEW_REL")")"
    err "Deploy failed — the live site was not changed"
  fi
}

deploy_run() {
  local d=$1 ref=$2 maint=$3 migrate=$4
  local type user home repo branch commit subject rel relp prev started n=2 meta after
  DEPLOY_SITE=$d; started=$(date +%s)
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR)
  repo=$(site_get "$d" REPO); branch=$(site_get "$d" BRANCH main); ref=${ref:-$branch}
  step "Deploying $d ($ref)"

  deploy_trust_local "$d" "$repo"
  if [[ ! -d $home/repo.git ]]; then
    info "Cloning $repo"
    run deploy_git "$d" clone --mirror --quiet "$repo" "$home/repo.git" || die "git clone failed — check the URL and the deploy key (srv deploy key $d)"
  else
    run deploy_git "$d" --git-dir="$home/repo.git" remote set-url origin "$repo"
    info "Fetching $repo"
    run deploy_git "$d" --git-dir="$home/repo.git" remote update --prune || die "git fetch failed — check access (srv deploy key $d)"
  fi
  commit=$(deploy_git "$d" --git-dir="$home/repo.git" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || die "Branch, tag or commit not found: $ref"
  subject=$(deploy_git "$d" --git-dir="$home/repo.git" log -1 --format=%s "$commit" 2>/dev/null) || subject=""
  info "Commit ${commit:0:10} — $subject"

  rel=$(date -u +%Y%m%d%H%M%S)
  while [[ -e $home/releases/$rel ]]; do rel="$(date -u +%Y%m%d%H%M%S)-$n"; n=$(( n + 1 )); done
  relp="$home/releases/$rel"; DEPLOY_NEW_REL=$relp
  run runuser -u "$user" -- mkdir "$relp"
  deploy_git "$d" --git-dir="$home/repo.git" archive --format=tar "$commit" | runuser -u "$user" -- tar -x -C "$relp" 9>&- \
    || die "Couldn't export commit $commit"
  meta=$(deploy_meta "$d" "$rel")
  printf 'COMMIT=%s\nSUBJECT=%s\nREF=%s\nDATE=%s\nBY=%s\nSTATUS=building\n' \
    "$commit" "$subject" "$ref" "$(date '+%F %T')" "${SRV_TRIGGER:-cli}" >"$meta"
  chmod 600 "$meta"
  ok "Release $rel created"

  deploy_link_shared "$d" "$relp"
  deploy_build "$d" "$relp"

  if [[ $maint == yes ]]; then touch "$home/.maintenance"; DEPLOY_MAINT_SET=1; info "Maintenance mode on"; fi
  if [[ $migrate == yes ]]; then deploy_migrate "$d" "$relp"; fi

  prev=$(deploy_current "$d" || true)
  deploy_switch "$d" "$rel"
  DEPLOY_ACTIVATED=1
  kv_set "$meta" STATUS live

  after=$(site_get "$d" DEPLOY_AFTER)
  if [[ -n $after ]]; then
    info "After-deploy command: $after"
    app_exec "$d" "$after" "$home/current" "$(deploy_path "$d" "$relp")" || warn "The after-deploy command failed"
  fi
  if (( DEPLOY_MAINT_SET )); then rm -f "${home:?}/.maintenance"; DEPLOY_MAINT_SET=0; info "Maintenance mode off"; fi

  if ! deploy_health "$d"; then
    kv_set "$meta" STATUS failed
    if [[ -n $prev && -d $home/releases/$prev && $(site_get "$d" DEPLOY_AUTO_ROLLBACK yes) == yes ]]; then
      warn "Rolling back to $prev"
      deploy_switch "$d" "$prev"
      deploy_health "$d" || true
      die "Deploy of ${commit:0:10} failed its health check — rolled back to $prev (database migrations are not rolled back)"
    fi
    die "Deploy of ${commit:0:10} failed its health check — check: srv site logs $d"
  fi
  kv_set "$meta" STATUS ok
  kv_set "$meta" SECONDS "$(( $(date +%s) - started ))"
  deploy_cleanup "$d"
  ok "Deployed $d → ${commit:0:10} (release $rel) in $(( $(date +%s) - started ))s"
}

deploy_path() {   # PATH for build steps inside a release
  if [[ $(site_get "$1" TYPE) == python ]]; then app_path "$1" "$2/.venv"; else app_path "$1"; fi
}

deploy_link_shared() {
  local d=$1 rel=$2 home user x
  home=$(site_get "$d" HOME_DIR); user=$(site_get "$d" SITE_USER)
  for x in $(site_get "$d" DEPLOY_SHARED_DIRS); do
    valid_relpath "$x" && [[ -n $x && $x != . ]] || die "Invalid shared dir: $x"
    if [[ ! -e $home/shared/$x ]]; then
      mkdir -p "$(dirname "$home/shared/$x")"
      if [[ -d $rel/$x ]]; then cp -a "$rel/$x" "$home/shared/$x"; else mkdir -p "$home/shared/$x"; fi
      info "shared/$x created"
    fi
    rm -rf "${rel:?}/${x:?}"
    mkdir -p "$(dirname "$rel/$x")"
    ln -s "$home/shared/$x" "$rel/$x"
  done
  for x in $(site_get "$d" DEPLOY_SHARED_FILES); do
    valid_relpath "$x" && [[ -n $x && $x != . ]] || die "Invalid shared file: $x"
    if [[ ! -e $home/shared/$x ]]; then
      mkdir -p "$(dirname "$home/shared/$x")"
      if [[ -f $rel/$x ]]; then cp -a "$rel/$x" "$home/shared/$x"
      elif [[ -f $rel/$x.example ]]; then cp -a "$rel/$x.example" "$home/shared/$x"; info "shared/$x created from $x.example"
      else touch "$home/shared/$x"; fi
      if [[ $x == .env ]]; then DEPLOY_ENV_CREATED=1; chmod 600 "$home/shared/$x"; fi
    fi
    rm -f "${rel:?}/${x:?}"
    mkdir -p "$(dirname "$rel/$x")"
    ln -s "$home/shared/$x" "$rel/$x"
  done
  if [[ $(site_get "$d" TYPE) == laravel && -d $home/shared/storage ]]; then
    mkdir -p "$home/shared/storage/"{app/public,framework/cache/data,framework/sessions,framework/views,logs}
  fi
  chown -R "$user:$user" "$home/shared"
  chown -hR "$user:$user" "$rel"
}

deploy_build() {
  local d=$1 rel=$2 type php path cmd home
  type=$(site_get "$d" TYPE); php=$(site_get "$d" PHP); home=$(site_get "$d" HOME_DIR); path=$(deploy_path "$d" "$rel")
  case $type in
    php|laravel)
      if [[ -f $rel/composer.json && $(site_get "$d" DEPLOY_COMPOSER yes) != no ]]; then
        info "composer install"
        app_exec "$d" "/usr/bin/php$php /usr/local/bin/composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction --no-progress" "$rel" "$path" \
          || die "composer install failed"
      fi
      if [[ -f $rel/package.json ]] && grep -qE '"build"[[:space:]]*:' "$rel/package.json" && [[ $(site_get "$d" DEPLOY_NPM yes) != no ]]; then
        if [[ -n $(node_default_bin) ]]; then
          info "Building front-end assets"
          app_exec "$d" "$(node_install_cmd "$rel") && npm run build" "$rel" "$path" || die "Front-end build failed"
        else
          warn "package.json has a build script but Node.js isn't installed — skipped (srv install node)"
        fi
      fi
      if [[ $type == laravel && -f $rel/artisan ]]; then
        local envf="$home/shared/.env"
        if [[ " $(site_get "$d" DEPLOY_SHARED_FILES) " == *" .env "* && -f $envf ]]; then
          if (( DEPLOY_ENV_CREATED )); then info "New .env — filling in APP_URL, database and Redis"; laravel_env_write "$d" "$envf"; fi
          if ! grep -qE '^APP_KEY=.+' "$envf"; then
            app_exec "$d" "/usr/bin/php$php artisan key:generate --force" "$rel" "$path" || warn "key:generate failed"
          fi
        fi
        if [[ -d $rel/public && ! -e $rel/public/storage ]]; then
          app_exec "$d" "/usr/bin/php$php artisan storage:link" "$rel" "$path" 2>/dev/null || warn "storage:link failed"
        fi
        if [[ $(site_get "$d" DEPLOY_OPTIMIZE yes) != no ]]; then
          info "artisan optimize"
          app_exec "$d" "/usr/bin/php$php artisan optimize" "$rel" "$path" || warn "artisan optimize failed — continuing without caches"
        fi
      fi ;;
    node)   node_build "$d" "$rel" "$path" ;;
    python) py_build "$d" "$rel" "$rel/.venv" ;;
  esac
  cmd=$(site_get "$d" DEPLOY_BUILD)
  if [[ -n $cmd ]]; then
    info "Build command: $cmd"
    app_exec "$d" "$cmd" "$rel" "$path" || die "Build command failed"
  fi
}

deploy_migrate() {
  local d=$1 rel=$2 path; path=$(deploy_path "$d" "$rel")
  case $(site_get "$d" TYPE) in
    laravel)
      if [[ -f $rel/artisan ]]; then
        info "artisan migrate --force"
        app_exec "$d" "/usr/bin/php$(site_get "$d" PHP) artisan migrate --force" "$rel" "$path" || die "Migrations failed — the live release was not changed"
      fi ;;
    python)
      if [[ -f $rel/manage.py ]]; then
        info "manage.py migrate"
        app_exec "$d" "python manage.py migrate --noinput" "$rel" "$path" || die "Migrations failed — the live release was not changed"
      fi ;;
  esac
}

# Atomically point "current" at a release, then reload / restart what serves it
deploy_switch() {
  local d=$1 rel=$2 user home first=0
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR)
  [[ -d $home/releases/$rel ]] || die "Release not found: $rel"
  ln -sfn "releases/$rel" "$home/.current.tmp"
  mv -Tf "$home/.current.tmp" "$home/current"
  chown -h "$user:$user" "$home/current"
  if [[ $(site_get "$d" DEPLOY) != yes || $(site_get "$d" APP_DIR) != "$home/current" ]]; then
    site_set "$d" DEPLOY yes; site_set "$d" APP_DIR "$home/current"; first=1
    info "From now on the site is served from $home/current"
  fi
  ok "Live: release $rel"
  deploy_reload "$d" "$first"
  # Nginx reloads in the background — give the new workers a moment before anyone checks
  if (( first )); then sleep 2; fi
}

deploy_reload() {
  local d=$1 first=$2 type user
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER)
  if (( first )); then site_apply_nginx "$d" || die "Nginx update failed"; site_render_cron "$d"; cron_render "$d"; fi
  case $type in
    php|laravel)
      run systemctl reload "php$(site_get "$d" PHP)-fpm" || warn "PHP-FPM reload failed"
      if [[ $type == laravel && -f $(laravel_conf "$d") ]]; then
        if (( first )); then laravel_render_workers "$d" || warn "Worker config update failed"; fi
        run supervisorctl restart "srv-$user-laravel:*" || warn "Restarting the Laravel workers failed"
      fi ;;
    node|python)
      app_start "$d" ;;
  esac
}

deploy_health() {
  local d=$1 home path code="" i
  home=$(site_get "$d" HOME_DIR); path=$(site_get "$d" DEPLOY_HEALTH_PATH /)
  if [[ -f $home/.maintenance ]]; then info "Maintenance mode is on — health check skipped"; return 0; fi
  if [[ $(site_get "$d" ENABLED yes) != yes ]]; then info "Site is disabled — health check skipped"; return 0; fi
  if is_app_type "$(site_get "$d" TYPE)" && ! port_in_use "$(site_get "$d" PORT)"; then app_wait "$d" || return 1; fi
  for (( i = 0; i < 8; i++ )); do
    if [[ $(site_get "$d" SSL) == yes ]]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' -k --noproxy '*' --max-time 15 --resolve "$d:443:127.0.0.1" "https://$d$path" 2>/dev/null) || true
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 15 -H "Host: $d" "http://127.0.0.1$path" 2>/dev/null) || true
    fi
    if [[ $code =~ ^[1-4][0-9][0-9]$ ]]; then ok "Health check: GET $path → $code"; return 0; fi
    sleep 2
  done
  err "Health check failed: GET $path → ${code:-no response}"
  return 1
}

deploy_cleanup() {
  local d=$1 keep cur home r i=0
  keep=$(site_get "$d" DEPLOY_KEEP 5); cur=$(deploy_current "$d" || true); home=$(site_get "$d" HOME_DIR)
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    i=$(( i + 1 ))
    if (( i <= keep )) || [[ $r == "$cur" ]]; then continue; fi
    rm -rf "${home:?}/releases/${r:?}"
    rm -f "$(deploy_meta "$d" "$r")"
    info "Removed old release $r"
  done < <(deploy_releases_desc "$d")
}

deploy_releases_list() {
  local d cur r meta mark any=0
  d=$(resolve_domain "${1:-}" deploy) || exit 1
  deploy_enabled "$d" || die "Deploys aren't set up for $d — run: srv deploy setup $d"
  cur=$(deploy_current "$d" || true)
  printf '%s  %-18s %-10s %-8s %-19s %s%s\n' "$C_BOLD" RELEASE COMMIT STATUS DATE MESSAGE "$C_0"
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    any=1; meta=$(deploy_meta "$d" "$r"); mark=" "
    if [[ $r == "$cur" ]]; then mark="*"; fi
    printf '%s %-18s %-10s %-8s %-19s %s\n' "$mark" "$r" "$(kv_get "$meta" COMMIT | cut -c1-10)" "$(kv_get "$meta" STATUS "?")" \
      "$(kv_get "$meta" DATE)" "$(kv_get "$meta" SUBJECT | cut -c1-50)"
  done < <(deploy_releases_desc "$d")
  if (( any )); then echo "  * = live    repo: $(site_get "$d" REPO) ($(site_get "$d" BRANCH main))"
  else echo "  (no releases yet — deploy with: srv deploy $d)"; fi
}

deploy_rollback() {
  local d=${1:-} target=${2:-} cur r st home meta
  d=$(resolve_domain "$d" deploy) || exit 1
  deploy_enabled "$d" || die "Deploys aren't set up for $d."
  home=$(site_get "$d" HOME_DIR)
  cur=$(deploy_current "$d") || die "No release is live yet."
  if [[ -z $target ]]; then
    if (( INTERACTIVE && ! ASSUME_YES )); then
      local -a items=()
      while IFS= read -r r; do
        [[ -n $r && $r != "$cur" ]] || continue
        meta=$(deploy_meta "$d" "$r")
        items+=("$r" "$(kv_get "$meta" COMMIT | cut -c1-8) $(kv_get "$meta" STATUS) $(kv_get "$meta" SUBJECT | cut -c1-40)")
      done < <(deploy_releases_desc "$d")
      (( ${#items[@]} )) || die "No other release to roll back to."
      target=$(ui_menu "Roll back $d" "Live: $cur. Switch to:" "${items[@]}") || die "Cancelled."
    else
      while IFS= read -r r; do
        st=$(kv_get "$(deploy_meta "$d" "$r")" STATUS)
        if [[ $r < "$cur" && $st != failed && $st != building ]]; then target=$r; break; fi
      done < <(deploy_releases_desc "$d")
    fi
  fi
  [[ -n $target ]] || die "No earlier working release to roll back to."
  [[ -d $home/releases/$target ]] || die "Release not found: $target (see: srv deploy releases $d)"
  [[ $target != "$cur" ]] || die "$target is already live."
  ui_yesno "Switch $d from $cur to $target? Database migrations are NOT rolled back." yes || die "Cancelled."
  printf '\n===== %s  rollback %s → %s =====\n' "$(date '+%F %T')" "$cur" "$target" >>"$home/logs/deploy.log"
  deploy_switch "$d" "$target"
  deploy_health "$d" || warn "The release you rolled back to fails its health check too — see: srv site logs $d"
  ok "Rolled back $d to $target"
}

deploy_log() {
  local d f
  d=$(resolve_domain "${1:-}" deploy) || exit 1
  f="$(site_get "$d" HOME_DIR)/logs/deploy.log"
  [[ -f $f ]] || die "No deploys yet for $d."
  if (( MENU_MODE )) || [[ ${2:-} != -f ]]; then tail -n 80 "$f"; else exec tail -n 80 -f "$f"; fi
}

# ── Webhooks ─────────────────────────────────────────────────────────────────
webhook_url() { local s=http; if [[ $(site_get "$1" SSL) == yes ]]; then s=https; fi; printf '%s://%s/_srv/deploy' "$s" "$1"; }

webhook_write_secret() {
  local d=$1 f="$HOOKS_DIR/$1.json" secret
  secret=$(site_get "$d" WEBHOOK_SECRET)
  if [[ -z $secret ]]; then secret=$(gen_password 40); site_set "$d" WEBHOOK_SECRET "$secret"; fi
  install -d -m 750 -o root -g srv-hook "$HOOKS_DIR"
  printf '{"secret": "%s", "branch": "%s"}\n' "$secret" "$(site_get "$d" BRANCH main)" >"$f"
  chown root:srv-hook "$f"; chmod 640 "$f"
}

webhook_show() {
  local d=$1
  echo
  printf '  %-9s %s\n' "URL" "$(webhook_url "$d")" "Secret" "$(site_get "$d" WEBHOOK_SECRET)" \
    "Branch" "$(site_get "$d" BRANCH main)  (pushes to other branches are ignored)"
  echo
  echo "  GitHub     Settings → Webhooks → Add webhook: Payload URL, Content type application/json, Secret, push event"
  echo "  GitLab     Settings → Webhooks: URL, Secret token, Push events"
  echo "  Bitbucket  Repository settings → Webhooks: URL, Secret, Repository push"
  echo "  Other      POST to the URL with the header  X-Srv-Token: <secret>"
  echo
  if [[ $(site_get "$d" SSL) != yes ]]; then warn "$d has no HTTPS yet, so the secret travels unencrypted — run: srv ssl add $d"; fi
}

deploy_webhook() {
  local d=${1:-} mode=${2:-show}
  d=$(resolve_domain "$d" deploy) || exit 1
  deploy_enabled "$d" || die "Set up deploys first: srv deploy setup $d"
  case $mode in
    on|enable)
      ensure_feature webhook
      webhook_write_secret "$d"
      site_set "$d" DEPLOY_WEBHOOK yes
      site_apply_nginx "$d" || die "Nginx update failed"
      ok "Auto-deploy webhook enabled for $d"
      webhook_show "$d" ;;
    off|disable)
      rm -f "${HOOKS_DIR:?}/${d:?}.json"
      site_set "$d" DEPLOY_WEBHOOK no
      site_apply_nginx "$d" || die "Nginx update failed"
      ok "Webhook disabled for $d" ;;
    rotate)
      [[ $(site_get "$d" DEPLOY_WEBHOOK) == yes ]] || die "The webhook is off — enable it with: srv deploy webhook $d on"
      site_set "$d" WEBHOOK_SECRET ""
      webhook_write_secret "$d"
      ok "New webhook secret — update it in your git host"
      webhook_show "$d" ;;
    show)
      [[ $(site_get "$d" DEPLOY_WEBHOOK) == yes ]] || die "The webhook is off — enable it with: srv deploy webhook $d on"
      webhook_show "$d" ;;
    *) die "Usage: srv deploy webhook <domain> on|off|show|rotate" ;;
  esac
}

# Run deploys queued by the webhook receiver (called by srv-deploy-queue.service)
deploy_run_queue() {
  local f d n=0
  [[ -d $DEPLOY_QUEUE ]] || return 0
  while (( n < 50 )); do
    f=$(find "$DEPLOY_QUEUE" -maxdepth 1 -type f -print -quit 2>/dev/null)
    [[ -n $f ]] || break
    d=$(basename "$f"); rm -f "${f:?}"; n=$(( n + 1 ))
    if valid_domain "$d" && site_exists "$d" && [[ $(site_get "$d" DEPLOY_WEBHOOK) == yes ]] && deploy_enabled "$d"; then
      info "Webhook deploy: $d"
      SRV_TRIGGER=webhook
      try deploy_now "$d"
      if (( TRY_RC != 0 )); then err "Webhook deploy of $d failed (see $(site_get "$d" HOME_DIR)/logs/deploy.log)"; fi
    else
      warn "Ignoring a queued deploy for $d (no such site, or its webhook is off)"
    fi
  done
}

cmd_deploy() {
  local sub=${1:-}
  case $sub in
    setup|init)       shift; deploy_setup "$@" ;;
    key)              shift; deploy_key "${1:-}" ;;
    webhook|hook)     shift; deploy_webhook "$@" ;;
    releases|list|ls) shift; deploy_releases_list "${1:-}" ;;
    rollback)         shift; deploy_rollback "$@" ;;
    log|logs)         shift; deploy_log "$@" ;;
    --run-queue)      deploy_run_queue ;;
    ""|menu)          menu_deploy ;;
    -*|*.*)           deploy_now "$@" ;;
    *) die "Unknown deploy command: $sub (see: srv help)" ;;
  esac
}

# =============================================================================
#  RUNTIMES — several PHP, Node.js and Python versions side by side
# =============================================================================
sites_using() {   # KEY VALUE → domains whose KEY equals VALUE
  local d out=""
  while IFS= read -r d; do
    if [[ -n $d && $(site_get "$d" "$1") == "$2" ]]; then out+="$d "; fi
  done < <(site_list_domains)
  printf '%s' "${out% }"
}

# ── PHP ──────────────────────────────────────────────────────────────────────
php_cmd_list() {
  local v def any=0
  def=$(cfg_get PHP_DEFAULT)
  printf '%s%-8s %-8s %-10s %s%s\n' "$C_BOLD" VERSION DEFAULT FPM SITES "$C_0"
  for v in $(php_versions); do
    any=1
    printf '%-8s %-8s %-10s %s\n' "$v" "$([[ $v == "$def" ]] && echo yes)" "$(svc_state "php$v-fpm")" "$(sites_using PHP "$v")"
  done
  if (( ! any )); then echo "  (no PHP installed — srv php install 8.4)"; return 0; fi
  echo "  CLI 'php' → $(readlink -f /usr/bin/php 2>/dev/null || echo none)"
}

php_cmd_default() {
  local v=${1:-}
  local -a vers=(); mapfile -t vers < <(php_versions)
  [[ -n $v ]] || die "Usage: srv php default <version>   (installed: ${vers[*]})"
  in_list "$v" "${vers[@]}" || die "PHP $v isn't installed (installed: ${vers[*]})"
  cfg_set PHP_DEFAULT "$v"
  if [[ -x /usr/bin/php$v ]]; then run update-alternatives --set php "/usr/bin/php$v" || warn "Couldn't switch the 'php' command"; fi
  ok "Default PHP is now $v — used for new sites, the 'php' command and Composer"
}

php_cmd_remove() {
  local v=${1:-} used pkgs
  local -a vers=(); mapfile -t vers < <(php_versions)
  [[ -n $v ]] || die "Usage: srv php remove <version>"
  in_list "$v" "${vers[@]}" || die "PHP $v isn't installed."
  used=$(sites_using PHP "$v")
  [[ -z $used ]] || die "PHP $v is used by: $used — move them first (srv site set <domain> PHP <other version>)"
  if [[ $(cfg_get TOOLS_PHP) == "$v" ]] && feat_has dbadmin; then die "The database tools run on PHP $v — reinstall them on another version first."; fi
  if [[ $v == "$(cfg_get PHP_DEFAULT)" ]] && (( ${#vers[@]} > 1 )); then die "PHP $v is the default — pick another first: srv php default <version>"; fi
  if (( ! ASSUME_YES )); then ui_yesno "Remove PHP $v and all its extensions?" no || die "Cancelled."; fi
  pkgs=$(dpkg-query -W -f='${Package} ${Status}\n' "php$v-*" "php$v" 2>/dev/null | awk '$NF == "installed" {print $1}' | tr '\n' ' ') || true
  [[ -n $pkgs ]] || die "No packages found for PHP $v"
  # shellcheck disable=SC2086
  run env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" -y -q purge $pkgs || die "Removing PHP $v failed — see $SRV_LOG"
  mapfile -t vers < <(php_versions)
  if (( ${#vers[@]} )); then feat_set php "${vers[*]}"; else kv_del "$SRV_STATE" php; cfg_set PHP_DEFAULT ""; fi
  ok "PHP $v removed"
}

php_cmd_ext() {
  local ext=${1:-} target=${2:-all} v any=0
  [[ $ext =~ ^[a-z0-9_-]+$ ]] || die "Usage: srv php ext <name> [version|all]   e.g. srv php ext imagick"
  local -a vers=()
  if [[ $target == all ]]; then mapfile -t vers < <(php_versions); else vers=("$target"); fi
  (( ${#vers[@]} )) || die "No PHP installed."
  for v in "${vers[@]}"; do
    [[ -d /etc/php/$v ]] || { warn "PHP $v isn't installed"; continue; }
    if pkg_installed "php$v-$ext"; then ok "php$v-$ext is already installed"; any=1; continue; fi
    if pkg_available "php$v-$ext"; then
      apt_install "php$v-$ext" && run systemctl restart "php$v-fpm" && ok "php$v-$ext installed" && any=1
    else
      warn "There's no php$v-$ext package (it may be built in — check: php$v -m)"
    fi
  done
  (( any )) || return 1
}

# ── Node.js ──────────────────────────────────────────────────────────────────
node_cmd_list() {
  local m def any=0
  def=$(cfg_get NODE_DEFAULT)
  printf '%s%-7s %-11s %-8s %s%s\n' "$C_BOLD" MAJOR VERSION DEFAULT SITES "$C_0"
  for m in $(node_versions); do
    any=1
    printf '%-7s %-11s %-8s %s\n' "$m" "$(node_full "$m")" "$([[ $m == "$def" ]] && echo yes)" "$(sites_using NODE "$m")"
  done
  if (( ! any )); then echo "  (no Node.js installed — srv node install lts)"; fi
}

node_cmd_default() {
  local m=${1:-}
  local -a vers=(); mapfile -t vers < <(node_versions)
  [[ -n $m ]] || die "Usage: srv node default <major>   (installed: ${vers[*]})"
  in_list "$m" "${vers[@]}" || die "Node.js $m isn't installed (installed: ${vers[*]})"
  cfg_set NODE_DEFAULT "$m"
  node_link_default "$m"
  feat_set node "$(node_versions | tr '\n' ' ' | sed 's/ $//') (default $m)"
  ok "Default Node.js is now $m ($(node_full "$m")) — 'node', 'npm', PM2 and PHP/static builds use it"
  if feat_has pm2; then info "Running PM2 daemons keep the old version until their app restarts (srv app restart <domain>)"; fi
}

node_cmd_remove() {
  local m=${1:-} used real
  local -a vers=(); mapfile -t vers < <(node_versions)
  [[ -n $m ]] || die "Usage: srv node remove <major>"
  in_list "$m" "${vers[@]}" || die "Node.js $m isn't installed."
  used=$(sites_using NODE "$m")
  [[ -z $used ]] || die "Node.js $m is used by: $used — move them first (srv site set <domain> NODE <other major>)"
  if [[ $m == "$(cfg_get NODE_DEFAULT)" ]] && (( ${#vers[@]} > 1 )); then die "Node.js $m is the default — pick another first: srv node default <major>"; fi
  if [[ $m == "$(cfg_get NODE_DEFAULT)" ]] && feat_has pm2; then die "PM2 runs on the default Node.js — remove PM2's apps first."; fi
  if (( ! ASSUME_YES )); then ui_yesno "Remove Node.js $m ($(node_full "$m"))?" no || die "Cancelled."; fi
  real=$(readlink -f "$NODE_ROOT/$m")
  [[ $real == "$NODE_ROOT"/versions/v* ]] || die "Unexpected install path: $real"
  rm -f "${NODE_ROOT:?}/${m:?}"
  rm -rf "${real:?}"
  if [[ $m == "$(cfg_get NODE_DEFAULT)" ]]; then
    cfg_set NODE_DEFAULT ""
    local b; for b in node npm npx corepack; do rm -f "/usr/local/bin/${b:?}"; done
  fi
  mapfile -t vers < <(node_versions)
  if (( ${#vers[@]} )); then feat_set node "${vers[*]} (default $(cfg_get NODE_DEFAULT))"; else kv_del "$SRV_STATE" node; fi
  ok "Node.js $m removed"
}

node_cmd_upgrade() {   # newest patch release of a major, then restart its apps
  local m=${1:-} before d n=0
  local -a vers=(); mapfile -t vers < <(node_versions)
  [[ -n $m ]] || die "Usage: srv node upgrade <major>"
  in_list "$m" "${vers[@]}" || die "Node.js $m isn't installed."
  before=$(node_full "$m")
  node_install_version "$m" || die "Upgrade failed — see $SRV_LOG"
  if [[ $(node_full "$m") == "$before" ]]; then ok "Node.js $m is already the newest ($before)"; return 0; fi
  ok "Node.js $m: $before → $(node_full "$m")"
  for d in $(sites_using NODE "$m"); do
    if [[ $(site_get "$d" APP_ACTIVE) == yes ]]; then info "Restarting $d"; try app_restart "$d"; n=$(( n + 1 )); fi
  done
  if (( n == 0 )); then info "No running apps use Node.js $m."; fi
}

# ── Python (extra versions through uv's standalone builds) ───────────────────
PY_ROOT="$SRV_LIB/python"
UV_DIR="$SRV_LIB/uv"

py_versions() {
  local l
  for l in "$PY_ROOT"/*; do
    if [[ -L $l && -x $l/bin/python3 ]]; then basename "$l"; fi
  done | sort -V
}

py_interpreter() {   # the python a site's virtualenv is built from
  local v; v=$(site_get "$1" PY_VERSION)
  if [[ -n $v && -x $PY_ROOT/$v/bin/python3 ]]; then printf '%s/%s/bin/python3' "$PY_ROOT" "$v"; else printf 'python3'; fi
}

uv_ensure() {
  if [[ -x $UV_DIR/bin/uv ]]; then return 0; fi
  info "Installing uv (Python version manager) from PyPI"
  apt_install python3-venv || return 1
  run python3 -m venv "$UV_DIR" || return 1
  run "$UV_DIR/bin/pip" install -q --disable-pip-version-check uv || return 1
  chmod -R a+rX "$UV_DIR"
}

py_install_version() {   # 3.12 or 3.12.7
  local ver=$1 bin dir minor
  [[ $ver =~ ^3\.[0-9]+(\.[0-9]+)?$ ]] || { err "Python version must look like 3.12 or 3.12.7"; return 1; }
  uv_ensure || { err "Couldn't install uv"; return 1; }
  install -d -m 755 "$PY_ROOT" "$PY_ROOT/versions"
  info "Installing Python $ver (standalone build)"
  run env UV_PYTHON_INSTALL_DIR="$PY_ROOT/versions" "$UV_DIR/bin/uv" python install "$ver" || return 1
  bin=$(env UV_PYTHON_INSTALL_DIR="$PY_ROOT/versions" "$UV_DIR/bin/uv" python find --python-preference only-managed "$ver" 2>>"$SRV_LOG") || bin=""
  [[ -x $bin ]] || { err "uv installed Python $ver but it couldn't be found"; return 1; }
  dir=$(dirname "$(dirname "$(readlink -f "$bin")")")
  minor=$("$bin" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  chmod -R a+rX "$dir"
  ln -sfn "$dir" "$PY_ROOT/$minor"
  ok "Python $("$bin" -c 'import platform; print(platform.python_version())') → $PY_ROOT/$minor"
}

py_cmd_list() {
  local v any=0
  printf '%s%-9s %-12s %s%s\n' "$C_BOLD" VERSION SOURCE SITES "$C_0"
  local d sys_sites=""
  while IFS= read -r d; do
    if [[ -n $d && $(site_get "$d" TYPE) == python && -z $(site_get "$d" PY_VERSION) ]]; then sys_sites+="$d "; fi
  done < <(site_list_domains)
  printf '%-9s %-12s %s\n' "$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo -)" system "${sys_sites% }"
  for v in $(py_versions); do
    any=1
    printf '%-9s %-12s %s\n' "$v" "uv" "$(sites_using PY_VERSION "$v")"
  done
  if (( ! any )); then echo "  Add versions with: srv python install 3.12"; fi
}

py_cmd_remove() {
  local v=${1:-} used real
  [[ -n $v ]] || die "Usage: srv python remove <version>"
  [[ -L $PY_ROOT/$v ]] || die "Python $v wasn't installed by srv."
  used=$(sites_using PY_VERSION "$v")
  [[ -z $used ]] || die "Python $v is used by: $used — move them first (srv site set <domain> PY_VERSION <other>)"
  if (( ! ASSUME_YES )); then ui_yesno "Remove Python $v?" no || die "Cancelled."; fi
  real=$(readlink -f "$PY_ROOT/$v")
  [[ $real == "$PY_ROOT"/versions/* ]] || die "Unexpected install path: $real"
  rm -f "${PY_ROOT:?}/${v:?}"
  rm -rf "${real:?}"
  ok "Python $v removed"
}

cmd_php() {
  local sub=${1:-list}; shift || true
  case $sub in
    list|ls)  php_cmd_list ;;
    install)  [[ -n ${1:-} ]] || die "Usage: srv php install <version>"; cmd_install php "$1" ;;
    default)  php_cmd_default "${1:-}" ;;
    remove|uninstall) php_cmd_remove "${1:-}" ;;
    ext|extension) php_cmd_ext "$@" ;;
    *) die "Usage: srv php list|install <v>|default <v>|remove <v>|ext <name> [v|all]" ;;
  esac
}

cmd_node() {
  local sub=${1:-list}; shift || true
  case $sub in
    list|ls)  node_cmd_list ;;
    install)  [[ -n ${1:-} ]] || die "Usage: srv node install <major|lts|latest>"; cmd_install node "$1" ;;
    default)  node_cmd_default "${1:-}" ;;
    upgrade|update) node_cmd_upgrade "${1:-}" ;;
    remove|uninstall) node_cmd_remove "${1:-}" ;;
    *) die "Usage: srv node list|install <major>|default <major>|upgrade <major>|remove <major>" ;;
  esac
}

cmd_python() {
  local sub=${1:-list}; shift || true
  case $sub in
    list|ls)  py_cmd_list ;;
    install)  [[ -n ${1:-} ]] || die "Usage: srv python install <3.x>"; cmd_install python "$1" ;;
    remove|uninstall) py_cmd_remove "${1:-}" ;;
    *) die "Usage: srv python list|install <3.x>|remove <3.x>" ;;
  esac
}

# =============================================================================
#  CRON — scheduled commands per site, run as the site user
# =============================================================================
cron_store() { printf '%s/cron/%s.jobs' "$SRV_DIR" "$1"; }
cron_file()  { printf '/etc/cron.d/srv-%s-jobs' "$(site_get "$1" SITE_USER)"; }

valid_schedule() {
  [[ $1 =~ ^@(reboot|hourly|daily|weekly|monthly|yearly|annually|midnight)$ ]] && return 0
  local -a f=(); read -ra f <<<"$1"
  (( ${#f[@]} == 5 )) || return 1
  local -a lo=(0 0 1 1 0) hi=(59 23 31 12 7) items=() ends=()
  local i item base step e
  for (( i = 0; i < 5; i++ )); do
    IFS=',' read -ra items <<<"${f[i]}"
    (( ${#items[@]} )) || return 1
    for item in "${items[@]}"; do
      base=${item%%/*}; step=""
      if [[ $item == */* ]]; then step=${item#*/}; [[ $step =~ ^[0-9]+$ ]] && (( 10#$step >= 1 )) || return 1; fi
      [[ $base == "*" ]] && continue
      IFS='-' read -ra ends <<<"$base"
      (( ${#ends[@]} >= 1 && ${#ends[@]} <= 2 )) || return 1
      for e in "${ends[@]}"; do
        if [[ $e =~ ^[0-9]+$ ]]; then (( 10#$e >= lo[i] && 10#$e <= hi[i] )) || return 1
        elif (( i == 3 )) && [[ ${e,,} =~ ^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)$ ]]; then :
        elif (( i == 4 )) && [[ ${e,,} =~ ^(sun|mon|tue|wed|thu|fri|sat)$ ]]; then :
        else return 1; fi
      done
    done
  done
}

cron_render() {
  local d=$1 store user home app sched cmd
  store=$(cron_store "$d"); user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR)
  if [[ ! -s $store ]]; then rm -f "$(cron_file "$d")"; return 0; fi
  {
    echo "# Managed by srv — cron jobs for $d (srv cron $d list|add|remove). Output: $home/logs/cron.log"
    echo "SHELL=/bin/bash"
    echo "PATH=$(app_path "$d")"
    while IFS=$'\t' read -r sched cmd; do
      [[ -n $sched && -n $cmd ]] || continue
      echo "$sched $user cd $app && ( set -a; [ -f $home/app.env ] && . $home/app.env; set +a; ${cmd//%/\\%} ) >>$home/logs/cron.log 2>&1"
    done <"$store"
  } >"$(cron_file "$d")"
  chmod 644 "$(cron_file "$d")"
}

cron_list() {
  local d=$1 store n=0 sched cmd
  store=$(cron_store "$d")
  if [[ ! -s $store ]]; then echo "  (no cron jobs for $d — add one: srv cron $d add \"*/5 * * * *\" \"php artisan inspire\")"; return 0; fi
  printf '%s  #  %-17s %s%s\n' "$C_BOLD" SCHEDULE COMMAND "$C_0"
  while IFS=$'\t' read -r sched cmd; do
    n=$(( n + 1 )); printf '  %-2s %-17s %s\n' "$n" "$sched" "$cmd"
  done <"$store"
  echo "  Output: $(site_get "$d" HOME_DIR)/logs/cron.log"
}

cron_add() {
  local d=$1 sched=${2:-} cmd=${3:-}
  if [[ -z $sched ]]; then sched=$(ui_input "Schedule (5 cron fields or @daily, e.g. */10 * * * *)" "") || die "Cancelled."; fi
  valid_schedule "$sched" || die "Invalid schedule: $sched (e.g. \"*/10 * * * *\", \"0 3 * * *\" or @daily)"
  if [[ -z $cmd ]]; then cmd=$(ui_input "Command (runs in $(site_get "$d" APP_DIR) as $(site_get "$d" SITE_USER))" "") || die "Cancelled."; fi
  [[ -n $cmd && $cmd != *$'\n'* && $cmd != *$'\t'* ]] || die "The command must be one line."
  install -d -m 700 "$SRV_DIR/cron"
  printf '%s\t%s\n' "$sched" "$cmd" >>"$(cron_store "$d")"
  chmod 600 "$(cron_store "$d")"
  cron_render "$d"
  ok "Cron job added for $d: $sched  $cmd"
}

cron_remove() {
  local d=$1 n=${2:-} store tmp total
  store=$(cron_store "$d")
  [[ -s $store ]] || die "$d has no cron jobs."
  if [[ -z $n ]]; then
    (( INTERACTIVE )) || die "Usage: srv cron $d remove <number>  (see: srv cron $d list)"
    local -a items=(); local i=0 sched cmd
    while IFS=$'\t' read -r sched cmd; do i=$(( i + 1 )); items+=("$i" "$sched  $cmd"); done <"$store"
    n=$(ui_menu "Cron: $d" "Remove which job?" "${items[@]}") || die "Cancelled."
  fi
  total=$(grep -c . "$store")
  n=$(dec "$n")
  [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= total )) || die "No job number $n (see: srv cron $d list)"
  tmp=$(mktemp); awk -v n="$n" 'NR != n' "$store" >"$tmp"; cat "$tmp" >"$store"; rm -f "${tmp:?}"
  cron_render "$d"
  ok "Cron job $n removed"
}

cron_run_now() {
  local d=$1 n=${2:-} store sched cmd
  store=$(cron_store "$d")
  [[ $n =~ ^[0-9]+$ ]] || die "Usage: srv cron $d run <number>"
  IFS=$'\t' read -r sched cmd < <(sed -n "${n}p" "$store") || true
  [[ -n ${cmd:-} ]] || die "No job number $n"
  info "Running job $n now: $cmd"
  app_exec "$d" "$cmd"
}

cmd_cron() {
  local d=${1:-} sub=${2:-list}
  d=$(resolve_domain "$d") || exit 1
  [[ $(site_get "$d" TYPE) != proxy ]] || die "Proxy sites have no code to run."
  case $sub in
    list|ls)        cron_list "$d" ;;
    add)            cron_add "$d" "${3:-}" "${4:-}" ;;
    remove|rm|del)  cron_remove "$d" "${3:-}" ;;
    run)            cron_run_now "$d" "${3:-}" ;;
    *) die "Usage: srv cron <domain> list|add \"<schedule>\" \"<command>\"|remove <n>|run <n>" ;;
  esac
}

# =============================================================================
#  DATABASE TOOLS — Adminer / phpMyAdmin behind a secret URL, a password and
#  (optionally) an IP allowlist, running in their own PHP-FPM pool as srv-tools
# =============================================================================
TOOLS_WEB="$SRV_LIB/tools-web"        # document root: <secret path>/{adminer,phpmyadmin}
TOOLS_DIR="$SRV_LIB/tools"            # downloaded software
TOOLS_VAR="/var/lib/srv-tools"        # sessions, temp files
TOOLS_HTPASSWD="/etc/nginx/srv-tools.htpasswd"
TOOLS_CONF="/etc/nginx/srv-tools.conf"

tools_url() {
  local h scheme=http path; h=$(cfg_get TOOLS_HOST _); path=$(cfg_get TOOLS_PATH)
  if [[ $h == _ ]]; then h=$(hostname -I 2>/dev/null | awk '{print $1}'); h=${h:-<server-ip>}
  elif [[ $(site_get "$h" SSL) == yes ]]; then scheme=https; fi
  printf '%s://%s/%s/' "$scheme" "$h" "$path"
}

ask_dbadmin() {
  if [[ -z $OPT_TOOLS ]]; then
    OPT_TOOLS=$(ui_menu "Database tools" "Which web database tool?" \
      adminer    "Adminer — one file, MySQL/MariaDB + PostgreSQL (recommended)" \
      phpmyadmin "phpMyAdmin — MySQL/MariaDB" \
      both       "Both") || die "Cancelled."
  fi
  if [[ -z $OPT_TOOLS_HOST ]] && (( ! INTERACTIVE )); then
    die "Add --host <domain> to choose where the tools are served (or --host _ for the server IP)."
  fi
  if [[ -z $OPT_TOOLS_HOST ]]; then
    local -a items=(); local d
    while IFS= read -r d; do
      if [[ -n $d ]]; then items+=("$d" "$(site_get "$d" TYPE)$([[ $(site_get "$d" SSL) == yes ]] && echo ", https")"); fi
    done < <(site_list_domains)
    items+=(_ "The server's IP address (plain HTTP — use only with an IP allowlist)")
    OPT_TOOLS_HOST=$(ui_menu "Database tools" "Serve the tools under which address? (a secret path is added)" "${items[@]}") || die "Cancelled."
  fi
  if [[ -z ${OPT_TOOLS_ALLOW+x} ]]; then
    OPT_TOOLS_ALLOW=$(ui_input "Only allow these IP addresses/ranges (space-separated, blank = any, e.g. 203.0.113.7 10.0.0.0/8)" "$(cfg_get TOOLS_ALLOW)" empty) || die "Cancelled."
  fi
}

tools_install_adminer() {
  local aurl="" afile="$TMP_DIR/adminer.php" ver=""
  aurl=$(curl -fsSL --max-time 20 https://api.github.com/repos/vrana/adminer/releases/latest 2>/dev/null \
        | grep -oE '"browser_download_url": *"[^"]+/adminer-[0-9.]+\.php"' | head -n 1 | sed -E 's/.*"(https[^"]+)"$/\1/') || url=""
  if [[ -n $aurl ]] && run curl -fsSL -o "$afile" "$aurl"; then
    ver=$(basename "$aurl" .php); ver=${ver#adminer-}
  else
    warn "Couldn't download the latest Adminer from GitHub — using the distro package instead"
    apt_install adminer || return 1
    afile=/usr/share/adminer/adminer.php
    if [[ ! -f $afile ]]; then afile=$(find /usr/share/adminer -maxdepth 2 -type f -name adminer.php -print -quit 2>/dev/null); fi
    [[ -n $afile ]] || { err "The adminer package has no adminer.php"; return 1; }
    ver="$(dpkg-query -W -f='${Version}' adminer 2>/dev/null) (distro)"
  fi
  "/usr/bin/php$(cfg_get TOOLS_PHP)" -l "$afile" >/dev/null 2>&1 || { err "The Adminer file doesn't look like valid PHP"; return 1; }
  install -m 644 "$afile" "$TOOLS_DIR/adminer.php"
  cfg_set TOOLS_ADMINER "$ver"
  ok "Adminer $ver installed"
}

tools_install_pma() {   # [tarball] — latest from phpmyadmin.net, or a local file
  local file=${1:-} ver url tb="$TMP_DIR/pma.tar.gz" sum new="$TOOLS_DIR/phpmyadmin.new"
  if [[ -n $file ]]; then
    [[ -f $file ]] || { err "Not found: $file"; return 1; }
    cp "$file" "$tb"; ver="(from $(basename "$file"))"
  else
    ver=$(curl -fsSL --max-time 20 https://www.phpmyadmin.net/home_page/version.txt 2>/dev/null | head -n 1) || ver=""
    [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { err "Couldn't get the latest phpMyAdmin version (offline? install from a file: srv tools install phpmyadmin --file phpMyAdmin-x.y.z-all-languages.tar.gz)"; return 1; }
    url="https://files.phpmyadmin.net/phpMyAdmin/$ver/phpMyAdmin-$ver-all-languages.tar.gz"
    run curl -fsSL -o "$tb" "$url" || return 1
    sum=$(curl -fsSL "$url.sha256" 2>/dev/null | awk '{print $1}') || sum=""
    [[ -n $sum && $(sha256sum "$tb" | awk '{print $1}') == "$sum" ]] || { err "phpMyAdmin checksum mismatch — aborting"; return 1; }
  fi
  rm -rf "${new:?}"; mkdir -p "$new"
  tar -xzf "$tb" -C "$new" --strip-components=1 --no-same-owner || { err "Couldn't unpack phpMyAdmin"; return 1; }
  [[ -f $new/index.php ]] || { err "That archive doesn't contain phpMyAdmin"; return 1; }
  local secret; secret=$(cfg_get TOOLS_PMA_SECRET); if [[ -z $secret ]]; then secret=$(gen_password 32); cfg_set TOOLS_PMA_SECRET "$secret"; fi
  cat >"$new/config.inc.php" <<EOF
<?php
// Managed by srv — regenerated by 'srv tools update'
\$cfg['blowfish_secret'] = '$secret';
\$i = 1;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '$TOOLS_VAR/tmp';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['VersionCheck'] = false;
EOF
  chown -R root:root "$new"; chmod -R a+rX,go-w "$new"
  chown root:srv-tools "$new/config.inc.php"; chmod 640 "$new/config.inc.php"
  rm -rf "${TOOLS_DIR:?}/phpmyadmin"; mv "$new" "$TOOLS_DIR/phpmyadmin"
  if [[ $ver != \(* ]]; then cfg_set TOOLS_PMA "$ver"; else cfg_set TOOLS_PMA "installed $ver"; fi
  ok "phpMyAdmin $ver installed"
}

tools_render() {   # web folder, PHP pool and the Nginx location
  local path php allow ip
  path=$(cfg_get TOOLS_PATH); php=$(cfg_get TOOLS_PHP); allow=$(cfg_get TOOLS_ALLOW)
  # Web folder — only the secret path exists, so nothing else is reachable
  install -d -m 755 "$TOOLS_WEB"
  find "$TOOLS_WEB" -mindepth 1 -maxdepth 1 -name '_srv-tools-*' ! -name "$path" -exec rm -rf {} + 2>/dev/null || true
  install -d -m 755 "$TOOLS_WEB/$path"
  local links=""
  if [[ -f $TOOLS_DIR/adminer.php ]]; then
    install -d -m 755 "$TOOLS_WEB/$path/adminer"
    ln -sfn "$TOOLS_DIR/adminer.php" "$TOOLS_WEB/$path/adminer/index.php"
    links+='<li><a href="adminer/">Adminer</a> — MySQL/MariaDB and PostgreSQL</li>'
  else
    rm -rf "${TOOLS_WEB:?}/${path:?}/adminer"
  fi
  if [[ -d $TOOLS_DIR/phpmyadmin ]]; then
    ln -sfn "$TOOLS_DIR/phpmyadmin" "$TOOLS_WEB/$path/phpmyadmin"
    links+='<li><a href="phpmyadmin/">phpMyAdmin</a> — MySQL/MariaDB</li>'
  else
    rm -f "${TOOLS_WEB:?}/${path:?}/phpmyadmin"
  fi
  cat >"$TOOLS_WEB/$path/index.php" <<EOF
<?php header('X-Robots-Tag: noindex'); ?><!doctype html><html><head><meta charset="utf-8"><title>Database tools</title>
<style>body{font-family:system-ui,sans-serif;margin:3rem;line-height:1.6}</style></head>
<body><h1>Database tools</h1><ul>$links</ul><p>Log in with a database user and password (create an admin login with: srv tools db-user).</p></body></html>
EOF
  chmod 644 "$TOOLS_WEB/$path/index.php"

  # PHP-FPM pool, isolated from the sites
  local f
  for f in /etc/php/*/fpm/pool.d/srv-tools.conf; do
    if [[ -f $f && $f != "/etc/php/$php/fpm/pool.d/srv-tools.conf" ]]; then rm -f "$f"; local ov=${f#/etc/php/}; ov=${ov%%/*}; run systemctl reload "php$ov-fpm" || true; fi
  done
  cat >"/etc/php/$php/fpm/pool.d/srv-tools.conf" <<EOF
; Managed by srv — Adminer / phpMyAdmin (srv tools)
[srv-tools]
user = srv-tools
group = srv-tools
listen = /run/php/srv-tools.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 60s
chdir = /
php_admin_value[open_basedir] = $TOOLS_WEB:$TOOLS_DIR:$TOOLS_VAR:/tmp
php_admin_value[session.save_path] = $TOOLS_VAR/sessions
php_admin_value[upload_tmp_dir] = $TOOLS_VAR/tmp
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[memory_limit] = 512M
php_admin_value[max_execution_time] = 300
php_admin_flag[expose_php] = off
EOF
  "/usr/sbin/php-fpm$php" -t >>"$SRV_LOG" 2>&1 || { err "PHP-FPM rejected the tools pool — see $SRV_LOG"; return 1; }
  run systemctl reload "php$php-fpm" || return 1

  # Nginx location (included by the host site, or by the default server)
  {
    echo "# Managed by srv — database tools (srv tools). Don't edit; use srv tools allow|password|host."
    echo "location ^~ /$path/ {"
    echo "    root $TOOLS_WEB;"
    echo "    index index.php;"
    echo "    auth_basic \"Restricted\";"
    echo "    auth_basic_user_file $TOOLS_HTPASSWD;"
    if [[ -n $allow ]]; then
      for ip in $allow; do echo "    allow $ip;"; done
      echo "    deny all;"
    fi
    echo "    client_max_body_size 256m;"
    echo "    access_log /var/log/nginx/srv-tools.access.log;"
    echo "    add_header X-Robots-Tag \"noindex, nofollow\" always;"
    echo "    add_header X-Frame-Options \"SAMEORIGIN\" always;"
    echo "    add_header X-Content-Type-Options \"nosniff\" always;"
    echo "    location ~ \\.php\$ {"
    echo "        try_files \$uri =404;"
    echo "        fastcgi_pass unix:/run/php/srv-tools.sock;"
    echo "        include fastcgi_params;"
    echo "        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;"
    echo "        fastcgi_param HTTP_PROXY \"\";"
    echo "        fastcgi_read_timeout 300s;"
    echo "    }"
    echo "}"
  } >"$TOOLS_CONF"
}

# Re-render whichever server{} includes the tools (a site, or the default server)
tools_apply_host() {
  local h; h=$(cfg_get TOOLS_HOST _)
  if [[ $h == _ ]]; then nginx_write_default && nginx_reload
  else site_exists "$h" || { warn "Tools host $h no longer exists — moving the tools to the server IP"; cfg_set TOOLS_HOST _; nginx_write_default && nginx_reload; return; }
    site_apply_nginx "$h"
  fi
}

tools_set_password() {
  local user pass hash
  user=$(cfg_get TOOLS_USER admin); pass=$(gen_password 20)
  hash=$(openssl passwd -6 -stdin <<<"$pass") || { err "openssl passwd failed"; return 1; }
  printf '%s:%s\n' "$user" "$hash" >"$TOOLS_HTPASSWD"
  chown root:www-data "$TOOLS_HTPASSWD"; chmod 640 "$TOOLS_HTPASSWD"
  TOOLS_NEW_PASS=$pass
}

mod_dbadmin() {
  step "Installing the database tools"
  local -a vers=(); mapfile -t vers < <(php_versions)
  (( ${#vers[@]} )) || { err "PHP is required — run: srv install php"; return 1; }
  local php; php=$(cfg_get TOOLS_PHP); if [[ -z $php || ! -d /etc/php/$php ]]; then php=$(cfg_get PHP_DEFAULT "${vers[-1]}"); fi
  in_list "$php" "${vers[@]}" || php=${vers[-1]}
  cfg_set TOOLS_PHP "$php"
  local ext; for ext in mysql pgsql mbstring xml zip; do
    if ! pkg_installed "php$php-$ext" && pkg_available "php$php-$ext"; then apt_install "php$php-$ext" || true; fi
  done
  if ! id srv-tools &>/dev/null; then
    run useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin srv-tools || return 1
  fi
  install -d -m 755 "$TOOLS_DIR"
  install -d -m 700 -o srv-tools -g srv-tools "$TOOLS_VAR" "$TOOLS_VAR/tmp" "$TOOLS_VAR/sessions"
  local want=${OPT_TOOLS:-adminer} failed=0
  if [[ $want == adminer || $want == both ]]; then tools_install_adminer || failed=1; fi
  if [[ $want == phpmyadmin || $want == both ]]; then tools_install_pma "${OPT_TOOLS_FILE:-}" || failed=1; fi
  if [[ ! -f $TOOLS_DIR/adminer.php && ! -d $TOOLS_DIR/phpmyadmin ]]; then err "No database tool could be installed"; return 1; fi
  if [[ -z $(cfg_get TOOLS_PATH) ]]; then cfg_set TOOLS_PATH "_srv-tools-$(openssl rand -hex 10)"; fi
  cfg_set TOOLS_HOST "${OPT_TOOLS_HOST:-$(cfg_get TOOLS_HOST _)}"
  if [[ -n ${OPT_TOOLS_ALLOW+x} ]]; then cfg_set TOOLS_ALLOW "$OPT_TOOLS_ALLOW"; fi
  local ip; for ip in $(cfg_get TOOLS_ALLOW); do [[ $ip =~ ^[0-9A-Fa-f:./]+$ ]] || { err "Invalid IP or range: $ip"; return 1; }; done
  TOOLS_NEW_PASS=""
  if [[ ! -s $TOOLS_HTPASSWD ]]; then tools_set_password || return 1; fi
  tools_render || return 1
  tools_apply_host || return 1
  feat_set dbadmin "$( [[ -f $TOOLS_DIR/adminer.php ]] && echo adminer)$( [[ -d $TOOLS_DIR/phpmyadmin ]] && echo " phpmyadmin") on $(cfg_get TOOLS_HOST _)"
  ok "Database tools ready"
  tools_show
  if (( failed )); then warn "Some tools failed to install — see above"; fi
}

tools_show() {
  feat_has dbadmin || { echo "Database tools aren't installed — run: srv tools install"; return 0; }
  echo
  printf '  %-12s %s\n' "URL" "$(tools_url)" "Login" "$(cfg_get TOOLS_USER admin)  $( [[ -n ${TOOLS_NEW_PASS:-} ]] && echo "/ $TOOLS_NEW_PASS   ← shown once" || echo "(reset with: srv tools password)")" \
    "Allowed IPs" "$(x=$(cfg_get TOOLS_ALLOW); echo "${x:-any}")" \
    "Adminer" "$(x=$(cfg_get TOOLS_ADMINER); [[ -f $TOOLS_DIR/adminer.php ]] && echo "${x:-installed}" || echo "not installed")" \
    "phpMyAdmin" "$(x=$(cfg_get TOOLS_PMA); [[ -d $TOOLS_DIR/phpmyadmin ]] && echo "${x:-installed}" || echo "not installed")"
  echo
  echo "  Then log in with a database user — sites' users work, or create an admin: srv tools db-user"
  echo "  (MariaDB/MySQL 'root' can't log in here: it only works from the server's own shell.)"
  if [[ $(cfg_get TOOLS_HOST _) == _ && -z $(cfg_get TOOLS_ALLOW) ]]; then
    warn "The tools are on plain HTTP and open to any IP — restrict them: srv tools allow \"<your IP>\""
  elif [[ $(cfg_get TOOLS_HOST _) != _ && $(site_get "$(cfg_get TOOLS_HOST)" SSL) != yes ]]; then
    warn "$(cfg_get TOOLS_HOST) has no HTTPS — passwords travel unencrypted. Run: srv ssl add $(cfg_get TOOLS_HOST)"
  fi
}

tools_db_user() {   # create / reset an all-powerful DB login for the tools
  local eng="" a pass u=srv_admin
  for a in "$@"; do case $a in --pg|--pgsql|--postgres) eng=pgsql ;; --mysql|--mariadb) eng=mysql ;; esac; done
  db_pick_engine "$eng"
  ui_yesno "Create/reset the database superuser '$u' on $(eng_label "$DB_ENG")? It can read and change every database." yes || die "Cancelled."
  pass=$(gen_password 24)
  if [[ $DB_ENG == pgsql ]]; then
    if pg_user_exists "$u"; then pg_run >>"$SRV_LOG" 2>&1 <<SQL || die "Failed — see $SRV_LOG"
ALTER ROLE "$u" WITH LOGIN SUPERUSER PASSWORD '$pass';
SQL
    else pg_run >>"$SRV_LOG" 2>&1 <<SQL || die "Failed — see $SRV_LOG"
CREATE ROLE "$u" WITH LOGIN SUPERUSER PASSWORD '$pass';
SQL
    fi
  else
    db_run >>"$SRV_LOG" 2>&1 <<SQL || die "Failed — see $SRV_LOG"
CREATE USER IF NOT EXISTS '$u'@'localhost' IDENTIFIED BY '$pass';
ALTER USER '$u'@'localhost' IDENTIFIED BY '$pass';
GRANT ALL PRIVILEGES ON *.* TO '$u'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  fi
  ok "$(eng_label "$DB_ENG") login for the tools: $u / $pass   (server: localhost)"
}

tools_remove() {
  feat_has dbadmin || die "The database tools aren't installed."
  if (( ! ASSUME_YES )); then ui_yesno "Remove Adminer / phpMyAdmin from this server?" no || die "Cancelled."; fi
  local php; php=$(cfg_get TOOLS_PHP)
  rm -f "$TOOLS_CONF" "$TOOLS_HTPASSWD" "/etc/php/$php/fpm/pool.d/srv-tools.conf"
  rm -rf "${TOOLS_WEB:?}" "${TOOLS_DIR:?}"
  kv_del "$SRV_STATE" dbadmin
  local h; h=$(cfg_get TOOLS_HOST _)
  if [[ $h == _ ]]; then nginx_write_default && nginx_reload || true; elif site_exists "$h"; then site_apply_nginx "$h" || true; fi
  run systemctl reload "php$php-fpm" || true
  ok "Database tools removed (the srv_admin database login, if any, still exists)"
}

cmd_tools() {
  local sub=${1:-status}; shift || true
  case $sub in
    status|show|info) tools_show ;;
    install)
      local t="" file=""
      while (( $# )); do
        case $1 in
          adminer|phpmyadmin|both) t=$1; shift ;;
          --file) need_val "$@"; file=$2; shift 2 ;;
          --host) need_val "$@"; OPT_TOOLS_HOST=$2; shift 2 ;;
          --allow) need_val "$@"; OPT_TOOLS_ALLOW=$2; shift 2 ;;
          *) die "Usage: srv tools install [adminer|phpmyadmin|both] [--host <domain|_>] [--allow \"ips\"] [--file pma.tar.gz]" ;;
        esac
      done
      if [[ -n $t ]]; then OPT_TOOLS=$t; fi   # installs just that tool; an installed other one stays
      OPT_TOOLS_FILE=$file
      if [[ -n $OPT_TOOLS_HOST && $OPT_TOOLS_HOST != _ ]]; then site_exists "$OPT_TOOLS_HOST" || die "Site not found: $OPT_TOOLS_HOST"; fi
      if ! feat_has dbadmin; then ask_dbadmin; fi
      if ! feat_has base; then try mod_base; fi
      try mod_dbadmin
      (( TRY_RC == 0 )) || die "Installing the database tools failed — see $SRV_LOG" ;;
    update)
      feat_has dbadmin || die "The database tools aren't installed."
      if [[ -f $TOOLS_DIR/adminer.php ]]; then tools_install_adminer || warn "Adminer update failed"; fi
      if [[ -d $TOOLS_DIR/phpmyadmin ]]; then tools_install_pma "${1:-}" || warn "phpMyAdmin update failed"; fi
      tools_render && tools_apply_host ;;
    password|passwd)
      feat_has dbadmin || die "The database tools aren't installed."
      if [[ -n ${1:-} ]]; then [[ $1 =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "Invalid user name"; cfg_set TOOLS_USER "$1"; fi
      tools_set_password || die "Couldn't set the password"
      ok "New login for the database tools: $(cfg_get TOOLS_USER admin) / $TOOLS_NEW_PASS" ;;
    allow)
      feat_has dbadmin || die "The database tools aren't installed."
      local iplist=${1-}; if [[ $iplist == off || $iplist == any ]]; then iplist=""; fi
      local ip; for ip in $iplist; do [[ $ip =~ ^[0-9A-Fa-f:./]+$ ]] || die "Invalid IP or range: $ip"; done
      cfg_set TOOLS_ALLOW "$iplist"
      tools_render && tools_apply_host
      ok "Database tools allowed from: ${iplist:-any IP}" ;;
    host)
      feat_has dbadmin || die "The database tools aren't installed."
      local h=${1:-}; [[ -n $h ]] || die "Usage: srv tools host <domain|_>"
      if [[ $h != _ ]]; then site_exists "$h" || die "Site not found: $h"; fi
      local old; old=$(cfg_get TOOLS_HOST _)
      cfg_set TOOLS_HOST "$h"
      if [[ $old == _ ]]; then nginx_write_default && nginx_reload; elif site_exists "$old"; then site_apply_nginx "$old"; fi
      tools_apply_host
      feat_set dbadmin "$(feat_get dbadmin | sed 's/ on .*//') on $h"
      ok "Database tools moved to $(tools_url)" ;;
    db-user)  tools_db_user "$@" ;;
    remove|uninstall) tools_remove ;;
    *) die "Usage: srv tools status|install|update|password|allow \"ips\"|host <domain>|db-user|remove" ;;
  esac
}

# =============================================================================
#  CHECKS, ALERTS, DASHBOARD
# =============================================================================
CHECK_RESULTS=()
declare -A PROBE_CODE=() PROBE_MS=()
chk() { CHECK_RESULTS+=("$1|$2|$3"); }   # level(ok|warn|fail|info) name detail

human_age() {
  local s=$1
  if (( s < 120 )); then echo "${s}s"; elif (( s < 7200 )); then echo "$(( s / 60 ))m"
  elif (( s < 172800 )); then echo "$(( s / 3600 ))h"; else echo "$(( s / 86400 ))d"; fi
}

http_probe() {   # domain → "code seconds"
  local d=$1 path; path=$(site_get "$d" DEPLOY_HEALTH_PATH /)
  if [[ $(site_get "$d" SSL) == yes ]]; then
    curl -s -o /dev/null -w '%{http_code} %{time_total}' -k --noproxy '*' --max-time 8 --resolve "$d:443:127.0.0.1" "https://$d$path" 2>/dev/null || true
  else
    curl -s -o /dev/null -w '%{http_code} %{time_total}' --noproxy '*' --max-time 8 -H "Host: $d" "http://127.0.0.1$path" 2>/dev/null || true
  fi
}

probe_sites() {   # all enabled sites in parallel → PROBE_CODE / PROBE_MS
  local d dir r code t
  dir=$(mktemp -d "$TMP_DIR/probe.XXXXXX")
  while IFS= read -r d; do
    if [[ -n $d && $(site_get "$d" ENABLED yes) == yes ]]; then ( http_probe "$d" >"$dir/$d" ) & fi
  done < <(site_list_domains)
  wait
  PROBE_CODE=(); PROBE_MS=()
  for r in "$dir"/*; do
    [[ -f $r ]] || continue
    d=$(basename "$r"); read -r code t <"$r" || true
    PROBE_CODE[$d]=${code:-000}
    PROBE_MS[$d]=$(awk -v t="${t:-0}" 'BEGIN { printf "%d", t * 1000 }')
  done
}

run_checks() {
  CHECK_RESULTS=()
  local p pct mounts avail cores load5 d s v days code st newest age home
  # Disk (each filesystem once)
  mounts=$(df -P / /var /var/www 2>/dev/null | awk 'NR > 1 {print $6}' | sort -u)
  for p in $mounts; do
    pct=$(df -P "$p" | awk 'NR == 2 {gsub("%", "", $5); print $5}')
    if (( pct >= 95 )); then chk fail "disk $p" "$pct% used"
    elif (( pct >= 85 )); then chk warn "disk $p" "$pct% used"
    else chk ok "disk $p" "$pct% used"; fi
  done
  # Memory
  avail=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d", a * 100 / t}' /proc/meminfo)
  if (( avail < 5 )); then chk fail memory "only $avail% available"
  elif (( avail < 10 )); then chk warn memory "only $avail% available"
  else chk ok memory "$avail% available"; fi
  # Load
  cores=$(nproc 2>/dev/null || echo 1); load5=$(cut -d' ' -f2 /proc/loadavg)
  if awk -v l="$load5" -v c="$cores" 'BEGIN { exit !(l > c * 2) }'; then chk warn load "5-min load $load5 on $cores CPU(s)"
  else chk ok load "5-min load $load5 on $cores CPU(s)"; fi
  # Services
  local -a svcs=()
  if feat_has nginx; then svcs+=(nginx); fi
  for v in $(php_versions); do svcs+=("php$v-fpm"); done
  if feat_has database; then svcs+=("$( [[ $(cfg_get DB_ENGINE) == mysql ]] && echo mysql || echo mariadb )"); fi
  if feat_has postgres; then svcs+=("postgresql@$(cfg_get PG_VERSION)-main"); fi
  if feat_has redis; then svcs+=(redis-server); fi
  if feat_has supervisor; then svcs+=(supervisor); fi
  if feat_has webhook; then svcs+=(srv-webhook); fi
  if feat_has fail2ban; then svcs+=(fail2ban); fi
  svcs+=(cron)
  for s in "${svcs[@]}"; do
    if [[ $(svc_state "$s") == active ]]; then chk ok "service $s" running; else chk fail "service $s" "$(svc_state "$s")"; fi
  done
  # Sites, certificates, apps, workers
  probe_sites
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    home=$(site_get "$d" HOME_DIR)
    if [[ $(site_get "$d" ENABLED yes) != yes ]]; then chk info "site $d" disabled; continue; fi
    if [[ -f $home/.maintenance ]]; then chk info "site $d" "maintenance mode"
    else
      code=${PROBE_CODE[$d]:-000}
      if [[ $code =~ ^[1-4][0-9][0-9]$ ]]; then chk ok "site $d" "HTTP $code in ${PROBE_MS[$d]:-?}ms"
      else chk fail "site $d" "HTTP ${code/000/no response}"; fi
    fi
    if [[ $(site_get "$d" SSL) == yes ]]; then
      if days=$(cert_days_left "$d"); then
        if (( days < 3 )); then chk fail "cert $d" "expires in $days days"
        elif (( days < 14 )); then chk warn "cert $d" "expires in $days days (renewal should have happened — check: srv ssl renew-test)"
        else chk ok "cert $d" "$days days left"; fi
      else chk fail "cert $d" "certificate missing"; fi
    fi
    if is_app_type "$(site_get "$d" TYPE)" && [[ $(site_get "$d" APP_ACTIVE) == yes ]]; then
      st=$(pm_state "$d")
      if [[ $st == running ]] && port_in_use "$(site_get "$d" PORT)"; then chk ok "app $d" "running ($(app_pm "$d"))"
      else chk fail "app $d" "$st, port $(site_get "$d" PORT) $(port_in_use "$(site_get "$d" PORT)" && echo open || echo closed)"; fi
    fi
    if [[ -f $(laravel_conf "$d") ]]; then
      st=$(laravel_state "$d")
      if [[ $st =~ ^([0-9]+)/([0-9]+)\ running$ && ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]]; then chk ok "workers $d" "$st"
      else chk warn "workers $d" "$st"; fi
    fi
  done < <(site_list_domains)
  # Backups
  if feat_has backup; then
    newest=$(find "$BACKUP_DIR" -type f -name '*.gz' ! -name '*before-restore*' -printf '%T@\n' 2>/dev/null | sort -n | tail -n 1 | cut -d. -f1)
    if [[ -z $newest ]]; then chk warn backups "no backups yet"
    else
      age=$(( $(date +%s) - newest ))
      if (( age > 93600 )); then chk warn backups "newest is $(human_age "$age") old"; else chk ok backups "newest is $(human_age "$age") old"; fi
    fi
  fi
  if [[ -f /var/run/reboot-required ]]; then chk warn reboot "a reboot is required to finish updates"; fi
}

check_counts() {   # → "fails warns"
  local r f=0 w=0
  for r in "${CHECK_RESULTS[@]}"; do case ${r%%|*} in fail) f=$(( f + 1 )) ;; warn) w=$(( w + 1 )) ;; esac; done
  echo "$f $w"
}

cmd_check() {
  local notify=0 quiet=0 a r lvl name detail icon f w
  for a in "$@"; do case $a in --notify) notify=1 ;; --quiet|-q) quiet=1 ;; *) die "Usage: srv check [--notify] [--quiet]" ;; esac; done
  run_checks
  read -r f w < <(check_counts)
  if (( ! quiet )); then
    for r in "${CHECK_RESULTS[@]}"; do
      IFS='|' read -r lvl name detail <<<"$r"
      case $lvl in
        ok)   icon="$C_G✓$C_0" ;;
        warn) icon="$C_Y!$C_0" ;;
        fail) icon="$C_R✗$C_0" ;;
        *)    icon="$C_D·$C_0" ;;
      esac
      printf ' %s %-40s %s\n' "$icon" "$name" "$detail"
    done
    echo
    if (( f + w == 0 )); then ok "All ${#CHECK_RESULTS[@]} checks passed"; else warn "$f failing, $w warning"; fi
  fi
  if (( notify )); then notify_changes; fi
  if (( f )); then return 2; fi
  if (( w )); then return 1; fi
  return 0
}

# ── Notifications (Telegram, Slack, Discord, any webhook) ────────────────────
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

notify_send() {   # message — returns non-zero if delivery failed
  local t msg; t=$(cfg_get NOTIFY_TYPE)
  [[ -n $t ]] || return 0
  msg="[$(hostname)] $1"
  log "NOTIFY $t: ${1%%$'\n'*}"
  case $t in
    telegram)
      printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(cfg_get NOTIFY_TOKEN)" \
        | curl -fsS --max-time 15 -K - --data-urlencode "chat_id=$(cfg_get NOTIFY_CHAT)" --data-urlencode "text=$msg" -o /dev/null 2>>"$SRV_LOG" ;;
    discord)
      printf 'url = "%s"\n' "$(cfg_get NOTIFY_URL)" | curl -fsS --max-time 15 -K - -H 'Content-Type: application/json' \
        --data "{\"content\": \"$(json_escape "$msg")\"}" -o /dev/null 2>>"$SRV_LOG" ;;
    slack|webhook)
      printf 'url = "%s"\n' "$(cfg_get NOTIFY_URL)" | curl -fsS --max-time 15 -K - -H 'Content-Type: application/json' \
        --data "{\"text\": \"$(json_escape "$msg")\", \"host\": \"$(hostname)\"}" -o /dev/null 2>>"$SRV_LOG" ;;
    *) return 0 ;;
  esac
}

# Alert only when something changes (new problem, or recovered)
notify_changes() {
  local state=/var/lib/srv/check.state r lvl name detail key prev
  local -A old=()
  local -a lines=()
  install -d -m 755 /var/lib/srv
  if [[ -f $state ]]; then
    while IFS='=' read -r key lvl; do if [[ -n $key ]]; then old[$key]=$lvl; fi; done <"$state"
  fi
  : >"$state.new"
  for r in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r lvl name detail <<<"$r"
    [[ $lvl == info ]] && lvl=ok
    key=${name//[^A-Za-z0-9]/_}
    prev=${old[$key]:-ok}
    if [[ $lvl != "$prev" ]]; then
      if [[ $lvl == ok ]]; then lines+=("✅ $name recovered — $detail")
      elif [[ $lvl == fail ]]; then lines+=("❌ $name — $detail")
      else lines+=("⚠️ $name — $detail"); fi
    fi
    echo "$key=$lvl" >>"$state.new"
  done
  mv -f "$state.new" "$state"
  if (( ${#lines[@]} )); then
    notify_send "$(printf '%s\n' "${lines[@]}")" || warn "Couldn't send the alert — see $SRV_LOG"
  fi
}

notify_setup() {
  local t="" token="" chat="" url=""
  while (( $# )); do
    case $1 in
      --telegram) need_val "$@"; t=telegram; token=$2; shift 2 ;;
      --chat)     need_val "$@"; chat=$2; shift 2 ;;
      --slack|--discord|--webhook) need_val "$@"; t=${1#--}; url=$2; shift 2 ;;
      *) die "Usage: srv notify setup [--telegram <bot token> --chat <id> | --slack <url> | --discord <url> | --webhook <url>]" ;;
    esac
  done
  if [[ -z $t ]]; then
    t=$(ui_menu "Alerts" "Send alerts to:" \
      telegram "Telegram (a bot from @BotFather)" \
      slack    "Slack (incoming webhook URL)" \
      discord  "Discord (channel webhook URL)" \
      webhook  "Any URL — POST JSON {\"text\": …}") || die "Cancelled."
  fi
  case $t in
    telegram)
      if [[ -z $token ]]; then token=$(ui_input "Bot token from @BotFather (looks like 123456:ABC…)" "") || die "Cancelled."; fi
      [[ $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "That doesn't look like a bot token."
      if [[ -z $chat ]]; then
        info "Send any message to your bot now, then continue — srv will look up your chat id."
        if (( INTERACTIVE )); then read -r -p "Press Enter after you've messaged the bot… " _ </dev/tty || true; fi
        chat=$(printf 'url = "https://api.telegram.org/bot%s/getUpdates"\n' "$token" | curl -fsS --max-time 15 -K - 2>/dev/null \
               | grep -oE '"chat":\{"id":-?[0-9]+' | tail -n 1 | grep -oE -- '-?[0-9]+$') || chat=""
        if [[ -z $chat ]]; then chat=$(ui_input "Couldn't find it automatically — chat id" "") || die "Cancelled."; fi
      fi
      [[ $chat =~ ^-?[0-9]+$ ]] || die "The chat id must be a number."
      cfg_set NOTIFY_TOKEN "$token"; cfg_set NOTIFY_CHAT "$chat"; cfg_set NOTIFY_URL "" ;;
    slack|discord|webhook)
      if [[ -z $url ]]; then url=$(ui_input "Webhook URL" "") || die "Cancelled."; fi
      [[ $url =~ ^https?://[^[:space:]\"]+$ ]] || die "That doesn't look like a URL."
      cfg_set NOTIFY_URL "$url"; cfg_set NOTIFY_TOKEN ""; cfg_set NOTIFY_CHAT "" ;;
    *) die "Unknown channel: $t" ;;
  esac
  cfg_set NOTIFY_TYPE "$t"
  if notify_send "srv alerts are set up ✅ You'll hear about failing services, sites, certificates, apps, backups and deploys."; then
    ok "Test message sent via $t"
  else
    cfg_set NOTIFY_TYPE ""
    die "Sending the test message failed — check the details (see $SRV_LOG). Alerts are off."
  fi
  self_install
  cat >/etc/cron.d/srv-check <<EOF
# Managed by srv — health checks every 5 minutes, alerts on changes
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root $SRV_BIN check --notify --quiet >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/srv-check
  rm -f /var/lib/srv/check.state   # first run reports current problems
  ok "Health checks run every 5 minutes; you get a message when something breaks or recovers"
}

cmd_notify() {
  local sub=${1:-status}; shift || true
  case $sub in
    setup)  notify_setup "$@" ;;
    test)   [[ -n $(cfg_get NOTIFY_TYPE) ]] || die "Alerts aren't set up — run: srv notify setup"
            if notify_send "Test alert from srv ✅"; then ok "Sent"; else die "Sending failed — see $SRV_LOG"; fi ;;
    off|disable) cfg_set NOTIFY_TYPE ""; rm -f /etc/cron.d/srv-check; ok "Alerts turned off" ;;
    deploys) case ${1:-} in on|yes) cfg_set NOTIFY_DEPLOYS yes ;; off|no) cfg_set NOTIFY_DEPLOYS no ;; *) die "Usage: srv notify deploys on|off" ;; esac
             ok "Deploy notifications: $(cfg_get NOTIFY_DEPLOYS)" ;;
    status|"")
      if [[ -n $(cfg_get NOTIFY_TYPE) ]]; then echo "Alerts: $(cfg_get NOTIFY_TYPE) · checks every 5 min · deploy messages: $(cfg_get NOTIFY_DEPLOYS yes)"
      else echo "Alerts are off — set them up with: srv notify setup"; fi ;;
    *) die "Usage: srv notify setup|test|off|deploys on|off" ;;
  esac
}

# ── Dashboard ────────────────────────────────────────────────────────────────
bar() {   # percent width → coloured bar
  local p=$1 w=${2:-20} n c
  (( p > 100 )) && p=100; (( p < 0 )) && p=0
  n=$(( p * w / 100 )); c=$C_G
  if (( p >= 90 )); then c=$C_R; elif (( p >= 75 )); then c=$C_Y; fi
  printf '%s%s%s%s' "$c" "$(printf '%*s' "$n" '' | tr ' ' '#')" "$C_D$(printf '%*s' $(( w - n )) '' | tr ' ' '.')" "$C_0"
}

dashboard_render() {
  local cores l1 memt mema memp swt swu p pct d type code ms ssl days proc mem dep cur meta r lvl name detail n=0 cols
  cols=$(tput cols 2>/dev/null || echo 100)
  cores=$(nproc 2>/dev/null || echo 1); l1=$(cut -d' ' -f1 /proc/loadavg)
  read -r memt mema swt swu < <(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2} END {print int(t/1024), int(a/1024), int(st/1024), int((st-sf)/1024)}' /proc/meminfo)
  memp=$(( (memt - mema) * 100 / (memt > 0 ? memt : 1) ))
  printf '%s srv dashboard — %s — %s %s(q quits)%s\n' "$C_BOLD" "$(hostname)" "$(date '+%F %T')" "$C_D" "$C_0"
  hr
  printf '  %-6s %s %5s  load %s on %s CPU\n' CPU "$(bar "$(awk -v l="$l1" -v c="$cores" 'BEGIN { printf "%d", l * 100 / c }')")" "" "$l1" "$cores"
  printf '  %-6s %s %4s%%  %s / %s MB\n' Memory "$(bar "$memp")" "$memp" "$(( memt - mema ))" "$memt"
  if (( swt > 0 )); then printf '  %-6s %s %4s%%  %s / %s MB\n' Swap "$(bar $(( swu * 100 / swt )))" "$(( swu * 100 / swt ))" "$swu" "$swt"; fi
  for p in $(df -P / /var /var/www 2>/dev/null | awk 'NR > 1 {print $6}' | sort -u); do
    pct=$(df -P "$p" | awk 'NR == 2 {gsub("%", "", $5); print $5}')
    printf '  %-6s %s %4s%%  %s\n' Disk "$(bar "$pct")" "$pct" "$p ($(df -h "$p" | awk 'NR == 2 {print $3 " / " $2}'))"
  done
  echo
  printf '%s  Services%s  ' "$C_BOLD" "$C_0"
  for r in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r lvl name detail <<<"$r"
    [[ $name == service\ * ]] || continue
    if [[ $lvl == ok ]]; then printf '%s●%s %s  ' "$C_G" "$C_0" "${name#service }"; else printf '%s●%s %s  ' "$C_R" "$C_0" "${name#service }"; fi
  done
  echo; echo
  printf '%s  %-30s %-8s %-6s %-7s %-6s %-13s %-7s %s%s\n' "$C_BOLD" SITE TYPE HTTP TIME SSL PROCESS MEMORY "LAST DEPLOY" "$C_0"
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    n=$(( n + 1 )); type=$(site_get "$d" TYPE)
    code=${PROBE_CODE[$d]:--}; ms=${PROBE_MS[$d]:-}
    if [[ -f $(site_get "$d" HOME_DIR)/.maintenance ]]; then code=maint; fi
    if [[ $(site_get "$d" ENABLED yes) != yes ]]; then code=off; fi
    ssl=-; if [[ $(site_get "$d" SSL) == yes ]]; then if days=$(cert_days_left "$d"); then ssl="${days}d"; else ssl=missing; fi; fi
    proc=-
    if is_app_type "$type"; then proc=$(pm_state "$d"); elif [[ -f $(laravel_conf "$d") ]]; then proc=$(laravel_state "$d" | sed 's/ running//'); fi
    mem="$(user_rss_mb "$(site_get "$d" SITE_USER)")M"
    dep=-
    if deploy_enabled "$d" && cur=$(deploy_current "$d"); then
      meta=$(deploy_meta "$d" "$cur")
      dep="$(kv_get "$meta" COMMIT | cut -c1-7) $(human_age $(( $(date +%s) - $(date -d "$(kv_get "$meta" DATE)" +%s 2>/dev/null || date +%s) ))) ago"
    fi
    local cc=$C_G; if [[ ! $code =~ ^[1-4] ]]; then cc=$C_R; fi; if [[ $code == maint || $code == off ]]; then cc=$C_Y; fi
    printf '  %-30s %-8s %s%-6s%s %-7s %-6s %-13s %-7s %s\n' "${d:0:30}" "$type" "$cc" "$code" "$C_0" "${ms:+${ms}ms}" "$ssl" "$proc" "$mem" "$dep"
  done < <(site_list_domains)
  if (( n == 0 )); then echo "  (no sites yet)"; fi
  echo
  local alerts=0
  printf '%s  Alerts%s\n' "$C_BOLD" "$C_0"
  for r in "${CHECK_RESULTS[@]}"; do
    IFS='|' read -r lvl name detail <<<"$r"
    case $lvl in
      fail) alerts=1; printf '  %s✗ %s%s — %s\n' "$C_R" "$name" "$C_0" "$detail" ;;
      warn) alerts=1; printf '  %s! %s%s — %s\n' "$C_Y" "$name" "$C_0" "$detail" ;;
    esac
  done
  if (( ! alerts )); then printf '  %s✓ all %s checks passing%s\n' "$C_G" "${#CHECK_RESULTS[@]}" "$C_0"; fi
  local bl="off"
  if feat_has backup; then bl="$(feat_get backup)$( [[ -n $(cfg_get BACKUP_REMOTE) ]] && echo " → $(cfg_get BACKUP_REMOTE)")"; fi
  printf '\n  %sBackups: %s · Alerts: %s%s\n' "$C_D" "$bl" "$(x=$(cfg_get NOTIFY_TYPE); echo "${x:-off}")" "$C_0"
  : "$cols"
}

cmd_dashboard() {
  local interval=5 once=0 key
  while (( $# )); do
    case $1 in
      --interval|-n) need_val "$@"; interval=$2; shift 2 ;;
      --once) once=1; shift ;;
      *) die "Usage: srv dashboard [--interval seconds] [--once]" ;;
    esac
  done
  interval=$(dec "$interval")
  [[ $interval =~ ^[0-9]+$ ]] && (( interval >= 2 )) || die "The interval must be 2 seconds or more."
  if (( ! INTERACTIVE )); then once=1; fi
  if (( ! once )); then tput civis 2>/dev/null || true; trap 'tput cnorm 2>/dev/null || true' RETURN; fi
  while true; do
    run_checks
    if (( ! once )); then printf '\e[H\e[2J'; fi
    dashboard_render
    if (( once )); then break; fi
    key=""
    read -rsn1 -t "$interval" key </dev/tty || true
    if [[ $key == q || $key == Q ]]; then break; fi
  done
}

# ── Self-update ──────────────────────────────────────────────────────────────
self_update() {   # [URL|file] [--force]
  local src="" force=0 a f="$TMP_DIR/srv-new.sh" new target bak url
  for a in "$@"; do
    case $a in
      --force) force=1 ;;
      -*)      die "Usage: srv self-update [URL or file] [--force]" ;;
      *)       src=$a ;;
    esac
  done
  src=${src:-$(cfg_get UPDATE_URL)}; src=${src:-$SRV_UPDATE_URL}
  if [[ $src =~ ^https?:// ]]; then
    info "Checking $src"
    url=$src; if [[ $url != *\?* ]]; then url="$url?t=$(date +%s)"; fi   # skip stale CDN copies
    run curl -fsSL --max-time 60 -H 'Cache-Control: no-cache' -o "$f" "$url" || die "Download failed — check the URL (or pass a file: srv self-update ./srv.sh)"
  else
    [[ -f $src ]] || die "Not found: $src"
    cp "$src" "$f"
  fi
  grep -q '^SRV_VERSION=' "$f" || die "That file isn't srv."
  bash -n "$f" 2>>"$SRV_LOG" || die "The new file has syntax errors — not installing it."
  new=$(sed -n 's/^SRV_VERSION="\(.*\)"$/\1/p' "$f" | head -n 1)
  target=$(readlink -f "$SRV_BIN" 2>/dev/null) || target=$SRV_BIN
  if [[ -f $target ]] && cmp -s "$f" "$target"; then ok "Already up to date (srv $SRV_VERSION)"; return 0; fi
  if [[ -n $new ]] && ! ver_ge "$new" "$SRV_VERSION" && (( ! force )); then
    die "That's an older version ($new, you have $SRV_VERSION) — add --force to install it anyway."
  fi
  if [[ -f $target ]]; then
    bak="$SRV_BIN.bak-$SRV_VERSION"; if [[ -e $bak ]]; then bak="$bak-$(date +%Y%m%d%H%M%S)"; fi
    cp -L "$SRV_BIN" "$bak"            # the old file's contents, even if srv is a symlink
  fi
  # Write a new file and rename it into place: atomic, replaces a symlink with a real
  # file, and the srv process running right now keeps reading its old copy
  install -m 0755 "$f" "$SRV_BIN.new.$$"
  mv -f "$SRV_BIN.new.$$" "$SRV_BIN"
  if [[ $src =~ ^https?:// && $src != "$SRV_UPDATE_URL" ]]; then cfg_set UPDATE_URL "$src"
  elif [[ $src == "$SRV_UPDATE_URL" ]]; then cfg_set UPDATE_URL ""; fi
  if [[ $new == "$SRV_VERSION" ]]; then ok "srv $new updated to the latest build"
  else ok "srv updated: $SRV_VERSION → ${new:-?}"; fi
  if [[ -n ${bak:-} ]]; then info "Previous version saved as $bak"; fi
  if [[ $target != "$SRV_BIN" ]]; then info "$SRV_BIN was a link to $target — it's now a standalone copy, so $target is no longer used."; fi
  info "Apply the new config templates with: srv site rebuild --all"
}

# =============================================================================
#  SSL
# =============================================================================
server_ips() {
  printf ' %s %s %s ' \
    "$(hostname -I 2>/dev/null || true)" \
    "$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)" \
    "$(curl -6 -fsS --max-time 6 https://api6.ipify.org 2>/dev/null || true)"
}
dns_resolve() { getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u || true; }

# dns_check name "server ips" → 0 points here, 1 points elsewhere, 2 doesn't resolve
dns_check() {
  local ips=" ${2//$'\n'/ } " r any=0
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    any=1
    if [[ $ips == *" $r "* ]]; then return 0; fi
  done < <(dns_resolve "$1")
  if (( any )); then return 1; fi
  return 2
}

ssl_issue() {
  local d=$1 force=${2:-0}
  ensure_feature certbot
  if [[ $(site_get "$d" ENABLED yes) != yes ]]; then err "$d is disabled — enable it first: srv site enable $d"; return 1; fi
  local -a names=() good=(); local n rc ips email
  read -ra names <<<"$d $(site_get "$d" ALIASES)"
  info "Checking DNS for: ${names[*]}"
  ips=$(server_ips)
  for n in "${names[@]}"; do
    rc=0; dns_check "$n" "$ips" || rc=$?
    case $rc in
      0) ok "$n → this server" ;;
      1) warn "$n → $(dns_resolve "$n" | tr '\n' ' ')(not this server — behind a proxy/CDN?)" ;;
      2) warn "$n doesn't resolve yet" ;;
    esac
    if (( rc == 0 )); then good+=("$n")
    elif (( force )) || ui_yesno "Include $n in the certificate anyway?" no; then good+=("$n"); fi
  done
  if ! in_list "$d" "${good[@]}"; then
    err "The primary domain $d must be in the certificate. Point its DNS here, then run: srv ssl add $d"
    return 1
  fi
  install -d -m 755 "$ACME_ROOT"
  local -a args=(certonly --webroot -w "$ACME_ROOT" --cert-name "$d" --non-interactive --agree-tos --keep-until-expiring --expand)
  email=$(cfg_get ADMIN_EMAIL)
  if [[ -n $email ]]; then args+=(-m "$email"); else args+=(--register-unsafely-without-email); fi
  for n in "${good[@]}"; do args+=(-d "$n"); done
  info "Requesting a certificate from Let's Encrypt"
  if ! run certbot "${args[@]}"; then
    err "Certificate request failed. Check that port 80 is open and DNS points to this server."
    return 1
  fi
  site_set "$d" SSL yes
  site_set "$d" SSL_NAMES "${good[*]}"
  site_apply_nginx "$d" || return 1
  ok "HTTPS enabled: https://$d"
  if [[ $(site_get "$d" TYPE) == laravel ]]; then info "Update APP_URL (and Reverb) in .env: srv site apply-env $d"; fi
}

cmd_ssl() {
  local sub=${1:-}; shift || true
  case $sub in
    add|issue)
      local d="" force=0 a
      for a in "$@"; do case $a in --force) force=1 ;; *) d=$a ;; esac; done
      d=$(resolve_domain "$d") || exit 1
      ssl_issue "$d" "$force" ;;
    list|ls)
      ensure_feature certbot
      certbot certificates ;;
    renew-test)
      ensure_feature certbot
      info "Testing renewal (dry run)…"
      if run certbot renew --dry-run; then ok "Renewal works — certificates renew automatically"; else die "Renewal dry run failed"; fi ;;
    ""|menu) menu_ssl ;;
    *) die "Unknown ssl command: $sub (see: srv help)" ;;
  esac
}

# =============================================================================
#  DATABASES (MySQL/MariaDB and PostgreSQL)
# =============================================================================
site_for_db() {   # site_for_db KEY VALUE ENGINE → prints the site using it
  local d
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ $(site_get "$d" "$1") == "$2" && $(site_get "$d" DB_ENGINE mysql) == "$3" ]]; then printf '%s' "$d"; return 0; fi
  done < <(site_list_domains)
  return 1
}

db_cmd_create() {
  local name=${1:-} user=${2:-} pass e=$DB_ENG
  if [[ -z $name ]]; then name=$(ui_input "New $(eng_label "$e") database name" "") || die "Cancelled."; fi
  valid_db_ident "$name" || die "Use only letters, numbers and _ (max 63 characters)."
  if eng_exists "$e" "$name"; then die "Database $name already exists."; fi
  if [[ -z $user ]]; then user=$(ui_input "Database user" "${name:0:32}") || die "Cancelled."; fi
  if ! valid_db_ident "$user" || (( ${#user} > 32 )); then die "Invalid user name (letters, numbers, _; max 32)."; fi
  if eng_user_exists "$e" "$user"; then die "User $user already exists."; fi
  pass=$(gen_password 24)
  eng_create "$e" "$name" "$user" "$pass" || die "Failed — see $SRV_LOG"
  ok "$(eng_label "$e") database created"
  printf '  %-10s %s\n' Database "$name" User "$user" Password "$pass" Host "127.0.0.1:$(eng_port "$e")"
}

db_cmd_list() {
  local e rows name size any=0
  printf '%s%-12s %-36s %10s  %s%s\n' "$C_BOLD" ENGINE DATABASE "SIZE (MB)" SITE "$C_0"
  for e in $(db_engines); do
    if [[ $e == pgsql ]]; then
      rows=$(pg_sql "SELECT datname, round(pg_database_size(datname) / 1048576.0, 2) FROM pg_database
        WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1") || { warn "Couldn't query PostgreSQL"; continue; }
    else
      rows=$(db_sql "SELECT s.SCHEMA_NAME, ROUND(COALESCE(SUM(t.DATA_LENGTH + t.INDEX_LENGTH), 0) / 1048576, 2)
        FROM information_schema.SCHEMATA s
        LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = s.SCHEMA_NAME
        WHERE s.SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys')
        GROUP BY s.SCHEMA_NAME ORDER BY s.SCHEMA_NAME") || { warn "Couldn't query MySQL/MariaDB"; continue; }
    fi
    [[ -n $rows ]] || continue
    while IFS=$'\t' read -r name size; do
      any=1
      printf '%-12s %-36s %10s  %s\n' "$([[ $e == pgsql ]] && echo postgresql || echo mysql)" "$name" "$size" "$(site_for_db DB_NAME "$name" "$e" || true)"
    done <<<"$rows"
  done
  if (( ! any )); then echo "  (no databases)"; fi
}

db_cmd_drop() {
  local name=${1:-} u="" d="" e=$DB_ENG
  if [[ -z $name ]]; then
    local -a items=(); local x
    while IFS= read -r x; do if [[ -n $x ]]; then items+=("$x" "$(site_for_db DB_NAME "$x" "$e" || true)"); fi; done < <(eng_databases "$e")
    (( ${#items[@]} )) || die "No databases to drop."
    name=$(ui_menu "Drop database" "Select the $(eng_label "$e") database to DROP:" "${items[@]}") || die "Cancelled."
  fi
  valid_db_ident "$name" || die "Invalid database name."
  eng_exists "$e" "$name" || die "$(eng_label "$e") database not found: $name"
  if (( INTERACTIVE && ! ASSUME_YES )); then
    local typed; typed=$(ui_input "Type '$name' to confirm DROP (this can't be undone)" "") || die "Cancelled."
    [[ $typed == "$name" ]] || die "Confirmation didn't match — nothing dropped."
  elif (( ! ASSUME_YES )); then
    die "Refusing to drop without --yes in non-interactive mode."
  fi
  if d=$(site_for_db DB_NAME "$name" "$e"); then u=$(site_get "$d" DB_USER); fi
  if [[ -z $u ]] && eng_user_exists "$e" "$name"; then u=$name; fi
  eng_drop_db "$e" "$name" || die "Drop failed — see $SRV_LOG"
  ok "Database $name dropped"
  if [[ -n $u ]] && ui_yesno "Also drop the database user '$u'?" yes; then
    eng_drop_user "$e" "$u" && ok "User $u dropped"
  fi
  if [[ -n $d ]]; then site_set "$d" DB_NAME ""; site_set "$d" DB_USER ""; site_set "$d" DB_PASS ""; fi
}

db_cmd_password() {
  local u=${1:-} p d e=$DB_ENG
  if [[ -z $u ]]; then u=$(ui_input "$(eng_label "$e") user to reset" "") || die "Cancelled."; fi
  valid_db_ident "$u" || die "Invalid user name."
  eng_user_exists "$e" "$u" || die "User not found: $u"
  p=$(gen_password 24)
  eng_set_password "$e" "$u" "$p" || die "Password change failed — see $SRV_LOG"
  ok "New password for $u: $p"
  if d=$(site_for_db DB_USER "$u" "$e"); then
    site_set "$d" DB_PASS "$p"
    if is_app_type "$(site_get "$d" TYPE)"; then app_env_sync "$d"; info "Site $d's app.env updated — restart: srv app restart $d"
    else info "Site $d updated — write it to .env with: srv site apply-env $d"; fi
  fi
}

cmd_db() {
  local sub=${1:-}; shift || true
  local -a rest=(); local a eng=""
  for a in "$@"; do
    case $a in
      --pg|--pgsql|--postgres|--postgresql) eng=pgsql ;;
      --mysql|--mariadb) eng=mysql ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"
  case $sub in
    create|add)      db_pick_engine "$eng"; db_cmd_create "$@" ;;
    list|ls)
      if [[ -z $(db_engines) ]]; then die "No database server installed. Run: srv install database  (or: srv install postgres)"; fi
      db_cmd_list ;;
    drop|rm|delete)  db_pick_engine "$eng"; db_cmd_drop "$@" ;;
    password|passwd) db_pick_engine "$eng"; db_cmd_password "$@" ;;
    ""|menu)         menu_db ;;
    *) die "Unknown db command: $sub (see: srv help)" ;;
  esac
}

# =============================================================================
#  BACKUPS
# =============================================================================
backup_dir_for() { if [[ $1 == pgsql ]]; then printf '%s/pgsql/%s' "$BACKUP_DIR" "$2"; else printf '%s/db/%s' "$BACKUP_DIR" "$2"; fi; }

backup_dump() {   # engine db file
  if [[ $1 == pgsql ]]; then
    runuser -u postgres -- env -C / pg_dump -p "$(pg_port)" "$2" 2>>"$SRV_LOG" | gzip -6 >"$3"
  else
    "$(db_dump_bin)" --single-transaction --quick --routines --triggers --events "$2" 2>>"$SRV_LOG" | gzip -6 >"$3"
  fi
}

backup_db() {
  local target="" eng="" a
  for a in "$@"; do
    case $a in
      --all) target=__all__ ;;
      --pg|--pgsql|--postgres) eng=pgsql ;;
      --mysql|--mariadb) eng=mysql ;;
      -*) die "Unknown option: $a" ;;
      *) target=$a ;;
    esac
  done
  target=${target:-__all__}
  local -a engines=()
  if [[ -n $eng ]]; then engines=("$eng"); else mapfile -t engines < <(db_engines); fi
  (( ${#engines[@]} )) || die "No database server installed."

  local keep stamp failed=0 count=0 e db dir file
  keep=$(cfg_get BACKUP_KEEP_DAYS 7); stamp=$(date +%Y%m%d-%H%M%S)
  for e in "${engines[@]}"; do
    eng_installed "$e" || die "$(eng_label "$e") isn't installed."
    local -a dbs=()
    if [[ $target == __all__ ]]; then mapfile -t dbs < <(eng_databases "$e")
    elif eng_exists "$e" "$target"; then dbs=("$target"); fi
    (( ${#dbs[@]} )) || continue
    info "$(eng_label "$e"): backing up ${#dbs[@]} database(s) — keeping $keep days"
    for db in "${dbs[@]}"; do
      [[ -n $db ]] || continue
      count=$(( count + 1 ))
      dir=$(backup_dir_for "$e" "$db"); install -d -m 700 "$dir"
      file="$dir/$db-$stamp.sql.gz"
      if backup_dump "$e" "$db" "$file.part"; then
        mv -f "$file.part" "$file"; chmod 600 "$file"
        ok "$db → $file ($(du -h "$file" | cut -f1))"
      else
        rm -f "$file.part"; err "Backup failed: $db"; failed=1
      fi
      find "$dir" -maxdepth 1 -type f -name '*.sql.gz' -mtime +"$keep" -delete
    done
  done
  if [[ $target != __all__ ]] && (( count == 0 )); then die "Database not found: $target"; fi
  if (( count == 0 )); then info "No databases to back up."; fi
  if (( failed )); then return 1; fi
}

backup_list() {
  local f any=0 sub
  for sub in db pgsql files; do
    [[ -d $BACKUP_DIR/$sub ]] || continue
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      any=1; printf '%8s  %s\n' "$(du -h "$f" | cut -f1)" "$f"
    done < <(find "$BACKUP_DIR/$sub" -type f \( -name '*.sql.gz' -o -name '*.tar.gz' \) | sort -r)
  done
  if (( ! any )); then echo "  (no backups yet — run: srv backup run)"; fi
  if [[ -n $(cfg_get BACKUP_REMOTE) ]]; then echo; echo " Remote copy: $(cfg_get BACKUP_REMOTE) (kept $(cfg_get BACKUP_REMOTE_KEEP 30) days)"; fi
  echo
  echo " Restore:  srv backup restore <domain>          site files + its database"
  echo "           srv backup restore-db <name> [file]  one database"
}

# ── Site files ───────────────────────────────────────────────────────────────
# One archive per site: the code (the live release for git sites), shared/
# files, app.env, the virtualenv, plus srv's site config and custom Nginx conf.
backup_one_site() {
  local d=$1 stamp=$2 home type cur="" tmpd dir out rc=0
  home=$(site_get "$d" HOME_DIR); type=$(site_get "$d" TYPE)
  local -a members=()
  if [[ $(site_get "$d" DEPLOY) == yes ]] && cur=$(deploy_current "$d"); then
    members+=(shared "releases/$cur")
  else
    cur=""
    if [[ -d $home/app ]]; then members+=(app); fi
    if [[ -d $home/venv ]]; then members+=(venv); fi
  fi
  if [[ -f $home/app.env ]]; then members+=(app.env); fi
  tmpd=$(mktemp -d "$TMP_DIR/site.XXXXXX")
  {
    echo "DOMAIN=$d"
    echo "TYPE=$type"
    echo "DEPLOY=$(site_get "$d" DEPLOY no)"
    echo "RELEASE=$cur"
    echo "DB_ENGINE=$(site_get "$d" DB_ENGINE mysql)"
    echo "DB_NAME=$(site_get "$d" DB_NAME)"
    echo "APP_ACTIVE=$(site_get "$d" APP_ACTIVE no)"
    echo "CREATED=$(date '+%F %T')"
    echo "HOST=$(hostname)"
    echo "SRV_VERSION=$SRV_VERSION"
  } >"$tmpd/srv-backup.info"
  cp "$(site_file "$d")" "$tmpd/srv-site.conf"
  local -a extra=(srv-backup.info srv-site.conf nginx-custom)
  if [[ -n $cur && -f $(deploy_meta "$d" "$cur") ]]; then cp "$(deploy_meta "$d" "$cur")" "$tmpd/srv-release.meta"; extra+=(srv-release.meta); fi
  if [[ -d $NGINX_CUSTOM/$d ]]; then cp -a "$NGINX_CUSTOM/$d" "$tmpd/nginx-custom"; else mkdir "$tmpd/nginx-custom"; fi
  dir="$BACKUP_DIR/files/$d"; install -d -m 700 "$BACKUP_DIR" "$BACKUP_DIR/files" "$dir"
  out="$dir/$d-$stamp.tar.gz"
  tar -czf "$out.part" --exclude='node_modules/.cache' --exclude='.next/cache' --exclude='__pycache__' \
    -C "$home" "${members[@]}" -C "$tmpd" "${extra[@]}" 2>>"$SRV_LOG" || rc=$?
  # tar exit 1 = "some files changed while reading" — still a usable archive
  if (( rc > 1 )); then rm -f "${out:?}.part"; err "File backup of $d failed (tar exit $rc) — see $SRV_LOG"; return 1; fi
  mv -f "$out.part" "$out"; chmod 600 "$out"
  ok "$d files → $out ($(du -h "$out" | cut -f1))"
}

backup_site() {   # <domain> | --all
  local target=${1:---all} d stamp keep failed=0 dir
  local -a list=()
  if [[ $target == --all ]]; then mapfile -t list < <(site_list_domains)
  else d=$(resolve_domain "$target") || exit 1; list=("$d"); fi
  (( ${#list[@]} )) || { info "No sites to back up."; return 0; }
  stamp=$(date +%Y%m%d-%H%M%S); keep=$(cfg_get BACKUP_KEEP_DAYS 7)
  info "Backing up site files — keeping $keep days"
  for d in "${list[@]}"; do
    [[ -n $d ]] || continue
    if [[ $(site_get "$d" TYPE) == proxy ]]; then continue; fi
    backup_one_site "$d" "$stamp" || failed=1
    dir="$BACKUP_DIR/files/$d"
    if [[ -d $dir ]]; then find "$dir" -maxdepth 1 -type f -name '*.tar.gz' -mtime +"$keep" -delete; fi
  done
  if (( failed )); then return 1; fi
}

# What the daily cron job runs: databases, site files, remote copy
backup_run() {
  local failed=0
  info "Backup run started $(date '+%F %T')"
  if [[ -n $(db_engines) ]]; then try backup_db --all; if (( TRY_RC != 0 )); then failed=1; fi; fi
  if [[ $(cfg_get BACKUP_FILES no) == yes ]]; then try backup_site --all; if (( TRY_RC != 0 )); then failed=1; fi; fi
  if [[ -n $(cfg_get BACKUP_REMOTE) ]]; then try remote_push; if (( TRY_RC != 0 )); then failed=1; fi; fi
  if (( failed )); then
    err "Backup run finished with errors — see $SRV_LOG"
    notify_send "❌ Backup run failed — see $SRV_LOG" || true
    return 1
  fi
  ok "Backup run finished"
}

# ── Restore ──────────────────────────────────────────────────────────────────
backup_pick() {   # dir title glob → chosen file (newest first; non-interactive = newest)
  local dir=$1 title=$2 glob=$3 f sel
  local -a items=()
  [[ -d $dir ]] || return 1
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    items+=("$(basename "$f")" "$(du -h "$f" | cut -f1)  $(date -r "$f" '+%F %T')")
  done < <(find "$dir" -maxdepth 1 -type f -name "$glob" -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
  (( ${#items[@]} )) || return 1
  if (( ! INTERACTIVE || ASSUME_YES )); then printf '%s/%s' "$dir" "${items[0]}"; return 0; fi
  sel=$(ui_menu "$title" "Choose a backup (newest first):" "${items[@]}") || return 1
  printf '%s/%s' "$dir" "$sel"
}

# db_restore engine name file — replace a database with a dump (a safety dump is taken first)
db_restore() {
  local e=$1 n=$2 f=$3 owner safety dir
  eng_exists "$e" "$n" || die "$(eng_label "$e") database $n doesn't exist — create it first (srv db create $n)"
  [[ -f $f ]] || die "Not found: $f"
  gzip -t "$f" 2>/dev/null || die "$f is not a valid .gz file"
  dir=$(backup_dir_for "$e" "$n"); install -d -m 700 "$dir"
  safety="$dir/$n-before-restore-$(date +%Y%m%d-%H%M%S).sql.gz"
  if backup_dump "$e" "$n" "$safety"; then chmod 600 "$safety"; info "Safety copy of the current database: $safety"
  else rm -f "${safety:?}"; die "Couldn't take a safety dump of $n — not restoring"; fi
  if [[ $e == pgsql ]]; then
    owner=$(pg_sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$n'")
    eng_drop_db pgsql "$n" || die "Couldn't drop $n"
    printf 'CREATE DATABASE "%s" OWNER "%s" ENCODING '"'"'UTF8'"'"' TEMPLATE template0;\nREVOKE ALL ON DATABASE "%s" FROM PUBLIC;\n' "$n" "$owner" "$n" \
      | pg_run >>"$SRV_LOG" 2>&1 || die "Couldn't recreate $n — the safety dump is $safety"
    gunzip -c "$f" | runuser -u postgres -- env -C / psql -X -q -p "$(pg_port)" -d "$n" >>"$SRV_LOG" 2>&1 \
      || die "Loading the dump failed — see $SRV_LOG (safety dump: $safety)"
  else
    printf 'DROP DATABASE IF EXISTS `%s`;\nCREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$n" "$n" \
      | db_run >>"$SRV_LOG" 2>&1 || die "Couldn't recreate $n — the safety dump is $safety"
    gunzip -c "$f" | "$(db_client)" --protocol=socket -u root "$n" >>"$SRV_LOG" 2>&1 \
      || die "Loading the dump failed — see $SRV_LOG (safety dump: $safety)"
  fi
  ok "Database $n restored from $(basename "$f")"
}

backup_restore_db() {
  local name="" file="" eng="" a d
  for a in "$@"; do
    case $a in
      --pg|--pgsql|--postgres) eng=pgsql ;;
      --mysql|--mariadb) eng=mysql ;;
      -*) die "Unknown option: $a" ;;
      *) if [[ -z $name ]]; then name=$a; else file=$a; fi ;;
    esac
  done
  db_pick_engine "$eng"
  if [[ -z $name ]]; then
    (( INTERACTIVE )) || die "Usage: srv backup restore-db <name> [file] [--mysql|--pg]"
    local -a items=(); local x
    while IFS= read -r x; do if [[ -n $x ]]; then items+=("$x" "$(site_for_db DB_NAME "$x" "$DB_ENG" || true)"); fi; done < <(eng_databases "$DB_ENG")
    (( ${#items[@]} )) || die "No databases."
    name=$(ui_menu "Restore database" "Database to restore:" "${items[@]}") || die "Cancelled."
  fi
  valid_db_ident "$name" || die "Invalid database name."
  if [[ -z $file ]]; then
    file=$(backup_pick "$(backup_dir_for "$DB_ENG" "$name")" "Restore $name" '*.sql.gz') \
      || die "No dumps for $name in $(backup_dir_for "$DB_ENG" "$name") (from the remote: srv backup remote pull)"
  fi
  if (( INTERACTIVE && ! ASSUME_YES )); then
    local typed; typed=$(ui_input "Type '$name' to replace it with $(basename "$file")" "") || die "Cancelled."
    [[ $typed == "$name" ]] || die "Confirmation didn't match — nothing changed."
  elif (( ! ASSUME_YES )); then
    die "Refusing to restore without --yes in non-interactive mode."
  fi
  db_restore "$DB_ENG" "$name" "$file"
  if d=$(site_for_db DB_NAME "$name" "$DB_ENG"); then info "Restart $d if it caches data: srv app restart $d"; fi
}

backup_restore_site() {
  local d="" archive="" dbmode=""
  while (( $# )); do
    case $1 in
      --file)  need_val "$@"; archive=$2; shift 2 ;;
      --db)    dbmode=yes; shift ;;
      --no-db) dbmode=no; shift ;;
      -*)      die "Unknown option: $1" ;;
      *)       d=$1; shift ;;
    esac
  done
  d=$(resolve_domain "$d") || exit 1
  local type user home stamp tmpd info
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); stamp=$(date +%Y%m%d-%H%M%S)
  if [[ -z $archive ]]; then
    archive=$(backup_pick "$BACKUP_DIR/files/$d" "Restore $d" '*.tar.gz') \
      || die "No file backups for $d in $BACKUP_DIR/files/$d (from the remote: srv backup remote pull files/$d)"
  fi
  [[ -f $archive ]] || die "Not found: $archive"
  tmpd=$(mktemp -d "$TMP_DIR/restore.XXXXXX")
  tar -xzf "$archive" -C "$tmpd" --wildcards 'srv-*' 2>/dev/null || die "$archive isn't an srv site backup"
  info="$tmpd/srv-backup.info"
  [[ -f $info ]] || die "$archive isn't an srv site backup"
  local adom atype adeploy arel adbeng adbname
  adom=$(kv_get "$info" DOMAIN); atype=$(kv_get "$info" TYPE); adeploy=$(kv_get "$info" DEPLOY no)
  arel=$(kv_get "$info" RELEASE); adbeng=$(kv_get "$info" DB_ENGINE mysql); adbname=$(kv_get "$info" DB_NAME)
  [[ $atype == "$type" ]] || die "The backup is a $atype site but $d is $type — create the site with --type $atype first."
  if [[ $adom != "$d" ]]; then warn "This backup is from $adom — restoring it into $d"; fi
  local -a content=(); mapfile -t content < <(tar -tzf "$archive" 2>/dev/null | sed 's|/.*||' | sort -u)
  ui_yesno "Restore $d from $(basename "$archive") (made $(kv_get "$info" CREATED))? Current files are moved aside, not deleted." yes || die "Cancelled."

  step "Restoring $d"
  if is_app_type "$type" && [[ $(site_get "$d" APP_ACTIVE) == yes ]]; then pm_stop "$d" || true; fi
  if [[ -f $(laravel_conf "$d") ]]; then supervisorctl stop "srv-$user-laravel:*" >>"$SRV_LOG" 2>&1 || true; fi
  if [[ $(kv_get "$info" APP_ACTIVE) == yes ]]; then site_set "$d" APP_ACTIVE yes; fi

  # 1. Files
  local m
  local -a want=()
  if [[ $adeploy == yes ]]; then
    [[ -n $arel ]] || die "The backup doesn't name its release."
    install -d -m 750 -o "$user" -g "$user" "$home/releases"
    if [[ -e $home/shared ]]; then mv "$home/shared" "$home/shared.before-restore-$stamp"; fi
    if [[ -e $home/releases/$arel ]]; then mv "$home/releases/$arel" "$home/release-$arel.before-restore-$stamp"; fi
    want=(shared "releases/$arel")
  else
    for m in app venv; do
      if in_list "$m" "${content[@]}"; then
        if [[ -e $home/$m ]]; then mv "$home/$m" "$home/$m.before-restore-$stamp"; fi
        want+=("$m")
      fi
    done
  fi
  if in_list app.env "${content[@]}"; then
    if [[ -f $home/app.env ]]; then mv "$home/app.env" "$home/app.env.before-restore-$stamp"; fi
    want+=(app.env)
  fi
  if (( ${#want[@]} )); then tar -xzpf "$archive" -C "$home" "${want[@]}" || die "Extracting $archive failed"; fi
  if [[ -d $tmpd/nginx-custom ]] && [[ -n $(ls -A "$tmpd/nginx-custom" 2>/dev/null) ]]; then
    install -d -m 755 "$NGINX_CUSTOM/$d"; cp -a "$tmpd/nginx-custom/." "$NGINX_CUSTOM/$d/"
  fi
  chown -R "$user:$user" "$home"
  ok "Files restored"

  if [[ $adeploy == yes ]]; then
    if ! deploy_enabled "$d"; then   # e.g. a fresh server: take over the git settings too
      local k
      for k in REPO BRANCH DEPLOY_KEEP DEPLOY_SHARED_DIRS DEPLOY_SHARED_FILES DEPLOY_BUILD DEPLOY_AFTER DEPLOY_MIGRATE \
               DEPLOY_COMPOSER DEPLOY_NPM DEPLOY_OPTIMIZE DEPLOY_HEALTH_PATH DEPLOY_AUTO_ROLLBACK; do
        if grep -qE "^$k=" "$tmpd/srv-site.conf"; then site_set "$d" "$k" "$(kv_get "$tmpd/srv-site.conf" "$k")"; fi
      done
      # Keep auto-deploy working: same webhook secret as configured in the git host
      if [[ $(kv_get "$tmpd/srv-site.conf" DEPLOY_WEBHOOK) == yes ]]; then
        site_set "$d" WEBHOOK_SECRET "$(kv_get "$tmpd/srv-site.conf" WEBHOOK_SECRET)"
        if feat_has webhook; then site_set "$d" DEPLOY_WEBHOOK yes; webhook_write_secret "$d"
        else warn "This site auto-deployed via webhook — turn it back on with: srv deploy webhook $d on (same secret)"; fi
      fi
    fi
    deploy_ensure_dirs "$d"
    if [[ -f $tmpd/srv-release.meta ]]; then cp "$tmpd/srv-release.meta" "$(deploy_meta "$d" "$arel")"
    else printf 'SUBJECT=restored from %s\nDATE=%s\nSTATUS=ok\n' "$(basename "$archive")" "$(date '+%F %T')" >"$(deploy_meta "$d" "$arel")"; fi
    kv_set "$(deploy_meta "$d" "$arel")" BY restore
  elif [[ $(site_get "$d" DEPLOY) == yes ]]; then
    site_set "$d" DEPLOY no; site_set "$d" APP_DIR "$home/app"
  fi

  # 2. Database
  local dbn eng dump=""
  dbn=$(site_get "$d" DB_NAME); eng=$(site_get "$d" DB_ENGINE mysql)
  if [[ -n $dbn && $dbmode != no ]]; then
    if [[ -n $adbname && $adbeng == "$eng" ]]; then
      dump=$(INTERACTIVE=0 backup_pick "$(backup_dir_for "$eng" "$adbname")" x "$adbname-[0-9]*.sql.gz" || true)
    fi
    if [[ -z $dump ]]; then dump=$(INTERACTIVE=0 backup_pick "$(backup_dir_for "$eng" "$dbn")" x "$dbn-[0-9]*.sql.gz" || true); fi
    if [[ -n $dump ]]; then
      if [[ $dbmode == yes ]] || ui_yesno "Also restore database $dbn from $(basename "$dump")?" yes; then db_restore "$eng" "$dbn" "$dump"; fi
    else
      warn "No database dump found for ${adbname:-$dbn} — only files were restored (srv backup remote pull fetches remote dumps)"
    fi
  fi

  # 3. Point the env files at this server's database / Redis
  if [[ -n $dbn || $(site_get "$d" REDIS) == yes ]]; then
    if is_app_type "$type"; then app_env_sync "$d"
    elif is_php_type "$type"; then
      local envf
      if [[ $adeploy == yes ]]; then envf="$home/shared/.env"; else envf="$home/app/.env"; fi
      if [[ -f $envf ]]; then laravel_env_write "$d" "$envf"; fi
    fi
  fi

  # 4. Go live
  if [[ $adeploy == yes ]]; then
    deploy_switch "$d" "$arel"
  else
    site_rebuild "$d" || warn "Rebuild had problems — check: srv site rebuild $d"
    if is_app_type "$type" && [[ $(site_get "$d" APP_ACTIVE) == yes ]]; then app_start "$d" || true; fi
    if is_php_type "$type"; then run systemctl reload "php$(site_get "$d" PHP)-fpm" || true; fi
  fi
  if [[ -f $(laravel_conf "$d") ]]; then run supervisorctl start "srv-$user-laravel:*" || true; fi
  ok "Restored $d from $(basename "$archive")"
  info "Previous files were kept as *.before-restore-$stamp in $home — delete them once you're happy"
}

# ── Remote copies (rclone) ───────────────────────────────────────────────────
rclone_cmd() { rclone --config "$RCLONE_CONF" "$@"; }

rclone_write_section() {   # the lines of the [srv-remote] section
  local tmp
  touch "$RCLONE_CONF"; chmod 600 "$RCLONE_CONF"; tmp=$(mktemp)
  awk 'BEGIN { skip = 0 } /^\[/ { skip = ($0 == "[srv-remote]") } !skip' "$RCLONE_CONF" >"$tmp"
  { cat "$tmp"; echo "[srv-remote]"; printf '%s\n' "$@"; echo; } >"$RCLONE_CONF"
  rm -f "${tmp:?}"; chmod 600 "$RCLONE_CONF"
}

remote_need() { [[ -n $(cfg_get BACKUP_REMOTE) ]] || die "No remote storage configured — run: srv backup remote setup"; }

remote_setup() {
  local kind="" provider="" akey="" skey="" region="" endpoint="" bucket="" prefix="" keep="" existing="" remote
  while (( $# )); do
    case $1 in
      --existing)   need_val "$@"; existing=$2; shift 2 ;;
      --type)       need_val "$@"; kind=$2; shift 2 ;;
      --provider)   need_val "$@"; provider=$2; shift 2 ;;
      --access-key) need_val "$@"; akey=$2; shift 2 ;;
      --secret-key) need_val "$@"; skey=$2; shift 2 ;;
      --region)     need_val "$@"; region=$2; shift 2 ;;
      --endpoint)   need_val "$@"; endpoint=$2; shift 2 ;;
      --bucket)     need_val "$@"; bucket=$2; shift 2 ;;
      --prefix)     need_val "$@"; prefix=$2; shift 2 ;;
      --keep)       need_val "$@"; keep=$2; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  ensure_feature rclone
  if [[ -n $existing ]]; then
    [[ $existing =~ ^[A-Za-z0-9_.-]+:[^[:space:]]*$ ]] || die "Use the form remote:path (a remote defined in $RCLONE_CONF)"
    remote=$existing
  else
    if [[ -z $kind ]]; then
      kind=$(ui_menu "Remote backups" "Where should backups be copied?" \
        s3    "Amazon S3 or S3-compatible (Cloudflare R2, Wasabi, DO Spaces, MinIO …)" \
        b2    "Backblaze B2" \
        drive "Google Drive (rclone's own setup wizard)" \
        other "Any other rclone storage (rclone's wizard)") || die "Cancelled."
    fi
    case $kind in
      s3)
        if [[ -z $provider ]]; then
          provider=$(ui_menu "S3 provider" "Provider:" AWS "Amazon S3" Cloudflare "Cloudflare R2" Wasabi "Wasabi" \
            DigitalOcean "DigitalOcean Spaces" Minio "MinIO" Other "Other S3-compatible") || die "Cancelled."
        fi
        if [[ -z $akey ]]; then akey=$(ui_input "Access key ID" "") || die "Cancelled."; fi
        if [[ -z $skey ]]; then
          (( INTERACTIVE )) || die "--secret-key is required"
          skey=$(ui_password "Secret access key") || die "Cancelled."
        fi
        local rdef=""; case $provider in AWS) rdef=us-east-1 ;; Cloudflare) rdef=auto ;; esac
        if [[ -z $region ]]; then region=$(ui_input "Region (blank if not needed)" "$rdef" empty) || die "Cancelled."; fi
        if [[ -z $endpoint && $provider != AWS ]]; then
          endpoint=$(ui_input "Endpoint URL (e.g. https://<account-id>.r2.cloudflarestorage.com)" "") || die "Cancelled."
        fi
        if [[ -z $bucket ]]; then bucket=$(ui_input "Bucket name" "") || die "Cancelled."; fi
        local -a lines=("type = s3" "provider = $provider" "access_key_id = $akey" "secret_access_key = $skey")
        if [[ -n $region ]]; then lines+=("region = $region"); fi
        if [[ -n $endpoint ]]; then lines+=("endpoint = $endpoint"); fi
        lines+=("acl = private")
        if [[ $provider == Cloudflare ]]; then lines+=("no_check_bucket = true"); fi
        rclone_write_section "${lines[@]}" ;;
      b2)
        if [[ -z $akey ]]; then akey=$(ui_input "Key ID (account ID or application key ID)" "") || die "Cancelled."; fi
        if [[ -z $skey ]]; then
          (( INTERACTIVE )) || die "--secret-key is required"
          skey=$(ui_password "Application key") || die "Cancelled."
        fi
        if [[ -z $bucket ]]; then bucket=$(ui_input "Bucket name" "") || die "Cancelled."; fi
        rclone_write_section "type = b2" "account = $akey" "key = $skey" ;;
      drive|other)
        (( INTERACTIVE )) || die "Google Drive and other storage use rclone's interactive wizard — run this in a terminal."
        info "rclone's wizard starts now. Create a remote named exactly:  srv-remote"
        if [[ $kind == drive ]]; then info "Pick 'drive'. On a server without a browser, answer 'n' to auto config and follow the 'rclone authorize' steps."; fi
        rclone_cmd config </dev/tty >/dev/tty 2>&1 || true
        grep -qx '\[srv-remote\]' "$RCLONE_CONF" || die "No remote named srv-remote was created."
        if [[ -z $bucket ]]; then bucket=$(ui_input "Folder or bucket on that storage (blank = top level)" "" empty) || die "Cancelled."; fi ;;
      *) die "Unknown storage type: $kind (use s3, b2, drive or other)" ;;
    esac
    [[ -z $bucket || $bucket =~ ^[A-Za-z0-9._/-]+$ ]] || die "Invalid bucket or folder name: $bucket"
    if [[ -z $prefix ]]; then prefix=$(ui_input "Folder for this server's backups" "srv-backups/$(hostname -s)") || die "Cancelled."; fi
    valid_relpath "$prefix" || die "Invalid folder: $prefix"
    remote="srv-remote:${bucket:+$bucket/}$prefix"
  fi
  if [[ -z $keep ]]; then keep=$(ui_input "Keep remote copies for how many days?" "$(cfg_get BACKUP_REMOTE_KEEP 30)") || die "Cancelled."; fi
  keep=$(dec "$keep")
  [[ $keep =~ ^[0-9]+$ ]] && (( keep >= 1 )) || die "Days must be 1 or more."
  local old_remote old_keep; old_remote=$(cfg_get BACKUP_REMOTE); old_keep=$(cfg_get BACKUP_REMOTE_KEEP)
  cfg_set BACKUP_REMOTE "$remote"; cfg_set BACKUP_REMOTE_KEEP "$keep"
  if ! remote_test; then
    cfg_set BACKUP_REMOTE "$old_remote"; cfg_set BACKUP_REMOTE_KEEP "$old_keep"
    die "The remote storage isn't working — nothing changed. Fix the settings and run: srv backup remote setup"
  fi
  ok "Remote backups: $remote (kept $keep days)"
  if ! feat_has backup; then info "Schedule daily backups with: srv install backup"; fi
  if [[ -d $BACKUP_DIR ]] && ui_yesno "Upload the existing backups now?" yes; then remote_push; fi
}

remote_test() {
  remote_need
  local r; r=$(cfg_get BACKUP_REMOTE)
  info "Testing $r"
  if ! echo "srv test $(date)" | rclone_cmd rcat "$r/.srv-test" >>"$SRV_LOG" 2>&1; then
    err "Can't write to $r — see $SRV_LOG"; return 1
  fi
  rclone_cmd deletefile "$r/.srv-test" >>"$SRV_LOG" 2>&1 || true
  ok "Remote storage works: $r"
}

remote_push() {
  remote_need
  local r keep; r=$(cfg_get BACKUP_REMOTE); keep=$(cfg_get BACKUP_REMOTE_KEEP 30)
  [[ -d $BACKUP_DIR ]] || { info "Nothing to upload yet."; return 0; }
  info "Uploading backups to $r"
  run rclone_cmd copy "$BACKUP_DIR" "$r" --exclude '*.part' --transfers 4 || { err "Upload failed — see $SRV_LOG"; return 1; }
  rclone_cmd delete "$r" --min-age "${keep}d" >>"$SRV_LOG" 2>&1 || warn "Removing old remote copies failed"
  rclone_cmd rmdirs "$r" --leave-root >>"$SRV_LOG" 2>&1 || true
  ok "Backups uploaded (the remote keeps $keep days)"
}

remote_pull() {   # [sub-folder, e.g. files/example.com or db/shop]
  remote_need
  local sub=${1:-} r; r=$(cfg_get BACKUP_REMOTE)
  if [[ -n $sub ]]; then sub=${sub#/}; sub=${sub%/}; valid_relpath "$sub" || die "Invalid folder: $sub"; fi
  info "Downloading $r${sub:+/$sub} → $BACKUP_DIR${sub:+/$sub}"
  install -d -m 700 "$BACKUP_DIR"
  run rclone_cmd copy "$r${sub:+/$sub}" "$BACKUP_DIR${sub:+/$sub}" --transfers 4 || die "Download failed — see $SRV_LOG"
  chmod -R go-rwx "$BACKUP_DIR"
  ok "Downloaded — restore with: srv backup restore <domain>"
}

remote_list() {
  remote_need
  rclone_cmd lsl "$(cfg_get BACKUP_REMOTE)" 2>>"$SRV_LOG" | sort -k2,3 || die "Listing failed — see $SRV_LOG"
}

cmd_backup_remote() {
  local sub=${1:-}; shift || true
  case $sub in
    setup)          remote_setup "$@" ;;
    test)           remote_test ;;
    push|upload)    remote_push ;;
    pull|download)  remote_pull "${1:-}" ;;
    list|ls)        remote_list ;;
    off|disable)    cfg_set BACKUP_REMOTE ""; ok "Remote copies turned off (nothing was deleted on the remote)" ;;
    ""|status)
      if [[ -n $(cfg_get BACKUP_REMOTE) ]]; then echo "Remote: $(cfg_get BACKUP_REMOTE) (kept $(cfg_get BACKUP_REMOTE_KEEP 30) days)"
      else echo "No remote storage configured — set it up with: srv backup remote setup"; fi ;;
    *) die "Usage: srv backup remote setup|test|push|pull [folder]|list|off" ;;
  esac
}

cmd_backup() {
  local sub=${1:-}; shift || true
  case $sub in
    run)          backup_run ;;
    db)           backup_db "$@" ;;
    site|files)   backup_site "${1:---all}" ;;
    list|ls)      backup_list ;;
    restore)      backup_restore_site "$@" ;;
    restore-db)   backup_restore_db "$@" ;;
    remote)       cmd_backup_remote "$@" ;;
    ""|menu)      menu_backup ;;
    *) die "Unknown backup command: $sub (see: srv help)" ;;
  esac
}

# =============================================================================
#  STATUS
# =============================================================================
svc_row() {
  local s; s=$(svc_state "$1")
  if [[ $s == active ]]; then printf '  %-26s %s%s%s\n' "$1" "$C_G" "$s" "$C_0"
  else printf '  %-26s %s%s%s\n' "$1" "$C_R" "${s:-unknown}" "$C_0"; fi
}

cmd_status() {
  local f v mem disk up d
  mem=$(free -m | awk '/^Mem:/{printf "%d / %d MB used", $3, $2}')
  disk=$(df -h / | awk 'NR==2{printf "%s / %s used (%s)", $3, $2, $5}')
  up=$(uptime -p 2>/dev/null || true)
  echo; printf '%ssrv %s%s\n' "$C_BOLD" "$SRV_VERSION" "$C_0"; hr
  printf '  %-13s %s\n' Host "$(hostname)" OS "$OS_NAME" Uptime "${up#up }" \
    Load "$(cut -d' ' -f1-3 /proc/loadavg)" Memory "$mem" Disk "$disk"
  if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then
    printf '  %-13s %s\n' Swap "$(free -m | awk '/^Swap:/{printf "%d / %d MB used", $3, $2}')"
  fi

  echo; printf '%sFeatures%s\n' "$C_BOLD" "$C_0"
  for f in base "${FEATURES[@]}"; do
    v=$(feat_get "$f")
    if [[ -n $v ]]; then printf '  %-13s %s\n' "$f" "$v"
    else printf '  %-13s %s%s%s\n' "$f" "$C_D" "not installed" "$C_0"; fi
  done
  if [[ -n $(cfg_get BACKUP_REMOTE) ]]; then printf '  %-13s %s\n' "  remote" "$(cfg_get BACKUP_REMOTE) (kept $(cfg_get BACKUP_REMOTE_KEEP 30) days)"; fi
  if feat_has dbadmin; then printf '  %-13s %s\n' "  tools URL" "$(tools_url)"; fi
  printf '  %-13s %s\n' "alerts" "$(x=$(cfg_get NOTIFY_TYPE); echo "${x:-off} (srv notify setup · health check: srv check)")"

  echo; printf '%sServices%s\n' "$C_BOLD" "$C_0"
  if feat_has nginx; then svc_row nginx; fi
  for v in $(php_versions); do svc_row "php$v-fpm"; done
  if feat_has database; then svc_row "$( [[ $(cfg_get DB_ENGINE) == mysql ]] && echo mysql || echo mariadb )"; fi
  if feat_has postgres; then svc_row "postgresql@$(cfg_get PG_VERSION)-main"; fi
  if feat_has redis; then svc_row redis-server; fi
  if feat_has supervisor; then svc_row supervisor; fi
  while IFS= read -r d; do
    if [[ -n $d && $(site_get "$d" PM) == pm2 && $(site_get "$d" APP_ACTIVE) == yes ]]; then
      printf '  %-26s %s\n' "pm2-$(site_get "$d" SITE_USER)" "$(pm_state "$d") (PM2 for $d)"
    fi
  done < <(site_list_domains)
  if feat_has webhook; then svc_row srv-webhook; fi
  if feat_has fail2ban; then svc_row fail2ban; fi
  if feat_has certbot; then svc_row certbot.timer; fi
  svc_row cron
  if command -v ufw >/dev/null 2>&1; then
    printf '  %-26s %s\n' ufw "$(ufw status 2>/dev/null | head -n 1 | sed 's/Status: //' || true)"
  fi

  echo; printf '%sSites%s\n' "$C_BOLD" "$C_0"
  site_list
  local has_apps=0
  while IFS= read -r d; do if [[ -n $d ]] && site_has_process "$d"; then has_apps=1; break; fi; done < <(site_list_domains)
  if (( has_apps )); then echo; printf '%sApps%s\n' "$C_BOLD" "$C_0"; app_list; fi
  if [[ -f /var/run/reboot-required ]]; then echo; warn "A reboot is required to finish updates."; fi
  echo
}

# =============================================================================
#  MENUS
# =============================================================================
main_menu() {
  MENU_MODE=1
  ensure_whiptail
  local c
  while true; do
    c=$(ui_menu "srv $SRV_VERSION — $(hostname)" "What would you like to do?" \
      sites   "Sites — add, list, SSL, logs, remove …" \
      apps    "Apps — Node.js / Python processes, Laravel workers" \
      deploy  "Deploy — git releases, rollback, webhooks" \
      dashboard "Live dashboard" \
      check   "Health check & alerts" \
      runtimes "PHP / Node.js / Python versions" \
      tools   "Database tools (Adminer / phpMyAdmin)" \
      ssl     "SSL certificates" \
      db      "Databases (MySQL/MariaDB, PostgreSQL)" \
      backup  "Backups" \
      install "Install a feature (anything skipped earlier)" \
      setup   "Run the server setup wizard" \
      status  "Server status" \
      quit    "Exit") || break
    ui_clear
    case $c in
      quit)    break ;;
      sites)   try menu_sites; continue ;;
      apps)    try menu_apps; continue ;;
      deploy)  try menu_deploy; continue ;;
      dashboard) try cmd_dashboard; continue ;;
      check)   try menu_check; continue ;;
      runtimes) try menu_runtimes; continue ;;
      tools)   try menu_tools; continue ;;
      ssl)     try menu_ssl; continue ;;
      db)      try menu_db; continue ;;
      backup)  try menu_backup; continue ;;
      install) try cmd_install ;;
      setup)   try cmd_setup ;;
      status)  cmd_status ;;
    esac
    pause
  done
}

menu_sites() {
  local c d k
  while true; do
    c=$(ui_menu "Sites" "Manage sites:" \
      add       "Add a new site" \
      list      "List all sites" \
      info      "Site details" \
      ssl       "Enable HTTPS (Let's Encrypt)" \
      logs      "View recent logs" \
      workers   "Laravel queue workers / Horizon / Reverb" \
      maintenance "Maintenance mode on/off" \
      cron      "Cron jobs for a site" \
      redis     "Turn Redis on/off for a site" \
      fix-perms "Fix ownership & permissions" \
      apply-env "Write DB / Redis credentials into .env" \
      rebuild   "Regenerate Nginx / PHP / process config" \
      enable    "Enable a site" \
      disable   "Disable a site" \
      remove    "Remove a site" \
      back      "Back") || return 0
    ui_clear
    case $c in
      back) return 0 ;;
      list) site_list ;;
      ssl)  try cmd_ssl add ;;
      cron)
        if d=$(pick_site); then
          try cron_list "$d"
          k=$(ui_menu "Cron: $d" "Cron jobs:" add "Add a job" remove "Remove a job" back "Back") || continue
          case $k in add) try cron_add "$d" ;; remove) try cron_remove "$d" ;; esac
        fi ;;
      logs)
        if d=$(pick_site); then
          k=$(ui_menu "Logs: $d" "Which log?" error "Nginx error log" access "Nginx access log" \
                app "App output (Node.js / Python)" php "PHP error log" laravel "Laravel log" \
                queue "Queue workers" horizon "Horizon" reverb "Reverb") || continue
          try site_logs "$d" "$k"
        fi ;;
      *) try "site_${c//-/_}" ;;
    esac
    pause
  done
}

menu_apps() {
  local c d
  while true; do
    c=$(ui_menu "Apps" "Node.js / Python apps and Laravel workers:" \
      list    "List apps and their state" \
      build   "Install dependencies, build and (re)start" \
      start   "Start" \
      stop    "Stop" \
      restart "Restart" \
      logs    "Recent output" \
      manager "Switch process manager (systemd / PM2 / Supervisor)" \
      back    "Back") || return 0
    ui_clear
    case $c in
      back) return 0 ;;
      list) app_list ;;
      *)    if d=$(pick_site apps); then try cmd_app "$c" "$d"; fi ;;
    esac
    pause
  done
}

menu_ssl() {
  local c
  while true; do
    c=$(ui_menu "SSL" "Certificates:" \
      add        "Issue / expand a certificate for a site" \
      list       "List certificates" \
      renew-test "Test automatic renewal" \
      back       "Back") || return 0
    ui_clear
    if [[ $c == back ]]; then return 0; fi
    try cmd_ssl "$c"
    pause
  done
}

menu_db() {
  local c
  while true; do
    c=$(ui_menu "Databases" "Manage databases:" \
      create   "Create a database + user" \
      list     "List databases" \
      drop     "Drop a database" \
      password "Reset a user's password" \
      back     "Back") || return 0
    ui_clear
    if [[ $c == back ]]; then return 0; fi
    try cmd_db "$c"
    pause
  done
}

menu_deploy() {
  local c d m
  while true; do
    c=$(ui_menu "Deploy" "Git deployments:" \
      now      "Deploy now" \
      setup    "Set up git deploys for a site (repository, branch)" \
      releases "List releases" \
      rollback "Roll back to an earlier release" \
      webhook  "Auto-deploy on git push (webhook)" \
      key      "Show the SSH deploy key" \
      log      "Deploy log" \
      back     "Back") || return 0
    ui_clear
    case $c in
      back)  return 0 ;;
      setup) try deploy_setup ;;
      *)
        if d=$(pick_site deploy); then
          case $c in
            now)      try deploy_now "$d" ;;
            releases) try deploy_releases_list "$d" ;;
            rollback) try deploy_rollback "$d" ;;
            key)      try deploy_key "$d" ;;
            log)      try deploy_log "$d" ;;
            webhook)
              if m=$(ui_menu "Webhook: $d" "Auto-deploy webhook:" on "Enable / show URL and secret" off "Disable" rotate "Generate a new secret"); then
                try deploy_webhook "$d" "$m"
              fi ;;
          esac
        fi ;;
    esac
    pause
  done
}

menu_check() {
  local c
  while true; do
    c=$(ui_menu "Health & alerts" "$(x=$(cfg_get NOTIFY_TYPE); echo "Alerts: ${x:-off}")" \
      check  "Run all health checks now" \
      setup  "Set up alerts (Telegram, Slack, Discord, webhook)" \
      test   "Send a test alert" \
      off    "Turn alerts off" \
      back   "Back") || return 0
    ui_clear
    case $c in
      back)  return 0 ;;
      check) try cmd_check ;;
      *)     try cmd_notify "$c" ;;
    esac
    pause
  done
}

menu_runtimes() {
  local c v
  while true; do
    c=$(ui_menu "Runtimes" "PHP, Node.js and Python versions:" \
      php-list     "PHP: list versions" \
      php-install  "PHP: install a version" \
      php-default  "PHP: set the default" \
      php-ext      "PHP: add an extension" \
      php-remove   "PHP: remove a version" \
      node-list    "Node.js: list versions" \
      node-install "Node.js: install a version" \
      node-default "Node.js: set the default" \
      node-upgrade "Node.js: upgrade a version to its newest release" \
      node-remove  "Node.js: remove a version" \
      py-list      "Python: list versions" \
      py-install   "Python: install a version" \
      py-remove    "Python: remove a version" \
      back         "Back") || return 0
    ui_clear
    case $c in
      back)         return 0 ;;
      php-list)     php_cmd_list ;;
      php-install)  try cmd_install php ;;
      node-list)    node_cmd_list ;;
      node-install) try cmd_install node ;;
      py-list)      py_cmd_list ;;
      php-ext)      if v=$(ui_input "Extension name (e.g. imagick, soap, imap)" ""); then try php_cmd_ext "$v" all; fi ;;
      py-install)   if v=$(ui_input "Python version (e.g. 3.12)" ""); then try cmd_install python "$v"; fi ;;
      *)
        if v=$(ui_input "Version" ""); then
          case $c in
            php-default)  try php_cmd_default "$v" ;;
            php-remove)   try php_cmd_remove "$v" ;;
            node-default) try node_cmd_default "$v" ;;
            node-upgrade) try node_cmd_upgrade "$v" ;;
            node-remove)  try node_cmd_remove "$v" ;;
            py-remove)    try py_cmd_remove "$v" ;;
          esac
        fi ;;
    esac
    pause
  done
}

menu_tools() {
  local c v
  while true; do
    c=$(ui_menu "Database tools" "$(feat_has dbadmin && tools_url || echo "Not installed")" \
      status   "Show URL and login" \
      install  "Install Adminer / phpMyAdmin" \
      password "New login password" \
      allow    "Restrict to IP addresses" \
      host     "Serve under another site's domain" \
      db-user  "Create an admin database login" \
      update   "Update to the newest versions" \
      remove   "Remove the tools" \
      back     "Back") || return 0
    ui_clear
    case $c in
      back)  return 0 ;;
      allow) if v=$(ui_input "Allowed IPs/ranges, space-separated (blank = any)" "$(cfg_get TOOLS_ALLOW)" empty); then try cmd_tools allow "${v:-off}"; fi ;;
      host)  if v=$(pick_site); then try cmd_tools host "$v"; fi ;;
      *)     try cmd_tools "$c" ;;
    esac
    pause
  done
}

menu_backup() {
  local c m
  while true; do
    c=$(ui_menu "Backups" "Backups:" \
      run        "Back up everything now (databases, files, remote copy)" \
      db         "Back up databases only" \
      files      "Back up site files only" \
      list       "List backups" \
      restore    "Restore a site (files + database)" \
      restore-db "Restore one database" \
      remote     "Remote storage (S3, R2, B2, Google Drive …)" \
      schedule   "Daily automatic backups" \
      back       "Back") || return 0
    ui_clear
    case $c in
      back)       return 0 ;;
      run)        try backup_run ;;
      db)         try backup_db --all ;;
      files)      try backup_site --all ;;
      list)       backup_list ;;
      restore)    try backup_restore_site ;;
      restore-db) try backup_restore_db ;;
      schedule)   try cmd_install backup ;;
      remote)
        if m=$(ui_menu "Remote storage" "$(x=$(cfg_get BACKUP_REMOTE); echo "Now: ${x:-not configured}")" \
             setup "Set up / change" test "Test the connection" push "Upload backups now" \
             pull "Download backups from the remote" list "List remote files" off "Turn off"); then
          try cmd_backup_remote "$m"
        fi ;;
    esac
    pause
  done
}

# =============================================================================
#  HELP & MAIN
# =============================================================================
usage() {
  cat <<EOF
srv $SRV_VERSION — server & site manager (Nginx · PHP · Node.js · Python · MySQL · PostgreSQL · Redis)

Usage: sudo srv [command] [options]        (no command = interactive menu)

Server
  setup                        Interactive first-time setup wizard
  install [feature] [version]  Install a feature (no name = choose from a list)
                               Features: ${FEATURES[*]}
                               e.g. srv install php 8.3 · srv install node 22 · srv install postgres 17
  status                       Server, services, sites, apps and certificates
  self-install                 Copy this script to $SRV_BIN (also upgrades it)

Sites
  site add [domain] --type static|spa|php|laravel|node|python|proxy  [options]
      common   --aliases "www.example.com"  --db|--no-db  --mysql|--pg  --redis|--no-redis  --ssl|--no-ssl
               --repo <git url> [--branch main]   deploy from git right away
               --canonical|--no-canonical         redirect aliases (www) to the primary domain
      PHP      --php 8.4  --webroot public
      Node.js  --node 24  --preset next|nuxt|nest|generic  --start "npm start"  --build "npm run build"
      Python   --framework django|flask|fastapi|other  --server gunicorn|uvicorn  --module main:app  --workers 3  --python 3.12
      apps     --pm systemd|pm2|supervisor  --port 3001  --websocket|--no-websocket
      proxy    --upstream 127.0.0.1:8080  --websocket|--no-websocket
  site list
  site info <domain> [--secrets]
  site set <domain> <KEY> <value>   Change a setting (START_CMD, PORT, PHP, DEPLOY_SHARED_DIRS …)
  site enable|disable <domain>
  site rebuild <domain>|--all  Regenerate Nginx / PHP-FPM / process / cron config
  site fix-perms <domain>      Reset ownership & permissions after uploading files
  site apply-env <domain>      Laravel: APP_URL, DB, Redis, Reverb → .env · apps: DB/Redis → app.env
  site workers <domain> [--queue N] [--horizon|--no-horizon] [--reverb|--no-reverb]
  site redis <domain> on|off
  site maintenance <domain> on|off|status [--allow "1.2.3.4 …"]
  site rollback <domain> [release]
  site logs <domain> [error|access|php|laravel|app|queue|horizon|reverb|deploy]
  site remove <domain> [--purge]   --purge also deletes files, database and cert

Runtimes
  php list | install <v> | default <v> | remove <v> | ext <name> [v|all]
  node list | install <major|lts> | default <major> | upgrade <major> | remove <major>
  python list | install <3.x> | remove <3.x>        per site: srv site set <domain> PY_VERSION 3.12

Admin
  dashboard [--interval 5]     Live view: resources, services, sites, apps, alerts
  check [--notify] [--quiet]   Health checks (exit code 0 ok, 1 warnings, 2 failures)
  notify setup|test|off|deploys on|off   Alerts via Telegram, Slack, Discord or a webhook
  tools [status|install [adminer|phpmyadmin]|password|allow "ips"|host <domain>|db-user|update|remove]
  cron <domain> list | add "<schedule>" "<command>" | remove <n> | run <n>
  self-update [URL|file]       Update srv to the latest version from GitHub (or a given URL/file;
                               syntax-checked first, previous version kept as a backup)

Deploy (git)
  deploy setup <domain> [--repo URL] [--branch main] [--keep 5] [--no-deploy]
  deploy <domain> [--ref <branch|tag|commit>] [--maintenance] [--no-migrate]
  deploy releases <domain>     List releases (* = live)
  deploy rollback <domain> [release]
  deploy webhook <domain> on|off|show|rotate   Auto-deploy on push (GitHub, GitLab, Bitbucket)
  deploy key <domain>          Show / create the SSH deploy key
  deploy log <domain> [-f]

Apps (Node.js / Python processes, Laravel workers)
  app list
  app build <domain>           Install dependencies, build, then (re)start (sites without git deploys)
  app start|stop|restart <domain>
  app status <domain>
  app logs <domain> [type]
  app exec <domain> '<cmd>'    Run a command as the app user (e.g. 'python manage.py migrate')
  app manager <domain> [systemd|pm2|supervisor]

SSL
  ssl add <domain> [--force]   Issue / expand a Let's Encrypt certificate
  ssl list
  ssl renew-test

Databases (add --mysql or --pg when both servers are installed)
  db create [name] [user]
  db list
  db drop <name>
  db password <user>           Generate a new password for a database user

Backups
  backup run                   Databases + site files + remote copy (what the daily job runs)
  backup db [name|--all] [--mysql|--pg]
  backup site <domain>|--all   Site files
  backup list
  backup restore <domain> [--file F] [--db|--no-db]
  backup restore-db <name> [file] [--mysql|--pg]
  backup remote setup|test|push|pull [folder]|list|off

Options
  -y, --yes    Accept defaults and confirmations (for scripts)
  --plain      Plain text prompts instead of dialog boxes

Log: $SRV_LOG
EOF
}

main() {
  local -a args=(); local a
  for a in "$@"; do
    case $a in
      -y|--yes) ASSUME_YES=1 ;;
      --plain)  SRV_PLAIN=1 ;;
      *)        args+=("$a") ;;
    esac
  done
  set -- "${args[@]}"
  local cmd=${1:-menu}
  if (( $# )); then shift; fi

  case $cmd in
    help|-h|--help)       usage; return 0 ;;
    version|-v|--version) echo "srv $SRV_VERSION"; return 0 ;;
  esac

  need_root "$cmd" "$@"
  detect_os
  init_dirs
  trap on_err ERR
  trap cleanup EXIT
  ui_init

  case $cmd in
    menu)    (( INTERACTIVE )) || { usage; exit 1; }; acquire_lock; main_menu ;;
    setup)   acquire_lock; cmd_setup "$@" ;;
    install) acquire_lock; cmd_install "$@" ;;
    site)
      case ${1:-} in list|ls|info|show|logs|log) ;; *) acquire_lock ;; esac
      cmd_site "$@" ;;
    app)
      case ${1:-} in list|ls|status|logs|log) ;; *) acquire_lock ;; esac
      cmd_app "$@" ;;
    deploy)
      case ${1:-} in
        releases|list|ls|log|logs|key) ;;
        --run-queue) acquire_lock 1800 ;;          # webhook deploys wait their turn
        *) acquire_lock ;;
      esac
      cmd_deploy "$@" ;;
    ssl)     acquire_lock; cmd_ssl "$@" ;;
    db)      if [[ ${1:-} != list && ${1:-} != ls ]]; then acquire_lock; fi; cmd_db "$@" ;;
    backup)
      case ${1:-} in list|ls) ;; run) acquire_lock 3600 ;; *) acquire_lock ;; esac
      cmd_backup "$@" ;;
    status)  cmd_status ;;
    check)   cmd_check "$@" || exit $? ;;   # 1 = warnings, 2 = failures (not an error)
    dashboard|top) cmd_dashboard "$@" ;;
    notify|alerts)
      case ${1:-} in status|"") ;; *) acquire_lock ;; esac
      cmd_notify "$@" ;;
    php)     case ${1:-list} in list|ls) ;; *) acquire_lock ;; esac; cmd_php "$@" ;;
    node)    case ${1:-list} in list|ls) ;; *) acquire_lock ;; esac; cmd_node "$@" ;;
    python)  case ${1:-list} in list|ls) ;; *) acquire_lock ;; esac; cmd_python "$@" ;;
    tools)   case ${1:-status} in status|show|info) ;; *) acquire_lock ;; esac; cmd_tools "$@" ;;
    cron)    case ${2:-list} in list|ls) ;; *) acquire_lock ;; esac; cmd_cron "$@" ;;
    self-install) self_install ;;
    self-update)  acquire_lock; self_update "$@" ;;
    *) err "Unknown command: $cmd"; echo; usage; exit 1 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
