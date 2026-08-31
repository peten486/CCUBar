#!/usr/bin/env python3
"""
Claude.ai 사용량 조회 API 서버

Flask REST API 서버 모드(--server)로 실행하면 /api/usage 엔드포인트를 제공한다.
데이터 소스는 두 가지이며 CCUBAR_USAGE_SOURCE 로 선택한다 (기본 snapshot):

  snapshot (기본)
    - Claude Code 가 statusline 스크립트에 stdin 으로 넘기는 세션 JSON 에는
      계정 단위 rate_limits(5시간/7일 소진율·리셋)가 들어 있다.
    - 수집기(statusline-custom.sh)가 그 값을 usage-snapshot.json 으로 저장하고,
      이 서버는 그 파일만 읽는다. 인증도 네트워크 호출도 필요 없다.
    - statusline 은 resets_at 을 Unix epoch 정수로 주므로 이 서버가 ISO8601 로 변환하고
      remaining_minutes 를 계산한다. seven_day_sonnet 은 statusline 이 제공하지 않는다.

  browser_cookie (레거시)
    - 브라우저(Safari/Chrome) 쿠키에서 sessionKey 를 추출해 claude.ai 내부 API 를
      직접 호출한다 (curl_cffi 로 Cloudflare TLS 핑거프린트 우회).
    - 주기적 로그아웃 원인 가설 검증을 위해 플래그로만 남겨 둔 경로다.
    - Safari: binarycookies 직접 추출(전체 디스크 접근 필요).
      Chrome: browser_cookie3 가 /usr/bin/security 로 Keychain Safe Storage 패스워드를
      조회해 AES 복호화. token.ini 에는 org_id 만 저장.

공통: 표준화된 REST 에러 응답, 파일/콘솔 로깅(TimedRotatingFileHandler).
"""

# --- Flask: REST API 서버 ---
from flask import Flask, jsonify, request

# --- 표준 라이브러리 ---
import os
import json
import sys
import time
import configparser
import certifi
import logging
import threading
import signal
from logging.handlers import TimedRotatingFileHandler
from datetime import datetime, timezone

# --- 브라우저 쿠키 통합 추출 (Safari: binarycookies, Chrome: AES 복호화) ---
import browser_cookie3

# --- Cloudflare 우회 HTTP 클라이언트 ---
from curl_cffi import requests as curl_requests

# --- 로컬 Claude Code 로그 기반 토큰 집계 (부가 기능) ---
# 순수 부가물이므로, 번들에서 빠졌거나 임포트가 깨져도 쿼터 조회는 계속 동작해야 한다.
try:
    from claude_token_stats import TokenAggregator
except Exception:
    TokenAggregator = None


# --- macOS SSL 인증서 문제 해결 ---
os.environ['SSL_CERT_FILE'] = certifi.where()
os.environ['REQUESTS_CA_BUNDLE'] = certifi.where()


# ============================================================
# 설정 상수
# ============================================================

API_PORT = int(os.getenv("API_PORT", "8306"))
# 바인드 주소. 기본값은 모든 인터페이스 — 다른 기기(휴대폰, 워치페이스, 홈서버)에서
# 폴링하는 구성이 흔하기 때문이다. 이 머신에서만 쓸 거라면 BRIDGE_HOST=127.0.0.1 로
# 잠글 것. 노출 시 무엇이 공개되는지는 아래 _warn_if_exposed() 와 README 참고.
BRIDGE_HOST = os.getenv("BRIDGE_HOST", "0.0.0.0").strip() or "0.0.0.0"
CACHE_TTL_SECONDS = int(os.getenv("CACHE_TTL_SECONDS", "300"))
# 조회 실패 후 재시도까지의 최소 간격. 실패는 대개 지속적(로그아웃, 권한 없음)인데
# 클라이언트는 수 초 간격으로 폴링하므로, 쿨다운이 없으면 매 요청마다 Safari 파일
# 접근과 Chrome 쿠키 복호화를 다시 시도하고 로그를 여섯 줄씩 남긴다.
FAILURE_COOLDOWN_SECONDS = int(os.getenv("FAILURE_COOLDOWN_SECONDS", "60"))
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")

# 로컬 로그 토큰 집계 (부가 기능). 상류 쿼터 조회와는 수명도 무효화 조건도 다르므로
# _usage_cache 를 재사용하지 않고 별도 상태를 둔다.
TOKENS_ENABLED = os.getenv("TOKENS_ENABLED", "1").strip().lower() not in ("0", "false", "no")
TOKENS_SCAN_INTERVAL = int(os.getenv("TOKENS_SCAN_INTERVAL", "30"))
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# When launched by CCU Bar from a read-only .app bundle, the script directory
# can't receive writes — so the launcher injects CCUBAR_BRIDGE_DATA pointing to
# a user-writable folder (e.g. ~/Library/Application Support/CCUBar/bridge/).
_DATA_DIR = os.environ.get("CCUBAR_BRIDGE_DATA", "").strip() or _SCRIPT_DIR
try:
    os.makedirs(_DATA_DIR, exist_ok=True)
