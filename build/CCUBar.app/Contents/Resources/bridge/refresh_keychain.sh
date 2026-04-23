#!/bin/bash
# 키체인에서 Chrome Safe Storage 패스워드를 새로 추출하는 스크립트
# Terminal.app 또는 iTerm 등 GUI 터미널에서 직접 실행해야 합니다.
#
# Safari는 Keychain 패스워드가 필요 없으며, 전체 디스크 접근 권한만 필요합니다.
# 이 스크립트는 Chrome 폴백용 패스워드만 갱신합니다.
cd "$(dirname "$0")"

echo "=== 키체인 패스워드 갱신 (Chrome) ==="
echo ""

# 키체인 잠금 해제
echo "macOS 로그인 패스워드를 입력하세요:"
security unlock-keychain ~/Library/Keychains/login.keychain-db

if [ $? -ne 0 ]; then
    echo "[ERROR] 키체인 잠금해제 실패"
    exit 1
fi

echo ""

# Chrome Safe Storage
CHROME_PASS=$(security find-generic-password -s "Chrome Safe Storage" -a "Chrome" -w 2>/dev/null)
if [ -n "$CHROME_PASS" ]; then
    echo "[OK] Chrome Safe Storage: ${CHROME_PASS:0:4}*** (${#CHROME_PASS}자)"
    echo -n "$CHROME_PASS" > .chrome_safe_storage_pass
    chmod 600 .chrome_safe_storage_pass
else
    echo "[ERROR] Chrome Safe Storage 패스워드 추출 실패"
    echo "  - 키체인 접근 '항상 허용'을 선택했는지 확인하세요"
    exit 1
fi

echo ""
echo "=== 완료 ==="
echo "서버 재시작: ./stop.sh && ./run.sh"
