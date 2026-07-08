# COE: sw3-google-drive mirror "stale since Jul 2" — false alarm + a real logging trap (Jul 8, 2026)

## Summary

On 2026-07-08 the `~/build/sw3-google-drive/drive/` mirror looked stale: its newest Plaud file was `Esben 2026-07-02`, and the launchd job's configured stdout log (`sync-stdout.log`) had been frozen since May 7. This was read as "the Drive→local sync is dead; Zapier→Drive is fine, the break is Drive→local."

That diagnosis was **backwards**. The launchd sync job had run and completed cleanly every scheduled cycle the entire time (zero errors), and Drive→local was never broken. The apparent staleness was upstream: the Jul 7 recordings did not arrive in Google Drive until Jul 8 ~10:33am (Plaud device → cloud → Zapier → Drive lag). rclone correctly had nothing new to pull Jul 3–7, then mirrored each file within minutes of it appearing.

The one real defect is a **logging trap**: in `--auto` mode the script writes nothing to stdout, so the launchd-configured `stdout path` stays frozen forever and looks dead even while syncs succeed. Trusting that file (instead of the live `sync.csv`) is what produced the wrong root-cause.

## Timeline (all times PDT, from `sync.csv` and Drive-side rclone modtimes)

- **Jul 2 19:52** — `Esben` written to Drive; synced to local normally.
- **Jul 2 → Jul 8** — launchd job ran ~every 4h and logged `sync_end "Sync complete"` on every run (3× Jul 2, plus Jul 4, 5, 6, 7, 8). **Zero ERROR rows.** No new Plaud files existed in Drive to pull.
- **Jul 7 21:00 → Jul 8 11:23** — one ~14h gap in runs: the personal laptop slept overnight, and `StartInterval` launchd jobs don't fire while asleep (they catch up on wake). Not a failure.
- **Jul 8 10:33–10:37** — `Mr col` (recorded Jul 7 07:46), `Mr health fin` (Jul 7 20:07), `Mr complain`, `Simon` all *first appear in Drive* (Drive-side modtimes), i.e. Plaud→Drive delivered the Jul 7 batch ~27h after the earliest recording. A sync (manual, ~10:33) pulled them; the 11:23 auto run confirmed.
- **Jul 8 14:49** — `luke` appears in Drive and syncs. Mirror fully current.

## Root cause

Two non-bugs read as one bug, plus one real trap:

1. **Upstream lag, not a sync failure.** rclone can only mirror what is in Drive. The Jul 7 Plaud recordings were not in Drive until Jul 8 morning (device/Zapier propagation), so there was nothing to pull Jul 3–7. Confirmed authoritatively by Drive-side modtimes (`rclone lsl "gdrive-personal:2.2 Plaud/"`): every "missing" file has a Drive modtime of Jul 8 10:33+, not Jul 7.
2. **Overnight sleep batches runs.** The 14h run gap was the laptop asleep, not a dead job.
3. **The logging trap (the real, fixable defect).** In `--auto` mode `log()` writes only to `$LOCAL_DIR/sync.csv`, and rclone's stderr is redirected there too (`2>> "$LOG_FILE"`). Nothing is ever written to stdout, so launchd's configured `stdout path` (`sync-stdout.log`) never updates and has looked frozen since the auto-mode/CSV logging landed (~May 7). A diagnostician who checks that file concludes the job is dead.

## Why it wasn't caught / was mis-called

The `sync-stdout.log` path is the obvious place to look ("what does the launchd job print?"), and it had a plausible-looking frozen-since-May-7 signature. The actual live log (`sync.csv`, updated every run) and the Drive-side modtimes (which show *when a file entered Drive*) were not consulted first. There was no signal in the configured log pointing to the real one.

## Fixes applied

| Issue | Fix | Where |
|---|---|---|
| Configured stdout log dead-by-design → looks like a dead job | `--auto` mode now emits a heartbeat line to stdout at run start and end, including a pointer to the real `sync.csv` | `sync.sh` (`auto_heartbeat`) |
| Stale 28MB `sync-stdout.log` frozen since May 7 | Truncated and seeded with a header explaining the heartbeat-only design and pointing to `sync.csv` | `~/build/sw3-google-drive/sync-stdout.log` |
| ~22 `WARN Failed to convert ~$*.docx` rows per run burying real signal in `sync.csv` | Skip Office lock/temp files (`~$*`) in the docx→md conversion `find` | `sync.sh` (`convert_docx_to_md`) |
| Logging architecture undocumented | Added a "Logs / how to tell if it's healthy" section | `drive-sync/README.md` |

## Why it won't recur

The failure mode was diagnostic, not operational: a healthy job was mistaken for a dead one because the trusted log was silent by design. The heartbeat + pointer make the configured stdout log reflect liveness and route the next diagnostician to `sync.csv` on sight, so "frozen stdout log" can no longer masquerade as "dead sync." The README section records the two-source truth (heartbeat = alive; `sync.csv` = detail) and the "check Drive-side modtimes before blaming rclone" step.

## Remaining risk / not addressed

- **Plaud→Drive lag itself is not owned by drive-sync.** If timely mirroring of same-day recordings matters, the lever is the Plaud device/app upload cadence and the Zapier zap, not rclone. Out of scope here; noted so it isn't re-chased on the sync side.
- **Still no active alerting** (carried over from COE-2026-02-07): a >24h `sync.csv` gap is not surfaced anywhere. A health check remains the right future improvement.

## Lessons learned

- Before blaming a mirror, check the source-of-truth modtime (when did the file enter Drive?), not just the destination's newest file.
- A log that is silent "by design" is a trap; make the obvious log point to the real one.
- exit code 0 + a frozen stdout log is not evidence of a dead job — read the log the script actually writes.
