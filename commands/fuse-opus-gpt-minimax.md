---
description: fan to the FULL pinned panel (Opus 4.8 + GPT-5.5 + MiniMax M3), no auto-detect downgrade
argument-hint: <prompt>
---

Invoke the `fuse` skill (read its `SKILL.md` — Claude Code provides the skill's base
directory when it loads — and follow it verbatim). The skill needs `Bash` (scratch
dirs, prompt files, the parallel runner fan-out), `Read`, and `Write`; do not narrow
its tools. Pass the user's text **byte-for-byte** as the panel prompt — no editing, no
persona, no lens, no wrapping. **Skip `detect_panel.sh`** for this command — the
panel is pinned to all three runners: Opus 4.8 (`run_opus.sh`), GPT-5.5
(`run_gpt.sh`), and MiniMax M3 (`run_minimax.sh`). Fan to all three every time; if a
backend is down, surface that explicitly in the audit panel line (per FR-011: name
the missing piece + how to enable it) rather than silently dropping the panelist
from the panel — a downgraded run breaks the pin the user asked for. The judge
still applies the standard rubric (mode defaults to combine per task_class); a
`pin_mode` from `/fuse-pick` would override, but `/fuse-opus-gpt-minimax` pins the
**panel**, not the **mode**.

User prompt:

$ARGUMENTS
