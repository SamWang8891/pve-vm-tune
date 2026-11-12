#!/usr/bin/env bash
# optimize-for-ssd.sh - reduce SSD wear from Ubuntu 24.04 / 26.04 LTS guests (e.g. Proxmox VMs)
#
#   sudo ./optimize-for-ssd.sh              interactive: pick items, answer questions, review plan, apply
#   sudo ./optimize-for-ssd.sh --status     show what is applied, change nothing
#   sudo ./optimize-for-ssd.sh --dry-run    same flow, but only show what would change
#   sudo ./optimize-for-ssd.sh --yes --apply rsyslog,journal,ship --config ./optimize-for-ssd.conf
#                                           non-interactive (answers from the config file)
#
# Items: rsyslog journal ship docker weblog swap fstab trim tmp
# Nothing is changed until you confirm the plan. Quit / Esc / Ctrl+C before that = no changes.
# Every changed file is backed up to /var/backups/optimize-for-ssd/<timestamp>/ first.

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

NAME=optimize-for-ssd
VERSION=1.4
CONF=/etc/$NAME.conf
BACKUP_DIR=/var/backups/$NAME/$(date +%Y%m%d-%H%M%S)
DRY_RUN=0 ASSUME_YES=0 STATUS_ONLY=0 FORCE=0 APPLY_LIST="" APT_UPDATED=0
PHASE=ask
REBOOT_REASONS=() SUMMARY=() PLAN=()
declare -A WRITTEN=()

# ---------- defaults (overridden by the saved config) ----------
JOURNAL_MODE=log2ram
L2R_SIZE_MB=256
L2R_SYNC_HOURS=6
VOLATILE_MAX=64M
DISK_MAX=200M
VLOGS_URL=""
VLOGS_CA=""
DOCKER_DRIVER=journald
DOCKER_RESTART=yes
DOCKER_RECREATE=no
SWAP_MODE=zram
ZRAM_PERCENT=50          # legacy (v1.0-1.2 configs); ZRAM_SIZE wins when set
ZRAM_SIZE=""             # e.g. 50%, 2G, 2GiB, 1536M, 1536MiB
ZRAM_MIB=0 ZRAM_PCT=0
ZRAM_ALGO=zstd
SWAPPINESS_ZRAM=100
SWAPPINESS_DISK=10
COMMIT_SEC=60
TMP_SIZE=1G
CONF_VARS=(JOURNAL_MODE L2R_SIZE_MB L2R_SYNC_HOURS VOLATILE_MAX DISK_MAX VLOGS_URL VLOGS_CA
           DOCKER_DRIVER DOCKER_RESTART DOCKER_RECREATE SWAP_MODE ZRAM_SIZE ZRAM_ALGO
           SWAPPINESS_ZRAM SWAPPINESS_DISK COMMIT_SEC TMP_SIZE)

# per-run decisions made during the question phase
RSYS_DO=0 RSYS_DEL_OLD=no
JOURNAL_DO=0 L2R_VACUUM=no JOURNAL_DEL_OLD=no
SHIP_DO=0
SWAP_DO=0
FSTAB_DO=0
DOCKER_DO=0

# ---------- paths ----------
JD=/etc/systemd/journald.conf.d/50-$NAME.conf
UPLOAD_DROPIN=/etc/systemd/journal-upload.conf.d/50-$NAME.conf
L2R_TIMER_DROPIN=/etc/systemd/system/log2ram-daily.timer.d/50-$NAME.conf
DOCKER_JSON=/etc/docker/daemon.json
SWAP_SYSCTL=/etc/sysctl.d/99-$NAME-swap.conf
NGINX_MAP=/etc/nginx/conf.d/$NAME-logs.conf
NGINX_VAR=optimize_for_ssd_loggable
APACHE_CONF_NAME=$NAME-logs
APACHE_SNIP=/etc/apache2/conf-available/$APACHE_CONF_NAME.conf

ITEMS=(rsyslog journal ship docker weblog swap fstab trim tmp)
declare -A DESC=(
  [rsyslog]="Remove rsyslog (stop duplicate logging)"
  [journal]="Journal storage: log2ram / RAM-only / capped disk"
  [ship]="Ship journal to VictoriaLogs"
  [docker]="Docker: default log driver journald/local"
  [weblog]="nginx/apache: buffered access log, skip static"
  [swap]="Swap: zram instead of disk / lower swappiness"
  [fstab]="Root fs: noatime + longer ext4 commit"
  [trim]="TRIM: fstrim.timer + discard check"
  [tmp]="/tmp in RAM (tmpfs)"
)

