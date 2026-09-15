<#
  dm-core.ps1 - disk-monitor-cleanup v4 core
  Architecture (frozen design, see D:\DiskMonitor\*.md):
    - on-demand by default (no background tasks); every run leaves a ledger => next run has a baseline
    - single-run retro attribution: file age histogram (+ USN when elevated)
    - watch registry (mark lives here, NOT inside the snapshot tree) with residual-driven promote/demote
    - tree store = full baseline each run, gzip + prefix-compressed paths, pruned to KeepTrees
    - series points follow the record rule (cumulative change >= ThetaRecMB), segments close on cleanup
    - ledger reconciliation: volume free delta must equal tree delta + non-directory buckets
    - heavy work is in DmScan.cs; PowerShell only orchestrates and renders (no += over big data)
#>

# D3 fix: this file deliberately does NOT assign $ErrorActionPreference any more.
# The entry script (scripts\diskmonitor.ps1) sets it to "Stop" and then dot-sources this file;
# assigning "SilentlyContinue" here silently downgraded that back, which is how the old
# implementation reported "cleaned N MB" while actually deleting 0 bytes.
$script:DmVersion = "4.0.0"
$script:DmSchema  = "diskmonitor-tree-v4"

# ---------------------------------------------------------------- config / paths
function Get-DmConf {
    $c = [ordered]@{
        Drive            = "C"
        Threads          = 4
        LowPriority      = $true
        MaxSeconds       = 150          # hard wall-clock cap for a full run
        MaxDirs          = 0            # 0 = unlimited (caps still apply via MaxSeconds)
        ThetaCleanMB     = 1024         # "worth cleaning" cumulative growth
        ThetaRecMB       = 256          # record threshold = ThetaCleanMB/4
        MinDeltaMB       = 32           # report threshold for a single path
        HotMinMB         = 8            # dirs with >= this much written in 30d carry the histogram
        HotTopN          = 2000
        MaxTier1         = 300          # budget: how many items may be tier-1 monitored
        MinTopFileMB     = 32
        MaxTopFiles      = 2000
        AllocProbeMinMB  = 64
        AllocProbeSuffix = @(".vhdx", ".vhd", ".vmdk", ".vdi", ".qcow2", ".iso", ".dmp", ".bin")
        KeepTrees        = 12
        KeepSeriesPoints = 2000         # hard cap on series.jsonl lines (enforced by Trim-DmSeriesPoints)
        SeriesHeartbeatDays = 7         # if a path changed at all within N days, leave one point (distinguishes "flat" from "not recorded")
        QuarantineMinMB  = 100          # single entries >= this are moved to quarantine (undoable) instead of deleted; 0 = disable
        DemoteAfterRuns  = 14
        SleepAfterRuns   = 30
        RecycleBinMaxSec = 30
        SkipNames        = @()
        SkipPaths        = @()
        CleanMinAgeDays  = 7            # only delete temp entries older than N days
        AgentRuleTtlDays = 90
        AllowElevatedExtras = $true
    }
    $p = Join-Path $PSScriptRoot "..\config\diskmonitor.conf.json"
    if (Test-Path $p) {
        try {
            $j = Get-Content $p -Raw | ConvertFrom-Json
            foreach ($prop in $j.PSObject.Properties) { $c[$prop.Name] = $prop.Value }
        } catch { }
    }
    return $c
}

function Copy-DmConf {
    param($Conf)
    # OrderedDictionary has NO .Clone() (only Hashtable does), so $Conf.Clone() dies with
    # "方法调用失败，因为 [OrderedDictionary] 不包含名为 Clone 的方法".
    # Used for per-run overrides (tests, forced thresholds) without mutating the shared config.
    $c = [ordered]@{}
    if ($Conf) { foreach ($k in $Conf.Keys) { $c[$k] = $Conf[$k] } }
    return $c
}

function Ensure-DmDir([string]$Path) {
    if ($Path -and -not (Test-Path $Path)) { New-Item -ItemType Directory -Force $Path | Out-Null }
}

function Get-DmDataDir {
    $envDir = [Environment]::GetEnvironmentVariable("DISKMON_DATA_DIR", "User")
    if (-not $envDir) { $envDir = $env:DISKMON_DATA_DIR }
    $dir = ""
    if ($envDir -and (Test-Path $envDir)) { $dir = $envDir }
    elseif (Test-Path "D:\DiskMonitor") { $dir = "D:\DiskMonitor" }
    else {
        $best = ""; $bestFree = 3GB
        try {
            Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
                if ($_.DeviceID -ne "C:" -and $_.FreeSpace -gt $bestFree) { $best = $_.DeviceID; $bestFree = $_.FreeSpace }
            }
        } catch { }
        if ($best) { $dir = $best + "\DiskMonitor" } else { $dir = Join-Path $env:USERPROFILE ".diskmonitor" }
        if ($envDir) { $dir = $envDir }
    }
    # subdirectories must exist on EVERY branch, including the env-var / legacy early returns:
    # a missing "series" or "events" folder used to swallow Add-Content silently.
    foreach ($sub in @("trees", "registry", "series", "events", "baselines")) { Ensure-DmDir (Join-Path $dir $sub) }
    return $dir
}

