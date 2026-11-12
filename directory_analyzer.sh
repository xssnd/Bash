#!/usr/bin/env bash
#
# directory_analyzer.sh
# A read-only Linux directory and filesystem analyzer.
# Requires Bash 4+, GNU findutils, coreutils, and du.
#
# ============================================================================
# INSTALLATION
# ============================================================================
# Debian / Ubuntu:
#   sudo apt update && sudo apt install -y bash findutils coreutils
# Fedora / RHEL:
#   sudo dnf install -y bash findutils coreutils
# Arch Linux:
#   sudo pacman -S --needed bash findutils coreutils
#
# Download:
#   curl -fLO https://raw.githubusercontent.com/xssnd/Bash/main/directory_analyzer.sh
#   chmod +x directory_analyzer.sh
#   ./directory_analyzer.sh --help
#
# ============================================================================
# EXAMPLES
# ============================================================================
# Analyze current directory:
#   ./directory_analyzer.sh
#
# Analyze a specific location:
#   ./directory_analyzer.sh --path "$HOME"
#
# Show the 30 largest files and 15 largest subdirectories:
#   ./directory_analyzer.sh -p /var --top-files 30 --top-dirs 15
#
# Limit traversal depth:
#   ./directory_analyzer.sh -p "$HOME" --max-depth 3
#
# Skip cache and dependency directories:
#   ./directory_analyzer.sh -p "$HOME" --exclude "$HOME/.cache" \
#       --exclude "$HOME/.local/share/Trash" --exclude '*/node_modules'
#
# Export a report:
#   ./directory_analyzer.sh -p /data --output directory-report.txt
#
# Analyze one filesystem only:
#   sudo ./directory_analyzer.sh -p / --one-file-system
#
# SAFETY:
#   This tool is read-only. It does not delete, move, rename, or modify files.
#   Use permissions appropriate to the target directory; sudo is not normally
#   required for a home-directory scan.
#
# Version: 1.0.0 | License: MIT
#
set -uo pipefail

SCRIPT_NAME="directory_analyzer.sh"
VERSION="1.0.0"
SCAN_PATH="."
OUTPUT_FILE=""
MAX_DEPTH=""
TOP_FILES=10
TOP_DIRS=10
ONE_FILE_SYSTEM=false
FOLLOW_LINKS=false
NO_COLOR=false
EXCLUDES=()
START_TIME=$(date +%s)

if [[ -t 1 ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; CYAN=$'\033[36m'; WHITE=$'\033[1;37m'
else
  RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''
  BLUE=''; CYAN=''; WHITE=''
fi

banner() {
  printf '%b' "$CYAN$BOLD"
  cat <<'ART'
   ____ ___ ____  _____ ____ _____ ___  ______   __
  / ___|_ _|  _ \| ____|  _ \_   _/ _ \|  _ \ \ / /
  \___ \| || |_) |  _| | |_) || || | | | |_) \ V /
   ___) | ||  _ <| |___|  _ < | || |_| |  _ < | |
  |____/___|_| \_\_____|_| \_\_|  \___/|_| \_\|_|
ART
  printf '%b\n' "$RESET"
  printf '  %bDIRECTORY ANALYZER%b  %b v%s%b\n\n' "$WHITE$BOLD" "$RESET" "$DIM" "$VERSION" "$RESET"
}
line() { printf '  %b────────────────────────────────────────────────────────────%b\n' "$DIM" "$RESET"; }
info() { printf '  %b[INFO]%b %s\n' "$BLUE" "$RESET" "$1"; }
ok() { printf '  %b[ OK ]%b %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %b[WARN]%b %s\n' "$YELLOW" "$RESET" "$1"; }
err() { printf '  %b[ERROR]%b %s\n' "$RED" "$RESET" "$1" >&2; }

