"""OAuth 주간 모델 스코프 + /api/stats 단위 테스트 (stdlib unittest).

네트워크는 절대 부르지 않는다 — _fetch_oauth_usage 를 몽키패치하거나
파싱 함수에 고정 응답을 먹인다.
"""

import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import claude_usage_scraper as scraper  # noqa: E402

UTC = timezone.utc


def _iso_in(seconds):
    return (datetime.now(UTC) + timedelta(seconds=seconds)).isoformat()


def _sample_oauth_response(fable_pct=30, resets_in=180000):
    return {
        "five_hour": {"utilization": 12.0},
        "limits": [
            {"kind": "session", "group": "session", "percent": 12,
             "resets_at": _iso_in(3600), "scope": None},
            {"kind": "weekly_all", "group": "weekly", "percent": 18,
             "resets_at": _iso_in(resets_in), "scope": None},
            {"kind": "weekly_scoped", "group": "weekly", "percent": fable_pct,
             "resets_at": _iso_in(resets_in),
             "scope": {"model": {"id": None, "display_name": "Fable"}, "surface": None}},
        ],
    }


class OauthTokenTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        self.tmp.close()
        self._orig_file = scraper.OAUTH_CREDENTIALS_FILE
        scraper.OAUTH_CREDENTIALS_FILE = self.tmp.name

    def tearDown(self):
        scraper.OAUTH_CREDENTIALS_FILE = self._orig_file
        try:
            os.unlink(self.tmp.name)
        except OSError:
            pass

    def _write_cred(self, access_token="tok-123", expires_in_ms=3_600_000):
        with open(self.tmp.name, "w") as f:
            json.dump({"claudeAiOauth": {
                "accessToken": access_token,
                "expiresAt": int(time.time() * 1000) + expires_in_ms,
            }}, f)

    def test_valid_token_loaded(self):
        self._write_cred()
        self.assertEqual(scraper._load_oauth_access_token(), "tok-123")

    def test_expired_token_rejected(self):
        # 만료된 토큰은 절대 쓰지 않는다 (갱신은 Claude Code 몫).
        self._write_cred(expires_in_ms=-1000)
        # Keychain 폴백이 실제 토큰을 주울 수 있으므로 폴백도 차단한다.
        orig = scraper.subprocess.run
        scraper.subprocess.run = lambda *a, **k: type(
            "P", (), {"returncode": 1, "stdout": ""})()
        try:
            self.assertIsNone(scraper._load_oauth_access_token())
        finally:
            scraper.subprocess.run = orig

    def test_token_expiring_within_margin_rejected(self):
        self._write_cred(expires_in_ms=30_000)  # 60초 여유보다 짧음
        orig = scraper.subprocess.run
        scraper.subprocess.run = lambda *a, **k: type(
            "P", (), {"returncode": 1, "stdout": ""})()
        try:
            self.assertIsNone(scraper._load_oauth_access_token())
        finally:
            scraper.subprocess.run = orig

    def test_flat_cred_without_wrapper(self):
        # claudeAiOauth 래퍼 없이 평평한 형태도 허용.
        with open(self.tmp.name, "w") as f:
            json.dump({"accessToken": "flat-tok",
                       "expiresAt": int(time.time() * 1000) + 3_600_000}, f)
        self.assertEqual(scraper._load_oauth_access_token(), "flat-tok")


class WeeklyScopedParseTest(unittest.TestCase):
    def test_parse_extracts_only_weekly_scoped(self):
        blocks = scraper._parse_weekly_scoped(_sample_oauth_response())
        self.assertEqual(list(blocks), ["seven_day_fable"])
        self.assertEqual(blocks["seven_day_fable"]["utilization"], 30.0)
        self.assertEqual(blocks["seven_day_fable"]["model"], "Fable")

    def test_slug_handles_spaces(self):
        self.assertEqual(scraper._weekly_scope_slug("Sonnet only"), "sonnet_only")

    def test_missing_limits_is_empty(self):
        self.assertEqual(scraper._parse_weekly_scoped({}), {})
        self.assertEqual(scraper._parse_weekly_scoped({"limits": None}), {})

    def test_malformed_entries_skipped(self):
        blocks = scraper._parse_weekly_scoped({"limits": [
            {"kind": "weekly_scoped", "percent": 10, "scope": None},          # 모델 없음
            {"kind": "weekly_scoped", "percent": "?",                         # 퍼센트 불량
             "scope": {"model": {"display_name": "X"}}},
            "not-a-dict",
        ]})
        self.assertEqual(blocks, {})