except Exception:
    _DATA_DIR = _SCRIPT_DIR  # graceful fallback

TOKEN_FILE = os.path.join(_DATA_DIR, "token.ini")
LOG_FILE = os.path.join(_DATA_DIR, "app.log")

# /api/usage 응답에 실을 쿼터 구간. REQUIRED_PERIODS 가 빠지면 상류 스키마가 바뀐 것이므로
# 경고를 남기고, 나머지는 플랜에 따라 정상적으로 null 이 올 수 있어 조용히 생략한다.
USAGE_PERIODS = ["five_hour", "seven_day", "seven_day_sonnet"]
REQUIRED_PERIODS = {"five_hour"}

# ============================================================
# 데이터 소스 선택 (snapshot 기본 / browser_cookie 레거시)
# ============================================================

# snapshot       — statusline 수집기가 저장한 usage-snapshot.json 을 읽는다 (기본).
# browser_cookie — 레거시. 브라우저 sessionKey 로 claude.ai 내부 API 를 직접 호출한다.
USAGE_SOURCE = (os.getenv("CCUBAR_USAGE_SOURCE", "snapshot").strip().lower() or "snapshot")

# statusline 수집기(statusline-custom.sh)가 원자적으로 쓰는 스냅샷 파일.
SNAPSHOT_FILE = (
    os.environ.get("CCUBAR_USAGE_SNAPSHOT", "").strip()
    or os.path.expanduser("~/.claude/usage-snapshot.json")
)
# 스냅샷이 이보다 오래되면 응답에 stale=true 를 실어 "N분 전 기준"임을 위젯에 알린다.
STALE_THRESHOLD_SECONDS = int(os.getenv("STALE_THRESHOLD_SECONDS", "1800"))
# 이 서버가 이해하는 스냅샷 스키마 버전. 더 큰 버전을 만나면 경고 후 아는 필드만 쓴다.
SNAPSHOT_SCHEMA_VERSION = 1
# 스냅샷에서 나오는 구간. statusline 은 seven_day_sonnet 을 제공하지 않으므로 제외한다.
SNAPSHOT_PERIODS = ["five_hour", "seven_day"]

# 지원 브라우저 (browser_cookie3 경로 매핑)
# - Safari: ~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies
# - Chrome: ~/Library/Application Support/Google/Chrome/Default/Cookies (AES 복호화 필요)
# BROWSER_PRIORITY 는 logger 초기화 후 `_compute_browser_priority()` 로 동적 계산된다.
SUPPORTED_BROWSERS = ["safari", "chrome"]
BROWSER_PRIORITY = list(SUPPORTED_BROWSERS)  # 나중에 재계산됨

# macOS Launch Services 핸들러 bundle id → 내부 키 매핑
DEFAULT_BROWSER_BUNDLE_MAP = {
    "com.apple.safari":          "safari",
    "com.google.chrome":         "chrome",
    "com.google.chrome.canary":  "chrome",
    "com.google.chrome.beta":    "chrome",
    "com.google.chrome.dev":     "chrome",
    "com.brave.browser":         "chrome",   # Chromium 기반 → Chrome 복호화 경로 호환
    "com.microsoft.edgemac":     "chrome",
    "com.operasoftware.opera":   "chrome",
    "com.vivaldi.vivaldi":       "chrome",
}


# ============================================================
# 로깅 시스템 설정
# ============================================================

def setup_logger():
    """파일(app.log, 10MB 로테이션) + 콘솔(stderr) 로거 초기화."""
    app_logger = logging.getLogger("claude_usage_scraper")
    app_logger.setLevel(logging.DEBUG)

    if app_logger.handlers:
        return app_logger

    formatter = logging.Formatter(
        '[%(asctime)s] [%(levelname)s] [%(funcName)s] %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )

    # Daily rotation at local midnight. Keeps up to 14 days of history; older files
    # are pruned automatically. Suffix is YYYY-MM-DD so files sort chronologically.
    file_handler = TimedRotatingFileHandler(
        LOG_FILE, when="midnight", interval=1, backupCount=14, encoding="utf-8"
    )
    file_handler.suffix = "%Y-%m-%d"
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)

    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(getattr(logging, LOG_LEVEL.upper(), logging.INFO))
    console_handler.setFormatter(formatter)

    app_logger.addHandler(file_handler)
    app_logger.addHandler(console_handler)

    return app_logger


logger = setup_logger()


# ============================================================
# 기본 브라우저 감지 → 쿠키 추출 우선순위 재계산
# ============================================================

