# disk_newfiles.ps1 - legacy entry: now served by the report (largest files + recent-30d attribution)
param([string]$Since = "", [int]$Top = 30, [switch]$Json)
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$a = @("report")
if ($Json) { $a += "-Json" }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir "diskmonitor.ps1") @a
