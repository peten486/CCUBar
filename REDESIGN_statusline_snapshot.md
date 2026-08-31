# Claude Usage Monitor 재설계 (데이터 소스 교체: 브라우저 쿠키 → statusline 스냅샷)

> **상태:** 검증 완료(GO). 아래 "0. 검증 결과"의 확정 사실을 계약으로 삼아 구현 가능.
> 이전 초안의 4개 GAP을 반영해 개정한 버전이다. 변경점은 각 절의 **[개정]** 표기 참고.

---

## 배경

현재 구조는 브라우저(Safari/Chrome)의 `claude.ai` 세션 쿠키(`sessionKey`)를 추출해
비공개 엔드포인트 `/api/organizations/{org_id}/usage`를 호출한다.

문제점:

1. **세션 무효화 위험** — 세션 쿠키로 자동화된 반복 호출을 하는 패턴이 이상 접근으로
   판단될 수 있고, 그 결과 브라우저와 Claude Code 로그인이 함께 끊길 수 있다.
   (실제로 주기적 로그아웃 증상이 관측되고 있으며, 이 구조가 유력한 원인 후보)
2. **크로스 플랫폼 취약** — Windows는 DPAPI + Chrome App-Bound Encryption 때문에
   쿠키 복호화가 자주 깨진다. Safari 경로는 Windows에 없다.
3. **SSH 환경에서 실패** — 키체인 접근에 GUI 세션이 필요해, SSH 전용 세션에서는
   복호화 키를 얻지 못한다.
4. **브라우저 로그인 상태에 종속** — 브라우저에서 로그아웃하면 조회가 실패한다.

## 목표 **[개정]**

- REST 응답 스키마를 **가능한 한** 유지한다. 단 `seven_day_sonnet`은 새 데이터 소스에서
  제공되지 않으므로 **의도적으로 생략한다**(아래 0.3, GAP 2 참조). 나머지 필드
  (`five_hour`, `seven_day`, `timestamp` 등)와 안드로이드/애플워치 위젯의 파싱 계약은
  변경하지 않는다.
- 인증이 필요 없는 로컬 데이터 소스로 교체한다.
- 레거시(쿠키) 경로를 플래그로 남겨, 로그아웃 원인 가설을 검증할 수 있게 한다.

## 비목표

- 위젯 UI 재작성
- 계정 전체 이력 분석 기능 추가
- Claude Code가 꺼져 있을 때의 실시간 조회 (구조상 불가능, 아래 한계 참조)
- `seven_day_sonnet`(Sonnet 7일 창) 지표 유지 — statusline이 제공하지 않으므로 포기

---

## 0. 검증 결과 (확정된 사실) **[신설]**

초안의 Phase 0("사전 조사")는 완료되었다. 아래는 추측이 아니라 **3중 교차 확인**된 사실이다:
(a) 현役 `~/.claude/statusline.sh`가 실제로 파싱 중인 키, (b) `claude-dashboard` 플러그인
파서, (c) 공식 문서(`https://code.claude.com/docs/en/statusline.md` 및 Claude Code 변경 로그).

### 0.1 stdin JSON의 rate limit 구조 (확정)

Claude Code가 statusline 스크립트에 stdin으로 넘기는 JSON에는 다음이 포함된다:

```json
{
  "rate_limits": {
    "five_hour":  { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day":  { "used_percentage": 41.2, "resets_at": 1738857600 },
    "spend_limit":{ "used_percentage": 62.8, "resets_at": 1740787200 }
  }
}
```

| 필드 | 타입 | 비고 |
| --- | --- | --- |
| `rate_limits.five_hour.used_percentage` | float 0–100 | 5시간 창 소진율 |
| `rate_limits.five_hour.resets_at` | **int (Unix epoch 초)** | ⚠ ISO 문자열 아님 → 변환 필요 (GAP 1) |
| `rate_limits.seven_day.used_percentage` | float 0–100 | 7일 창 소진율 |
| `rate_limits.seven_day.resets_at` | **int (Unix epoch 초)** | 위와 동일 |
| `rate_limits.spend_limit.*` | — | 게이트웨이 지출 한도. 본 프로젝트에서는 미사용 |

기타 활용 가능한 필드: `model.display_name`, `model.id`, `workspace.current_dir`,
`cost.total_cost_usd`, `cost.total_duration_ms`, `context_window.used_percentage`,
`version`, `session_id`.

### 0.2 가용성 제약 (확정 — GAP 3의 근거)

