#!/usr/bin/env bash
# =============================================================================
# Linux Disk Monitor Dashboard
# =============================================================================
# DESCRIPTION
#   Live terminal dashboard for physical disks, filesystem capacity, device
#   read/write throughput, and processes ranked by I/O activity.
#
# INSTALLATION
#   Debian / Ubuntu:
#     sudo apt update
#     sudo apt install -y bash util-linux coreutils gawk procps
#
#   Fedora / RHEL:
#     sudo dnf install -y bash util-linux coreutils gawk procps-ng
#
#   Arch Linux:
#     sudo pacman -S --needed bash util-linux coreutils gawk procps-ng
#
#   Save this file as disk-monitor.sh, then make it executable:
#     chmod +x disk-monitor.sh
#
# USAGE
#   ./disk-monitor.sh [OPTIONS]
#
#   Recommended (root provides visibility into more process I/O counters):
#     sudo ./disk-monitor.sh
#
# OPTIONS
#   --asc             Sort top processes by I/O rate, lowest first.
#   --desc            Sort top processes by I/O rate, highest first (default).
#   --interval=SEC    Refresh interval in whole seconds (default: 2).
#   --top=N           Number of processes to display (default: 10).
#   -h, --help        Show usage information and exit.
#
# EXAMPLES
#   sudo ./disk-monitor.sh
#   sudo ./disk-monitor.sh --asc
#   sudo ./disk-monitor.sh --desc --interval=3
#   sudo ./disk-monitor.sh --top=20 --interval=5
#   ./disk-monitor.sh --help
#
# DASHBOARD LEGEND
#   Red   = filesystem space used
#   Green = filesystem space available
#   Grey  = remaining bar width / rounding remainder
#   Device throughput is displayed in bytes per second.
#   Process I/O is sampled from /proc/<PID>/io and displayed in bytes/second.
#
# NOTES
#   - Linux only; requires /proc, lsblk, df, awk, sort, and standard utilities.
#   - Root is recommended for the most complete per-process I/O visibility.
#   - Process I/O counters are not identical to physical-device throughput:
#     caching, buffering, writeback, and filesystem behavior affect attribution.
#   - Capacity is reported for mounted filesystems associated with each disk.
#     Unmounted partitions and filesystems may not have a capacity bar.
#   - This script is read-only. It does not format, mount, or modify disks.
#   - Press Ctrl+C to exit the dashboard.
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

SORT_ORDER=desc
INTERVAL=2
TOP_N=10
for arg in "$@"; do
  case "$arg" in
    --asc) SORT_ORDER=asc ;;
    --desc) SORT_ORDER=desc ;;
    --interval=*) INTERVAL="${arg#*=}" ;;
    --top=*) TOP_N="${arg#*=}" ;;
    -h|--help)
      sed -n '1,82p' "$0" | sed 's/^#\?//' | sed 's/^ //'
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "interval must be a positive integer" >&2; exit 2; }
[[ "$TOP_N" =~ ^[1-9][0-9]*$ ]] || { echo "top must be a positive integer" >&2; exit 2; }
for cmd in lsblk df awk sort; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

