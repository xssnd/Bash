#!/usr/bin/env bash
#
# duplicate_files.sh
# Find duplicate files by content using SHA-256.
# Requires Bash 4+, GNU findutils, coreutils (sha256sum, stat, sort).
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
#   curl -fLO https://raw.githubusercontent.com/xssnd/Bash/main/duplicate_files.sh
#   chmod +x duplicate_files.sh
#   ./duplicate_files.sh --help
#
# Or clone the repository:
#   git clone https://github.com/xssnd/Bash.git
#   cd Bash
#   chmod +x duplicate_files.sh
#
# ============================================================================
# USAGE EXAMPLES
# ============================================================================
# Scan current directory:
#   ./duplicate_files.sh
#
# Scan home directory:
#   ./duplicate_files.sh --path "$HOME"
#
# Scan a directory and export a report:
#   ./duplicate_files.sh --path /data --output duplicates.txt
#
# Ignore common cache / dependency directories:
#   ./duplicate_files.sh --path "$HOME" --exclude "$HOME/.cache" \
#       --exclude "$HOME/.local/share/Trash"
#
# Only consider files at least 1 MiB:
#   ./duplicate_files.sh --path /data --min-size 1M
#
# Do not cross mount points:
#   sudo ./duplicate_files.sh --path / --one-file-system
#
# Review duplicate groups interactively (no deletion unless confirmed):
#   ./duplicate_files.sh --path "$HOME" --interactive
#
# NOTES:
# - Files are considered duplicates only when their SHA-256 content hashes
#   match. File names and paths do not determine duplication.
# - Size filtering is used first to reduce hashing work.
# - Symlinks are not followed. The scan is read-only unless --interactive
#   is selected and you explicitly confirm removal of a duplicate.
# - Keep backups. The interactive removal option permanently unlinks files.
#
# Version: 1.0.0 | License: MIT
#
set -uo pipefail

SCRIPT_NAME="duplicate_files.sh"
VERSION="1.0.0"
SCAN_PATH="."
OUTPUT_FILE=""
MIN_SIZE=0
ONE_FILE_SYSTEM=false
INTERACTIVE=false
NO_COLOR=false
EXCLUDES=()

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
   ____  _   _ ____  _     ___ ____    _    _____ _____
  |  _ \| | | |  _ \| |   |_ _|  _ \  / \  |_   _| ____|
  | | | | | | | |_) | |    | || |_) |/ _ \   | | |  _|
  | |_| | |_| |  __/| |___ | ||  __// ___ \  | | | |___
  |____/ \___/|_|   |_____|___|_|  /_/   \_\ |_| |_____|
ART
  printf '%b\n' "$RESET"
  printf '  %bDUPLICATE FILES FINDER%b  %b v%s%b\n\n' "$WHITE$BOLD" "$RESET" "$DIM" "$VERSION" "$RESET"
}
line() { printf '  %b────────────────────────────────────────────────────────%b\n' "$DIM" "$RESET"; }
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
  -p, --path PATH       Directory to scan (default: .)
  -e, --exclude PATH    Exclude path; repeatable
      --min-size SIZE   Ignore smaller files (e.g. 1K, 10M, 1G)
  -o, --output FILE     Save a text report
      --one-file-system Do not cross filesystem boundaries
  -i, --interactive     Review groups; optionally remove duplicates
      --no-color        Disable colors
  -h, --help            Show help
  -v, --version         Show version

EXAMPLES:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --path "\$HOME"
  ./$SCRIPT_NAME -p /data -o duplicates.txt
  ./$SCRIPT_NAME -p /home --min-size 1M
  ./$SCRIPT_NAME -p / --exclude /proc --exclude /sys --one-file-system
  ./$SCRIPT_NAME -p "\$HOME" --interactive

Duplicate detection uses SHA-256 content hashes. No files are removed
unless you explicitly use --interactive and confirm a removal.
EOF
}

parse_size() {
  local value="${1^^}" number suffix multiplier
  if [[ "$value" =~ ^([0-9]+)(B|K|KB|M|MB|G|GB|T|TB)?$ ]]; then
    number=${BASH_REMATCH[1]}; suffix=${BASH_REMATCH[2]:-B}
    case "$suffix" in
      B) multiplier=1 ;; K|KB) multiplier=1024 ;;
      M|MB) multiplier=$((1024**2)) ;; G|GB) multiplier=$((1024**3)) ;;
      T|TB) multiplier=$((1024**4)) ;;
    esac
    printf '%s' "$((number * multiplier))"
  else
    return 1
  fi
}