function Test-DmElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-DmBytes([double]$b) {
    if ($b -ge 1GB) { return ("{0:N2} GB" -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ("{0:N0} MB" -f ($b / 1MB)) }
    return ("{0:N0} KB" -f ($b / 1KB))
}

function Write-DmJson([string]$Path, $Obj, [int]$Depth = 8) {
    $json = $Obj | ConvertTo-Json -Depth $Depth
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Write-DmEvent {
    param([string]$DataDir, [string]$Kind, $Payload)
    $e = [ordered]@{ t = (Get-Date).ToString("o"); kind = $Kind; data = $Payload }
    $line = $e | ConvertTo-Json -Depth 6 -Compress
    $p = Join-Path $DataDir "events\events.jsonl"
    Ensure-DmDir (Split-Path $p -Parent)
    Add-Content -Path $p -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- engine
function Initialize-DmEngine {
    if ([type]::GetType("DmFast.Engine") ) { return $true }
    $cs = Join-Path $PSScriptRoot "DmScan.cs"
    if (-not (Test-Path $cs)) { return $false }
    try {
        Add-Type -Path $cs -ErrorAction Stop
    } catch {
        try { Add-Type -Path $cs -ErrorAction Stop } catch { return $false }
    }
    try { [DmFast.Engine]::SelfCheck() } catch { return $false }
    return $true
}

function New-DmOpt {
    param($Conf, [int]$Threads = 0, [double]$MaxSeconds = -1, [int]$HotMinMB = -1)
    $o = New-Object DmFast.Opt
    $o.Threads = if ($Threads -gt 0) { $Threads } else { [int]$Conf.Threads }
    $o.MaxSeconds = if ($MaxSeconds -ge 0) { $MaxSeconds } else { [double]$Conf.MaxSeconds }
    $o.MaxDirs = [long]$Conf.MaxDirs
    $o.LowPriority = [bool]$Conf.LowPriority
    $o.HotMinBytes = if ($HotMinMB -gt 0) { [long]$HotMinMB * 1MB } else { [long]$Conf.HotMinMB * 1MB }
    $o.HotTopN = [int]$Conf.HotTopN
    $o.AllocProbeMinBytes = [long]$Conf.AllocProbeMinMB * 1MB
    $o.AllocProbeSuffix = [string[]]$Conf.AllocProbeSuffix
    $o.MinTopFileBytes = [long]$Conf.MinTopFileMB * 1MB
    $o.MaxTopFiles = [int]$Conf.MaxTopFiles
    $o.SkipNames = [string[]]$Conf.SkipNames
    $o.SkipPaths = [string[]]$Conf.SkipPaths
    return $o
}

function Invoke-DmScan {
    param($Conf, [string]$Root = "", [int]$Threads = 0, [double]$MaxSeconds = -1, [int]$HotMinMB = -1)
    if (-not (Initialize-DmEngine)) { throw "扫描引擎编译失败（lib\DmScan.cs）" }
    if (-not $Root) { $Root = ([string]$Conf.Drive).TrimEnd(":") + ":\" }
    $o = New-DmOpt -Conf $Conf -Threads $Threads -MaxSeconds $MaxSeconds -HotMinMB $HotMinMB
    $r = [DmFast.Engine]::Scan($Root, $o)
    [DmFast.Engine]::BuildIndex($r)
    return $r
}

# ---------------------------------------------------------------- tree store
function Save-DmTree {
    param([string]$DataDir, $Scan)
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $p = Join-Path $DataDir ("trees\tree_{0}.bin" -f $ts)
    [DmFast.Engine]::Save($Scan, $p)
    $meta = [ordered]@{
        file = (Split-Path $p -Leaf); at = $Scan.At.ToString("o"); root = $Scan.Root
        state = $Scan.State; sec = [math]::Round($Scan.Sec, 2); dirs = $Scan.Dirs; files = $Scan.Files
        bytes = $Scan.Bytes; alloc = $Scan.Alloc; denied = $Scan.Denied
        size_kb = [math]::Round((Get-Item $p).Length / 1KB)
    }
    Write-DmEvent -DataDir $DataDir -Kind "tree.saved" -Payload $meta
    return $p
}

function Get-DmTrees {
    param([string]$DataDir, [int]$Limit = 0)
    $d = Join-Path $DataDir "trees"
    if (-not (Test-Path $d)) { return @() }
    $l = Get-ChildItem $d -Filter "tree_*.bin" | Sort-Object Name
    if ($Limit -gt 0) { $l = $l | Select-Object -Last $Limit }
    return @($l)
}

function Remove-DmOldTrees {
    param([string]$DataDir, [int]$Keep)
    $l = Get-DmTrees -DataDir $DataDir
    if ($l.Count -le $Keep) { return 0 }
    $drop = $l | Select-Object -First ($l.Count - $Keep)
    foreach ($f in $drop) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
    return $drop.Count
}

function Get-DmLastTree {
    param([string]$DataDir, [int]$SkipLatest = 0)
    $l = Get-DmTrees -DataDir $DataDir
    $idx = $l.Count - 1 - $SkipLatest
    if ($idx -lt 0) { return $null }
    return $l[$idx]
}

# ---------------------------------------------------------------- ledger (non-directory buckets)
function Get-DmCmdOut {
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutSec = 20)
    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo.FileName = $Exe
        $p.StartInfo.Arguments = ($ArgList -join " ")
        $p.StartInfo.UseShellExecute = $false
        $p.StartInfo.RedirectStandardOutput = $true
        $p.StartInfo.RedirectStandardError = $true
        $p.StartInfo.CreateNoWindow = $true
        [void]$p.Start()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; return "" }
        return $p.StandardOutput.ReadToEnd()
    } catch { return "" }
}

function Get-DmLedger {
    param($Conf, [string]$DataDir)
    $drive = ([string]$Conf.Drive).TrimEnd(":") + ":"
    $led = [ordered]@{
        at = (Get-Date).ToString("o"); drive = $drive; elevated = (Test-DmElevated)
        total = 0; free = 0; used = 0
        hiberfil = 0; pagefile = 0; swapfile = 0; recyclebin = 0
        vss = -1; mft = -1; usn = -1; reserved = -1
        extras_note = ""
    }
    try {
        $di = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive)
        $led.total = [long]$di.Size; $led.free = [long]$di.FreeSpace; $led.used = [long]($di.Size - $di.FreeSpace)
    } catch { }
    foreach ($n in @("hiberfil.sys", "pagefile.sys", "swapfile.sys")) {
        $p = Join-Path $drive "\$n"
        if (Test-Path $p) {
            try { $led[$n.Replace(".sys", "")] = [long](Get-Item $p -Force).Length } catch { }
        }
    }
    # recycle bin: measured by the engine instead of Shell COM (COM can block)
    try {
        $rbRoot = Join-Path $drive "\`$Recycle.Bin"
        if (Test-Path $rbRoot) {
            $rr = Invoke-DmScan -Conf $Conf -Root $rbRoot -Threads 2 -MaxSeconds $Conf.RecycleBinMaxSec
            $led.recyclebin = [long]$rr.Bytes
        }
    } catch { }
    if ($led.elevated -and $Conf.AllowElevatedExtras) {
        $v = Get-DmCmdOut -Exe "vssadmin.exe" -ArgList @("list", "shadowstorage") -TimeoutSec 15
        if ($v -match '(?m)^\s*(已用|Used)\D*([\d.,]+)\s*(GB|MB|TB)') {
            $n = [double]($matches[2] -replace ",", ""); $u = $matches[3]
            $led.vss = [long]($n * (if ($u -eq "GB") { 1GB } elseif ($u -eq "TB") { 1TB } else { 1MB }))
        }
        $f = Get-DmCmdOut -Exe "fsutil.exe" -ArgList @("fsinfo", "ntfsinfo", $drive) -TimeoutSec 15
        if ($f -match '(?im)mft\D*:?\s*0x([0-9a-f]+)') { $led.mft = [long][Convert]::ToInt64($matches[1], 16) }
        $j = Get-DmCmdOut -Exe "fsutil.exe" -ArgList @("usn", "queryjournal", $drive) -TimeoutSec 15
        if ($j -match '(?im)(Next Usn|下一个 USN)\D*:?\s*0x([0-9a-f]+)') { $led.usn = [long][Convert]::ToInt64($matches[2], 16) }
    } else {
        $led.extras_note = "未提权：卷影/MFT/USN 未采集（盲区）"
    }
    return $led
}

