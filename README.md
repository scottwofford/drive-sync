# drive-sync

Config-driven Google Drive sync to local directories. Uses rclone for syncing, pandoc for .docx-to-markdown conversion, and macOS notifications for error alerts.

## Features

- Sync Google Drive folders to local directories via rclone
- Auto-convert `.docx` files to `.md` (via pandoc)
- Optional git commit + push
- Optional reverse sync (local files back to Drive)
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

## Config reference

See `example.conf` for all options with documentation.
