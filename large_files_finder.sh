#!/usr/bin/env bash
# =============================================================================
# large_files_finder.sh — Linux disk overview and large-file auditor
# =============================================================================
# INSTALLATION
#   Debian/Ubuntu: sudo apt update && sudo apt install -y bash findutils coreutils util-linux python3
#   Fedora/RHEL:   sudo dnf install -y bash findutils coreutils util-linux python3
#   Arch Linux:    sudo pacman -S --needed bash findutils coreutils util-linux python
#
#   chmod +x large_files_finder.sh
#
# USAGE
#   ./large_files_finder.sh [OPTIONS] [PATH ...]
#   ./large_files_finder.sh --select-drives
#   sudo ./large_files_finder.sh --select-drives --min-size 500M
#
# OPTIONS
#   -s, --min-size SIZE       Minimum size (default 100M; e.g. 500M, 2G)
#   -n, --top N               Maximum displayed files (default 50; 0 = all)
#       --sort asc|desc       Sort by size (default desc)
#       --exclude PATH        Exclude a directory; repeatable
#       --select-drives       Interactively choose mounted filesystems to scan
#       --older-than DAYS     Only files not modified in the last DAYS days
#       --duplicates          Find duplicate files by SHA-256 (can take time)
#       --report FORMAT       Save report: csv, json, or html
#       --output FILE         Report destination (default large-files-report.FORMAT)
#   -h, --help                Show help
#
# EXAMPLES
#   ./large_files_finder.sh ~/Downloads
#   sudo ./large_files_finder.sh /home /var --min-size 500M
#   ./large_files_finder.sh --exclude ~/Downloads/cache --exclude /home/user/.cache /
#   ./large_files_finder.sh --older-than 90 --duplicates /home
#   sudo ./large_files_finder.sh --select-drives --report html
#   ./large_files_finder.sh --min-size 1G --report json --output /tmp/large.json /
#
# OVERVIEW
#   [1] Physical disks and mounted filesystem capacity.
#   [2] Matching files with sizes and full paths.
#   Optional duplicate analysis and machine-readable/HTML reports.
#
# NOTES
#   - Requires Bash 4+, GNU find/sort, lsblk, df, findmnt, and Python 3.
#   - Use sudo for broader access. Permission errors are reported at the end.
#   - /proc, /sys, /dev, and /run are always excluded from traversal.
#   - The script does not modify, move, or delete scanned files.
#   - --older-than uses file modification time; size comparison is strictly greater.
# =============================================================================
set -Eeuo pipefail
export LC_ALL=C

MIN_SIZE=100M
TOP_N=50
SORT_ORDER=desc
OLDER_THAN=""
REPORT_FORMAT=""
REPORT_FILE=""
DO_DUPLICATES=0
SELECT_DRIVES=0
PATHS=()
EXCLUDES=()

usage() { sed -n '1,55p' "$0" | sed 's/^#\?//' | sed 's/^ //'; }
die() { printf 'Error: %s\n' "$*" >&2; exit 2; }