# ---------- output ----------
if [[ -t 1 ]]; then R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' B=$'\e[34m' D=$'\e[2m' N=$'\e[0m'; else R='' G='' Y='' B='' D='' N=''; fi
info() { printf '%s[*]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; }
die()  {
  err "$*"
  if [[ $PHASE == ask ]]; then info "Nothing was changed."; else warn "Stopped while applying. Changed files are backed up in $BACKUP_DIR"; fi
  exit 1
}
quit_clean() { echo; info "Quit - nothing was changed."; exit 0; }
on_int() {
  echo
  if [[ $PHASE == ask ]]; then quit_clean; fi
  warn "Interrupted while applying. Changed files are backed up in $BACKUP_DIR"
  exit 130
}
trap on_int INT TERM
trap 'err "failed at line $LINENO: $BASH_COMMAND"' ERR

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------- helpers ----------
has_cmd()       { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

run() {
  if ((DRY_RUN)); then echo "    ${D}[dry-run]${N} $*"; else "$@"; fi
}

apt_install() {
  local missing=() p
  for p; do pkg_installed "$p" || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  if ((!APT_UPDATED)); then run apt-get update -qq; APT_UPDATED=1; fi
  run apt-get install -y -qq "${missing[@]}"
}

backup() {
  local f
  for f; do
    [[ -e $f || -L $f ]] || continue
    [[ -e $BACKUP_DIR$f ]] && continue          # keep the original from this run
    mkdir -p "$BACKUP_DIR"
    cp -a --parents "$f" "$BACKUP_DIR/"
  done
}

# write_file PATH [MODE] < content  - writes only if changed; backs up; diff in dry-run
write_file() {
  local path=$1 mode=${2:-0644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $path ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
  if ((DRY_RUN)); then
    echo "    ${D}[dry-run] would write $path:${N}"
    if [[ -f $path ]]; then diff -u "$path" "$tmp" | sed 's/^/      /' || true
    else sed 's/^/      + /' "$tmp"; fi
    rm -f "$tmp"; return 0
  fi
  backup "$path"
  mkdir -p "$(dirname "$path")"
  install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  WRITTEN[$path]=1
}

# undo a write made in this run (restore original, or remove if it did not exist)
restore_file() {
  local f=$1
  [[ -n ${WRITTEN[$f]:-} ]] || return 0
  if [[ -e $BACKUP_DIR$f ]]; then cp -a "$BACKUP_DIR$f" "$f"; else rm -f "$f"; fi
  warn "restored $f"
}

# set_kv FILE KEY VALUE [KEY VALUE...] - shell-style KEY=VALUE config files
set_kv() {
  local file=$1 content k v; shift
  content=$(cat "$file" 2>/dev/null || true)
  while (($#)); do
    k=$1 v=$2; shift 2
    content=$(awk -v k="$k" -v v="$v" '
      { line[NR] = $0 }
      END {
        t = 0
        for (i = 1; i <= NR; i++) if (line[i] ~ "^[[:space:]]*" k "=") { t = i; break }
        if (!t) for (i = 1; i <= NR; i++) if (line[i] ~ "^[[:space:]]*#[[:space:]]*" k "=") { t = i; break }
        for (i = 1; i <= NR; i++) {
          if (i == t) { print k "=" v; continue }
          if (line[i] ~ "^[[:space:]]*" k "=") continue
          print line[i]
        }
        if (!t) print k "=" v
      }' <<<"$content")
  done
  content=$(sed '/./,$!d' <<<"$content")   # drop leading blank lines
  printf '%s\n' "$content" | write_file "$file"
}

fstab_ok() {   # fstab_ok CONTENT - validate a candidate fstab
  local tmp out
  tmp=$(mktemp); printf '%s\n' "$1" >"$tmp"
  if out=$(findmnt --verify --tab-file "$tmp" 2>&1); then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; err "new fstab failed verification:"; printf '%s\n' "$out" >&2; return 1
}

mb_of() { du -sm "$@" 2>/dev/null | awk '{s += $1} END {print s + 0}'; }

ram_mib() { awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo; }

# size_to_mib "50%"|"2G"|"2GiB"|"1536M"|"1536MiB" RAM_MIB -> prints MiB (integer)
size_to_mib() {
  local v=${1,,} n u; v=${v// /}
  [[ $v =~ ^([0-9]+([.][0-9]+)?)(%|m|mb|mib|g|gb|gib)$ ]] || return 1
  n=${BASH_REMATCH[1]} u=${BASH_REMATCH[3]}
  case $u in
    %)        awk -v n="$n" -v r="$2" 'BEGIN {printf "%d\n", n * r / 100}' ;;
    m|mb|mib) awk -v n="$n"           'BEGIN {printf "%d\n", n}' ;;
    *)        awk -v n="$n"           'BEGIN {printf "%d\n", n * 1024}' ;;
  esac
}

# ---------- UI (whiptail, or saved answers with --yes) ----------
WT_W=$(( $(tput cols 2>/dev/null || echo 80) - 6 )); ((WT_W > 100)) && WT_W=100; ((WT_W < 60)) && WT_W=60
WT=(whiptail --title "$NAME" --cancel-button "Quit")

ui_input() {   # ui_input VAR "prompt" default [regex]
  local var=$1 prompt=$2 def=$3 re=${4:-} val
  if ((ASSUME_YES)); then
    val=$def
    [[ -z $re || $val =~ $re ]] || die "invalid or missing value for $var: '$val' (set it in $CONF)"
  else
    while :; do
      val=$("${WT[@]}" --inputbox "$prompt" 15 "$WT_W" "$def" 3>&1 1>&2 2>&3) || quit_clean
      [[ -z $re || $val =~ $re ]] && break
      whiptail --title "$NAME" --msgbox "Invalid value: '$val'" 8 60
    done
  fi
  printf -v "$var" '%s' "$val"
}

# ui_yesno "prompt" yes|no -> 0/1. During questions, Esc quits without changes.
ui_yesno() {
  local prompt=$1 def=${2:-no} rc=0 extra=()
  if ((ASSUME_YES)); then [[ $def == yes ]]; return; fi
  [[ $def == no ]] && extra=(--defaultno)
  [[ $PHASE == ask ]] && prompt+="\n\n(Esc = quit without changing anything)"
  whiptail --title "$NAME" "${extra[@]}" --yesno "$prompt" 18 "$WT_W" || rc=$?
  if ((rc == 255)) && [[ $PHASE == ask ]]; then quit_clean; fi
  ((rc == 0))
}

ui_radio() {   # ui_radio VAR "prompt" current tag desc [tag desc...]
  local var=$1 prompt=$2 cur=$3 args=() v; shift 3
  if ((ASSUME_YES)); then printf -v "$var" '%s' "$cur"; return; fi
  while (($#)); do
    if [[ $1 == "$cur" ]]; then args+=("$1" "$2" ON); else args+=("$1" "$2" OFF); fi
    shift 2
  done
  v=$("${WT[@]}" --radiolist "$prompt" 16 "$WT_W" 5 "${args[@]}" 3>&1 1>&2 2>&3) || quit_clean
  printf -v "$var" '%s' "$v"
}

ui_msg() {
  if ((ASSUME_YES)); then printf '%s\n' "$1" | sed 's/^/    /'; else whiptail --title "$NAME" --msgbox "$1" 18 "$WT_W" || true; fi
}

# ---------- state detection: each st_* prints "state|detail" (done/todo/n/a) ----------
journal_mode_now() {
  if pkg_installed log2ram; then echo log2ram; return; fi
  if [[ -f $JD ]]; then
    if grep -q '^Storage=volatile' "$JD"; then echo volatile; return; fi
    if grep -q '^Storage=persistent' "$JD"; then echo disk; return; fi
  fi
  echo none
}
swap_disk_list() { swapon --show=NAME --noheadings --raw 2>/dev/null | grep -v '^/dev/zram' || true; }
zram_active()    { swapon --show=NAME --noheadings --raw 2>/dev/null | grep -q '^/dev/zram'; }
swap_mode_now() {
  if zram_active && [[ -z $(swap_disk_list) ]]; then echo zram
  elif [[ -f $SWAP_SYSCTL ]]; then echo swappiness
  else echo none; fi
}
docker_present() { has_cmd dockerd || pkg_installed docker-ce || pkg_installed docker.io; }
docker_driver_now() {
  [[ -s $DOCKER_JSON ]] || { echo ""; return; }
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("log-driver",""))' "$DOCKER_JSON" 2>/dev/null || echo "?"
}
root_fstab_opts() { awk '$1 !~ /^#/ && $2 == "/" {print $4; exit}' /etc/fstab; }
root_discard_ok() {
  local src m
  src=$(findmnt -no SOURCE / 2>/dev/null) || return 1
  m=$(lsblk -dno DISC-MAX "$src" 2>/dev/null | tr -d ' ')
  [[ -n $m && $m != 0B ]]
}

st_rsyslog() { if pkg_installed rsyslog; then echo "todo|rsyslog installed"; else echo "done|rsyslog not installed"; fi; }
st_journal() { local m; m=$(journal_mode_now); if [[ $m == none ]]; then echo "todo|journald defaults"; else echo "done|$m"; fi; }
st_ship() {
  if [[ -f $UPLOAD_DROPIN ]] && systemctl is-enabled -q systemd-journal-upload 2>/dev/null; then
    echo "done|$(sed -n 's/^URL=//p' "$UPLOAD_DROPIN")"
  else echo "todo|not shipping"; fi
}
st_docker() {
  docker_present || { echo "n/a|docker not installed"; return; }
  local d; d=$(docker_driver_now)
  case $d in journald|local) echo "done|log-driver $d";; *) echo "todo|log-driver ${d:-json-file (default)}";; esac
}
st_weblog() {
  local any=0 done=1
  if has_cmd nginx; then any=1; grep -qs "$NGINX_VAR" /etc/nginx/nginx.conf || done=0; fi
  if has_cmd apache2ctl; then any=1; [[ -e /etc/apache2/conf-enabled/$APACHE_CONF_NAME.conf ]] || done=0; fi
  if ((!any)); then echo "n/a|no nginx/apache"; elif ((done)); then echo "done|buffered"; else echo "todo|unbuffered"; fi
}
st_swap() {
  local m; m=$(swap_mode_now)
  if [[ $m == none ]]; then echo "todo|$(swap_disk_list | tr '\n' ' ')swappiness=$(cat /proc/sys/vm/swappiness)"
  else echo "done|$m, swappiness=$(cat /proc/sys/vm/swappiness)"; fi
}
st_fstab() {
  local o fs; o=$(root_fstab_opts); fs=$(findmnt -no FSTYPE / 2>/dev/null || echo ?)
  if [[ ,$o, == *,noatime,* ]] && { [[ $fs != ext4 ]] || [[ $o == *commit=* ]]; }; then echo "done|$o"
  else echo "todo|${o:-no / entry} ($fs)"; fi
}
st_trim() {
  local t=0; systemctl is-enabled -q fstrim.timer 2>/dev/null && t=1
  if ((t)) && root_discard_ok; then echo "done|timer on, discard supported"
  elif ((t)); then echo "todo|timer on, but virtual disk has no discard"
  else echo "todo|fstrim.timer disabled"; fi
}
st_tmp() {
  if [[ $(findmnt -no FSTYPE /tmp 2>/dev/null) == tmpfs ]]; then
    echo "done|tmpfs $(findmnt -no SIZE /tmp 2>/dev/null || true)"
  elif awk '$1 !~ /^#/ && $2 == "/tmp" && $3 == "tmpfs" {f=1} END {exit !f}' /etc/fstab; then
    echo "done|in fstab, reboot pending"
  else echo "todo|on disk"; fi
}

print_status() {
  local k s d c
  printf '\n%s%-8s %-5s %-48s %s%s\n' "$D" ITEM STATE DESCRIPTION DETAIL "$N"
  for k in "${ITEMS[@]}"; do
    IFS='|' read -r s d < <("st_$k")
    case $s in done) c=$G;; todo) c=$Y;; *) c=$D;; esac
    printf '%-8s %s%-5s%s %-48s %s\n' "$k" "$c" "$s" "$N" "${DESC[$k]}" "$d"
  done
  echo
}

select_items() {
  local args=() k s d label
  for k in "${ITEMS[@]}"; do
    IFS='|' read -r s d < <("st_$k")
    case $s in
      n/a)  continue ;;
      done) label="[DONE] ${DESC[$k]} ($d)" ;;
      *)    label="[    ] ${DESC[$k]}" ;;
    esac
    args+=("$k" "${label:0:$((WT_W - 20))}" OFF)
  done
  SELECTED=$(whiptail --title "$NAME $VERSION - $(hostname)" --ok-button "Next" --cancel-button "Quit" \
    --separate-output --checklist \
    "SPACE toggles, ENTER = Next. [DONE] = already applied; tick it to re-apply.\nNothing changes until you confirm the plan at the end. Quit / Esc = exit now." \
    22 "$WT_W" 10 "${args[@]}" 3>&1 1>&2 2>&3) || quit_clean
}

