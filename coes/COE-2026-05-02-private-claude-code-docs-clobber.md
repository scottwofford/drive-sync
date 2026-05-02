# COE: drive-sync silently clobbered private-claude-code-docs working tree (May 2026)

**Type:** B (operational / process incident — code change is the fix, but the bug was a config + script-design pattern, not a single bad line)

## Summary

`private-claude-code-docs/CLAUDE.md` was rolled back from the May 2026 HEAD content (688 lines) to a stale February 21 version (617 lines) by the scheduled drive-sync job. The drift was invisible to all sync logs (every run logged `Sync complete`) and to git (no `git push` involved). It surfaced only when Scott's Claude Code session noticed the working tree differed from HEAD by 73 lines.

Window of exposure: at least 2026-04-29 (first sync log entry showing the recurring pattern) through 2026-05-02 09:08:50 (last clobber, ~15 minutes before discovery). Likely longer; sync.csv was rotated.

## Repro Steps (the original bug, before this fix)

1. Check out commit `32c54e3` of drive-sync (parent of this PR).
2. Use `configs/private-claude-code-docs.conf` as-is (REMOTE and REVERSE_SYNC_REMOTE both set to `gdrive-personal-claude-docs`).
3. From a **different machine**, edit `private-claude-code-docs/CLAUDE.md`, commit, push to GitHub.
4. On the affected machine, run `git pull` (working tree updates to new content, mtime = now).
5. Within 4 hours, the launchd-scheduled `sync.sh configs/private-claude-code-docs.conf --auto` fires.
6. Observe: `git status` now shows `M CLAUDE.md`, working tree is back to the OLD Drive version, on-disk mtime is rolled back to the Drive copy's mtime (Feb 21 in our case).

## RCA/COE

### Bug: forward sync silently downgrades a git-tracked working tree to an older Drive copy

**Impact:**

Trust impact is the load-bearing one. Scott uses CLAUDE.md as the binding behavioral spec for every Claude session across multiple surfaces (Claude Code on this machine, claude.ai web, Claude Desktop). When the working tree on this machine silently diverges from HEAD:

- **Behavior on this machine drifts** from what Scott has written and pushed. Every `Read CLAUDE.md` from this machine's git checkout returned 73 lines fewer than what was actually in HEAD, including R1/R2/R3 cross-surface behavior, the repo permissions table, and the "process learnings → docs not memory" rule that was added on 2026-05-01 specifically.
- **Other surfaces also degraded.** The same mechanism that made the local working tree stale also made the Drive-mounted copy stale (Drive contained the same old bytes). Any Claude surface reading CLAUDE.md from sw3 Google Drive (e.g. claude.ai web project knowledge synced from this Drive folder) was reading the same 617-line stale version.
- **Cumulative.** Each new commit Scott made to CLAUDE.md from another surface had a 4-hour half-life on this machine before being silently reverted. The recent additions Scott most cares about (R1/R2/R3 binding) were the ones being silently dropped.
- **Severity:** session-level degradation, not blocking. Discovered by chance, not by alert. Could have persisted indefinitely.

Blast radius: 1 file confirmed (`CLAUDE.md`). Other tracked .md/.csv files at top level (`COE_INDEX.md`, `MCP_TOOL_PATTERNS.md`, `MENTOR_NOTES.md`, `SETUP.md`) happened to match between Drive and HEAD, so were not visibly drifted at the moment of discovery — but were vulnerable to the same mechanism.

**Timeline:**

