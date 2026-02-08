# Session Notes: Feb 7-8, 2026

## Key Decisions Made

### LinkedIn Headline
- **Chose:** "Helping Claude Code follow your rules @ Luthien | Ex-Amazon"
- **Inspired by:** Google Drive research folder (linked from Drive)
- **Pattern:** Specific product value + company + credibility signal
- **Rejected patterns:** Ultra-simple (too early-stage for that), keyword-stuffed (LinkedIn influencer energy)

### Drive Sync Architecture
- **One shared script, multiple configs** — lives in public `scottwofford/drive-sync` repo
- **Each project has a `.conf` file** with its rclone remote, local dir, excludes, git push setting
- **luthien-org:** syncs to GitHub (GIT_PUSH=true), reverse sync enabled
- **sw3-google-drive:** local only (GIT_PUSH=false), no reverse sync
- **Luthien Drive folder excluded from personal sync** — already synced via luthien-org, would be a 25.8 GB duplicate

### Personal Drive Scope
- **Total Drive:** 44.3 GB, 4,128 files
- **After excludes:** ~9 GB (excluded Luthien 25.8 GB, Archives 6.4 GB, Music 1.8 GB, Meet Recordings 1.4 GB)
- **Syncs to:** `/Users/scottwofford/build/sw3-google-drive/drive/`
- **No git push** — Google Drive is the cloud backup, local sync is for offline access + Claude Code searchability

### COE: Sync Gap Feb 4-7
- **Root cause:** `set -e` + no error handling on `git push` + launchd only triggered at login
- **Fixes applied:** All error handling explicit, macOS notifications on ERROR, rclone auth pre-flight, StartInterval every 4 hours, stranded commit recovery
- **PR:** https://github.com/LuthienResearch/luthien-org/pull/1
- **Shared script now includes all fixes** — luthien-org launchd updated to point to shared script

## Files Created/Modified This Session

| File | Repo | What |
|------|------|------|
| `founder_linkedin_profiles_research.csv` | personal-site | 20 founder profiles with LinkedIn URLs, notes, relevance |
| `sync.sh` | drive-sync | Config-driven sync script (open source) |
| `configs/luthien-org.conf` | drive-sync | Luthien org sync config |
| `configs/sw3-google-drive.conf` | drive-sync | Personal Drive sync config |
| `example.conf` | drive-sync | Example config for other users |
| `README.md` | drive-sync | Setup instructions |
| `scripts/COE-2026-02-07-sync-gap.md` | luthien-org (PR #1) | COE document |
| `scripts/sync-from-drive.sh` | luthien-org (PR #1) | Original script with fixes (now superseded by shared script) |
| `scripts/com.luthien.sync-drive.plist` | luthien-org (PR #1) | launchd config tracked in repo |
| `CLAUDE.md` | build (root) | Added effort scoping preference |
| `com.luthien.sync-drive.plist` | ~/Library/LaunchAgents/ | Updated to point to shared script + 4hr interval |

## Open Questions for Next Session

1. **GitHub Issue on failure** — still undecided. macOS notifications are working. Worth adding GH Issues for when laptop is closed? (~30 min, ~2 min from Scott)
2. **Personal Drive launchd agent** — need to create and install (after initial sync runs successfully)
3. **LinkedIn About/Experience sections** — the main LinkedIn work is still ahead
4. **GitHub profile pins + bio** — quick wins after LinkedIn is done
5. **Google Drive MCP** — still erroring (`-32603: invalid_request`). OAuth may need refresh. Not blocking anything since rclone works fine.

## Gotchas / Things to Remember

- **UTF-8 BOM on CSVs** — always add BOM for files with special characters (em dashes, arrows). In CLAUDE.md but easy to forget.
- **luthien-org PR #1** — still open, needs review/merge. The fixes are already live via the shared script but the COE and old script changes are on the PR branch.
- **launchd + git branches** — if launchd fires while on a feature branch, it commits to that branch. Be aware when working on luthien-org branches.
- **Personal Drive has numbered folders** (0, 1, 2, 3.1, etc.) — Scott's organizational system. Don't rename.
