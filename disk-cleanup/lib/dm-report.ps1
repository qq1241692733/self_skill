<#
  dm-report.ps1 - rendering for disk-monitor-cleanup v4
  Two report shapes:
    * single run   -> retro attribution (file age histogram), no baseline needed
    * run vs previous tree -> growth/shrink attribution + ledger reconciliation
  Output: human text and a stable JSON contract for agents (every number traceable to a source).
#>

function Get-DmRetroGroups {
    param([string]$DataDir, $Scan, [int]$Top = 15)
    # self (non-double-counted) values: an ancestor must not be credited with its descendants' writes
    $hot = [DmFast.Engine]::HotSelfList($Scan, 1MB, 3000)
    $rows = @()
    $catAgg = @{}
    $root30 = 0
    $re = [DmFast.Engine]::Get($Scan, $Scan.Root)
    if ($re) { $root30 = [long]$re.N30 }
    $selfSum = 0.0
    foreach ($h in $hot) {
        $a = Get-DmAttribution -Path $h.P -DataDir $DataDir
        $selfMb = [math]::Round($h.OwnB / 1MB, 1)
        $selfSum += $selfMb
        $rows += [PSCustomObject]@{
            Path = $h.P; MB30 = $selfMb; CurMB = [math]::Round($h.CurB / 1MB, 1)
            Files = $h.CurF; AgeDays = $h.Age; Mtime = $h.Mtime
            App = $a.App; Category = $a.Category; Clean = $a.Clean; Note = $a.Note
        }
        if (-not $catAgg.ContainsKey($a.Category)) { $catAgg[$a.Category] = 0.0 }
        $catAgg[$a.Category] += $selfMb
    }
    $cats = @()
    foreach ($k in ($catAgg.Keys | Sort-Object { -$catAgg[$_] })) {
        $cats += [PSCustomObject]@{ Category = $k; MB30 = [math]::Round($catAgg[$k], 1) }
    }
    return [ordered]@{
        RootMB30 = [math]::Round($root30 / 1MB, 1)
        CoveredMB30 = [math]::Round($selfSum, 1)
        Categories = $cats
        Dirs = ($rows | Sort-Object MB30 -Descending | Select-Object -First $Top)
    }
}

function Get-DmReconcile {
    param($LedgerPrev, $LedgerNow, $Diff)
    $r = [ordered]@{ available = $false; vol_used_delta_mb = 0; tree_delta_mb = 0; bucket_delta_mb = 0; gap_mb = 0; buckets = @() }
    if (-not $LedgerPrev -or -not $LedgerNow) { return $r }
    $r.available = $true
    $r.vol_used_delta_mb = [math]::Round(([double]$LedgerNow.used - [double]$LedgerPrev.used) / 1MB, 1)
    if ($Diff) { $r.tree_delta_mb = [math]::Round([double]$Diff.TreeNetDelta / 1MB, 1) }
    $sum = 0.0
    foreach ($k in @("hiberfil", "pagefile", "swapfile", "recyclebin", "vss", "mft", "usn")) {
        $a = [double]$LedgerPrev[$k]; $b = [double]$LedgerNow[$k]
        if ($a -lt 0 -or $b -lt 0) { continue }        # bucket not measurable (needs elevation)
        $d = $b - $a
        $sum += $d
        if ([math]::Abs($d) -gt 0) { $r.buckets += [PSCustomObject]@{ Bucket = $k; DeltaMB = [math]::Round($d / 1MB, 1) } }
    }
    $r.bucket_delta_mb = [math]::Round($sum / 1MB, 1)
    $r.gap_mb = [math]::Round($r.vol_used_delta_mb - $r.tree_delta_mb - $r.bucket_delta_mb, 1)
    return $r
}

