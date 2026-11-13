#!/usr/bin/env bash
# =============================================================================
# system_health_check.sh — concise Linux system health report
# =============================================================================
# INSTALLATION
#   Debian/Ubuntu: sudo apt install -y procps util-linux coreutils
#   Fedora/RHEL:   sudo dnf install -y procps-ng util-linux coreutils
#   Arch:          sudo pacman -S --needed procps-ng util-linux coreutils
#   chmod +x system_health_check.sh
#
# USAGE
#   ./system_health_check.sh
#   ./system_health_check.sh --watch 5
#   ./system_health_check.sh --json
#   ./system_health_check.sh --help
#
# OPTIONS
#   --watch SECONDS  Refresh the dashboard at the given interval
#   --json           Print a machine-readable JSON snapshot (requires Python 3)
#   --help           Show this help
#
# Read-only diagnostic tool. It does not change system configuration.
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

WATCH=0
JSON=0
usage() { sed -n '1,31p' "$0" | sed 's/^#\?//' | sed 's/^ //'; }
die() { printf 'Error: %s\n' "$*" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --watch) (($# >= 2)) || die "--watch requires seconds"; [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "watch interval must be a positive integer"; WATCH=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

for cmd in uptime free df awk hostname date; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

collect() {
  local host kernel uptime_text load cpus mem_total mem_used mem_available mem_pct
  host=$(hostname 2>/dev/null || printf unknown)
  kernel=$(uname -r 2>/dev/null || printf unknown)
  uptime_text=$(uptime -p 2>/dev/null || uptime 2>/dev/null || printf unknown)
  load=$(awk '{print $1 " " $2 " " $3}' /proc/loadavg 2>/dev/null || printf unknown)
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
  read -r mem_total mem_used mem_available < <(free -b | awk '/^Mem:/ {print $2, $3, $7}')
  mem_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{if(t>0)printf "%.1f",u*100/t;else print "0"}')
  if (( JSON )); then
    command -v python3 >/dev/null 2>&1 || die "python3 is required for --json"
    export HOST="$host" KERNEL="$kernel" UPTIME_TEXT="$uptime_text" LOAD="$load"
    export CPUS="$cpus" MEM_TOTAL="$mem_total" MEM_USED="$mem_used" MEM_AVAILABLE="$mem_available" MEM_PCT="$mem_pct"
    python3 - <<'PY'
import json, os, subprocess
def run(args):
    try: return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception: return "unavailable"
filesystems=[]
try:
    lines=run(["df","-PT","-x","tmpfs","-x","devtmpfs","-x","squashfs"]).splitlines()[1:]
    for line in lines:
        p=line.split(None,6)
        if len(p)==7:
            filesystems.append({"device":p[0],"type":p[1],"size":p[2],"used":p[3],"available":p[4],"use_percent":p[5],"mount":p[6]})
except Exception: pass
print(json.dumps({
 "hostname":os.environ["HOST"],"kernel":os.environ["KERNEL"],"uptime":os.environ["UPTIME_TEXT"],
 "load_average":os.environ["LOAD"],"online_cpus":int(os.environ["CPUS"]),
 "memory":{"total_bytes":int(os.environ["MEM_TOTAL"]),"used_bytes":int(os.environ["MEM_USED"]),
 "available_bytes":int(os.environ["MEM_AVAILABLE"]),"used_percent":float(os.environ["MEM_PCT"])},
 "filesystems":filesystems
},indent=2))
PY
    return
  fi

  printf '\033[1;36mLINUX SYSTEM HEALTH CHECK\033[0m\n'
  printf 'Generated: %s\n' "$(date '+%F %T %Z')"
  printf '%-22s %s\n' "Hostname:" "$host" "Kernel:" "$kernel" "Uptime:" "$uptime_text"
  printf '%-22s %s\n' "Load average:" "$load" "Online CPU cores:" "$cpus"
  printf '\n\033[1;33mMEMORY\033[0m\n'
  free -h
  printf 'Memory used (including cache): %s%%\n' "$mem_pct"
  printf '\n\033[1;33mFILESYSTEMS\033[0m\n'
  df -hT -x tmpfs -x devtmpfs -x squashfs
  printf '\n\033[1;33mSYSTEM STATUS\033[0m\n'
  if command -v systemctl >/dev/null 2>&1; then
    printf 'Failed systemd units: '
    systemctl --failed --no-legend --plain 2>/dev/null | awk 'END{print NR+0}'
  else
    printf 'systemd status: unavailable\n'
  fi
  if [[ -r /proc/pressure/cpu ]]; then
    printf 'CPU pressure: '; awk '/^some /{print $0}' /proc/pressure/cpu
    printf 'Memory pressure: '; awk '/^some /{print $0}' /proc/pressure/memory
    printf 'I/O pressure: '; awk '/^some /{print $0}' /proc/pressure/io
  fi
  printf '\n'
}

if (( JSON )); then
  collect
elif (( WATCH > 0 )); then
  trap 'printf "\nStopped.\n"; exit 0' INT TERM
  while true; do
    if [[ -t 1 ]]; then clear; fi
    collect
    sleep "$WATCH"
  done
else
  collect
fi
