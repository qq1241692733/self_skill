# disk-monitor-cleanup

A zero-dependency Windows skill for monitoring C: drive usage, attributing growth, and cleaning safely.

Every run leaves a ledger, so the second run produces an exact diff — no background service required. It answers "why did C: grow?" from file last-write timestamps alone, without needing a historical baseline. Cleanup is staged: enumerate → dry run → confirm → execute → verify, with rollback support.

Zero external dependencies. Works on any Windows machine with PowerShell.

## Quick start

```powershell
cd <skill-directory>
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 run        # full scan + report (150s hard cap)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 run -Json  # structured output (for agents)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 report     # report only, no scan
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 diff       # incremental diff only (1MB threshold)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean      # cleanup dry run (nothing deleted)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean -Execute
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean-restore            # list restorable cleanups
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean-restore -Stamp <stamp>   # roll back
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 clean-restore -Stamp <stamp> -Purge
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 mark       # "remember now" (light 60s checkpoint)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diskmonitor.ps1 verify     # self-test + correctness assertions (~10s)
```

Legacy entry points still work: `disk_snapshot.ps1` (= run), `disk_report.ps1` (= report),
`disk_clean.ps1` (= clean, dry run by default), `disk_newfiles.ps1` (= report).

## Which command should I run

| You want to | Run |
| --- | --- |
| See what is taking space right now / why it grew | `run` |
| Explain an X GB drop over a period | `run` |
| Free space because C: is nearly full | `clean` (dry run) → `clean -Execute` |
| Undo a cleanup / restore deleted files | `clean-restore` → `clean-restore -Stamp <stamp>` |

## Layout

```
SKILL.md                  # full specification and operating guide
config/
  diskmonitor.conf.json   # all tunables (time caps, thresholds, retention)
lib/
  DmScan.cs               # C# scan engine (compiled on demand)
  dm-core.ps1             # orchestration core
  dm-clean.ps1            # cleanup planning and execution
  dm-report.ps1           # report rendering
scripts/
  diskmonitor.ps1         # unified entry point
  disk_snapshot.ps1       # legacy: run
  disk_report.ps1         # legacy: report
  disk_clean.ps1          # legacy: clean
  disk_newfiles.ps1       # legacy: report
references/
  migration-guide.md      # moving caches off C: for good
  growth-theory.md        # how growth attribution works
```

## Safety

- `clean` never deletes anything until you pass `-Execute`.
- Before executing, the full plan is written to disk so a run can be rolled back.
- Items at or above `QuarantineMinMB` (default 100 MB) are moved to `quarantine\<stamp>\`
  rather than deleted, and can be restored with `clean-restore -Stamp <stamp>`.
- Elevated privileges unlock visibility into shadow copies, reserved storage, MFT and USN
  journal. Without them the report states the blind spots explicitly instead of guessing.

## Requirements

- Windows with PowerShell 5.1 or later.
- No third-party packages. The C# engine is compiled on demand by `lib\DmScan.cs`.
