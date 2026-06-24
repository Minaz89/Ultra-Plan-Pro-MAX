#!/usr/bin/env python3
"""Pre-Stage-2 cost guard for ultraplan --harness (spec 019, FR-8).

Harness mode stacks a second panel + a team execution + audit on top of the
plan panel. On a small feature that overhead exceeds the gain, so this guard
sizes tasks.md and STEERS small features back to plain --ultra. Advisory by
default: it never silently blocks — it warns, and `--force-harness` overrides.

Exit codes: 0 proceed (feature large enough, or forced) · 4 too small + not
forced (the SKILL driver stops Stage 2, Stage 1 output still delivered).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TASK_LINE_RE = re.compile(r"^- \[[ xX]\] T\d", re.MULTILINE)
SMALL_TASK_THRESHOLD = 3  # <= this many tasks, with no multi-file signal, = "too small to staff"
MULTI_FILE_SIGNALS = ("greenfield", "multi-file", "new service", "rebuild", "migrate")


def count_tasks(tasks_md: str) -> int:
    return len(TASK_LINE_RE.findall(tasks_md))


def has_multi_file_signal(tasks_md: str) -> bool:
    lowered = tasks_md.lower()
    return any(signal in lowered for signal in MULTI_FILE_SIGNALS)


def is_too_small(tasks_md: str) -> bool:
    return count_tasks(tasks_md) <= SMALL_TASK_THRESHOLD and not has_multi_file_signal(tasks_md)


def write_spend_log(log_path: Path, tasks: int, decision: str) -> None:
    log_path.write_text(
        json.dumps({"tasks": tasks, "decision": decision, "threshold": SMALL_TASK_THRESHOLD}, indent=2),
        encoding="utf-8",
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ultraplan --harness cost guard (pre-Stage-2 sizing).")
    parser.add_argument("--tasks", required=True, type=Path, help="path to tasks.md")
    parser.add_argument("--force-harness", action="store_true", help="override the small-feature warning")
    parser.add_argument("--log", type=Path, help="optional path to write a spend/decision log")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    tasks_md = args.tasks.read_text(encoding="utf-8")
    tasks = count_tasks(tasks_md)
    small = is_too_small(tasks_md)
    if small and not args.force_harness:
        decision = "warn-too-small"
        print(
            f"harness mode not worth it for this scope: {tasks} task(s), no multi-file signal — use plain --ultra "
            "(pass --force-harness to override).",
            file=sys.stderr,
        )
        exit_code = 4
    else:
        decision = "forced" if small else "proceed"
        print(f"cost guard: {tasks} task(s) → {decision}")
        exit_code = 0
    if args.log:
        write_spend_log(args.log, tasks, decision)
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