function Format-DmReport {
    param([string]$DataDir, $Conf, $Scan, $Ledger, $LedgerPrev, $Reg, $Diff)
    $sb = New-Object System.Text.StringBuilder
    $line = { param($s) [void]$sb.AppendLine($s) }

    & $line "=========================================================="
    & $line ("  C 盘监控报告   (disk-monitor-cleanup v$script:DmVersion)")
    & $line "=========================================================="
    $cov = "全覆盖"
    if ($Scan.State -eq "CAPPED") { $cov = "已按上限截断（结果不完整）" }
    & $line ("运行: {0}   根: {1}" -f $Scan.At.ToString("yyyy-MM-dd HH:mm:ss"), $Scan.Root)
    & $line ("耗时: {0}s  线程: {1}  状态: {2}  ({3})" -f [math]::Round($Scan.Sec, 1), $Scan.Threads, $Scan.State, $cov)
    & $line ("规模: {0} 个目录 / {1} 个文件 / {2}" -f $Scan.Dirs, $Scan.Files, (Format-DmBytes $Scan.Bytes))
    & $line ("权限盲区: {0} 个目录未读到" -f $Scan.Denied)
    & $line ""
    & $line "---- 卷 ----"
    & $line ("总容量 {0}   已用 {1}   剩余 {2}" -f (Format-DmBytes $Ledger.total), (Format-DmBytes $Ledger.used), (Format-DmBytes $Ledger.free))
    & $line ""

    # ---- retro attribution: works on the very first run ----
    $retro = Get-DmRetroGroups -DataDir $DataDir -Scan $Scan -Top 15
    & $line "---- 回顾式归因（不需要历史基线：按文件最后写入时间统计）----"
    & $line ("全盘近 30 天写入: {0}（占已用 {1}%）" -f ($retro.RootMB30.ToString("N0") + " MB"), $(if ($Ledger.used -gt 0) { [math]::Round($retro.RootMB30 / ($Ledger.used / 1MB) * 100, 1) } else { 0 }))
    if ($retro.CoveredMB30 -gt 0) {
        & $line ("  （已定位到具体目录: {0} MB；与总量的差为小于 1MB 阈值的分散写入 + 未提权盲区）" -f $retro.CoveredMB30)
    }
    & $line ""
    & $line "最近 30 天写入最多的目录:"
    & $line ("{0,-52} {1,10} {2,8} {3,10} {4}" -f "目录", "近30天MB", "文件数", "最新活动", "类别/建议")
    foreach ($d in $retro.Dirs) {
        $p = $d.Path
        if ($p.Length -gt 50) { $p = "..." + $p.Substring($p.Length - 47) }
        & $line ("{0,-52} {1,10:N0} {2,8} {3,10} {4} / {5}" -f $p, $d.MB30, $d.Files, ("$($d.AgeDays)天前"), $d.Category, $d.Clean)
    }
    & $line ""
    & $line "按类别汇总（近 30 天写入）:"
    foreach ($c in $retro.Categories) { & $line ("  {0,-16} {1,10:N0} MB" -f $c.Category, $c.MB30) }
    & $line ""

    if ($Scan.TopFiles -and $Scan.TopFiles.Count -gt 0) {
        & $line ("最大的文件 Top 10（阈值 {0}MB，用于替代旧的 disk_newfiles）:" -f $Conf.MinTopFileMB)
        foreach ($f in ($Scan.TopFiles | Sort-Object -Property B -Descending | Select-Object -First 10)) {
            $p = $f.P
            if ($p.Length -gt 62) { $p = "..." + $p.Substring($p.Length - 59) }
            & $line ("  {0,8:N0} MB  写入于 {1}  {2}" -f ($f.B / 1MB), ([DmFast.Engine]::IsoFromTicks([long]$f.M)), $p)
        }
        & $line ""
    }

    # ---- diff vs previous tree ----
    if ($Diff) {
        $span = ""
        try { $span = ("{0:N1} 天" -f (($Diff.NewT.At - $Diff.OldT.At).TotalDays)) } catch { }
        & $line "---- 与上次快照对比（间隔 $span）----"
        & $line ("上次: {0}   本次: {1}   树内净变化: {2}" -f $Diff.OldT.At.ToString("MM-dd HH:mm"), $Diff.NewT.At.ToString("MM-dd HH:mm"), (Format-DmBytes $Diff.TreeNetDelta))
        & $line ""
        & $line "增长 Top 15（含子树）:"
        & $line ("{0,-50} {1,10} {2,8} {3,10} {4}" -f "目录", "增长MB", "文件数+", "自身MB", "类别")
        $n = 0
        foreach ($g in $Diff.Grow) {
            if ($n -ge 15) { break }
            $a = Get-DmAttribution -Path $g.P -DataDir $DataDir
            $p = $g.P; if ($p.Length -gt 48) { $p = "..." + $p.Substring($p.Length - 45) }
            & $line ("{0,-50} {1,10:N0} {2,8} {3,10:N0} {4}" -f $p, ($g.DB / 1MB), $g.DF, ($g.OwnB / 1MB), $a.Category)
            $n++
        }
        if ($n -eq 0) {
            & $line ("  （本次没有任何目录超过 {0}MB 的增长阈值；两次快照间隔越短越正常。想看得更细可加 -MinDeltaMB 1）" -f $Conf.MinDeltaMB)
        }
        & $line ""
        & $line "减少 Top 10:"
        $n = 0
        foreach ($s in $Diff.Shrink) {
            if ($n -ge 10) { break }
            $p = $s.P; if ($p.Length -gt 60) { $p = "..." + $p.Substring($p.Length - 57) }
            & $line ("  {0,10:N0} MB  {1}" -f ($s.DB / 1MB), $p)
            $n++
        }
        & $line ("  新增目录 {0} 个 / 消失目录 {1} 个" -f $Diff.Appeared, $Diff.Vanished)
        & $line ""
    } else {
        & $line "---- 与上次快照对比 ----"
        & $line "（首次运行，没有可对比的基线。本报告用上面的「回顾式归因」回答「为什么涨」。下次运行即可给出精确 diff。）"
        & $line ""
    }

    # ---- ledger reconciliation ----
    $rec = Get-DmReconcile -LedgerPrev $LedgerPrev -LedgerNow $Ledger -Diff $Diff
    & $line "---- 对账（总账不变量）----"
    & $line ("卷已用变化: {0:N0} MB   树内变化: {1:N0} MB   " -f $rec.vol_used_delta_mb, $rec.tree_delta_mb)
    if ($rec.available) {
        foreach ($b in $rec.buckets) { & $line ("  非目录桶 {0,-12} {1,10:N0} MB" -f $b.Bucket, $b.DeltaMB) }
        & $line ("  非目录桶合计: {0:N0} MB   未定位差值: {1:N0} MB" -f $rec.bucket_delta_mb, $rec.gap_mb)
        if ([math]::Abs($rec.gap_mb) -gt 512) {
            & $line "  -> 差值偏大：常见原因是卷影副本/保留存储变化、未提权盲区、或硬链接重复计数。建议提权重扫一次。"
        }
    } else {
        & $line "（首次运行，只记录账本；下次运行起可对账）"
    }
    & $line ""
    & $line "---- 账本明细 ----"
    & $line ("hiberfil {0}   pagefile {1}   swapfile {2}   回收站 {3}" -f (Format-DmBytes $Ledger.hiberfil), (Format-DmBytes $Ledger.pagefile), (Format-DmBytes $Ledger.swapfile), (Format-DmBytes $Ledger.recyclebin))
    $vssTxt = if ($Ledger.vss -lt 0) { "未采集" } else { Format-DmBytes $Ledger.vss }
    $mftTxt = if ($Ledger.mft -lt 0) { "未采集" } else { Format-DmBytes $Ledger.mft }
    & $line ("卷影副本 {0}   MFT {1}   USN 游标 {2}" -f $vssTxt, $mftTxt, $(if ($Ledger.usn -lt 0) { "未采集" } else { $Ledger.usn }))
    if ($Ledger.extras_note) { & $line ("  " + $Ledger.extras_note) }
    & $line ""

    # ---- registry ----
    if ($Reg) {
        & $line "---- 监控名单（注册表）----"
        & $line ("一级(每期必看) {0} 项   二级 {1} 项   休眠 {2} 项" -f $Reg.tier1_count, $Reg.tier2_count, $Reg.dormant_count)
        $top = @($Reg.items | Where-Object { $_.tier -eq 1 } | Sort-Object -Property { [double]$_.score } -Descending | Select-Object -First 10)
        foreach ($it in $top) {
            & $line ("  [{0,6:N1}] {1}   近30天 {2:N0} MB   残差 {3:N0} MB" -f [double]$it.score, $it.path, [double]$it.n30_mb, [double]$it.gap_mb)
        }
        & $line ""
    }

    # ---- clean preview ----
    $targets = Get-DmCleanTargets -Conf $Conf -DataDir $DataDir
    if ($targets.Count -gt 0) {
        $mf = Get-DmCleanManifest -Conf $Conf -Targets $targets
        $total = ($mf | Measure-Object -Property MB -Sum).Sum
        & $line "---- 可立即处理（预演，未删除）----"
        & $line ("预计可释放合计: {0:N0} MB" -f $total)
        foreach ($m in ($mf | Where-Object { $_.MB -gt 0 } | Sort-Object MB -Descending | Select-Object -First 12)) {
            $auto = if ($m.Auto) { "可自动" } else { "需确认" }
            & $line ("  {0,8:N0} MB  {1,-26} {2}" -f $m.MB, $m.Label, $auto)
        }
        & $line "  执行: powershell -File scripts\diskmonitor.ps1 clean -Execute"
        & $line ""
    }

    & $line "---- 盲区与置信度 ----"
    & $line ("提权: {0}" -f $(if ($Ledger.elevated) { "是" } else { "否（卷影/保留存储/MFT 不可见）" }))
    & $line ("截断: {0}" -f $Scan.State)
    & $line ("未读到目录: {0}" -f $Scan.Denied)
    & $line ("近 30 天口径: 按文件最后写入时间分桶；桶覆盖全部文件，目录级明细仅展示写入 >= {0}MB 的目录" -f $Conf.HotMinMB)
    & $line "=========================================================="
    return $sb.ToString()
}