# =====================================================================
# Question phase (ask_*): only reads state and collects answers.
# Apply phase (do_*): makes the changes.
# =====================================================================

# ---------- rsyslog ----------
ask_rsyslog() {
  RSYS_DO=0
  if ! pkg_installed rsyslog; then PLAN+=("rsyslog: already removed - nothing to do"); return; fi
  local extra
  extra=$(apt-get -s purge rsyslog 2>/dev/null | awk '/^(Purg|Remv) / {print $2}' | grep -vx rsyslog || true)
  if [[ -n $extra ]]; then
    if ! ui_yesno "Purging rsyslog would also remove:\n\n$extra\n\nInclude rsyslog removal anyway?" no; then
      PLAN+=("rsyslog: skipped (would remove other packages)"); return
    fi
  fi
  RSYS_DO=1
  RSYS_DEL_OLD=no
  if ui_yesno "Also delete rsyslog's old files (/var/log/syslog*, kern.log*, auth.log*, mail.*)?\n\nThe same logs are still in the journal (journalctl)." yes; then RSYS_DEL_OLD=yes; fi
  PLAN+=("rsyslog: purge package$([[ $RSYS_DEL_OLD == yes ]] && echo ', delete old syslog/auth/kern/mail logs' || true)")
}
do_rsyslog() {
  ((RSYS_DO)) || return 0
  run apt-get purge -y -qq rsyslog
  if [[ $RSYS_DEL_OLD == yes ]]; then
    run bash -c 'rm -f /var/log/syslog* /var/log/kern.log* /var/log/auth.log* /var/log/mail.log* /var/log/mail.err*'
  fi
  SUMMARY+=("rsyslog purged")
}

