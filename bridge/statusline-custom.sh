#!/bin/bash
# statusline-custom.sh — CCU Bar 사용량 수집기 래퍼
#
# Claude Code 가 settings.json 의 statusLine.command 로 이 스크립트를 호출한다.
# stdin 으로 넘어온 세션 JSON 을 받아 두 가지 일을 한다:
#   1) 원본 statusline 을 그대로 실행해 화면 출력을 통과시킨다 (표시가 깨지면 안 됨).
#   2) rate_limits 를 usage-snapshot.json 으로 원자적으로 저장한다 (브리지 서버가 읽는다).
#
# 설계 규칙:
#   - 스냅샷 저장 실패가 화면 렌더를 막지 않도록 모든 오류를 삼키고 항상 exit 0.
#   - 성능 예산 50ms: 필드마다 파서를 부르지 않고 jq(없으면 python) 1회 호출로 전부 뽑는다.
#   - 부재 보존: rate_limits(또는 두 창 모두)가 없으면 스냅샷을 갱신하지 않는다.
#     세션 첫 API 응답 전이나 Pro/Max 가 아니면 필드가 비므로, 0 으로 덮어쓰면 마지막
#     정상 스냅샷이 파괴된다. → 이 경우 기존 파일을 그대로 둔다.
#   - resets_at 은 statusline 이 주는 Unix epoch 정수 그대로 저장한다. epoch→ISO 변환과
#     remaining_minutes 계산은 브리지 서버(파이썬)에서 한 곳에 모아 수행한다.
#
# 오버라이드 (환경변수):
#   CCUBAR_STATUSLINE_ORIGINAL  통과시킬 원본 statusline (기본 ~/.claude/statusline.sh)
#   CCUBAR_USAGE_SNAPSHOT       스냅샷 출력 경로 (기본 ~/.claude/usage-snapshot.json)

input=$(cat)

ORIGINAL="${CCUBAR_STATUSLINE_ORIGINAL:-$HOME/.claude/statusline.sh}"
SNAPSHOT="${CCUBAR_USAGE_SNAPSHOT:-$HOME/.claude/usage-snapshot.json}"

# --- 1) 원본 통과 (있을 때만). 원본이 없으면 조용히 건너뛴다. ---
if [ -x "$ORIGINAL" ]; then
  printf '%s' "$input" | "$ORIGINAL"
elif [ -f "$ORIGINAL" ]; then
  printf '%s' "$input" | bash "$ORIGINAL"
fi

# --- 2) 스냅샷 저장 (모든 stdout/stderr 격리 → 화면에 새어나가지 않음) ---
{
  snapshot_json=""

  if command -v jq >/dev/null 2>&1; then
    # rate_limits.five_hour / seven_day 중 하나라도 있으면 스냅샷 JSON, 없으면 빈 출력.
    snapshot_json=$(printf '%s' "$input" | jq -c '
      (.rate_limits // {}) as $rl
      | ($rl.five_hour  // null) as $f
      | ($rl.seven_day  // null) as $s
      | if ($f == null) and ($s == null) then empty
        else {
          schema_version: 1,
          captured_at: (now | todate),
          source: "statusline",
          rate_limits: (
            (if $f then {five_hour: {used_percentage: $f.used_percentage, resets_at: $f.resets_at}} else {} end)
            + (if $s then {seven_day: {used_percentage: $s.used_percentage, resets_at: $s.resets_at}} else {} end)
          ),
          session: {
            model:       (.model.display_name // null),
            cost_usd:    (.cost.total_cost_usd // null),
            context_pct: (.context_window.used_percentage // null)
          }
        } end
    ' 2>/dev/null)
  else
    py=$(command -v python3 || command -v python)
    if [ -n "$py" ]; then
      snapshot_json=$(printf '%s' "$input" | "$py" - <<'PY' 2>/dev/null
import sys, json, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rl = d.get("rate_limits") or {}
f = rl.get("five_hour"); s = rl.get("seven_day")
if not isinstance(f, dict) and not isinstance(s, dict):
    sys.exit(0)  # 부재 보존: 아무것도 출력하지 않음
out = {
    "schema_version": 1,
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "source": "statusline",
    "rate_limits": {},
    "session": {
        "model":       (d.get("model") or {}).get("display_name"),
        "cost_usd":    (d.get("cost") or {}).get("total_cost_usd"),
        "context_pct": (d.get("context_window") or {}).get("used_percentage"),
    },
}
if isinstance(f, dict):
    out["rate_limits"]["five_hour"] = {"used_percentage": f.get("used_percentage"), "resets_at": f.get("resets_at")}
if isinstance(s, dict):
    out["rate_limits"]["seven_day"] = {"used_percentage": s.get("used_percentage"), "resets_at": s.get("resets_at")}
print(json.dumps(out))
PY
)
    fi
  fi

  # 부재 보존: 뽑아낸 게 없으면 기존 스냅샷을 건드리지 않는다.
  if [ -n "$snapshot_json" ]; then
    tmp="$(mktemp "${SNAPSHOT}.tmp.XXXXXX")" || exit 0
    if printf '%s' "$snapshot_json" > "$tmp"; then
      chmod 600 "$tmp" 2>/dev/null
      mv -f "$tmp" "$SNAPSHOT"    # 같은 디렉터리 내 rename → 원자적 교체
    else
      rm -f "$tmp"
    fi
  fi
} >/dev/null 2>&1

exit 0
