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
#   MODE="both"                                 # "forward" (Drive→local), "reverse" (local→Drive), "both" (default)
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
    # Modal alert (not banner): bypasses per-app Notifications toggle, which
    # for Script Editor is off on Scott's Mac. Async so sync.sh doesn't block
    # waiting for the OK click.
    osascript -e "display alert \"Drive Sync Error\" message \"$msg\" as critical" >/dev/null 2>&1 &
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
        echo -e "$msg" >&2
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

MODE="${MODE:-both}"
case "$MODE" in
    forward|reverse|both) ;;
    *)
        log "Invalid MODE='$MODE' in config (must be forward|reverse|both)" "ERROR" "config_invalid"
        exit 1
        ;;
esac

if [[ "$MODE" == "reverse" && -z "$REVERSE_SYNC_REMOTE" ]]; then
    log "MODE=reverse requires REVERSE_SYNC_REMOTE to be set" "ERROR" "config_invalid"
    exit 1
fi

# Refuse to run if MODE=both with REMOTE == REVERSE_SYNC_REMOTE: this is the
# topology error that produced COE 2026-05-02 (silent self-clobber loop).
# The original private-claude-code-docs config hit this; explicit refusal here
# means future configs cannot reproduce the bug regardless of --update behavior.
if [[ "$MODE" == "both" && -n "$REMOTE" && "$REMOTE" == "$REVERSE_SYNC_REMOTE" ]]; then
    log "REMOTE and REVERSE_SYNC_REMOTE are the same ($REMOTE) with MODE=both — refusing to run; set MODE=forward or MODE=reverse to express intent" "ERROR" "config_invalid"
    exit 1
fi

if [[ -n "$DRY_RUN" ]]; then
    log "DRY RUN - no files will be changed" "INFO" "dry_run"
fi

PREFLIGHT_REMOTE="$REMOTE"
[[ "$MODE" == "reverse" ]] && PREFLIGHT_REMOTE="$REVERSE_SYNC_REMOTE"
# Capture rclone's stderr to diagnose preflight failures (2026-05-07: previously
# `2>/dev/null` swallowed the actual error, leaving us guessing whether failures
# were auth, network, rate-limit, or something else; the generic "auth_fail"
# log message was an over-confident assumption — actual cause was usually
# `rateLimitExceeded`).
#
# Apply same retry policy as the main rclone sync below — the preflight is a
# tiny request but shares the same per-user-per-100s quota as everything else,
# so it can rate-limit too. Without retries here, a single transient quota
# saturation kills the whole run before the main sync even starts.
PREFLIGHT_ERR=$(rclone lsd "$PREFLIGHT_REMOTE:" --max-depth 0 --quiet \
    --retries 3 --retries-sleep 30s --low-level-retries 20 \
    --drive-pacer-min-sleep 100ms 2>&1 >/dev/null)
PREFLIGHT_EXIT=$?
if [ "$PREFLIGHT_EXIT" != "0" ]; then
    # Detect rate-limit specifically so the log message doesn't mislead future
    # diagnosticians (the original "auth_fail" assumption cost ~2 hours of
    # wrong-direction debugging on 2026-05-07).
    if echo "$PREFLIGHT_ERR" | grep -qi "rateLimitExceeded\|userRateLimitExceeded\|quotaExceeded"; then
        log "rclone preflight RATE-LIMITED by Google Drive API (exit $PREFLIGHT_EXIT). Per-user-per-100s quota saturated. Retried 3x with backoff and still failed; either too much concurrent rclone activity or quota is genuinely exhausted. Wait 5+ min and retry, OR consider raising quota via own GCP OAuth project. rclone stderr: $PREFLIGHT_ERR" "ERROR" "preflight_rate_limited"
    elif echo "$PREFLIGHT_ERR" | grep -qi "invalid_grant\|token expired\|unauthorized\|401"; then
        log "rclone preflight AUTH FAILED (exit $PREFLIGHT_EXIT) — token expired or invalid. Run: rclone config reconnect $PREFLIGHT_REMOTE:" "ERROR" "preflight_auth_fail"
    else
        log "rclone preflight FAILED (exit $PREFLIGHT_EXIT) — uncategorized error. rclone stderr: $PREFLIGHT_ERR" "ERROR" "preflight_fail"
    fi
    exit 1
