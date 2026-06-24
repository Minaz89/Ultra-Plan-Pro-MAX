#!/usr/bin/env python3
"""Materialize an ultraplan --harness team design into .claude/{agents,skills}/.

The Stage-2 judge emits team-design.json; this script is the SOLE disk writer
(the model never free-writes files). Validation is authoritative: it enforces
the executor-pool / codex ban and the mandatory guard-reviewer BY CONSTRUCTION
(spec 019, FR-4/FR-5/FR-7). Any violation refuses loudly and writes nothing.

Refusals (exit 3, reason on stderr):
  R1  a roster model (pin or fallback) outside the executor pool (bans gpt-5.5/codex)
  R2  a producer agent absent from guard_topology
  R3  no reviewer carrying all of clean-code-guard / test-guard / docs-guard
  R4  roster larger than a pattern's max_roster (cost)
  R5  pattern not one of the 6 absorbed patterns, or an agent name/skill that
      does not validate / resolve (agent name doubles as a path segment, so an
      unvalidated name is a path-traversal sink — it is checked, not trusted)

Usage:
  materialize_team.py --design team-design.json --staging <dir> [--skills-root DIR] [--apply]
Without --apply it validates only (dry run); with --apply it writes the staging tree.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
PATTERNS_PATH = SKILL_ROOT / "references" / "patterns.json"
REQUIRED_GUARD_SKILLS = frozenset({"clean-code-guard", "test-guard", "docs-guard"})
AGENT_NAME_RE = re.compile(r"[a-z0-9-]+")  # used with fullmatch — no trailing-newline slack
REQUIRED_AGENT_KEYS = ("name", "role", "model_pin")
PRODUCER_ROLES = frozenset({"producer", "dispatcher", "supervisor", "aggregator"})


class TeamRefusal(Exception):
    """A team design that violates a hard invariant. Carries the R-code."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code


def load_catalog() -> dict:
    """Read the frozen pattern catalog — the single source of truth for the
    allowed patterns, executor pool, and forbidden executors."""
    return json.loads(PATTERNS_PATH.read_text(encoding="utf-8"))


def reviewer_covers_guards(agent: dict) -> bool:
    return REQUIRED_GUARD_SKILLS.issubset(set(agent.get("skills", [])))


def check_executor_pool(roster: list[dict], pool: set[str], forbidden: set[str]) -> None:
    """R1 — every worker model (pin + fallback) must be inside the executor pool.
    Forbidden models (gpt-5.5/codex) can never be a worker; opus is audit-only and
    is simply not in the pool. Fail-closed: a model neither pinned nor known refuses."""
    for agent in roster:
        for field in ("model_pin", "model_fallback"):
            model = agent.get(field)
            if model is None:
                continue
            if model in forbidden or model not in pool:
                raise TeamRefusal(
                    "R1",
                    f"agent '{agent.get('name')}' {field}={model!r} is not in the "
                    f"executor pool {sorted(pool)} (gpt-5.5/codex are panel-only, never workers)",
                )


def check_guard_topology(roster: list[dict], topology: dict) -> None:
    """R2 — every producer-class agent must be gated by an entry in guard_topology.
    R3 — at least one reviewer must carry all three guard skills."""
    for agent in roster:
        if agent.get("role") in PRODUCER_ROLES:
            gates = topology.get(agent["name"])
            if not gates:
                raise TeamRefusal("R2", f"producer '{agent['name']}' has no guard_topology entry")
    if not any(a.get("role") == "reviewer" and reviewer_covers_guards(a) for a in roster):
        raise TeamRefusal(
            "R3",
            f"no reviewer carries all of {sorted(REQUIRED_GUARD_SKILLS)} "
            "(a harness team without a guard-reviewer is invalid)",
        )


