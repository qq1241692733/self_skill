# disk_snapshot.ps1 - legacy entry, forwards to the v4 unified entry (kept so old schedules keep working)
param([int]$Level = 2, [int]$Threads = 0, [string]$Since = "", [switch]$Json)
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$a = @("run")
if ($Threads -gt 0) { $a += @("-Threads", "$Threads") }
if ($Json) { $a += "-Json" }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir "diskmonitor.ps1") @a