fi

# --- Capture pre-sync git state (for post-sync correctness check) ---
# If LOCAL_DIR is a git working tree, snapshot which tracked files are
# modified before sync. Compared against post-sync state to detect silent
# clobbers (the class of bug from COE 2026-05-02).

GIT_TRACKED=false
PRE_GIT_TRACKED_MODS=""
if [[ -d "$LOCAL_DIR/.git" || -f "$LOCAL_DIR/.git" ]]; then
    GIT_TRACKED=true
    PRE_GIT_TRACKED_MODS=$(cd "$LOCAL_DIR" && git status --porcelain 2>/dev/null | grep -E "^.M " | sort)
fi

# --- Drive → Local sync ---

RCLONE_OPTS=()
for pattern in "${EXCLUDES[@]}"; do
    RCLONE_OPTS+=(--exclude "$pattern")
done

if [[ "${SKIP_DANGLING_SHORTCUTS:-true}" == "true" ]]; then
    RCLONE_OPTS+=(--drive-skip-dangling-shortcuts)
fi

# --- Google Drive API rate-limit handling ---
# Added 2026-05-07 after diagnosing that sw3-google-drive cron was hitting
# Google's per-user-per-100-second quota (~1000 reqs/100s) on every run.
# Scott's personal Drive has 247+ folders — even just listing them blows
# through the quota in <30s, and rclone fires requests as fast as Google
# allows by default with no built-in backoff.
#
# Symptoms before this fix:
#   - sync.csv showed `ERROR rclone_forward_fail` with `rateLimitExceeded` payload
#   - Sync would die mid-way; later folders never reached
#   - launchctl exit code was 0 (rclone returns 0 even when subfolders fail
#     for some error classes), so the cron-monitor in private-claude-code-docs/
#     scripts/auto-log-prompt.sh missed the failure entirely
#   - Plaud Drive folders created today (2.2 Plaud + Claude-for-Chrome historical)
#     never appeared in the local mirror
#
# Fix flags:
#   --tpslimit 5             cap at 5 transactions/sec (~500 over 100s window,
#                            well under 1000 limit, with headroom for bursts)
#   --tpslimit-burst 1       no burst, strict pacing
#   --drive-pacer-min-sleep 100ms
#                            rclone's built-in pacer; 100ms floor between requests
#   --retries 3              retry whole operation up to 3x on failure
#   --low-level-retries 20   retry individual network operations 20x
#   --retries-sleep 30s      30s between retries (3 × 30s = 90s buffer, just over
#                            the 100s quota window — handles rate-limit blips
#                            without burning 7 min on permanent failures like
#                            auth_fail). Originally set to 10 retries; reduced
#                            after observing auth-token-expired runs taking ~7 min
#                            to fail.
#   --fast-list              consolidates folder listing into fewer requests for
#                            hierarchical scans — large win for 247-folder tree
#
# Trade-off: each sync takes longer (~8-12 min vs. ~3 min before, when not
# rate-limited). But it actually completes vs. previous "die mid-way."
#
# Reference: COE 2026-05-07 + Trello https://trello.com/c/XKRT2c4f
RCLONE_OPTS+=(
    --tpslimit 5
    --tpslimit-burst 1
    --drive-pacer-min-sleep 100ms
    --retries 3
    --low-level-retries 20
    --retries-sleep 30s
    --fast-list
)

