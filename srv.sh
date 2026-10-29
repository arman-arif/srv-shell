#!/usr/bin/env bash
# =============================================================================
#  srv — single-file server & site manager for Nginx-based web hosting
#  Version 1.0.0 (Phase 1 / MVP)
#
#  What it does
#    • Setup wizard: system upgrade, timezone, hostname, swap, sudo user,
#      SSH hardening, UFW firewall, fail2ban, automatic security updates
#    • Stack: Nginx, PHP-FPM (any version, Ondřej Surý repo) + Composer,
#      MariaDB / MySQL, Certbot (Let's Encrypt), scheduled database backups
#    • Sites: static, SPA, generic PHP, Laravel — each site gets its own Linux
#      user and PHP-FPM pool, an optional database and HTTPS
#    • Anything skipped during setup can be installed later:  srv install
#
#  Supported OS: Ubuntu 22.04+ LTS, Debian 12+
#
#  Quick start
#    sudo bash srv.sh setup     # first run — also installs the 'srv' command
#    sudo srv                   # interactive menu
#    sudo srv help              # all commands
# =============================================================================

set -Eeuo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
SRV_VERSION="1.0.0"
SRV_DIR="/etc/srv"
SRV_STATE="$SRV_DIR/installed.conf"     # installed features
SRV_CFG="$SRV_DIR/srv.conf"             # global settings
SRV_SITES="$SRV_DIR/sites"              # one <domain>.conf per site
SRV_LOG="/var/log/srv.log"
SRV_BIN="/usr/local/bin/srv"
WEB_ROOT="/var/www"
ACME_ROOT="/var/www/_letsencrypt"
NGINX_CUSTOM="/etc/nginx/srv-custom"
BACKUP_DIR="/var/backups/srv"
PHP_DEFAULT="8.4"
PHP_OFFERED=(8.4 8.5 8.3 8.2 8.1)

FEATURES=(upgrade timezone hostname swap sudo-user ssh firewall fail2ban auto-updates
          nginx php composer database certbot backup)

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

# Answers collected by the ask_* functions, consumed by the mod_* functions
OPT_TZ="" OPT_HOSTNAME="" OPT_SWAP="" OPT_USER="" OPT_USER_KEYS="no" OPT_USER_PASS=""
OPT_SSH_PORT="" OPT_ROOT_LOGIN="" OPT_SSH_NOPASS="no" OPT_PHP="" OPT_DB_ENGINE=""
OPT_EMAIL="" OPT_BACKUP_KEEP=""

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
  "$@" >>"$SRV_LOG" 2>&1 || rc=$?
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

gen_password() {
  local p
  p=$(openssl rand -base64 48 2>/dev/null) || p=$(head -c 48 /dev/urandom | base64)
  p=${p//[^A-Za-z0-9]/}
  printf '%s' "${p:0:${1:-24}}"
}

valid_domain()   { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; }
valid_db_ident() { [[ $1 =~ ^[A-Za-z0-9_]{1,64}$ ]]; }

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
    install -m 0755 "$src" "$SRV_BIN"
    ok "Installed the 'srv' command to $SRV_BIN"
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
    certbot)      echo "Certbot — free Let's Encrypt SSL" ;;
    backup)       echo "Daily database backups with rotation" ;;
    *)            echo "$1" ;;
  esac
}

feat_default() {
  case $1 in
    hostname|sudo-user) echo OFF ;;
    swap) if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then echo OFF; else echo ON; fi ;;
    *) echo ON ;;
  esac
}

# ── base (always installed first) ────────────────────────────────────────────
mod_base() {
  step "Installing base packages"
  apt_install ca-certificates curl wget gnupg git unzip zip rsync acl cron logrotate \
              openssl sudo htop whiptail
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
  if [[ -z $(ss -Hltn "sport = :$port" 2>/dev/null) ]]; then
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
}