# ---------------------------------------------------------------- watch registry (marks live here)
function Get-DmRegistry {
    param([string]$DataDir)
    $p = Join-Path $DataDir "registry\watch.json"
    if (-not (Test-Path $p)) { return [ordered]@{ updated = ""; items = @() } }
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        # items are re-hydrated as ordered hashtables so new fields can be added on later runs
        $items = @()
        foreach ($i in @($j.items)) {
            $h = [ordered]@{}
            foreach ($pp in $i.PSObject.Properties) { $h[$pp.Name] = $pp.Value }
            if (-not $h.Contains("memory_of")) { $h["memory_of"] = @() }
            $items += $h
        }
        $reg = [ordered]@{}
        foreach ($pp in $j.PSObject.Properties) { if ($pp.Name -ne "items") { $reg[$pp.Name] = $pp.Value } }
        $reg["items"] = $items
        return $reg
    } catch { return [ordered]@{ updated = ""; items = @() } }
}

function Save-DmRegistry {
    param([string]$DataDir, $Reg)
    $Reg.updated = (Get-Date).ToString("o")
    Write-DmJson -Path (Join-Path $DataDir "registry\watch.json") -Obj $Reg
}

function New-DmItem {
    param([string]$Path, [string]$Reason, [int]$Tier = 1, $Attr = $null)
    return [ordered]@{
        path = $Path; scope = "rollup"; tier = $Tier; state = "ACTIVE"; reason = $Reason
        created = (Get-Date).ToString("o"); zero_streak = 0; hits = 0
        app = $(if ($Attr) { $Attr.App } else { "" }); category = $(if ($Attr) { $Attr.Category } else { "" })
        clean = $(if ($Attr) { $Attr.Clean } else { "" })
        last_mb = 0; last_files = 0; n30_mb = 0; rate_mb_day = 0; score = 0; memory_of = @()
        gap_mb = 0; gap_delta_mb = 0; runs = 0
        # credit baselines: the size/residual at the moment this item was last credited a
        # tier-1 slot. The promotion gate is "cumulative increase since this baseline".
        hit_mb = 0; hit_gap = 0
    }
}