| Date | Event |
|------|-------|
| 2026-02-07 | Earlier drive-sync COE shipped (`coes/COE-2026-02-07-sync-gap.md`) — added `set -e` removal, push retry, `StartInterval`. Did not address sync direction. |
| 2026-02-21 16:37 | Apparent last time this machine's CLAUDE.md was edited locally / Drive copy was last in agreement with HEAD. Working-tree mtime frozen here. |
| 2026-02 → 2026-05 | Multiple commits to CLAUDE.md pushed from other surfaces (commits `499974a`, `25b31bc`, `a8fa709`, `e93674e`, `726f836`). Each `git pull` on this machine restored the new content; the next ≤4h sync rolled it back. |
| 2026-04-29 | First sync log entry under current rotation showing the recurring Drive→local clobber. |
| 2026-05-02 09:08:50 | Most recent silent clobber. |
| 2026-05-02 ~10:15 | Discovered: Claude Code session noticed `git diff` showed 73 lines deleted from working tree relative to HEAD, mtime stuck at Feb 21. |
| 2026-05-02 10:23 | Working tree restored via `git checkout HEAD -- CLAUDE.md`. Restored content pushed directly to Drive via `rclone copyto` (bypassing forward sync) so the next cron tick stabilizes on the correct content. |
| 2026-05-02 (this PR) | Architectural fix: `MODE` flag added to sync.sh; `MODE=reverse` set in private-claude-code-docs.conf; `--update` defense-in-depth added to forward rclone copy. |

Window of exposure: **multiple weeks** (since Feb 21 at minimum, likely longer for any cross-machine CLAUDE.md edit during the period).

**5 Whys:**

1. Why did CLAUDE.md get rolled back? → The scheduled `sync.sh configs/private-claude-code-docs.conf --auto` ran `rclone copy gdrive-personal-claude-docs: /local` (forward sync), which overwrote the local file with the older Drive copy.
2. Why did forward sync run when the config comment said "Reverse sync only"? → `sync.sh` has no concept of "reverse-only mode." The script always runs forward sync if `REMOTE` is set (which it must be, for the auth pre-flight). The comment in the config was aspirational, not enforced.
3. Why did `rclone copy` overwrite a newer local file with an older Drive file? → No `--update` flag was passed. Default `rclone copy` compares size + mtime and copies whenever they differ, in the source-to-destination direction, regardless of which side is newer. Drive (Feb 21) and local (recent pull) had different mtimes → rclone copied Drive over local and reset local mtime to match Drive.
4. Why was the same remote configured for both forward AND reverse sync? → The intent was "push local docs to Drive so other Claude surfaces can read them" (one-way reverse). Reusing the same remote name for both `REMOTE` and `REVERSE_SYNC_REMOTE` looked like a natural way to express "this Drive folder is the sync target." There was no MODE primitive to express "I only want one direction."
5. Why didn't anyone notice for weeks? → No detection. `sync.sh` only logs `sync_start` / `sync_end` / `commit_skip` and does not compare the post-sync working tree against `git HEAD` (or against any expected state). Every silent clobber logged as a successful run. `GIT_PUSH=false` means git never had a chance to flag the divergence either. The drift surfaced only because a Claude Code session happened to read both `git status` and `git diff` while doing unrelated work.
6. Why was there no MODE primitive? → drive-sync started as a forward-only tool. Reverse sync was bolted on later via `REVERSE_SYNC_REMOTE`. The design assumed: "if you don't want reverse sync, leave REVERSE_SYNC_REMOTE empty; otherwise both directions run." There was no design conversation about "what if I want reverse only?" — that case wasn't anticipated, so the only way to express it was via the comment, which the script doesn't read.
7. Why doesn't the script defend against overwriting newer destinations even in MODE=both? → The earlier 2026-02-07 COE focused on "sync stops running" (silent failure to sync), not "sync runs but corrupts data" (silent success that destroys content). The previous fix was load-bearing for liveness, not for safety. The class of bug "forward sync overwrites newer local content" was never on anyone's threat model.

Root cause is item 7 (no defense against this class of bug at the sync-engine level) plus item 6 (no way to express the intent at the config level). Items 1-5 are downstream consequences.

### The Pattern

