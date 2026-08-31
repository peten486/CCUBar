"""statusline-custom.sh 단조성 가드 테스트 (stdlib unittest — 추가 의존성 없음).

여러 Claude Code 세션이 스냅샷을 덮어쓸 때, 이전 5시간 창의 resets_at 을 가진
낡은 세션의 에코가 최신 스냅샷을 파괴하지 않는지 검증한다. 이 에코는 소비자
(안드로이드/iOS 앱)의 "새 창" 감지를 오발시켜 같은 구간 알림이 폴링 주기마다
반복 발화하는 버그의 근본 원인이었다.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "statusline-custom.sh"
)

WINDOW_A = 1788154200  # 이전 5시간 창
WINDOW_B = 1788172200  # 현재 창
WINDOW_C = 1788190200  # 다음 창


def _session_input(used, resets_at):
    return json.dumps({
        "rate_limits": {
            "five_hour": {"used_percentage": used, "resets_at": resets_at},
            "seven_day": {"used_percentage": 10, "resets_at": 1788332400},
        },
        "model": {"display_name": "Test"},
        "cost": {"total_cost_usd": 1.0},
        "context_window": {"used_percentage": 5},
    })


class StatuslineGuardTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.snapshot = os.path.join(self.dir, "usage-snapshot.json")
        self.env = dict(
            os.environ,
            CCUBAR_USAGE_SNAPSHOT=self.snapshot,
            CCUBAR_STATUSLINE_ORIGINAL="/nonexistent",
        )

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _run(self, stdin, env=None):
        subprocess.run(
            ["bash", SCRIPT], input=stdin, text=True,
            env=env or self.env, capture_output=True, timeout=30,
        )

    def _five_hour(self):
        with open(self.snapshot, encoding="utf-8") as f:
            return json.load(f)["rate_limits"]["five_hour"]

    def test_first_write_and_same_window_update(self):
        self._run(_session_input(34, WINDOW_B))
        self.assertEqual(self._five_hour()["resets_at"], WINDOW_B)
        self._run(_session_input(36, WINDOW_B))
        self.assertEqual(self._five_hour()["used_percentage"], 36)

    def test_stale_echo_is_skipped(self):
        self._run(_session_input(36, WINDOW_B))
        # 낡은 세션이 이전 창(87%)을 되돌려 씀 → 무시돼야 한다
        self._run(_session_input(87, WINDOW_A))
        fh = self._five_hour()
        self.assertEqual(fh["resets_at"], WINDOW_B)
        self.assertEqual(fh["used_percentage"], 36)

    def test_forward_window_is_written(self):
        self._run(_session_input(87, WINDOW_B))
        self._run(_session_input(5, WINDOW_C))
        fh = self._five_hour()
        self.assertEqual(fh["resets_at"], WINDOW_C)
        self.assertEqual(fh["used_percentage"], 5)

    def test_missing_rate_limits_preserves_snapshot(self):
        self._run(_session_input(36, WINDOW_B))
        self._run(json.dumps({"model": {"display_name": "Test"}}))
        self.assertEqual(self._five_hour()["used_percentage"], 36)

    def test_corrupt_existing_snapshot_still_writes(self):
        with open(self.snapshot, "w", encoding="utf-8") as f:
            f.write("{not json")
        self._run(_session_input(36, WINDOW_B))
        self.assertEqual(self._five_hour()["resets_at"], WINDOW_B)

    def test_python_fallback_guard(self):
        # jq 없는 환경 재현: 필요한 바이너리만 담은 PATH 로 실행
        bindir = os.path.join(self.dir, "bin")
        os.makedirs(bindir)
        for tool in ("bash", "sh", "cat", "printf", "mktemp", "mv", "rm", "chmod", "python3"):
            path = shutil.which(tool)
            if path:
                os.symlink(path, os.path.join(bindir, tool))
        env = dict(self.env, PATH=bindir)
        self._run(_session_input(36, WINDOW_B), env=env)
        self._run(_session_input(87, WINDOW_A), env=env)
        fh = self._five_hour()
        self.assertEqual(fh["resets_at"], WINDOW_B)
        self.assertEqual(fh["used_percentage"], 36)


if __name__ == "__main__":
    unittest.main()
