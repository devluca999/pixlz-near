"""The attack demo (docs/ATTACKS.md) must keep passing: every attack blocked or limited as documented."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import attack_demo  # noqa: E402


def test_every_attack_is_blocked_or_limited(capsys):
    attack_demo.rows.clear()
    assert attack_demo.main() == 0
    assert len(attack_demo.rows) >= 21
    assert all(r.ok for r in attack_demo.rows)
    assert [r.expect for r in attack_demo.rows].count("LIMITED") == 1
