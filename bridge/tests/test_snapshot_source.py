"""SnapshotSource 단위 테스트 (stdlib unittest — 추가 의존성 없음).

statusline 스냅샷 읽기 경로만 검증한다. epoch→ISO 변환, remaining_minutes 계산,
stale/age 판정, 콜드스타트/부재 보존, seven_day_sonnet 생략을 다룬다.
"""

import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import claude_usage_scraper as scraper  # noqa: E402

UTC = timezone.utc


def _now_epoch():
    return int(datetime.now(UTC).timestamp())


def _write_snapshot(path, rate_limits, captured_at=None, schema_version=1):
    if captured_at is None:
        captured_at = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    snap = {
        "schema_version": schema_version,
        "captured_at": captured_at,
        "source": "statusline",
        "rate_limits": rate_limits,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(snap, f)


class SnapshotSourceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(
            suffix=".json", delete=False, mode="w"
        )
        self.tmp.close()
        self.path = self.tmp.name
        # 모듈 전역을 테스트용으로 지정하고 원복.
        self._orig_file = scraper.SNAPSHOT_FILE
        self._orig_thresh = scraper.STALE_THRESHOLD_SECONDS
        self._orig_last = scraper._last_snapshot_result["data"]
        scraper.SNAPSHOT_FILE = self.path
        scraper.STALE_THRESHOLD_SECONDS = 1800
        scraper._last_snapshot_result["data"] = None

    def tearDown(self):
        scraper.SNAPSHOT_FILE = self._orig_file
        scraper.STALE_THRESHOLD_SECONDS = self._orig_thresh
        scraper._last_snapshot_result["data"] = self._orig_last
        try:
            os.unlink(self.path)
        except OSError:
            pass

    # --- 변환 헬퍼 ---

    def test_epoch_to_iso_valid(self):
        iso = scraper._epoch_to_iso(1788163415)
        self.assertEqual(iso, "2026-08-31T08:03:35+00:00")

    def test_epoch_to_iso_invalid(self):
        self.assertIsNone(scraper._epoch_to_iso(None))
        self.assertIsNone(scraper._epoch_to_iso("not-a-number"))

    # --- 정상 경로 ---

    def test_normal_snapshot(self):
        _write_snapshot(self.path, {
            "five_hour": {"used_percentage": 45.5, "resets_at": _now_epoch() + 3600},
            "seven_day": {"used_percentage": 12.0, "resets_at": _now_epoch() + 500000},
        })
        r = scraper._scrape_via_snapshot()

        self.assertFalse(r["stale"])
        self.assertEqual(r["source"], "statusline")
        # float 정밀도 보존 (반올림 금지)
        self.assertEqual(r["five_hour"]["utilization"], 45.5)
        self.assertEqual(r["seven_day"]["utilization"], 12.0)
        # epoch → ISO 문자열
        self.assertTrue(r["five_hour"]["resets_at"].endswith("+00:00"))
        # remaining_minutes ≈ 60분
        self.assertGreaterEqual(r["five_hour"]["remaining_minutes"], 55)
        self.assertLessEqual(r["five_hour"]["remaining_minutes"], 60)

    def test_seven_day_sonnet_never_emitted(self):
        # 스냅샷에 sonnet 이 잘못 들어와도 서버는 SNAPSHOT_PERIODS 만 내보낸다.
        _write_snapshot(self.path, {
            "five_hour": {"used_percentage": 10, "resets_at": _now_epoch() + 3600},
            "seven_day_sonnet": {"used_percentage": 99, "resets_at": _now_epoch() + 3600},
        })
        r = scraper._scrape_via_snapshot()
        self.assertIn("five_hour", r)
        self.assertNotIn("seven_day_sonnet", r)

    def test_missing_window_omitted(self):
        # seven_day 가 없으면 그 키만 빠지고 나머지는 정상.
        _write_snapshot(self.path, {
            "five_hour": {"used_percentage": 10, "resets_at": _now_epoch() + 3600},
        })
        r = scraper._scrape_via_snapshot()
        self.assertIn("five_hour", r)
        self.assertNotIn("seven_day", r)

    def test_resets_at_in_past_clamps_to_zero(self):
        _write_snapshot(self.path, {
            "five_hour": {"used_percentage": 90, "resets_at": _now_epoch() - 60},
        })
        r = scraper._scrape_via_snapshot()
        self.assertEqual(r["five_hour"]["remaining_minutes"], 0)

    # --- staleness ---

    def test_old_snapshot_is_stale(self):
        _write_snapshot(self.path, {
            "five_hour": {"used_percentage": 90, "resets_at": _now_epoch() + 3600},
        }, captured_at="2020-01-01T00:00:00Z")
        r = scraper._scrape_via_snapshot()
        self.assertTrue(r["stale"])
        self.assertGreater(r["age_seconds"], 1800)
        # 값 자체는 여전히 실려 나온다
        self.assertEqual(r["five_hour"]["utilization"], 90.0)

    # --- 콜드스타트 / 부재 보존 ---

    def test_cold_start_no_file(self):
        os.unlink(self.path)
        r = scraper._scrape_via_snapshot()
        self.assertTrue(r["stale"])
        self.assertIsNone(r["age_seconds"])
        self.assertNotIn("five_hour", r)

    def test_corrupt_json_treated_as_missing(self):
        with open(self.path, "w") as f:
            f.write("{ this is not json ]")
        r = scraper._scrape_via_snapshot()
        self.assertTrue(r["stale"])
        self.assertNotIn("five_hour", r)

    def test_last_known_served_when_file_vanishes(self):
        _write_snapshot(self.path, {
            "five_hour": {"used_percentage": 30, "resets_at": _now_epoch() + 3600},
        })
        good = scraper._scrape_via_snapshot()
        self.assertFalse(good["stale"])

        # 파일이 사라져도 마지막 알려진 값을 stale 로 되돌린다.
        os.unlink(self.path)
        r = scraper._scrape_via_snapshot()
        self.assertTrue(r["stale"])
        self.assertTrue(r["cached"])
        self.assertEqual(r["five_hour"]["utilization"], 30.0)

    def test_future_schema_version_still_parses(self):
        _write_snapshot(self.path, {
            "five_hour": {"used_percentage": 20, "resets_at": _now_epoch() + 3600},
        }, schema_version=999)
        r = scraper._scrape_via_snapshot()
        self.assertIn("five_hour", r)


if __name__ == "__main__":
    unittest.main()
