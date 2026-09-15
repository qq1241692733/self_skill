# disk_report.ps1 - legacy entry: print the latest report (no scan)
param([int]$MinMB = 0, [switch]$Json)
$scriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$a = @("report")
if ($MinMB -gt 0) { $a += @("-MinDeltaMB", "$MinMB") }
if ($Json) { $a += "-Json" }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir "diskmonitor.ps1") @a