mod_nginx() {
  step "Installing Nginx"
  apt_install nginx
  install -d -m 755 "$ACME_ROOT" "$NGINX_CUSTOM" /etc/nginx/snippets
  nginx_write_global
  nginx_write_snippets

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

  # PHP error logs inside each site (Nginx logs live in /var/log/nginx)
  cat >/etc/logrotate.d/srv-sites <<'EOF'
/var/www/*/logs/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
}
EOF

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
  for ext in fpm cli common mysql curl mbstring xml zip bcmath intl gd readline sqlite3 opcache; do
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

# ── database ─────────────────────────────────────────────────────────────────
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
  feat_has database || { err "A database server is required first — run: srv install database"; return 1; }
  step "Scheduling daily database backups"
  self_install
  [[ -x $SRV_BIN ]] || { err "$SRV_BIN is missing — copy srv.sh there first"; return 1; }
  local keep=${OPT_BACKUP_KEEP:-$(cfg_get BACKUP_KEEP_DAYS 7)}
  cfg_set BACKUP_KEEP_DAYS "$keep"
  install -d -m 700 "$BACKUP_DIR" "$BACKUP_DIR/db"
  cat >/etc/cron.d/srv-backup <<EOF
# Managed by srv — daily database backups
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 2 * * * root $SRV_BIN backup db --all >>/var/log/srv-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/srv-backup
  feat_set backup "daily 02:30, keep ${keep}d"
  ok "Daily backups at 02:30 → $BACKUP_DIR/db (kept $keep days)"
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
  if in_list backup "${want[@]}" && ! in_list database "${want[@]}" && ! feat_has database; then want+=(database); info "Adding database (required by backup)"; fi
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
      if [[ $x == php ]] && feat_has php; then desc="$desc [installed: $(feat_get php) — add another]"
      elif [[ $x != upgrade ]] && feat_has "$x"; then desc="$desc [installed — reconfigure]"; fi
      items+=("$x" "$desc" OFF)
    done
    mapfile -t todo < <(ui_checklist "Install features" "Select features to install (space = toggle):" "${items[@]}")
  else
    case $f in
      mysql|mariadb) OPT_DB_ENGINE=$f; f=database ;;
      ufw) f=firewall ;;
      ssl|letsencrypt) f=certbot ;;
    esac
    if [[ $f == php && -n ${1:-} ]]; then
      [[ $1 =~ ^[0-9]+\.[0-9]+$ ]] || die "PHP version must look like 8.3"
      OPT_PHP=$1
    fi
    in_list "$f" "${FEATURES[@]}" || die "Unknown feature: $f. Available: ${FEATURES[*]}"
    if [[ $f != php && $f != upgrade ]] && feat_has "$f"; then
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

pick_site() {
  local -a items=(); local d ssl
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    ssl=""; if [[ $(site_get "$d" SSL) == yes ]]; then ssl=", https"; fi
    items+=("$d" "$(site_get "$d" TYPE)$ssl")
  done < <(site_list_domains)
  (( ${#items[@]} )) || { warn "No sites yet — create one with: srv site add"; return 1; }
  if (( ! INTERACTIVE )); then err "Specify the domain."; return 1; fi
  ui_menu "Sites" "Select a site:" "${items[@]}"
}

# resolve_domain [domain] → prints an existing site's domain (asks if missing)
resolve_domain() {
  local d=${1:-}
  d=${d,,}
  if [[ -z $d ]]; then d=$(pick_site) || die "No site selected."; fi
  site_exists "$d" || die "Site not found: $d (see: srv site list)"
  printf '%s' "$d"
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
    if [[ $v != "$php" || ( $type != php && $type != laravel ) ]]; then rm -f "$f"; reload+=("$v"); fi
  done
  if [[ $type == php || $type == laravel ]]; then
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

site_nginx_body() {
  local d=$1 type=$2 root=$3 user=$4
  local sock="/run/php/srv-$user.sock" index="index.html index.htm" tpl
  if [[ $type == php || $type == laravel ]]; then index="index.php index.html"; fi
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
}

site_render_nginx() {
  local d=$1 aliases type user ssl root names v6=0 nv h2_listen=" http2" h2_on=0
  aliases=$(site_get "$d" ALIASES); type=$(site_get "$d" TYPE)
  user=$(site_get "$d" SITE_USER); ssl=$(site_get "$d" SSL no)
  root=$(site_docroot "$d"); names="$d${aliases:+ $aliases}"
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
  site_nginx_body "$d" "$type" "$root" "$user"
  echo "}"
}

# Write + enable the vhost, test it, reload; roll back if Nginx rejects it.
site_apply_nginx() {
  local d=$1 avail="/etc/nginx/sites-available/$1.conf" enabled="/etc/nginx/sites-enabled/$1.conf" bak="" out
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
  local d=$1 base name user pass i=2
  base=${d//[^a-z0-9]/_}; base=${base:0:48}
  name=$base
  while db_exists "$name"; do name="${base}_$i"; i=$(( i + 1 )); done
  user=${name:0:32}; i=2
  while db_user_exists "$user"; do user="${name:0:28}_$i"; i=$(( i + 1 )); done
  pass=$(gen_password 24)
  db_create "$name" "$user" "$pass" || return 1
  site_set "$d" DB_NAME "$name"; site_set "$d" DB_USER "$user"; site_set "$d" DB_PASS "$pass"
}

# ── site add ─────────────────────────────────────────────────────────────────
site_add() {
  local domain="" aliases="" aliases_set=0 type="" php="" webroot="" webroot_set=0 want_db="" want_ssl=""
  while (( $# )); do
    case $1 in
      --domain)  need_val "$@"; domain=$2; shift 2 ;;
      --aliases) need_val "$@"; aliases=$2; aliases_set=1; shift 2 ;;
      --type)    need_val "$@"; type=$2; shift 2 ;;
      --php)     need_val "$@"; php=$2; shift 2 ;;
      --webroot) need_val "$@"; webroot=$2; webroot_set=1; shift 2 ;;
      --db)      want_db=yes; shift ;;
      --no-db)   want_db=no; shift ;;
      --ssl)     want_ssl=yes; shift ;;
      --no-ssl)  want_ssl=no; shift ;;
      -*)        die "Unknown option: $1" ;;
      *)         domain=$1; shift ;;
    esac
  done

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
      laravel "Laravel application") || die "Cancelled."
  fi
  case $type in static|spa|php|laravel) ;; *) die "Unknown type: $type (use static, spa, php or laravel)" ;; esac

  # PHP version
  if [[ $type == php || $type == laravel ]]; then
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

  # Web root
  if (( ! webroot_set )); then
    local def_wr=""
    if [[ $type == laravel ]]; then def_wr=public; fi
    webroot=$(ui_input "Web root inside the app folder (blank = app folder itself; e.g. public, dist, build)" "$def_wr" empty) || die "Cancelled."
  fi
  webroot=${webroot#/}; webroot=${webroot%/}
  if [[ $webroot == *..* || ! $webroot =~ ^[A-Za-z0-9._/-]*$ ]]; then die "Invalid web root: $webroot"; fi

  # Database
  if [[ $type == php || $type == laravel ]]; then
    if [[ -z $want_db ]]; then
      local dbdef=no; if [[ $type == laravel ]]; then dbdef=yes; fi
      if ui_yesno "Create a MySQL/MariaDB database for $domain?" "$dbdef"; then want_db=yes; else want_db=no; fi
    fi
    if [[ $want_db == yes ]]; then ensure_feature database; fi
  else
    want_db=no
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
    local summary
    summary=$(printf 'Domain:      %s\nAliases:     %s\nType:        %s\nPHP:         %s\nWeb root:    %s\nLinux user:  %s\nDatabase:    %s\nHTTPS:       %s' \
      "$domain" "${aliases:-none}" "$type" "${php:-n/a}" "$docroot" "$user" "$want_db" "$want_ssl")
    ui_yesno "Create this site?"$'\n\n'"$summary" yes || die "Cancelled."
  fi

  # Create
  step "Creating site $domain"
  if [[ -d $home ]]; then warn "$home already exists — reusing it"; fi
  if ! id "$user" &>/dev/null; then
    run useradd --home-dir "$home" --no-create-home --shell /bin/bash --user-group "$user" || die "Could not create user $user"
  fi
  mkdir -p "$app" "$home/logs" "$home/tmp"
  # Laravel: keep app/ empty so the project can be cloned straight into it
  if [[ $type != laravel ]]; then
    mkdir -p "$docroot"
    if [[ -z $(ls -A "$docroot" 2>/dev/null) ]]; then site_placeholder "$docroot" "$type" "$domain"; fi
  fi
  chown -R "$user:$user" "$home"
  chmod 750 "$home" "$app" "$home/logs"; chmod 700 "$home/tmp"
  run usermod -aG "$user" www-data   # Nginx may read (not write) the site's files

  {
    echo "# srv site config — managed by srv"
    echo "DOMAIN=$domain"
    echo "ALIASES=$aliases"
    echo "TYPE=$type"
    echo "PHP=$php"
    echo "SITE_USER=$user"
    echo "HOME_DIR=$home"
    echo "APP_DIR=$app"
    echo "WEBROOT=$webroot"
    echo "SSL=no"
    echo "ENABLED=yes"
    echo "DB_NAME="
    echo "DB_USER="
    echo "DB_PASS="
    echo "CREATED=$(date '+%F %T')"
  } >"$(site_file "$domain")"
  chmod 600 "$(site_file "$domain")"

  site_render_pool "$domain" || die "PHP-FPM pool setup failed — see $SRV_LOG. Clean up with: srv site remove $domain"
  site_apply_nginx "$domain" || die "Nginx setup failed. Clean up with: srv site remove $domain"
  site_render_cron "$domain"
  ok "Nginx${php:+ + PHP-FPM $php} configured"

  if [[ $want_db == yes ]]; then
    if site_create_db "$domain"; then ok "Database $(site_get "$domain" DB_NAME) created"
    else warn "Database creation failed — create one later with: srv db create"; fi
  fi
  if [[ $want_ssl == yes ]]; then
    if ! ssl_issue "$domain" 0; then warn "HTTPS isn't enabled yet — fix DNS, then run: srv ssl add $domain"; fi
  fi
  site_summary "$domain"
}

site_summary() {
  local d=$1 scheme=http type user app php dbn
  if [[ $(site_get "$d" SSL) == yes ]]; then scheme=https; fi
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); app=$(site_get "$d" APP_DIR)
  php=$(site_get "$d" PHP); dbn=$(site_get "$d" DB_NAME)
  echo; hr
  printf '%s%s %s is ready%s\n' "$C_G" "$C_BOLD" "$d" "$C_0"
  hr
  printf '  %-13s %s\n' "URL" "$scheme://$d" "App folder" "$app" "Web root" "$(site_docroot "$d")" "Linux user" "$user"
  if [[ -n $php ]]; then printf '  %-13s %s\n' "PHP" "$php  (pool: /etc/php/$php/fpm/pool.d/srv-$user.conf)"; fi
  printf '  %-13s %s\n' "Nginx" "/etc/nginx/sites-available/$d.conf" "Custom conf" "$NGINX_CUSTOM/$d/*.conf"
  if [[ -n $dbn ]]; then
    printf '  %-13s %s\n' "DB name" "$dbn" "DB user" "$(site_get "$d" DB_USER)" "DB password" "$(site_get "$d" DB_PASS)" "DB host" "127.0.0.1:3306"
  fi
  echo
  echo " Next steps"
  echo "   1. Upload your project into $app   (git clone, rsync, SFTP …)"
  echo "   2. srv site fix-perms $d"
  if [[ $type == laravel ]]; then
    echo "   3. runuser -u $user -- env -C $app composer install --no-dev --optimize-autoloader"
    echo "   4. srv site apply-env $d      # APP_URL + DB credentials → .env (+ APP_KEY)"
    echo "   5. runuser -u $user -- env -C $app php$php artisan migrate --force"
  fi
  if [[ $scheme == http ]]; then echo "   •  Enable HTTPS once DNS points here:  srv ssl add $d"; fi
}

# ── Other site commands ──────────────────────────────────────────────────────
site_list() {
  local d any=0 ssl days
  printf '%s%-34s %-8s %-5s %-10s %-9s %s%s\n' "$C_BOLD" DOMAIN TYPE PHP SSL STATUS DATABASE "$C_0"
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    any=1
    ssl=no
    if [[ $(site_get "$d" SSL) == yes ]]; then
      if days=$(cert_days_left "$d"); then ssl="${days}d"; else ssl=yes; fi
    fi
    printf '%-34s %-8s %-5s %-10s %-9s %s\n' "$d" "$(site_get "$d" TYPE)" "$(site_get "$d" PHP)" "$ssl" \
      "$([[ $(site_get "$d" ENABLED yes) == yes ]] && echo enabled || echo disabled)" "$(site_get "$d" DB_NAME)"
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
    printf '  %-10s %s\n' "$k" "${line#*=}"
  done <"$(site_file "$d")"
  hr
  printf '  %-10s %s\n' "Nginx" "/etc/nginx/sites-available/$d.conf" "Custom" "$NGINX_CUSTOM/$d/*.conf" \
    "Logs" "/var/log/nginx/$d.{access,error}.log, $(site_get "$d" HOME_DIR)/logs/"
  local days
  if days=$(cert_days_left "$d"); then printf '  %-10s %s\n' "Cert" "expires in $days days"; fi
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
  ok "$d disabled (files, database and config are kept)"
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
    if site_render_pool "$d" && site_apply_nginx "$d"; then site_render_cron "$d"; ok "$d rebuilt"
    else err "$d failed"; failed=1; fi
  done
  if (( failed )); then return 1; fi
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
  # Owner (PHP) read/write; group (Nginx) read-only; others nothing. Keeps exec bits.
  run chmod -R u+rwX,g+rX,g-w,o-rwx "$app"
  if [[ -f $app/.env ]]; then run chmod 600 "$app/.env"; fi
  ok "Owner $user (read/write), Nginx read-only, others no access"
}

env_set() {
  local file=$1 key=$2 val=$3 tmp
  tmp=$(mktemp)
  if grep -qE "^#?[[:space:]]*${key}=" "$file"; then
    awk -v k="$key" -v v="$val" '!done && $0 ~ "^#?[[:space:]]*" k "=" { print k "=" v; done=1; next } { print }' "$file" >"$tmp"
  else
    cp "$file" "$tmp"
    if [[ -n $(tail -c 1 "$tmp") ]]; then echo >>"$tmp"; fi
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
  fi
  cat "$tmp" >"$file"; rm -f "$tmp"
}

site_apply_env() {
  local d type user app php dbn scheme=http env
  d=$(resolve_domain "${1:-}") || exit 1
  type=$(site_get "$d" TYPE); user=$(site_get "$d" SITE_USER); app=$(site_get "$d" APP_DIR)
  php=$(site_get "$d" PHP); dbn=$(site_get "$d" DB_NAME)
  [[ $type == php || $type == laravel ]] || die "apply-env is for PHP/Laravel sites."
  if [[ $(site_get "$d" SSL) == yes ]]; then scheme=https; fi
  env="$app/.env"
  if [[ ! -f $env ]]; then
    if [[ -f $app/.env.example ]]; then cp "$app/.env.example" "$env"; info "Created .env from .env.example"
    else die "No $env or .env.example found — upload your project first."; fi
  fi
  env_set "$env" APP_URL "$scheme://$d"
  if [[ -n $dbn ]]; then
    env_set "$env" DB_CONNECTION mysql
    env_set "$env" DB_HOST 127.0.0.1
    env_set "$env" DB_PORT 3306
    env_set "$env" DB_DATABASE "$dbn"
    env_set "$env" DB_USERNAME "$(site_get "$d" DB_USER)"
    env_set "$env" DB_PASSWORD "$(site_get "$d" DB_PASS)"
  else
    warn "No database is linked to this site — only APP_URL was written."
  fi
  chown "$user:$user" "$env"; chmod 600 "$env"
  if [[ $type == laravel && -f $app/artisan && -f $app/vendor/autoload.php ]] && ! grep -qE '^APP_KEY=.+' "$env"; then
    run runuser -u "$user" -- env -C "$app" "/usr/bin/php$php" artisan key:generate --force && ok "APP_KEY generated"
  fi
  ok ".env updated for $d"
}

site_logs() {
  local d=${1:-} kind=${2:-error} f
  d=$(resolve_domain "$d") || exit 1
  case $kind in
    error)       f=/var/log/nginx/$d.error.log ;;
    access)      f=/var/log/nginx/$d.access.log ;;
    php)         f=$(site_get "$d" HOME_DIR)/logs/php-error.log ;;
    laravel|app) f=$(site_get "$d" APP_DIR)/storage/logs/laravel.log ;;
    *) die "Log type must be one of: error, access, php, laravel" ;;
  esac
  [[ -f $f ]] || die "No log yet: $f"
  if (( MENU_MODE )); then tail -n 100 "$f"; else exec tail -n 100 -f "$f"; fi
}

site_remove() {
  local d="" purge=0 a
  for a in "$@"; do case $a in --purge) purge=1 ;; *) d=$a ;; esac; done
  d=$(resolve_domain "$d") || exit 1
  local user home php dbn dbu
  user=$(site_get "$d" SITE_USER); home=$(site_get "$d" HOME_DIR); php=$(site_get "$d" PHP)
  dbn=$(site_get "$d" DB_NAME); dbu=$(site_get "$d" DB_USER)

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
    if [[ -n $dbn ]] && ui_yesno "Drop database '$dbn' and user '$dbu'?" no; then del_db=yes; fi
    if [[ -d /etc/letsencrypt/live/$d ]] && ui_yesno "Delete the SSL certificate?" yes; then del_cert=yes; fi
  fi

  step "Removing $d"
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
    if printf 'DROP DATABASE IF EXISTS `%s`;\nDROP USER IF EXISTS '"'"'%s'"'"'@'"'"'localhost'"'"';\n' "$dbn" "$dbu" | db_run >>"$SRV_LOG" 2>&1
    then ok "Database $dbn dropped"; else warn "Couldn't drop database $dbn"; fi
  fi
  if [[ $del_cert == yes && -d /etc/letsencrypt/live/$d ]]; then
    run certbot delete --cert-name "$d" --non-interactive || warn "Couldn't delete the certificate"
  fi
  if [[ $del_files == yes ]]; then
    if [[ $home == "$WEB_ROOT"/?* && $home != *..* && $home != "$ACME_ROOT" ]]; then
      pkill -u "$user" 2>/dev/null || true
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
    enable)           site_enable "${1:-}" ;;
    disable)          site_disable "${1:-}" ;;
    rebuild)          site_rebuild "${1:-}" ;;
    fix-perms|perms)  site_fix_perms "${1:-}" ;;
    apply-env|env)    site_apply_env "${1:-}" ;;
    logs|log)         site_logs "$@" ;;
    remove|rm|delete) site_remove "$@" ;;
    ""|menu)          menu_sites ;;
    *) die "Unknown site command: $sub (see: srv help)" ;;
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
#  DATABASES
# =============================================================================
site_for_db() {   # site_for_db KEY VALUE → prints the site using it
  local d
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    if [[ $(site_get "$d" "$1") == "$2" ]]; then printf '%s' "$d"; return 0; fi
  done < <(site_list_domains)
  return 1
}

db_cmd_create() {
  local name=${1:-} user=${2:-} pass
  if [[ -z $name ]]; then name=$(ui_input "New database name" "") || die "Cancelled."; fi
  valid_db_ident "$name" || die "Use only letters, numbers and _ (max 64 characters)."
  if db_exists "$name"; then die "Database $name already exists."; fi
  if [[ -z $user ]]; then user=$(ui_input "Database user" "${name:0:32}") || die "Cancelled."; fi
  if ! valid_db_ident "$user" || (( ${#user} > 32 )); then die "Invalid user name (letters, numbers, _; max 32)."; fi
  if db_user_exists "$user"; then die "User $user already exists."; fi
  pass=$(gen_password 24)
  db_create "$name" "$user" "$pass" || die "Failed — see $SRV_LOG"
  ok "Database created"
  printf '  %-10s %s\n' Database "$name" User "$user" Password "$pass" Host "127.0.0.1:3306"
}

db_cmd_list() {
  local rows name size
  rows=$(db_sql "SELECT s.SCHEMA_NAME, ROUND(COALESCE(SUM(t.DATA_LENGTH + t.INDEX_LENGTH), 0) / 1048576, 2)
    FROM information_schema.SCHEMATA s
    LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = s.SCHEMA_NAME
    WHERE s.SCHEMA_NAME NOT IN ('information_schema','performance_schema','mysql','sys')
    GROUP BY s.SCHEMA_NAME ORDER BY s.SCHEMA_NAME") || die "Couldn't query the database server."
  printf '%s%-40s %10s  %s%s\n' "$C_BOLD" DATABASE "SIZE (MB)" SITE "$C_0"
  if [[ -z $rows ]]; then echo "  (no databases)"; return 0; fi
  while IFS=$'\t' read -r name size; do
    printf '%-40s %10s  %s\n' "$name" "$size" "$(site_for_db DB_NAME "$name" || true)"
  done <<<"$rows"
}

db_cmd_drop() {
  local name=${1:-} u="" d=""
  if [[ -z $name ]]; then
    local -a items=(); local x
    while IFS= read -r x; do if [[ -n $x ]]; then items+=("$x" "$(site_for_db DB_NAME "$x" || true)"); fi; done < <(db_user_databases)
    (( ${#items[@]} )) || die "No databases to drop."
    name=$(ui_menu "Drop database" "Select the database to DROP:" "${items[@]}") || die "Cancelled."
  fi
  valid_db_ident "$name" || die "Invalid database name."
  db_exists "$name" || die "Database not found: $name"
  if (( INTERACTIVE && ! ASSUME_YES )); then
    local typed; typed=$(ui_input "Type '$name' to confirm DROP (this can't be undone)" "") || die "Cancelled."
    [[ $typed == "$name" ]] || die "Confirmation didn't match — nothing dropped."
  elif (( ! ASSUME_YES )); then
    die "Refusing to drop without --yes in non-interactive mode."
  fi
  if d=$(site_for_db DB_NAME "$name"); then u=$(site_get "$d" DB_USER); fi
  if [[ -z $u ]] && db_user_exists "$name"; then u=$name; fi
  printf 'DROP DATABASE `%s`;\n' "$name" | db_run >>"$SRV_LOG" 2>&1 || die "Drop failed — see $SRV_LOG"
  ok "Database $name dropped"
  if [[ -n $u ]] && ui_yesno "Also drop the database user '$u'?" yes; then
    printf "DROP USER IF EXISTS '%s'@'localhost';\n" "$u" | db_run >>"$SRV_LOG" 2>&1 && ok "User $u dropped"
  fi
  if [[ -n $d ]]; then site_set "$d" DB_NAME ""; site_set "$d" DB_USER ""; site_set "$d" DB_PASS ""; fi
}

db_cmd_password() {
  local u=${1:-} p d
  if [[ -z $u ]]; then u=$(ui_input "Database user to reset" "") || die "Cancelled."; fi
  valid_db_ident "$u" || die "Invalid user name."
  db_user_exists "$u" || die "User not found: $u@localhost"
  p=$(gen_password 24)
  printf "ALTER USER '%s'@'localhost' IDENTIFIED BY '%s';\nFLUSH PRIVILEGES;\n" "$u" "$p" | db_run >>"$SRV_LOG" 2>&1 \
    || die "Password change failed — see $SRV_LOG"
  ok "New password for $u: $p"
  if d=$(site_for_db DB_USER "$u"); then
    site_set "$d" DB_PASS "$p"
    info "Site $d updated — write it to .env with: srv site apply-env $d"
  fi
}

cmd_db() {
  local sub=${1:-}; shift || true
  case $sub in ""|menu) ;; *) ensure_feature database ;; esac
  case $sub in
    create|add)      db_cmd_create "$@" ;;
    list|ls)         db_cmd_list ;;
    drop|rm|delete)  db_cmd_drop "$@" ;;
    password|passwd) db_cmd_password "$@" ;;
    ""|menu)         menu_db ;;
    *) die "Unknown db command: $sub (see: srv help)" ;;
  esac
}

# =============================================================================
#  BACKUPS
# =============================================================================
backup_db() {
  local target="" a
  for a in "$@"; do case $a in --all) target=__all__ ;; -*) die "Unknown option: $a" ;; *) target=$a ;; esac; done
  target=${target:-__all__}
  feat_has database || die "No database server installed."
  local -a dbs=()
  if [[ $target == __all__ ]]; then mapfile -t dbs < <(db_user_databases)
  else db_exists "$target" || die "Database not found: $target"; dbs=("$target"); fi
  (( ${#dbs[@]} )) || { info "No databases to back up."; return 0; }

  local keep dump stamp failed=0 db dir file
  keep=$(cfg_get BACKUP_KEEP_DAYS 7); dump=$(db_dump_bin); stamp=$(date +%Y%m%d-%H%M%S)
  info "Backing up ${#dbs[@]} database(s) — keeping $keep days"
  for db in "${dbs[@]}"; do
    [[ -n $db ]] || continue
    dir="$BACKUP_DIR/db/$db"; install -d -m 700 "$dir"
    file="$dir/$db-$stamp.sql.gz"
    if "$dump" --single-transaction --quick --routines --triggers --events "$db" 2>>"$SRV_LOG" | gzip -6 >"$file.part"; then
      mv -f "$file.part" "$file"; chmod 600 "$file"
      ok "$db → $file ($(du -h "$file" | cut -f1))"
    else
      rm -f "$file.part"; err "Backup failed: $db"; failed=1
    fi
    find "$dir" -maxdepth 1 -type f -name '*.sql.gz' -mtime +"$keep" -delete
  done
  if (( failed )); then return 1; fi
}

backup_list() {
  local f any=0
  if [[ -d $BACKUP_DIR/db ]]; then
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      any=1; printf '%8s  %s\n' "$(du -h "$f" | cut -f1)" "$f"
    done < <(find "$BACKUP_DIR/db" -type f -name '*.sql.gz' | sort -r)
  fi
  if (( ! any )); then echo "  (no backups yet — run: srv backup db --all)"; return 0; fi
  echo
  echo " Restore with:  gunzip -c <file> | $(db_client) <database>"
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
  if [[ $s == active ]]; then printf '  %-22s %s%s%s\n' "$1" "$C_G" "$s" "$C_0"
  else printf '  %-22s %s%s%s\n' "$1" "$C_R" "${s:-unknown}" "$C_0"; fi
}

cmd_status() {
  local f v mem disk up
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
  if feat_has fail2ban; then svc_row fail2ban; fi
  if feat_has certbot; then svc_row certbot.timer; fi
  svc_row cron
  if command -v ufw >/dev/null 2>&1; then
    printf '  %-22s %s\n' ufw "$(ufw status 2>/dev/null | head -n 1 | sed 's/Status: //' || true)"
  fi

  echo; printf '%sSites%s\n' "$C_BOLD" "$C_0"
  site_list
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
      ssl     "SSL certificates" \
      db      "Databases" \
      backup  "Backups" \
      install "Install a feature (anything skipped earlier)" \
      setup   "Run the server setup wizard" \
      status  "Server status" \
      quit    "Exit") || break
    case $c in
      quit)    break ;;
      sites)   try menu_sites; continue ;;
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
      fix-perms "Fix ownership & permissions" \
      apply-env "Write DB credentials into .env" \
      rebuild   "Regenerate Nginx / PHP config" \
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
                php "PHP error log" laravel "Laravel log") || continue
          try site_logs "$d" "$k"
        fi ;;
      *) try "site_${c//-/_}" ;;
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
  ensure_feature database
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
srv $SRV_VERSION — server & site manager (Nginx · PHP · MariaDB/MySQL · Let's Encrypt)

Usage: sudo srv [command] [options]        (no command = interactive menu)

Server
  setup                        Interactive first-time setup wizard
  install [feature] [version]  Install a feature (no name = choose from a list)
                               Features: ${FEATURES[*]}
                               e.g. srv install php 8.3 · srv install mariadb
  status                       Server, services, sites and certificates
  self-install                 Copy this script to $SRV_BIN

Sites
  site add [domain] [--type static|spa|php|laravel] [--aliases "www.example.com"]
                    [--php 8.4] [--webroot public] [--db|--no-db] [--ssl|--no-ssl]
  site list
  site info <domain> [--secrets]
  site enable|disable <domain>
  site rebuild <domain>|--all  Regenerate Nginx / PHP-FPM / cron config
  site fix-perms <domain>      Reset ownership & permissions after uploading files
  site apply-env <domain>      Write APP_URL + DB credentials into .env
  site logs <domain> [error|access|php|laravel]
  site remove <domain> [--purge]   --purge also deletes files, database and cert

SSL
  ssl add <domain> [--force]   Issue / expand a Let's Encrypt certificate
  ssl list
  ssl renew-test

Databases
  db create [name] [user]
  db list
  db drop <name>
  db password <user>           Generate a new password for a database user

Backups
  backup db [name|--all]       Dump database(s) to $BACKUP_DIR/db
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
    ssl)     acquire_lock; cmd_ssl "$@" ;;
    db)      if [[ ${1:-} != list && ${1:-} != ls ]]; then acquire_lock; fi; cmd_db "$@" ;;
    backup)  cmd_backup "$@" ;;
    status)  cmd_status ;;
    self-install) self_install ;;
    *) err "Unknown command: $cmd"; echo; usage; exit 1 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