while (($#)); do
  case "$1" in
    -s|--min-size) (($# >= 2)) || die "$1 requires a value"; MIN_SIZE=$2; shift 2 ;;
    --min-size=*) MIN_SIZE=${1#*=}; shift ;;
    -n|--top) (($# >= 2)) || die "$1 requires a value"; TOP_N=$2; shift 2 ;;
    --top=*) TOP_N=${1#*=}; shift ;;
    --sort) (($# >= 2)) || die "$1 requires a value"; SORT_ORDER=$2; shift 2 ;;
    --sort=*) SORT_ORDER=${1#*=}; shift ;;
    --exclude) (($# >= 2)) || die "$1 requires a path"; EXCLUDES+=("$2"); shift 2 ;;
    --exclude=*) EXCLUDES+=("${1#*=}"); shift ;;
    --older-than) (($# >= 2)) || die "$1 requires days"; OLDER_THAN=$2; shift 2 ;;
    --older-than=*) OLDER_THAN=${1#*=}; shift ;;
    --duplicates) DO_DUPLICATES=1; shift ;;
    --select-drives) SELECT_DRIVES=1; shift ;;
    --report) (($# >= 2)) || die "$1 requires csv, json, or html"; REPORT_FORMAT=$2; shift 2 ;;
    --report=*) REPORT_FORMAT=${1#*=}; shift ;;
    --output) (($# >= 2)) || die "$1 requires a file path"; REPORT_FILE=$2; shift 2 ;;
    --output=*) REPORT_FILE=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while (($#)); do PATHS+=("$1"); shift; done ;;
    -*) die "Unknown option: $1 (use --help)" ;;
    *) PATHS+=("$1"); shift ;;
  esac
done

[[ "$MIN_SIZE" =~ ^[1-9][0-9]*([KMGTP])?$ ]] || die "Invalid size '$MIN_SIZE' (examples: 500M, 2G, 104857600)"
[[ "$TOP_N" =~ ^(0|[1-9][0-9]*)$ ]] || die "--top must be zero or a positive integer"
[[ "$SORT_ORDER" == asc || "$SORT_ORDER" == desc ]] || die "--sort must be asc or desc"
[[ -z "$OLDER_THAN" || "$OLDER_THAN" =~ ^[0-9]+$ ]] || die "--older-than must be a non-negative number of days"
[[ -z "$REPORT_FORMAT" || "$REPORT_FORMAT" =~ ^(csv|json|html)$ ]] || die "--report must be csv, json, or html"
[[ -z "$REPORT_FILE" || -n "$REPORT_FORMAT" ]] || die "--output requires --report"

for cmd in find sort lsblk df awk findmnt python3 sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command '$cmd'. Install findutils, coreutils, util-linux, and python3."
done

if (( SELECT_DRIVES )); then
  [[ -t 0 ]] || die "--select-drives requires an interactive terminal"
  mapfile -t MOUNTS < <(findmnt -rn -o TARGET -t ext4,xfs,btrfs,vfat,exfat,ntfs,ntfs3,fuseblk 2>/dev/null | sort -u)
  (("${#MOUNTS[@]}" > 0)) || die "No mounted data filesystems found."
  printf 'Mounted filesystems available to scan:\n'
  for i in "${!MOUNTS[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${MOUNTS[$i]}"; done
  printf 'Enter drive numbers separated by spaces (or "all"): '
  read -r selection
  if [[ "$selection" == all ]]; then
    PATHS=("${MOUNTS[@]}")
  else
    read -r -a picks <<< "$selection"
    for pick in "${picks[@]}"; do
      [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#MOUNTS[@]} )) || die "Invalid drive number: $pick"
      PATHS+=("${MOUNTS[$((pick-1))]}")
    done
    (("${#PATHS[@]}" > 0)) || die "No drives selected."
  fi
fi
(("${#PATHS[@]}" > 0)) || PATHS=(.)
for path in "${PATHS[@]}"; do [[ -d "$path" ]] || die "Search path is not a directory or does not exist: $path"; done
for path in "${EXCLUDES[@]}"; do [[ -d "$path" ]] || die "Excluded directory does not exist: $path"; done

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/large-files-finder.XXXXXX")
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
RAW_FILE="$TMP_DIR/results.raw"
SORTED_FILE="$TMP_DIR/results.sorted"
ERROR_FILE="$TMP_DIR/find-errors.log"
: > "$RAW_FILE"; : > "$ERROR_FILE"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

human_size() {
  awk -v n="$1" 'BEGIN { split("B KiB MiB GiB TiB PiB",u," "); i=1; while(n>=1024&&i<6){n/=1024;i++}; printf "%.2f %s",n,u[i] }'
}

printf '%s%sLARGE FILES FINDER%s\n' "$BOLD" "$CYAN" "$RESET"
printf 'Started: %s\nPaths:' "$(date '+%F %T')"
printf ' %q' "${PATHS[@]}"
printf '\nThreshold: %s | Limit: %s | Sort: %s' "$MIN_SIZE" "${TOP_N:-all}" "$SORT_ORDER"
[[ -n "$OLDER_THAN" ]] && printf ' | Older than: %s days' "$OLDER_THAN"
printf '\n'

# SECTION 1 — drive inventory
printf '\n%s%s[1] SYSTEM DRIVES & FILESYSTEMS%s\n' "$BOLD" "$GREEN" "$RESET"
printf 'Physical disks:\n'
lsblk -dn -e 7 -o NAME,SIZE,MODEL,TRAN,TYPE 2>/dev/null |
  awk '$5=="disk"{printf "  /dev/%-12s %-10s %-28s %s\n",$1,$2,$3,$4;found=1} END{if(!found)print "  No physical disks detected."}'
printf '\nMounted filesystem usage:\n'
df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || true

# SECTION 2 — scan in background and show a spinner when attached to a terminal
printf '\n%s%s[2] LARGE FILES FOUND%s\n' "$BOLD" "$YELLOW" "$RESET"
scan_files() {
  local path
  for path in "${PATHS[@]}"; do
    local -a prune=( -path /proc -o -path /sys -o -path /dev -o -path /run )
    local ex
    for ex in "${EXCLUDES[@]}"; do prune+=( -o -path "$ex" ); done
    if [[ -n "$OLDER_THAN" ]]; then
      find "$path" \( "${prune[@]}" \) -prune -o -type f -size "+$MIN_SIZE" -mtime "+$OLDER_THAN" -printf '%s\t%p\0' >> "$RAW_FILE" 2>> "$ERROR_FILE" || true
    else
      find "$path" \( "${prune[@]}" \) -prune -o -type f -size "+$MIN_SIZE" -printf '%s\t%p\0' >> "$RAW_FILE" 2>> "$ERROR_FILE" || true
    fi
  done
}
scan_files &
SCAN_PID=$!
if [[ -t 1 ]]; then
  spin='|/-\\'; i=0
  while kill -0 "$SCAN_PID" 2>/dev/null; do
    printf '\rScanning files... %s' "${spin:i++%4:1}"
    sleep 0.15
  done
  wait "$SCAN_PID" || true
  printf '\rScan finished.                 \n'
else
  printf 'Scanning files...\n'
  wait "$SCAN_PID" || true
fi

if [[ "$SORT_ORDER" == desc ]]; then sort -z -t $'\t' -k1,1nr "$RAW_FILE" > "$SORTED_FILE"
else sort -z -t $'\t' -k1,1n "$RAW_FILE" > "$SORTED_FILE"; fi
TOTAL=$(python3 -c 'import sys; print(open(sys.argv[1],"rb").read().count(b"\\0"))' "$SORTED_FILE")
printf 'Matching files: %s\n\n' "$TOTAL"

printf '%-14s %s\n' 'FILE SIZE' 'FULL PATH'
printf '%s\n' '--------------------------------------------------------------------------'
shown=0
while IFS= read -r -d '' record; do
  bytes=${record%%$'\t'*}; file_path=${record#*$'\t'}
  printf '%-14s %s\n' "$(human_size "$bytes")" "$file_path"
  ((shown+=1))
  if (( TOP_N > 0 && shown >= TOP_N )); then break; fi
done < "$SORTED_FILE"
printf '\nDisplayed %s of %s matching files.\n' "$shown" "$TOTAL"

# Optional duplicate detection and reports use Python for safe path/JSON/HTML handling.
if (( DO_DUPLICATES )) || [[ -n "$REPORT_FORMAT" ]]; then
  REPORT_FILE=${REPORT_FILE:-"large-files-report.$REPORT_FORMAT"}
  python3 - "$SORTED_FILE" "$REPORT_FORMAT" "$REPORT_FILE" "$DO_DUPLICATES" "$TOP_N" <<'PY'
import csv, hashlib, html, json, os, sys
source, fmt, report, duplicates, limit = sys.argv[1:]
limit = int(limit)
rows = []
with open(source, "rb") as f:
    for item in f.read().split(b"\0"):
        if not item:
            continue
        size, path = item.split(b"\t", 1)
        rows.append({"size_bytes": int(size), "path": os.fsdecode(path)})
shown = rows if limit == 0 else rows[:limit]

if duplicates == "1":
    print("\nDuplicate detection (SHA-256):")
    groups = {}
    for row in rows:
        try:
            h = hashlib.sha256()
            with open(row["path"], "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
            groups.setdefault((row["size_bytes"], h.hexdigest()), []).append(row["path"])
        except (OSError, PermissionError) as e:
            print(f"  Could not hash {row['path']}: {e}", file=sys.stderr)
    found = 0
    for (size, digest), paths in groups.items():
        if len(paths) > 1:
            found += 1
            print(f"  {len(paths)} identical files ({size} bytes; SHA-256 {digest[:16]}…)")
            for path in paths:
                print(f"    {path}")
    if not found:
        print("  No duplicate files found among matching files.")

if fmt:
    os.makedirs(os.path.dirname(os.path.abspath(report)), exist_ok=True)
    if fmt == "csv":
        with open(report, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["size_bytes", "path"])
            w.writeheader(); w.writerows(rows)
    elif fmt == "json":
        with open(report, "w", encoding="utf-8") as f:
            json.dump({"total_matches": len(rows), "files": rows}, f, ensure_ascii=False, indent=2)
            f.write("\n")
    elif fmt == "html":
        with open(report, "w", encoding="utf-8") as f:
            f.write("<!doctype html><html><head><meta charset='utf-8'><title>Large files report</title>")
            f.write("<style>body{font:14px sans-serif;margin:2rem}table{border-collapse:collapse;width:100%}th,td{padding:.5rem;border:1px solid #ccc;text-align:left}th{background:#eee}</style></head><body>")
            f.write(f"<h1>Large files report</h1><p>{len(rows)} matching files</p><table><tr><th>Size (bytes)</th><th>Full path</th></tr>")
            for r in rows:
                f.write(f"<tr><td>{r['size_bytes']}</td><td>{html.escape(r['path'])}</td></tr>")
            f.write("</table></body></html>\n")
    print(f"\nReport saved: {report}")
PY
fi

if [[ -s "$ERROR_FILE" ]]; then
  errors=$(wc -l < "$ERROR_FILE" | tr -d ' ')
  printf '\n%sWarning:%s %s access error(s) occurred; some paths may not have been scanned. Try sudo for broader access.\n' "$RED" "$RESET" "$errors"
fi
printf '\nCompleted: %s\n' "$(date '+%F %T')"