공식 문서 명시 사항:

- `rate_limits`는 **Claude.ai Pro/Max 구독자**(또는 지출 한도가 걸린 게이트웨이)에서만 나타난다.
- **세션의 첫 API 응답 이후에만** 채워진다. 세션 시작 직후 첫 렌더에는 없을 수 있다.
- `five_hour` / `seven_day` / `spend_limit` 각 창은 **독립적으로 부재**할 수 있다.

→ 수집기는 필드 부재를 **정상 상황**으로 다뤄야 하며, 부재 시 0%로 덮어쓰지 않는다(0.4).

### 0.3 `seven_day_sonnet` 부재 (확정 — GAP 2의 근거)

statusline의 `rate_limits`에는 `five_hour`, `seven_day`, `spend_limit`만 있다.
**`seven_day_sonnet`은 존재하지 않는다.** 현 REST 스키마(`USAGE_PERIODS =
["five_hour", "seven_day", "seven_day_sonnet"]`)와 달리, 새 소스로 전환하면 이 지표는
영구적으로 제공 불가다.

- **영향:** 안드로이드/애플워치/iOS 소비자는 이미 `seven_day_sonnet`이 `null`이거나
  통째로 생략될 때 **게이지를 숨기도록** 구현돼 있다(기존 계정 플랜에 따라 원래도 null이
  내려오던 필드). 따라서 소비자 코드 변경 없이 안전하게 게이지가 사라진다.
- **결정:** 이 생략을 **명시적·문서화된 선택**으로 확정한다. 초안 스냅샷 JSON이 이미
  이 필드를 빼고 있었으나 근거가 없었으므로, 여기서 사유를 명문화한다.

### 0.4 형식 변환 계약 (GAP 1 · GAP 4)

새 소스(statusline)와 기존 REST 스키마 사이의 **필드 매핑**을 아래로 고정한다.
수집기 또는 서버는 이 변환을 반드시 수행한다.

| statusline (입력) | REST 응답 (출력) | 변환 규칙 |
| --- | --- | --- |
| `five_hour.used_percentage` (float) | `five_hour.utilization` (float) | **이름만 변경, float 유지**(반올림 금지) |
| `five_hour.resets_at` (epoch int) | `five_hour.resets_at` (ISO8601 문자열) | `epoch → UTC ISO8601`. 예: `1738425600` → `"2026-02-01T16:00:00+00:00"` |
| (계산) | `five_hour.remaining_minutes` (int) | `max(0, (resets_at - now) // 60)` |
| `seven_day.*` | `seven_day.*` | 위와 동일 |

**주의 (GAP 4):** `used_percentage`를 int로 반올림하지 말 것. iOS 알림 로직이 10% 구간
경계 통과와 `resets_at` 문자열 변경을 트리거 키로 쓰므로, 정밀도 손실 시 알림이 어긋난다.
소비자는 `resets_at`을 `Z` / `+00:00` 오프셋과 소수점 유무 모두 파싱하므로, 출력 문자열은
그중 하나의 유효한 형식이면 된다(권장: `+00:00` 오프셋, 초 단위까지).

---

## 새 데이터 소스

Claude Code는 status line 스크립트를 실행할 때 stdin으로 세션 JSON을 넘겨준다(위 0.1).
여기에 5시간/7일 rate limit 소진율이 포함되며, 이 값은 내장 `/status` 표시와 동일한
**계정 단위** 수치다. 인증도 네트워크 호출도 필요 없다.

기존 `~/.claude/statusline.sh`(claude-status-bar)가 이미 이 값을 파싱해 표시하고 있다.

---

## 컴포넌트 설계

```
Claude Code (Mac mini)
  └─ stdin JSON ─▶ statusline-custom.sh (래퍼)
                     ├─▶ statusline.sh (원본, 화면 출력 그대로)
                     └─▶ usage-snapshot.json (원자적 쓰기)
                                │
                                ▼
                       REST 서버 (Mac mini)  ← epoch→ISO 변환, remaining_minutes 계산
                                │
                                ▼
                      안드로이드 위젯 (폴링)
```

### 1. 수집기 — `~/.claude/statusline-custom.sh` **[개정]**

원본을 수정하지 않고 감싼다. claude-status-bar를 `install.sh`로 업데이트해도
살아남아야 하기 때문이다. `settings.json`의 `statusLine.command`만 래퍼를 가리키게 바꾼다.

요구사항:

