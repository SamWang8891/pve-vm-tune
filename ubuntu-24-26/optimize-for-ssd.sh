#!/usr/bin/env bash
# optimize-for-ssd.sh - reduce SSD wear from Ubuntu 24.04 / 26.04 LTS guests (e.g. Proxmox VMs)
#
#   sudo ./optimize-for-ssd.sh                 interactive selector (whiptail)
#   sudo ./optimize-for-ssd.sh --status        show what is applied, change nothing
#   sudo ./optimize-for-ssd.sh --dry-run       walk through everything, show diffs, change nothing
#   sudo ./optimize-for-ssd.sh --yes --apply rsyslog,journal,ship --config ./ssd-tune.conf
#                                      non-interactive (answers from the config file)
#
# Items: rsyslog journal ship docker weblog swap fstab trim tmp
# Every changed file is backed up to /var/backups/ssd-tune/<timestamp>/ first.

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

VERSION=1.0
CONF=/etc/ssd-tune.conf
BACKUP_DIR=/var/backups/ssd-tune/$(date +%Y%m%d-%H%M%S)
DRY_RUN=0 ASSUME_YES=0 STATUS_ONLY=0 FORCE=0 APPLY_LIST="" APT_UPDATED=0
REBOOT_REASONS=() SUMMARY=()
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
DOCKER_RECREATE=no
SWAP_MODE=zram
ZRAM_PERCENT=50
ZRAM_ALGO=zstd
SWAPPINESS_ZRAM=100
SWAPPINESS_DISK=10
COMMIT_SEC=60
TMP_SIZE=1G
CONF_VARS=(JOURNAL_MODE L2R_SIZE_MB L2R_SYNC_HOURS VOLATILE_MAX DISK_MAX VLOGS_URL VLOGS_CA
           DOCKER_DRIVER DOCKER_RECREATE SWAP_MODE ZRAM_PERCENT ZRAM_ALGO SWAPPINESS_ZRAM
           SWAPPINESS_DISK COMMIT_SEC TMP_SIZE)

# ---------- paths ----------
JD=/etc/systemd/journald.conf.d/50-ssd-tune.conf
UPLOAD_DROPIN=/etc/systemd/journal-upload.conf.d/50-ssd-tune.conf
L2R_TIMER_DROPIN=/etc/systemd/system/log2ram-daily.timer.d/50-ssd-tune.conf
DOCKER_JSON=/etc/docker/daemon.json
SWAP_SYSCTL=/etc/sysctl.d/99-ssd-tune-swap.conf
NGINX_MAP=/etc/nginx/conf.d/ssd-tune-logs.conf
APACHE_SNIP=/etc/apache2/conf-available/ssd-tune-logs.conf

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
die()  { err "$*"; exit 1; }
trap 'err "failed at line $LINENO: $BASH_COMMAND"' ERR

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

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

# ---------- UI (whiptail, or defaults with --yes) ----------
WT_W=$(( $(tput cols 2>/dev/null || echo 80) - 6 )); ((WT_W > 100)) && WT_W=100; ((WT_W < 60)) && WT_W=60

ui_input() {   # ui_input VAR "prompt" default [regex]
  local var=$1 prompt=$2 def=$3 re=${4:-} val
  if ((ASSUME_YES)); then
    val=$def
    [[ -z $re || $val =~ $re ]] || die "invalid or missing value for $var: '$val' (set it in $CONF)"
  else
    while :; do
      val=$(whiptail --title "optimize-for-ssd" --inputbox "$prompt" 14 "$WT_W" "$def" 3>&1 1>&2 2>&3) || die "Cancelled."
      [[ -z $re || $val =~ $re ]] && break
      whiptail --title "optimize-for-ssd" --msgbox "Invalid value: '$val'" 8 60
    done
  fi
  printf -v "$var" '%s' "$val"
}

ui_yesno() {   # ui_yesno "prompt" yes|no  -> exit status
  local prompt=$1 def=${2:-no}
  if ((ASSUME_YES)); then [[ $def == yes ]]; return; fi
  local extra=(); [[ $def == no ]] && extra=(--defaultno)
  whiptail --title "optimize-for-ssd" "${extra[@]}" --yesno "$prompt" 16 "$WT_W"
}