| PR / COE | Date | What went wrong | How discovered |
|----|------|----------------|----------------|
| [`coes/COE-2026-02-07-sync-gap.md`](./COE-2026-02-07-sync-gap.md) | 2026-02-07 | Drive sync stopped running for 3 days after `git push` HTTP 500 + `set -e` killed the script; launchd `RunAtLoad` only fired at login | Manual check, 3 days later |
| **This COE** | 2026-05-02 | Drive sync ran "successfully" but silently downgraded a git-tracked file to an older Drive copy on every run | Claude Code session noticed `git diff` divergence by chance |

**Pattern: drive-sync silent failures.** Both incidents share a structural property: the sync script reports success but the user-visible state is wrong. Feb 2026 was silent failure to do work (no sync). May 2026 was silent failure to do work correctly (sync ran but corrupted data). Both went undetected for days-to-weeks because **the success criterion logged by the script ("sync_end") is decoupled from the success criterion the user actually cares about ("the file I edited is the file that's there")**.

The Feb 2026 fix improved liveness (script keeps running) but did not improve correctness verification (does the result match expectation?). This COE must address that gap, not just the specific config.

### Detection gap

1. **How was the bug actually discovered?** A Claude Code session was about to edit CLAUDE.md to add a "file-write defaults" rule. As part of investigating the file's current state, it ran `git status` and saw `M CLAUDE.md` with 73 lines deleted. The session paused to investigate rather than blindly editing — without that pause, the fix would have stomped on the (correct) HEAD content with another stale version.
2. **How *should* it have been discovered?** A periodic check that compares each sync target's tracked-file state against `git HEAD` (or, more simply, runs `git status --porcelain` and alerts if it's non-empty after a sync). Either as part of `sync.sh` itself (post-sync verification step) or as a separate health check job. macOS notification + log entry on divergence.

### What else could break?

I audited all three configs in `configs/`:

| Config | REMOTE | REVERSE_SYNC_REMOTE | Risk |
|--------|--------|--------------------|------|
| `private-claude-code-docs.conf` | `gdrive-personal-claude-docs` | `gdrive-personal-claude-docs` (SAME) | **The bug.** Fixed in this PR (MODE=reverse). |
| `luthien-org.conf` | `gdrive-luthien` | `gdrive-claude-docs` (different) | Lower risk — different remotes mean no self-clobber loop. But forward sync without `--update` could still overwrite newer local content if Drive ever had an older version of a `*.md` file. **Mitigated** by `--update` default in this PR. |
| `sw3-google-drive.conf` | `gdrive-personal` | `""` (forward only) | No risk of this bug class (no reverse sync). Forward-sync overwrites are intentional for this config (Drive is source of truth, local is the rclone-mirrored consumer). |

I also checked git status of `private-claude-code-docs/` for any other tracked file in unexpected drift state: only `CLAUDE.md` was modified at time of discovery. Other top-level .md/.csv files happened to match between Drive and HEAD.

I did **not** check whether the same class of bug exists in any other rclone-based sync tooling on this machine (e.g. `automation/` if it has its own sync, or claude-ai-sync). That is a follow-up audit, tracked below.

### Incident detail (evidence)

Forward sync command (sync.sh line 149, before fix):

```bash
rclone copy "$REMOTE:" "$SYNC_DIR" \
    --drive-export-formats docx \
    "${RCLONE_OPTS[@]}" \
    --quiet \
    $DRY_RUN 2>> "$LOG_FILE" || true
```

No `--update` flag. `rclone copy` default behavior copies whenever source size or mtime differs from destination, in either direction.

Working tree state at discovery:

```
$ ls -la CLAUDE.md
-rw-r--r--@ 1 scottwofford  staff  33113 Feb 21 16:37 CLAUDE.md
$ git diff --stat CLAUDE.md
 CLAUDE.md | 75 ++-------------------------------------------------------------
 1 file changed, 2 insertions(+), 73 deletions(-)
$ git log --oneline -3 -- CLAUDE.md
726f836 CLAUDE.md: cross-surface Claude behavior section (R1, R2, R3 binding)
e93674e Major restructure: requirements as Epic+sub-stories, repo permissions, falsified-isolation note
4c1633d Merge requirements/initial-uber to main + preserve full session log
```

