#!/usr/bin/env bash
# =============================================================================
# large_files_finder.sh — find large files on Linux
# =============================================================================
# INSTALLATION
#   Debian / Ubuntu: sudo apt update && sudo apt install -y bash findutils coreutils util-linux
#   Fedora / RHEL:   sudo dnf install -y bash findutils coreutils util-linux
#   Arch Linux:      sudo pacman -S --needed bash findutils coreutils util-linux
#
#   Save as large_files_finder.sh, then:
#     chmod +x large_files_finder.sh
#
# USAGE
#   ./large_files_finder.sh [OPTIONS] [PATH ...]
#
#   Examples:
#     sudo ./large_files_finder.sh /
#     ./large_files_finder.sh ~/Downloads
#     sudo ./large_files_finder.sh --min-size 500M --top 30 /home /var
#     ./large_files_finder.sh --min-size=2G --sort asc /mnt/storage
#     ./large_files_finder.sh --help
#
# OPTIONS
#   -s, --min-size SIZE   Minimum file size: bytes or K, M, G, T, P (default: 100M)
#   -n, --top N           Maximum number of files to display (default: 50)
#       --sort ORDER      Sort by size: desc (default) or asc
#   -h, --help            Show this help and exit
#
#   If no PATH is supplied, the current directory is searched.
#
# OVERVIEW
#   SECTION 1: Physical disks and their capacity, plus mounted filesystem usage.
#   SECTION 2: Matching files with human-readable sizes and their full paths.
#
# NOTES
#   - Linux with Bash 4+, GNU find, GNU sort, lsblk, and df is required.
#   - Use sudo to scan protected directories and reduce permission errors.
#   - Searching / can take a long time. Scans include mounted filesystems below
#     the selected path; virtual /proc, /sys, /dev, and /run trees are skipped.
#   - The script is read-only: it does not delete, move, or change files.
#   - Files larger than the threshold are selected (strictly greater).
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

MIN_SIZE=100M
TOP_N=50
SORT_ORDER=desc
PATHS=()

usage() {
  sed -n '1,46p' "$0" | sed 's/^#\?//' | sed 's/^ //'
}

die() { printf 'Error: %s\n' "$*" >&2; exit 2; }

while (($#)); do
  case "$1" in
    -s|--min-size)
      (($# >= 2)) || die "$1 requires a size value"
      MIN_SIZE=$2; shift 2 ;;
    --min-size=*)
      MIN_SIZE=${1#*=}; shift ;;
    -n|--top)
      (($# >= 2)) || die "$1 requires a number"
      TOP_N=$2; shift 2 ;;
    --top=*)
      TOP_N=${1#*=}; shift ;;
    --sort)
      (($# >= 2)) || die "$1 requires asc or desc"
      SORT_ORDER=$2; shift 2 ;;
    --sort=*)
      SORT_ORDER=${1#*=}; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift
      while (($#)); do PATHS+=("$1"); shift; done ;;
    -*)
      die "Unknown option: $1 (use --help)" ;;
    *)
      PATHS+=("$1"); shift ;;
  esac
done

[[ "$MIN_SIZE" =~ ^[1-9][0-9]*([KMGTP])?$ ]] || die "Invalid size '$MIN_SIZE'. Examples: 500M, 2G, 104857600"
[[ "$TOP_N" =~ ^[1-9][0-9]*$ ]] || die "--top must be a positive integer"
[[ "$SORT_ORDER" == asc || "$SORT_ORDER" == desc ]] || die "--sort must be asc or desc"

for cmd in find sort lsblk df awk; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command '$cmd'. Install findutils, coreutils, and util-linux."
done

(("${#PATHS[@]}" > 0)) || PATHS=(.)
for path in "${PATHS[@]}"; do
  [[ -d "$path" ]] || die "Search path is not a directory or does not exist: $path"
done

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/large-files-finder.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT INT TERM
RAW_FILE="$TMP_DIR/results.raw"
SORTED_FILE="$TMP_DIR/results.sorted"
ERROR_FILE="$TMP_DIR/find-errors.log"
: > "$RAW_FILE"
: > "$ERROR_FILE"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

human_size() {
  awk -v n="$1" 'BEGIN {
    split("B KiB MiB GiB TiB PiB",u," "); i=1
    while (n>=1024 && i<6) { n/=1024; i++ }
    printf "%.2f %s",n,u[i]
  }'
}

printf '%s%sLARGE FILES FINDER%s\n' "$BOLD" "$CYAN" "$RESET"
printf 'Scan started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf 'Search path(s):'
printf ' %q' "${PATHS[@]}"
printf '\nMinimum file size: %s | Results limit: %s | Sort: %s\n' "$MIN_SIZE" "$TOP_N" "$SORT_ORDER"

# ---------------------------------------------------------------------------
# SECTION 1 — Installed physical disks and mounted filesystem capacity
# ---------------------------------------------------------------------------
printf '\n%s%s[1] SYSTEM DRIVES & FILESYSTEMS%s\n' "$BOLD" "$GREEN" "$RESET"
printf '%s\n' 'Physical disks:'
if ! lsblk -dn -e 7 -o NAME,SIZE,MODEL,TRAN,TYPE 2>/dev/null | awk '$5=="disk" {printf "  /dev/%-12s %-10s %-28s %s\n",$1,$2,$3,$4; found=1} END {if (!found) print "  No physical disks detected."}'; then
  echo '  Unable to read block-device information.'
fi

printf '\nMounted filesystem usage (excluding temporary virtual filesystems):\n'
df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | awk 'NR==1 || NR>1 {print "  "$0}'

# ---------------------------------------------------------------------------
# SECTION 2 — Search and list files above the selected size threshold
# ---------------------------------------------------------------------------
printf '\n%s%s[2] LARGE FILES FOUND%s\n' "$BOLD" "$YELLOW" "$RESET"
printf 'Searching... This may take a while for large directory trees.\n'

for path in "${PATHS[@]}"; do
  find "$path" \
    \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \
    -type f -size "+$MIN_SIZE" -printf '%s\t%p\0' \
    >> "$RAW_FILE" 2>> "$ERROR_FILE" || true
done

if [[ "$SORT_ORDER" == desc ]]; then
  sort -z -t $'\t' -k1,1nr "$RAW_FILE" > "$SORTED_FILE"
else
  sort -z -t $'\t' -k1,1n "$RAW_FILE" > "$SORTED_FILE"
fi

TOTAL=$(tr -cd '\0' < "$SORTED_FILE" | wc -c | tr -d ' ')
printf 'Files matching threshold: %s\n\n' "$TOTAL"

if (( TOTAL == 0 )); then
  printf 'No files larger than %s were found in the selected path(s).\n' "$MIN_SIZE"
else
  printf '%-14s %s\n' 'FILE SIZE' 'FULL PATH'
  printf '%s\n' '--------------------------------------------------------------------------'
  shown=0
  while IFS= read -r -d '' record; do
    bytes=${record%%$'\t'*}
    file_path=${record#*$'\t'}
    printf '%-14s %s\n' "$(human_size "$bytes")" "$file_path"
    ((shown += 1))
    (( shown >= TOP_N )) && break
  done < "$SORTED_FILE"
  printf '\nDisplayed %s of %s matching files.\n' "$shown" "$TOTAL"
fi

if [[ -s "$ERROR_FILE" ]]; then
  error_count=$(wc -l < "$ERROR_FILE" | tr -d ' ')
  printf '\n%sWarning:%s %s filesystem access error(s) occurred. Some directories may not have been scanned. Run with sudo for broader access.\n' "$RED" "$RESET" "$error_count"
fi

printf '\nCompleted: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