# ---------- journal ----------
ask_journal() {
  JOURNAL_DO=1
  ui_radio JOURNAL_MODE "Where should the systemd journal live? (current: $(journal_mode_now))" "$JOURNAL_MODE" \
    log2ram  "RAM, synced to disk every N hours + at shutdown" \
    volatile "RAM only (pair with shipping to VictoriaLogs)" \
    disk     "On disk, size-capped"
  case $JOURNAL_MODE in
    log2ram)
      local used journal rotated jmax est
      used=$(mb_of /var/log)
      journal=$(mb_of /var/log/journal)
      rotated=$(find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -printf '%s\n' 2>/dev/null | awk '{s += $1} END {print int(s / 1048576)}')
      while :; do
        ui_input L2R_SIZE_MB "RAM size for /var/log, in MB.\n\n/var/log now: ${used}MB  (journal ${journal}MB, rotated logs ${rotated}MB)" "$L2R_SIZE_MB" '^[0-9]+$'
        jmax=$(( L2R_SIZE_MB * 40 / 100 ))
        if (( used <= L2R_SIZE_MB * 70 / 100 )); then L2R_VACUUM=no; break; fi
        est=$(( used - journal - rotated + (journal < jmax ? journal : jmax) ))
        if (( est <= L2R_SIZE_MB * 85 / 100 )) && \
           ui_yesno "/var/log is ${used}MB - too big for ${L2R_SIZE_MB}MB.\n\nCleaning up (journal vacuumed to ${jmax}MB, rotated *.gz / *.1 logs deleted)\nbrings it to about ${est}MB.\n\nDo that cleanup as part of the plan?" yes; then
          L2R_VACUUM=yes; break
        fi
        ((ASSUME_YES)) && die "/var/log (${used}MB, ~${est}MB after cleanup) won't fit in L2R_SIZE_MB=${L2R_SIZE_MB}"
        ui_msg "/var/log needs about ${est}MB even after cleanup (or cleanup was declined).\n\nPick a bigger size."
      done
      ui_input L2R_SYNC_HOURS "Sync /var/log to disk every N hours (1-24).\nA crash loses logs since the last sync (shipping to VictoriaLogs covers that)." "$L2R_SYNC_HOURS" '^([1-9]|1[0-9]|2[0-4])$'
      PLAN+=("journal: log2ram ${L2R_SIZE_MB}MB, sync every ${L2R_SYNC_HOURS}h, journal capped at ${jmax}MB$([[ $L2R_VACUUM == yes ]] && echo ', clean up /var/log first' || true) (reboot)")
      ;;
    volatile)
      ui_input VOLATILE_MAX "Max RAM for the journal (e.g. 64M)" "$VOLATILE_MAX" '^[0-9]+[MG]$'
      JOURNAL_DEL_OLD=no
      if [[ -d /var/log/journal ]] && ui_yesno "Delete the old on-disk journal in /var/log/journal ($(mb_of /var/log/journal)MB)?" yes; then JOURNAL_DEL_OLD=yes; fi
      PLAN+=("journal: RAM only, max $VOLATILE_MAX$([[ $JOURNAL_DEL_OLD == yes ]] && echo ', delete old on-disk journal' || true)")
      ;;
    disk)
      ui_input DISK_MAX "Max disk space for the journal (e.g. 200M)" "$DISK_MAX" '^[0-9]+[MG]$'
      PLAN+=("journal: on disk, max $DISK_MAX")
      ;;
    *) die "unknown JOURNAL_MODE '$JOURNAL_MODE'" ;;
  esac
  if pkg_installed log2ram && [[ $JOURNAL_MODE != log2ram ]]; then PLAN+=("journal: remove log2ram (reboot)"); fi
}

remove_log2ram() {
  pkg_installed log2ram || return 0
  info "removing log2ram (syncing /var/log to disk first)"
  run systemctl reload log2ram || true
  run apt-get purge -y -qq log2ram
  if [[ -f $L2R_TIMER_DROPIN ]]; then run rm -f "$L2R_TIMER_DROPIN"; fi
  run systemctl daemon-reload
  REBOOT_REASONS+=("log2ram removed - reboot so /var/log is back on disk")
}

install_log2ram() {
  pkg_installed log2ram && return 0
  info "installing log2ram from packages.azlux.fr"
  run install -d -m 0755 /usr/share/keyrings
  run curl -fsSL https://azlux.fr/repo.gpg -o /usr/share/keyrings/azlux-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ bookworm main" \
    | write_file /etc/apt/sources.list.d/azlux.list
  APT_UPDATED=0
  apt_install log2ram
}

do_journal() {
  ((JOURNAL_DO)) || return 0
  case $JOURNAL_MODE in
    log2ram)
      local jmax=$(( L2R_SIZE_MB * 40 / 100 ))M used
      if [[ $L2R_VACUUM == yes ]]; then
        run journalctl --vacuum-size="$jmax"
        run find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -delete
      fi
      printf '[Journal]\nStorage=persistent\nSystemMaxUse=%s\nCompress=yes\n' "$jmax" | write_file "$JD"
      run systemctl restart systemd-journald
      used=$(mb_of /var/log)
      if ((!DRY_RUN)) && (( used > L2R_SIZE_MB * 85 / 100 )); then
        warn "/var/log is still ${used}MB - too big for ${L2R_SIZE_MB}MB. Journal is capped, but log2ram was NOT installed."
        SUMMARY+=("journal: capped at $jmax (log2ram skipped - /var/log too big)")
        return
      fi
      install_log2ram
      set_kv /etc/log2ram.conf SIZE "${L2R_SIZE_MB}M" USE_RSYNC true MAIL false
      printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 00/%s:00:00\n' "$L2R_SYNC_HOURS" | write_file "$L2R_TIMER_DROPIN"
      run systemctl daemon-reload
      run systemctl enable log2ram log2ram-daily.timer
      REBOOT_REASONS+=("log2ram mounts /var/log in RAM at boot")
      SUMMARY+=("journal: log2ram ${L2R_SIZE_MB}MB, sync every ${L2R_SYNC_HOURS}h, journal cap $jmax")
      ;;
    volatile)
      remove_log2ram
      printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=%s\n' "$VOLATILE_MAX" | write_file "$JD"
      run systemctl restart systemd-journald
      if [[ $JOURNAL_DEL_OLD == yes ]]; then run rm -rf /var/log/journal; fi
      if [[ ! -f $UPLOAD_DROPIN && $SHIP_DO -eq 0 ]]; then warn "RAM-only journal: logs vanish on reboot unless you also ship them"; fi
      SUMMARY+=("journal: RAM only, max $VOLATILE_MAX")
      ;;
    disk)
      remove_log2ram
      printf '[Journal]\nStorage=persistent\nSystemMaxUse=%s\nCompress=yes\n' "$DISK_MAX" | write_file "$JD"
      run mkdir -p /var/log/journal
      run systemd-tmpfiles --create --prefix /var/log/journal
      run systemctl restart systemd-journald
      run journalctl --flush
      run journalctl --vacuum-size="$DISK_MAX"
      SUMMARY+=("journal: on disk, max $DISK_MAX")
      ;;
  esac
}

