#!/usr/bin/env bash
# =============================================================================
# process_monitor.sh - Interactive and snapshot Linux process monitor
# Version: 1.0.0 | Bash 4.3+
#
# INSTALLATION
#   Debian / Ubuntu: sudo apt install procps coreutils gawk
#   Fedora / RHEL:   sudo dnf install procps-ng coreutils gawk
#   Arch Linux:      sudo pacman -S --needed procps-ng coreutils gawk
#   chmod +x process_monitor.sh
#
# USAGE
#   ./process_monitor.sh
#   ./process_monitor.sh --watch --interval 2 --top 15
#   ./process_monitor.sh --sort mem --top 20
#   ./process_monitor.sh --user www-data --sort cpu
#   ./process_monitor.sh --pid 1234
#   ./process_monitor.sh --contains nginx
#   ./process_monitor.sh --watch --count 10 --interval 1
#   ./process_monitor.sh --json --sort rss --top 50
#
# OPTIONS
#   --watch             Refresh continuously (default: one snapshot).
#   --interval SEC      Refresh interval in seconds (default: 2; 1..3600).
#   --count N           Stop after N samples in watch mode (default: 0 = forever).
#   --top N             Maximum displayed/returned processes (default: 20; 1..100).
#   --sort FIELD        Sort by cpu, mem, rss, or pid (default: cpu).
#   --user USER         Include only processes owned by an existing account.
#   --pid PID           Include only the exact process ID.
#   --contains TEXT     Case-insensitive literal substring in the command line.
#   --json              Emit one JSON snapshot (requires Python 3; incompatible with --watch).
#   --no-color          Disable ANSI colors.
#   -h, --help          Show this help and exit.
#
# FEATURES / NOTES
#   - Shows PID, parent PID, user, state, CPU%, memory%, RSS/VSZ, elapsed time,
#     and command line; filters can be combined.
#   - CPU% is the process accounting value reported by ps, not a fresh interval
#     delta. RSS/VSZ are KiB. Process visibility follows the caller's permissions.
#   - Read-only: does not signal, reprioritize, or otherwise modify processes.
#   - Requires Linux procfs and a procps-compatible ps. BusyBox/BSD ps variants
#     may not support the required output format and are detected at runtime.
#   - Python 3 is optional and is needed only for --json output.
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

WATCH=0
INTERVAL=2
COUNT=0
TOP=20
SORT_BY=cpu
USER_FILTER=""
USER_UID=""
PID_FILTER=""
CONTAINS=""
JSON=0
DISABLE_COLOR=0
if [[ -n "${NO_COLOR:-}" ]]; then DISABLE_COLOR=1; fi