class WeeklyServeTest(unittest.TestCase):
    def setUp(self):
        self._orig_cache = dict(scraper._oauth_cache)
        self._orig_enabled = scraper.OAUTH_USAGE_ENABLED
        scraper.OAUTH_USAGE_ENABLED = True

    def tearDown(self):
        scraper._oauth_cache.clear()
        scraper._oauth_cache.update(self._orig_cache)
        scraper.OAUTH_USAGE_ENABLED = self._orig_enabled

    def _prime_cache(self, blocks):
        scraper._oauth_cache.update({
            "blocks": blocks, "fetched_at": time.monotonic(), "refreshing": False,
        })

    def test_remaining_minutes_computed_at_serve_time(self):
        self._prime_cache({"seven_day_fable": {
            "utilization": 30.0, "resets_at": _iso_in(7200), "model": "Fable"}})
        served = scraper._oauth_weekly_blocks()
        rm = served["seven_day_fable"]["remaining_minutes"]
        self.assertGreaterEqual(rm, 115)
        self.assertLessEqual(rm, 120)

    def test_past_reset_dropped(self):
        # 지난 주 창의 낡은 값은 새 창처럼 보이면 안 되므로 통째로 버린다.
        self._prime_cache({"seven_day_fable": {
            "utilization": 99.0, "resets_at": _iso_in(-60), "model": "Fable"}})
        self.assertIsNone(scraper._oauth_weekly_blocks())

    def test_disabled_returns_none(self):
        scraper.OAUTH_USAGE_ENABLED = False
        self._prime_cache({"seven_day_fable": {
            "utilization": 30.0, "resets_at": _iso_in(7200), "model": "Fable"}})
        self.assertIsNone(scraper._oauth_weekly_blocks())

    def test_attach_never_overrides_existing_keys(self):
        self._prime_cache({"seven_day_fable": {
            "utilization": 30.0, "resets_at": _iso_in(7200), "model": "Fable"}})
        usage = {"five_hour": {"utilization": 1.0},
                 "seven_day_fable": {"utilization": 77.0}}
        scraper._attach_oauth_weekly(usage)
        self.assertEqual(usage["seven_day_fable"]["utilization"], 77.0)

    def test_attach_adds_new_key(self):
        self._prime_cache({"seven_day_fable": {
            "utilization": 30.0, "resets_at": _iso_in(7200), "model": "Fable"}})
        usage = {"five_hour": {"utilization": 1.0}}
        scraper._attach_oauth_weekly(usage)
        self.assertIn("seven_day_fable", usage)
        self.assertEqual(usage["seven_day_fable"]["utilization"], 30.0)

    def test_sync_refresh_uses_fetcher(self):
        # 만료된 캐시 + sync=True → _fetch_oauth_usage 경유로 즉시 채워진다.
        orig_load = scraper._load_oauth_access_token
        orig_fetch = scraper._fetch_oauth_usage
        scraper._load_oauth_access_token = lambda: "tok"
        scraper._fetch_oauth_usage = lambda token: _sample_oauth_response(fable_pct=42)
        try:
            scraper._oauth_cache.update(
                {"blocks": None, "fetched_at": None, "refreshing": False})
            served = scraper._oauth_weekly_blocks(sync=True)
            self.assertEqual(served["seven_day_fable"]["utilization"], 42.0)
        finally:
            scraper._load_oauth_access_token = orig_load
            scraper._fetch_oauth_usage = orig_fetch


class StatsEndpointTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w")
        self.tmp.close()
        self._orig_file = scraper.STATS_FILE
        scraper.STATS_FILE = self.tmp.name
        self.client = scraper.app.test_client()

    def tearDown(self):
        scraper.STATS_FILE = self._orig_file
        try:
            os.unlink(self.tmp.name)
        except OSError:
            pass

    def _write_stats(self):
        with open(self.tmp.name, "w") as f:
            json.dump({
                "version": 5,
                "lastComputedDate": "2026-08-30",
                "dailyActivity": [
                    {"date": "2026-08-29", "messageCount": 10,
                     "sessionCount": 1, "toolCallCount": 3},
                ],
                "dailyModelTokens": [
                    {"date": "2026-08-29",
                     "tokensByModel": {"claude-fable-5": 12345}},
                ],
                "modelUsage": {"claude-fable-5": {"inputTokens": 1, "outputTokens": 2}},
                "totalSessions": 43,
            }, f)

    def test_stats_served_snake_case(self):
        self._write_stats()
        resp = self.client.get("/api/stats")
        self.assertEqual(resp.status_code, 200)
        body = resp.get_json()
        self.assertFalse(body["stale"])
        stats = body["stats"]
        self.assertEqual(stats["last_computed_date"], "2026-08-30")
        self.assertEqual(stats["daily_activity"][0]["message_count"], 10)
        # 모델 ID(소문자)는 변환되지 않아야 한다.
        self.assertIn("claude-fable-5",
                      stats["daily_model_tokens"][0]["tokens_by_model"])
        self.assertEqual(stats["model_usage"]["claude-fable-5"]["input_tokens"], 1)
        self.assertEqual(stats["total_sessions"], 43)

    def test_missing_file_is_404(self):
        os.unlink(self.tmp.name)
        resp = self.client.get("/api/stats")
        self.assertEqual(resp.status_code, 404)
        self.assertEqual(resp.get_json()["error_type"], "StatsUnavailable")

    def test_corrupt_file_is_500(self):
        with open(self.tmp.name, "w") as f:
            f.write("{ nope ]")
        resp = self.client.get("/api/stats")
        self.assertEqual(resp.status_code, 500)
        self.assertEqual(resp.get_json()["error_type"], "StatsUnavailable")

    def test_old_file_marked_stale(self):
        self._write_stats()
        old = time.time() - 10 * 86400
        os.utime(self.tmp.name, (old, old))
        resp = self.client.get("/api/stats")
        self.assertEqual(resp.status_code, 200)
        self.assertTrue(resp.get_json()["stale"])


if __name__ == "__main__":
    unittest.main()