def _detect_default_browser():
    """
    macOS Launch Services에서 https:// 스킴 기본 핸들러를 조회해
    어느 브라우저가 기본값인지 추론한다. 실패/미지원 시 None.
    """
    import subprocess, re
    try:
        prefs = os.path.expanduser(
            "~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"
        )
        result = subprocess.run(
            ["plutil", "-convert", "xml1", "-o", "-", prefs],
            capture_output=True, text=True, timeout=3, check=False
        )
        if result.returncode != 0:
            return None

        for block in re.findall(r"<dict>(.*?)</dict>", result.stdout, re.DOTALL):
            if re.search(r"<key>LSHandlerURLScheme</key>\s*<string>https</string>", block):
                m = re.search(
                    r"<key>LSHandlerRoleAll</key>\s*<string>([^<]+)</string>", block
                )
                if m:
                    bundle_id = m.group(1).strip().lower()
                    mapped = DEFAULT_BROWSER_BUNDLE_MAP.get(bundle_id)
                    if mapped:
                        logger.info(
                            f"기본 브라우저 감지: {bundle_id} → 쿠키 추출 '{mapped}' 사용"
                        )
                        return mapped
                    logger.info(
                        f"기본 브라우저({bundle_id})는 미지원 — Safari/Chrome 순 폴백"
                    )
                    return None
        logger.debug("Launch Services에서 https 기본 핸들러를 찾지 못함")
    except Exception as e:
        logger.debug(f"기본 브라우저 감지 예외: {e}")
    return None


def _compute_browser_priority():
    """기본 브라우저를 최우선, 나머지 지원 브라우저를 뒤에 붙여 반환."""
    default = _detect_default_browser()
    if default and default in SUPPORTED_BROWSERS:
        return [default] + [b for b in SUPPORTED_BROWSERS if b != default]
    return list(SUPPORTED_BROWSERS)


# 모듈 초기화 시점에 우선순위 확정
BROWSER_PRIORITY = _compute_browser_priority()
logger.info(f"브라우저 추출 순서: {BROWSER_PRIORITY}")


# ============================================================
# 캐싱 메커니즘 (스레드 안전)
# ============================================================

_usage_cache = {"data": None, "timestamp": None}
# 마지막 실패와 그 사유. 성공 캐시와 수명이 다르므로(TTL 5분 vs 쿨다운 60초) 따로 둔다.
_failure_cache = {"message": None, "timestamp": None}
_cache_lock = threading.Lock()


def get_cached_usage():
    """캐시된 사용량 데이터를 반환한다. 만료되었거나 없으면 None."""
    with _cache_lock:
        if _usage_cache["data"] is None or _usage_cache["timestamp"] is None:
            logger.debug("캐시 데이터 없음 (cache miss)")
            return None

        elapsed = (datetime.utcnow() - _usage_cache["timestamp"]).total_seconds()

        if elapsed > CACHE_TTL_SECONDS:
            logger.info(f"캐시 만료 (경과: {elapsed:.1f}초, TTL: {CACHE_TTL_SECONDS}초)")
            _usage_cache["data"] = None
            _usage_cache["timestamp"] = None
            return None

        logger.info(f"캐시 적중 (경과: {elapsed:.1f}초)")
        return dict(_usage_cache["data"])


def set_cached_usage(data):
    """스크래핑 결과를 캐시에 저장한다."""
    with _cache_lock:
        _usage_cache["data"] = dict(data)
        _usage_cache["timestamp"] = datetime.utcnow()
        # 성공했으니 남아 있던 쿨다운은 즉시 해제한다.
        _failure_cache["message"] = None
        _failure_cache["timestamp"] = None
        logger.debug("캐시 갱신 완료")


def get_cooldown_failure():
    """쿨다운이 아직 유효하면 마지막 실패 사유를 반환한다. 아니면 None."""
    with _cache_lock:
        if _failure_cache["timestamp"] is None:
            return None

        elapsed = (datetime.utcnow() - _failure_cache["timestamp"]).total_seconds()
        if elapsed > FAILURE_COOLDOWN_SECONDS:
            _failure_cache["message"] = None
            _failure_cache["timestamp"] = None
            return None

        return _failure_cache["message"]


def set_cooldown_failure(message):
    """실패 사유를 기록해 쿨다운 시작."""
    with _cache_lock:
        _failure_cache["message"] = message
        _failure_cache["timestamp"] = datetime.utcnow()


def clear_cache():
    """캐시를 수동으로 무효화한다."""
    with _cache_lock:
        _usage_cache["data"] = None
        _usage_cache["timestamp"] = None
        _failure_cache["message"] = None
        _failure_cache["timestamp"] = None
        logger.debug("캐시 초기화 완료")


# ============================================================
# 로컬 토큰 집계기 (부가 기능)
# ============================================================

# 위 _usage_cache 와 의도적으로 분리된 상태다. 상류 캐시는 5분 TTL, 이쪽은 30초 스캔
# 주기라 하나로 합치면 둘 중 하나가 반드시 손해를 본다. 락 관용구만 맞춰 둔다.
_aggregator = TokenAggregator() if (TOKENS_ENABLED and TokenAggregator) else None


def _tokens_block(args):
    """
    응답에 덧붙일 tokens 블록을 만든다. 비활성/오류면 None.

    호출자는 이 함수의 예외를 삼켜야 한다 — 토큰 통계는 부가물이고, 상류 쿼터 응답이
    이것 때문에 실패해선 안 된다.
    """
    if _aggregator is None:
        return None

    mode = (args.get("tokens") or "").strip().lower()
    if mode == "off":
        return None

    _aggregator.maybe_scan(TOKENS_SCAN_INTERVAL)
    return _aggregator.snapshot(
        range_key=(args.get("range") or "today").strip().lower(),
        since=args.get("since"),
        until=args.get("until"),
        tz_name=args.get("tz"),
        full=(mode == "full"),
    )