usage() {
  sed -n '2,44p' "$0" | sed 's/^# //' | sed 's/^#$//'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

need_value() {
  (($# >= 2)) || die "Option $1 requires a value"
  [[ -n "$2" ]] || die "Option $1 requires a non-empty value"
}

while (($#)); do
  case "$1" in
    --watch) WATCH=1; shift ;;
    --interval) need_value "$@"; INTERVAL=$2; shift 2 ;;
    --count) need_value "$@"; COUNT=$2; shift 2 ;;
    --top) need_value "$@"; TOP=$2; shift 2 ;;
    --sort) need_value "$@"; SORT_BY=$2; shift 2 ;;
    --user) need_value "$@"; USER_FILTER=$2; shift 2 ;;
    --pid) need_value "$@"; PID_FILTER=$2; shift 2 ;;
    --contains) need_value "$@"; CONTAINS=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --no-color) DISABLE_COLOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; (($# == 0)) || die "Positional arguments are not supported" ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ "$INTERVAL" =~ ^[0-9]+$ ]] && (("${#INTERVAL}" <= 4)) && ((10#$INTERVAL >= 1 && 10#$INTERVAL <= 3600)) || die "--interval must be an integer from 1 to 3600"
[[ "$COUNT" =~ ^[0-9]+$ ]] && (("${#COUNT}" <= 6)) && ((10#$COUNT <= 100000)) || die "--count must be an integer from 0 to 100000"
[[ "$TOP" =~ ^[0-9]+$ ]] && (("${#TOP}" <= 3)) && ((10#$TOP >= 1 && 10#$TOP <= 100)) || die "--top must be an integer from 1 to 100"
case "$SORT_BY" in cpu|mem|rss|pid) ;; *) die "--sort must be one of: cpu, mem, rss, pid" ;; esac
[[ -z "$PID_FILTER" || ( "$PID_FILTER" =~ ^[1-9][0-9]{0,9}$ ) ]] || die "--pid must be a positive decimal PID"
(( WATCH == 1 || COUNT == 0 )) || die "--count requires --watch"
(( JSON == 0 || WATCH == 0 )) || die "--json cannot be combined with --watch"

for cmd in ps awk sort mktemp date; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done
[[ -r /proc/stat && -d /proc ]] || die "Linux procfs is unavailable; this script requires /proc"

if [[ -n "$USER_FILTER" ]]; then
  command -v id >/dev/null 2>&1 || die "The id command is required to validate --user"
  USER_UID=$(id -u -- "$USER_FILTER" 2>/dev/null) || die "Unknown user account: $USER_FILTER"
fi

if (( JSON )); then
  command -v python3 >/dev/null 2>&1 || die "python3 is required for --json"
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/process-monitor.XXXXXX") || die "Cannot create temporary directory"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RAW_FILE="$TMP_DIR/ps.raw"
ROWS_FILE="$TMP_DIR/processes.tsv"
SORTED_FILE="$TMP_DIR/sorted.tsv"

collect_processes() {
  local ps_error="$TMP_DIR/ps.err"
  if ! ps -ww -eo pid=,ppid=,uid=,user=,stat=,pcpu=,pmem=,rss=,vsz=,etime=,args= >"$RAW_FILE" 2>"$ps_error"; then
    if [[ -s "$ps_error" ]]; then
      sed 's/^/ps: /' "$ps_error" >&2
    fi
    die "The installed ps does not support the required procps output format"
  fi

  awk -v wanted_uid="$USER_UID" -v wanted_pid="$PID_FILTER" -v needle="$CONTAINS" '
    {
      if (NF < 10) next
      command = (NF >= 11 ? $11 : "")
      for (i = 12; i <= NF; i++) command = command " " $i
      if (wanted_uid != "" && $3 != wanted_uid) next
      if (wanted_pid != "" && $1 != wanted_pid) next
      if (needle != "" && index(tolower(command), tolower(needle)) == 0) next
      gsub(/[\t\r\n]/, " ", command)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",  $1, $2, $4, $5, $6, $7, $8, $9, $10, command
    }
  ' "$RAW_FILE" > "$ROWS_FILE"

  local sort_key
  case "$SORT_BY" in
    cpu) sort_key=5 ;;
    mem) sort_key=6 ;;
    rss) sort_key=7 ;;
    pid) sort_key=1 ;;
  esac
  if [[ "$SORT_BY" == pid ]]; then
    sort -t $'\t' -k"${sort_key},${sort_key}"n "$ROWS_FILE" > "$SORTED_FILE"
  else
    sort -t $'\t' -k"${sort_key},${sort_key}"nr "$ROWS_FILE" > "$SORTED_FILE"
  fi
}

