<#
  One-click installer for the 406 Dashboard collector.
  Registers a Windows scheduled task that runs collect.ps1 every 10 minutes.

  Run it once:  right-click this file -> "Run with PowerShell"
  (or:  powershell -ExecutionPolicy Bypass -File install-collector-task.ps1)

  Re-run any time to update the schedule. Safe to run before you've made
  config.ps1 - the collector just no-ops until config.ps1 exists.
#>
$ErrorActionPreference = "Stop"
$TaskName  = "406 Dashboard Collector"
$collector = Join-Path $PSScriptRoot "collect.ps1"
if (-not (Test-Path $collector)) { throw "collect.ps1 not found next to this script ($collector)." }

if (-not (Test-Path (Join-Path $PSScriptRoot "config.ps1"))) {
  Write-Host "NOTE: collector\config.ps1 doesn't exist yet." -ForegroundColor Yellow
  Write-Host "      The task will run but do nothing until you copy config.example.ps1 to" -ForegroundColor Yellow
  Write-Host "      config.ps1 and set your RCON password + Push = `$true." -ForegroundColor Yellow
}

$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$collector`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
             -RepetitionInterval (New-TimeSpan -Minutes 10)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 9)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Host ""
Write-Host "Installed scheduled task '$TaskName' - runs every 10 minutes." -ForegroundColor Green
Write-Host "Test it now:  powershell -ExecutionPolicy Bypass -File `"$collector`" -NoPush"
Write-Host "Remove it later:  schtasks /Delete /TN `"$TaskName`" /F"