function Update-DmItemGate {
    param($It, [double]$NowMb, [double]$ResidualMb, [double]$N30Mb, $Conf)
    # The D1 promotion gate + credit/demote state machine for ONE item.
    #
    # Deliberately pure with respect to the engine and the filesystem, so `verify` can drive it
    # through many simulated runs and assert the behaviour without scanning anything.
    #
    # DESIGN: every growth test is CHANGE - a cumulative increase since the item was last
    # credited - never a level compared against a change threshold. The old code compared an
    # absolute quantity against ThetaRecMB (first the subtree size, which pinned every large
    # directory forever; then, in a first attempt at a fix, the 30-day write volume, which still
    # pinned 283 of 300 items because ThetaRecMB is far too low a bar for a 30-day total). Both
    # are the same category error and both froze tier-1 into "the 300 biggest directories" with
    # an unreachable demote branch.
    #
    # Cumulative-since-credit, rather than a per-run delta, is what makes this work at any
    # cadence: a directory growing 200MB a day and one that grew 3GB at once both earn a slot,
    # merely after a different number of runs. It is the same semantics the series record rule
    # uses (ThetaRecMB of change since the last recorded point).
    $theta = [double]$Conf.ThetaRecMB        # growth credited since the last credit (a CHANGE)
    $thetaClean = [double]$Conf.ThetaCleanMB # 30-day write volume that counts as real churn (a LEVEL)
    if (-not $It.Contains("hit_mb")) { $It["hit_mb"] = [double]$It.last_mb }
    if (-not $It.Contains("hit_gap")) { $It["hit_gap"] = [double]$It.gap_mb }
    $sinceMb = $NowMb - [double]$It.hit_mb         # subtree net growth since the last credit
    $sinceGap = $ResidualMb - [double]$It.hit_gap  # ...of the part no watch item names
    $It.gap_delta_mb = [math]::Round($sinceGap, 1)
    $signals = 0
    if ($sinceMb -ge $theta) { $signals++ }      # the subtree grew -> keep watching it
    if ($sinceGap -ge $theta) { $signals++ }     # the unnamed remainder grew -> new deep dirs to name
    # A directory written to this much within 30 days is genuinely churning. A LEVEL is fine here
    # because (a) the bar is ThetaCleanMB ("worth cleaning"), not ThetaRecMB, so only real top
    # churners qualify (22 of 480 on this machine, not 283) and (b) the window rolls, so the pin
    # decays on its own once the writes stop.
    if ($N30Mb -ge $thetaClean) { $signals++ }
    # No special "first sighting" rule: a new directory starts with its credit baseline equal to
    # its current size, so it rides the DemoteAfterRuns grace window until it earns a slot by
    # growing or churning. One bar for growth, one for churn, no exceptions.
    if ($signals -gt 0) {
        $It.zero_streak = 0
        $It.hits = [int]$It.hits + 1
        $It.tier = 1; $It.state = "ACTIVE"
        $It.hit_mb = $NowMb                     # restart the growth window from here
        $It.hit_gap = [math]::Round($ResidualMb, 1)
    } else {
        $It.zero_streak = [int]$It.zero_streak + 1
        if ([int]$It.zero_streak -ge [int]$Conf.SleepAfterRuns) { $It.tier = 2; $It.state = "DORMANT" }
        elseif ([int]$It.zero_streak -ge [int]$Conf.DemoteAfterRuns) { $It.tier = 2 }
    }
    return $signals
}

