#!/usr/bin/env bash
# =============================================================================
#  srv — single-file server & site manager for Nginx-based web hosting
#  Version 2.0.0 (Phase 2)
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
SRV_VERSION="2.0.0"
SRV_DIR="/etc/srv"
SRV_STATE="$SRV_DIR/installed.conf"     # installed features
SRV_CFG="$SRV_DIR/srv.conf"             # global settings
SRV_SITES="$SRV_DIR/sites"              # one <domain>.conf per site
SRV_LOG="/var/log/srv.log"
SRV_BIN="/usr/local/bin/srv"
SRV_LIB="/opt/srv"                      # runtimes and app launchers
SRV_RUN="$SRV_LIB/run"                  # <domain>.sh launchers, PM2 configs
NODE_ROOT="$SRV_LIB/node"               # <major> -> versions/vX.Y.Z
PM2_PREFIX="$SRV_LIB/pm2"
WEB_ROOT="/var/www"
ACME_ROOT="/var/www/_letsencrypt"
NGINX_CUSTOM="/etc/nginx/srv-custom"
BACKUP_DIR="/var/backups/srv"
PHP_DEFAULT="8.4"
PHP_OFFERED=(8.4 8.5 8.3 8.2 8.1)

FEATURES=(upgrade timezone hostname swap sudo-user ssh firewall fail2ban auto-updates
          nginx php composer database postgres redis node python supervisor pm2 certbot backup)

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

# Answers collected by the ask_* functions, consumed by the mod_* functions
OPT_TZ="" OPT_HOSTNAME="" OPT_SWAP="" OPT_USER="" OPT_USER_KEYS="no" OPT_USER_PASS=""
OPT_SSH_PORT="" OPT_ROOT_LOGIN="" OPT_SSH_NOPASS="no" OPT_PHP="" OPT_DB_ENGINE=""
OPT_EMAIL="" OPT_BACKUP_KEEP="" OPT_NODE="" OPT_PG="" OPT_REDIS_POLICY=""

# Answers collected while adding a site
S_NODE="" S_PRESET="" S_START="" S_START_SET=0 S_BUILD="" S_BUILD_SET=0 S_PM="" S_PORT=""
S_FRAMEWORK="" S_SERVER="" S_MODULE="" S_MODULE_SET=0 S_WORKERS="" S_UPSTREAM="" S_WS="" S_PRESERVE=""

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
feat_get() { kv_get "$SRV_STATE" "$1"; }
feat_has() { [[ -n $(kv_get "$SRV_STATE" "$1") ]]; }
feat_set() { kv_set "$SRV_STATE" "$1" "${2:-$(date '+%F %T')}"; }
cfg_get()  { kv_get "$SRV_CFG" "$1" "${2-}"; }
cfg_set()  { kv_set "$SRV_CFG" "$1" "$2"; }

# ── UI: whiptail dialogs with a plain-prompt fallback ────────────────────────
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
valid_port()     { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 )); }
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

acquire_lock() {
  exec 9>/run/srv.lock
  flock -n 9 || die "Another srv process is running. Try again when it finishes."
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
    backup)       echo "Daily database backups with rotation" ;;
    *)            echo "$1" ;;
  esac
}

feat_default() {
  case $1 in
    hostname|sudo-user|postgres|redis|node|python|supervisor|pm2) echo OFF ;;
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
  case ${size: -1} in G) mb=$(( ${size%?} * 1024 )) ;; *) mb=${size%?} ;; esac
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
    p=$(ui_input "SSH port (keep $cur unless you have a reason to change it)" "$cur") || die "Cancelled."
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

