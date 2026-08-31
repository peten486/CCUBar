#Requires -Version 5.1
<#
  stop.ps1 — Windows에서 브리지 서버를 종료한다.
#>
Set-Location $PSScriptRoot

$pidFile = Join-Path $PSScriptRoot '.app.pid'
if (Test-Path $pidFile) {
    $procId = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($procId) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    Write-Host "[OK] 브리지 종료 (PID $procId)"
} else {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*claude_usage_scraper.py*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host "[OK] 브리지 종료 (명령 매칭)"
}
