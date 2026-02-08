#!/bin/bash
# drive-sync: Config-driven Google Drive sync with markdown conversion
#
# Syncs a Google Drive folder to a local directory via rclone.
# Optionally converts .docx → .md (pandoc) and commits to git.
#
# Usage:
#   ./sync.sh <config-file>                    # sync only
#   ./sync.sh <config-file> --commit           # sync + commit + push
#   ./sync.sh <config-file> --dry-run          # preview what would sync
#   ./sync.sh <config-file> --auto             # scheduled runs (quiet, auto-commit)
#
# Config file format (bash):
#   REMOTE="gdrive-luthien"
#   LOCAL_DIR="/Users/you/build/my-project"
#   SYNC_SUBDIR=""                              # optional: sync into a subdirectory
#   GIT_PUSH=true                               # true/false
#   CONVERT_DOCX=true                           # true/false
#   REVERSE_SYNC_REMOTE=""                      # optional: remote for GitHub→Drive sync
#   REVERSE_SYNC_INCLUDES=("*.md" "*.csv")      # file patterns for reverse sync
#   EXCLUDES=("*.mp4" "*.wav")                  # rclone exclude patterns
#   SKIP_DANGLING_SHORTCUTS=true                # skip broken Drive shortcuts

# No set -e — we handle errors explicitly so the script never dies silently

# --- Argument parsing ---

CONFIG_FILE="$1"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
    echo "Usage: $0 <config-file> [--commit|--dry-run|--auto]"
    echo ""
    echo "Example: $0 /path/to/sync.conf --commit"
    exit 1
fi

shift # remove config file from args

DRY_RUN=""
AUTO_COMMIT=""
AUTO_MODE=""

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN="--dry-run"
            ;;
        --commit)
            AUTO_COMMIT="1"
            ;;
        --auto)
            AUTO_MODE="1"
            AUTO_COMMIT="1"
            ;;
    esac
done

# --- Load config ---

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Resolve sync target directory
if [[ -n "$SYNC_SUBDIR" ]]; then
    SYNC_DIR="$LOCAL_DIR/$SYNC_SUBDIR"
else
    SYNC_DIR="$LOCAL_DIR"
fi

LOG_FILE="$LOCAL_DIR/sync.csv"

# --- Helpers ---

SYNC_ERRORS=0

notify_error() {
    local msg="$1"
    osascript -e "display notification \"$msg\" with title \"Drive Sync\" subtitle \"Error\"" 2>/dev/null || true
}

log() {
    local level="${2:-INFO}"
    local action="${3:-general}"
    local msg="$1"

    if [[ "$level" == "ERROR" ]]; then
        ((SYNC_ERRORS++))
        notify_error "$msg"
    fi

    if [[ -n "$AUTO_MODE" ]]; then
        if [[ ! -f "$LOG_FILE" ]]; then
            echo "timestamp,level,action,message" > "$LOG_FILE"
        fi
        local escaped="${msg//\"/\"\"}"
        echo "$(date '+%Y-%m-%d %H:%M:%S'),$level,$action,\"$escaped\"" >> "$LOG_FILE"
    else
        echo -e "$msg"
    fi
}

convert_docx_to_md() {
    local dir="$1"
    local converted=0
    local failed=0

    while IFS= read -r -d '' docx_file; do
        md_file="${docx_file%.docx}.md"

        if [[ -f "$md_file" && "$md_file" -nt "$docx_file" ]]; then
            continue
        fi

        if pandoc "$docx_file" -o "$md_file" --wrap=none 2>/dev/null; then
            ((converted++))
            rm "$docx_file"
        else
            log "Failed to convert $(basename "$docx_file")" "WARN" "convert"
            ((failed++))
        fi
    done < <(find "$dir" -name "*.docx" -not -path "*/.git/*" -not -path "*/scripts/*" -print0)

    echo "$converted $failed"
}

# --- Pre-flight checks ---

if [[ -n "$DRY_RUN" ]]; then
    log "DRY RUN - no files will be changed" "INFO" "dry_run"
fi

if ! rclone lsd "$REMOTE:" --max-depth 0 --quiet 2>/dev/null; then
    log "rclone cannot connect to $REMOTE — auth token may be expired. Run: rclone config reconnect $REMOTE:" "ERROR" "auth_fail"
    exit 1