mod_nginx() {
  step "Installing Nginx"
  apt_install nginx
  nginx_write_global
  nginx_sync_shared

  # Catch-all: unknown hostnames / bare IP get the connection closed
  rm -f /etc/nginx/sites-enabled/default
  {
    echo "# Managed by srv — catch-all for unknown hosts"
    echo "server {"
    echo "    listen 80 default_server;"
    if [[ -f /proc/net/if_inet6 ]]; then echo "    listen [::]:80 default_server;"; fi
    echo "    server_name _;"
    echo "    access_log off;"
    echo "    return 444;"
    echo "}"
  } >/etc/nginx/sites-available/000-srv-default.conf
  ln -sfn /etc/nginx/sites-available/000-srv-default.conf /etc/nginx/sites-enabled/000-srv-default.conf

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
  feat_set python "$(python3 -V 2>&1 | awk '{print $2}')"
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
    d=$(ui_input "Keep database backups for how many days?" "$(cfg_get BACKUP_KEEP_DAYS 7)") || die "Cancelled."
    if [[ $d =~ ^[0-9]+$ ]] && (( d >= 1 )); then break; fi
    warn "Enter a number of days (1 or more)"; retry_or_die "Invalid number of days: $d"
  done
  OPT_BACKUP_KEEP=$d
}
mod_backup() {
  if ! feat_has database && ! feat_has postgres; then
    err "A database server is required first — run: srv install database  (or: srv install postgres)"; return 1
  fi
  step "Scheduling daily database backups"
  self_install
  [[ -x $SRV_BIN ]] || { err "$SRV_BIN is missing — copy srv.sh there first"; return 1; }
  local keep=${OPT_BACKUP_KEEP:-$(cfg_get BACKUP_KEEP_DAYS 7)}
  cfg_set BACKUP_KEEP_DAYS "$keep"
  install -d -m 700 "$BACKUP_DIR"
  cat >/etc/cron.d/srv-backup <<EOF
# Managed by srv — daily database backups (MySQL/MariaDB and PostgreSQL)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 2 * * * root $SRV_BIN backup db --all >>/var/log/srv-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/srv-backup
  feat_set backup "daily 02:30, keep ${keep}d"
  ok "Daily backups at 02:30 → $BACKUP_DIR (kept $keep days)"
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
      certbot)   extra=${OPT_EMAIL:-no email} ;;
      backup)    extra="keep $OPT_BACKUP_KEEP days" ;;
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
  if in_list backup "${want[@]}" && ! in_list database "${want[@]}" && ! in_list postgres "${want[@]}" \
     && ! feat_has database && ! feat_has postgres; then want+=(database); info "Adding database (required by backup)"; fi
  for f in "${FEATURES[@]}"; do
    if in_list "$f" "${want[@]}"; then final+=("$f"); fi
  done
  (( ${#final[@]} )) || { info "Nothing selected."; return 0; }

  for f in "${final[@]}"; do
    if declare -F "ask_${f//-/_}" >/dev/null; then "ask_${f//-/_}"; fi
  done
  if (( INTERACTIVE && ! ASSUME_YES )); then
    ui_yesno "Ready to install:"$'\n\n'"$(feature_summary "${final[@]}")"$'\n\n'"Proceed?" yes || die "Cancelled."
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
    esac
    in_list "$f" "${FEATURES[@]}" || die "Unknown feature: $f. Available: ${FEATURES[*]}"
    if [[ -n ${1:-} ]]; then
      case $f in
        php)      [[ $1 =~ ^[0-9]+\.[0-9]+$ ]] || die "PHP version must look like 8.3"; OPT_PHP=$1 ;;
        node)     [[ $1 =~ ^([0-9]+|lts|latest)$ ]] || die "Node.js version must be a major version (e.g. 22), lts or latest"; OPT_NODE=$1 ;;
        postgres) [[ $1 =~ ^[0-9]+$ ]] || die "PostgreSQL version must be a number (e.g. 17)"; OPT_PG=$1 ;;
        *) die "'$f' doesn't take a version." ;;
      esac
    fi
    if [[ $f != php && $f != node && $f != upgrade ]] && feat_has "$f"; then
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
    ssl=""; if [[ $(site_get "$d" SSL) == yes ]]; then ssl=", https"; fi
    items+=("$d" "$(site_get "$d" TYPE)$ssl")
  done < <(site_list_domains)
  if (( ! ${#items[@]} )); then
    if [[ $filter == apps ]]; then warn "No apps yet — create one with: srv site add --type node|python"
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

site_render_nginx() {
  local d=$1 aliases ssl names v6=0 nv h2_listen=" http2" h2_on=0
  aliases=$(site_get "$d" ALIASES); ssl=$(site_get "$d" SSL no)
  names="$d${aliases:+ $aliases}"
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
  site_nginx_body "$d"
  echo "}"
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
    awk -v k="$key" -v v="$val" '!done && $0 ~ "^#?[[:space:]]*" k "=" { print k "=" v; done=1; next } { print }' "$file" >"$tmp"
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
  local want_db="" want_ssl="" want_redis="" engine="" want_workers=no
  S_NODE="" S_PRESET="" S_START="" S_START_SET=0 S_BUILD="" S_BUILD_SET=0 S_PM="" S_PORT=""
  S_FRAMEWORK="" S_SERVER="" S_MODULE="" S_MODULE_SET=0 S_WORKERS="" S_UPSTREAM="" S_WS="" S_PRESERVE=""
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
  fi

  # Create
  step "Creating site $domain"
  if [[ -d $home ]]; then warn "$home already exists — reusing it"; fi
  if ! id "$user" &>/dev/null; then
    run useradd --home-dir "$home" --no-create-home --shell /bin/bash --user-group "$user" || die "Could not create user $user"
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
    case $type in
      static|spa) echo "WEBROOT=$webroot" ;;
      php)        printf '%s\n' "PHP=$php" "WEBROOT=$webroot" ;;
      laravel)    printf '%s\n' "PHP=$php" "WEBROOT=$webroot" "QUEUE_WORKERS=0" "HORIZON=no" "REVERB=no" ;;
      node)       printf '%s\n' "NODE=$S_NODE" "PRESET=$S_PRESET" "START_CMD=$S_START" "BUILD_CMD=$S_BUILD" "INSTALL_CMD=" \
                                "PORT=$S_PORT" "PM=$S_PM" "APP_ACTIVE=no" "WEBSOCKET=$S_WS" "TIMEOUT=60" ;;
      python)     printf '%s\n' "PY_FRAMEWORK=$S_FRAMEWORK" "PY_SERVER=$S_SERVER" "PY_APP=$S_MODULE" "WORKERS=$S_WORKERS" "BUILD_CMD=" \
                                "PORT=$S_PORT" "PM=$S_PM" "APP_ACTIVE=no" "WEBSOCKET=$S_WS" "TIMEOUT=60"
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
  site_summary "$domain"
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
  case $type in
    static|spa|php)
      echo "   1. Upload your files into $(site_docroot "$d")   (git clone, rsync, SFTP …)"
      echo "   2. srv site fix-perms $d" ;;
    laravel)
      echo "   1. Upload your project into $app   (git clone, rsync, SFTP …)"
      echo "   2. srv site fix-perms $d"
      echo "   3. runuser -u $user -- env -C $app composer install --no-dev --optimize-autoloader"
      echo "   4. srv site apply-env $d      # APP_URL, DB, Redis, Reverb → .env (+ APP_KEY)"
      echo "   5. runuser -u $user -- env -C $app php$php artisan migrate --force"
      echo "   •  Queue workers / Horizon / Reverb:  srv site workers $d" ;;
    node|python)
      echo "   1. Upload your project into $app   (git clone, rsync, SFTP …)"
      echo "   2. Put your environment variables in $home/app.env"
      echo "   3. srv app build $d       # installs dependencies, builds and starts the app"
      echo "   4. srv app logs $d" ;;
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
    if [[ $k == DB_PASS && -n ${line#*=} && $secrets -eq 0 ]]; then line="DB_PASS=******** (show with --secrets)"; fi
    printf '  %-14s %s\n' "$k" "${line#*=}"
  done <"$(site_file "$d")"
  hr
  printf '  %-14s %s\n' "Nginx" "/etc/nginx/sites-available/$d.conf" "Custom" "$NGINX_CUSTOM/$d/*.conf" \
    "Logs" "/var/log/nginx/$d.{access,error}.log, $(site_get "$d" HOME_DIR)/logs/"
  if is_app_type "$(site_get "$d" TYPE)"; then
    printf '  %-14s %s\n' "Launcher" "$SRV_RUN/$d.sh" "Env file" "$(site_get "$d" HOME_DIR)/app.env" "State" "$(pm_state "$d")"
  fi
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
    python)      allowed="PY_APP PY_SERVER WORKERS BUILD_CMD PORT TIMEOUT WEBSOCKET MAX_BODY STATIC_DIR MEDIA_DIR" ;;
    proxy)       allowed="UPSTREAM PRESERVE_HOST TIMEOUT WEBSOCKET MAX_BODY" ;;
  esac
  # shellcheck disable=SC2086
  in_list "$k" $allowed || die "Editable keys for $type sites: $allowed"
  [[ $v != *$'\n'* ]] || die "The value must be a single line."
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
  esac
  site_set "$d" "$k" "$v"
  ok "$d: $k=$v"
  site_rebuild "$d"
}

