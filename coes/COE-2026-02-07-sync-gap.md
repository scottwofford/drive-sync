# COE: Drive Sync Gap (Feb 4-7, 2026)

## Summary

Google Drive sync to GitHub stopped running after Feb 4. Discovered Feb 7 when manually checking — 3 days of Drive content not synced.

## Timeline

- **Feb 4 15:53** — Last successful sync. Script synced files, converted 2 docx, committed. Git push hit HTTP 500 from GitHub.
- **Feb 4 15:53 → Feb 7 16:53** — No syncs ran. New Drive content (Seldon labs notes, user interviews, PBC docs) not synced.
- **Feb 7 16:53** — Manual sync run. 31 files synced, 15 docx converted, pushed successfully.

## Root Cause

**Two compounding issues:**

### 1. `git push` failure kills the script silently

The script uses `set -e` (exit on any error). The rclone commands have `|| true` to handle transient errors, but `git push` at line 181 does **not**. When GitHub returned HTTP 500, `set -e` killed the script. launchd recorded exit status 1.

```bash
# rclone — has error handling ✅
rclone copy ... || true

# git push — no error handling ❌
git push   # HTTP 500 → set -e → script dies
```

### 2. launchd only triggers once per login

The plist uses `RunAtLoad` only. Despite the comment saying "laptop wakes," `RunAtLoad` **only fires when the agent is first loaded** (at login). There is no `StartInterval` or `WatchPaths` trigger. So after the initial run failed, launchd never retried.

### 3. No retry for unpushed commits

If push fails but commit succeeds, subsequent runs see no uncommitted changes (`git status --porcelain` is clean) and skip the commit/push block entirely. The unpushed commit is stranded.

## Impact

- 3 days of Drive content not in GitHub (Seldon labs weekly notes, user interview notes for Finn/Quentin/Jack, PBC mission control docs, value prop landing pages)
- No alerting — discovered by chance

## Fixes Applied

| Issue | Fix | Commit |
|-------|-----|--------|
| `set -e` kills script on any error | Removed `set -e`, handle all errors explicitly | `b41997a` |
| `git push` failure crashes script | `if ! git push` with error logging | `267dace` |
| `git add` / `git commit` failure crashes script | `if ! git add` / `elif ! git commit` chain | `b41997a` |
| No retry for unpushed commits | Check `git rev-list --count @{u}..HEAD` at start, push if >0 | `267dace` |
| launchd only runs at login | Added `StartInterval` (every 4 hours / 14400s) | `be53ff9` |
| Dangling shortcut errors | `--drive-skip-dangling-shortcuts` flag | `a062a93` |
| launchd plist not version-controlled | Copied to `scripts/com.luthien.sync-drive.plist` | `be53ff9` |

## Remaining Risk

- **No alerting** — failures are logged but nobody gets notified. A future improvement would be a simple health check (e.g., if last sync > 24h old, send a notification).
- **rclone OAuth token expiry** — would fail silently. Monitor sync.csv for gaps.

## Lessons Learned

- `set -e` is a blunt instrument — critical commands need explicit error handling
- `RunAtLoad` alone is insufficient for reliability — need periodic triggers
- Silent failures in automated scripts need some form of alerting
- Version-control your launchd plists alongside the scripts they run