- stdin은 한 번만 읽을 수 있으므로 변수에 담아 원본과 스냅샷 양쪽에 사용.
- **원본 출력을 그대로 통과시킬 것** (화면 표시가 깨지면 안 됨).
- 스냅샷 쓰기 실패가 status line 렌더링을 막지 않을 것 (모든 오류 무시하고 exit 0).
- **성능 예산: 래퍼 추가분 50ms 이내.** status line은 매우 자주 렌더링된다.
  네트워크 호출, `security` 호출, 무거운 프로세스 기동 금지.
- **[개정] 단일 패스 추출.** 필드별로 `jq`/`python3`를 반복 호출하지 말 것.
  `jq` 한 번(또는 python 한 번)으로 필요한 모든 필드를 뽑아 스냅샷 JSON을 통째로 만든다.
  (원본 statusline.sh는 필드마다 파서를 호출하는데, `jq` 부재 시 파서를 8회 이상 spawn해
  50ms를 초과할 수 있다. 래퍼는 이 실수를 반복하지 않는다.)
- 원자적 쓰기: 임시 파일에 쓴 뒤 `mv`로 교체 (서버가 반쯤 쓰인 파일을 읽지 않도록).
- `jq` 없으면 `python3` 폴백 (원본 스크립트와 동일한 전략).
- **[개정] 부재 필드 보존 규칙 (GAP 3).** `rate_limits`(또는 특정 창)가 stdin에 없으면
  **스냅샷을 갱신하지 않는다**(기존 파일 유지). 절대 `used_pct: 0`으로 덮어쓰지 않는다.
  세션 첫 API 응답 전이나 Pro/Max가 아닌 경우 필드가 통째로 비므로, 0으로 쓰면 마지막
  정상 스냅샷이 파괴된다.

에러/부재 시 흐름:

```
rate_limits.five_hour.used_percentage 존재?
  ├─ 예 → 임시파일에 스냅샷 작성 → mv 로 교체
  └─ 아니오 → 아무것도 하지 않음(기존 스냅샷 보존), 원본 출력만 통과, exit 0
```

### 2. 스냅샷 파일 **[개정]**

경로: `~/.claude/usage-snapshot.json` (권한 600)

```json
{
  "schema_version": 1,
  "captured_at": "2026-08-31T14:39:00+09:00",
  "source": "statusline",
  "rate_limits": {
    "five_hour": { "used_percentage": 45.0, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 12.0, "resets_at": 1738857600 }
  },
  "session": {
    "model": "Fable 5",
    "cost_usd": 1.23,
    "context_pct": 4
  }
}
```

**[개정] 설계 결정:**

- 스냅샷은 statusline의 **원시 형태를 그대로 보존**한다. 즉 `used_percentage`는 float,
  `resets_at`은 **epoch 정수** 그대로 둔다. epoch→ISO 변환과 `remaining_minutes` 계산은
  **서버(§3)에서** 수행한다. 이렇게 하면 변환 로직이 셸 스크립트(수집기)가 아니라 파이썬
  (서버) 한 곳에 모여, 타임존·소수점 처리 버그를 한 군데서만 관리한다.
- `seven_day_sonnet`은 넣지 않는다(0.3).
- `spend_limit`은 넣지 않는다(본 프로젝트 무관).

`schema_version`을 두는 이유: Claude Code의 stdin JSON 구조는 문서화된 계약이지만
버전업으로 바뀔 수 있다. 서버는 모르는 버전을 만나면 에러 대신 경고 로그를 남기고
가능한 필드만 사용한다.

### 3. 서버 — 데이터 소스 추상화 **[개정]**

기존 `_fetch_usage_via_api()` 직접 호출을 걷어내고 인터페이스를 하나 둔다.

```
UsageSource (인터페이스)
  ├─ SnapshotSource      # 신규, 기본값. usage-snapshot.json 읽기 + epoch→ISO 변환
  └─ BrowserCookieSource # 기존 로직 이관, 플래그로만 활성
```

- 설정 키: `usage_source = snapshot | browser_cookie` (기본 `snapshot`).
  환경변수 `CCUBAR_USAGE_SOURCE`로도 오버라이드 가능하게 한다(기존 `CCUBAR_*` 관례와 일치).
- 기존 쿠키 로직은 **삭제하지 말고** `BrowserCookieSource`로 옮긴다.
  로그아웃 원인 가설 검증을 위해 켜고 끌 수 있어야 한다.