site_fix_perms() {
  local d user home app
  d=$(resolve_domain "${1:-}") || exit 1
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR)
  step "Fixing ownership & permissions for $d"
  mkdir -p "$home/logs" "$home/tmp"
  run chown -R "$user:$user" "$home"
  run chmod 750 "$home" "$app" "$home/logs"
  run chmod 700 "$home/tmp"
  # Owner read/write; group (Nginx) read-only; others nothing. Keeps exec bits.
  run chmod -R u+rwX,g+rX,g-w,o-rwx "$app"
  local f
  for f in "$app/.env" "$home/app.env"; do if [[ -f $f ]]; then run chmod 600 "$f"; fi; done
  ok "Owner $user (read/write), Nginx read-only, others no access"
}

site_apply_env() {
  local d type user app php dbn scheme=http env eng port
  d=$(resolve_domain "${1:-}") || exit 1
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); app=$(site_get "$d" APP_DIR)
  php=$(site_get "$d" PHP); dbn=$(site_get "$d" DB_NAME)
  if is_app_type "$type"; then
    app_env_sync "$d"
    ok "$(site_get "$d" HOME_DIR)/app.env updated — restart to apply: srv app restart $d"
    return 0
  fi
  is_php_type "$type" || die "apply-env is for PHP, Laravel, Node.js and Python sites."
  if [[ $(site_get "$d" SSL) == yes ]]; then scheme=https; fi
  env="$app/.env"
  if [[ ! -f $env ]]; then
    if [[ -f $app/.env.example ]]; then cp "$app/.env.example" "$env"; info "Created .env from .env.example"
    else die "No $env or .env.example found — upload your project first."; fi
  fi
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
  if [[ $type == laravel && -f $app/artisan && -f $app/vendor/autoload.php ]] && ! grep -qE '^APP_KEY=.+' "$env"; then
    run runuser -u "$user" -- env -C "$app" "/usr/bin/php$php" artisan key:generate --force && ok "APP_KEY generated"
  fi
  ok ".env updated for $d: ${written[*]}"
  if [[ $type == laravel && -f $(laravel_conf "$d") ]]; then info "Restart workers to load it: srv app restart $d"; fi
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
    queue|horizon|reverb) f=$home/logs/$kind.log ;;
    *) die "Log type must be one of: error, access, php, laravel, app, queue, horizon, reverb" ;;
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
  rm -f "$SRV_RUN/$d.sh" "$SRV_RUN/$d.pm2.config.js"

  rm -f "/etc/nginx/sites-enabled/$d.conf" "/etc/nginx/sites-available/$d.conf"
  rm -rf "${NGINX_CUSTOM:?}/$d"
  nginx_reload || warn "Nginx reload failed — check: nginx -t"
  local f v
  for f in /etc/php/*/fpm/pool.d/srv-"$user".conf; do
    [[ -f $f ]] || continue
    v=${f#/etc/php/}; v=${v%%/*}
    rm -f "$f"; run systemctl reload "php$v-fpm" || true
  done
  rm -f "/etc/cron.d/srv-$user"

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

app_path() {
  local d=$1 base=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  case $(site_get "$d" TYPE) in
    node)   printf '%s/%s/bin:%s' "$NODE_ROOT" "$(site_get "$d" NODE)" "$base" ;;
    python) printf '%s/venv/bin:%s' "$(site_get "$d" HOME_DIR)" "$base" ;;
    *)      printf '%s' "$base" ;;
  esac
}

py_detect_module() {   # Django: find <project>/wsgi.py next to manage.py
  local app=$1 f
  f=$(find "$app" -mindepth 2 -maxdepth 2 -name wsgi.py -print -quit 2>/dev/null) || true
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

# Run a shell command in the app folder as the site user, with app.env loaded.
app_exec() {
  local d=$1 cmd=$2 user home app rc=0
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR)
  log "EXEC  [$d] $cmd"
  runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" LANG=C.UTF-8 TERM=dumb \
      PATH="$(app_path "$d")" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 npm_config_update_notifier=false \
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
  if [[ $type == python && ! -x $(site_get "$d" HOME_DIR)/venv/bin/$(site_get "$d" PY_SERVER gunicorn) ]]; then
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

app_build() {
  local d type user home app cmd
  d=$(resolve_domain "${1:-}" apps) || exit 1
  type=$(site_get "$d" TYPE)
  is_app_type "$type" || die "build is for Node.js and Python apps ($d is a $type site)."
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); app=$(site_get "$d" APP_DIR)
  [[ -n $(ls -A "$app" 2>/dev/null) ]] || die "$app is empty — upload your project first (git clone, rsync, SFTP …)."
  site_fix_perms "$d" 2>/dev/null
  step "Building $d"
  if [[ $type == node ]]; then
    [[ -f $app/package.json ]] || die "No package.json in $app."
    cmd=$(site_get "$d" INSTALL_CMD)
    if [[ -z $cmd ]]; then cmd=$(node_install_cmd "$app"); fi
    info "Installing dependencies: $cmd"
    app_exec "$d" "$cmd" || die "Dependency install failed (see the output above)"
    cmd=$(site_get "$d" BUILD_CMD)
    if [[ -n $cmd ]]; then
      info "Building: $cmd"
      app_exec "$d" "$cmd" || die "Build failed (see the output above)"
    fi
  else
    local venv="$home/venv" server pkg
    if [[ ! -x $venv/bin/python ]]; then
      info "Creating the virtualenv in $venv"
      run runuser -u "$user" -- env -C "$home" python3 -m venv "$venv" || die "Couldn't create the virtualenv"
    fi
    app_exec "$d" "python -m pip install -q --upgrade pip wheel" || die "pip upgrade failed"
    if [[ -f $app/requirements.txt ]]; then
      info "Installing requirements.txt"
      app_exec "$d" "pip install -r requirements.txt" || die "pip install failed (see the output above)"
    elif [[ -f $app/pyproject.toml ]]; then
      info "Installing from pyproject.toml"
      app_exec "$d" "pip install ." || die "pip install failed (see the output above)"
    else
      warn "No requirements.txt or pyproject.toml — skipping dependency install"
    fi
    server=$(site_get "$d" PY_SERVER gunicorn)
    if [[ ! -x $venv/bin/$server ]]; then
      pkg=gunicorn; if [[ $server == uvicorn ]]; then pkg='uvicorn[standard]'; fi
      info "Installing $pkg"
      app_exec "$d" "pip install '$pkg'" || die "Installing $pkg failed"
    fi
    if [[ $(site_get "$d" PY_FRAMEWORK) == django && -f $app/manage.py ]]; then
      info "Collecting static files"
      app_exec "$d" "python manage.py collectstatic --noinput" || warn "collectstatic failed — check STATIC_ROOT in settings.py"
    fi
    cmd=$(site_get "$d" BUILD_CMD)
    if [[ -n $cmd ]]; then info "Running: $cmd"; app_exec "$d" "$cmd" || die "Build command failed"; fi
  fi
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
        if [[ $q =~ ^[0-9]+$ ]] && (( q <= 32 )); then break; fi
        warn "Enter a number from 0 to 32"
      done
    fi
    if ui_yesno "Run Laravel Reverb (WebSockets)? Nginx will send /app/* and /apps/* to it." "$cr"; then r=yes; else r=no; fi
  fi
  q=${q:-$cq}; h=${h:-$ch}; r=${r:-$cr}
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
  for sub in db pgsql; do
    [[ -d $BACKUP_DIR/$sub ]] || continue
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      any=1; printf '%8s  %s\n' "$(du -h "$f" | cut -f1)" "$f"
    done < <(find "$BACKUP_DIR/$sub" -type f -name '*.sql.gz' | sort -r)
  done
  if (( ! any )); then echo "  (no backups yet — run: srv backup db --all)"; return 0; fi
  echo
  echo " Restore with:"
  if feat_has database; then echo "   MySQL/MariaDB:  gunzip -c <file> | $(db_client) <database>"; fi
  if feat_has postgres; then echo "   PostgreSQL:     gunzip -c <file> | runuser -u postgres -- psql -d <database>"; fi
}

cmd_backup() {
  local sub=${1:-}; shift || true
  case $sub in
    db)      backup_db "$@" ;;
    list|ls) backup_list ;;
    ""|menu) menu_backup ;;
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
      ssl     "SSL certificates" \
      db      "Databases (MySQL/MariaDB, PostgreSQL)" \
      backup  "Backups" \
      install "Install a feature (anything skipped earlier)" \
      setup   "Run the server setup wizard" \
      status  "Server status" \
      quit    "Exit") || break
    case $c in
      quit)    break ;;
      sites)   try menu_sites; continue ;;
      apps)    try menu_apps; continue ;;
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
      redis     "Turn Redis on/off for a site" \
      fix-perms "Fix ownership & permissions" \
      apply-env "Write DB / Redis credentials into .env" \
      rebuild   "Regenerate Nginx / PHP / process config" \
      enable    "Enable a site" \
      disable   "Disable a site" \
      remove    "Remove a site" \
      back      "Back") || return 0
    case $c in
      back) return 0 ;;
      list) site_list ;;
      ssl)  try cmd_ssl add ;;
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
    if [[ $c == back ]]; then return 0; fi
    try cmd_db "$c"
    pause
  done
}

menu_backup() {
  local c
  while true; do
    c=$(ui_menu "Backups" "Database backups:" \
      now      "Back up all databases now" \
      list     "List backups" \
      schedule "Set up daily automatic backups" \
      back     "Back") || return 0
    case $c in
      back)     return 0 ;;
      now)      try backup_db --all ;;
      list)     backup_list ;;
      schedule) try cmd_install backup ;;
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
      PHP      --php 8.4  --webroot public
      Node.js  --node 24  --preset next|nuxt|nest|generic  --start "npm start"  --build "npm run build"
      Python   --framework django|flask|fastapi|other  --server gunicorn|uvicorn  --module main:app  --workers 3
      apps     --pm systemd|pm2|supervisor  --port 3001  --websocket|--no-websocket
      proxy    --upstream 127.0.0.1:8080  --websocket|--no-websocket
  site list
  site info <domain> [--secrets]
  site set <domain> <KEY> <value>   Change a setting (START_CMD, PORT, PHP, UPSTREAM …) and rebuild
  site enable|disable <domain>
  site rebuild <domain>|--all  Regenerate Nginx / PHP-FPM / process / cron config
  site fix-perms <domain>      Reset ownership & permissions after uploading files
  site apply-env <domain>      Laravel: APP_URL, DB, Redis, Reverb → .env · apps: DB/Redis → app.env
  site workers <domain> [--queue N] [--horizon|--no-horizon] [--reverb|--no-reverb]
  site redis <domain> on|off
  site logs <domain> [error|access|php|laravel|app|queue|horizon|reverb]
  site remove <domain> [--purge]   --purge also deletes files, database and cert

Apps (Node.js / Python processes, Laravel workers)
  app list
  app build <domain>           Install dependencies, build, then (re)start
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
  backup db [name|--all] [--mysql|--pg]   Dump database(s) to $BACKUP_DIR
  backup list

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
    ssl)     acquire_lock; cmd_ssl "$@" ;;
    db)      if [[ ${1:-} != list && ${1:-} != ls ]]; then acquire_lock; fi; cmd_db "$@" ;;
    backup)  cmd_backup "$@" ;;
    status)  cmd_status ;;
    self-install) self_install ;;
    *) err "Unknown command: $cmd"; echo; usage; exit 1 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
