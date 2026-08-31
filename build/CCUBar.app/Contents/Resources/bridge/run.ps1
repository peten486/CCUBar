#Requires -Version 5.1
<#
  run.ps1 — Windows에서 Claude 사용량 브리지 서버를 시작한다 (기본 snapshot 소스).
  브라우저 쿠키/키체인 불필요. 수집기(statusline-custom.ps1)가 쓴 스냅샷만 읽는다.
  종료: .\stop.ps1
#>
Set-Location $PSScriptRoot

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) { Write-Error 'python 을 PATH 에서 찾을 수 없습니다'; exit 1 }

$pidFile = Join-Path $PSScriptRoot '.app.pid'
if (Test-Path $pidFile) {
    $old = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
        Write-Error "이미 실행 중입니다 (PID $old)"; exit 1
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}

$log = Join-Path $PSScriptRoot 'app.log'
$proc = Start-Process -FilePath $py.Source `
    -ArgumentList @('claude_usage_scraper.py', '--server') `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
    -WindowStyle Hidden -PassThru

$proc.Id | Out-File -FilePath $pidFile -Encoding ascii
Write-Host "[OK] 브리지 시작 (PID $($proc.Id)), 로그: $log"
Write-Host "[INFO] 완전 종료: .\stop.ps1"