RED=$'\033[31m'; GREEN=$'\033[32m'; GREY=$'\033[90m'; RESET=$'\033[0m'; BOLD=$'\033[1m'
declare -A PREV_R PREV_W PREV_PR PREV_PW
human() { awk -v n="${1:-0}" 'BEGIN { split("B KiB MiB GiB TiB PiB",u," "); i=1; while(n>=1024 && i<6){n/=1024;i++} printf "%.1f %s",n,u[i] }'; }
bar() {
  local used=$1 free=$2 total=$3 width=30 r g x
  (( total > 0 )) || { printf '[%*s]' "$width" ''; return; }
  r=$(( used * width / total )); g=$(( free * width / total ))
  (( r > width )) && r=$width
  (( g > width-r )) && g=$((width-r))
  x=$((width-r-g))
  printf '['
  printf '%s' "$RED"; printf '%*s' "$r" '' | tr ' ' '█'
  printf '%s' "$GREEN"; printf '%*s' "$g" '' | tr ' ' '█'
  printf '%s' "$GREY"; printf '%*s' "$x" '' | tr ' ' '░'
  printf '%s]' "$RESET"
}
sample_devices() {
  local name reads writes delta_r delta_w
  while read -r name reads writes; do
    [[ -n "$name" ]] || continue
    if [[ -n "${PREV_R[$name]+x}" ]]; then
      delta_r=$(( (reads - PREV_R[$name]) * 512 / INTERVAL ))
      delta_w=$(( (writes - PREV_W[$name]) * 512 / INTERVAL ))
      (( delta_r < 0 )) && delta_r=0
      (( delta_w < 0 )) && delta_w=0
      printf '%s\t%s\t%s\n' "$name" "$delta_r" "$delta_w"
    fi
    PREV_R[$name]=$reads; PREV_W[$name]=$writes
  done < <(awk '$3 !~ /^(loop|ram|zram)/ {print $3, $6, $10}' /proc/diskstats)
}
sample_processes() {
  local d pid r w comm dr dw
  for d in /proc/[0-9]*; do
    [[ -r "$d/io" ]] || continue
    pid=${d##*/}
    r=$(awk '$1=="read_bytes:"{print $2}' "$d/io" 2>/dev/null) || continue
    w=$(awk '$1=="write_bytes:"{print $2}' "$d/io" 2>/dev/null) || continue
    [[ "$r" =~ ^[0-9]+$ && "$w" =~ ^[0-9]+$ ]] || continue
    if [[ -n "${PREV_PR[$pid]+x}" ]]; then
      dr=$(( (r - PREV_PR[$pid]) / INTERVAL )); dw=$(( (w - PREV_PW[$pid]) / INTERVAL ))
      (( dr < 0 )) && dr=0; (( dw < 0 )) && dw=0
      if (( dr + dw > 0 )); then
        comm=$(cat "$d/comm" 2>/dev/null || echo '?')
        printf '%s\t%s\t%s\t%s\n' "$pid" "$comm" "$dr" "$dw"
      fi
    fi
    PREV_PR[$pid]=$r; PREV_PW[$pid]=$w
  done
}
render() {
  local disk size model part mount fs_size used avail total name
  local -a dev_rows proc_rows
  clear 2>/dev/null || true
  printf '%s%sLinux Disk Monitor%s  |  %s  |  refresh: %ss  |  sort: %s\n' "$BOLD" "$GREEN" "$RESET" "$(date '+%F %T')" "$INTERVAL" "$SORT_ORDER"
  printf '%s\n' '==============================================================================='
  printf '\n%sPHYSICAL DISKS & MOUNTED FILESYSTEM CAPACITY%s\n' "$BOLD" "$RESET"
  while read -r disk size model; do
    [[ -n "$disk" ]] || continue
    printf '\n%s (%s) %s\n' "$disk" "$(human "$size")" "${model:-}"
    total=0; used=0; avail=0
    while read -r part mount; do
      [[ -n "$mount" && "$mount" != "-" ]] || continue
      read -r fs_size fs_used fs_avail < <(df -B1 --output=size,used,avail -- "$mount" 2>/dev/null | awk 'NR==2{print $1,$2,$3}') || true
      [[ "${fs_size:-}" =~ ^[0-9]+$ ]] || continue
      total=$((total+fs_size)); used=$((used+fs_used)); avail=$((avail+fs_avail))
      printf '  %-18s ' "$mount"; bar "$fs_used" "$fs_avail" "$fs_size"
      printf '  used %s / %s\n' "$(human "$fs_used")" "$(human "$fs_size")"
    done < <(lsblk -lnpo NAME,MOUNTPOINT "$disk" 2>/dev/null)
    if (( total > 0 )); then
      printf '  %-18s ' 'TOTAL*'; bar "$used" "$avail" "$total"
      printf '  used %s  free %s\n' "$(human "$used")" "$(human "$avail")"
    else
      printf '  No mounted filesystem found for this disk.\n'
    fi
  done < <(lsblk -dnbo NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{ $4=""; print $1,$2,$3 }')

  printf '\n%sLIVE DEVICE THROUGHPUT%s\n' "$BOLD" "$RESET"
  mapfile -t dev_rows < <(sample_devices)
  if (("${#dev_rows[@]}" == 0)); then
    echo '  Collecting initial sample...'
  else
    printf '%-16s %16s %16s\n' DEVICE READ/s WRITE/s
    printf '%s\n' "${dev_rows[@]}" | awk -F '\t' '{printf "%-16s %16s %16s\n",$1,$2,$3}' 
  fi

  printf '\n%sTOP PROCESS I/O (per-process counters)%s\n' "$BOLD" "$RESET"
  mapfile -t proc_rows < <(sample_processes)
  if (("${#proc_rows[@]}" == 0)); then
    echo '  Collecting initial sample or no process I/O detected.'
  else
    if [[ "$SORT_ORDER" == asc ]]; then
      printf '%s\n' "${proc_rows[@]}" | awk -F '\t' '{print $1,$2,$3+$4,$3,$4}' | sort -n -k3,3 | head -n "$TOP_N" | awk '{printf "PID %-7s %-20s total/s %-12s read/s %-12s write/s\n",$1,$2,$3,$4,$5}'
    else
      printf '%s\n' "${proc_rows[@]}" | awk -F '\t' '{print $1,$2,$3+$4,$3,$4}' | sort -nr -k3,3 | head -n "$TOP_N" | awk '{printf "PID %-7s %-20s total/s %-12s read/s %-12s write/s\n",$1,$2,$3,$4,$5}'
    fi
  fi
  printf '\n%sNote:%s process counters are kernel per-process bytes; they are not guaranteed to map exactly to physical-device throughput. Run with sudo for fuller process visibility. Press Ctrl+C to exit.\n' "$GREY" "$RESET"
}
trap 'printf "\n"; exit 0' INT TERM
while :; do
  render
  sleep "$INTERVAL"
done
