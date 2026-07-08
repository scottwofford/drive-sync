# drive-sync

Config-driven Google Drive sync to local directories. Uses rclone for syncing, pandoc for .docx-to-markdown conversion, and macOS notifications for error alerts.

Standalone by design: kept in its own public repo so it can be shared without exposing the private repos that consume it.

## Features

- Sync Google Drive folders to local directories via rclone
- Auto-convert `.docx` files to `.md` (via pandoc)
- Optional git commit + push
- Optional reverse sync (local files back to Drive)
- Explicit `MODE` per config (`forward` | `reverse` | `both`, default `both`)
- Refuses to start when `MODE=both` with `REMOTE == REVERSE_SYNC_REMOTE` (the topology error fixed in [COE 2026-05-02](./coes/COE-2026-05-02-private-claude-code-docs-clobber.md))
- `--update` on forward sync so Drive cannot overwrite a newer local file
- macOS notifications on errors
- Pre-flight auth check (catches expired OAuth tokens)
- Stranded commit recovery (retries failed pushes)
- Config-driven — one script, multiple sync targets

## Prerequisites

```bash
brew install rclone pandoc
```

## Setup

1. Create an rclone remote for your Google Drive:
   ```bash
   rclone config create my-remote drive
   ```

2. Copy and customize the example config:
   ```bash
   cp example.conf configs/my-project.conf
   # Edit REMOTE, LOCAL_DIR, and other settings
   ```

3. Run a dry-run to verify:
   ```bash
   ./sync.sh configs/my-project.conf --dry-run
   ```

4. Sync for real:
   ```bash
   ./sync.sh configs/my-project.conf --commit
   ```

## Scheduling (macOS)

Create a launchd plist to run automatically. See `example.plist` or:

```bash
# Run every 4 hours
cat > ~/Library/LaunchAgents/com.drive-sync.my-project.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.drive-sync.my-project</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/drive-sync/sync.sh</string>
        <string>/path/to/configs/my-project.conf</string>
        <string>--auto</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>/Users/you</string>
    </dict>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.drive-sync.my-project.plist
```

## Logs / how to tell if it's healthy

Two log surfaces, and it matters which you read:

- **`$LOCAL_DIR/sync.csv`** — the real, per-run log (timestamp, level, action, message). Written every run in `--auto` mode; rclone's own stderr is appended here too. **This is the source of truth.** A run that worked ends with a `sync_end,"Sync complete"` row; failures show `ERROR` rows.
- **The launchd `stdout path`** (e.g. `sync-stdout.log`) — in `--auto` mode the script writes only a **heartbeat** line here at run start and end, each pointing back to `sync.csv`. It intentionally carries no detail.

Health check at a glance: a recent heartbeat (or recent `sync.csv` activity) means the job is alive. A stdout log that looks frozen is **not** evidence of a dead job on its own — before the heartbeat was added (see [COE 2026-07-08](./coes/COE-2026-07-08-sw3-mirror-false-staleness.md)) that file had been silent by design since May 7 and a healthy mirror was wrongly called dead.

Diagnosing "the mirror looks stale": check whether the file is even *in Drive yet* before blaming rclone. `rclone lsl "<remote>:<subfolder>/"` shows the Drive-side modtime (when the file entered Drive). Upstream delivery lag (e.g. Plaud→Zapier→Drive) presents as a stale mirror but is not a sync failure — rclone can only mirror what Drive already has.

## Config reference

See `example.conf` for all options with documentation.

## Known caveats

**macOS "App Background Activity" toasts.** macOS Background Task Management (BTM) occasionally posts an advisory notification ("`<script>` can run in the background") for each LaunchAgent it tracks. These fire on:

- LaunchAgent registration changes (any edit to the plist's `ProgramArguments`)
- BTM database migrations after macOS updates (observed 2026-05-05)

There is no clean user-controllable suppression for `BackgroundTaskManagementAgent` in System Settings → Notifications. The toasts are infrequent in practice; expect a brief batch after macOS updates, then quiet for weeks.

Investigation source (private repo): [`session-logs/2026-05-05_drive-sync-notification-fix.csv`](https://github.com/scottwofford/private-claude-code-docs/blob/main/session-logs/2026-05-05_drive-sync-notification-fix.csv).