- 라우트 경로(`/api/usage`)와 응답 필드는 **§0.3의 예외(seven_day_sonnet 생략)를 제외하고**
  기존 그대로 유지. 아래 필드만 **추가**한다.

```json
{
  "five_hour":  { "utilization": 45.0, "resets_at": "2026-02-01T16:00:00+00:00", "remaining_minutes": 132 },
  "seven_day":  { "utilization": 12.0, "resets_at": "2026-02-06T16:00:00+00:00", "remaining_minutes": 8820 },
  "timestamp": "2026-08-31T14:39:00Z",
  "cached": false,
  "source": "statusline",
  "updated_at": "2026-08-31T14:39:00+09:00",
  "age_seconds": 132,
  "stale": false
}
```

**[개정] `SnapshotSource` 동작 규칙:**

- 스냅샷을 읽어 `used_percentage → utilization`(float 유지), `resets_at(epoch) → ISO8601`,
  `remaining_minutes = max(0, (resets_at - now)//60)`로 변환한다(§0.4).
- `seven_day_sonnet` 키는 **응답에 넣지 않는다.** 소비자는 부재 시 게이지를 숨긴다.
- 스냅샷이 없거나 파싱 실패 → HTTP 200 + `"stale": true` + 마지막 알려진 값(있으면).
  위젯이 에러 화면으로 깜빡이는 것보다 "N분 전 기준"이 낫다.
- 스냅샷의 특정 창(예: `seven_day`)만 비어 있으면 그 키만 생략하고 나머지는 정상 응답.
- `age_seconds`는 `now - captured_at`. 임계값(기본 1800초, 설정 가능) 초과 시 `stale: true`.
- `schema_version`이 서버가 아는 버전보다 크면 경고 로그 후 아는 필드만 사용(에러 아님).
- 기존 메모리 캐시(TTL 5분)는 **불필요해지므로 제거.** 파일 읽기는 충분히 싸다.
  (`BrowserCookieSource`를 켤 때만 기존 캐시/쿨다운 로직을 함께 활성화한다.)

### 4. 위젯 (최소 변경)

- `updated_at` 기준 상대 시각 표시 ("3분 전").
- `stale: true`면 숫자를 흐리게 처리.
- **[개정]** `seven_day_sonnet` 게이지는 응답에 필드가 없으면 자동으로 숨겨지므로
  위젯 로직 변경 불필요(기존 null 처리 재사용). 레이아웃/폴링 로직도 변경 없음.
- 폴링 주기는 5~15분으로 완화 권장 (파일 읽기라 서버 부하는 무시할 수준이지만,
  배터리 관점에서).

---

## 정리 작업 (별도 커밋) **[개정 — 일부 완료]**

우선순위 높음. 현 구조 유지 여부와 무관하게 처리할 것.

1. **`.chrome_safe_storage_pass` 제거 — ✅ 완료.** 파이썬 경로에서 사용되지 않는 잔재인데,
   내용물은 claude.ai 쿠키 하나가 아니라 **Chrome 전체의 쿠키·저장된 비밀번호를
   복호화할 수 있는 마스터 키**였다.
   - `run.sh`의 `CHROME_SAFE_STORAGE_PASS` export 및 파일 생성 로직 삭제 — 완료
   - `refresh_keychain.sh` 무력화(파일 쓰기 제거, 키체인 ACL 사전 허용 기능만 유지) — 완료
   - `.gitignore`에서 `.chrome_safe_storage_pass` 항목 제거, 관련 docstring/README 정정 — 완료
   - 디스크에 파일 없음(생성된 적 없음) 확인 — 완료
2. **git 이력 확인 — ✅ 완료.** `.chrome_safe_storage_pass`, `token.ini`, `app.log` 모두
   커밋 이력 0건, 현재 추적 대상 아님. 이력 세탁 불필요.
3. **`.gitignore` 점검 — ✅ 완료.** `token.ini`, `app.log`, `app.log.*` 포함 확인됨.
4. **홈이 외장 SSD에 있는 환경 고려 — ⬜ 미완.** `~/.claude/` 및 프로젝트 디렉터리가
   백업/동기화 대상에서 제외되는지, 그리고 SSD 언마운트/절전 시
   `~/.claude/.credentials.json`·`usage-snapshot.json` 접근 실패 가능성을 확인
   (아래 원인 가설 검증 4와 연동).

---

## 플랫폼 (macOS)

