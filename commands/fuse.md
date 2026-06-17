---
description: fan a prompt across the richest auto-detected panel and judge with Opus
argument-hint: <prompt>
---

Invoke the `fuse` skill (read its `SKILL.md` — Claude Code provides the skill's base
directory when it loads — and follow it verbatim). The skill needs `Bash` (scratch
dirs, prompt files, the parallel runner fan-out), `Read`, and `Write`; do not narrow
its tools. Pass the user's text **byte-for-byte** as the panel prompt — no editing, no
persona, no lens, no wrapping. The skill auto-detects the richest available panel via
`detect_panel.sh`; do **not** pin a subset (that is what `/fuse-opus-gpt-minimax` and
`/fuse-pick` are for).

User prompt:

$ARGUMENTS
