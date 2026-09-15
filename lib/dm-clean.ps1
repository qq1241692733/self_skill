<#
  dm-clean.ps1 - safe cleanup for disk-monitor-cleanup v4
  Rules (frozen design D8):
    * whitelist only; personal files / WinSxS / Installer / system settings are never touched
    * default = dry run (manifest); -Execute is required to delete anything
    * age filter: only entries older than CleanMinAgeDays are removed from temp-like targets
    * per-target manifest with size, action, and whether it may run unattended (Auto)
    * after execution: re-measure, verify against the volume free-space delta, and close a series segment
  G1 fix (2026-09-15 review): the plan and every removed entry are now written to disk
    under events\manifest_<stamp>.json and events\deleted_<stamp>.jsonl, and single entries
    >= QuarantineMinMB are MOVED to <data>\quarantine\<stamp>\ instead of being deleted, so a
    cleanup can actually be undone (scripts\diskmonitor.ps1 clean-restore -Stamp <stamp>).
  Note: this module never calls Shell COM (the old implementation could block on the recycle bin).
#>

function Get-DmCleanTargets {
    param($Conf, [string]$DataDir)
    $local = $env:LOCALAPPDATA
    $programData = $env:ProgramData
    $t = @()
    # kind=contents  -> delete the *contents* of the directory (never the directory itself)
    # kind=glob      -> delete matching files only
    # kind=file      -> delete one file
    # kind=recycle   -> empty the recycle bin (always needs confirmation)
    $t += [PSCustomObject]@{ Label = "用户临时文件"; Path = $env:TEMP; Kind = "contents"; Auto = $true; MinAgeDays = $Conf.CleanMinAgeDays; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "系统临时文件"; Path = "$($Conf.Drive):\Windows\Temp"; Kind = "contents"; Auto = $true; MinAgeDays = $Conf.CleanMinAgeDays; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "Windows更新下载缓存"; Path = "$($Conf.Drive):\Windows\SoftwareDistribution\Download"; Kind = "contents"; Auto = $true; MinAgeDays = 1; Note = "需停wuauserv" }
    $t += [PSCustomObject]@{ Label = "传递优化缓存"; Path = "$($Conf.Drive):\Windows\SoftwareDistribution\DeliveryOptimization"; Kind = "contents"; Auto = $true; MinAgeDays = 1; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "DirectX着色器缓存"; Path = "$local\D3DSCache"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "NVIDIA着色器缓存"; Path = "$local\NVIDIA\DXCache"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "NVIDIA GL缓存"; Path = "$local\NVIDIA\GLCache"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "崩溃转储"; Path = "$local\CrashDumps"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "错误报告WER"; Path = "$programData\Microsoft\Windows\WER"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "蓝屏小转储"; Path = "$($Conf.Drive):\Windows\Minidump"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "内核实时报告"; Path = "$($Conf.Drive):\Windows\LiveKernelReports"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "CBS更新临时"; Path = "$($Conf.Drive):\Windows\CbsTemp"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "系统日志(旧)"; Path = "$($Conf.Drive):\Windows\Logs"; Kind = "glob"; Pattern = "*.log"; Auto = $false; MinAgeDays = 14; Note = "保留 CBS 排障日志" }
    $t += [PSCustomObject]@{ Label = "内存转储"; Path = "$($Conf.Drive):\Windows\MEMORY.DMP"; Kind = "file"; Auto = $false; MinAgeDays = 0; Note = "内核转储" }
    $t += [PSCustomObject]@{ Label = "缩略图缓存"; Path = "$local\Microsoft\Windows\Explorer"; Kind = "glob"; Pattern = "thumbcache_*.db"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "npm缓存"; Path = "$local\npm-cache"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "npm cache clean --force 等价" }
    $t += [PSCustomObject]@{ Label = "Yarn缓存"; Path = "$local\Yarn\Cache"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "UV缓存"; Path = "$local\uv\cache"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "pip缓存"; Path = "$local\pip\cache"; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "可再生" }
    $t += [PSCustomObject]@{ Label = "回收站"; Path = "$($Conf.Drive):\`$Recycle.Bin"; Kind = "recycle"; Auto = $false; MinAgeDays = 0; Note = "清空不可恢复" }
    if (-not ($Conf.SkipBrowser -eq $true)) {
        foreach ($ud in @("$local\Google\Chrome\User Data", "$local\Microsoft\Edge\User Data")) {
            if (-not (Test-Path $ud)) { continue }
            $brand = if ($ud -match "Chrome") { "Chrome" } else { "Edge" }
            foreach ($prof in (Get-ChildItem $ud -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" })) {
                foreach ($sub in @("Cache", "Code Cache", "GPUCache", "Service Worker\CacheStorage")) {
                    $p = Join-Path $prof.FullName $sub
                    if (Test-Path $p) {
                        $t += [PSCustomObject]@{ Label = "$brand缓存($($prof.Name)/$sub)"; Path = $p; Kind = "contents"; Auto = $true; MinAgeDays = 0; Note = "不碰书签/密码/历史" }
                    }
                }
            }
        }
    }
    return @($t | Where-Object { Test-Path $_.Path })
}

function Measure-DmTarget {
    param($Target, $Conf)
    $mb = 0.0
    switch ($Target.Kind) {
        "file" { try { $mb = [math]::Round((Get-Item $Target.Path -Force).Length / 1MB, 1) } catch { } }
        "glob" {
            try {
                $sum = (Get-ChildItem (Split-Path $Target.Path) -Filter (Split-Path $Target.Path -Leaf) -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                if ($sum) { $mb = [math]::Round($sum / 1MB, 1) }
            } catch { }
        }
        default {
            try {
                $r = Invoke-DmScan -Conf $Conf -Root $Target.Path -Threads 2 -MaxSeconds 60 -HotMinMB 1024
                $mb = [math]::Round($r.Bytes / 1MB, 1)
            } catch { }
        }
    }
    return $mb
}

function Get-DmCleanManifest {
    param($Conf, $Targets)
    $rows = @()
    foreach ($t in $Targets) {
        $mb = Measure-DmTarget -Target $t -Conf $Conf
        $skipped = ($t.Kind -eq "recycle")
        $rows += [PSCustomObject]@{
            Label = $t.Label; Path = $t.Path; Kind = $t.Kind; MB = $mb
            MinAgeDays = $t.MinAgeDays; Auto = [bool]$t.Auto; Note = $t.Note
            Action = $(if ($skipped) { "需 -RecycleBin 显式确认" } elseif ($mb -le 0) { "无需处理" } else { "可清理" })
        }
    }
    return @($rows)
}

# ---------------------------------------------------------------- G1: quarantine (undoable cleanup)
function Get-DmQuarantineDir {
    param([string]$DataDir, [string]$Stamp)
    return (Join-Path $DataDir ("quarantine\{0}" -f $Stamp))
}

function Move-DmToQuarantine {
    param([string]$Source, [string]$QDir, [int]$Index)
    # Flat layout with an index prefix: cache paths get very deep, so mirroring the source tree
    # here would blow past MAX_PATH. The original path is recorded in the deleted log instead.
    try {
        if (-not (Test-Path $QDir)) { New-Item -ItemType Directory -Force $QDir | Out-Null }
        $name = [System.IO.Path]::GetFileName($Source); if (-not $name) { $name = "entry" }
        $dest = Join-Path $QDir ("{0:D6}_{1}" -f $Index, $name)
        Move-Item -LiteralPath $Source -Destination $dest -Force -ErrorAction Stop
        return $dest
    } catch { return $null }
}

function Get-DmCleanLogs {
    param([string]$DataDir)
    $d = Join-Path $DataDir "events"
    if (-not (Test-Path $d)) { return @() }
    return @(Get-ChildItem $d -Filter "deleted_*.jsonl" | Sort-Object Name -Descending)
}

function Invoke-DmRestore {
    param([string]$DataDir, [string]$Stamp, [switch]$Purge)
    $logPath = Join-Path $DataDir ("events\deleted_{0}.jsonl" -f $Stamp)
    if (-not (Test-Path $logPath)) { throw ("找不到清理记录: " + $logPath) }
    $qDir = Get-DmQuarantineDir -DataDir $DataDir -Stamp $Stamp
    if ($Purge) {
        if (Test-Path $qDir) { Remove-Item -LiteralPath $qDir -Recurse -Force -ErrorAction Stop }
        return [ordered]@{ Stamp = $Stamp; Restored = 0; Failed = 0; Purged = $true; QuarantineDir = $qDir }
    }
    $restored = 0; $failed = 0
    foreach ($line in [System.IO.File]::ReadLines($logPath)) {
        if (-not $line) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.mode -ne "quarantined") { continue }
        if (-not (Test-Path -LiteralPath $o.qpath)) { $failed++; continue }
        try {
            $parent = Split-Path -Path ([string]$o.path) -Parent
            if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            Move-Item -LiteralPath $o.qpath -Destination ([string]$o.path) -Force -ErrorAction Stop
            $restored++
        } catch { $failed++ }
    }
    return [ordered]@{ Stamp = $Stamp; Restored = $restored; Failed = $failed; Purged = $false; QuarantineDir = $qDir }
}

function Invoke-DmClean {
    param($Conf, [string]$DataDir, [switch]$Execute, [switch]$RecycleBin, [int]$MinAgeDays = -1, [switch]$Recycle, $Targets = $null)
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $before = $null; $after = $null
    try { $before = Get-DmLedger -Conf $Conf -DataDir $DataDir } catch { }
    # -Targets lets a caller supply the plan instead of discovering it. It is what makes the
    # cleanup path testable without touching the real machine, and it makes `clean` scriptable.
    $targets = $Targets
    if (-not $targets) { $targets = Get-DmCleanTargets -Conf $Conf -DataDir $DataDir }
    $manifest = Get-DmCleanManifest -Conf $Conf -Targets $targets
    $rows = @()
    $freedTotal = 0.0
    $qMin = [long]$Conf.QuarantineMinMB * 1MB
    $qDir = Get-DmQuarantineDir -DataDir $DataDir -Stamp $stamp
    $log = New-Object System.Collections.Generic.List[string]     # G1: what was actually removed
    $quarantined = 0

    Ensure-DmDir (Join-Path $DataDir "events")
    # G1 fix: the plan is on disk BEFORE anything is touched.
    $plan = [ordered]@{
        t = (Get-Date).ToString("o"); stamp = $stamp; execute = [bool]$Execute
        quarantine_dir = $(if ($Execute -and $qMin -gt 0) { $qDir } else { "" })
        quarantine_min_mb = [int]$Conf.QuarantineMinMB
        items = @($manifest | ForEach-Object {
            [ordered]@{ label = $_.Label; path = $_.Path; kind = $_.Kind; mb = $_.MB
                        min_age_days = $_.MinAgeDays; auto = $_.Auto; action = $_.Action; note = $_.Note } })
    }
    Write-DmJson -Path (Join-Path $DataDir ("events\manifest_{0}.json" -f $stamp)) -Obj $plan

    foreach ($m in $manifest) {
        $t = $targets | Where-Object { $_.Label -eq $m.Label -and $_.Path -eq $m.Path } | Select-Object -First 1
        if (-not $t) { continue }
        $age = if ($MinAgeDays -ge 0) { $MinAgeDays } else { [int]$t.MinAgeDays }
        if ($t.Kind -eq "recycle") {
            if (-not $RecycleBin) {
                $rows += [PSCustomObject]@{ Label = $m.Label; MB = $m.MB; Action = "跳过(需 -RecycleBin)"; Note = $m.Note }
                continue
            }
            if (-not $Execute) {
                $rows += [PSCustomObject]@{ Label = $m.Label; MB = $m.MB; Action = "预演(不可恢复)"; Note = $m.Note }
                continue
            }
            try { Clear-RecycleBin -Force -ErrorAction Stop } catch { }
            $log.Add(([ordered]@{ t = (Get-Date).ToString("o"); target = $m.Label; path = $t.Path; size = 0; mode = "recyclebin-emptied" } | ConvertTo-Json -Compress))
            $rows += [PSCustomObject]@{ Label = $m.Label; MB = $m.MB; Action = "已清空"; Note = $m.Note }
            $freedTotal += $m.MB
            continue
        }
        if ($m.MB -le 0) { continue }
        if (-not $Execute) {
            $rows += [PSCustomObject]@{ Label = $m.Label; MB = $m.MB; Action = "预演"; Note = $m.Note }
            continue
        }
        $cut = (Get-Date).AddDays(-1 * $age)
        $wuStopped = $false
        if ($t.Path -match "SoftwareDistribution") {
            $svc = Get-Service wuauserv -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue; $wuStopped = $true }
        }

        # one entry at a time: >= QuarantineMinMB is MOVED (undoable), everything else is deleted.
        # both branches are recorded with the original path, so the run is auditable and reversible.
        $handleFile = {
            param($FileObj)
            $full = $FileObj.FullName; $len = [long]$FileObj.Length
            if ($qMin -gt 0 -and $len -ge $qMin) {
                $q = Move-DmToQuarantine -Source $full -QDir $qDir -Index $log.Count
                if ($q) {
                    $log.Add(([ordered]@{ t = (Get-Date).ToString("o"); target = $m.Label; path = $full; size = $len; mode = "quarantined"; qpath = $q } | ConvertTo-Json -Compress))
                } else {
                    $log.Add(([ordered]@{ t = (Get-Date).ToString("o"); target = $m.Label; path = $full; size = $len; mode = "quarantine-failed-kept" } | ConvertTo-Json -Compress))
                }
                return
            }
            Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            $log.Add(([ordered]@{ t = (Get-Date).ToString("o"); target = $m.Label; path = $full; size = $len; mode = "deleted" } | ConvertTo-Json -Compress))
        }

        if ($t.Kind -eq "file") {
            $fi = Get-Item -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue
            if ($fi) { & $handleFile $fi }
        } elseif ($t.Kind -eq "glob") {
            Get-ChildItem (Split-Path $t.Path) -Filter (Split-Path $t.Path -Leaf) -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cut } | ForEach-Object { & $handleFile $_ }
        } else {
            # delete the CONTENTS only, recursively: a fresh parent directory must not shield old files
            $dirs = New-Object System.Collections.Generic.List[object]
            Get-ChildItem -LiteralPath $t.Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.PSIsContainer) { $dirs.Add($_); return }
                if (($_.LastWriteTime -lt $cut) -or ($_.CreationTime -lt $cut)) { & $handleFile $_ }
            }
            # then drop directories left empty (deepest first); the target directory itself is never removed
            $sorted = @($dirs | Sort-Object -Property { $_.FullName.Length } -Descending)
            foreach ($d in $sorted) {
                if (-not (Test-Path -LiteralPath $d.FullName)) { continue }
                if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if ($wuStopped) { Start-Service wuauserv -ErrorAction SilentlyContinue }
        $afterMb = Measure-DmTarget -Target $t -Conf $Conf
        $freed = [math]::Max(0, $m.MB - $afterMb)
        $freedTotal += $freed
        $rows += [PSCustomObject]@{ Label = $m.Label; MB = $freed; Action = "已清理"; Note = $m.Note }
    }

    $quarantined = @($log | Where-Object { $_ -like '*"mode":"quarantined"*' }).Count

    # G1: the run log is only produced when something was actually touched
    if ($Execute -and $log.Count -gt 0) {
        [System.IO.File]::WriteAllLines((Join-Path $DataDir ("events\deleted_{0}.jsonl" -f $stamp)), $log.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    }

    try { $after = Get-DmLedger -Conf $Conf -DataDir $DataDir } catch { }
    $volDelta = 0.0
    if ($before -and $after) { $volDelta = [math]::Round(([double]$after.free - [double]$before.free) / 1MB, 1) }

    $hist = [ordered]@{
        t = (Get-Date).ToString("o"); execute = [bool]$Execute; dry = (-not $Execute)
        stamp = $stamp; quarantined = $quarantined
        before_free_mb = $(if ($before) { [math]::Round($before.free / 1MB, 1) } else { 0 })
        after_free_mb = $(if ($after) { [math]::Round($after.free / 1MB, 1) } else { 0 })
        claimed_freed_mb = [math]::Round($freedTotal, 1); measured_vol_delta_mb = $volDelta
        rows = @($rows | ForEach-Object { [ordered]@{ label = $_.Label; mb = $_.MB; action = $_.Action } })
    }
    Ensure-DmDir (Join-Path $DataDir "events")
    Add-Content -Path (Join-Path $DataDir "events\cleanup_history.jsonl") -Value ($hist | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8
    Write-DmEvent -DataDir $DataDir -Kind "clean.$(if($Execute){'executed'}else{'dryrun'})" -Payload @{ freed_mb = [math]::Round($freedTotal, 1); vol_delta_mb = $volDelta; quarantined = $quarantined; stamp = $stamp }
    if ($Execute) { [void](Close-DmSegment -DataDir $DataDir -Reason "clean" -FreedBytes ([long]($freedTotal * 1MB)) -LedgerBefore $before -LedgerAfter $after) }

    return [ordered]@{
        Execute = [bool]$Execute; FreedMB = [math]::Round($freedTotal, 1)
        VolumeFreeDeltaMB = $volDelta; Stamp = $stamp; Quarantined = $quarantined
        BeforeFreeMB = $(if ($before) { [math]::Round($before.free / 1MB, 1) } else { 0 })
        AfterFreeMB = $(if ($after) { [math]::Round($after.free / 1MB, 1) } else { 0 })
        Rows = $rows; Manifest = $manifest
    }
}
