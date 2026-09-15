# self_skill

A personal library of Agent skills. Each subdirectory is one self-contained skill with no
cross-dependencies — take whichever you need.

English | [简体中文](./README.md)

## Skills

| Skill | Directory | What it solves | In one line |
| --- | --- | --- | --- |
| Disk cleanup | [disk-cleanup](./disk-cleanup) | Drive is full, fills up again right after cleaning, no idea where the space went | Incremental monitoring + retrospective attribution + reversible safe cleanup |

---

## Disk cleanup `disk-cleanup`

> Full specification: [disk-cleanup/SKILL.md](./disk-cleanup/SKILL.md).
> Drive C: is the most common use case, but the skill is not tied to it — `Drive` in the config
> and `-Root` on the command line can point at any drive or directory.
> Zero external dependencies. Runs on any Windows with PowerShell 5.1+.

### When to use it

- **The drive is nearly full** — you want to know what is actually eating the space instead of
  staring at a red progress bar.
- **It fills up again after cleaning** — you want to find the source that keeps growing and fix it
  at the root, not sweep the floor on a loop.
- **It grew a lot recently** — you want to answer "where did the growth land in this period",
  without having any historical baseline.
- **Tens of GB disappeared** — you want to explain why the drive lost X GB over a period.
- **You want ongoing monitoring** — without installing a resident background service.
- **You want cleanup to be safe** — dry run first, rollback available, instead of deleting blindly
  and hoping.

### Core capabilities

1. **Incremental monitoring (ledger diff)**
   Every run leaves a directory tree plus a ledger, so **the second run produces an exact diff** —
   top 15 growers, top 10 shrinkers, directories added and removed.
   No background service required: run it on demand. Run often for finer detail, run rarely and
   you still have a baseline.

2. **Retrospective attribution (answers on the very first run)**
   Using an age histogram of file last-write times (≤7 / 30 / 90 / 365 days), **a single scan
   explains "what grew in the last 30 days"**, with the top 15 heaviest-write directories and a
   per-category rollup. No historical data needed.

3. **Finding the root cause of "full again"**
   - **Residual-driven dynamic watchlist.** Watch marks live in a standalone registry
     (`registry/watch.json`), not bound to directory hierarchy.
     `residual = subtree total − sum of already-watched children`, so scanning only one level
     still leaves no blind spot.
   - **The gate looks at change, not absolute size.** A constant 5 GB directory that stopped
     growing is demoted normally; a directory that grows only 120 MB at a time but keeps growing
     earns its slot cumulatively — which is exactly what a "full again" culprit looks like.
   - **Drill-down chain:** USN-changed directories → directory mtime change → sampling →
     binary-search descent.
   - **Cure, not sweep.** Once the growth source is identified, follow
     [migration-guide](./disk-cleanup/references/migration-guide.md) to move caches off the system
     drive and stop the growth at the source.

4. **Safe cleanup (enumerate → dry run → confirm → execute → verify)**
   - Whitelist only: temp files, update download caches, shader caches, crash dumps, WER,
     thumbnail caches, npm/yarn/uv/pip caches, browser caches (**never bookmarks, passwords or
     history**).
   - **Dry run by default** — only `-Execute` deletes; the recycle bin needs an explicit
     `-RecycleBin`.
   - **Reversible.** The full plan is written to disk before execution, then each item is executed
     with its original path recorded. Items at or above `QuarantineMinMB` (default 100 MB) are
     **moved to a quarantine folder rather than deleted**, and
     `clean-restore -Stamp <stamp>` puts them back.
   - Age filter (`CleanMinAgeDays`, default 7), contents only, never the directory itself, files in
     use are skipped, and after execution it **verifies against the actual free-space delta**
     instead of trusting its own estimate.
   - Never touched: personal files, installed software, `System32`, `WinSxS` (DISM only),
     `Windows\Installer`, `hiberfil/pagefile/swapfile`, OneDrive, UWP data.

5. **Reconciliation invariant (it does not bluff)**
   `change in used space = change inside the tree + non-directory buckets (hibernation / paging /
   recycle bin / shadow copies / MFT / USN) ± delta`.
   A large delta triggers an explicit "re-scan elevated" hint. Without elevation, shadow copies,
   reserved storage, MFT and USN are invisible, and the report **states those blind spots
   explicitly rather than guessing**.

### Why it is good