경로는 하드코딩하지 말고 홈 기준 상대 경로로 해석한다(`~/.claude/`,
파이썬이면 `Path.home() / ".claude"`). 현재 지원 대상은 macOS 뿐이다.

**모니터링 전용 기기에는 수집기가 필요 없다.** 수집은 Claude Code를 실제로
돌리는 기기(Mac mini)에서만 하고, 다른 기기는 REST를 읽기만 한다.

---

## statusline 슬롯 소유권 **[신설]**

`settings.json`의 `statusLine.command`는 한 번에 하나만 소유한다. 현재 이 계정에는
여러 statusline 후보(claude-status-bar의 `~/.claude/statusline.sh`,
`claude-statusline-memes`, `claude-dashboard`)가 있고, 세션 시작 시 충돌 경고가 관측됐다.

- 본 래퍼(`statusline-custom.sh`)를 `statusLine.command`로 지정한다.
- 래퍼는 claude-status-bar의 `install.sh` 갱신에는 살아남지만, 다른 플러그인의
  `/setup-statusline`류 명령이 `statusLine.command`를 도로 덮어쓸 수 있다.
- **결정 필요:** 어느 statusline이 슬롯을 소유할지 먼저 정한다. 래퍼가 소유하되 내부에서
  원하는 원본(메뉴바용/메메용 등)을 호출하는 방식으로 통합하는 것을 권장.

---

## 한계 (설계상 수용)

1. **Claude Code 실행 중에만 갱신된다.** 완전히 꺼둔 상태에서는 마지막 스냅샷이
   그대로 유지된다. `stale` 플래그와 `age_seconds`로 이 사실을 위젯에 노출한다.
2. **세션 첫 API 응답 전에는 rate_limits가 비어 있다.** 재부팅/새 세션 직후 한 턴을
   돌리기 전까지 스냅샷이 갱신되지 않는다(0.2). 수집기가 부재를 보존 처리하므로
   마지막 정상 값이 유지된다.
3. **다른 기기에서 쓴 사용량도 값에 반영되지만**, 그 반영은 Mac mini에서
   status line이 한 번이라도 렌더링돼야 스냅샷에 들어온다.
4. **`seven_day_sonnet`(Sonnet 7일 창)은 제공 불가.** statusline이 노출하지 않는다(0.3).
5. 실시간성이 반드시 필요하면 claude.ai 웹 대시보드가 유일한 정답이다.

---

## 검증 계획

### 기능

- 스냅샷 파싱: 정상 / 창 일부 누락 / `rate_limits` 통째 부재 / 손상된 JSON / 파일 없음
- **[개정]** epoch→ISO8601 변환 정확도(타임존, 소수점 없는 정수 입력), `remaining_minutes`
  경계값(리셋 시각 경과 시 0)
- **[개정]** 부재 시 스냅샷 보존(0으로 덮어쓰지 않는지) — 수집기 단위 테스트
- **[개정]** `used_percentage` float 정밀도 보존(int 반올림 안 하는지) — iOS 알림 연동 회귀
- staleness 임계값 경계 동작
- 원본 status line 출력이 래퍼 적용 전후로 동일한지 (문자 단위 비교)
- 래퍼 추가 지연시간 측정 (목표 50ms 이내, 특히 `jq` 부재 폴백 경로)
- **[개정]** `seven_day_sonnet` 키가 응답에서 빠지고 위젯이 게이지를 숨기는지 확인

### 원인 가설 검증

데이터 소스 교체와 별개로 진행할 관찰 항목.

1. `usage_source = snapshot`으로 전환 후 **최소 1주 관찰**
2. 주기적 로그아웃 증상이 사라지는지 기록
3. 사라지면 → 쿠키 기반 폴링이 원인으로 확정, `BrowserCookieSource` 완전 제거
4. 계속되면 → 다른 원인. 아래를 순서대로 점검
   - 외장 SSD 마운트 해제/절전으로 `~/.claude/.credentials.json` 접근 실패 여부
   - SSH 접속 때마다 `/login`을 반복하는 습관 (이전 자격증명이 무효화될 수 있음)
   - 시스템 시계 정확도 (`sudo sntp -sS time.apple.com`)
   - Google 계정 보안 이벤트 이력 (myaccount.google.com/security)

### 롤백

`usage_source = browser_cookie`로 되돌리면 즉시 기존 동작. 위젯은 무변경.
(단 이 경로에서만 `seven_day_sonnet`이 다시 응답에 포함된다.)
