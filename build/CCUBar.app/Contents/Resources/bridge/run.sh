#!/bin/bash
# Claude.ai 사용량 모니터링 서버 시작 스크립트
# 브라우저 쿠키에서 sessionKey를 자동 추출하여 API 직접 호출 (Safari 우선, Chrome 폴백)
#
# Safari: 전체 디스크 접근 권한만 있으면 binarycookies에서 직접 읽음 (패스워드 불필요)
# Chrome: Keychain의 Safe Storage 패스워드로 AES 복호화 필요
cd "$(dirname "$0")"

PID_FILE=".app.pid"

# 이미 실행 중인 프로세스 확인
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[ERROR] 이미 실행 중입니다 (PID $OLD_PID)"
        exit 1
    fi
    rm -f "$PID_FILE"
fi

# Chrome Safe Storage 패스워드는 여기서 미리 뽑지 않는다. browser_cookie3 가 필요 시점에
# /usr/bin/security 를 직접 호출해 Keychain 에서 조회하므로, 스크립트가 환경변수나 캐시
# 파일로 전달할 필요가 없다. (첫 접근 시 Keychain '항상 허용'을 물으며, 그 권한은
# /usr/bin/security 에 귀속돼 이후 재사용된다. 대화상자를 놓쳤다면 refresh_keychain.sh 참고.)

# Flask 서버를 백그라운드에서 감시하며 자동 재시작
RESTART_DELAY=3

(
    while true; do
        python3 claude_usage_scraper.py --server >> app.log 2>&1
        EXIT_CODE=$?
        # PID 파일이 삭제되었으면 stop.sh에 의한 정상 종료로 판단
        if [ ! -f "$PID_FILE" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 정상 종료 (PID 파일 없음)" >> app.log
            break
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 프로세스 종료됨 (exit=$EXIT_CODE), ${RESTART_DELAY}초 후 재시작..." >> app.log
        sleep "$RESTART_DELAY"
    done
) &
WATCHDOG_PID=$!
echo $WATCHDOG_PID > "$PID_FILE"
echo "[API Mode] 서버 시작 완료 (감시 PID $WATCHDOG_PID, 로그: app.log)"
echo "[INFO] 프로세스 종료 시 자동 재시작됩니다. 완전 종료: stop.sh 사용"