function Update-DmRegistry {
    param([string]$DataDir, $Conf, $Scan, $Ledger)
    $reg = Get-DmRegistry -DataDir $DataDir
    # Get-DmRegItems, not @($reg.items): @() over a List[object] is a PS 5.1 binder crash.
    $items = Get-DmRegItems -Reg $reg
    $known = @{}
    foreach ($it in $items) { $known[[string]$it.path] = $it }

    # 1) seed: top-level children of the drive + known hot categories (first ever run)
    if ($items.Count -eq 0) {
        foreach ($e in [DmFast.Engine]::ShallowList($Scan, 2, 256MB, 200)) {
            $a = Get-DmAttribution -Path $e.P -DataDir $DataDir
            $it = New-DmItem -Path $e.P -Reason "seed:top" -Tier 1 -Attr $a
            # stats are filled immediately, otherwise a brand-new item shows up as score 0 on the first run
            $it.last_mb = [math]::Round($e.CurB / 1MB, 1)
            $it.n30_mb = [math]::Round($e.N30 / 1MB, 1)
            $it.last_files = $e.CurF
            $it.gap_mb = 0
            $it.hit_mb = $it.last_mb    # credit baseline starts at the seed size
            $it.hit_gap = 0
            # score must be dominated by the actual 30-day write volume; category risk is only a nudge
            $it.score = [math]::Round(($e.N30 / 1MB) / 10.0 + [double]$a.HotBias / 10.0, 1)
            $it.at = $Scan.At.ToString("o")
            $items += $it
            $known[$e.P] = $it
        }
    }

    # 2) update stats for every item; residual = own subtree minus monitored children
    #    (the promotion thresholds live in Update-DmItemGate, which owns the whole gate)
    # frontier sums: attribute each item's rollup to its NEAREST monitored ancestor, so that a residual
    # means exactly "the part of this subtree that no watch item names" (nesting must not double count).
    $frontier = @{}
    foreach ($it2 in $items) {
        $p2 = [string]$it2.path
        if (-not $p2) { continue }
        $e2 = [DmFast.Engine]::Get($Scan, $p2)
        if (-not $e2) { continue }
        $mb2 = $e2.B / 1MB
        $anc = $p2
        while ($true) {
            $li2 = $anc.LastIndexOf("\")
            if ($li2 -lt 2) { break }
            $anc = $anc.Substring(0, $li2)
            if ($known.ContainsKey($anc)) {
                if (-not $frontier.ContainsKey($anc)) { $frontier[$anc] = 0.0 }
                $frontier[$anc] += $mb2
                break
            }
        }
    }
    foreach ($it in $items) {
        # always keep the reporting fields well-defined, even for items whose path vanished
        if (-not $it.Contains("gap_mb")) { $it["gap_mb"] = 0 }
        if (-not $it.Contains("gap_delta_mb")) { $it["gap_delta_mb"] = 0 }
        if (-not $it.Contains("n30_mb")) { $it["n30_mb"] = 0 }
        if (-not $it.Contains("score")) { $it["score"] = 0 }
        if (-not $it.Contains("last_mb")) { $it["last_mb"] = 0 }
        if (-not $it.Contains("runs")) { $it["runs"] = 0 }
        # credit baselines for items written by an older version: start the growth window at the
        # values we already have, so no item gets retroactive credit for history it lived through.
        if (-not $it.Contains("hit_mb")) { $it["hit_mb"] = [double]$it.last_mb }
        if (-not $it.Contains("hit_gap")) { $it["hit_gap"] = [double]$it.gap_mb }
        $e = [DmFast.Engine]::Get($Scan, [string]$it.path)
        if (-not $e) {
            $it.state = "ARCHIVED"; $it.tier = 2
            $it.runs = [int]$it.runs + 1
            continue
        }
        $nowMb = [math]::Round($e.B / 1MB, 1)
        $childSum = 0.0
        if ($frontier.ContainsKey([string]$it.path)) { $childSum = [double]$frontier[[string]$it.path] }
        $residualMb = $nowMb - $childSum                       # absolute unnamed mass -> DISPLAY ONLY
        $it.n30_mb = [math]::Round($e.N30 / 1MB, 1)
        $it.last_files = $e.F
        $it.gap_mb = [math]::Round($residualMb, 1)
        $attr = Get-DmAttribution -Path $e.P -DataDir $DataDir
        $it.app = $attr.App; $it.category = $attr.Category; $it.clean = $attr.Clean
        $it.score = [math]::Round(($e.N30 / 1MB) / 10.0 + ($attr.HotBias) / 10.0, 1)
        $it.last_mb = $nowMb
        $it.at = $Scan.At.ToString("o")
        $it.runs = [int]$it.runs + 1

        # ---- D1 promotion gate (change-driven; see Update-DmItemGate for the full rationale) ----
        [void](Update-DmItemGate -It $it -NowMb $nowMb -ResidualMb $residualMb -N30Mb ([double]$it.n30_mb) -Conf $Conf)
    }

    # 3) promote newly discovered hot deep dirs (the "tag a deep directory" behaviour)
    if ($Scan) {
        foreach ($e in [DmFast.Engine]::HotList($Scan, 3000)) {
            if ($known.ContainsKey($e.P)) { continue }
            if ($items.Count -ge ([int]$Conf.MaxTier1 + 600)) { break }
            $attr = Get-DmAttribution -Path $e.P -DataDir $DataDir
            # a hot directory must show real volume to earn a watch slot (bias only breaks ties)
            if (($e.N30 / 1MB) -lt 32) { continue }
            $it = New-DmItem -Path $e.P -Reason "promote:hot" -Tier 1 -Attr $attr
            $it.last_mb = [math]::Round($e.CurB / 1MB, 1)
            $it.n30_mb = [math]::Round($e.N30 / 1MB, 1)
            $it.last_files = $e.CurF
            $it.gap_mb = 0
            $it.hit_mb = $it.last_mb    # credit baseline = the size at admission (no retroactive credit)
            $it.hit_gap = 0
            $it.score = [math]::Round(($e.N30 / 1MB) / 10.0 + [double]$attr.HotBias / 10.0, 1)
            $it.at = $Scan.At.ToString("o")
            $items += $it
            $known[$e.P] = $it
        }
    }

    # 4) tier-1 budget: keep the highest scores, remember what the parent used to focus on
    $t1 = @($items | Where-Object { $_.tier -eq 1 -and $_.state -ne "ARCHIVED" })
    if ($t1.Count -gt [int]$Conf.MaxTier1) {
        $keep = $t1 | Sort-Object -Property { [double]$_.score } -Descending | Select-Object -First ([int]$Conf.MaxTier1)
        $keepPaths = @{}; foreach ($k in $keep) { $keepPaths[[string]$k.path] = $true }
        foreach ($it in $t1) {
            if (-not $keepPaths.ContainsKey([string]$it.path)) {
                $it.tier = 2
                $li = ([string]$it.path).LastIndexOf("\")
                if ($li -gt 2) {
                    $parent = ([string]$it.path).Substring(0, $li)
                    foreach ($pit in $items) {
                        if ([string]$pit.path -eq $parent) {
                            $mem = @($pit.memory_of) + @($it.path)
                            $pit.memory_of = @($mem | Select-Object -Unique | Select-Object -Last 3)
                        }
                    }
                }
            }
        }
    }

    # 5) stats of the registry itself for the report
    $reg.items = $items
    $reg.tier1_count = @($items | Where-Object { $_.tier -eq 1 }).Count
    $reg.tier2_count = @($items | Where-Object { $_.tier -eq 2 }).Count
    $reg.dormant_count = @($items | Where-Object { $_.state -eq "DORMANT" }).Count
    Save-DmRegistry -DataDir $DataDir -Reg $reg
    return $reg
}

# ---------------------------------------------------------------- collection safety
function Get-DmRegItems {
    param($Reg)
    # Materialize a registry's item collection into a PLAIN ARRAY.
    #
    # Why this exists: on Windows PowerShell 5.1, the array-subexpression operator @() applied to a
    # System.Collections.Generic.List[object] throws "ArgumentException: 参数类型不匹配" from
    # PSEnumerableBinder.MaybeDebase -> Expression.Condition. It is NOT about the elements: a
    # List[object] holding plain ints fails exactly the same way, while List[string] and object[]
    # are fine. foreach and pipelines are unaffected, so we copy through a loop.
    #
    # The production registry (Get-DmRegistry) happens to hand back object[], which is why a bare
    # @($Reg.items) usually survives - but that is luck, not a contract. Any caller (tests, future
    # report code) that builds a List[object] would take the whole run down.
    $r = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Reg) {
        $v = $Reg.items
        if ($null -ne $v) {
            if ($v -is [System.Collections.IList]) { foreach ($x in $v) { $r.Add($x) } }
            else { $r.Add($v) }   # a single item (e.g. a one-entry registry from ConvertFrom-Json)
        }
    }
    return ,$r.ToArray()
}

# ---------------------------------------------------------------- series (record rule + segments)
function Get-DmSeriesIndex {
    param([string]$SeriesPath)
    # Per-path last recorded point.
    # D2 fix: the WHOLE file must be read. With ~500 watched paths a "-Tail 200" window missed
    # most of them, so every path looked brand new on every run, the record rule (ThetaRecMB)
    # was bypassed, and series.jsonl grew without bound.
    $idx = @{}
    if (-not (Test-Path $SeriesPath)) { return $idx }
    foreach ($line in [System.IO.File]::ReadLines($SeriesPath)) {
        if (-not $line) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if (-not $o.path) { continue }
        $idx[[string]$o.path] = $o
    }
    return $idx
}

function Trim-DmSeriesPoints {
    param([string]$DataDir, $Conf)
    # D2 fix: KeepSeriesPoints was declared in config but never enforced anywhere.
    # This is the hard backstop; per-segment roll-up summaries live in series\segments.jsonl.
    $p = Join-Path $DataDir "series\series.jsonl"
    if (-not (Test-Path $p)) { return 0 }
    $cap = [int]$Conf.KeepSeriesPoints
    if ($cap -le 0) { return 0 }
    $all = @([System.IO.File]::ReadAllLines($p))
    if ($all.Count -le $cap) { return 0 }
    $keep = @($all[($all.Count - $cap)..($all.Count - 1)])
    [System.IO.File]::WriteAllLines($p, $keep, (New-Object System.Text.UTF8Encoding($false)))
    return ($all.Count - $keep.Count)
}

function Add-DmSeriesPoint {
    param([string]$DataDir, $Conf, $Reg, $Ledger, $Scan)
    $p = Join-Path $DataDir "series\series.jsonl"
    Ensure-DmDir (Split-Path $p -Parent)
    $last = Get-DmSeriesIndex -SeriesPath $p
    $theta = [double]$Conf.ThetaRecMB
    $heartbeat = [double]$Conf.SeriesHeartbeatDays
    $now = $Scan.At
    $added = 0
    $out = New-Object System.Collections.Generic.List[string]
    # Get-DmRegItems, not @($Reg.items): @() over a List[object] is a PS 5.1 binder crash.
    foreach ($it in (Get-DmRegItems -Reg $Reg)) {
        if ($it.state -eq "ARCHIVED") { continue }
        $path = [string]$it.path
        if (-not $path) { continue }
        $prev = $last[$path]
        $mb = [double]$it.last_mb
        if ($prev) {
            # cumulative since the last RECORDED point (a run below the threshold writes nothing,
            # so the next run is compared against the same older point and the change accumulates)
            $delta = [math]::Abs($mb - [double]$prev.mb)
            $stale = 999.0
            try { $stale = ($now - ([datetime]$prev.t)).TotalDays } catch { }
            $write = ($delta -ge $theta) -or (($stale -ge $heartbeat) -and ($delta -gt 0))
        } else {
            $write = $true
        }
        if ($write) {
            $pt = [ordered]@{ t = $now.ToString("o"); path = $path; mb = $mb; files = [long]$it.last_files; n30_mb = [double]$it.n30_mb; tier = [int]$it.tier; kind = "point" }
            $out.Add(($pt | ConvertTo-Json -Compress))
            $added++
        }
    }
    # the volume point is unconditional: it is what lets you distinguish "flat" from "not recorded"
    $out.Add(([ordered]@{ t = $now.ToString("o"); path = "<volume>"; mb = [math]::Round($Ledger.used / 1MB, 1); free_mb = [math]::Round($Ledger.free / 1MB, 1); kind = "volume" } | ConvertTo-Json -Compress))
    if ($out.Count -gt 0) { Add-Content -Path $p -Value $out.ToArray() -Encoding UTF8 }
    [void](Trim-DmSeriesPoints -DataDir $DataDir -Conf $Conf)
    return $added
}

function Close-DmSegment {
    param([string]$DataDir, [string]$Reason, [long]$FreedBytes, $LedgerBefore, $LedgerAfter)
    $p = Join-Path $DataDir "series\segments.jsonl"
    Ensure-DmDir (Split-Path $p -Parent)
    $pts = @()
    $sp = Join-Path $DataDir "series\series.jsonl"
    if (Test-Path $sp) {
        foreach ($line in (Get-Content $sp -Encoding UTF8)) {
            try { $o = $line | ConvertFrom-Json; if ($o.kind -eq "volume") { $pts += $o } } catch { }
        }
    }
    $seg = [ordered]@{
        t = (Get-Date).ToString("o"); reason = $Reason; points = $pts.Count
        start = $(if ($pts.Count) { $pts[0].t } else { "" })
        mb_first = $(if ($pts.Count) { $pts[0].mb } else { 0 })
        peak_mb = $(if ($pts.Count) { ($pts | Measure-Object -Property mb -Maximum).Maximum } else { 0 })
        freed_mb = [math]::Round($FreedBytes / 1MB, 1)
        before_mb = $(if ($LedgerBefore) { [math]::Round($LedgerBefore.used / 1MB, 1) } else { 0 })
        after_mb = $(if ($LedgerAfter) { [math]::Round($LedgerAfter.used / 1MB, 1) } else { 0 })
    }
    Add-Content -Path $p -Value (($seg | ConvertTo-Json -Compress)) -Encoding UTF8
    # keep the last two segments in detail.
    # D2 fix: prune EVERY kind of point older than the 3rd-newest segment, not only the volume
    # points - the per-path points used to survive forever and were the bulk of the growth.
    if (Test-Path $p) {
        $segs = @(Get-Content $p -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
        if ($segs.Count -gt 2) {
            $cut = $segs[$segs.Count - 3].t
            $keep = New-Object System.Collections.Generic.List[string]
            foreach ($line in (Get-Content $sp -Encoding UTF8)) {
                try { $o = $line | ConvertFrom-Json } catch { continue }
                if ($o.t -lt $cut) { continue }
                $keep.Add($line)
            }
            [System.IO.File]::WriteAllLines($sp, $keep.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    return $seg
}

# ---------------------------------------------------------------- attribution rules
# hot bias steers the watch-list budget: regenerative caches / virtual disks / logs are worth watching
$script:DmRules = @(
    @("appdata\\local\\google\\chrome\\user data\\[^\\]+\\cache", "Chrome缓存", "浏览器", "安全可清", 30),
    @("appdata\\local\\google\\chrome\\user data\\[^\\]+\\code cache", "Chrome代码缓存", "浏览器", "安全可清", 20),
    @("appdata\\local\\microsoft\\edge\\user data\\[^\\]+\\cache", "Edge缓存", "浏览器", "安全可清", 30),
    @("appdata\\local\\microsoft\\edge\\user data\\[^\\]+\\code cache", "Edge代码缓存", "浏览器", "安全可清", 20),
    @("appdata\\local\\temp", "用户临时文件", "临时文件", "安全可清", 20),
    @("windows\\temp", "系统临时文件", "临时文件", "安全可清", 20),
    @("windows\\softwaredistribution\\download", "Windows更新缓存", "系统更新", "安全可清", 40),
    @("windows\\softwaredistribution\\deliveryoptimization", "传递优化缓存", "系统更新", "安全可清", 40),
    @("windows\\winsxs", "WinSxS组件存储", "系统更新", "需管理员", 60),
    @("windows\\installer", "Windows安装器缓存", "系统", "禁止清理", 0),
    @("windows\\logs", "系统日志", "日志转储", "安全可清", 10),
    @("windows\\minidump", "蓝屏小转储", "日志转储", "安全可清", 10),
    @("windows\\livekernelreports", "内核实时报告", "日志转储", "安全可清", 10),
    @("windows\\cbstemp", "CBS更新临时", "系统更新", "安全可清", 20),
    @("programdata\\microsoft\\windows\\wer", "错误报告WER", "日志转储", "安全可清", 10),
    @("programdata\\package cache", "安装器缓存", "系统", "需管理员", 10),
    @("programdata\\microsoft\\windows defender", "Defender", "系统", "禁止清理", 10),
    @("appdata\\local\\d3dscache", "DirectX着色器缓存", "缓存·可再生", "安全可清", 20),
    @("appdata\\local\\nvidia\\(dxcache|glcache)", "NVIDIA着色器缓存", "缓存·可再生", "安全可清", 20),
    @("appdata\\local\\crashdumps", "崩溃转储", "日志转储", "安全可清", 10),
    @("appdata\\local\\packages", "UWP应用数据", "应用数据", "禁止清理", 10),
    @("appdata\\local\\microsoft\\windows\\explorer", "资源管理器缓存", "系统", "安全可清", 5),
    @("appdata\\local\\npm-cache", "npm缓存", "开发者工具", "安全可清", 30),
    @("appdata\\local\\yarn\\cache", "Yarn缓存", "开发者工具", "安全可清", 20),
    @("appdata\\local\\pnpm", "pnpm缓存", "开发者工具", "安全可清", 20),
    @("appdata\\local\\uv\\cache", "UV缓存", "开发者工具", "安全可清", 30),
    @("appdata\\local\\pip\\cache", "pip缓存", "开发者工具", "安全可清", 30),
    @("appdata\\local\\ms-playwright", "Playwright浏览器", "开发者工具", "安全可清", 30),
    @("driverstore\\filerepository", "驱动仓库(旧驱动包)", "系统", "需管理员", 30),
    @("\\edgecore\\|\\edgewebview\\", "Edge运行时组件", "浏览器", "需确认", 25),
    @("microsoft\\edge\\application", "Edge程序目录", "浏览器", "需确认", 15),
    @("google\\googleupdater|google\\chrome\\application", "Chrome/更新器", "浏览器", "需确认", 15),
    @("-updater\\|\\installer\.exe$|\\app_shell_cache_|\\app_package_", "应用更新安装包/外壳缓存", "缓存·可再生", "安全可清", 25),
    @("\\wsl\\|docker\\", "WSL/Docker 镜像", "虚拟机", "需管理员", 60),
    @("appdata\\local\\jetbrains", "JetBrains缓存/索引", "开发者工具", "需配置迁移", 40),
    @("appdata\\roaming\\jetbrains", "JetBrains配置", "开发者工具", "禁止清理", 0),
    @("appdata\\roaming\\code", "VS Code", "开发者工具", "禁止清理", 10),
    @("appdata\\local\\code", "VS Code数据", "开发者工具", "禁止清理", 10),
    @("node_modules", "node_modules依赖", "开发者工具", "需配置迁移", 40),
    @("\\.gradle|\\.m2|\\.nuget|\\.cargo|\\.conda", "构建/包缓存", "开发者工具", "安全可清", 40),
    @("\\.cache", "通用缓存目录", "缓存·可再生", "安全可清", 30),
    @("appdata\\local\\docker|docker\\wsl", "Docker数据", "虚拟机", "需管理员", 60),
    @("\.vhdx$|\.vhd$|\.vmdk$|\.vdi$|\.qcow2$", "虚拟磁盘(vhdx)", "虚拟机", "需管理员", 80),
    @("appdata\\roaming\\tencent|appdata\\local\\tencent", "腾讯系(微信/QQ)", "通讯社交", "需配置迁移", 50),
    @("wechat files|tencent files|qqnt", "微信/QQ文件", "通讯社交", "需配置迁移", 50),
    @("appdata\\local\\netease", "网易云音乐", "媒体", "需配置迁移", 30),
    @("appdata\\local\\doubao", "豆包", "应用数据", "需配置迁移", 40),
    @("appdata\\roaming\\kingsoft|appdata\\local\\kingsoft", "WPS", "应用数据", "需配置迁移", 20),
    @("appdata\\roaming\\adobe|programdata\\adobe", "Adobe", "媒体", "需配置迁移", 20),
    @("appdata\\local\\mihoyo|appdata\\local\\hoyoverse|appdata\\roaming\\mihoyo", "米哈游游戏", "游戏", "需配置迁移", 40),
    @("appdata\\local\\ollama|\\.ollama", "Ollama模型", "AI模型", "需配置迁移", 60),
    @("huggingface", "HuggingFace模型", "AI模型", "需配置迁移", 60),
    @("onedrive", "OneDrive", "个人数据", "禁止清理", 0),
    @("\\downloads$|\\downloads\\", "下载目录", "个人数据", "禁止清理", 0),
    @("\\$recycle\\.bin", "回收站", "临时文件", "需确认", 0),
    @("windows\\.old", "Windows.old", "系统更新", "需确认", 0),
    @("\\logs?\\|\\log\\|\\temp\\|\\cache\\|\\caches\\", "应用缓存(通用)", "缓存·可再生", "安全可清", 15),
    @("", "其他/未知", "未知", "未知", 0)
)

function Get-DmAttribution {
    param([string]$Path, [string]$DataDir = "")
    if ($DataDir) {
        $ruleFile = Join-Path $DataDir "events\agent_rules.jsonl"
        if (Test-Path $ruleFile) {
            foreach ($line in (Get-Content $ruleFile -Tail 200 -Encoding UTF8)) {
                try {
                    $r = $line | ConvertFrom-Json
                    if ($r.ttl_until -and ([datetime]$r.ttl_until -lt (Get-Date))) { continue }
                    if ($r.glob -and ($Path -like $r.glob)) {
                        return [PSCustomObject]@{ App = $r.app; Category = $r.category; Clean = $r.clean; Note = $r.advice; HotBias = 10; Source = "agent" }
                    }
                } catch { }
            }
        }
    }
    $p = $Path.ToLower()
    $cur = $p
    while ($cur) {
        foreach ($r in $script:DmRules) {
            if ($r[0] -and ($cur -match $r[0])) {
                return [PSCustomObject]@{ App = $r[1]; Category = $r[2]; Clean = $r[3]; Note = ""; HotBias = $r[4]; Source = "rule" }
            }
        }
        if ($cur -notmatch "\\") { break }
        $cur = $cur.Substring(0, $cur.LastIndexOf("\"))
    }
    return [PSCustomObject]@{ App = "其他/未知"; Category = "未知"; Clean = "未知"; Note = ""; HotBias = 0; Source = "none" }
}

function Add-DmAgentRule {
    param([string]$DataDir, [string]$Glob, [string]$App, [string]$Category, [string]$Clean, [string]$Advice, [double]$Confidence = 0.7, [int]$TtlDays = 90)
    $r = [ordered]@{
        t = (Get-Date).ToString("o"); glob = $Glob; app = $App; category = $Category
        clean = $Clean; advice = $Advice; confidence = $Confidence; by = "agent"
        ttl_until = (Get-Date).AddDays($TtlDays).ToString("o")
    }
    Add-Content -Path (Join-Path $DataDir "events\agent_rules.jsonl") -Value ($r | ConvertTo-Json -Compress) -Encoding UTF8
    return $r
}
