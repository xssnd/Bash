#!/usr/bin/env bash
#
# empty_files_finder.sh
# Modern, read-only empty file and directory scanner for Linux.
# Requires Bash 4+ and GNU findutils/coreutils.
#
# Version: 1.0.1
# License: MIT
#

set -uo pipefail

SCRIPT_NAME="empty_files_finder.sh"
VERSION="1.0.1"

SCAN_PATH="."
SCAN_TYPE="both"
OUTPUT_FILE=""
NO_COLOR=false
ONE_FILE_SYSTEM=false
EXCLUDES=()

START_TIME=$(date +%s)

# ---------------------------------------------------------------------------
# Terminal colors (only when stdout is a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RESET=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    CYAN=$'\033[36m'
    WHITE=$'\033[1;37m'
else
    RESET='' BOLD='' DIM='' RED='' GREEN='' YELLOW=''
    BLUE='' CYAN='' WHITE=''
fi

print_banner() {
    printf '\n%b' "$CYAN$BOLD"
    cat <<'BANNER'
  ███████╗███╗   ███╗██████╗ ████████╗██╗   ██╗
  ██╔════╝████╗ ████║██╔══██╗╚══██╔══╝╚██╗ ██╔╝
  █████╗  ██╔████╔██║██████╔╝   ██║    ╚████╔╝
  ██╔══╝  ██║╚██╔╝██║██╔═══╝    ██║     ╚██╔╝
  ██║     ██║ ╚═╝ ██║██║        ██║      ██║
  ╚═╝     ╚═╝     ╚═╝╚═╝        ╚═╝      ╚═╝
BANNER
    printf '%b\n' "$RESET"
    printf '  %bEMPTY FILES FINDER%b\n' "$WHITE$BOLD" "$RESET"
    printf '  %bLinux System Administration Utility | v%s%b\n\n' "$DIM" "$VERSION" "$RESET"
}

line() { printf '  %b────────────────────────────────────────────────%b\n' "$DIM" "$RESET"; }
info() { printf '  %b[INFO]%b %s\n' "$BLUE" "$RESET" "$1"; }
success() { printf '  %b[ OK ]%b %s\n' "$GREEN" "$RESET" "$1"; }
warning() { printf '  %b[WARN]%b %s\n' "$YELLOW" "$RESET" "$1"; }
error() { printf '  %b[ERROR]%b %s\n' "$RED" "$RESET" "$1" >&2; }

usage() {
    print_banner
    cat <<EOF
USAGE:
  ./$SCRIPT_NAME [OPTIONS]

OPTIONS:
  -p, --path PATH       Root directory to scan (default: .)
  -t, --type TYPE       files | dirs | both (default: both)
  -e, --exclude PATH    Exclude path; may be repeated
  -o, --output FILE     Save a text report
      --one-file-system Do not cross filesystem boundaries
      --no-color        Disable terminal colors
  -h, --help            Show this help
  -v, --version         Show version

EXAMPLES:
  ./$SCRIPT_NAME
  ./$SCRIPT_NAME --path "\$HOME"
  ./$SCRIPT_NAME -p /var/log -t files
  ./$SCRIPT_NAME -p /home -t dirs
  ./$SCRIPT_NAME -p / --exclude /proc --exclude /sys
  ./$SCRIPT_NAME -p /home -o empty-report.txt
  ./$SCRIPT_NAME -p / --one-file-system

DEFINITIONS:
  Empty file      Regular file with size exactly 0 bytes.
  Empty directory Directory containing no entries, including hidden entries.

NOTES:
  Recursive scan; symbolic links are not followed.
  Names containing spaces or unusual characters are handled safely.
  No files or directories are deleted or modified.
  Permission and traversal errors are reported.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while (($#)); do
    case "$1" in
        -p|--path)
            (($# >= 2)) || { error "Missing value for $1"; exit 1; }
            SCAN_PATH=$2; shift 2 ;;
        -t|--type)
            (($# >= 2)) || { error "Missing value for $1"; exit 1; }
            SCAN_TYPE=$2; shift 2 ;;
        -e|--exclude)
            (($# >= 2)) || { error "Missing value for $1"; exit 1; }
            EXCLUDES+=("$2"); shift 2 ;;
        -o|--output)
            (($# >= 2)) || { error "Missing value for $1"; exit 1; }
            OUTPUT_FILE=$2; shift 2 ;;
        --one-file-system) ONE_FILE_SYSTEM=true; shift ;;
        --no-color) NO_COLOR=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -v|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
        *) error "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
done

if [[ "$NO_COLOR" == true || -n "\${NO_COLOR:-}" ]]; then
    RESET='' BOLD='' DIM='' RED='' GREEN='' YELLOW=''
    BLUE='' CYAN='' WHITE=''
fi

case "$SCAN_TYPE" in
    files|dirs|both) ;;
    *) error "Invalid type '$SCAN_TYPE'; use files, dirs, or both."; exit 1 ;;
esac

if [[ ! -d "$SCAN_PATH" ]]; then
    error "Directory does not exist: $SCAN_PATH"
    exit 1
fi
if [[ ! -r "$SCAN_PATH" || ! -x "$SCAN_PATH" ]]; then
    error "Directory is not readable/searchable: $SCAN_PATH"
    exit 1
fi
command -v find >/dev/null 2>&1 || { error "Required command not found: find"; exit 1; }
command -v sort >/dev/null 2>&1 || { error "Required command not found: sort"; exit 1; }

# ---------------------------------------------------------------------------
# Temporary workspace and signal handling
# ---------------------------------------------------------------------------
TEMP_DIR=$(mktemp -d "\${TMPDIR:-/tmp}/empty-finder.XXXXXX") || {
    error "Unable to create temporary workspace."
    exit 1
}
RESULT_FILE="$TEMP_DIR/results"
ERROR_FILE="$TEMP_DIR/errors"
REPORT_FILE="$TEMP_DIR/report"

cleanup() { rm -rf -- "$TEMP_DIR"; }
interrupted() {
    printf '\n'
    warning "Scan interrupted; partial results are discarded."
    exit 130
}
trap cleanup EXIT
trap interrupted INT TERM

# ---------------------------------------------------------------------------
# Build find expression. -prune prevents descending into excluded paths.
# ---------------------------------------------------------------------------
FIND_ARGS=("$SCAN_PATH")
[[ "$ONE_FILE_SYSTEM" == true ]] && FIND_ARGS+=(-xdev)

if (("\${#EXCLUDES[@]}" > 0)); then
    FIND_ARGS+=("(")
    first=true
    for excluded in "\${EXCLUDES[@]}"; do
        if [[ "$first" == false ]]; then FIND_ARGS+=(-o); fi
        FIND_ARGS+=(-path "$excluded")
        first=false
    done
    FIND_ARGS+=(")" -prune -o)
fi

case "$SCAN_TYPE" in
    files) FIND_ARGS+=(-type f -size 0c) ;;
    dirs)  FIND_ARGS+=(-type d -empty) ;;
    both)  FIND_ARGS+=("(" -type f -size 0c -o -type d -empty ")") ;;
