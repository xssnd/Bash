#!/usr/bin/env bash
# =============================================================================
# system_health_check.sh - Linux health monitoring for local and remote servers
# Version: 2.0.0 | Bash 4.3+
#
# INSTALLATION
#   Debian/Ubuntu: sudo apt install openssh-client procps util-linux coreutils
#   Fedora/RHEL:   sudo dnf install openssh-clients procps-ng util-linux coreutils
#   Arch:          sudo pacman -S --needed openssh procps-ng util-linux
#   chmod +x system_health_check.sh
#
# SSH SECURITY
#   ssh-keygen -t ed25519
#   ssh-copy-id user@server
#   Verify server fingerprints out-of-band and populate ~/.ssh/known_hosts.
#   Strict host-key checking is enabled; this script never disables it.
#
# HOST FILE: one host or user@host per line; blank lines and # comments ignored.
#   admin@192.0.2.10
#   ops@web01.example.net
#
# USAGE
#   ./system_health_check.sh
#   ./system_health_check.sh --hosts servers.txt --parallel 5
#   ./system_health_check.sh --hosts servers.txt --user admin --identity ~/.ssh/id_ed25519
#   ./system_health_check.sh --hosts servers.txt --port 2222 --timeout 8
#   ./system_health_check.sh --hosts servers.txt --service nginx --service ssh
#   ./system_health_check.sh --hosts servers.txt --output health-report.txt
#   ./system_health_check.sh --cpu-warn 2.0 --memory-warn 85 --disk-warn 90
#   ./system_health_check.sh --json
#
# FEATURES
#   CPU load/core ratio, RAM and swap, filesystem space/inodes, uptime, top
#   processes, process count, failed systemd units, selected services, network
#   route/listening sockets, firewall indicator and reboot-required marker.
#   SSH key auth, strict known_hosts, batch mode, timeouts and bounded parallel
#   batches. Read-only: no automatic remediation or configuration edits.
#
# REQUIREMENTS: Bash 4.3+, awk, df, free, ps, uptime, hostname, coreutils.
# Remote mode also needs OpenSSH client and standard Linux monitoring utilities.
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C
umask 077

VERSION="2.0.0"
HOSTS_FILE=""
SSH_USER=""
SSH_PORT=22
IDENTITY=""
PARALLEL=5
TIMEOUT=8
CPU_WARN=2.0
MEM_WARN=85
DISK_WARN=90
OUTPUT=""
JSON=0
AGENT=0
SERVICES=()
SCRIPT_PATH="$(readlink -f -- "$${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$${BASH_SOURCE[0]}")"

usage() { sed -n '1,51p' "$0" | sed 's/^#//' | sed 's/^ //'; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
need_value() { (($# >= 2)) || die "Option $1 requires a value"; }

while (($#)); do
  case "$1" in
    --hosts) need_value "$@"; HOSTS_FILE=$2; shift 2 ;;
    --user) need_value "$@"; SSH_USER=$2; shift 2 ;;
    --port) need_value "$@"; SSH_PORT=$2; shift 2 ;;
    --identity) need_value "$@"; IDENTITY=$2; shift 2 ;;
    --parallel) need_value "$@"; PARALLEL=$2; shift 2 ;;
    --timeout) need_value "$@"; TIMEOUT=$2; shift 2 ;;
    --cpu-warn) need_value "$@"; CPU_WARN=$2; shift 2 ;;
    --memory-warn) need_value "$@"; MEM_WARN=$2; shift 2 ;;
    --disk-warn) need_value "$@"; DISK_WARN=$2; shift 2 ;;
    --service) need_value "$@"; SERVICES+=("$2"); shift 2 ;;
    --output|-o) need_value "$@"; OUTPUT=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --agent) AGENT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || die "Invalid SSH port"
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] && ((PARALLEL <= 64)) || die "--parallel must be 1..64"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] && ((TIMEOUT <= 300)) || die "--timeout must be 1..300"
awk -v n="$CPU_WARN" 'BEGIN{exit !(n>0)}' || die "--cpu-warn must be greater than zero"
for n in "$MEM_WARN" "$DISK_WARN"; do
  [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= 100)) || die "Memory/disk thresholds must be 1..100"
done

