---
description: fan to the panel, judge PICKS the single best answer (selection mode) instead of merging
argument-hint: <prompt>
---

Invoke the `fuse` skill (read its `SKILL.md` — Claude Code provides the skill's base
directory when it loads — and follow it verbatim). The skill needs `Bash` (scratch
dirs, prompt files, the parallel runner fan-out), `Read`, and `Write`; do not narrow
its tools. Pass the user's text **byte-for-byte** as the panel prompt — no editing, no
persona, no lens, no wrapping. The skill auto-detects the richest available panel via
`detect_panel.sh`. Honor the judge's `pin_mode=select` for this command: the judge
emits the **one** best panelist answer outright, then a short "why it beat the
others" naming what each rejected answer missed — **do not** merge, **do not**
synthesize across panelists, **do not** produce the five-section Track B output.
A `pin_mode` from `/fuse-pick` always wins over the default-by-task (FR-007 /
FR-012); record the pin in the audit and honor it verbatim.

User prompt:

$ARGUMENTS
