"""claude_token_stats 단위 테스트 (stdlib unittest — 추가 의존성 없음)."""

import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from claude_token_stats import TokenAggregator  # noqa: E402


UTC = timezone.utc


def line(request_id, ts, model="claude-opus-4-8", cwd="/tmp/demo",
         inp=100, out=10, cc=20, cr=1000, uuid="u-1", iterations=False):
    """실제 로그 형태를 흉내낸 assistant 줄 하나."""
    usage = {
        "input_tokens": inp,
        "output_tokens": out,
        "cache_creation_input_tokens": cc,
        "cache_read_input_tokens": cr,
        "service_tier": "standard",
    }
    if iterations:
        # 같은 숫자를 되풀이하는 배열 — 집계에 반영되면 안 된다.
        usage["iterations"] = [dict(usage)]
    return json.dumps({
        "type": "assistant",
        "timestamp": ts,
        "sessionId": "s-1",
        "cwd": cwd,
        "requestId": request_id,
        "uuid": uuid,
        "message": {"model": model, "usage": usage},
    }) + "\n"


class TokenStatsTest(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.addCleanup(self._tmp.cleanup)
        # 보관기간 밖으로 밀려나지 않도록 "지금"을 기준으로 타임스탬프를 만든다.
        self.now = datetime.now(UTC)

    def agg(self, **kw):
        return TokenAggregator(projects_dir=self.root, **kw)

    def write(self, relpath, text, mode="w"):
        path = os.path.join(self.root, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode, encoding="utf-8") as fh:
            fh.write(text)
        return path

    def ts(self, **delta):
        return (self.now - timedelta(**delta)).strftime("%Y-%m-%dT%H:%M:%S.000Z")

    # -- dedup ------------------------------------------------

    def test_same_request_id_counted_once(self):
        """한 응답이 content block 별로 여러 줄에 기록돼도 1회만 집계한다."""
        t = self.ts(minutes=5)
        self.write("proj/s.jsonl",
                   line("req-1", t, uuid="u-a") + line("req-1", t, uuid="u-b"))
        a = self.agg()
        a.scan()
        snap = a.snapshot(range_key="30d")
        self.assertEqual(snap["totals"]["requests"], 1)
        self.assertEqual(snap["totals"]["input_tokens"], 100)
        self.assertEqual(snap["stats"]["duplicates_skipped"], 1)

    def test_iterations_not_double_counted(self):
        self.write("proj/s.jsonl", line("req-1", self.ts(minutes=5), iterations=True))
        a = self.agg()
        a.scan()
        self.assertEqual(a.snapshot(range_key="30d")["totals"]["output_tokens"], 10)

    def test_null_request_id_falls_back_to_uuid(self):
        t = self.ts(minutes=5)
        self.write("proj/s.jsonl",
                   line(None, t, uuid="u-a") + line(None, t, uuid="u-b"))
        a = self.agg()
        a.scan()
        self.assertEqual(a.snapshot(range_key="30d")["totals"]["requests"], 2)

    def test_synthetic_model_excluded(self):
        self.write("proj/s.jsonl",
                   line("req-1", self.ts(minutes=5), model="<synthetic>",
                        inp=0, out=0, cc=0, cr=0))
        a = self.agg()
        a.scan()
        snap = a.snapshot(range_key="30d")
        self.assertEqual(snap["totals"]["requests"], 0)
        self.assertEqual(snap["by_model"], [])

    # -- 증분 읽기 --------------------------------------------

    def test_incremental_matches_full_scan(self):
        """append 후 증분 적재 결과가 처음부터 전체를 읽은 결과와 같아야 한다."""
        self.write("proj/s.jsonl", line("req-1", self.ts(minutes=9)))
        incremental = self.agg()
        incremental.scan()

        self.write("proj/s.jsonl",
                   line("req-2", self.ts(minutes=8)) + line("req-3", self.ts(minutes=7)),
                   mode="a")
        incremental.scan()

        fresh = self.agg()
        fresh.scan()
        self.assertEqual(
            incremental.snapshot(range_key="30d")["totals"],
            fresh.snapshot(range_key="30d")["totals"],
        )
        self.assertEqual(incremental.snapshot(range_key="30d")["totals"]["requests"], 3)

    def test_reingest_from_zero_is_idempotent(self):
        """offset 을 0으로 되돌려 통째로 다시 읽어도 총량은 변하지 않는다 (핵심 불변식)."""
        path = self.write("proj/s.jsonl",
                          line("req-1", self.ts(minutes=9)) + line("req-2", self.ts(minutes=8)))
        a = self.agg()
        a.scan()
        before = a.snapshot(range_key="30d")["totals"]

        for state in a._files.values():
            state.offset = 0
            state.inode = None      # skip 판정을 우회해 강제 재적재
        a.scan()

        self.assertEqual(a.snapshot(range_key="30d")["totals"], before)
        self.assertTrue(os.path.exists(path))

    def test_truncated_tail_counted_once_after_completion(self):
        """append 중인 잘린 마지막 줄은 미집계 → 완결된 뒤 정확히 1회."""
        complete = line("req-1", self.ts(minutes=9))
        partial = line("req-2", self.ts(minutes=8))
        head, tail = partial[:40], partial[40:]

        self.write("proj/s.jsonl", complete + head)
        a = self.agg()
        a.scan()
        self.assertEqual(a.snapshot(range_key="30d")["totals"]["requests"], 1)

        self.write("proj/s.jsonl", tail, mode="a")
        a.scan()
        self.assertEqual(a.snapshot(range_key="30d")["totals"]["requests"], 2)

    def test_nested_subagent_logs_included(self):
        """로그 대다수는 <proj>/<sid>/subagents/ 아래에 있다 — rglob 회귀 테스트."""
        self.write("proj/top.jsonl", line("req-1", self.ts(minutes=9)))
        self.write("proj/sid/subagents/sub.jsonl", line("req-2", self.ts(minutes=8)))
        a = self.agg()
        a.scan()
        snap = a.snapshot(range_key="30d")
        self.assertEqual(snap["totals"]["requests"], 2)
        self.assertEqual(snap["stats"]["files_tracked"], 2)

    def test_files_outside_retention_not_opened(self):
        old = self.write("proj/old.jsonl", line("req-old", self.ts(days=90)))
        stale = (datetime.now(UTC) - timedelta(days=90)).timestamp()
        os.utime(old, (stale, stale))
        self.write("proj/new.jsonl", line("req-new", self.ts(minutes=5)))

        a = self.agg(retention_days=30)
        a.scan()
        snap = a.snapshot(range_key="30d")
        self.assertEqual(snap["totals"]["requests"], 1)
        self.assertEqual(snap["stats"]["files_skipped"], 1)

    # -- 타임존 -----------------------------------------------

    def test_hour_buckets_shift_with_timezone(self):
        """UTC 23:30 은 Asia/Seoul 기준 다음 날 08:30 이다."""
        day = (datetime.now(UTC) - timedelta(days=1)).strftime("%Y-%m-%d")
        self.write("proj/s.jsonl", line("req-1", day + "T23:30:00.000Z"))
        a = self.agg()
        a.scan()

        seoul = a.snapshot(range_key="7d", tz_name="Asia/Seoul", full=True)
        hit = [r for r in seoul["by_hour"] if r["requests"]]
        self.assertEqual(len(hit), 1)
        self.assertEqual(hit[0]["hour_of_day"], 8)
        self.assertEqual(seoul["utc_offset_minutes"], 540)

        utc = a.snapshot(range_key="7d", tz_name="UTC", full=True)
        hit = [r for r in utc["by_hour"] if r["requests"]]
        self.assertEqual(hit[0]["hour_of_day"], 23)

    def test_by_hour_is_dense(self):
        self.write("proj/s.jsonl", line("req-1", self.ts(minutes=5)))
        a = self.agg()
        a.scan()
        rows = a.snapshot(range_key="today", tz_name="UTC", full=True)["by_hour"]
        self.assertEqual(len(rows), 24)
        self.assertEqual([r["hour_of_day"] for r in rows], list(range(24)))

    def test_compact_snapshot_omits_heavy_arrays(self):
        self.write("proj/s.jsonl", line("req-1", self.ts(minutes=5)))
        a = self.agg()
        a.scan()
        snap = a.snapshot(range_key="today")
        self.assertNotIn("by_hour", snap)
        self.assertNotIn("by_project", snap)
        self.assertIn("by_model", snap)

    # -- 파생 값 / 분해 ----------------------------------------

    def test_billable_excludes_cache_reads(self):
        self.write("proj/s.jsonl", line("req-1", self.ts(minutes=5),
                                        inp=100, out=10, cc=20, cr=9999))
        a = self.agg()
        a.scan()
        totals = a.snapshot(range_key="30d")["totals"]
        self.assertEqual(totals["billable_tokens"], 130)
        self.assertEqual(totals["total_tokens"], 10129)

    def test_breakdown_by_model_and_project(self):
        self.write("proj-a/s.jsonl",
                   line("req-1", self.ts(minutes=9), model="claude-opus-4-8",
                        cwd="/tmp/alpha"))
        self.write("proj-b/s.jsonl",
                   line("req-2", self.ts(minutes=8), model="claude-haiku-4-5-20251001",
                        cwd="/tmp/beta"))
        a = self.agg()
        a.scan()
        snap = a.snapshot(range_key="30d", full=True)
        self.assertEqual({r["model"] for r in snap["by_model"]},
                         {"claude-opus-4-8", "claude-haiku-4-5-20251001"})
        self.assertEqual({r["project"] for r in snap["by_project"]}, {"alpha", "beta"})
        self.assertEqual(
            [r["cwd"] for r in snap["by_project"] if r["project"] == "alpha"],
            ["/tmp/alpha"],
        )

    def test_unknown_model_passes_through(self):
        """새 모델 id 때문에 토큰이 사라지면 안 된다 — allowlist 없음."""
        self.write("proj/s.jsonl",
                   line("req-1", self.ts(minutes=5), model="claude-something-9"))
        a = self.agg()
        a.scan()
        self.assertEqual(a.snapshot(range_key="30d")["by_model"][0]["model"],
                         "claude-something-9")

    # -- 실패 모드 --------------------------------------------

    def test_missing_directory_degrades(self):
        a = TokenAggregator(projects_dir=os.path.join(self.root, "nope"))
        a.scan()
        snap = a.snapshot(range_key="30d")
        self.assertEqual(snap["totals"]["requests"], 0)
        self.assertTrue(snap["warnings"])
        self.assertTrue(snap["ready"])

    def test_malformed_lines_skipped(self):
        self.write("proj/s.jsonl",
                   '{"type":"assistant" broken\n'
                   + line("req-1", self.ts(minutes=5))
                   + '{"type":"assistant","message":{}}\n')
        a = self.agg()
        a.scan()
        snap = a.snapshot(range_key="30d")
        self.assertEqual(snap["totals"]["requests"], 1)
        self.assertEqual(snap["stats"]["malformed_lines"], 1)

    def test_bad_timestamp_skipped_not_bucketed_as_now(self):
        self.write("proj/s.jsonl", line("req-1", "not-a-timestamp"))
        a = self.agg()
        a.scan()
        snap = a.snapshot(range_key="30d")
        self.assertEqual(snap["totals"]["requests"], 0)
        self.assertEqual(snap["stats"]["malformed_lines"], 1)

    def test_non_integer_usage_values_treated_as_zero(self):
        self.write("proj/s.jsonl", json.dumps({
            "type": "assistant",
            "timestamp": self.ts(minutes=5),
            "cwd": "/tmp/demo",
            "requestId": "req-1",
            "uuid": "u-1",
            "message": {"model": "claude-opus-4-8",
                        "usage": {"input_tokens": None, "output_tokens": "oops"}},
        }) + "\n")
        a = self.agg()
        a.scan()
        totals = a.snapshot(range_key="30d")["totals"]
        self.assertEqual(totals["requests"], 1)
        self.assertEqual(totals["total_tokens"], 0)

    def test_non_assistant_lines_ignored(self):
        self.write("proj/s.jsonl",
                   json.dumps({"type": "user", "timestamp": self.ts(minutes=5)}) + "\n"
                   + line("req-1", self.ts(minutes=5)))
        a = self.agg()
        a.scan()
        self.assertEqual(a.snapshot(range_key="30d")["totals"]["requests"], 1)


if __name__ == "__main__":
    unittest.main()