ui_radio() {   # ui_radio VAR "prompt" current tag desc [tag desc...]
  local var=$1 prompt=$2 cur=$3 args=() v; shift 3
  if ((ASSUME_YES)); then printf -v "$var" '%s' "$cur"; return; fi
  while (($#)); do
    if [[ $1 == "$cur" ]]; then args+=("$1" "$2" ON); else args+=("$1" "$2" OFF); fi
    shift 2
  done
  v=$(whiptail --title "optimize-for-ssd" --radiolist "$prompt" 16 "$WT_W" 5 "${args[@]}" 3>&1 1>&2 2>&3) || die "Cancelled."
  printf -v "$var" '%s' "$v"
}

ui_msg() {
  if ((ASSUME_YES)); then printf '%s\n' "$1" | sed 's/^/    /'; else whiptail --title "optimize-for-ssd" --msgbox "$1" 18 "$WT_W"; fi
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
  if has_cmd nginx; then any=1; grep -qs ssd_tune_loggable /etc/nginx/nginx.conf || done=0; fi
  if has_cmd apache2ctl; then any=1; [[ -e /etc/apache2/conf-enabled/ssd-tune-logs.conf ]] || done=0; fi
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
  SELECTED=$(whiptail --title "optimize-for-ssd $VERSION - $(hostname)" --separate-output --checklist \
    "SPACE toggles, ENTER confirms. [DONE] = already applied; tick it to re-apply.\nItems that don't apply to this VM are hidden." \
    22 "$WT_W" 10 "${args[@]}" 3>&1 1>&2 2>&3) || die "Cancelled."
}

# ================= apply functions =================

apply_rsyslog() {
  if ! pkg_installed rsyslog; then ok "rsyslog already removed"; return; fi
  local extra
  extra=$(apt-get -s purge rsyslog 2>/dev/null | awk '/^(Purg|Remv) / {print $2}' | grep -vx rsyslog || true)
  if [[ -n $extra ]]; then
    if ! ui_yesno "Purging rsyslog would also remove:\n\n$extra\n\nContinue?" no; then warn "rsyslog: skipped"; return; fi
  fi
  run apt-get purge -y -qq rsyslog
  if ui_yesno "Delete rsyslog's old files (/var/log/syslog*, kern.log*, auth.log*, mail.*)?\n\nThe same logs are still in the journal (journalctl)." yes; then
    run bash -c 'rm -f /var/log/syslog* /var/log/kern.log* /var/log/auth.log* /var/log/mail.log* /var/log/mail.err*'
  fi
  SUMMARY+=("rsyslog purged")
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

journal_log2ram() {
  ui_input L2R_SIZE_MB "RAM size for /var/log, in MB.\n\nCurrent /var/log usage: $(du -sh /var/log 2>/dev/null | cut -f1)" "$L2R_SIZE_MB" '^[0-9]+$'
  ui_input L2R_SYNC_HOURS "Sync /var/log to disk every N hours (1-24).\nA crash loses logs since the last sync (shipping to VictoriaLogs covers that)." "$L2R_SYNC_HOURS" '^([1-9]|1[0-9]|2[0-4])$'
  local jmax=$(( L2R_SIZE_MB * 40 / 100 ))M used
  used=$(du -sm /var/log | cut -f1)
  if (( used > L2R_SIZE_MB * 70 / 100 )); then
    if ui_yesno "/var/log uses ${used}MB - over 70% of ${L2R_SIZE_MB}MB.\n\nVacuum the journal to $jmax and delete rotated logs (*.gz, *.1 ...)?" yes; then
      run journalctl --vacuum-size="$jmax"
      run find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' \) -delete
    fi
    used=$(du -sm /var/log | cut -f1)
    (( DRY_RUN || used <= L2R_SIZE_MB * 85 / 100 )) || die "/var/log (${used}MB) won't fit in ${L2R_SIZE_MB}MB - pick a bigger size or clean up first"
  fi
  printf '[Journal]\nStorage=persistent\nSystemMaxUse=%s\nCompress=yes\n' "$jmax" | write_file "$JD"
  run systemctl restart systemd-journald
  install_log2ram
  set_kv /etc/log2ram.conf SIZE "${L2R_SIZE_MB}M" USE_RSYNC true MAIL false
  printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 00/%s:00:00\n' "$L2R_SYNC_HOURS" | write_file "$L2R_TIMER_DROPIN"
  run systemctl daemon-reload
  run systemctl enable log2ram log2ram-daily.timer
  REBOOT_REASONS+=("log2ram mounts /var/log in RAM at boot")
  SUMMARY+=("journal: log2ram ${L2R_SIZE_MB}MB, sync every ${L2R_SYNC_HOURS}h, journal cap $jmax")
}

journal_volatile() {
  ui_input VOLATILE_MAX "Max RAM for the journal (e.g. 64M)" "$VOLATILE_MAX" '^[0-9]+[MG]$'
  remove_log2ram
  printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=%s\n' "$VOLATILE_MAX" | write_file "$JD"
  run systemctl restart systemd-journald
  if [[ -d /var/log/journal ]] && ui_yesno "Delete the old on-disk journal in /var/log/journal ($(du -sh /var/log/journal | cut -f1))?" yes; then
    run rm -rf /var/log/journal
  fi
  if [[ ! -f $UPLOAD_DROPIN ]]; then warn "RAM-only journal: logs vanish on reboot unless you also select 'ship'"; fi
  SUMMARY+=("journal: RAM only, max $VOLATILE_MAX")
}

journal_disk() {
  ui_input DISK_MAX "Max disk space for the journal (e.g. 200M)" "$DISK_MAX" '^[0-9]+[MG]$'
  remove_log2ram
  printf '[Journal]\nStorage=persistent\nSystemMaxUse=%s\nCompress=yes\n' "$DISK_MAX" | write_file "$JD"
  run mkdir -p /var/log/journal
  run systemd-tmpfiles --create --prefix /var/log/journal
  run systemctl restart systemd-journald
  run journalctl --flush
  run journalctl --vacuum-size="$DISK_MAX"
  SUMMARY+=("journal: on disk, max $DISK_MAX")
}

apply_journal() {
  local cur; cur=$(journal_mode_now)
  ui_radio JOURNAL_MODE "Where should the systemd journal live? (current: $cur)" "$JOURNAL_MODE" \
    log2ram  "RAM, synced to disk every N hours + at shutdown" \
    volatile "RAM only (pair with shipping to VictoriaLogs)" \
    disk     "On disk, size-capped"
  case $JOURNAL_MODE in
    log2ram)  journal_log2ram ;;
    volatile) journal_volatile ;;
    disk)     journal_disk ;;
    *) die "unknown JOURNAL_MODE '$JOURNAL_MODE'" ;;
  esac
}

