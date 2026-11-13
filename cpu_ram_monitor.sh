#!/usr/bin/env bash
# cpu_ram_monitor.sh - CPU/RAM monitoring for local and multi-server Linux
# Version 1.0.0 | Bash 4.3+
#
# INSTALL
#   Debian/Ubuntu: sudo apt install openssh-client procps
#   Fedora/RHEL:   sudo dnf install openssh-clients procps-ng
#   Arch:          sudo pacman -S --needed openssh procps-ng
#   chmod +x cpu_ram_monitor.sh
#
# SECURE SSH SETUP
#   ssh-keygen -t ed25519
#   ssh-copy-id admin@server
#   Verify host fingerprints and populate ~/.ssh/known_hosts.
#   StrictHostKeyChecking=yes is enforced; host-key checks are never bypassed.
#
# HOST FILE: one host or user@host per line; blank lines and # comments ignored.
#   admin@192.0.2.10
#   ops@web01.example.net
#
# USAGE
#   ./cpu_ram_monitor.sh
#   ./cpu_ram_monitor.sh --interval 2 --count 10
#   ./cpu_ram_monitor.sh --hosts servers.txt --interval 5 --parallel 10
#   ./cpu_ram_monitor.sh --hosts servers.txt --user admin --identity ~/.ssh/id_ed25519
#   ./cpu_ram_monitor.sh --hosts servers.txt --port 2222 --timeout 10
#   ./cpu_ram_monitor.sh --cpu-warn 80 --memory-warn 85 --top 5
#   ./cpu_ram_monitor.sh --hosts servers.txt --output cpu-ram-report.log
#
# FEATURES
#   CPU percentage from /proc/stat deltas, RAM used/available, swap usage,
#   load average, CPU core count, top CPU/RAM processes, warning thresholds,
#   continuous or finite sampling, multi-server SSH, key selection, strict
#   host-key verification, bounded parallel polling, timeout and report logging.
#   Read-only; no root privileges or automatic remediation required.
#
# REQUIREMENTS: Bash 4.3+, awk, ps, sed, sleep, date and Linux /proc interfaces.
# Remote mode also requires OpenSSH client and Bash on target hosts.
set -Eeuo pipefail
export LC_ALL=C
umask 077

VERSION=1.0.0
HOSTS_FILE=""
SSH_USER=""
SSH_PORT=22
IDENTITY=""
PARALLEL=5
INTERVAL=2
COUNT=0
TIMEOUT=8
CPU_WARN=80
MEM_WARN=85
OUTPUT=""
TOP=3
AGENT=0

usage() { sed -n '1,48p' "$0" | sed 's/^#//' | sed 's/^ //'; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need_value() { (($# >= 2)) || die "Option $1 requires a value"; }

while (($#)); do
  case "$1" in
    --hosts) need_value "$@"; HOSTS_FILE=$2; shift 2 ;;
    --user) need_value "$@"; SSH_USER=$2; shift 2 ;;
    --port) need_value "$@"; SSH_PORT=$2; shift 2 ;;
    --identity) need_value "$@"; IDENTITY=$2; shift 2 ;;
    --parallel) need_value "$@"; PARALLEL=$2; shift 2 ;;
    --interval|-i) need_value "$@"; INTERVAL=$2; shift 2 ;;
    --count|-n) need_value "$@"; COUNT=$2; shift 2 ;;
    --timeout) need_value "$@"; TIMEOUT=$2; shift 2 ;;
    --cpu-warn) need_value "$@"; CPU_WARN=$2; shift 2 ;;
    --memory-warn) need_value "$@"; MEM_WARN=$2; shift 2 ;;
    --output|-o) need_value "$@"; OUTPUT=$2; shift 2 ;;
    --top) need_value "$@"; TOP=$2; shift 2 ;;
    --agent) AGENT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT>=1 && SSH_PORT<=65535)) || die "Invalid SSH port"
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] && ((PARALLEL<=64)) || die "--parallel must be 1..64"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] && ((INTERVAL<=3600)) || die "--interval must be 1..3600"
[[ "$COUNT" =~ ^[0-9]+$ ]] && ((COUNT<=1000000)) || die "Invalid --count"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] && ((TIMEOUT<=300)) || die "--timeout must be 1..300"
[[ "$TOP" =~ ^[0-9]+$ ]] && ((TOP<=20)) || die "--top must be 0..20"
for n in "$CPU_WARN" "$MEM_WARN"; do
  [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=100)) || die "CPU/RAM thresholds must be 1..100"