Drive copy at discovery:

```
$ ls -la "/Users/scottwofford/build/sw3-google-drive/drive/2.1 Private Claude Code Docs/CLAUDE.md"
-rw-r--r--@ 1 scottwofford  staff  33113 Feb 21 16:37 CLAUDE.md
$ diff -q working_tree_CLAUDE.md drive_CLAUDE.md
# (no output — files identical)
```

Drive bytes byte-equal to working tree, both Feb 21 mtime, both 73 lines short of HEAD. The cycle was self-stabilizing: forward sync makes local match Drive; reverse sync makes Drive match local; both halves no-op once they agree on the stale content.

### Fixes Applied

| Issue | Fix | File |
|-------|-----|------|
| `sync.sh` always runs forward sync if `REMOTE` is set; no way to express "reverse only" | Added `MODE` flag (`forward`\|`reverse`\|`both`, default `both` for back-compat). Forward sync is gated on `MODE != reverse`; reverse sync gated on `MODE != forward`. Pre-flight validates MODE value and that MODE=reverse has a REVERSE_SYNC_REMOTE. | `sync.sh` |
| `rclone copy` overwrites newer destinations with older sources | Added `--update` flag to forward rclone copy. Belt-and-suspenders: even in MODE=both, Drive cannot overwrite a newer local file. | `sync.sh` |
| `private-claude-code-docs.conf` had the same remote on both ends with no MODE flag | Set `MODE="reverse"`. Updated header comment to explain the rationale and reference this COE. | `configs/private-claude-code-docs.conf` |
| Restore the actual file | `git checkout HEAD -- CLAUDE.md` then `rclone copyto local_file gdrive-personal-claude-docs:CLAUDE.md` to push corrected content to Drive without going through `sync.sh` (which would have re-clobbered before this PR's fix landed). | `private-claude-code-docs/CLAUDE.md` (out-of-tree) |

### Action items

*Claude-automatable (do first):*

| Action | Trello card | Delivering PR / artifact | Success criteria | Type | Status |
|--------|-------------|--------------------------|-----------------|------|--------|
| Add `MODE` flag + `--update` defense-in-depth to sync.sh; set `MODE=reverse` in private-claude-code-docs.conf | (none — shipped in this PR) | This PR | After merge, the next 4-hourly cron run logs `MODE=reverse — skipping forward sync` and `git status` in private-claude-code-docs stays clean for 24h | Architectural | DONE in-session |
| Add a post-sync correctness check: if `LOCAL_DIR` is a git repo, run `git status --porcelain` after sync and `notify_error` if previously-clean tree now has tracked-file modifications | [b53xIuAX](https://trello.com/c/b53xIuAX) | Follow-up PR | After implementation, manually trigger an old-conf scenario (rename Drive copy to be older) → expect macOS notification "Drive Sync clobbered tracked files in <path>" | Detection | Trello-filed (de-prioritized until post demo day) |
| Audit `automation/` and any other local rclone-using scripts for the same bidirectional-on-same-remote pattern | [5VRvKdGi](https://trello.com/c/5VRvKdGi) | Follow-up PR or "no action" note | Audit doc lists all rclone configs touched, marks each as "safe / vulnerable / fixed" | Detection | Trello-filed (de-prioritized until post demo day) |

*Requires human decision/design:*

| Action | Trello card | Delivering PR / artifact | Success criteria | Type | Status |
|--------|-------------|--------------------------|-----------------|------|--------|
| Decide whether reverse-syncing private-claude-code-docs to Google Drive is still useful, given that `claude.ai` web reads the GitHub-synced repo directly. If not, delete the reverse sync entirely (and the launchd job) rather than leaving it as one-direction-only | [8sSKRTe5](https://trello.com/c/8sSKRTe5) | Decision + (optional) PR removing the launchd job | Either: (a) Trello card moves to DONE with "kept; reason: X" comment, or (b) launchd plist deleted and `private-claude-code-docs.conf` removed | Architectural | Human decision (Trello-filed, de-prioritized until post demo day) |
| Decide on alerting/observability for this class of "silent success that destroys data" bug across ALL drive-sync targets, not just patched configs | [cLxWbPbF](https://trello.com/c/cLxWbPbF) | Decision document | A brief in `coes/` or `README.md` describing the chosen detection mechanism (post-sync verification, periodic git divergence check, Healthchecks.io ping, etc.) | Detection | Human decision (Trello-filed, de-prioritized until post demo day) |

**Trello cards:** all four filed on the Luthien board in the "de-prioritized until post demo day" list since none are critical-path for fundraising. Shortlinks linked above.

### Completeness checklist

- [x] An architectural action item exists AND is shipped in this PR (the MODE flag + --update + config update).
- [x] The architectural fix is shipped in this PR; no deferral.
- [x] No manual install step required by Scott to activate the fix. Existing launchd job will pick up the new `sync.sh` automatically on next 4-hourly tick. Verified via `--dry-run` that `MODE=reverse` skips forward sync and `MODE=both` (default) preserves existing behavior on luthien-org.conf and sw3-google-drive.conf.
- [x] **Completeness gate:** "If a similar but slightly different version of this bug appeared tomorrow in an adjacent area, would this fix prevent it?"
   - **For the same-remote bidirectional pattern in another config:** the MODE flag is opt-in for new configs but the `--update` defense-in-depth catches it even without MODE. Partial yes.
   - **For a bidirectional sync between DIFFERENT remotes where one side has older content (the luthien-org pattern):** `--update` prevents the overwrite. Yes.
   - **For sync silently succeeding while corrupting data via a non-rclone mechanism (e.g. a future cloud-sync tool added to drive-sync):** would NOT prevent. The post-sync correctness check (Detection action item, deferred) is what addresses this. Tracked.

### Remaining risk

- **Detection gap unresolved.** If the `--update` flag misbehaves in a way I haven't anticipated (e.g. clock-skew between local and Drive making "newer" the wrong file), the silent-success-destroys-data class would recur. The post-sync correctness check (deferred to follow-up PR) is the right architectural defense. Until then, manual `git status` checks remain the only detection.
- **Other Drive-tracked files still vulnerable to a different bug class.** If reverse sync somehow runs against a `LOCAL_DIR` that has been replaced by a git rebase / restore that drops content, reverse sync will faithfully push the dropped content to Drive. Out of scope for this fix; would need a "pre-sync verify against expected state" check.
- **Other surfaces (claude.ai web project knowledge synced from sw3 Drive folder)** were also reading the stale CLAUDE.md. Now that Drive is corrected, those surfaces will get the correct content on their next refresh, but no one was alerted that they'd been reading stale content for weeks.

### Meta-observation

The Feb 2026 sync-gap COE addressed liveness ("sync stops running"). This May 2026 COE addresses correctness ("sync runs and silently destroys data"). Both surfaced by chance, weeks after the bug started. The COE process is identifying these incidents but not preventing the *next class* — there is a third silent-failure mode (e.g. "reverse sync pushes git-restored content over freshly-edited Drive content") that is conceptually adjacent and not yet defended. The post-sync correctness check (deferred Detection action item) is the correct generalization.

Process-wise: this incident also revealed a Claude-collaboration pattern worth naming. The Claude Code session was about to edit CLAUDE.md when it noticed the working-tree drift. Per the [auto-memory rule](https://github.com/scottwofford/private-claude-code-docs/blob/main/CLAUDE.md): *"If you discover unexpected state like unfamiliar files, branches, or configuration, investigate before deleting or overwriting, as it may represent the user's in-progress work."* That rule fired correctly here and prevented compounding the bug. Worth keeping that rule load-bearing.
