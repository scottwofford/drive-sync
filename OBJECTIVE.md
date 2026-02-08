# Current Objective: Personal Drive Sync Setup + LinkedIn Optimization

## Status: In Progress — Paused for Session Break

## What We're Doing

Two parallel workstreams from the Feb 7-8 session:

### 1. LinkedIn Founder Profile Optimization
**Goal:** Simplify Scott's LinkedIn to project founder/investor vibe, feature scottwofford.com.

**Completed:**
- [x] Researched 20 founder LinkedIn profiles → `personal-site/founder_linkedin_profiles_research.csv`
- [x] Analyzed headline patterns (ultra-simple vs. mission-driven)
- [x] Landed on headline: "Helping Claude Code follow your rules @ Luthien | Ex-Amazon"
- [x] Analyzed About section patterns and Experience section patterns
- [x] Identified key models: Daniela Amodei, Cristina Cordova, Claire Vo

**Remaining:**
- [ ] Write About section (founder pitch style, not resume)
- [ ] Rewrite Experience section (Luthien description, Amazon bullets, trim skills lists)
- [ ] Feature scottwofford.com in Featured section
- [ ] Remove/trim certifications (show doing, not learning)
- [ ] Update GitHub bio to match new headline

### 2. Google Drive Sync Infrastructure
**Goal:** Config-driven sync script (open-source), personal Drive sync, resilience fixes.

**Completed:**
- [x] Ran luthien-org sync (31 files, 3-day gap recovered)
- [x] COE + RCA for sync gap → PR #1 on luthien-org
- [x] Resilience fixes: removed set -e, error handling on all git ops, macOS notifications, rclone auth pre-flight check
- [x] Refactored to shared config-driven script → `scottwofford/drive-sync` (public repo)
- [x] Migrated luthien-org launchd to use shared script (verified working)
- [x] Added StartInterval (every 4 hours) to launchd
- [x] Set up rclone remote `gdrive-personal` (scottwofford3@gmail.com)
- [x] Sized personal Drive (44 GB total, ~9 GB after excludes)
- [x] Updated config with excludes (Luthien, Meet Recordings, Music, Archives)

**Remaining:**
- [ ] Run initial personal Drive sync (will take ~10-15 min for ~9 GB)
- [ ] Verify sync completes and docx conversion works
- [ ] Set up launchd agent for personal Drive (every 4 hours)
- [ ] Commit drive-sync config updates to GitHub

### 3. GitHub Profile Cleanup
**Completed:**
- [x] Archived 7 bootcamp repos (2014-2015)

**Remaining:**
- [ ] Pin best repos (personal-site, scottys-llm-jedi-council, luthien-proxy)
- [ ] Update GitHub bio to match new LinkedIn headline

### 4. CLAUDE.md Updates
- [x] Added "effort scoping" preference (always include input needed from Scott)