- **Fast — the design choices that matter**
  - Heavy lifting is a C# engine (`lib/DmScan.cs`); **PowerShell only orchestrates and renders**.
    It never walks the tree in PowerShell (the legacy `+=` pattern takes tens of minutes on a
    large drive).
  - Measured on a Ryzen 5 5600 / NVMe: ~**12k directories/sec single-threaded**,
    ~**20k–37k/sec on 4 threads**, and ~**20–35 seconds for a 400k-directory full-drive scan**.
  - Directory trees use **prefix compression + GZip**: ~0.4 MB per 30k directories, 12 kept.
  - **Bounded scanning.** Hard caps `MaxSeconds` (default 150s) and `MaxDirs`; when the cap hits
    it stops and marks the result `CAPPED` — results are labelled incomplete, **never faked as
    complete**.
  - **Low priority.** Worker threads run under `THREAD_MODE_BACKGROUND_BEGIN`, demoting only the
    workers, not the whole process, so it never drags down the agent shell that called it.

- **Accurate — no wishful baselines**
  In on-demand mode it **never snapshots a file-level baseline up front** (it cannot); when
  file-name granularity is needed it reads the USN journal under elevation.
  `verify` runs 28 assertions covering engine layout, ledger reconciliation, watchlist gates,
  recording rules and cleanup rollback — it can prove itself trustworthy at any time.

- **Lean — the time series only records what matters**
  A point is written only when cumulative change reaches `ThetaRecMB` (not on every `run`), with a
  7-day heartbeat floor and a hard cap of `KeepSeriesPoints`. On cleanup, a segment is folded into
  a single summary line, keeping detail for only the two most recent segments.

- **Accumulating — agent reasoning becomes rules**
  Semantic judgements (which software owns this, can it be moved, can it be deleted) can be saved
  with `agent-rule` as path-glob → owner / category / cleanability / advice plus a TTL, so the
  same directory hits the rule next time instead of being re-reasoned from scratch.

### Quick start

```powershell
cd self_skill\disk-cleanup

# Full scan + report (150s hard cap by default)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 run
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 run -Json   # structured output for agents
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 report      # report only, no scan
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 diff        # incremental diff only

# Cleanup: dry run first, then execute
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean -Execute
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean-restore -Stamp <stamp>   # roll back

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 mark        # "remember now" checkpoint
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 verify      # self-test + assertions
```

**Which command should I run**

| I want to | Run |
| --- | --- |
| See what is taking space / why it grew | `run` |
| Explain an X GB drop over a period | `run` |
| Find the cause after it filled up again | `run` → read retrospective attribution and regrowth signals → fix via migration-guide |
| Free space because the drive is nearly full | `clean` (dry run) → `clean -Execute` |
| Undo a cleanup / restore files | `clean-restore` → `clean-restore -Stamp <stamp>` |
| Check whether the results are trustworthy | `verify` |

### Layout

```
disk-cleanup/
  SKILL.md                    # full spec: design premises, commands, report structure, snapshot
                              # structure, gates and residuals, safety model, performance limits
  config/diskmonitor.conf.json  # every tunable (time caps, thresholds, retention counts)
  lib/
    DmScan.cs                 # C# scan engine (compiled on demand)
    dm-core.ps1               # orchestration core
    dm-clean.ps1              # cleanup planning and execution
    dm-report.ps1             # report rendering
  scripts/
    diskmonitor.ps1           # unified entry point
    disk_snapshot.ps1         # legacy: run
    disk_report.ps1           # legacy: report
    disk_clean.ps1            # legacy: clean (dry run by default)
    disk_newfiles.ps1         # legacy: report
  references/
    migration-guide.md        # move caches off the system drive to prevent it filling up
    growth-theory.md          # how growth attribution is computed
```

### Safety boundaries

- **Scripts own determinism**: collection, statistics, thresholds, drill-down, reconciliation,
  and executing approved cleanup actions. **Numbers come only from the scripts.**
- **The agent owns semantics**: explaining what software uses a path, whether it can be moved or
  deleted, why it grew. **It must never delete anything directly.**
- **The human owns authorization**: deletion, migration, elevation, and system settings changes.

---

## Adding a skill

Create a lowercase, hyphenated directory at the repository root (for example `my-skill/`) with at
least a `SKILL.md`, then:

1. Keep the skill self-contained, without depending on other skills.
2. Add a row to the **Skills** table above — in both the English and Chinese README.
3. Add a "When to use it / Core capabilities / Why it is good" section.

Any runtime output (logs, caches, snapshots) belongs in the root `.gitignore`, not in a commit.