def check_shape(design: dict, catalog: dict) -> None:
    """R4 roster size vs the pattern's cap; R5 pattern membership + agent-name safety."""
    pattern = design.get("pattern")
    by_name = {p["name"]: p for p in catalog["patterns"]}
    if pattern not in by_name:
        raise TeamRefusal("R5", f"pattern {pattern!r} is not one of {sorted(by_name)}")
    roster = design.get("roster", [])
    cap = by_name[pattern]["max_roster"]
    if len(roster) > cap:
        raise TeamRefusal("R4", f"roster size {len(roster)} exceeds pattern '{pattern}' cap {cap}")
    for agent in roster:
        missing = [k for k in REQUIRED_AGENT_KEYS if not agent.get(k)]
        if missing:
            raise TeamRefusal("R5", f"agent {agent.get('name', '?')!r} missing required key(s): {missing}")
        name = agent["name"]
        if not AGENT_NAME_RE.fullmatch(name):
            raise TeamRefusal("R5", f"agent name {name!r} is not [a-z0-9-]+ (path-segment safety)")


def resolve_skills(roster: list[dict], skills_root: Path) -> None:
    """R5 — every referenced skill must resolve under skills_root (guard skills count)."""
    for agent in roster:
        for skill in agent.get("skills", []):
            if skill in REQUIRED_GUARD_SKILLS:
                continue
            if not (skills_root / skill).is_dir():
                raise TeamRefusal("R5", f"agent '{agent['name']}' references unresolved skill {skill!r}")


def validate(design: dict, catalog: dict, skills_root: Path) -> None:
    roster = design.get("roster")
    if not isinstance(roster, list) or len(roster) < 2:
        raise TeamRefusal("R5", "design must have a roster of at least 2 agents")
    pool = set(catalog["executor_pool"])
    forbidden = set(catalog["forbidden_executors"])
    check_shape(design, catalog)
    check_executor_pool(roster, pool, forbidden)
    check_guard_topology(roster, design.get("guard_topology", {}))
    resolve_skills(roster, skills_root)


def render_agent(agent: dict, pattern: str) -> str:
    """Render one agent definition file. Frontmatter carries the pinned model +
    its gates so the Stage-3 router and a human reader both see the contract."""
    gated_by = ", ".join(agent.get("gated_by", [])) or "(none)"
    skills = ", ".join(agent.get("skills", []))
    return (
        f"---\nname: {agent['name']}\nrole: {agent['role']}\n"
        f"model: {agent['model_pin']}\n"
        f"model_fallback: {agent.get('model_fallback', '')}\n"
        f"pattern: {pattern}\nskills: [{skills}]\ngated_by: {gated_by}\n---\n\n"
        f"# {agent['name']} ({agent['role']})\n\n"
        f"Generated by ultraplan --harness. Runs on `{agent['model_pin']}` "
        f"(fallback `{agent.get('model_fallback', 'none')}`). Pattern: {pattern}.\n"
    )


def materialize(design: dict, staging: Path) -> list[Path]:
    """Write the agent files into staging/.claude/agents/. Returns written paths.
    Caller copies staging→live only when execution starts (keeps live .claude pristine)."""
    agents_dir = staging / ".claude" / "agents"
    agents_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for agent in design["roster"]:
        path = agents_dir / f"{agent['name']}.md"
        path.write_text(render_agent(agent, design["pattern"]), encoding="utf-8")
        written.append(path)
    manifest = staging / "materialization_manifest.json"
    manifest.write_text(
        json.dumps(
            {"pattern": design["pattern"], "agents": [a["name"] for a in design["roster"]],
             "files": [str(p) for p in written]},
            indent=2,
        ),
        encoding="utf-8",
    )
    return written


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Materialize a harness team design.")
    parser.add_argument("--design", required=True, type=Path)
    parser.add_argument("--staging", required=True, type=Path)
    parser.add_argument("--skills-root", type=Path, default=Path.home() / ".claude" / "skills")
    parser.add_argument("--apply", action="store_true", help="write files (default: validate only)")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    design = json.loads(args.design.read_text(encoding="utf-8"))
    catalog = load_catalog()
    try:
        validate(design, catalog, args.skills_root)
    except TeamRefusal as refusal:
        print(f"REFUSED {refusal}", file=sys.stderr)
        return 3
    if not args.apply:
        print(f"OK (dry run) — pattern={design['pattern']} roster={len(design['roster'])}")
        return 0
    written = materialize(design, args.staging)
    print(f"materialized {len(written)} agents to {args.staging}/.claude/agents/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