function Convert-DmReportToJson {
    param([string]$DataDir, $Conf, $Scan, $Ledger, $LedgerPrev, $Reg, $Diff)
    $retro = Get-DmRetroGroups -DataDir $DataDir -Scan $Scan -Top 30
    $rec = Get-DmReconcile -LedgerPrev $LedgerPrev -LedgerNow $Ledger -Diff $Diff
    $o = [ordered]@{
        schema = "diskmonitor-report-v4"
        generated = (Get-Date).ToString("o")
        run = [ordered]@{
            at = $Scan.At.ToString("o"); root = $Scan.Root; seconds = [math]::Round($Scan.Sec, 2)
            state = $Scan.State; capped = $Scan.Capped; threads = $Scan.Threads
            dirs = $Scan.Dirs; files = $Scan.Files; bytes = $Scan.Bytes; alloc = $Scan.Alloc
            denied = $Scan.Denied; reparse = $Scan.Reparse; skipped = $Scan.Skipped
            coverage = $(if ($Scan.State -eq "CAPPED") { "partial" } else { "full" })
        }
        volume = [ordered]@{ total = $Ledger.total; used = $Ledger.used; free = $Ledger.free; elevated = $Ledger.elevated }
        ledger = $Ledger
        retro = [ordered]@{
            n30_total_mb = $retro.RootMB30
            n30_attributed_mb = $retro.CoveredMB30
            categories = $retro.Categories
            dirs = $retro.Dirs
            method = "file last-write-time histogram (no baseline required)"
        }
        diff = $(if ($Diff) {
            [ordered]@{
                span_days = [math]::Round(($Diff.NewT.At - $Diff.OldT.At).TotalDays, 2)
                tree_net_delta_mb = [math]::Round($Diff.TreeNetDelta / 1MB, 1)
                appeared_dirs = $Diff.Appeared; vanished_dirs = $Diff.Vanished
                grow = @($Diff.Grow | Select-Object -First 30 | ForEach-Object {
                    [ordered]@{ path = $_.P; delta_mb = [math]::Round($_.DB / 1MB, 1); delta_files = $_.DF; own_mb = [math]::Round($_.OwnB / 1MB, 1); n30_mb = [math]::Round($_.N30 / 1MB, 1); category = (Get-DmAttribution -Path $_.P -DataDir $DataDir).Category } })
                shrink = @($Diff.Shrink | Select-Object -First 20 | ForEach-Object {
                    [ordered]@{ path = $_.P; delta_mb = [math]::Round($_.DB / 1MB, 1); delta_files = $_.DF } })
            }
        } else { $null })
        reconcile = $rec
        registry = $(if ($Reg) { [ordered]@{ tier1 = $Reg.tier1_count; tier2 = $Reg.tier2_count; dormant = $Reg.dormant_count; items = @($Reg.items | Where-Object { $_.tier -eq 1 } | Select-Object -First 50) } } else { $null })
        blindspots = @(
            $(if (-not $Ledger.elevated) { "unelevated: shadow copies / reserved storage / MFT not measured" })
            $(if ($Scan.Capped) { "scan capped: results are partial" })
            $(if ($Scan.Denied -gt 0) { "$($Scan.Denied) directories unreadable" })
        )
        data_dir = $DataDir
    }
    return $o
}