if [[ "$MODE" == "forward" || "$MODE" == "both" ]]; then
    log "Syncing $REMOTE → $SYNC_DIR" "INFO" "sync_start"
    # --update: skip files where destination is newer than source. Prevents Drive (often
    # stale relative to local git working tree) from overwriting newer local content.
    if [[ -n "$AUTO_MODE" ]]; then
        if ! rclone copy "$REMOTE:" "$SYNC_DIR" \
            --update \
            --drive-export-formats docx \
            "${RCLONE_OPTS[@]}" \
            --quiet \
            $DRY_RUN 2>> "$LOG_FILE"; then
            log "rclone forward sync ($REMOTE -> $SYNC_DIR) failed: see $LOG_FILE" "ERROR" "rclone_forward_fail"
        fi
    else
        rclone copy "$REMOTE:" "$SYNC_DIR" \
            --update \
            --drive-export-formats docx \
            "${RCLONE_OPTS[@]}" \
            --progress \
            $DRY_RUN || true
    fi
else
    log "MODE=$MODE — skipping forward sync ($REMOTE → $SYNC_DIR)" "INFO" "sync_skip"
fi

# --- Local → Drive reverse sync (optional) ---

if [[ ( "$MODE" == "reverse" || "$MODE" == "both" ) && -n "$REVERSE_SYNC_REMOTE" ]]; then
    log "Syncing $LOCAL_DIR → $REVERSE_SYNC_REMOTE" "INFO" "sync_start"

    REVERSE_OPTS=()
    for pattern in "${REVERSE_SYNC_INCLUDES[@]}"; do
        REVERSE_OPTS+=(--include "$pattern")
    done

    if [[ -n "$AUTO_MODE" ]]; then
        if ! rclone sync "$LOCAL_DIR" "$REVERSE_SYNC_REMOTE:" \
            --max-depth "${REVERSE_MAX_DEPTH:-1}" \
            "${REVERSE_OPTS[@]}" \
            --quiet \
            $DRY_RUN 2>> "$LOG_FILE"; then
            log "rclone reverse sync ($LOCAL_DIR -> $REVERSE_SYNC_REMOTE) failed: see $LOG_FILE" "ERROR" "rclone_reverse_fail"
        fi
    else
        rclone sync "$LOCAL_DIR" "$REVERSE_SYNC_REMOTE:" \
            --max-depth "${REVERSE_MAX_DEPTH:-1}" \
            "${REVERSE_OPTS[@]}" \
            --progress \
            $DRY_RUN || true
    fi
fi

# --- Post-sync correctness check ---
# Compare git-tracked-file modifications before and after sync. Any NEW
# modification line indicates the sync overwrote a tracked file that
# wasn't already dirty (the COE 2026-05-02 silent-clobber pattern).
# Skipped in dry-run mode and when LOCAL_DIR is not a git repo.

if [[ "$GIT_TRACKED" == "true" && -z "$DRY_RUN" ]]; then
    POST_GIT_TRACKED_MODS=$(cd "$LOCAL_DIR" && git status --porcelain 2>/dev/null | grep -E "^.M " | sort)
    if [[ "$PRE_GIT_TRACKED_MODS" != "$POST_GIT_TRACKED_MODS" ]]; then
        NEW_MODS=$(diff <(echo "$PRE_GIT_TRACKED_MODS") <(echo "$POST_GIT_TRACKED_MODS") 2>/dev/null | grep '^> ' | sed 's/^> //' | tr '\n' ';' | sed 's/;$//')
        if [[ -n "$NEW_MODS" ]]; then
            log "Sync introduced new tracked-file modifications in $LOCAL_DIR (possible silent clobber): $NEW_MODS" "ERROR" "tracked_clobber"
        fi
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
    total_converted=$(echo "$result" | tail -1 | cut -d' ' -f1)
    total_failed=$(echo "$result" | tail -1 | cut -d' ' -f2)
    total_converted=${total_converted:-0}
    total_failed=${total_failed:-0}
    log "Converted $total_converted files to markdown" "INFO" "convert_end"
    if [[ "$total_failed" -gt 0 ]] 2>/dev/null; then
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
