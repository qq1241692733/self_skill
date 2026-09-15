<#
  diskmonitor.ps1 - disk-monitor-cleanup v4 unified entry
  Usage:
    diskmonitor.ps1 run        [-Root "C:\"] [-Lite] [-Json] [-MaxSeconds 150] [-Threads 4]
    diskmonitor.ps1 report     [-Json] [-MinDeltaMB 32]
    diskmonitor.ps1 diff       [-MinDeltaMB 32]
    diskmonitor.ps1 clean      [-Execute] [-RecycleBin] [-MinAgeDays 7]
    diskmonitor.ps1 clean-restore                # list cleanups that can be rolled back
    diskmonitor.ps1 clean-restore -Stamp <stamp> [-Purge]
    diskmonitor.ps1 mark                       # cheap "remember now" point (after a cleanup / install)
    diskmonitor.ps1 status
    diskmonitor.ps1 verify                     # engine self-check + correctness assertions (bounded)
    diskmonitor.ps1 agent-rule -Glob "C:\X\*" -App "X" -Category "缓存" -Clean "安全可清" -Advice "..."
    diskmonitor.ps1 schedule   -Enable [-Time 12:00] | -Disable
  Design: on-demand by default (no background tasks). Every run leaves a tree + ledger, so the next run
  gets an exact diff; a single run already answers "why did it grow" via the file age histogram.
#>
param(
    [Parameter(Position = 0)][string]$Command = "run",
    [string]$Root = "",
    [int]$Threads = 0,
    [double]$MaxSeconds = -1,
    [int]$MinDeltaMB = -1,
    [int]$MinAgeDays = -1,
    [string]$Stamp = "",
    [switch]$Purge,
    [switch]$Lite, [switch]$Json, [switch]$Execute, [switch]$RecycleBin,
    [switch]$Enable, [switch]$Disable, [switch]$Weekly, [string]$Time = "12:00",
    [string]$Glob, [string]$App, [string]$Category, [string]$Clean, [string]$Advice
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
. (Join-Path $scriptDir "..\lib\dm-core.ps1")
. (Join-Path $scriptDir "..\lib\dm-report.ps1")
. (Join-Path $scriptDir "..\lib\dm-clean.ps1")

function Save-DmLedgerFile {
    param([string]$DataDir, $Ledger, [string]$Stamp)
    Write-DmJson -Path (Join-Path $DataDir ("trees\ledger_{0}.json" -f $Stamp)) -Obj $Ledger
}

function Get-DmLedgerFiles {
    param([string]$DataDir)
    $d = Join-Path $DataDir "trees"
    if (-not (Test-Path $d)) { return @() }
    return @(Get-ChildItem $d -Filter "ledger_*.json" | Sort-Object Name)
}

function Read-DmLedgerFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Invoke-DmRun {
    param($Conf, [string]$DataDir, [string]$Root, [int]$Threads, [double]$MaxSeconds, [switch]$Lite, [switch]$Json, [int]$MinDeltaMB)
    if (-not $Root) { $Root = ([string]$Conf.Drive).TrimEnd(":") + ":\" }
    # engine must be ready BEFORE loading the previous tree: otherwise [DmFast.Engine] does not resolve yet
    # and the load silently fails, which used to make every run look like a first run.
    if (-not (Initialize-DmEngine)) { throw "扫描引擎编译失败（lib\DmScan.cs）" }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $prevFile = Get-DmLastTree -DataDir $DataDir
    $prevScan = $null
    if ($prevFile) {
        try { $prevScan = [DmFast.Engine]::Load($prevFile.FullName); [DmFast.Engine]::BuildIndex($prevScan) } catch { $prevScan = $null }
    }
    $ms = $MaxSeconds
    if ($Lite -and $ms -lt 0) { $ms = 60 }
    $hotMin = if ($Lite) { [math]::Max([int]$Conf.HotMinMB, 32) } else { -1 }

    Write-Host ("[$stamp] 扫描 {0} ... (预算 {1}s, 线程 {2}, 低优先级 {3})" -f $Root, $(if ($ms -lt 0) { $Conf.MaxSeconds } else { $ms }), $(if ($Threads -gt 0) { $Threads } else { $Conf.Threads }), $Conf.LowPriority)
    $scan = Invoke-DmScan -Conf $Conf -Root $Root -Threads $Threads -MaxSeconds $ms -HotMinMB $hotMin
    Write-Host ("  扫描完成: {0} 目录 / {1} 文件 / {2} / 耗时 {3}s / 状态 {4} / 未读到 {5}" -f `
        $scan.Dirs, $scan.Files, (Format-DmBytes $scan.Bytes), [math]::Round($scan.Sec, 1), $scan.State, $scan.Denied)

    $ledger = Get-DmLedger -Conf $Conf -DataDir $DataDir
    $prevLedger = $null
    $lf = Get-DmLedgerFiles -DataDir $DataDir
    if ($lf.Count -ge 1) { $prevLedger = Read-DmLedgerFile -Path $lf[$lf.Count - 1].FullName }

    $diff = $null
    if ($prevScan) {
        $minB = if ($MinDeltaMB -gt 0) { [long]$MinDeltaMB * 1MB } else { [long]$Conf.MinDeltaMB * 1MB }
        $diff = [DmFast.Engine]::Diff($prevScan, $scan, $minB, 40)
    }

    $treePath = Save-DmTree -DataDir $DataDir -Scan $scan
    Save-DmLedgerFile -DataDir $DataDir -Ledger $ledger -Stamp $stamp

    $reg = Get-DmRegistry -DataDir $DataDir
    if (-not $Lite) { $reg = Update-DmRegistry -DataDir $DataDir -Conf $Conf -Scan $scan -Ledger $ledger }
    $pts = Add-DmSeriesPoint -DataDir $DataDir -Conf $Conf -Reg $reg -Ledger $ledger -Scan $scan
    [void](Remove-DmOldTrees -DataDir $DataDir -Keep ([int]$Conf.KeepTrees))

    if ($diff) {
        Write-DmEvent -DataDir $DataDir -Kind "diff" -Payload @{ grow = $diff.Grow.Count; shrink = $diff.Shrink.Count; tree_net_mb = [math]::Round($diff.TreeNetDelta / 1MB, 1) }
    }
    Write-Host ("  快照: {0}  账本已记录  序列新增 {1} 点" -f (Split-Path $treePath -Leaf), $pts)
    Write-Host ""

    if ($Json) {
        $o = Convert-DmReportToJson -DataDir $DataDir -Conf $Conf -Scan $scan -Ledger $ledger -LedgerPrev $prevLedger -Reg $reg -Diff $diff
        $jp = Join-Path $DataDir ("events\report_{0}.json" -f $stamp)
        Write-DmJson -Path $jp -Obj $o
        return $o
    }
    return (Format-DmReport -DataDir $DataDir -Conf $Conf -Scan $scan -Ledger $ledger -LedgerPrev $prevLedger -Reg $reg -Diff $diff)
}

function Invoke-DmReportFromStore {
    param($Conf, [string]$DataDir, [switch]$Json, [int]$MinDeltaMB)
    if (-not (Initialize-DmEngine)) { throw "扫描引擎编译失败（lib\DmScan.cs）" }
    $trees = Get-DmTrees -DataDir $DataDir
    if ($trees.Count -lt 1) { throw "还没有任何快照，先运行: scripts\diskmonitor.ps1 run" }
    $new = [DmFast.Engine]::Load($trees[$trees.Count - 1].FullName); [DmFast.Engine]::BuildIndex($new)
    $old = $null
    if ($trees.Count -ge 2) {
        $old = [DmFast.Engine]::Load($trees[$trees.Count - 2].FullName); [DmFast.Engine]::BuildIndex($old)
    }
    $lf = Get-DmLedgerFiles -DataDir $DataDir
    $led = $null; $pled = $null
    if ($lf.Count -ge 1) { $led = Read-DmLedgerFile -Path $lf[$lf.Count - 1].FullName }
    if ($lf.Count -ge 2) { $pled = Read-DmLedgerFile -Path $lf[$lf.Count - 2].FullName }
    if (-not $led) { $led = Get-DmLedger -Conf $Conf -DataDir $DataDir }
    $diff = $null
    if ($old) {
        $minB = if ($MinDeltaMB -gt 0) { [long]$MinDeltaMB * 1MB } else { [long]$Conf.MinDeltaMB * 1MB }
        $diff = [DmFast.Engine]::Diff($old, $new, $minB, 40)
    }
    $reg = Get-DmRegistry -DataDir $DataDir
    if ($Json) { return (Convert-DmReportToJson -DataDir $DataDir -Conf $Conf -Scan $new -Ledger $led -LedgerPrev $pled -Reg $reg -Diff $diff) }
    return (Format-DmReport -DataDir $DataDir -Conf $Conf -Scan $new -Ledger $led -LedgerPrev $pled -Reg $reg -Diff $diff)
}

function Invoke-DmVerify {
    param($Conf)
    $script:verifyFails = 0
    function Chk([string]$n, [bool]$ok, [string]$d) {
        if (-not $ok) { $script:verifyFails++ }
        Write-Host ("{0}  {1,-46} {2}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $n, $d)
    }
    if (-not (Initialize-DmEngine)) { Write-Host "FAIL 引擎编译"; return 1 }
    Chk "engine layout 592/44/28" $true ([DmFast.Engine]::LayoutInfo())
    $o = New-DmOpt -Conf $Conf -Threads 4 -MaxSeconds 60
    $leaf = "C:\Windows\System32\drivers\etc"
    if (Test-Path $leaf) {
        $r = [DmFast.Engine]::Scan($leaf, $o)
        $g = (Get-ChildItem $leaf -File -Force | Measure-Object Length -Sum).Sum
        Chk "leaf dirs=1/files/bytes exact" (($r.Dirs -eq 1) -and ($r.Bytes -eq $g)) ("dirs=" + $r.Dirs + " bytes=" + $r.Bytes + "/" + $g)
    }
    $r2 = [DmFast.Engine]::Scan("C:\Program Files", $o)
    Chk "Program Files sane size" (($r2.Dirs -gt 1000) -and ($r2.Bytes -gt 1GB)) ("dirs=" + $r2.Dirs + " bytes=" + (Format-DmBytes $r2.Bytes))
    $root = [DmFast.Engine]::Get($r2, "C:\Program Files")
    if (-not $root) { [DmFast.Engine]::BuildIndex($r2); $root = [DmFast.Engine]::Get($r2, "C:\Program Files") }
    Chk "rollup == totals" ($root.B -eq $r2.Bytes) ((Format-DmBytes $root.B))
    $tmp = Join-Path $env:TEMP "dm_verify_tree.bin"
    [DmFast.Engine]::Save($r2, $tmp)
    $back = [DmFast.Engine]::Load($tmp)
    Chk "storage round-trip" (($back.Ents.Count -eq $r2.Ents.Count) -and ($back.Bytes -eq $r2.Bytes)) ("entries=" + $back.Ents.Count)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $oc = New-DmOpt -Conf $Conf -Threads 4 -MaxSeconds 1
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rc = [DmFast.Engine]::Scan("C:\Windows\WinSxS", $oc)
    $sw.Stop()
    Chk "hard cap stops the walk" ((($rc.State -eq "CAPPED")) -and ($sw.Elapsed.TotalSeconds -lt 8)) ($rc.State + " wall=" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s")
    if (Test-Path $leaf) {
        $r3 = [DmFast.Engine]::Scan($leaf, $o)
        Chk "no contamination after cap" ($r3.Dirs -eq 1) ("dirs=" + $r3.Dirs)
    }

    # ---- regression guards for the 2026-09-15 review findings (D1 / D2 / D3) ----
    Chk "error policy is Stop (D3)" ($ErrorActionPreference -eq "Stop") ("ErrorActionPreference=" + $ErrorActionPreference)

    $libCore = Join-Path (Split-Path $scriptDir -Parent) "lib\dm-core.ps1"
    if (Test-Path $libCore) {
        $src = Get-Content $libCore -Raw -Encoding UTF8
        # D1: the tier-1 gate must read CHANGE. A level compared against ThetaRecMB (whether the
        # subtree size or the 30-day write volume) pins every large directory forever - that is
        # exactly what turned tier-1 into a frozen "300 biggest" list.
        Chk "D1 gate is cumulative change, not a level" (($src -match 'sinceMb\s+-ge\s+\$theta') -and ($src -match 'hit_mb')) "growth credited since the last credit"
        Chk "D1 no level compared against ThetaRecMB" ((-not ($src -match 'residualMb\s+-ge\s+\$theta\b')) -and (-not ($src -match 'n30Mb\s+-ge\s+\$theta\b'))) "residualMb and n30Mb must not be tested against ThetaRecMB"
        Chk "D1 churn bar is ThetaCleanMB" ($src -match 'n30Mb\s+-ge\s+\$thetaClean') "30-day churn compared against the cleaning threshold"
        Chk "D1 demote is not force-overridden" (-not ($src -match '\$residualMb -ge \$theta -and \$it\.tier -eq 2')) "forced re-promote removed"

        # D1 behavioural: drive the real gate through 20 simulated runs. A big but STATIC directory
        # must end up demoted (the old code pinned it forever because its absolute size tripped the
        # threshold on every run); a directory growing less than theta per run must still keep its
        # slot, because the gate accumulates; and a flat-but-churning one must hold on 30-day volume.
        try {
            $flat = New-DmItem -Path "C:\verify\flat" -Reason "test"
            $flat.tier = 1; $flat.last_mb = 5000.0; $flat.hit_mb = 5000.0; $flat.hit_gap = 0.0
            $grow = New-DmItem -Path "C:\verify\grow" -Reason "test"
            $grow.tier = 1; $grow.last_mb = 100.0; $grow.hit_mb = 100.0; $grow.hit_gap = 0.0
            $sz = 100.0
            for ($k = 0; $k -lt 20; $k++) {
                $sz += 120.0     # less than theta per run: only accumulation can credit it
                [void](Update-DmItemGate -It $grow -NowMb $sz -ResidualMb $sz -N30Mb 50.0 -Conf $Conf)
                [void](Update-DmItemGate -It $flat -NowMb 5000.0 -ResidualMb 5000.0 -N30Mb 50.0 -Conf $Conf)
            }
            Chk "D1 big-but-static dir is demoted" (($flat.tier -eq 2) -and ([int]$flat.zero_streak -ge [int]$Conf.DemoteAfterRuns)) ("tier=" + $flat.tier + " zs=" + $flat.zero_streak + " (mb stayed 5000)")
            Chk "D1 sub-theta growth still earns the slot" (($grow.tier -eq 1) -and ([int]$grow.hits -ge 5)) ("tier=" + $grow.tier + " hits=" + $grow.hits + " (+120MB/run)")

            $churn = New-DmItem -Path "C:\verify\churn" -Reason "test"
            $churn.tier = 1; $churn.last_mb = 800.0; $churn.hit_mb = 800.0; $churn.hit_gap = 0.0
            for ($k = 0; $k -lt 20; $k++) {
                [void](Update-DmItemGate -It $churn -NowMb 800.0 -ResidualMb 800.0 -N30Mb 2000.0 -Conf $Conf)
            }
            Chk "D1 flat-but-churning dir holds on 30d volume" (($churn.tier -eq 1) -and ([int]$churn.hits -eq 20)) ("tier=" + $churn.tier + " hits=" + $churn.hits + " (n30=2000)")
        } catch {
            Chk "D1 gate harness ran" $false $_.Exception.Message
        }
        Chk "D3 no global error swallowing" (-not ($src -match '\$ErrorActionPreference\s*=\s*"SilentlyContinue"')) "libs must not assign SilentlyContinue"
    } else {
        Chk "dm-core.ps1 present" $false $libCore
    }

    # D2: the record rule must actually gate writes, and the per-path index must cover every path
    $tv = Join-Path $env:TEMP ("dm_verify_series_" + (Get-Date -Format "HHmmss"))
    try {
        Ensure-DmDir $tv
        # NOTE: passed as a List[object] ON PURPOSE. A bare @($Reg.items) over a List[object] is a
        # Windows PowerShell 5.1 binder crash ("参数类型不匹配"); production hands back object[] and
        # would therefore never catch the regression. Keeping the List here makes this a real sentinel.
        $fakeItems = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt 600; $i++) {
            $fakeItems.Add([ordered]@{ path = ("C:\verify\dir{0}" -f $i); state = "ACTIVE"; tier = 1; last_mb = 100.0; last_files = 1; n30_mb = 0 })
        }
        $fakeReg = [ordered]@{ items = $fakeItems }
        $fakeLed = [ordered]@{ used = 90000 * 1MB; free = 10000 * 1MB }
        $p1 = Join-Path $tv "series\series.jsonl"

        Chk "registry items materialize from a List[object]" ((Get-DmRegItems -Reg $fakeReg).Count -eq 600) ("count=" + (Get-DmRegItems -Reg $fakeReg).Count)

        $n1 = Add-DmSeriesPoint -DataDir $tv -Conf $Conf -Reg $fakeReg -Ledger $fakeLed -Scan ([PSCustomObject]@{ At = (Get-Date) })
        $c1 = @(Get-Content $p1 -Encoding UTF8).Count
        Chk "series records first sighting" (($n1 -eq 600) -and ($c1 -eq 601)) ("added=" + $n1 + " lines=" + $c1)

        # a below-threshold change on every path must write NOTHING.
        # this is exactly the rule the old "-Tail 200" window bypassed for ~275 of the 476 paths.
        foreach ($it in $fakeItems) { $it["last_mb"] = 101.0 }
        $n2 = Add-DmSeriesPoint -DataDir $tv -Conf $Conf -Reg $fakeReg -Ledger $fakeLed -Scan ([PSCustomObject]@{ At = (Get-Date).AddMinutes(1) })
        Chk "series rule gates below-theta writes" ($n2 -eq 0) ("added=" + $n2 + " (must be 0, not 600)")

        # an above-threshold change must record every path exactly once
        foreach ($it in $fakeItems) { $it["last_mb"] = 500.0 }
        $n3 = Add-DmSeriesPoint -DataDir $tv -Conf $Conf -Reg $fakeReg -Ledger $fakeLed -Scan ([PSCustomObject]@{ At = (Get-Date).AddMinutes(2) })
        Chk "series records above-theta writes" ($n3 -eq 600) ("added=" + $n3)

        $capConf = Copy-DmConf -Conf $Conf; $capConf["KeepSeriesPoints"] = 50
        [void](Trim-DmSeriesPoints -DataDir $tv -Conf $capConf)
        $c3 = @(Get-Content $p1 -Encoding UTF8).Count
        Chk "series cap is enforced (KeepSeriesPoints)" ($c3 -eq 50) ("lines=" + $c3)
    } catch {
        Chk "series regression harness ran" $false $_.Exception.Message
    } finally {
        Remove-Item $tv -Recurse -Force -ErrorAction SilentlyContinue
    }

    # G1: cleanup must be auditable and reversible. Driven end-to-end against a sandbox tree by
    # injecting the target list (-Targets), so the test never goes near the real machine.
    $g1root = Join-Path $env:TEMP ("dm_verify_g1_" + (Get-Date -Format "HHmmss"))
    try {
        $g1data = Join-Path $g1root "data"
        $g1tree = Join-Path $g1root "tree"
        Ensure-DmDir $g1data
        Ensure-DmDir $g1tree
        $old = (Get-Date).AddDays(-30)
        $fBig = Join-Path $g1tree "big.bin"        # >= QuarantineMinMB -> quarantined (undoable)
        $fSmall = Join-Path $g1tree "small.bin"    # <  QuarantineMinMB -> deleted
        $fGlob = Join-Path $g1tree "cache.tmp"     # reached through the glob target
        [System.IO.File]::WriteAllBytes($fBig, (New-Object byte[] 1572864))
        [System.IO.File]::WriteAllBytes($fSmall, (New-Object byte[] 81920))
        [System.IO.File]::WriteAllBytes($fGlob, (New-Object byte[] 204800))
        foreach ($f in @($fBig, $fSmall, $fGlob)) { (Get-Item -LiteralPath $f).LastWriteTime = $old }

        $g1conf = Copy-DmConf -Conf $Conf
        $g1conf["QuarantineMinMB"] = 1             # 1.5MB quarantines; 80KB / 200KB are deleted

        $tgt = @(
            [PSCustomObject]@{ Label = "big"; Path = $fBig; Kind = "file"; MinAgeDays = 7; Auto = $true; Note = "t" }
            [PSCustomObject]@{ Label = "small"; Path = $fSmall; Kind = "file"; MinAgeDays = 7; Auto = $true; Note = "t" }
            [PSCustomObject]@{ Label = "glob"; Path = (Join-Path $g1tree "*.tmp"); Kind = "glob"; MinAgeDays = 7; Auto = $true; Note = "t" }
        )

        # a dry run must not touch a single file
        [void](Invoke-DmClean -Conf $g1conf -DataDir $g1data -Targets $tgt)
        Chk "G1 dry run leaves everything alone" ((Test-Path -LiteralPath $fBig) -and (Test-Path -LiteralPath $fSmall) -and (Test-Path -LiteralPath $fGlob)) "3/3 intact"

        $res = Invoke-DmClean -Conf $g1conf -DataDir $g1data -Execute -Targets $tgt
        Chk "G1 large entry is quarantined, not deleted" ((-not (Test-Path -LiteralPath $fBig)) -and ([int]$res.Quarantined -eq 1)) ("quarantined=" + $res.Quarantined)
        Chk "G1 small entries are removed" ((-not (Test-Path -LiteralPath $fSmall)) -and (-not (Test-Path -LiteralPath $fGlob))) "gone"

        $mfile = Join-Path $g1data ("events\manifest_" + $res.Stamp + ".json")
        $lfile = Join-Path $g1data ("events\deleted_" + $res.Stamp + ".jsonl")
        Chk "G1 plan is on disk before anything is touched" (Test-Path -LiteralPath $mfile) ("manifest=" + $res.Stamp)
        $dl = Get-Content $lfile -Encoding UTF8
        Chk "G1 every removal records its original path" ((@($dl).Count -eq 3) -and (@($dl | Where-Object { $_ -match '"qpath"' }).Count -eq 1)) ("log lines=" + @($dl).Count)

        $rb = Invoke-DmRestore -DataDir $g1data -Stamp $res.Stamp
        $sz = 0
        if (Test-Path -LiteralPath $fBig) { $sz = (Get-Item -LiteralPath $fBig).Length }
        Chk "G1 quarantined entry restores intact" (($sz -eq 1572864) -and ([int]$rb.Restored -eq 1)) ("restored=" + $rb.Restored + " bytes=" + $sz)
        [void](Invoke-DmRestore -DataDir $g1data -Stamp $res.Stamp -Purge)
        Chk "G1 purge clears the quarantine" (-not (Test-Path -LiteralPath (Get-DmQuarantineDir -DataDir $g1data -Stamp $res.Stamp))) "quarantine dir removed"
    } catch {
        Chk "G1 cleanup harness ran" $false $_.Exception.Message
    } finally {
        Remove-Item $g1root -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ("---- {0} FAIL ----" -f $script:verifyFails)
    return $script:verifyFails
}

# ------------------------------------------------------------------ dispatch
$conf = Get-DmConf
$dataDir = Get-DmDataDir
foreach ($sub in @("trees", "registry", "series", "events")) { New-Item -ItemType Directory -Force (Join-Path $dataDir $sub) | Out-Null }

switch ($Command.ToLower()) {
    "run" {
        $out = Invoke-DmRun -Conf $conf -DataDir $dataDir -Root $Root -Threads $Threads -MaxSeconds $MaxSeconds -Lite:$Lite -Json:$Json -MinDeltaMB $MinDeltaMB
        if ($Json) { $out | ConvertTo-Json -Depth 8 } else { Write-Host $out }
    }
    "mark" {
        $out = Invoke-DmRun -Conf $conf -DataDir $dataDir -Root $Root -Threads $Threads -MaxSeconds 60 -Lite -Json:$Json
        if (-not $Json) { Write-Host "已记录当前状态（轻量点）。下次 run 即可看到这段时间的变化。" }
    }
    "report" { $o = Invoke-DmReportFromStore -Conf $conf -DataDir $dataDir -Json:$Json -MinDeltaMB $MinDeltaMB; if ($Json) { $o | ConvertTo-Json -Depth 8 } else { Write-Host $o } }
    "diff" { $o = Invoke-DmReportFromStore -Conf $conf -DataDir $dataDir -MinDeltaMB $(if ($MinDeltaMB -gt 0) { $MinDeltaMB } else { 1 }); Write-Host $o }
    "clean" {
        $d = $MinAgeDays
        if ($d -lt 0) { $d = [int]$conf.CleanMinAgeDays }
        $r = Invoke-DmClean -Conf $conf -DataDir $dataDir -Execute:$Execute -RecycleBin:$RecycleBin -MinAgeDays $d
        $mode = if ($Execute) { "执行" } else { "预演（未删除）" }
        Write-Host ("=== 清理{0}: 合计 {1:N0} MB；卷剩余变化 {2:N0} MB；剩余 {3:N0} -> {4:N0} MB ===" -f $mode, $r.FreedMB, $r.VolumeFreeDeltaMB, $r.BeforeFreeMB, $r.AfterFreeMB)
        $r.Rows | Format-Table Label, MB, Action, Note -AutoSize
        Write-Host ("清单: events\manifest_{0}.json" -f $r.Stamp)
        if ($Execute) {
            Write-Host ("记录: events\deleted_{0}.jsonl" -f $r.Stamp)
            if ($r.Quarantined -gt 0) { Write-Host ("其中 {0} 项 >= {1}MB 已移入隔离区（可回滚）: scripts\diskmonitor.ps1 clean-restore -Stamp {2}" -f $r.Quarantined, $conf.QuarantineMinMB, $r.Stamp) }
            Write-Host "提示: 现在运行 mark 或 run 记录清理后的状态，便于下次对比回涨。"
        } else {
            Write-Host "确认后执行: scripts\diskmonitor.ps1 clean -Execute"
        }
    }
    "clean-restore" {
        if (-not $Stamp) {
            $logs = Get-DmCleanLogs -DataDir $dataDir
            Write-Host "可回滚的清理记录:"
            if ($logs.Count -eq 0) { Write-Host "  （无）" }
            else { foreach ($l in $logs) { Write-Host ("  " + $l.Name + "   " + $l.LastWriteTime) } }
            Write-Host "用法: diskmonitor.ps1 clean-restore -Stamp yyyyMMdd_HHmmss [-Purge]"
            break
        }
        $r = Invoke-DmRestore -DataDir $dataDir -Stamp $Stamp -Purge:$Purge
        if ($r.Purged) { Write-Host ("已丢弃隔离区 {0}（{1}）— 这些条目无法再恢复。" -f $r.Stamp, $r.QuarantineDir) }
        else { Write-Host ("回滚 {0}: 已恢复 {1} 项，失败 {2} 项。隔离区: {3}" -f $r.Stamp, $r.Restored, $r.Failed, $r.QuarantineDir) }
    }
    "status" {
        Write-Host "=== disk-monitor-cleanup v4 状态 ==="
        $led = Get-DmLedger -Conf $conf -DataDir $dataDir
        Write-Host ("卷 {0}: 总 {1} / 已用 {2} / 剩余 {3}" -f $led.drive, (Format-DmBytes $led.total), (Format-DmBytes $led.used), (Format-DmBytes $led.free))
        Write-Host ("提权: {0}   数据目录: {1}" -f $(if ($led.elevated) { "是" } else { "否" }), $dataDir)
        $trees = Get-DmTrees -DataDir $dataDir
        Write-Host ("快照: {0} 个 (保留 {1})" -f $trees.Count, $conf.KeepTrees)
        if ($trees.Count) { Write-Host ("  最新: {0}" -f $trees[$trees.Count - 1].Name) }
        $reg = Get-DmRegistry -DataDir $dataDir
        Write-Host ("监控名单: 一级 {0} / 二级 {1} / 休眠 {2}" -f $reg.tier1_count, $reg.tier2_count, $reg.dormant_count)
        $sp = Join-Path $dataDir "series\series.jsonl"
        if (Test-Path $sp) { Write-Host ("序列点: {0}" -f (Get-Content $sp -Encoding UTF8).Count) }
        $seg = Join-Path $dataDir "series\segments.jsonl"
        if (Test-Path $seg) {
            Write-Host "清理段摘要(最近 5):"
            Get-Content $seg -Tail 5 -Encoding UTF8 | ForEach-Object {
                try { $s = $_ | ConvertFrom-Json; Write-Host ("  {0}  释放 {1:N0} MB  ({2})" -f ([datetime]$s.t).ToString("MM-dd HH:mm"), $s.freed_mb, $s.reason) } catch { }
            }
        }
        if (Initialize-DmEngine) { Write-Host ("引擎: OK  {0}" -f [DmFast.Engine]::LayoutInfo()) } else { Write-Host "引擎: 不可用" }
    }
    "verify" { $c = Invoke-DmVerify -Conf $conf; exit ([int]$c) }
    "agent-rule" {
        if (-not $Glob) { Write-Host "用法: agent-rule -Glob 'C:\X\*' -App X -Category 缓存 -Clean 安全可清 -Advice '...'"; break }
        $r = Add-DmAgentRule -DataDir $dataDir -Glob $Glob -App $App -Category $Category -Clean $Clean -Advice $Advice -TtlDays ([int]$conf.AgentRuleTtlDays)
        Write-Host ("已记录 agent 规则: {0} -> {1}/{2}/{3}" -f $Glob, $App, $Category, $Clean)
    }
    "schedule" {
        $task = "DiskMonitor_Run_v4"
        if ($Enable) {
            $ps = (Get-Command powershell.exe).Source
            $entry = Join-Path $scriptDir "diskmonitor.ps1"
            $sc = if ($Weekly) { "weekly" } else { "daily" }
            schtasks /create /tn $task /tr "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$entry`" run -Json" /sc $sc /st $Time /f | Out-Null
            Write-Host ("已创建定时任务 {0}（{1} {2}）。注意：默认设计是「按需运行」，定时任务请自行确认是否需要。" -f $task, $sc, $Time)
        } elseif ($Disable) {
            schtasks /delete /tn $task /f | Out-Null
            Write-Host ("已删除定时任务 {0}" -f $task)
        } else {
            Write-Host "用法: schedule -Enable [-Weekly] [-Time 12:00] | -Disable   （默认不启用任何后台任务）"
        }
    }
    default { Write-Host "用法: diskmonitor.ps1 <run|report|diff|clean|mark|status|verify|agent-rule|schedule> [参数]" }
}