render_json() {
  python3 - "$SORTED_FILE" "$SORT_BY" "$TOP" "$USER_FILTER" "$PID_FILTER" "$CONTAINS" <<'PY'
import datetime
import json
import socket
import sys

path, sort_by, top, user_filter, pid_filter, contains = sys.argv[1:]
processes = []
with open(path, encoding="utf-8", errors="replace") as handle:
    for line in handle:
        fields = line.rstrip("\n").split("\t", 9)
        if len(fields) != 10:
            continue
        pid, ppid, user, state, cpu, mem, rss, vsz, elapsed, command = fields
        try:
            processes.append({
                "pid": int(pid),
                "ppid": int(ppid),
                "user": user,
                "state": state,
                "cpu_percent": float(cpu),
                "memory_percent": float(mem),
                "rss_kib": int(rss),
                "vsz_kib": int(vsz),
                "elapsed": elapsed,
                "command": command,
            })
        except ValueError:
            continue

limit = int(top)
print(json.dumps({
    "hostname": socket.gethostname(),
    "captured_at": datetime.datetime.now().astimezone().isoformat(),
    "sort": sort_by,
    "filters": {
        "user": user_filter or None,
        "pid": int(pid_filter) if pid_filter else None,
        "contains": contains or None,
    },
    "total_matching_processes": len(processes),
    "returned_processes": min(len(processes), limit),
    "processes": processes[:limit],
}, indent=2, ensure_ascii=False))
PY
}

render_table() {
  local sample=$1 total=$2 pid ppid user state cpu mem rss vsz elapsed command color_reset="" color_bold="" color_cyan=""
  if [[ "$DISABLE_COLOR" == 0 && -t 1 && "${TERM:-dumb}" != dumb ]]; then
    color_reset=$'\033[0m'; color_bold=$'\033[1m'; color_cyan=$'\033[36m'
  fi
  if [[ -t 1 && "$WATCH" == 1 ]]; then
    printf '\033[H\033[2J'
  elif (( sample > 1 )); then
    printf '\n%s\n' '------------------------------------------------------------------------'
  fi

  printf '%sLinux Process Monitor%s  |  %s  |  sample %d' "$color_bold" "$color_reset" "$(date '+%F %T %Z')" "$sample"
  (( WATCH == 0 )) || printf '  |  refresh %ss' "$INTERVAL"
  printf '\n'
  printf 'Matching processes: %s | showing: %s | sorted by: %s\n' "$total" "$(( total < TOP ? total : TOP ))" "$SORT_BY"
  [[ -z "$USER_FILTER" ]] || printf 'Filter user: %s\n' "$USER_FILTER"
  [[ -z "$PID_FILTER" ]] || printf 'Filter PID: %s\n' "$PID_FILTER"
  [[ -z "$CONTAINS" ]] || printf 'Command contains: %s\n' "$CONTAINS"
  printf '\n%s%-7s %-7s %-10s %-5s %7s %7s %10s %10s %-10s %s%s\n'  "$color_cyan" PID PPID USER STAT CPU% MEM% RSS_KiB VSZ_KiB ELAPSED COMMAND "$color_reset"

  local shown=0
  while IFS=$'\t' read -r pid ppid user state cpu mem rss vsz elapsed command; do
    ((shown+=1))
    (( shown <= TOP )) || break
    command=${command:0:90}
    printf '%-7s %-7s %-10s %-5s %7s %7s %10s %10s %-10s %s\n'  "$pid" "$ppid" "$user" "$state" "$cpu" "$mem" "$rss" "$vsz" "$elapsed" "$command"
  done < "$SORTED_FILE"

  if (( total == 0 )); then
    printf '\nNo processes matched the selected filters.\n'
  fi
  printf '\nCPU%% is ps process accounting; RSS/VSZ are KiB. Read-only; Ctrl+C to stop watch mode.\n'
}

sample=0
while :; do
  ((sample+=1))
  collect_processes
  total=$(wc -l < "$SORTED_FILE" | tr -d '[:space:]')

  if (( JSON )); then
    render_json
    exit 0
  fi

  render_table "$sample" "$total"
  if (( WATCH == 0 )); then
    break
  fi
  if (( COUNT > 0 && sample >= COUNT )); then
    break
  fi
  sleep "$INTERVAL"
done
