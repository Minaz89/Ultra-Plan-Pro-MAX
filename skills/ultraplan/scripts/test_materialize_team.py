#!/usr/bin/env python3
"""Tests for materialize_team.py — proves each refusal gate (R1-R5) fires and a
valid design materializes a codex-free team. Run: python3 test_materialize_team.py
(stdlib only; no pytest dependency)."""
from __future__ import annotations

import copy
import tempfile
from pathlib import Path

import materialize_team as mt

VALID = {
    "pattern": "producer-reviewer",
    "roster": [
        {"name": "impl-worker", "role": "producer", "model_pin": "glm-5.2",
         "skills": ["clean-code-guard"], "gated_by": ["review-guard"]},
        {"name": "review-guard", "role": "reviewer", "model_pin": "claude-sonnet",
         "skills": ["clean-code-guard", "test-guard", "docs-guard"]},
    ],
    "routing": {"implement": "impl-worker", "review": "review-guard"},
    "guard_topology": {"impl-worker": ["review-guard"]},
}
CATALOG = mt.load_catalog()
SKILLS_ROOT = Path.home() / ".claude" / "skills"


def expect_refusal(design: dict, code: str) -> None:
    try:
        mt.validate(design, CATALOG, SKILLS_ROOT)
    except mt.TeamRefusal as refusal:
        assert refusal.code == code, f"expected {code}, got {refusal.code}"
        return
    raise AssertionError(f"expected refusal {code}, but validate passed")


def test_valid_passes_and_writes_codex_free() -> None:
    mt.validate(VALID, CATALOG, SKILLS_ROOT)
    with tempfile.TemporaryDirectory() as tmp:
        written = mt.materialize(VALID, Path(tmp))
        assert len(written) == 2
        blob = "".join(p.read_text() for p in written)
        assert "gpt-5.5" not in blob and "codex" not in blob


def test_r1_forbidden_executor() -> None:
    d = copy.deepcopy(VALID); d["roster"][0]["model_pin"] = "gpt-5.5"
    expect_refusal(d, "R1")


def test_r2_producer_not_gated() -> None:
    d = copy.deepcopy(VALID); d["guard_topology"] = {}
    expect_refusal(d, "R2")


def test_r3_no_guard_reviewer() -> None:
    d = copy.deepcopy(VALID); d["roster"][1]["skills"] = ["clean-code-guard"]
    expect_refusal(d, "R3")


def test_r4_roster_over_cap() -> None:
    d = copy.deepcopy(VALID)
    worker = {"role": "producer", "model_pin": "minimax-m3", "skills": [], "gated_by": ["review-guard"]}
    d["roster"] = [dict(worker, name=f"w{i}") for i in range(5)] + [d["roster"][1]]
    d["guard_topology"].update({f"w{i}": ["review-guard"] for i in range(5)})
    expect_refusal(d, "R4")


def test_r5_bad_pattern_and_unsafe_name() -> None:
    bad_pattern = copy.deepcopy(VALID); bad_pattern["pattern"] = "megazord"
    expect_refusal(bad_pattern, "R5")
    bad_name = copy.deepcopy(VALID); bad_name["roster"][0]["name"] = "impl\n"
    expect_refusal(bad_name, "R5")
    missing = copy.deepcopy(VALID); del missing["roster"][0]["model_pin"]
    expect_refusal(missing, "R5")


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    print(f"\n{len(tests)}/{len(tests)} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