fi

# --- Drive → Local sync ---

RCLONE_OPTS=()
for pattern in "${EXCLUDES[@]}"; do
    RCLONE_OPTS+=(--exclude "$pattern")
done

if [[ "${SKIP_DANGLING_SHORTCUTS:-true}" == "true" ]]; then
    RCLONE_OPTS+=(--drive-skip-dangling-shortcuts)
fi

log "Syncing $REMOTE → $SYNC_DIR" "INFO" "sync_start"
if [[ -n "$AUTO_MODE" ]]; then
    rclone copy "$REMOTE:" "$SYNC_DIR" \
        --drive-export-formats docx \
        "${RCLONE_OPTS[@]}" \
        --quiet \
        $DRY_RUN 2>> "$LOG_FILE" || true
else
    rclone copy "$REMOTE:" "$SYNC_DIR" \
        --drive-export-formats docx \
        "${RCLONE_OPTS[@]}" \
        --progress \
        $DRY_RUN || true
fi

# --- Local → Drive reverse sync (optional) ---

if [[ -n "$REVERSE_SYNC_REMOTE" ]]; then
    log "Syncing $LOCAL_DIR → $REVERSE_SYNC_REMOTE" "INFO" "sync_start"

    REVERSE_OPTS=()
    for pattern in "${REVERSE_SYNC_INCLUDES[@]}"; do
        REVERSE_OPTS+=(--include "$pattern")
    done

    if [[ -n "$AUTO_MODE" ]]; then
        rclone sync "$LOCAL_DIR" "$REVERSE_SYNC_REMOTE:" \
            --max-depth 1 \
            "${REVERSE_OPTS[@]}" \
            --quiet \
            $DRY_RUN 2>> "$LOG_FILE" || true
    else
        rclone sync "$LOCAL_DIR" "$REVERSE_SYNC_REMOTE:" \
            --max-depth 1 \
            "${REVERSE_OPTS[@]}" \
            --progress \
            $DRY_RUN || true
    fi
fi

log "Sync complete" "INFO" "sync_end"

# --- Conversion ---

if [[ -n "$DRY_RUN" ]]; then
    log "Skipping conversion in dry-run mode" "INFO" "dry_run"
    exit 0
fi

if [[ "${CONVERT_DOCX:-true}" == "true" ]]; then
    log "Converting .docx files to markdown" "INFO" "convert_start"
    result=$(convert_docx_to_md "$SYNC_DIR")
    total_converted=$(echo "$result" | cut -d' ' -f1)
    total_failed=$(echo "$result" | cut -d' ' -f2)
    log "Converted $total_converted files to markdown" "INFO" "convert_end"
    if [[ $total_failed -gt 0 ]]; then
        log "Failed to convert $total_failed files (kept as .docx)" "WARN" "convert_end"
    fi
fi

# --- Git commit + push ---

if [[ -n "$AUTO_COMMIT" && "${GIT_PUSH:-false}" == "true" ]]; then
    cd "$LOCAL_DIR"

    # Push any stranded commits from previous failed runs
    local_ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")
    if [[ "$local_ahead" -gt 0 ]]; then
        log "Found $local_ahead unpushed commits, pushing now" "WARN" "push_retry"
        if ! git push; then
            log "Failed to push stranded commits" "ERROR" "push_retry"
        fi
    fi

    if [[ -n $(git status --porcelain) ]]; then
        log "Committing changes" "INFO" "commit_start"
        if ! git add -A; then
            log "git add failed" "ERROR" "commit_fail"
        elif ! git commit -m "sync: drive folders $(date '+%Y-%m-%d %H:%M')"; then
            log "git commit failed" "ERROR" "commit_fail"
        elif ! git push; then
            log "git push failed — will retry on next run" "ERROR" "push_fail"
        else
            log "Pushed to GitHub" "INFO" "commit_end"
        fi
    else
        log "No changes to commit" "INFO" "commit_skip"
    fi
elif [[ -n "$AUTO_COMMIT" && "${GIT_PUSH:-false}" == "false" ]]; then
    log "Git push disabled in config — skipping" "INFO" "commit_skip"
fi
