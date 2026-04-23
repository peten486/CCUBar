#!/bin/bash
# Claude.ai 사용량 모니터링 서버 종료 스크립트
cd "$(dirname "$0")"

PROCESS_PATTERN="claude_usage_scraper.py"
PID_FILE=".app.pid"

# 프로세스 존재 여부 확인
if ! pgrep -f "$PROCESS_PATTERN" > /dev/null 2>&1; then
    echo "프로세스가 실행 중이 아닙니다"
    rm -f "$PID_FILE"
    exit 0
fi

# PID 파일을 먼저 삭제하여 감시 루프가 재시작하지 않도록 함
rm -f "$PID_FILE"

# 감시 프로세스(서브쉘) 종료
if [ -n "$WATCHDOG_PID" ] || [ -f ".app.pid" ]; then
    :
fi

# SIGTERM으로 graceful 종료 시도
echo "서버 종료 중... (SIGTERM)"
pkill -f "$PROCESS_PATTERN"

# 프로세스 종료 대기 (최대 5초)
for i in $(seq 1 10); do
    if ! pgrep -f "$PROCESS_PATTERN" > /dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

# 5초 후에도 생존 시 SIGKILL 강제 종료
if pgrep -f "$PROCESS_PATTERN" > /dev/null 2>&1; then
    echo "graceful 종료 실패 → SIGKILL 강제 종료"
    pkill -9 -f "$PROCESS_PATTERN"
    sleep 0.5
fi

echo "서버 종료 완료"