done

monitor_agent() {
  local interval=$1 cpu_warn=$2 mem_warn=$3 top=$4
  local before after t1 t2 i1 i2 dt di cpu_pct
  local mt ma mu mp st sf su sp cores load host status=OK reasons=""
  cpu_sample() {
    awk '/^cpu / {idle=$5+$6; total=0; for(i=2;i<=NF;i++) total+=$i; print total, idle; exit}' /proc/stat
  }
  before=$(cpu_sample)
  sleep "$interval"
  after=$(cpu_sample)
  read -r t1 i1 <<< "$before"
  read -r t2 i2 <<< "$after"
  dt=$((t2-t1)); di=$((i2-i1))
  cpu_pct=$(awk -v d="$dt" -v i="$di" 'BEGIN{v=(d>0?(d-i)*100/d:0); if(v<0)v=0; if(v>100)v=100; printf "%.1f",v}')
  read -r mt ma < <(awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END{print t+0,a+0}' /proc/meminfo)
  mu=$((mt-ma))
  mp=$(awk -v u="$mu" -v t="$mt" 'BEGIN{printf "%.1f",(t>0?u*100/t:0)}')
  read -r st sf < <(awk '/SwapTotal:/ {t=$2} /SwapFree:/ {f=$2} END{print t+0,f+0}' /proc/meminfo)
  su=$((st-sf))
  sp=$(awk -v u="$su" -v t="$st" 'BEGIN{printf "%.1f",(t>0?u*100/t:0)}')
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
  load=$(awk '{print $1" "$2" "$3}' /proc/loadavg)
  host=$(hostname -f 2>/dev/null || hostname)
  if awk -v x="$cpu_pct" -v t="$cpu_warn" 'BEGIN{exit !(x>=t)}'; then status=WARN; reasons+="CPU ${cpu_pct}% >= ${cpu_warn}%; "; fi
  if awk -v x="$mp" -v t="$mem_warn" 'BEGIN{exit !(x>=t)}'; then status=WARN; reasons+="RAM ${mp}% >= ${mem_warn}%; "; fi
  printf 'HOST=%s\nSTATUS=%s\nCPU=%s\nRAM=%s\n' "$host" "$status" "$cpu_pct" "$mp"
  printf 'RAM_USED_MIB=%s\nRAM_TOTAL_MIB=%s\nRAM_AVAILABLE_MIB=%s\n' "$((mu/1024))" "$((mt/1024))" "$((ma/1024))"
  printf 'SWAP=%s\nSWAP_USED_MIB=%s\nSWAP_TOTAL_MIB=%s\nCORES=%s\nLOAD=%s\n' "$sp" "$((su/1024))" "$((st/1024))" "$cores" "$load"
  printf 'DETAIL=%s\n' "${reasons:-Within configured thresholds.}"
  if ((top>0)); then
    printf 'TOP_CPU:\n'
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu | sed -n "1,$((top+1))p"
    printf 'TOP_RAM:\n'
    ps -eo pid,comm,%cpu,%mem --sort=-%mem | sed -n "1,$((top+1))p"
  fi
}

if ((AGENT)); then monitor_agent "$INTERVAL" "$CPU_WARN" "$MEM_WARN" "$TOP"; exit 0; fi
if [[ -n "$HOSTS_FILE" ]]; then
  command -v ssh >/dev/null 2>&1 || die "OpenSSH client required for remote mode"
  [[ -r "$HOSTS_FILE" ]] || die "Cannot read hosts file: $HOSTS_FILE"
  [[ -z "$IDENTITY" || -r "$IDENTITY" ]] || die "Cannot read SSH identity: $IDENTITY"
fi

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cpu-ram-monitor.XXXXXX") || die "Cannot create temporary directory"
trap 'rm -rf -- "$TMP_DIR"' EXIT INT TERM

if [[ -n "$HOSTS_FILE" ]]; then
  mapfile -t HOSTS < <(sed 's/[[:space:]]*#.*$//' "$HOSTS_FILE" | awk 'NF{print $1}')
  (("${#HOSTS[@]}" > 0)) || die "No hosts found"
else
  HOSTS=(LOCAL)
fi

run_target() {
  local target=$1 output_file=$2
  if [[ "$target" == LOCAL ]]; then
    "$SCRIPT_PATH" --agent --interval "$INTERVAL" --cpu-warn "$CPU_WARN" --memory-warn "$MEM_WARN" --top "$TOP" > "$output_file" 2>&1
    return $?
  fi
  local ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout="$TIMEOUT" -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o IdentitiesOnly=yes -p "$SSH_PORT")
  [[ -z "$SSH_USER" ]] || ssh_args+=(-l "$SSH_USER")
  [[ -z "$IDENTITY" ]] || ssh_args+=(-i "$IDENTITY")
  ssh "${ssh_args[@]}" "$target" "bash -s -- --agent --interval $INTERVAL --cpu-warn $CPU_WARN --memory-warn $MEM_WARN --top $TOP" < "$SCRIPT_PATH" > "$output_file" 2>&1
}

