#!/bin/bash
# Chrome 쿠키 복호화용 Keychain 접근을 미리 허용해 두는 스크립트.
# Terminal.app 또는 iTerm 등 GUI 터미널에서 직접 실행해야 합니다.
#
# 패스워드를 파일로 캐시하지 않습니다. browser_cookie3 는 필요 시점에 /usr/bin/security 를
# 직접 호출하는데, 여기서 같은 바이너리로 한 번 조회하며 Keychain '항상 허용'을 선택해 두면
# 그 ACL 이 /usr/bin/security 에 귀속돼 이후 브리지가 프롬프트 없이 쿠키를 복호화합니다.
#
# Safari는 Keychain 패스워드가 필요 없으며, 전체 디스크 접근 권한만 필요합니다.
cd "$(dirname "$0")"

echo "=== 키체인 접근 허용 (Chrome) ==="
echo ""

# 키체인 잠금 해제
echo "macOS 로그인 패스워드를 입력하세요:"
security unlock-keychain ~/Library/Keychains/login.keychain-db

if [ $? -ne 0 ]; then
    echo "[ERROR] 키체인 잠금해제 실패"
    exit 1
fi

echo ""

# Chrome Safe Storage — 조회에 성공하면 ACL 이 설정된 것. 값은 저장하지 않는다.
CHROME_PASS=$(security find-generic-password -s "Chrome Safe Storage" -a "Chrome" -w 2>/dev/null)
if [ -n "$CHROME_PASS" ]; then
    echo "[OK] Chrome Safe Storage 접근 확인 (${#CHROME_PASS}자) — 대화상자에서 '항상 허용'을 선택했다면 완료"
else
    echo "[ERROR] Chrome Safe Storage 접근 실패"
    echo "  - 키체인 접근 '항상 허용'을 선택했는지 확인하세요"
    exit 1
fi

echo ""
echo "=== 완료 ==="
echo "서버 재시작: ./stop.sh && ./run.sh"
