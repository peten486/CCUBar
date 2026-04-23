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

# Chrome Safe Storage 패스워드 추출 (Chrome 폴백용, Safari는 불필요)
CHROME_SAFE_STORAGE_PASS=""
CHROME_SAFE_STORAGE_PASS=$(security find-generic-password -s "Chrome Safe Storage" -a "Chrome" -w 2>/dev/null)
if [ -n "$CHROME_SAFE_STORAGE_PASS" ]; then
    echo "[OK] Chrome Safe Storage 패스워드 추출 성공 (Keychain)"
    echo -n "$CHROME_SAFE_STORAGE_PASS" > .chrome_safe_storage_pass
    chmod 600 .chrome_safe_storage_pass
elif [ -f ".chrome_safe_storage_pass" ]; then
    CHROME_SAFE_STORAGE_PASS=$(cat .chrome_safe_storage_pass)
    echo "[OK] Chrome Safe Storage 패스워드 캐시 사용"
else
    echo "[INFO] Chrome Safe Storage 패스워드 없음 (Safari만으로 동작 가능)"
fi

export CHROME_SAFE_STORAGE_PASS

# Flask 서버를 백그라운드에서 감시하며 자동 재시작
RESTART_DELAY=3

(
    while true; do
        env CHROME_SAFE_STORAGE_PASS="$CHROME_SAFE_STORAGE_PASS" python3 claude_usage_scraper.py --server >> app.log 2>&1
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