# ---------- ship ----------
ask_ship() {
  SHIP_DO=1
  local def=$VLOGS_URL base curl_tls=() code
  ((ASSUME_YES)) || def=${def:-https://192.168.1.6:9443/insert/journald}
  ui_input VLOGS_URL "VictoriaLogs journald endpoint:" "$def" '^https?://[^/]+/.+$'
  if [[ $VLOGS_URL == https://* ]]; then
    while :; do
      ui_input VLOGS_CA "HTTPS certificate check:\n\n  all   = encrypt, but don't verify the certificate (self-signed on IP)\n  /path = verify against this CA file (e.g. Caddy's or step-ca's root.crt)\n  empty = verify against the system CAs" "${VLOGS_CA:-all}" ''
      [[ -z $VLOGS_CA || $VLOGS_CA == all || -f $VLOGS_CA ]] && break
      ((ASSUME_YES)) && die "CA file $VLOGS_CA not found"
      ui_msg "File not found: $VLOGS_CA"
    done
  else
    VLOGS_CA=""
  fi
  base=${VLOGS_URL%%/insert/*}
  if [[ $VLOGS_CA == all ]]; then curl_tls=(-k); elif [[ -n $VLOGS_CA ]]; then curl_tls=(--cacert "$VLOGS_CA"); fi
  # /insert must be allowed from this VM: an empty POST should get 2xx/4xx from VictoriaLogs, not 403 from the proxy
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${curl_tls[@]}" -X POST "$VLOGS_URL/upload" 2>/dev/null || echo 000)
  if [[ $code == 000 || $code == 403 ]]; then
    local why="can't reach $base"; [[ $code == 403 ]] && why="$base answered 403 - this VM's IP is probably not in the proxy's insert allow-list"
    if ! ui_yesno "$why\n\nConfigure shipping anyway? journal-upload keeps retrying and catches up later." no; then
      SHIP_DO=0; PLAN+=("ship: skipped ($why)"); return
    fi
  fi
  PLAN+=("ship: systemd-journal-upload -> $VLOGS_URL$([[ $VLOGS_CA == all ]] && echo ' (TLS not verified)' || true), retry forever while the receiver is down")
}
do_ship() {
  ((SHIP_DO)) || return 0
  apt_install systemd-journal-remote
  {
    echo "[Upload]"
    echo "URL=$VLOGS_URL"
    if [[ -n $VLOGS_CA ]]; then echo "TrustedCertificateFile=$VLOGS_CA"; fi
  } | write_file "$UPLOAD_DROPIN"
  # keep retrying while the receiver is down/restarting; it resumes from its saved cursor, so nothing is skipped
  printf '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestart=always\nRestartSec=30\n' \
    | write_file /etc/systemd/system/systemd-journal-upload.service.d/50-$NAME.conf
  run systemctl daemon-reload
  run systemctl enable systemd-journal-upload
  run systemctl restart systemd-journal-upload
  if ((!DRY_RUN)); then
    logger -t "$NAME" "journal shipping configured on $(hostname)"
    sleep 8
    if systemctl is-active -q systemd-journal-upload && \
       ! journalctl -u systemd-journal-upload --since "-15s" --no-pager -q 2>/dev/null | grep -qiE 'fail|error|refused|denied|certificate'; then
      ok "journal-upload running, no errors (first run sends the whole existing journal)"
    else
      warn "journal-upload reports problems:"
      journalctl -u systemd-journal-upload --since "-30s" --no-pager -q 2>/dev/null | tail -5 | sed 's/^/      /'
    fi
  fi
  SUMMARY+=("shipping journal -> $VLOGS_URL")
}

# ---------- docker ----------
ask_docker() {
  DOCKER_DO=0
  if ! docker_present; then PLAN+=("docker: skipped (docker not installed)"); return; fi
  DOCKER_DO=1
  ui_radio DOCKER_DRIVER "Default log driver for new containers:" "$DOCKER_DRIVER" \
    journald "into the journal (log2ram'd / shipped with everything)" \
    local    "compressed local files, 10M x 3 per container"
  if ui_yesno "Restart Docker after changing daemon.json?\n(containers with a restart policy come back automatically)" "$DOCKER_RESTART"; then DOCKER_RESTART=yes; else DOCKER_RESTART=no; fi
  DOCKER_RECREATE=no
  if [[ $DOCKER_RESTART == yes ]] && ui_yesno "Existing containers keep their old log driver until recreated.\n\nRecreate all docker compose projects too? (brief downtime)" no; then DOCKER_RECREATE=yes; fi
  PLAN+=("docker: log-driver $DOCKER_DRIVER, restart docker: $DOCKER_RESTART, recreate compose projects: $DOCKER_RECREATE")
}
do_docker() {
  ((DOCKER_DO)) || return 0
  local new tmp
  new=$(python3 - "$DOCKER_JSON" "$DOCKER_DRIVER" <<'PY'
import json, os, sys
path, drv = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        cfg = json.load(f)
cfg["log-driver"] = drv
cfg["log-opts"] = {"tag": "{{.Name}}"} if drv == "journald" else {"max-size": "10m", "max-file": "3"}
print(json.dumps(cfg, indent=2))
PY
) || { warn "could not parse $DOCKER_JSON - docker skipped"; return; }
  tmp=$(mktemp); printf '%s\n' "$new" >"$tmp"
  if dockerd --help 2>&1 | grep -q -- '--validate'; then
    if ! dockerd --validate --config-file "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; warn "new daemon.json failed validation - docker skipped"; return; fi
  fi
  rm -f "$tmp"
  printf '%s\n' "$new" | write_file "$DOCKER_JSON"
  if [[ $DOCKER_RESTART == yes ]]; then run systemctl restart docker
  else REBOOT_REASONS+=("docker restart needed for the new log driver"); fi

  if [[ $DOCKER_RECREATE == yes ]]; then
    local name files fl f args
    while IFS=$'\t' read -r name files; do
      [[ -n $name ]] || continue
      args=(); IFS=',' read -ra fl <<<"$files"
      for f in "${fl[@]}"; do args+=(-f "$f"); done
      info "recreating compose project $name"
      run docker compose -p "$name" "${args[@]}" up -d --force-recreate
    done < <(docker compose ls --all --format json 2>/dev/null \
             | python3 -c 'import json,sys; [print(p["Name"]+"\t"+p["ConfigFiles"]) for p in json.load(sys.stdin)]' || true)
  else
    warn "existing containers: run 'docker compose up -d --force-recreate' in each project to switch them"
  fi
  local loose
  loose=$(docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null | awk -F'|' '$2=="" {print $1}' || true)
  if [[ -n $loose ]]; then warn "containers not managed by compose (recreate manually): $(echo "$loose" | tr '\n' ' ')"; fi
  SUMMARY+=("docker log-driver: $DOCKER_DRIVER")
}

# ---------- weblog ----------
ask_weblog() {
  if has_cmd nginx; then PLAN+=("weblog: nginx - buffered access log (64k / 5 min), static assets not logged"); fi
  if has_cmd apache2ctl; then PLAN+=("weblog: apache - BufferedLogs On, static assets not logged"); fi
}
weblog_nginx() {
  local conf=/etc/nginx/nginx.conf
  write_file "$NGINX_MAP" <<EOF
# $NAME: don't write access-log lines for static assets
map \$request_uri \$$NGINX_VAR {
    ~*\\.(css|js|mjs|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|map)(\\?.*)?\$ 0;
    default 1;
}
EOF
  if ! grep -q "$NGINX_VAR" "$conf"; then
    if grep -Eq '^\s*access_log\s+/var/log/nginx/access\.log\s*;' "$conf"; then
      sed -E "s#^(\\s*)access_log\\s+/var/log/nginx/access\\.log\\s*;#\\1access_log /var/log/nginx/access.log combined buffer=64k flush=5m if=\$$NGINX_VAR;#" "$conf" \
        | write_file "$conf"
    else
      warn "nginx.conf has a non-default access_log line - not changed. Add: buffer=64k flush=5m if=\$$NGINX_VAR"
    fi
  fi
  if ((!DRY_RUN)); then
    if nginx -t >/dev/null 2>&1; then run systemctl reload nginx; ok "nginx reloaded"
    else err "nginx -t failed - rolling back"; restore_file "$conf"; restore_file "$NGINX_MAP"; return; fi
  fi
  local own
  own=$(grep -ls '^\s*access_log' /etc/nginx/sites-enabled/* 2>/dev/null || true)
  if [[ -n $own ]]; then warn "these sites set their own access_log (not buffered - add 'buffer=64k flush=5m if=\$$NGINX_VAR'):"; echo "$own" | sed 's/^/      /'; fi
  SUMMARY+=("nginx: buffered access log, static assets skipped")
}
weblog_apache() {
  write_file "$APACHE_SNIP" <<EOF
# $NAME: buffer access-log writes, skip static assets
BufferedLogs On
SetEnvIfNoCase Request_URI "\\.(css|js|mjs|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|map)\$" dontlog
EOF
  local f changed=()
  for f in /etc/apache2/sites-enabled/*.conf /etc/apache2/conf-enabled/*.conf; do
    [[ -e $f ]] || continue
    f=$(readlink -f "$f")
    [[ $f == "$APACHE_SNIP" ]] && continue
    if grep -E '^\s*CustomLog\s' "$f" | grep -vq 'env='; then
      sed -E '/^\s*CustomLog\s/{/env=/!s/\s*$/ env=!dontlog/}' "$f" | write_file "$f"
      changed+=("$f")
    fi
  done
  run a2enconf -q "$APACHE_CONF_NAME"
  if ((!DRY_RUN)); then
    if apache2ctl configtest >/dev/null 2>&1; then run systemctl reload apache2; ok "apache reloaded"
    else
      err "apache2ctl configtest failed - rolling back"
      a2disconf -q "$APACHE_CONF_NAME" || true
      restore_file "$APACHE_SNIP"
      for f in "${changed[@]}"; do restore_file "$f"; done
      return
    fi
  fi
  SUMMARY+=("apache: BufferedLogs on, static assets skipped (${#changed[@]} files edited)")
}
do_weblog() {
  if has_cmd nginx; then weblog_nginx; fi
  if has_cmd apache2ctl; then weblog_apache; fi
}

# ---------- swap ----------
ask_swap() {
  SWAP_DO=1
  ui_radio SWAP_MODE "Swap strategy (current: $(swap_mode_now)):" "$SWAP_MODE" \
    zram       "compressed swap in RAM; disk swap removed" \
    swappiness "keep disk swap, just swap less"
  if [[ $SWAP_MODE == zram ]] && ! modprobe -n zram >/dev/null 2>&1; then
    if ui_yesno "Kernel $(uname -r) has no zram module\n(fix: apt install linux-modules-extra-$(uname -r), or use the generic kernel).\n\nJust lower swappiness instead (keep disk swap)?" yes; then
      SWAP_MODE=swappiness
    else
      SWAP_DO=0; PLAN+=("swap: skipped (no zram module)"); return
    fi
  fi
  case $SWAP_MODE in
    zram)
      local ram mib
      ram=$(ram_mib)
      [[ -n $ZRAM_SIZE ]] || ZRAM_SIZE="${ZRAM_PERCENT}%"
      while :; do
        if ((ASSUME_YES)); then
          mib=$(size_to_mib "$ZRAM_SIZE" "$ram") && (( mib >= 64 && mib <= ram * 2 )) \
            || die "ZRAM_SIZE '$ZRAM_SIZE' invalid (64 MiB .. 2x RAM = $((ram * 2)) MiB)"
          ZRAM_MIB=$mib ZRAM_PCT=$(( mib * 100 / ram )); break
        fi
        # step 1: enter a value -> [Calculate] / [Quit]
        ZRAM_SIZE=$(whiptail --title "$NAME - zram size" --ok-button "Calculate" --cancel-button "Quit" \
          --inputbox "zram swap size - a % of RAM or a size:\n\n   50%     2G     2GiB     1536M     1536MiB\n\nRAM in this VM: ${ram} MiB" \
          15 "$WT_W" "$ZRAM_SIZE" 3>&1 1>&2 2>&3) || quit_clean
        if ! mib=$(size_to_mib "$ZRAM_SIZE" "$ram") || (( mib < 64 || mib > ram * 2 )); then
          whiptail --title "$NAME - zram size" --ok-button "Back" \
            --msgbox "Can't use '$ZRAM_SIZE'.\n\nUse e.g. 50%, 2G or 1536M - between 64 MiB and $((ram * 2)) MiB (2x RAM)." 11 "$WT_W" || true
          continue
        fi
        ZRAM_MIB=$mib ZRAM_PCT=$(( mib * 100 / ram ))
        # step 2: show the result -> [OK] / [Back]   (Esc = quit)
        local rc=0
        whiptail --title "$NAME - zram size" --yes-button "OK" --no-button "Back" \
          --yesno "   You entered:  ${ZRAM_SIZE}\n\n   zram size:    ${ZRAM_MIB} MiB\n   share of RAM: ${ZRAM_PCT}% of ${ram} MiB$( ((ZRAM_PCT > 100)) && echo '\n\n   (over 100% only pays off if data compresses well)' || true)\n\n(Esc = quit without changing anything)" \
          15 "$WT_W" || rc=$?
        ((rc == 255)) && quit_clean
        ((rc == 0)) && break
      done
      ui_radio ZRAM_ALGO "zram compression:" "$ZRAM_ALGO" zstd "best ratio (recommended)" lz4 "fastest" lzo-rle "kernel default"
      ui_input SWAPPINESS_ZRAM "vm.swappiness with zram only (zram is cheap: 100-180 is normal)" "$SWAPPINESS_ZRAM" '^([0-9]|[1-9][0-9]|1[0-9][0-9]|200)$'
      local disk; disk=$(swap_disk_list | tr '\n' ' ')
      PLAN+=("swap: zram ${ZRAM_MIB} MiB (${ZRAM_PCT}% of RAM) $ZRAM_ALGO, swappiness=$SWAPPINESS_ZRAM, remove disk swap: ${disk:-none}")
      ;;
    swappiness)
      ui_input SWAPPINESS_DISK "vm.swappiness with disk swap (lower = swap less; 10 is typical)" "$SWAPPINESS_DISK" '^([0-9]|[1-9][0-9]|100)$'
      PLAN+=("swap: keep disk swap, swappiness=$SWAPPINESS_DISK")
      ;;
    *) die "unknown SWAP_MODE '$SWAP_MODE'" ;;
  esac
}
remove_disk_swap() {
  local name type used avail rm_files=() f new
  avail=$(awk '/^MemAvailable:/ {print $2 * 1024}' /proc/meminfo)
  while read -r name type used; do
    [[ -z $name || $name == /dev/zram* ]] && continue
    if (( used > avail )); then warn "$name holds $used bytes in use, more than free RAM - leaving it on"; continue; fi
    info "swapoff $name"
    run swapoff "$name"
    if [[ $type == file ]]; then rm_files+=("$name"); fi
  done < <(swapon --show=NAME,TYPE,USED --bytes --noheadings --raw 2>/dev/null || true)

  while read -r f; do [[ -f $f ]] && rm_files+=("$f"); done < <(awk '$1 !~ /^#/ && $3 == "swap" {print $1}' /etc/fstab)
  new=$(awk -v n="$NAME" '$1 !~ /^#/ && $3 == "swap" {print "# " n " disabled: " $0; next} {print}' /etc/fstab)
  fstab_ok "$new" || { warn "fstab not changed (verification failed)"; return; }
  printf '%s\n' "$new" | write_file /etc/fstab
  run systemctl daemon-reload
  for f in $(printf '%s\n' "${rm_files[@]}" | sort -u); do
    if ! swapon --show=NAME --noheadings --raw | grep -qx "$f"; then info "removing $f"; run rm -f "$f"; fi
  done
}
do_swap() {
  ((SWAP_DO)) || return 0
  case $SWAP_MODE in
    zram)
      if [[ -f /etc/systemd/zram-generator.conf ]]; then warn "zram-generator config found - may conflict with zram-tools"; fi
      apt_install zram-tools
      # SIZE is in MiB; PERCENT would override it, so comment PERCENT out
      set_kv /etc/default/zramswap ALGO "$ZRAM_ALGO" SIZE "$ZRAM_MIB" PRIORITY 100
      if grep -Eq '^[[:space:]]*PERCENT=' /etc/default/zramswap 2>/dev/null; then
        sed -E 's/^([[:space:]]*)PERCENT=/#\1PERCENT=/' /etc/default/zramswap | write_file /etc/default/zramswap
      fi
      run systemctl enable zramswap
      run systemctl restart zramswap
      if ((!DRY_RUN)) && ! zram_active; then warn "zram swap didn't come up - disk swap left untouched (systemctl status zramswap)"; return; fi
      remove_disk_swap
      printf 'vm.swappiness=%s\n' "$SWAPPINESS_ZRAM" | write_file "$SWAP_SYSCTL"
      run sysctl -q -w "vm.swappiness=$SWAPPINESS_ZRAM"
      SUMMARY+=("swap: zram ${ZRAM_MIB} MiB (${ZRAM_PCT}%) $ZRAM_ALGO, disk swap removed, swappiness=$SWAPPINESS_ZRAM")
      ;;
    swappiness)
      printf 'vm.swappiness=%s\n' "$SWAPPINESS_DISK" | write_file "$SWAP_SYSCTL"
      run sysctl -q -w "vm.swappiness=$SWAPPINESS_DISK"
      SUMMARY+=("swap: kept disk swap, swappiness=$SWAPPINESS_DISK")
      ;;
  esac
}

# ---------- fstab (root fs options) ----------
ask_fstab() {
  FSTAB_DO=0
  local fs; fs=$(findmnt -no FSTYPE /)
  if [[ -z $(root_fstab_opts) ]]; then PLAN+=("fstab: skipped (no / entry in /etc/fstab)"); return; fi
  FSTAB_DO=1
  if [[ $fs == ext4 ]]; then
    ui_input COMMIT_SEC "ext4 commit interval in seconds (kernel default 5).\n\nHigher = fewer metadata flushes. On a crash, up to this many seconds of\nwrites that apps didn't fsync can be lost (databases fsync, so they're safe)." "$COMMIT_SEC" '^[0-9]+$'
    PLAN+=("fstab: root (/) gets noatime,commit=$COMMIT_SEC, remounted live")
  else
    PLAN+=("fstab: root (/) is $fs - gets noatime only, remounted live")
  fi
}
do_fstab() {
  ((FSTAB_DO)) || return 0
  local fs e4=0 new
  fs=$(findmnt -no FSTYPE /); [[ $fs == ext4 ]] && e4=1
  new=$(awk -v c="$COMMIT_SEC" -v e4="$e4" '
    $1 !~ /^#/ && $2 == "/" {
      n = split($4, o, ","); out = ""
      for (i = 1; i <= n; i++) {
        if (o[i] ~ /^(relatime|noatime|strictatime|atime|commit=.*)$/) continue
        out = out (out == "" ? "" : ",") o[i]
      }
      out = out (out == "" ? "" : ",") "noatime"
      if (e4) out = out ",commit=" c
      $4 = out
    }
    { print }' /etc/fstab)
  fstab_ok "$new" || { warn "fstab not changed (verification failed)"; return; }
  printf '%s\n' "$new" | write_file /etc/fstab
  run systemctl daemon-reload
  if ! run mount -o remount /; then
    restore_file /etc/fstab; run systemctl daemon-reload
    warn "remount failed - fstab restored"; return
  fi
  ((DRY_RUN)) || ok "root mounted with: $(findmnt -no OPTIONS /)"
  SUMMARY+=("root fs: noatime$( ((e4)) && echo ",commit=$COMMIT_SEC" || true)")
}

# ---------- trim ----------
ask_trim() { PLAN+=("trim: enable fstrim.timer and test TRIM on /"); }
do_trim() {
  run systemctl enable --now fstrim.timer
  ((DRY_RUN)) && return 0
  local out
  if out=$(fstrim -v / 2>&1); then
    ok "TRIM works - $out"
    SUMMARY+=("TRIM: fstrim.timer on, discard works")
  else
    warn "TRIM failed: $out"
    ui_msg "TRIM isn't reaching the SSD. On the Proxmox host:

  VM -> Hardware -> Hard Disk -> Edit -> tick 'Discard' (+ 'SSD emulation')
  or:  qm set <vmid> --scsi0 <storage>:<disk>,discard=on,ssd=1

Then fully STOP and START the VM (a reboot inside the guest is not
enough), and run this item again."
    SUMMARY+=("TRIM: timer on, but discard NOT enabled on the virtual disk")
  fi
}

# ---------- tmp ----------
ask_tmp() {
  ui_input TMP_SIZE "Size cap for /tmp (e.g. 512M, 1G).\nRAM is only used as files are written. RAM: $(free -h | awk '/^Mem:/ {print $2}')" "$TMP_SIZE" '^[0-9]+[MG]$'
  PLAN+=("tmp: /tmp as tmpfs, size=$TMP_SIZE$([[ $(findmnt -no FSTYPE /tmp 2>/dev/null) == tmpfs ]] && echo ' (resize live)' || echo ' (reboot)')")
}
do_tmp() {
  if [[ $(systemctl is-enabled tmp.mount 2>/dev/null || true) == masked ]]; then run systemctl unmask tmp.mount; fi
  local new
  new=$(awk '!($1 !~ /^#/ && $2 == "/tmp")' /etc/fstab
        echo "tmpfs  /tmp  tmpfs  defaults,noatime,nosuid,nodev,mode=1777,size=$TMP_SIZE  0  0")
  fstab_ok "$new" || { warn "fstab not changed (verification failed)"; return; }
  printf '%s\n' "$new" | write_file /etc/fstab
  run systemctl daemon-reload
  if [[ $(findmnt -no FSTYPE /tmp 2>/dev/null) == tmpfs ]]; then
    run mount -o "remount,size=$TMP_SIZE" /tmp
  else
    REBOOT_REASONS+=("/tmp switches to tmpfs on next boot")
  fi
  if [[ -d /var/www/nextcloud || -d /var/www/html/nextcloud ]]; then
    warn "Nextcloud found: large uploads may pass through /tmp - point 'tempdirectory'/upload_tmp_dir to disk if needed"
  fi
  SUMMARY+=("/tmp: tmpfs size=$TMP_SIZE")
}

# ================= main =================
load_conf() {
  [[ -f $CONF ]] || return 0
  # shellcheck disable=SC1090
  source "$CONF"
}

save_conf() {
  ((DRY_RUN)) && return 0
  local v
  {
    echo "# $NAME answers - saved $(date '+%F %T') on $(hostname)"
    for v in "${CONF_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done
  } >"$CONF"
  chmod 600 "$CONF"
}

check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ ${ID:-} != ubuntu || ! ${VERSION_ID:-} =~ ^(24|26)\.04$ ]]; then
    ((FORCE)) || die "made for Ubuntu 24.04/26.04 LTS, found ${PRETTY_NAME:-unknown}. Use --force to run anyway."
    warn "running on ${PRETTY_NAME:-unknown} (--force)"
  fi
}

confirm_plan() {
  local text p
  text="$( ((DRY_RUN)) && echo 'DRY RUN - nothing will actually change.' || true)
$(hostname) - this is what will happen:

"
  for p in "${PLAN[@]}"; do text+=" * $p"$'\n'; done
  text+=$'\nChanged files are backed up to '"$BACKUP_DIR"$'\n'
  if ((ASSUME_YES)); then printf '%s\n' "$text"; return 0; fi
  whiptail --title "$NAME - review plan" --scrolltext --yes-button "Apply" --no-button "Quit" \
    --yesno "$text" 24 "$WT_W" || quit_clean
}

main() {
  while (($#)); do
    case $1 in
      --status)  STATUS_ONLY=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      --apply)   APPLY_LIST=${2:?--apply needs a list}; shift ;;
      --config)  CONF=${2:?--config needs a path}; shift ;;
      --force)   FORCE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done

  [[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
  check_os
  exec 9>"/run/$NAME.lock"
  flock -n 9 || die "another $NAME is running"
  load_conf

  if ((STATUS_ONLY)); then print_status; exit 0; fi

  local k
  if ((ASSUME_YES)); then
    [[ -n $APPLY_LIST ]] || die "--yes needs --apply item,item,...  (items: ${ITEMS[*]})"
    SELECTED=$(tr ',' '\n' <<<"$APPLY_LIST")
    for k in $SELECTED; do [[ -n ${DESC[$k]:-} ]] || die "unknown item '$k' (items: ${ITEMS[*]})"; done
  else
    if ! has_cmd whiptail; then apt-get install -y -qq whiptail >/dev/null; fi
    select_items
  fi
  [[ -n ${SELECTED//[[:space:]]/} ]] || quit_clean

  # 1) questions only - nothing changes here
  for k in "${ITEMS[@]}"; do
    if grep -qx "$k" <<<"$SELECTED"; then "ask_$k"; fi
  done
  ((${#PLAN[@]})) || quit_clean
  confirm_plan

  # 2) apply
  PHASE=apply
  ((DRY_RUN)) && warn "DRY RUN - nothing will be changed"
  for k in "${ITEMS[@]}"; do
    if grep -qx "$k" <<<"$SELECTED"; then
      echo; info "${B}-- $k: ${DESC[$k]}${N}"
      "do_$k"
    fi
  done

  save_conf
  echo; info "Summary$( ((DRY_RUN)) && echo ' (dry run - what would be done)' || true)"
  for k in "${SUMMARY[@]}"; do ok "$k"; done
  ((DRY_RUN)) || print_status
  if [[ -d $BACKUP_DIR ]]; then info "backups of changed files: $BACKUP_DIR"; fi
  ((DRY_RUN)) || info "answers saved to $CONF (reused as defaults next time)"

  if ((${#REBOOT_REASONS[@]})) && ((!DRY_RUN)); then
    warn "reboot needed:"; printf '      - %s\n' "${REBOOT_REASONS[@]}"
    if ((!ASSUME_YES)) && ui_yesno "Reboot needed:\n\n$(printf ' - %s\n' "${REBOOT_REASONS[@]}")\n\nReboot now?" no; then
      systemctl reboot
    fi
  fi
}

main "$@"