collect_agent() {
  local host kernel up load cores mt ma mu mp st sf su sp rp iproc pc failed route sockets fw reboot
  local status="OK" reasons="" service active
  host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf unknown)
  kernel=$(uname -r 2>/dev/null || printf unknown)
  up=$(uptime -p 2>/dev/null || uptime 2>/dev/null || printf unknown)
  load=$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || printf unknown)
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
  read -r mt ma < <(awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END{print t+0, a+0}' /proc/meminfo)
  mu=$((mt-ma)); mp=$(awk -v u="$mu" -v t="$mt" 'BEGIN{if(t>0)printf "%.1f",u*100/t;else print 0}')
  read -r st sf < <(awk '/SwapTotal:/ {t=$2} /SwapFree:/ {f=$2} END{print t+0, f+0}' /proc/meminfo)
  su=$((st-sf)); sp=$(awk -v u="$su" -v t="$st" 'BEGIN{if(t>0)printf "%.1f",u*100/t;else print 0}')
  rp=$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}')
  iproc=$(df -Pi / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}')
  pc=$(ps -e --no-headers 2>/dev/null | wc -l | tr -d ' ')
  failed="N/A"
  if command -v systemctl >/dev/null 2>&1; then failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'END{print NR+0}'); fi
  route="unavailable"
  if command -v ip >/dev/null 2>&1; then route=$(ip route show default 2>/dev/null | head -n 1); [[ -n "$route" ]] || route="NO DEFAULT ROUTE"; fi
  sockets="N/A"
  if command -v ss >/dev/null 2>&1; then sockets=$(ss -H -lntu 2>/dev/null | wc -l | tr -d ' '); fi
  fw="not detected / inactive"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then fw="active (ufw)"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then fw="active (firewalld)"
  elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q .; then fw="rules present (nftables)"
  elif command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null | grep -q '^-A'; then fw="rules present (iptables)"
  fi
  reboot="no"; [[ -e /var/run/reboot-required || -e /run/reboot-required ]] && reboot="yes"

  if awk -v x="$mp" -v t="$MEM_WARN" 'BEGIN{exit !(x>=t)}'; then status="WARN"; reasons+="RAM $mp% (limit $MEM_WARN%), "; fi
  if (( rp >= DISK_WARN )); then status="WARN"; reasons+="root filesystem $rp% (limit $DISK_WARN%), "; fi
  if awk -v x="$load" -v c="$cores" -v t="$CPU_WARN" 'BEGIN{split(x,a," "); exit !(a[1]/c>=t)}'; then status="WARN"; reasons+="load/core high, "; fi
  if [[ "$failed" =~ ^[0-9]+$ ]] && (( failed > 0 )); then status="WARN"; reasons+="$failed failed systemd unit(s), "; fi
  if [[ "$reboot" == yes ]]; then status="WARN"; reasons+="reboot required, "; fi

  printf 'HOST: %s\nSTATUS: %s\n' "$host" "$status"
  printf 'SYSTEM: kernel=%s | uptime=%s | CPUs=%s | load=%s\n' "$kernel" "$up" "$cores" "$load"
  printf 'MEMORY: used=%s%% | total=%s MiB | available=%s MiB | swap=%s%%\n' "$mp" "$((mt/1024))" "$((ma/1024))" "$sp"
  printf 'STORAGE: root=%s%% | root-inodes=%s%%\n' "$rp" "$iproc"
  printf 'PROCESSES: total=%s | failed-systemd-units=%s\n' "$pc" "$failed"
  printf 'NETWORK: default-route=%s | listening-sockets=%s\n' "$route" "$sockets"
  printf 'SECURITY: firewall=%s | reboot-required=%s\n' "$fw" "$reboot"
  printf 'TOP CPU PROCESSES:\n'
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | head -n 6 | sed 's/^/  /'
  if (("$${#SERVICES[@]}")); then
    printf 'REQUESTED SERVICES:\n'
    for service in "$${SERVICES[@]}"; do
      active="unknown"
      if command -v systemctl >/dev/null 2>&1; then active=$(systemctl is-active "$service" 2>/dev/null || true); [[ -n "$active" ]] || active="inactive"; fi
      printf '  %s: %s\n' "$service" "$active"
      if [[ "$active" != active ]]; then status="WARN"; reasons+="service $service=$active, "; fi
    done
  fi
  printf 'DETAIL: %s\n' "$${reasons:-No configured warning threshold exceeded.}"
}

if (( AGENT )); then collect_agent; exit 0; fi
for cmd in awk df free ps uptime hostname readlink; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done

if [[ -n "$HOSTS_FILE" ]]; then
  command -v ssh >/dev/null 2>&1 || die "OpenSSH client is required for remote mode"
  [[ -r "$HOSTS_FILE" ]] || die "Cannot read hosts file: $HOSTS_FILE"
  (( JSON == 0 )) || die "--json is supported for local-only checks"
  [[ -z "$IDENTITY" || -r "$IDENTITY" ]] || die "Cannot read SSH identity file: $IDENTITY"
fi

run_local() {
  local args=(--agent --cpu-warn "$CPU_WARN" --memory-warn "$MEM_WARN" --disk-warn "$DISK_WARN") s
  for s in "$${SERVICES[@]}"; do args+=(--service "$s"); done
  "$SCRIPT_PATH" "$${args[@]}"
}

