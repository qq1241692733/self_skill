# disk_clean.ps1 - legacy entry: dry run by default; -Execute really deletes
param([switch]$DryRun, [switch]$Execute, [switch]$IncludeRecycleBin, [switch]$SkipBrowser)
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$a = @("clean")
if ($Execute -and -not $DryRun) { $a += "-Execute" }
if ($IncludeRecycleBin) { $a += "-RecycleBin" }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir "diskmonitor.ps1") @a
