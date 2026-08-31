#Requires -Version 5.1
<#
  statusline-custom.ps1 — CCU Bar 사용량 수집기 래퍼 (Windows)

  statusline-custom.sh 의 Windows 대응판. Claude Code 가 settings.json 의
  statusLine.command 로 이 스크립트를 호출한다. stdin 세션 JSON 을 받아:
    1) 원본 statusline 을 그대로 실행해 화면 출력을 통과시키고,
    2) rate_limits 를 usage-snapshot.json 으로 원자적으로 저장한다.

  설계 규칙 (셸판과 동일):
    - 스냅샷 저장 실패가 화면 렌더를 막지 않도록 모든 오류를 삼키고 항상 exit 0.
    - 부재 보존: rate_limits(또는 두 창 모두)가 없으면 스냅샷을 갱신하지 않는다.
    - resets_at 은 statusline 이 주는 Unix epoch 정수 그대로 저장한다.
      epoch→ISO 변환과 remaining_minutes 계산은 브리지 서버(파이썬)에서 한다.

  오버라이드 (환경변수):
    CCUBAR_STATUSLINE_ORIGINAL  통과시킬 원본 statusline
                                (기본: %USERPROFILE%\.claude\statusline.ps1 → .sh 순)
    CCUBAR_USAGE_SNAPSHOT       스냅샷 출력 경로
                                (기본: %USERPROFILE%\.claude\usage-snapshot.json)
#>

$ErrorActionPreference = 'SilentlyContinue'

# stdin 전체를 한 번만 읽는다.
$raw = [Console]::In.ReadToEnd()

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$original  = $env:CCUBAR_STATUSLINE_ORIGINAL
$snapshot  = if ($env:CCUBAR_USAGE_SNAPSHOT) { $env:CCUBAR_USAGE_SNAPSHOT } `
             else { Join-Path $claudeDir 'usage-snapshot.json' }

# --- 1) 원본 statusline 통과 (있을 때만) ---
if (-not $original) {
    foreach ($cand in @((Join-Path $claudeDir 'statusline.ps1'),
                        (Join-Path $claudeDir 'statusline.sh'))) {
        if (Test-Path $cand) { $original = $cand; break }
    }
}
if ($original -and (Test-Path $original)) {
    try {
        switch ([IO.Path]::GetExtension($original).ToLower()) {
            '.ps1'  { $raw | & powershell -NoProfile -ExecutionPolicy Bypass -File $original }
            '.sh'   { $raw | & bash $original }
            default { $raw | & $original }
        }
    } catch { }
}

# --- 2) 스냅샷 저장 (모든 실패 삼킴) ---
try {
    $d  = $raw | ConvertFrom-Json
    $rl = $d.rate_limits
    $f  = if ($rl) { $rl.five_hour } else { $null }
    $s  = if ($rl) { $rl.seven_day } else { $null }

    if ($f -or $s) {
        $rateLimits = [ordered]@{}
        if ($f) { $rateLimits['five_hour'] = [ordered]@{ used_percentage = $f.used_percentage; resets_at = $f.resets_at } }
        if ($s) { $rateLimits['seven_day'] = [ordered]@{ used_percentage = $s.used_percentage; resets_at = $s.resets_at } }

        $obj = [ordered]@{
            schema_version = 1
            captured_at    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            source         = 'statusline'
            rate_limits    = $rateLimits
            session        = [ordered]@{
                model       = if ($d.model)          { $d.model.display_name }          else { $null }
                cost_usd    = if ($d.cost)           { $d.cost.total_cost_usd }         else { $null }
                context_pct = if ($d.context_window) { $d.context_window.used_percentage } else { $null }
            }
        }

        $json = $obj | ConvertTo-Json -Depth 6 -Compress
        $tmp  = "$snapshot.tmp.$PID"
        [IO.File]::WriteAllText($tmp, $json)
        Move-Item -Force -Path $tmp -Destination $snapshot   # 같은 볼륨 내 교체
    }
} catch { }

exit 0