run_remote() {
  local target=$1 outfile=$2
  local ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout="$TIMEOUT" -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o IdentitiesOnly=yes -p "$SSH_PORT")
  local remote_args=(--agent --cpu-warn "$CPU_WARN" --memory-warn "$MEM_WARN" --disk-warn "$DISK_WARN") s
  [[ -z "$SSH_USER" ]] || ssh_args+=(-l "$SSH_USER")
  [[ -z "$IDENTITY" ]] || ssh_args+=(-i "$IDENTITY")
  for s in "$${SERVICES[@]}"; do remote_args+=(--service "$s"); done
  {
    printf 'HOST TARGET: %s\n' "$target"
    if ssh "$${ssh_args[@]}" "$target" "bash -s -- $(printf '%q ' "$${remote_args[@]}")" < "$SCRIPT_PATH"; then :
    else printf 'STATUS: UNKNOWN\nDETAIL: SSH failed. Check key access, known_hosts, network and remote Bash.\n'; fi
  } > "$outfile" 2>&1
}

TMP_DIR=$(mktemp -d "$${TMPDIR:-/tmp}/system-health.XXXXXX") || die "Cannot create temporary directory"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT INT TERM

if [[ -z "$HOSTS_FILE" ]]; then
  if (( JSON )); then
    command -v python3 >/dev/null 2>&1 || die "python3 is required for --json"
    python3 - <<'PY'
import json, os, subprocess
def out(*cmd):
    try: return subprocess.check_output(cmd,text=True,stderr=subprocess.DEVNULL).strip()
    except Exception: return ""
m={}
for line in open("/proc/meminfo"):
    p=line.split()
    if len(p)>=2 and p[0] in ("MemTotal:","MemAvailable:","SwapTotal:","SwapFree:"): m[p[0]]=int(p[1])*1024
t=m.get("MemTotal:",0); a=m.get("MemAvailable:",0)
d=out("df","-P","/").splitlines()
u=int(d[1].split()[4].rstrip("%")) if len(d)>1 else None
print(json.dumps({"hostname":out("hostname"),"kernel":out("uname","-r"),"uptime":out("uptime","-p"),
 "load_average":open("/proc/loadavg").read().split()[:3],"cpu_cores":os.cpu_count(),
 "memory":{"total_bytes":t,"available_bytes":a,"used_percent":round((t-a)*100/t,1) if t else None},
 "root_filesystem_used_percent":u},indent=2))
PY
    exit 0
  fi
  run_local | tee "$TMP_DIR/local.txt"
  [[ -z "$OUTPUT" ]] || cp "$TMP_DIR/local.txt" "$OUTPUT"
  grep -q '^STATUS: WARN' "$TMP_DIR/local.txt" && exit 1 || exit 0
fi

mapfile -t HOSTS < <(sed 's/[[:space:]]*#.*$//' "$HOSTS_FILE" | awk 'NF {print $1}')
(("$${#HOSTS[@]}")) || die "No hosts found in $HOSTS_FILE"
printf '\033[1;36mSYSTEM HEALTH CHECK\033[0m version %s\n' "$VERSION"
printf 'Targets: %d | Parallel batch size: %d | SSH port: %s | Strict host-key checking: enabled\n\n' "$${#HOSTS[@]}" "$PARALLEL" "$SSH_PORT"

batch=0
for ((i=0; i<${#HOSTS[@]}; i++)); do
  target=$${HOSTS[$i]}
  [[ "$target" =~ ^[a-zA-Z0-9._@:-]+$ ]] || { printf 'Skipping invalid host: %s\n' "$target" >&2; continue; }
  run_remote "$target" "$TMP_DIR/host-$i.txt" &
  ((batch+=1))
  if (( batch >= PARALLEL )); then wait; batch=0; fi
done
((batch == 0)) || wait

overall=0
for ((i=0; i<${#HOSTS[@]}; i++)); do
  file="$TMP_DIR/host-$i.txt"; [[ -f "$file" ]] || continue
  printf '%s\n' '----------------------------------------------------------------'
  cat "$file"
  grep -q '^STATUS: WARN\|^STATUS: UNKNOWN' "$file" && overall=1 || true
done
printf '%s\n' '----------------------------------------------------------------'
printf 'Completed: %s | Hosts: %d | Overall: %s\n' "$(date '+%F %T %Z')" "$${#HOSTS[@]}" "$([[ $overall -eq 0 ]] && printf OK || printf WARN/UNKNOWN)"
if [[ -n "$OUTPUT" ]]; then
  { printf 'SYSTEM HEALTH REPORT | %s\n' "$(date '+%F %T %Z')"; for ((i=0; i<${#HOSTS[@]}; i++)); do [[ -f "$TMP_DIR/host-$i.txt" ]] && cat "$TMP_DIR/host-$i.txt"; done; } > "$OUTPUT"
  printf 'Report saved: %s\n' "$OUTPUT"
fi
exit "$overall"