def _warn_if_exposed():
    """
    루프백 밖으로 바인드할 때 무엇이 공개되는지 기동 로그에 남긴다.

    이 서비스에는 인증이 전혀 없다. 포트에 닿을 수 있는 누구나 전체 응답을 읽는다.
    """
    if BRIDGE_HOST in ("127.0.0.1", "localhost", "::1"):
        return

    logger.warning(f"⚠  {BRIDGE_HOST} 에 바인드됨 — 이 머신 밖에서 접근 가능합니다.")
    logger.warning("⚠  인증이 없으므로 포트에 닿는 누구나 아래를 읽을 수 있습니다:")
    logger.warning("⚠   · 쿼터 소진률 (5시간 / 7일 / Sonnet 7일)")
    if _aggregator is not None:
        logger.warning("⚠   · 프로젝트 이름과 절대 경로 (tokens.by_project[].cwd)")
        logger.warning("⚠   · 시간대별 활동 패턴 — 언제 작업하는지 (tokens.by_hour)")
        logger.warning("⚠   · 토큰 사용량과 모델별 분해")
        logger.warning("⚠  토큰 통계만 빼려면 TOKENS_ENABLED=0, 전부 잠그려면 BRIDGE_HOST=127.0.0.1")
    else:
        logger.warning("⚠  전부 잠그려면 BRIDGE_HOST=127.0.0.1")
    logger.warning("⚠  sessionKey 쿠키 자체는 응답에 실리지 않습니다.")


def warmup_token_stats_on_startup():
    """서버 시작 시 로그 트리 최초 전체 스캔. 실패해도 서버는 정상 시작."""
    if _aggregator is None:
        return
    try:
        _aggregator.scan()
        stats = _aggregator.stats
        logger.info(
            f"토큰 집계 워밍업 완료 "
            f"(파일 {stats['files_tracked']}개, {stats['scan_ms']}ms)"
        )
    except Exception as e:
        logger.warning(f"토큰 집계 워밍업 실패: {e}")


# ============================================================
# Flask 앱 인스턴스
# ============================================================

app = Flask(__name__)


# ============================================================
# 브라우저 쿠키에서 sessionKey 추출 (Safari 우선, Chrome 폴백)
# ============================================================

def _full_disk_access_grantee():
    """
    '전체 디스크 접근'을 부여해야 할 대상 앱 이름을 반환한다.

    TCC 는 이 파이썬 프로세스가 아니라 그것을 띄운 앱에 권한을 귀속시킨다. CCU Bar 가
    브리지를 spawn 한 경우 대상은 CCUBar.app 이고, 셸에서 직접 띄운 경우에만 터미널이다.
    launcher 가 CCUBAR_BRIDGE_DATA 를 주입하므로 그것으로 구분한다.
    """
    if os.environ.get("CCUBAR_BRIDGE_DATA", "").strip():
        return "CCUBar.app"
    return "현재 이 스크립트를 실행 중인 터미널 앱(Terminal/iTerm 등)"


def _extract_session_key_safari():
    """
    Safari의 binarycookies 파일에서 claude.ai sessionKey를 추출한다.
    전제 조건: 이 프로세스의 책임 앱에 '전체 디스크 접근' 권한 부여
    (_full_disk_access_grantee() 참고).

    Returns:
        str | None: sessionKey 문자열 또는 None
    """
    try:
        cj = browser_cookie3.safari(domain_name="claude.ai")
        for cookie in cj:
            if cookie.name == "sessionKey" and "claude.ai" in cookie.domain:
                logger.info(f"Safari 쿠키에서 sessionKey 추출 성공: {cookie.value[:8]}***")
                return cookie.value
        logger.debug("Safari 쿠키에 sessionKey 없음 (claude.ai 로그인 필요)")
        return None
    except PermissionError as e:
        logger.error(
            f"Safari 쿠키 접근 권한 없음: {e} — "
            f"시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근 에서 "
            f"{_full_disk_access_grantee()} 에 권한을 부여하세요"
        )
        return None
    except Exception as e:
        logger.error(f"Safari 쿠키 추출 실패: {e}", exc_info=True)
        return None


def _extract_session_key_chrome():
    """
    Chrome의 쿠키 DB(SQLite + AES 암호화)에서 claude.ai sessionKey를 추출한다.
    browser_cookie3가 /usr/bin/security 를 직접 호출해 Keychain의 "Chrome Safe Storage"
    패스워드를 조회하고 쿠키를 복호화한다. 환경변수나 캐시 파일은 사용하지 않는다 —
    첫 접근 시 Keychain 이 '항상 허용'을 물으며, 그 권한은 /usr/bin/security 에 귀속된다.

    Returns:
        str | None: sessionKey 문자열 또는 None
    """
    try:
        cj = browser_cookie3.chrome(domain_name="claude.ai")
        for cookie in cj:
            if cookie.name == "sessionKey" and "claude.ai" in cookie.domain:
                logger.info(f"Chrome 쿠키에서 sessionKey 추출 성공: {cookie.value[:8]}***")
                return cookie.value
        logger.debug("Chrome 쿠키에 sessionKey 없음")
        return None
    except Exception as e:
        logger.error(f"Chrome 쿠키 추출 실패: {e}", exc_info=True)
        return None