while (($#)); do
  case "$1" in
    -p|--path) (($# >= 2)) || { err "Missing path"; exit 1; }; SCAN_PATH=$2; shift 2 ;;
    -e|--exclude) (($# >= 2)) || { err "Missing exclude path"; exit 1; }; EXCLUDES+=("$2"); shift 2 ;;
    --min-size) (($# >= 2)) || { err "Missing size"; exit 1; }; MIN_SIZE=$(parse_size "$2") || { err "Invalid size: $2"; exit 1; }; shift 2 ;;
    -o|--output) (($# >= 2)) || { err "Missing output file"; exit 1; }; OUTPUT_FILE=$2; shift 2 ;;
    --one-file-system) ONE_FILE_SYSTEM=true; shift ;;
    -i|--interactive) INTERACTIVE=true; shift ;;
    --no-color) NO_COLOR=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
    *) err "Unknown option: $1"; usage >&2; exit 1 ;;
  esac
done

if [[ "$NO_COLOR" == true || -n "${NO_COLOR:-}" ]]; then
  RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''
  BLUE=''; CYAN=''; WHITE=''
fi

[[ -d "$SCAN_PATH" ]] || { err "Directory does not exist: $SCAN_PATH"; exit 1; }
[[ -r "$SCAN_PATH" && -x "$SCAN_PATH" ]] || { err "Directory is not readable/searchable: $SCAN_PATH"; exit 1; }
for cmd in find sort sha256sum stat; do
  command -v "$cmd" >/dev/null 2>&1 || { err "Required command missing: $cmd"; exit 1; }
done

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/duplicate-finder.XXXXXX") || { err "Cannot create temporary directory"; exit 1; }
trap 'rm -rf -- "$TMP_DIR"' EXIT
trap 'printf "\n"; warn "Interrupted."; exit 130' INT TERM
CANDIDATES="$TMP_DIR/candidates"
ERRORS="$TMP_DIR/errors"
RECORDS="$TMP_DIR/records"
: > "$CANDIDATES"; : > "$ERRORS"; : > "$RECORDS"

FIND_ARGS=("$SCAN_PATH")
[[ "$ONE_FILE_SYSTEM" == true ]] && FIND_ARGS+=(-xdev)
if (("${#EXCLUDES[@]}" > 0)); then
  FIND_ARGS+=("(")
  first=true
  for excluded in "${EXCLUDES[@]}"; do
    [[ "$first" == true ]] || FIND_ARGS+=(-o)
    FIND_ARGS+=(-path "$excluded")
    first=false
  done
  FIND_ARGS+=(")" -prune -o)
fi
FIND_ARGS+=(-type f)
if ((MIN_SIZE > 0)); then
  FIND_ARGS+=(-size +"$((MIN_SIZE - 1))"c)
fi
FIND_ARGS+=(-print0)

banner
line
info "Path      : $SCAN_PATH"
info "Algorithm : SHA-256"
info "Min size  : $MIN_SIZE bytes"
info "Exclusions: ${#EXCLUDES[@]}"
[[ "$ONE_FILE_SYSTEM" == true ]] && info "Filesystem: one filesystem only"
line
info "Collecting candidate files..."

find "${FIND_ARGS[@]}" 2>"$ERRORS" > "$CANDIDATES"
FIND_STATUS=$?

declare -A SIZE_COUNTS=()
declare -A HASH_COUNTS=()
declare -A HASH_FIRST=()
declare -A HASH_BYTES=()
FILE_COUNT=0
HASHED_COUNT=0
DUP_GROUPS=0
DUP_FILES=0
RECLAIMABLE=0
HASH_FAILURES=0

# First pass: count file sizes. Only same-size files can be duplicates.
while IFS= read -r -d '' file; do
  ((FILE_COUNT += 1))
  size=$(stat -c '%s' -- "$file" 2>>"$ERRORS") || continue
  SIZE_COUNTS["$size"]=$(( ${SIZE_COUNTS["$size"]:-0} + 1 ))
done < "$CANDIDATES"

info "Candidate files: $FILE_COUNT"
info "Hashing files in matching-size groups..."

# Second pass: hash only files whose size occurs more than once.
while IFS= read -r -d '' file; do
  size=$(stat -c '%s' -- "$file" 2>>"$ERRORS") || continue
  (( ${SIZE_COUNTS["$size"]:-0} > 1 )) || continue
  hash=$(sha256sum < "$file" 2>>"$ERRORS") || { ((HASH_FAILURES += 1)); continue; }
  hash=${hash%% *}
  ((HASHED_COUNT += 1))
  if [[ -z "${HASH_COUNTS[$hash]+x}" ]]; then
    HASH_FIRST["$hash"]="$file"
    HASH_COUNTS["$hash"]=1
    HASH_BYTES["$hash"]=$size
  else
    HASH_COUNTS["$hash"]=$((HASH_COUNTS["$hash"] + 1))
  fi
  printf '%s\0%s\0' "$hash" "$file" >> "$RECORDS"
done < "$CANDIDATES"

# Create readable report; %q safely represents whitespace and special chars.
REPORT="$TMP_DIR/report"
{
  printf '\n'
  line
  printf '  %bDUPLICATE SCAN SUMMARY%b\n' "$WHITE$BOLD" "$RESET"
  line
  printf '  Files discovered : %d\n' "$FILE_COUNT"
  printf '  Files hashed     : %d\n' "$HASHED_COUNT"
  for hash in "${!HASH_COUNTS[@]}"; do
    count=${HASH_COUNTS[$hash]}
    if ((count > 1)); then
      ((DUP_GROUPS += 1))
      ((DUP_FILES += count))
      RECLAIMABLE=$((RECLAIMABLE + HASH_BYTES[$hash] * (count - 1)))
    fi
  done
  printf '  Duplicate groups : %d\n' "$DUP_GROUPS"
  printf '  Duplicate files  : %d\n' "$DUP_FILES"
  printf '  Potential savings: %s bytes (one copy retained per group)\n' "$RECLAIMABLE"
  printf '\n'
  if ((DUP_GROUPS == 0)); then
    printf '  %bNo duplicate files found.%b\n' "$GREEN" "$RESET"
  else
    printf '  %bDUPLICATE GROUPS%b\n' "$WHITE$BOLD" "$RESET"
    line
    group=0
    for hash in "${!HASH_COUNTS[@]}"; do
      count=${HASH_COUNTS[$hash]}
      ((count > 1)) || continue
      ((group += 1))
      printf '\n  %b[GROUP %d]%b %d files | %s bytes each | SHA256 %s\n' "$CYAN$BOLD" "$group" "$RESET" "$count" "${HASH_BYTES[$hash]}" "$hash"
      while IFS= read -r -d '' record_hash && IFS= read -r -d '' record_path; do
        [[ "$record_hash" == "$hash" ]] && printf '    %q\n' "$record_path"
      done < "$RECORDS"
    done
  fi
  if [[ -s "$ERRORS" ]]; then
    printf '\n  %bSCAN WARNINGS%b\n' "$YELLOW$BOLD" "$RESET"
    line
    cat "$ERRORS"
  fi
  line
} > "$REPORT"

# Recompute group count from the report summary variables, then display.
cat "$REPORT"

if [[ -n "$OUTPUT_FILE" ]]; then
  if cp -- "$REPORT" "$OUTPUT_FILE"; then ok "Report saved: $OUTPUT_FILE"; else err "Cannot write report: $OUTPUT_FILE"; exit 1; fi
fi

if [[ "$INTERACTIVE" == true && "$DUP_GROUPS" -gt 0 ]]; then
  printf '\n%bINTERACTIVE REVIEW%b\n' "$WHITE$BOLD" "$RESET"
  warn "For each group, the first discovered file is kept. Other matching files may be removed."
  for hash in "${!HASH_COUNTS[@]}"; do
    count=${HASH_COUNTS[$hash]}
    ((count > 1)) || continue
    printf '\nGroup: %s (%d files)\n' "$hash" "$count"
    printf 'KEEP: %q\n' "${HASH_FIRST[$hash]}"
    while IFS= read -r -d '' record_hash && IFS= read -r -d '' record_path; do
      [[ "$record_hash" == "$hash" ]] || continue
      [[ "$record_path" == "${HASH_FIRST[$hash]}" ]] && continue
      printf 'Duplicate candidate: %q\n' "$record_path"
      read -r -p "Remove this duplicate? [y/N] " answer
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        if rm -i -- "$record_path"; then ok "Removal command completed."; else warn "Could not remove file."; fi
      fi
    done < "$RECORDS"
  done
fi

((HASH_FAILURES > 0)) && warn "$HASH_FAILURES file(s) could not be hashed."
if ((FIND_STATUS != 0)); then warn "Scan completed with traversal errors."; exit 2; fi
ok "Scan completed."
exit 0