apply_ship() {
  local def=$VLOGS_URL base tag
  ((ASSUME_YES)) || def=${def:-http://192.168.1.6:9428/insert/journald}
  ui_input VLOGS_URL "VictoriaLogs journald endpoint:" "$def" '^https?://[^/]+/.+$'
  ui_input VLOGS_CA "CA certificate file for HTTPS (e.g. your step-ca root).\nLeave empty for plain http or a publicly trusted cert." "$VLOGS_CA" ''
  if [[ -n $VLOGS_CA && ! -f $VLOGS_CA ]]; then die "CA file $VLOGS_CA not found"; fi
  base=${VLOGS_URL%%/insert/*}
  local curl_ca=(); [[ -n $VLOGS_CA ]] && curl_ca=(--cacert "$VLOGS_CA")
  if ! curl -fsS --max-time 5 "${curl_ca[@]}" "$base/health" >/dev/null 2>&1; then
    if ! ui_yesno "Can't reach $base/health from this VM.\n(firewall? IPsec rule? wrong IP?)\n\nConfigure anyway? journal-upload will retry and catch up later." no; then
      warn "ship: skipped"; return
    fi
  fi
  apt_install systemd-journal-remote
  {
    echo "[Upload]"
    echo "URL=$VLOGS_URL"
    if [[ -n $VLOGS_CA ]]; then echo "TrustedCertificateFile=$VLOGS_CA"; fi
  } | write_file "$UPLOAD_DROPIN"
  run systemctl enable systemd-journal-upload
  run systemctl restart systemd-journal-upload
  if ((!DRY_RUN)); then
    tag="ssd-tune-test-$(hostname)-$RANDOM"
    logger -t ssd-tune "$tag"
    info "sent test line '$tag', checking it arrived..."
    sleep 6
    if curl -fsS --max-time 10 "${curl_ca[@]}" "$base/select/logsql/query" --data-urlencode "query=_time:5m \"$tag\"" 2>/dev/null | grep -q "$tag"; then
      ok "test log line visible in VictoriaLogs"
    else
      warn "test line not found yet - the first upload sends the whole existing journal and can take a while. Check: journalctl -u systemd-journal-upload"
    fi
  fi
  SUMMARY+=("shipping journal -> $VLOGS_URL")
}

apply_docker() {
  if ! docker_present; then warn "docker not installed - skipping"; return; fi
  ui_radio DOCKER_DRIVER "Default log driver for new containers:" "$DOCKER_DRIVER" \
    journald "into the journal (log2ram'd / shipped with everything)" \
    local    "compressed local files, 10M x 3 per container"
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
) || die "could not parse $DOCKER_JSON"
  tmp=$(mktemp); printf '%s\n' "$new" >"$tmp"
  if dockerd --help 2>&1 | grep -q -- '--validate'; then
    dockerd --validate --config-file "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "new daemon.json failed 'dockerd --validate'"; }
  fi
  rm -f "$tmp"
  printf '%s\n' "$new" | write_file "$DOCKER_JSON"
  if ui_yesno "Restart Docker now so the new default applies?\n(containers with a restart policy come back automatically)" yes; then
    run systemctl restart docker
  else
    REBOOT_REASONS+=("docker restart needed for the new log driver")
  fi

  if ui_yesno "Existing containers keep their old log driver until recreated.\n\nRecreate all docker compose projects now? (brief downtime)" "$DOCKER_RECREATE"; then
    DOCKER_RECREATE=yes
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
    DOCKER_RECREATE=no
    warn "remember: docker compose up -d --force-recreate in each project"
  fi
  local loose
  loose=$(docker ps -a --format '{{.Names}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null | awk -F'|' '$2=="" {print $1}' || true)
  if [[ -n $loose ]]; then warn "containers not managed by compose (recreate manually): $(echo "$loose" | tr '\n' ' ')"; fi
  SUMMARY+=("docker log-driver: $DOCKER_DRIVER")
}

weblog_nginx() {
  local conf=/etc/nginx/nginx.conf
  cat <<'EOF' | write_file "$NGINX_MAP"
# ssd-tune: don't write access-log lines for static assets
map $request_uri $ssd_tune_loggable {
    ~*\.(css|js|mjs|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|map)(\?.*)?$ 0;
    default 1;
}
EOF
  if ! grep -q ssd_tune_loggable "$conf"; then
    if grep -Eq '^\s*access_log\s+/var/log/nginx/access\.log\s*;' "$conf"; then
      sed -E 's#^(\s*)access_log\s+/var/log/nginx/access\.log\s*;#\1access_log /var/log/nginx/access.log combined buffer=64k flush=5m if=$ssd_tune_loggable;#' "$conf" \
        | write_file "$conf"
    else
      warn "nginx.conf has a non-default access_log line - not changed. Add: buffer=64k flush=5m if=\$ssd_tune_loggable"
    fi
  fi
  if ((!DRY_RUN)); then
    if nginx -t >/dev/null 2>&1; then run systemctl reload nginx; ok "nginx reloaded"
    else err "nginx -t failed - rolling back"; restore_file "$conf"; restore_file "$NGINX_MAP"; return; fi
  fi
  local own
  own=$(grep -ls '^\s*access_log' /etc/nginx/sites-enabled/* 2>/dev/null || true)
  if [[ -n $own ]]; then warn "these sites set their own access_log (not buffered - add 'buffer=64k flush=5m if=\$ssd_tune_loggable'):"; echo "$own" | sed 's/^/      /'; fi
  SUMMARY+=("nginx: buffered access log, static assets skipped")
}

weblog_apache() {
  cat <<'EOF' | write_file "$APACHE_SNIP"
# ssd-tune: buffer access-log writes, skip static assets
BufferedLogs On
SetEnvIfNoCase Request_URI "\.(css|js|mjs|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|map)$" dontlog
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
  run a2enconf -q ssd-tune-logs
  if ((!DRY_RUN)); then
    if apache2ctl configtest >/dev/null 2>&1; then run systemctl reload apache2; ok "apache reloaded"
    else
      err "apache2ctl configtest failed - rolling back"
      a2disconf -q ssd-tune-logs || true
      restore_file "$APACHE_SNIP"
      for f in "${changed[@]}"; do restore_file "$f"; done
      return
    fi
  fi
  SUMMARY+=("apache: BufferedLogs on, static assets skipped (${#changed[@]} files edited)")
}

apply_weblog() {
  local did=0
  if has_cmd nginx; then weblog_nginx; did=1; fi
  if has_cmd apache2ctl; then weblog_apache; did=1; fi
  if ((!did)); then warn "no nginx/apache found - skipping"; fi
}

remove_disk_swap() {
  local name type used avail rm_files=() f
  avail=$(awk '/^MemAvailable:/ {print $2 * 1024}' /proc/meminfo)
  while read -r name type used; do
    [[ -z $name || $name == /dev/zram* ]] && continue
    if (( used > avail )); then warn "$name holds $used bytes in use, more than free RAM - leaving it on"; continue; fi
    info "swapoff $name"
    run swapoff "$name"
    if [[ $type == file ]]; then rm_files+=("$name"); fi
  done < <(swapon --show=NAME,TYPE,USED --bytes --noheadings --raw 2>/dev/null || true)

  while read -r f; do [[ -f $f ]] && rm_files+=("$f"); done < <(awk '$1 !~ /^#/ && $3 == "swap" {print $1}' /etc/fstab)
  local new
  new=$(awk '$1 !~ /^#/ && $3 == "swap" {print "# ssd-tune disabled: " $0; next} {print}' /etc/fstab)
  fstab_ok "$new" || die "not touching fstab"
  printf '%s\n' "$new" | write_file /etc/fstab
  run systemctl daemon-reload
  for f in $(printf '%s\n' "${rm_files[@]}" | sort -u); do
    if ! swapon --show=NAME --noheadings --raw | grep -qx "$f"; then info "removing $f"; run rm -f "$f"; fi
  done
}

swap_zram() {
  if ! modprobe -n zram >/dev/null 2>&1; then
    warn "kernel $(uname -r) has no zram module (try: apt install linux-modules-extra-$(uname -r), or the generic kernel)"
    if ui_yesno "zram isn't available on this kernel.\n\nJust lower swappiness instead (keep disk swap)?" yes; then SWAP_MODE=swappiness; swap_swappiness; fi
    return
  fi
  if [[ -f /etc/systemd/zram-generator.conf ]]; then warn "zram-generator config found - may conflict with zram-tools"; fi
  ui_input ZRAM_PERCENT "zram swap size as % of RAM (RAM: $(free -h | awk '/^Mem:/ {print $2}'))" "$ZRAM_PERCENT" '^([1-9][0-9]?|100)$'
  ui_radio ZRAM_ALGO "zram compression:" "$ZRAM_ALGO" zstd "best ratio (recommended)" lz4 "fastest" lzo-rle "kernel default"
  ui_input SWAPPINESS_ZRAM "vm.swappiness with zram only (zram is cheap: 100-180 is normal)" "$SWAPPINESS_ZRAM" '^([0-9]|[1-9][0-9]|1[0-9][0-9]|200)$'
  apt_install zram-tools
  set_kv /etc/default/zramswap ALGO "$ZRAM_ALGO" PERCENT "$ZRAM_PERCENT" PRIORITY 100
  run systemctl enable zramswap
  run systemctl restart zramswap
  if ((!DRY_RUN)) && ! zram_active; then die "zram swap didn't come up - disk swap left untouched (check: systemctl status zramswap)"; fi
  remove_disk_swap
  printf 'vm.swappiness=%s\n' "$SWAPPINESS_ZRAM" | write_file "$SWAP_SYSCTL"
  run sysctl -q -w "vm.swappiness=$SWAPPINESS_ZRAM"
  SUMMARY+=("swap: zram ${ZRAM_PERCENT}% $ZRAM_ALGO, disk swap removed, swappiness=$SWAPPINESS_ZRAM")
}

swap_swappiness() {
  ui_input SWAPPINESS_DISK "vm.swappiness with disk swap (lower = swap less; 10 is typical)" "$SWAPPINESS_DISK" '^([0-9]|[1-9][0-9]|100)$'
  printf 'vm.swappiness=%s\n' "$SWAPPINESS_DISK" | write_file "$SWAP_SYSCTL"
  run sysctl -q -w "vm.swappiness=$SWAPPINESS_DISK"
  SUMMARY+=("swap: kept disk swap, swappiness=$SWAPPINESS_DISK")
}

apply_swap() {
  ui_radio SWAP_MODE "Swap strategy (current: $(swap_mode_now)):" "$SWAP_MODE" \
    zram       "compressed swap in RAM; disk swap file removed" \
    swappiness "keep disk swap, just swap less"
  case $SWAP_MODE in
    zram)       swap_zram ;;
    swappiness) swap_swappiness ;;
    *) die "unknown SWAP_MODE '$SWAP_MODE'" ;;
  esac
}

apply_fstab() {
  local fs e4=0 new
  fs=$(findmnt -no FSTYPE /)
  [[ -n $(root_fstab_opts) ]] || { warn "no / entry in /etc/fstab - skipping"; return; }
  if [[ $fs == ext4 ]]; then
    e4=1
    ui_input COMMIT_SEC "ext4 commit interval in seconds (kernel default 5).\n\nHigher = fewer metadata flushes. On a crash, up to this many seconds of\nwrites that apps didn't fsync can be lost (databases fsync, so they're safe)." "$COMMIT_SEC" '^[0-9]+$'
  else
    warn "root is $fs, not ext4 - only adding noatime"
  fi
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
  fstab_ok "$new" || die "not touching fstab"
  printf '%s\n' "$new" | write_file /etc/fstab
  run systemctl daemon-reload
  if ! run mount -o remount /; then restore_file /etc/fstab; run systemctl daemon-reload; die "remount failed - fstab restored"; fi
  ((DRY_RUN)) || ok "root mounted with: $(findmnt -no OPTIONS /)"
  SUMMARY+=("root fs: noatime$( ((e4)) && echo ",commit=$COMMIT_SEC")")
}

apply_trim() {
  run systemctl enable --now fstrim.timer
  ((DRY_RUN)) && return
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

apply_tmp() {
  ui_input TMP_SIZE "Size cap for /tmp (e.g. 512M, 1G).\nRAM is only used as files are written. RAM: $(free -h | awk '/^Mem:/ {print $2}')" "$TMP_SIZE" '^[0-9]+[MG]$'
  if [[ $(systemctl is-enabled tmp.mount 2>/dev/null || true) == masked ]]; then run systemctl unmask tmp.mount; fi
  local new
  new=$(awk '!($1 !~ /^#/ && $2 == "/tmp")' /etc/fstab
        echo "tmpfs  /tmp  tmpfs  defaults,noatime,nosuid,nodev,mode=1777,size=$TMP_SIZE  0  0")
  fstab_ok "$new" || die "not touching fstab"
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
    echo "# ssd-tune answers - saved $(date '+%F %T') on $(hostname)"
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
  exec 9>/run/ssd-tune.lock
  flock -n 9 || die "another optimize-for-ssd is running"
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
  [[ -n ${SELECTED//[[:space:]]/} ]] || { info "nothing selected"; exit 0; }
  ((DRY_RUN)) && warn "DRY RUN - nothing will be changed"

  for k in "${ITEMS[@]}"; do
    if grep -qx "$k" <<<"$SELECTED"; then
      echo; info "${B}-- $k: ${DESC[$k]}${N}"
      "apply_$k"
    fi
  done

  save_conf
  echo; info "Summary$( ((DRY_RUN)) && echo ' (dry run - what would be done)')"
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
