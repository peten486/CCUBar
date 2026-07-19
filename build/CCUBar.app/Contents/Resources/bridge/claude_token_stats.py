"""
claude_token_stats — 로컬 Claude Code 세션 로그에서 토큰 사용량을 집계한다.

`~/.claude/projects/**/*.jsonl` 의 assistant 줄에 담긴 `message.usage` 를 읽어
총량 / 오늘 누적 / 모델별 / 시간대별 / 프로젝트별로 집계한다.

이 모듈이 재는 것과 claude_usage_scraper 가 재는 것은 다른 값이다:
  - 스크레이퍼: claude.ai 서버가 계산한 계정 전체(웹·데스크톱·전 기기) 쿼터 소진률(%)
  - 이 모듈:    이 맥의 Claude Code 로그에서 관측된 절대 토큰 수
둘은 일치하지 않으며 변환 계수도 없다. 한쪽에서 다른 쪽을 추정하지 말 것.

Flask 의존성 없음 (순수 모듈).
"""

import json
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # Python 3.8
    ZoneInfo = None


# ============================================================
# 설정 상수
# ============================================================

DEFAULT_PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
DEFAULT_RETENTION_DAYS = 30

# 15분 버킷. 저장은 UTC로 하고 로컬 변환은 조회 시점에 한다 — 적재 시점에 로컬 시각을
# 구우면 DST 전환이나 여행 후 집계가 조용히 틀어진다. 실존하는 모든 UTC 오프셋이
# 15분의 배수이므로 15분 버킷은 어떤 타임존으로도 무손실 변환된다.
BUCKET_SECONDS = 900

# 토큰 수 필드. 나머지 usage 키(service_tier, inference_geo, speed, ...)는 무시한다.
TOKEN_FIELDS = (
    "input_tokens",
    "output_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
)

# API 에러 자리를 채우는 합성 레코드. 전 항목이 0이라 모델 분해에서 제외한다.
SYNTHETIC_MODEL = "<synthetic>"

_UTC = timezone.utc


# ============================================================
# 카운터
# ============================================================

def _new_counters():
    return {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "requests": 0,
    }


def _add_counters(dst, src):
    for k in dst:
        dst[k] += src[k]


def _finalize(c):
    """집계 카운터에 파생 필드를 붙여 응답용 dict로 만든다."""
    inp = c["input_tokens"]
    out = c["output_tokens"]
    cc = c["cache_creation_input_tokens"]
    cr = c["cache_read_input_tokens"]
    return {
        "input_tokens": inp,
        "output_tokens": out,
        "cache_creation_input_tokens": cc,
        "cache_read_input_tokens": cr,
        "total_tokens": inp + out + cc + cr,
        # cache_read 는 다른 값들을 압도하므로(실측 14.8M vs 176K) total_tokens 만
        # 노출하면 무의미하게 큰 숫자가 "사용량"으로 읽힌다. 둘 다 준다.
        "billable_tokens": inp + out + cc,
        "requests": c["requests"],
    }


def _parse_timestamp(raw):
    """ISO-8601 UTC 문자열 → tz-aware UTC datetime. 실패 시 None."""
    if not isinstance(raw, str) or not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=_UTC)
    except ValueError:
        pass
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt.astimezone(_UTC) if dt.tzinfo else dt.replace(tzinfo=_UTC)


def _resolve_tz(name):
    """IANA 이름 → tzinfo. 이름이 없거나 알 수 없으면 시스템 로컬 타임존."""
    if name and ZoneInfo is not None:
        try:
            return ZoneInfo(name)
        except Exception:
            pass
    return datetime.now().astimezone().tzinfo


class FileState:
    """증분 읽기를 위한 파일별 상태."""

    __slots__ = ("inode", "size", "mtime", "offset")

    def __init__(self):
        self.inode = None
        self.size = 0
        self.mtime = 0.0
        self.offset = 0


# ============================================================
# 집계기
# ============================================================