esac
FIND_ARGS+=(-print0)

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
print_banner
line
printf '  %bSCAN CONFIGURATION%b\n\n' "$WHITE$BOLD" "$RESET"
info "Scan path : $SCAN_PATH"
info "Scan type : $SCAN_TYPE"
info "Recursive : enabled"
info "Exclusions: \${#EXCLUDES[@]}"
info "Mode      : read-only"
[[ "$ONE_FILE_SYSTEM" == true ]] && info "Filesystem: do not cross mount points"
for excluded in "\${EXCLUDES[@]}"; do
    printf '  %bExcluded:%b %q\n' "$YELLOW" "$RESET" "$excluded"
done
line
printf '\n'
info "Scanning filesystem..."

# Preserve find's exit status while retaining NUL-delimited paths.
find "\${FIND_ARGS[@]}" -print0 2>"$ERROR_FILE" |
    sort -z > "$RESULT_FILE"
FIND_STATUS=$?

# ---------------------------------------------------------------------------
# Count results (NUL-safe)
# ---------------------------------------------------------------------------
TOTAL_FILES=0
TOTAL_DIRS=0
TOTAL_ITEMS=0

while IFS= read -r -d '' item; do
    ((TOTAL_ITEMS += 1))
    if [[ -d "$item" && ! -L "$item" ]]; then
        ((TOTAL_DIRS += 1))
    else
        ((TOTAL_FILES += 1))
    fi
done < "$RESULT_FILE"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# ---------------------------------------------------------------------------
# Build report
# ---------------------------------------------------------------------------
{
    printf '\n'
    line
    printf '  %bSCAN RESULTS%b\n' "$WHITE$BOLD" "$RESET"
    line
    printf '\n'
    printf '  %bEmpty files       : %d%b\n' "$GREEN" "$TOTAL_FILES" "$RESET"
    printf '  %bEmpty directories : %d%b\n' "$YELLOW" "$TOTAL_DIRS" "$RESET"
    printf '  %bTotal found       : %d%b\n\n' "$WHITE$BOLD" "$TOTAL_ITEMS" "$RESET"

    if ((TOTAL_ITEMS == 0)); then
        printf '  %bNo empty files or directories found.%b\n' "$GREEN" "$RESET"
    else
        printf '  %bDETAILED RESULTS%b\n' "$WHITE$BOLD" "$RESET"
        line
        while IFS= read -r -d '' item; do
            if [[ -d "$item" && ! -L "$item" ]]; then
                printf '  %b[DIR ]%b  %q\n' "$YELLOW" "$RESET" "$item"
            else
                printf '  %b[FILE]%b  %q\n' "$GREEN" "$RESET" "$item"
            fi
        done < "$RESULT_FILE"
    fi

    printf '\n'
    line
    printf '  Scan duration : %s seconds\n' "$DURATION"
    printf '  Scan location : %q\n' "$SCAN_PATH"

    if [[ -s "$ERROR_FILE" ]]; then
        printf '\n  %bSCAN / PERMISSION ERRORS%b\n' "$YELLOW$BOLD" "$RESET"
        line
        cat "$ERROR_FILE"
    fi
    line
    printf '\n'
} > "$REPORT_FILE"

cat "$REPORT_FILE"

# ---------------------------------------------------------------------------
# Optional report export
# ---------------------------------------------------------------------------
if [[ -n "$OUTPUT_FILE" ]]; then
    if cp -- "$REPORT_FILE" "$OUTPUT_FILE"; then
        success "Report exported to: $OUTPUT_FILE"
    else
        error "Failed to export report: $OUTPUT_FILE"
        exit 1
    fi
fi

if ((FIND_STATUS != 0)); then
    warning "Scan finished with errors; some paths may not have been accessible."
    exit 2
fi

success "Scan completed successfully."
exit 0