printf '\033[1;36mCPU & RAM MONITOR\033[0m v%s\n' "$VERSION"
printf 'Targets: %d | Interval: %ss | CPU warn: %s%% | RAM warn: %s%% | Parallel: %s\n' "${#HOSTS[@]}" "$INTERVAL" "$CPU_WARN" "$MEM_WARN" "$PARALLEL"
printf 'Started: %s | Ctrl+C to stop\n\n' "$(date '+%F %T %Z')"

sample=0
overall=0
while :; do
  ((sample+=1))
  printf '\033[1;33mSAMPLE %d\033[0m %s\n' "$sample" "$(date '+%F %T %Z')"
  batch=0
  for ((i=0;i<${#HOSTS[@]};i++)); do
    target=${HOSTS[$i]}
    if [[ "$target" != LOCAL && ! "$target" =~ ^[a-zA-Z0-9][a-zA-Z0-9._@:-]*$ ]]; then
      printf 'Skipping invalid host entry: %s\n' "$target" >&2
      continue
    fi
    run_target "$target" "$TMP_DIR/host-$i.txt" &
    ((batch+=1))
    if ((batch>=PARALLEL)); then wait; batch=0; fi
  done
  ((batch==0)) || wait

  for ((i=0;i<${#HOSTS[@]};i++)); do
    file="$TMP_DIR/host-$i.txt"
    [[ -f "$file" ]] || continue
    if grep -q '^CPU=' "$file"; then
      host=$(sed -n 's/^HOST=//p' "$file" | sed -n '1p')
      cpu=$(sed -n 's/^CPU=//p' "$file" | sed -n '1p')
      ram=$(sed -n 's/^RAM=//p' "$file" | sed -n '1p')
      swap=$(sed -n 's/^SWAP=//p' "$file" | sed -n '1p')
      status=$(sed -n 's/^STATUS=//p' "$file" | sed -n '1p')
      load=$(sed -n 's/^LOAD=//p' "$file" | sed -n '1p')
      detail=$(sed -n 's/^DETAIL=//p' "$file" | sed -n '1p')
      printf '  %-28s CPU %6s%% | RAM %6s%% | SWAP %6s%% | Load %-14s | %s\n' "$host" "$cpu" "$ram" "$swap" "$load" "$status"
      [[ "$status" == WARN ]] && overall=1
      if ((TOP>0)); then awk '/^TOP_CPU:/{p=1;next}/^TOP_RAM:/{p=0}p' "$file" | sed 's/^/      /'; fi
      [[ -z "$detail" ]] || printf '      %s\n' "$detail"
    else
      printf '  %-28s UNKNOWN | SSH or remote execution failed\n' "${HOSTS[$i]}"
      sed 's/^/      /' "$file"
      overall=1
    fi
  done
  if [[ -n "$OUTPUT" ]]; then
    {
      printf 'SAMPLE %d | %s\n' "$sample" "$(date '+%F %T %Z')"
      for ((i=0;i<${#HOSTS[@]};i++)); do [[ -f "$TMP_DIR/host-$i.txt" ]] && cat "$TMP_DIR/host-$i.txt"; done
      printf '\n'
    } >> "$OUTPUT"
  fi
  printf '\n'
  if ((COUNT>0 && sample>=COUNT)); then break; fi
  sleep "$INTERVAL"
done
printf 'Finished: %s | Samples: %d | Result: %s\n' "$(date '+%F %T %Z')" "$sample" "$([[ $overall -eq 0 ]] && printf OK || printf WARN/ERROR)"
[[ -z "$OUTPUT" ]] || printf 'Report appended to: %s\n' "$OUTPUT"
exit "$overall"