class TokenAggregator:
    """
    JSONL 로그를 증분으로 읽어 인메모리 집계를 유지한다.

    영속화하지 않는다. 전체 재파싱은 실측 1.4초(644MB/208파일)라 프로세스 시작 시
    한 번 재구축하는 편이 SQLite나 상태 파일이 끌고 오는 스키마·손상 복구·offset
    불일치 버그보다 싸다. 재구축이 10초를 넘기면(로그 약 5GB) 그때 영속화를 재검토할 것.
    """

    def __init__(self, projects_dir=None, retention_days=None):
        self.projects_dir = projects_dir or os.getenv(
            "CLAUDE_PROJECTS_DIR", DEFAULT_PROJECTS_DIR
        )
        self.retention_days = (
            retention_days
            if retention_days is not None
            else int(os.getenv("TOKENS_RETENTION_DAYS", str(DEFAULT_RETENTION_DAYS)))
        )

        self._lock = threading.RLock()
        self._ready = threading.Event()

        self._files = {}      # abs path -> FileState
        self._buckets = {}    # (bucket, model, project) -> counters
        # requestId -> bucket. set 이 아니라 dict 인 이유: 보관기간이 지난 버킷을
        # 지울 때 해당 requestId 도 같이 지워야 하는데, 값이 있어야 2차 순회가 없다.
        self._seen = {}
        self._projects = {}   # project name -> cwd

        self._last_scan_at = 0.0
        self._last_scan_ms = 0
        self._stats = {
            "files_tracked": 0,
            "files_skipped": 0,
            "lines_parsed": 0,
            "malformed_lines": 0,
            "duplicates_skipped": 0,
        }
        self._warnings = []

    # -- 조회 -------------------------------------------------

    @property
    def ready(self):
        return self._ready.is_set()

    @property
    def stats(self):
        with self._lock:
            out = dict(self._stats)
            out["scan_ms"] = self._last_scan_ms
            return out

    def _warn(self, message):
        if message not in self._warnings:
            self._warnings.append(message)

    # -- 스캔 -------------------------------------------------

    def maybe_scan(self, min_interval):
        """마지막 스캔이 min_interval 보다 오래됐을 때만 스캔한다."""
        if time.time() - self._last_scan_at >= min_interval:
            self.scan()

    def scan(self):
        """로그 트리를 훑어 새로 추가된 바이트만 집계에 반영한다."""
        started = time.time()
        with self._lock:
            self._warnings = []
            self._stats["files_skipped"] = 0

            root = Path(self.projects_dir)
            if not root.is_dir():
                self._warn("claude projects directory not found: %s" % self.projects_dir)
                self._stats["files_tracked"] = 0
                self._last_scan_at = time.time()
                self._last_scan_ms = int((time.time() - started) * 1000)
                self._ready.set()
                return

            cutoff_ts = time.time() - self.retention_days * 86400
            seen_paths = set()

            # rglob 이어야 한다. 로그의 대다수는 <proj>/*.jsonl 이 아니라
            # <proj>/<sessionId>/subagents/*.jsonl 에 있다 (실측 208개 중 143개).
            # 서브에이전트 파일의 requestId 집합은 상위 파일과 서로소이므로
            # 중복이 아니라 실제 추가 트래픽이다.
            try:
                paths = sorted(root.rglob("*.jsonl"))
            except OSError as exc:
                self._warn("failed to walk %s: %s" % (self.projects_dir, exc))
                paths = []

            for path in paths:
                key = str(path)
                seen_paths.add(key)
                try:
                    st = path.stat()
                except OSError as exc:
                    self._stats["files_skipped"] += 1
                    self._warn("stat failed: %s" % exc)
                    continue

                # 보관기간이 지난 파일은 열지도 않는다 — 시작 스캔 비용의 주 절감원.
                if st.st_mtime < cutoff_ts:
                    self._stats["files_skipped"] += 1
                    continue

                self._ingest_file(path, st)

            # 사라진 파일의 상태는 버린다 (집계는 보관기간 정리에 맡긴다).
            for stale in [p for p in self._files if p not in seen_paths]:
                del self._files[stale]

            self._stats["files_tracked"] = len(self._files)
            self._prune()

            self._last_scan_at = time.time()
            self._last_scan_ms = int((self._last_scan_at - started) * 1000)
            self._ready.set()

            if self._stats["malformed_lines"]:
                # 줄 단위로 로깅하지 않는다 — 손상 파일 하나가 app.log 를 폭주시킨다.
                self._warn(
                    "%d malformed line(s) skipped" % self._stats["malformed_lines"]
                )

    def _ingest_file(self, path, st):
        key = str(path)
        state = self._files.get(key)
        if state is None:
            state = FileState()
            self._files[key] = state

        # mtime/size 는 skip 판단에만 쓴다. 정확성 입력으로는 쓰지 않는다.
        if (
            state.inode == st.st_ino
            and state.size == st.st_size
            and state.mtime == st.st_mtime
        ):
            return

        # inode 가 바뀌었거나 파일이 줄었으면 offset 을 못 믿는다 → 통째로 다시 읽는다.
        #
        # 그래도 안전한 이유이자 이 설계의 핵심 불변식: dedup 맵이 재적재를 멱등으로
        # 만든다. 파일 안의 모든 requestId 가 이미 _seen 에 있으므로 재읽기는 중복
        # 계산될 수 없다. 덕분에 offset 로직은 단순해도 되고, 복구 경로는 "그냥 다시
        # 읽는다" 하나로 끝난다.
        if state.inode != st.st_ino or st.st_size < state.offset:
            state.offset = 0

        offset = state.offset
        try:
            with open(key, "r", encoding="utf-8", errors="replace") as fh:
                fh.seek(offset)
                for line in fh:
                    encoded = len(line.encode("utf-8", errors="replace"))
                    # 완결되지 않은 마지막 줄(append 진행 중)은 집계하지 않고
                    # offset 도 전진시키지 않는다 → 다음 스캔에서 온전히 다시 읽힌다.
                    if not line.endswith("\n"):
                        break
                    offset += encoded
                    self._ingest_line(line)
        except OSError as exc:
            self._stats["files_skipped"] += 1
            self._warn("read failed: %s" % exc)
            return

        state.offset = offset
        state.inode = st.st_ino
        state.size = st.st_size
        state.mtime = st.st_mtime

    def _ingest_line(self, line):
        # assistant 줄만 usage 를 갖는다. json.loads 전에 문자열로 걸러 40% 절약.
        if '"assistant"' not in line:
            return

        self._stats["lines_parsed"] += 1
        try:
            record = json.loads(line)
        except ValueError:
            self._stats["malformed_lines"] += 1
            return
        if not isinstance(record, dict) or record.get("type") != "assistant":
            return

        message = record.get("message")
        if not isinstance(message, dict):
            return
        usage = message.get("usage")
        if not isinstance(usage, dict):
            return

        # 하나의 API 응답이 content block 별(thinking / tool_use / text)로 여러 줄에
        # 기록되며 동일한 usage 객체를 그대로 반복한다 — 실측 고유 requestId 12,253개 중
        # 8,596개가 복수 라인. dedup 없이 합산하면 총량이 약 2배 부풀려진다.
        # requestId 가 없는 줄(전부 <synthetic>)은 줄마다 고유한 uuid 로 폴백한다.
        dedup_key = record.get("requestId") or record.get("uuid")
        if not dedup_key:
            self._stats["malformed_lines"] += 1
            return
        if dedup_key in self._seen:
            self._stats["duplicates_skipped"] += 1
            return

        ts = _parse_timestamp(record.get("timestamp"))
        if ts is None:
            # "지금"으로 폴백하지 않는다 — 시간대 버킷이 오염된다.
            self._stats["malformed_lines"] += 1
            return

        model = message.get("model") or "unknown"
        if model == SYNTHETIC_MODEL:
            self._seen[dedup_key] = 0
            return

        cwd = record.get("cwd") or ""
        project = os.path.basename(cwd.rstrip("/")) if cwd else "unknown"
        if cwd:
            self._projects.setdefault(project, cwd)

        bucket = int(ts.timestamp()) // BUCKET_SECONDS
        counters = self._buckets.get((bucket, model, project))
        if counters is None:
            counters = _new_counters()
            self._buckets[(bucket, model, project)] = counters

        # usage.iterations[] 는 같은 숫자를 되풀이한다 — 읽지 않는다.
        for field in TOKEN_FIELDS:
            try:
                counters[field] += int(usage.get(field) or 0)
            except (TypeError, ValueError):
                pass
        counters["requests"] += 1
        self._seen[dedup_key] = bucket

    def _prune(self):
        """보관기간이 지난 버킷과 그 requestId 를 함께 버린다."""
        cutoff = int(
            (datetime.now(_UTC) - timedelta(days=self.retention_days)).timestamp()
        ) // BUCKET_SECONDS
        for key in [k for k in self._buckets if k[0] < cutoff]:
            del self._buckets[key]
        for key in [k for k, v in self._seen.items() if 0 < v < cutoff]:
            del self._seen[key]

    # -- 스냅샷 -----------------------------------------------

    def snapshot(self, range_key="today", since=None, until=None, tz_name=None,
                 full=False):
        """
        집계 결과를 응답용 dict 로 반환한다.

        full=False 이면 totals / today / by_model 만 담는다. dense 한 by_hour(최대 720개)와
        by_project 를 60초 폴링 응답에 매번 실으면 팝오버의 "원문 보기"가 못 쓰게 된다.
        """
        tzinfo = _resolve_tz(tz_name)
        now_local = datetime.now(tzinfo)
        since_dt, until_dt, resolved_key = self._resolve_range(
            range_key, since, until, now_local, tzinfo
        )

        # 오늘 경계는 요청마다 계산한다 → 장수명 프로세스도 자정에 정상 롤오버.
        today_start = now_local.replace(hour=0, minute=0, second=0, microsecond=0)
        today_end = today_start + timedelta(days=1)

        totals = _new_counters()
        today = _new_counters()
        by_model = {}
        by_project = {}
        by_hour = {}

        with self._lock:
            for (bucket, model, project), counters in self._buckets.items():
                bucket_dt = datetime.fromtimestamp(bucket * BUCKET_SECONDS, _UTC)

                if today_start <= bucket_dt < today_end:
                    _add_counters(today, counters)

                if not (since_dt <= bucket_dt < until_dt):
                    continue

                _add_counters(totals, counters)

                slot = by_model.get(model)
                if slot is None:
                    slot = by_model[model] = _new_counters()
                _add_counters(slot, counters)

                if full:
                    slot = by_project.get(project)
                    if slot is None:
                        slot = by_project[project] = _new_counters()
                    _add_counters(slot, counters)

                    hour = (bucket * BUCKET_SECONDS) // 3600 * 3600
                    slot = by_hour.get(hour)
                    if slot is None:
                        slot = by_hour[hour] = _new_counters()
                    _add_counters(slot, counters)

            stats = dict(self._stats)
            stats["scan_ms"] = self._last_scan_ms
            warnings = list(self._warnings)
            scanned_at = self._last_scan_at
            projects = dict(self._projects)

        offset = tzinfo.utcoffset(now_local) or timedelta(0)
        result = {
            "schema_version": 1,
            "source": "local_logs",
            # 같은 응답의 최상위 쿼터 퍼센트와 혼동하지 않도록 범위를 명시한다.
            "scope": "claude_code_this_machine",
            "ready": self.ready,
            "scanned_at": (
                datetime.fromtimestamp(scanned_at, _UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
                if scanned_at
                else None
            ),
            "timezone": str(getattr(tzinfo, "key", tzinfo)),
            "utc_offset_minutes": int(offset.total_seconds() // 60),
            "range": {
                "key": resolved_key,
                "since": since_dt.astimezone(tzinfo).isoformat(),
                "until": until_dt.astimezone(tzinfo).isoformat(),
            },
            "totals": _finalize(totals),
            "today": _finalize(today),
            "by_model": sorted(
                (dict(model=m, **_finalize(c)) for m, c in by_model.items()),
                key=lambda r: r["billable_tokens"],
                reverse=True,
            ),
        }

        if full:
            result["by_hour"] = self._dense_hours(by_hour, since_dt, until_dt, tzinfo)
            result["by_project"] = sorted(
                (
                    dict(project=p, cwd=projects.get(p, ""), **_finalize(c))
                    for p, c in by_project.items()
                ),
                key=lambda r: r["billable_tokens"],
                reverse=True,
            )

        result["stats"] = stats
        result["warnings"] = warnings
        return result

    def _resolve_range(self, range_key, since, until, now_local, tzinfo):
        """(since, until, key) 를 tz-aware 로 확정한다."""
        since_dt = _parse_timestamp(since) if isinstance(since, str) else since
        until_dt = _parse_timestamp(until) if isinstance(until, str) else until
        if since_dt or until_dt:
            end = until_dt or now_local
            start = since_dt or (end - timedelta(days=1))
            return start, end, "custom"

        midnight = now_local.replace(hour=0, minute=0, second=0, microsecond=0)
        if range_key == "7d":
            return midnight - timedelta(days=6), midnight + timedelta(days=1), "7d"
        if range_key == "30d":
            return midnight - timedelta(days=29), midnight + timedelta(days=1), "30d"
        return midnight, midnight + timedelta(days=1), "today"

    @staticmethod
    def _dense_hours(by_hour, since_dt, until_dt, tzinfo):
        """
        범위 안의 모든 시각을 0으로 채워 내보낸다 — 클라이언트가 gap-fill 하지 않게.

        UTC 초 단위로 전진시키고 라벨만 로컬로 변환하므로 DST 전환에도 안전하다.
        """
        start = int(since_dt.timestamp()) // 3600 * 3600
        end = int(until_dt.timestamp())
        rows = []
        for hour in range(start, end, 3600):
            local = datetime.fromtimestamp(hour, _UTC).astimezone(tzinfo)
            counters = by_hour.get(hour) or _new_counters()
            rows.append(
                dict(
                    hour=local.isoformat(),
                    # 비정규화해 둬서 "시간대별 패턴" 집계에 날짜 파싱이 필요 없다.
                    hour_of_day=local.hour,
                    **_finalize(counters),
                )
            )
        return rows