usage() {
  banner
  cat <<EOF
USAGE:
  ./$SCRIPT_NAME [OPTIONS]

OPTIONS:
  -p, --path PATH       Directory to analyze (default: .)
  -o, --output FILE     Export report to a text file
      --max-depth N     Limit directory traversal depth
      --top-files N     Number of largest files to show (default: 10)
      --top-dirs N      Number of largest subdirectories (default: 10)
  -e, --exclude PATH    Exclude path/pattern; repeatable
      --one-file-system Do not cross filesystem boundaries
      --follow-links    Follow symbolic links (use with care)
      --no-color        Disable terminal colors
  -h, --help            Show this help
  -v, --version         Show version

ANALYSIS INCLUDES:
  • File and directory counts, total regular-file size
  • Largest files and largest immediate subdirectories
  • File extension/type distribution
  • Empty files and empty directories
  • Hidden files, executable files, and symbolic links
  • World-writable files and directories (permission audit)
  • Oldest and newest file modification timestamps
  • Traversal errors and elapsed scan time

EXAMPLES:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --path "\$HOME"
  ./$SCRIPT_NAME -p /var --top-files 20 --top-dirs 10
  ./$SCRIPT_NAME -p "\$HOME" --max-depth 3
  ./$SCRIPT_NAME -p /data --exclude '*/node_modules' --output report.txt
  ./$SCRIPT_NAME -p / --one-file-system

NOTES:
  Symlinks are counted but not followed by default.
  --follow-links can encounter loops; use it only when needed.
  The scan is read-only. Permission errors may make totals incomplete.
EOF
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

while (($#)); do
  case "$1" in
    -p|--path) (($# >= 2)) || { err "Missing path value"; exit 1; }; SCAN_PATH=$2; shift 2 ;;
    -o|--output) (($# >= 2)) || { err "Missing output file"; exit 1; }; OUTPUT_FILE=$2; shift 2 ;;
    --max-depth) (($# >= 2)) || { err "Missing depth"; exit 1; }; MAX_DEPTH=$2; shift 2 ;;
    --top-files) (($# >= 2)) || { err "Missing count"; exit 1; }; TOP_FILES=$2; shift 2 ;;
    --top-dirs) (($# >= 2)) || { err "Missing count"; exit 1; }; TOP_DIRS=$2; shift 2 ;;
    -e|--exclude) (($# >= 2)) || { err "Missing exclude path"; exit 1; }; EXCLUDES+=("$2"); shift 2 ;;
    --one-file-system) ONE_FILE_SYSTEM=true; shift ;;
    --follow-links) FOLLOW_LINKS=true; shift ;;
    --no-color) NO_COLOR=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
    *) err "Unknown option: $1"; usage >&2; exit 1 ;;
  esac
done

[[ -z "$MAX_DEPTH" ]] || is_uint "$MAX_DEPTH" || { err "--max-depth must be a non-negative integer"; exit 1; }
is_uint "$TOP_FILES" && is_uint "$TOP_DIRS" || { err "--top-files and --top-dirs must be non-negative integers"; exit 1; }

if [[ "$NO_COLOR" == true || -n "${NO_COLOR:-}" ]]; then
  RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''
  BLUE=''; CYAN=''; WHITE=''
fi

[[ -d "$SCAN_PATH" ]] || { err "Directory does not exist: $SCAN_PATH"; exit 1; }
[[ -r "$SCAN_PATH" && -x "$SCAN_PATH" ]] || { err "Directory is not readable/searchable: $SCAN_PATH"; exit 1; }

for cmd in find stat du sort date; do
  command -v "$cmd" >/dev/null 2>&1 || { err "Required command not found: $cmd"; exit 1; }
done

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/directory-analyzer.XXXXXX") || { err "Cannot create temporary workspace"; exit 1; }
trap 'rm -rf -- "$TMP_DIR"' EXIT
trap 'printf "\n"; warn "Scan interrupted."; exit 130' INT TERM
ERRORS="$TMP_DIR/errors"
FILE_LIST="$TMP_DIR/files"
DIR_LIST="$TMP_DIR/dirs"
: > "$ERRORS"; : > "$FILE_LIST"; : > "$DIR_LIST"

FIND_ARGS=("$SCAN_PATH")
[[ "$FOLLOW_LINKS" == true ]] && FIND_ARGS=(-L "$SCAN_PATH")
[[ "$ONE_FILE_SYSTEM" == true ]] && FIND_ARGS+=(-xdev)
[[ -n "$MAX_DEPTH" ]] && FIND_ARGS+=(-maxdepth "$MAX_DEPTH")
if (("${#EXCLUDES[@]}")); then
  FIND_ARGS+=("(")
  first=true
  for pattern in "${EXCLUDES[@]}"; do
    [[ "$first" == true ]] || FIND_ARGS+=(-o)
    FIND_ARGS+=(-path "$pattern")
    first=false
  done
  FIND_ARGS+=(")" -prune -o)
fi

banner
line
info "Target       : $SCAN_PATH"
info "Max depth    : ${MAX_DEPTH:-unlimited}"
info "Top files    : $TOP_FILES"
info "Top dirs     : $TOP_DIRS"
info "Exclusions   : ${#EXCLUDES[@]}"
info "Symlinks     : $([[ "$FOLLOW_LINKS" == true ]] && printf 'follow' || printf 'do not follow')"
info "Mode         : read-only"
line
info "Scanning directory tree..."

# NUL-delimited lists keep filenames with whitespace/newlines safe.
find "${FIND_ARGS[@]}" -type f -print0 > "$FILE_LIST" 2>>"$ERRORS"
FIND_FILE_STATUS=$?
find "${FIND_ARGS[@]}" -mindepth 1 -type d -print0 > "$DIR_LIST" 2>>"$ERRORS"
FIND_DIR_STATUS=$?

FILE_COUNT=0
DIR_COUNT=0
EMPTY_FILES=0
EMPTY_DIRS=0
HIDDEN_COUNT=0
EXECUTABLE_COUNT=0
WORLD_WRITABLE=0
SYMLINK_COUNT=0
TOTAL_BYTES=0
LARGEST_SIZE=0
LARGEST_PATH=""
OLDEST_EPOCH=""
OLDEST_PATH=""
NEWEST_EPOCH=""
NEWEST_PATH=""
declare -A EXT_COUNTS=()
declare -a TOP_SIZE=()
declare -a TOP_PATH=()

format_bytes() {
  awk -v bytes="$1" 'BEGIN {
    split("B KiB MiB GiB TiB PiB",u," ");
    i=1; while (bytes>=1024 && i<6) {bytes/=1024; i++}
    printf "%.2f %s",bytes,u[i]
  }'
}

add_top_file() {
  local size="$1" path="$2" i inserted=false
  for ((i=0; i<${#TOP_SIZE[@]}; i++)); do
    if ((size > TOP_SIZE[i])); then
      TOP_SIZE=("${TOP_SIZE[@]:0:i}" "$size" "${TOP_SIZE[@]:i}")
      TOP_PATH=("${TOP_PATH[@]:0:i}" "$path" "${TOP_PATH[@]:i}")
      inserted=true
      break
    fi
  done
  if [[ "$inserted" == false ]]; then
    TOP_SIZE+=("$size"); TOP_PATH+=("$path")
  fi
  if ((${#TOP_SIZE[@]} > TOP_FILES)); then
    unset 'TOP_SIZE[-1]' 'TOP_PATH[-1]'
  fi
}

while IFS= read -r -d '' file; do
  ((FILE_COUNT += 1))
  size=$(stat -c '%s' -- "$file" 2>>"$ERRORS") || continue
  mtime=$(stat -c '%Y' -- "$file" 2>>"$ERRORS") || continue
  mode=$(stat -c '%A' -- "$file" 2>>"$ERRORS") || continue
  TOTAL_BYTES=$((TOTAL_BYTES + size))
  ((size == 0)) && ((EMPTY_FILES += 1))
  [[ "$file" == */.* || "$(basename -- "$file")" == .* ]] && ((HIDDEN_COUNT += 1))
  [[ -x "$file" ]] && ((EXECUTABLE_COUNT += 1))
  [[ "${mode:8:1}" == "w" ]] && ((WORLD_WRITABLE += 1))
  if ((size > LARGEST_SIZE)); then LARGEST_SIZE=$size; LARGEST_PATH=$file; fi
  add_top_file "$size" "$file"
  base=$(basename -- "$file")
  if [[ "$base" == *.* && "$base" != .* ]]; then
    ext=".\${base##*.}"
    ext="${ext,,}"
  else
    ext="[no extension]"
  fi
  EXT_COUNTS["$ext"]=$(( ${EXT_COUNTS["$ext"]:-0} + 1 ))
  if [[ -z "$OLDEST_EPOCH" || "$mtime" -lt "$OLDEST_EPOCH" ]]; then OLDEST_EPOCH=$mtime; OLDEST_PATH=$file; fi
  if [[ -z "$NEWEST_EPOCH" || "$mtime" -gt "$NEWEST_EPOCH" ]]; then NEWEST_EPOCH=$mtime; NEWEST_PATH=$file; fi
done < "$FILE_LIST"

while IFS= read -r -d '' dir; do
  ((DIR_COUNT += 1))
  [[ "$(basename -- "$dir")" == .* ]] && ((HIDDEN_COUNT += 1))
  dmode=$(stat -c '%A' -- "$dir" 2>>"$ERRORS") || dmode=""
  [[ "${dmode:8:1}" == "w" ]] && ((WORLD_WRITABLE += 1))
  [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>>"$ERRORS")" ]] && ((EMPTY_DIRS += 1))
done < "$DIR_LIST"

# Count symlinks separately (without following them).
SYMLINK_ARGS=("$SCAN_PATH")
[[ "$ONE_FILE_SYSTEM" == true ]] && SYMLINK_ARGS+=(-xdev)
[[ -n "$MAX_DEPTH" ]] && SYMLINK_ARGS+=(-maxdepth "$MAX_DEPTH")
find "${SYMLINK_ARGS[@]}" -type l -print0 2>>"$ERRORS" > "$TMP_DIR/links"
while IFS= read -r -d '' link; do ((SYMLINK_COUNT += 1)); done < "$TMP_DIR/links"

# Immediate child directory sizes (du reports apparent disk usage in bytes).
du -B1 -s -- "${SCAN_PATH%/}"/*/ 2>>"$ERRORS" | sort -rn > "$TMP_DIR/dir_sizes" || true

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
REPORT="$TMP_DIR/report"

{
  printf '\n'
  line
  printf '  %bDIRECTORY OVERVIEW%b\n' "$WHITE$BOLD" "$RESET"
  line
  printf '  Target path          : %q\n' "$SCAN_PATH"
  printf '  Regular files        : %d\n' "$FILE_COUNT"
  printf '  Directories          : %d\n' "$DIR_COUNT"
  printf '  Symbolic links       : %d\n' "$SYMLINK_COUNT"
  printf '  Total file size      : %s (%s bytes)\n' "$(format_bytes "$TOTAL_BYTES")" "$TOTAL_BYTES"
  printf '  Empty files          : %d\n' "$EMPTY_FILES"
  printf '  Empty directories    : %d\n' "$EMPTY_DIRS"
  printf '  Hidden entries       : %d\n' "$HIDDEN_COUNT"
  printf '  Executable files     : %d\n' "$EXECUTABLE_COUNT"
  printf '  World-writable items : %d\n' "$WORLD_WRITABLE"

  printf '\n  %bLARGEST FILES%b\n' "$WHITE$BOLD" "$RESET"
  line
  if ((${#TOP_SIZE[@]} == 0)); then printf '  No regular files found.\n'
  else
    for ((i=0; i<${#TOP_SIZE[@]}; i++)); do
      printf '  %3d. %10s  %q\n' "$((i+1))" "$(format_bytes "${TOP_SIZE[i]}")" "${TOP_PATH[i]}"
    done
  fi

  printf '\n  %bLARGEST IMMEDIATE SUBDIRECTORIES%b\n' "$WHITE$BOLD" "$RESET"
  line
  if [[ -s "$TMP_DIR/dir_sizes" ]]; then
    head -n "$TOP_DIRS" "$TMP_DIR/dir_sizes" | while IFS=$'\t' read -r bytes path; do
      printf '  %10s  %s\n' "$(format_bytes "$bytes")" "$path"
    done
  else
    printf '  No immediate child directories found (or glob had no matches).\n'
  fi

  printf '\n  %bFILE EXTENSION DISTRIBUTION%b\n' "$WHITE$BOLD" "$RESET"
  line
  for ext in "${!EXT_COUNTS[@]}"; do printf '%8d  %s\n' "${EXT_COUNTS[$ext]}" "$ext"; done | sort -rn | head -n 20

  printf '\n  %bMODIFICATION TIMESTAMPS%b\n' "$WHITE$BOLD" "$RESET"
  line
  [[ -n "$OLDEST_EPOCH" ]] && printf '  Oldest : %s  %q\n' "$(date -d "@$OLDEST_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$OLDEST_EPOCH")" "$OLDEST_PATH" || printf '  Oldest : N/A\n'
  [[ -n "$NEWEST_EPOCH" ]] && printf '  Newest : %s  %q\n' "$(date -d "@$NEWEST_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$NEWEST_EPOCH")" "$NEWEST_PATH" || printf '  Newest : N/A\n'

  if [[ -s "$ERRORS" ]]; then
    printf '\n  %bSCAN WARNINGS%b\n' "$YELLOW$BOLD" "$RESET"
    line
    cat "$ERRORS"
  fi
  printf '\n'
  line
  printf '  Scan duration : %s seconds\n' "$DURATION"
  printf '  Generated     : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  line
} > "$REPORT"

cat "$REPORT"
if [[ -n "$OUTPUT_FILE" ]]; then
  if cp -- "$REPORT" "$OUTPUT_FILE"; then ok "Report exported to: $OUTPUT_FILE"; else err "Could not write report: $OUTPUT_FILE"; exit 1; fi
fi

if ((FIND_FILE_STATUS != 0 || FIND_DIR_STATUS != 0)); then
  warn "Scan finished with traversal errors; results may be incomplete."
  exit 2
fi
ok "Analysis completed."
exit 0