def _get_session_key_from_browser():
    """
    브라우저 쿠키에서 claude.ai sessionKey를 추출한다.
    Safari → Chrome 순서로 시도한다.

    Returns:
        str | None: sessionKey 문자열 또는 None
    """
    extractors = {
        "safari": _extract_session_key_safari,
        "chrome": _extract_session_key_chrome,
    }

    for browser_key in BROWSER_PRIORITY:
        extractor = extractors.get(browser_key)
        if extractor is None:
            continue
        session_key = extractor()
        if session_key:
            return session_key

    logger.warning("모든 브라우저에서 sessionKey를 찾을 수 없음 - Claude.ai 로그인 필요")
    return None


# ============================================================
# token.ini에서 org_id 로드
# ============================================================

def _load_org_id():
    """token.ini 또는 CCUBAR_ORG_ID 환경변수에서 org_id 를 읽어 반환. 없으면 None."""
    env_override = os.environ.get("CCUBAR_ORG_ID", "").strip()
    if env_override:
        return env_override

    if not os.path.exists(TOKEN_FILE):
        return None

    try:
        config = configparser.ConfigParser()
        config.read(TOKEN_FILE)
        org_id = config.get('claude', 'org_id').strip()
        return org_id or None
    except Exception:
        return None


def _save_org_id(org_id: str) -> None:
    """이후 실행에서 재사용하도록 token.ini 에 org_id 를 저장."""
    try:
        config = configparser.ConfigParser()
        if os.path.exists(TOKEN_FILE):
            config.read(TOKEN_FILE)
        if 'claude' not in config:
            config['claude'] = {}
        config['claude']['org_id'] = org_id
        with open(TOKEN_FILE, 'w') as f:
            config.write(f)
        logger.info(f"token.ini 저장: org_id={org_id}")
    except Exception as e:
        logger.warning(f"token.ini 저장 실패: {e}")


def _discover_org_id(session_key: str):
    """sessionKey 로 /api/organizations 를 호출해 첫 번째 조직 UUID 를 반환. 실패 시 None."""
    try:
        session = curl_requests.Session(impersonate="chrome124")
        session.cookies.set("sessionKey", session_key, domain=".claude.ai")
        resp = session.get("https://claude.ai/api/organizations", timeout=10)
        if resp.status_code != 200:
            logger.warning(
                f"organizations 조회 실패: HTTP {resp.status_code}"
            )
            return None
        data = resp.json()
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, dict):
                uuid = first.get("uuid") or first.get("id")
                if uuid:
                    return uuid
        logger.warning("organizations 응답이 비었거나 UUID 없음")
    except Exception as e:
        logger.warning(f"org_id 자동 탐지 예외: {e}")
    return None


# ============================================================
# API 호출
# ============================================================

def _fetch_usage_via_api():
    """
    브라우저 쿠키의 sessionKey + token.ini의 org_id로 사용량 API를 호출한다.

    Returns:
        dict | None: 성공 시 사용량 데이터 dict, 실패 시 None
    """
    # sessionKey 획득 (브라우저 쿠키에서 자동 추출: Safari 우선, Chrome 폴백)
    session_key = _get_session_key_from_browser()
    if not session_key:
        logger.error("sessionKey를 획득할 수 없음")
        return None

    # org_id 획득: token.ini → 없으면 /api/organizations 자동 탐지 후 저장
    org_id = _load_org_id()
    if not org_id:
        logger.info("org_id 미설정 — /api/organizations 자동 탐지 시도")
        org_id = _discover_org_id(session_key)
        if not org_id:
            logger.error("org_id 자동 탐지 실패 — claude.ai 로그인 상태 확인 필요")
            return None
        _save_org_id(org_id)

    # curl_cffi Session 생성 (Chrome TLS 핑거프린트 모방으로 Cloudflare 우회)
    session = curl_requests.Session(impersonate="chrome124")
    session.cookies.set("sessionKey", session_key, domain=".claude.ai")

    # 사용량 데이터 조회 (429 재시도 포함)
    usage_url = f"https://claude.ai/api/organizations/{org_id}/usage"
    max_retries = 3
    usage_resp = None

    for attempt in range(1, max_retries + 1):
        logger.debug(f"사용량 데이터 조회 (시도 {attempt}/{max_retries})")
        try:
            usage_resp = session.get(usage_url, timeout=10)
        except Exception as e:
            logger.error(f"HTTP 요청 실패: {e}")
            if attempt < max_retries:
                time.sleep(2 * attempt)
                continue
            return None

        if usage_resp.status_code == 429:
            retry_after = max(3, int(usage_resp.headers.get("Retry-After", 3 * attempt)))
            logger.warning(f"HTTP 429 Rate Limit - {retry_after}초 후 재시도 ({attempt}/{max_retries})")
            if attempt < max_retries:
                time.sleep(retry_after)
                continue
            else:
                logger.error(f"사용량 조회 실패: HTTP 429 ({max_retries}회 재시도 소진)")
                return None
        break

    if usage_resp.status_code != 200:
        logger.error(f"사용량 조회 실패: HTTP {usage_resp.status_code}")
        logger.debug(f"응답 본문: {usage_resp.text[:500]}")
        return None

    usage_data = usage_resp.json()

    if not isinstance(usage_data, dict):
        logger.error(f"API 응답이 dict가 아님: {type(usage_data)}")
        return None

    logger.debug(f"API 응답 키: {list(usage_data.keys())}")

    # 응답 데이터를 표준 형식으로 변환
    result = {"timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")}

    for period_key in USAGE_PERIODS:
        period_data = usage_data.get(period_key)

        # 상류는 플랜에 없는 쿼터를 null 로 내려준다 (Pro 계정의 seven_day_sonnet 등).
        # 예전에는 이걸 utilization 0.0 으로 채워 넣었는데, 그러면 "아직 안 썼음" 과
        # "이 플랜엔 해당 없음" 이 구분되지 않아 게이지가 영원히 0% 로 표시됐다.
        # 이제는 키 자체를 빼서, 소비자가 없는 쿼터를 숨길 수 있게 한다.
        if not isinstance(period_data, dict):
            if period_key in REQUIRED_PERIODS:
                logger.warning(
                    f"API 응답에 필수 항목 {period_key} 가 없거나 dict 가 아님: "
                    f"{type(period_data).__name__}"
                )
            else:
                logger.debug(f"{period_key} 미제공(null) — 응답에서 생략")
            continue

        # dict 가 와도 utilization 만 null 인 경우가 있다 — 위와 같은 이유로 생략한다.
        try:
            utilization = float(period_data.get("utilization"))
        except (TypeError, ValueError):
            logger.debug(f"{period_key} utilization 미제공 — 응답에서 생략")
            continue

        resets_at_str = period_data.get("resets_at")

        remaining_minutes = 0
        if resets_at_str:
            try:
                resets_at = datetime.fromisoformat(resets_at_str.replace("Z", "+00:00"))
                now = datetime.now(resets_at.tzinfo)
                remaining_minutes = max(0, int((resets_at - now).total_seconds() / 60))
            except Exception as e:
                logger.warning(f"{period_key} resets_at 파싱 실패: {e}")

        result[period_key] = {
            "utilization": utilization,
            "resets_at": resets_at_str,
            "remaining_minutes": remaining_minutes
        }

    logger.info("API 호출 성공 - 사용량 데이터 획득")
    return result


# ============================================================
# 스냅샷 소스 (statusline 수집)
# ============================================================

# 파일이 일시적으로 없거나 손상됐을 때 stale 로 되돌려 줄 마지막 성공 파싱 결과.
_last_snapshot_result = {"data": None}


def _epoch_to_iso(epoch):
    """Unix epoch 초 → UTC ISO8601 문자열(+00:00 오프셋). 실패 시 None."""
    try:
        return datetime.fromtimestamp(int(epoch), tz=timezone.utc).isoformat()
    except (TypeError, ValueError, OSError, OverflowError):
        return None


def _snapshot_age(captured_at):
    """captured_at(ISO 문자열) → (updated_at, age_seconds). 파싱 실패 시 (원문, None)."""
    if not isinstance(captured_at, str) or not captured_at:
        return None, None
    try:
        dt = datetime.fromisoformat(captured_at.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        age = int((datetime.now(timezone.utc) - dt).total_seconds())
        return captured_at, max(0, age)
    except Exception:
        return captured_at, None


def _read_snapshot_file():
    """usage-snapshot.json 을 읽어 REST 응답 dict 로 변환한다. 없거나 손상되면 None."""
    if not os.path.exists(SNAPSHOT_FILE):
        logger.debug(f"스냅샷 파일 없음: {SNAPSHOT_FILE}")
        return None
    try:
        with open(SNAPSHOT_FILE, "r", encoding="utf-8") as f:
            snap = json.load(f)
    except Exception as e:
        logger.warning(f"스냅샷 읽기/파싱 실패: {e}")
        return None
    if not isinstance(snap, dict):
        logger.warning("스냅샷이 dict 가 아님 — 무시")
        return None

    sv = snap.get("schema_version")
    if isinstance(sv, int) and sv > SNAPSHOT_SCHEMA_VERSION:
        logger.warning(
            f"스냅샷 schema_version={sv} > 지원 {SNAPSHOT_SCHEMA_VERSION} — 아는 필드만 사용"
        )

    updated_at, age_seconds = _snapshot_age(snap.get("captured_at"))
    stale = (age_seconds is None) or (age_seconds > STALE_THRESHOLD_SECONDS)

    result = {
        "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": snap.get("source") or "statusline",
        "cached": False,
        "updated_at": updated_at,
        "age_seconds": age_seconds,
        "stale": stale,
    }

    rate_limits = snap.get("rate_limits") or {}
    now = datetime.now(timezone.utc)
    for period in SNAPSHOT_PERIODS:
        block = rate_limits.get(period)
        if not isinstance(block, dict):
            continue
        # used_percentage(float) → utilization(float). 반올림하지 않는다
        # (iOS 알림 로직이 10% 구간 경계를 트리거로 쓰므로 정밀도 유지 필수).
        try:
            utilization = float(block.get("used_percentage"))
        except (TypeError, ValueError):
            logger.debug(f"{period} used_percentage 미제공 — 생략")
            continue

        resets_iso = _epoch_to_iso(block.get("resets_at"))
        remaining_minutes = 0
        if resets_iso:
            try:
                resets_dt = datetime.fromisoformat(resets_iso)
                remaining_minutes = max(0, int((resets_dt - now).total_seconds() // 60))
            except Exception as e:
                logger.warning(f"{period} resets_at 계산 실패: {e}")

        result[period] = {
            "utilization": utilization,
            "resets_at": resets_iso,
            "remaining_minutes": remaining_minutes,
        }

    return result


def _scrape_via_snapshot():
    """스냅샷을 읽어 반환한다. 예외를 던지지 않는다 — 실패 시 stale 응답을 준다."""
    result = _read_snapshot_file()
    if result is not None:
        _last_snapshot_result["data"] = result
        if result.get("stale"):
            logger.info(f"스냅샷 stale (age={result.get('age_seconds')}초)")
        return result

    # 파일이 없거나 손상 → 마지막 알려진 값을 stale 로 되돌린다.
    last = _last_snapshot_result["data"]
    if last is not None:
        stale_copy = dict(last)
        _, age = _snapshot_age(stale_copy.get("updated_at"))
        stale_copy["age_seconds"] = age
        stale_copy["stale"] = True
        stale_copy["cached"] = True
        logger.info("스냅샷 부재 — 마지막 알려진 값을 stale 로 반환")
        return stale_copy

    # 아직 스냅샷이 한 번도 없음(콜드스타트). five_hour 없이 stale 응답.
    logger.info("스냅샷 없음(콜드스타트) — Claude Code 를 한 번 사용하면 채워집니다")
    return {
        "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "statusline",
        "cached": False,
        "updated_at": None,
        "age_seconds": None,
        "stale": True,
    }


# ============================================================
# 메인 스크래핑 함수 (데이터 소스 디스패치)
# ============================================================

def scrape_claude_usage(use_cache=True):
    """설정된 데이터 소스로 사용량을 조회한다 (기본 snapshot, 레거시 browser_cookie)."""
    if USAGE_SOURCE == "browser_cookie":
        return _scrape_via_browser_cookie(use_cache=use_cache)
    return _scrape_via_snapshot()


def _scrape_via_browser_cookie(use_cache=True):
    """
    레거시: 브라우저 쿠키 sessionKey 로 claude.ai 내부 API 를 호출한다.
    1. 캐시 확인 → 2. API 직접 호출 → 3. 캐시 저장
    """
    if use_cache:
        cached = get_cached_usage()
        if cached is not None:
            cached["cached"] = True
            logger.info("캐시된 데이터 반환")
            return cached

        # 직전 시도가 실패했다면 쿨다운이 끝날 때까지 브라우저를 다시 건드리지 않는다.
        # 실패 사유는 대개 지속적이라 재시도해도 결과가 같고, 폴링 주기(수 초)마다
        # 쿠키 복호화를 반복하면 로그만 수 MB 씩 불어난다.
        cooled = get_cooldown_failure()
        if cooled is not None:
            logger.debug(f"실패 쿨다운 중 — 재시도 생략 ({FAILURE_COOLDOWN_SECONDS}초)")
            raise Exception(cooled)

    logger.info("API 직접 호출 시도")
    api_result = _fetch_usage_via_api()

    if api_result is not None:
        api_result["cached"] = False
        api_result["source"] = "api"
        if use_cache:
            set_cached_usage(api_result)
        logger.info("API 호출 성공")
        return api_result

    message = (
        "API 호출 실패. 브라우저(Safari/Chrome) 쿠키 또는 token.ini의 org_id를 확인하세요."
    )
    logger.error("API 호출 실패 - 사용량 조회 불가")
    if use_cache:
        set_cooldown_failure(message)
    raise Exception(message)


# ============================================================
# 서버 시작 시 세션 워밍업
# ============================================================

def warmup_session_on_startup():
    """서버 시작 시 캐시 워밍업. 실패해도 서버는 정상 시작."""
    try:
        logger.info("세션 워밍업 시작")
        result = scrape_claude_usage(use_cache=False)
        five = result.get("five_hour") if isinstance(result, dict) else None
        if isinstance(five, dict):
            logger.info(
                f"워밍업 완료 "
                f"(퍼센트: {five.get('utilization')}%, "
                f"리셋: {five.get('remaining_minutes')}분)"
            )
        elif USAGE_SOURCE != "browser_cookie":
            logger.info(
                "워밍업: 아직 스냅샷 데이터 없음 — Claude Code 를 한 번 사용하면 채워집니다"
            )
        else:
            logger.info("워밍업: 아직 사용량 데이터 없음")
    except Exception as e:
        logger.warning(f"세션 워밍업 실패: {e}")
        logger.warning("서버는 정상적으로 시작됩니다. 첫 API 요청 시 자동 재시도됩니다.")


# ============================================================
# REST API 엔드포인트
# ============================================================

@app.route("/api/usage")
def api_usage():
    """/api/usage GET 엔드포인트"""
    logger.info("요청옴(/api/usage)")

    try:
        usage = scrape_claude_usage()

        # 로컬 로그 기반 토큰 통계를 덧붙인다. 순수 부가물이므로 무슨 일이 나든 삼켜서
        # 상류 쿼터 응답은 그대로 내보낸다. dict 는 삽입 순서를 보존하므로 맨 아래에 붙는다.
        try:
            tokens = _tokens_block(request.args)
            if tokens is not None:
                usage["tokens"] = tokens
        except Exception as token_error:
            logger.warning(f"토큰 집계 실패 (쿼터 응답은 정상): {token_error}")

        logger.info("API 응답: 200 OK")
        return jsonify(usage), 200

    except Exception as e:
        error_msg = str(e)
        timestamp = datetime.utcnow().isoformat() + "Z"

        if "token.ini" in error_msg or "session_key" in error_msg or "쿠키" in error_msg:
            logger.warning("API 응답: 401 (인증 실패)")
            return jsonify({
                "error": error_msg,
                "error_type": "AuthenticationFailed",
                "hint": "Safari 또는 Chrome에서 claude.ai에 로그인되어 있는지 확인하세요.",
                "timestamp": timestamp
            }), 401

        elif "타임아웃" in error_msg or "Timeout" in error_msg.lower():
            logger.error("API 응답: 500 (타임아웃)")
            return jsonify({
                "error": error_msg,
                "error_type": "Timeout",
                "hint": "네트워크 상태를 확인하고 다시 시도하세요.",
                "timestamp": timestamp
            }), 500

        else:
            logger.exception("API 응답: 500 (예상치 못한 에러)")
            return jsonify({
                "error": error_msg,
                "error_type": "APICallFailed",
                "hint": "로그 파일(app.log)을 확인하세요.",
                "timestamp": timestamp
            }), 500


# ============================================================
# CLI 엔트리포인트
# ============================================================

if __name__ == '__main__':
    import argparse

    arg_parser = argparse.ArgumentParser(description='Claude.ai 사용량 API 서버')
    arg_parser.add_argument('--server', action='store_true',
                            help='REST API 서버 모드로 실행')
    arg_parser.add_argument('--port', type=int, default=API_PORT,
                            help=f'서버 포트 (기본: {API_PORT})')
    arg_parser.add_argument('--no-cache', action='store_true',
                            help='캐시를 사용하지 않고 실시간 API 호출')

    args = arg_parser.parse_args()

    if args.server:
        def _shutdown_handler(signum, frame):
            sig_name = signal.Signals(signum).name
            logger.info("============================================================")
            logger.info(f"서버 종료 (시그널: {sig_name})")
            logger.info("============================================================")
            sys.exit(0)

        signal.signal(signal.SIGTERM, _shutdown_handler)
        signal.signal(signal.SIGINT, _shutdown_handler)

        logger.info("============================================================")
        logger.info("claude-usage-bridge 기동")
        logger.info(f"데이터 소스: {USAGE_SOURCE}")
        if USAGE_SOURCE == "browser_cookie":
            logger.info("⚠  UNOFFICIAL: 본 서비스는 Anthropic 공식 API가 아닙니다.")
            logger.info("⚠  브라우저(Safari/Chrome)에 로그인된 sessionKey 쿠키를 추출해")
            logger.info("⚠  claude.ai 내부 엔드포인트를 호출하는 리버스엔지니어링 기반 도구입니다.")
            logger.info("⚠  개인 사용 목적으로만 이용하세요.")
        else:
            logger.info(f"스냅샷 파일: {SNAPSHOT_FILE}")
            logger.info(f"stale 임계값: {STALE_THRESHOLD_SECONDS}초")
        logger.info(f"REST API 서버 시작: http://{BRIDGE_HOST}:{args.port}/api/usage")
        logger.info(f"캐시 TTL: {CACHE_TTL_SECONDS}초")
        logger.info(f"로그 레벨: {LOG_LEVEL}")
        _warn_if_exposed()
        logger.info("============================================================")

        # Warmup off the main thread so Flask starts listening immediately,
        # even if cookie extraction blocks (Keychain prompts, etc.).
        threading.Thread(target=warmup_session_on_startup, daemon=True).start()
        threading.Thread(target=warmup_token_stats_on_startup, daemon=True).start()

        app.run(host=BRIDGE_HOST, port=args.port, debug=False)
        sys.exit(0)

    try:
        use_cache = not args.no_cache
        if not use_cache:
            logger.info("캐시 비활성화 (--no-cache)")

        usage_data = scrape_claude_usage(use_cache=use_cache)
        print(json.dumps(usage_data, indent=2))
        sys.exit(0)
    except Exception as e:
        logger.error(f"CLI 실행 에러: {e}")
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
