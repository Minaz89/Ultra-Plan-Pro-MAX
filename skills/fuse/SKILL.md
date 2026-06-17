---
name: fuse
description: Use when the user wants a high-stakes question fanned across a blind multi-model panel (Opus 4.8, GPT-5.5, MiniMax M3) and then judged/merged by Opus @ultracode. Triggers — "fuse this", "panel this", "ask the panel", "fuse --pick combine|select", or any question explicitly worth three models.
---

# fuse — multi-AI panel→judge orchestration

You are the **orchestrator**. The opus model that ran this skill is also the **judge**
(separate from every spawned panelist). Your job: fan the user's verbatim prompt out
to a parallel, blind panel, then read every answer fresh and produce one final
deliverable + an attributed audit trail. Mechanics live in
`references/panel.md`; the judge's scoring rubric lives in
`references/judge_rubric.md`. This file is the procedural contract — follow it in
order.

## Hard rules (do not violate)

- **FR-001 verbatim prompt.** The prompt you write to disk is the exact text the user
  gave you, character for character. No lenses, no personas, no pre-digestion, no
  "you are a security expert" wrapper, no added context the user did not provide.
- **FR-002 blindness.** A panelist's answer is **never** placed in another panelist's
  prompt, ever. The judge reads all answers after all have returned.
- **FR-002 parallelism.** Every participating panelist is launched in the **same
  turn** of this session (one assistant message containing all `Bash` invocations).
  Wall-clock is the slowest panelist, not the sum.
- **FR-005 Anthropic via `claude -p` only.** Use the `run_opus.sh` runner; do not
  call any Anthropic API directly. `run_minimax.sh` reaches MiniMax through
  `mm --deep -p` **directly** — never `mm-exec`, whose worker preamble would
  contaminate the verbatim prompt (FR-001). Never set a global `ANTHROPIC_BASE_URL`.
- **FR-014 no credential leak.** No keys on argv, in prompts, in outputs, in
  scratch logs, or in the run receipt. The runners' `safe_log` redacts; rely on
  it. Use `mktemp -d` + caller-side `trap ... EXIT` for scratch.
- **FR-011 absent ≠ agreement.** A dropped / errored / empty / timed-out panelist
  is named as a missing vote, never a concurring one. Fusion needs ≥2 panelists
  to add value (edge case: 1-panelist runs are "not a true fusion").

## Locating the bundle

Claude Code tells you this skill's **base directory** when the skill loads
("Base directory for this skill: …"). Set `SKILL_DIR` to that path for every
shell snippet below; the scripts live at `${SKILL_DIR}/scripts/`. Do **not**
assume `CLAUDE_PROJECT_DIR` — the bundle is installed under `~/.claude/skills/fuse`,
not the caller's project.

```bash
SKILL_DIR="<this skill's base directory>"   # e.g. ~/.claude/skills/fuse
```

## STEP 0 — Detect the panel

```bash
bash "${SKILL_DIR}/scripts/detect_panel.sh" 2>&1
```

Parse the output: extract the `SLUG=` line (machine-readable). The slug is one of
`opus-gpt-minimax` | `opus-minimax` | `opus-gpt` | `opus-only`. Tell the user
which panel is active. **If `SLUG=opus-only`**, warn explicitly:

> WARNING: degenerate panel (opus-only) — not a true fusion. fusing requires ≥2
> panelists to add value. Continue anyway?

Get confirmation (or just proceed — fusion is opt-in and the user invoked
`/fuse`). Record the slug + which members are present for the final panel line.

Pin overrides (optional): if the user pinned a panel via `/fuse-opus-gpt-minimax`
or a `--panel` flag, honor the pin and skip auto-detection. If they pinned a mode
(`/fuse-pick select|combine` or `--pick`), record `pin_mode=...` and the judge
honors it (FR-007 / FR-012).

## STEP 1 — Fan out parallel + blind

1. Make a per-run scratch dir and register cleanup:

   ```bash
   scratch="$(mktemp -d -t fuse-XXXXXX)"
   trap 'rm -rf "${scratch}"' EXIT
   ```

2. Write the **verbatim** user prompt to `${scratch}/prompt.txt`. No edits. No
   framing. The file's bytes ARE the panelist prompt.

3. Define the output paths. `${scratch}` from `mktemp -d` is already absolute,
   so these are absolute — do **not** prefix `$(pwd)/` (that would corrupt the
   path):

   ```bash
   opus_out="${scratch}/answer_opus.txt"
   gpt_out="${scratch}/answer_gpt.txt"
   minimax_out="${scratch}/answer_minimax.txt"
   ```

   (Each runner resolves its own output path too, but these are already absolute
   so the judge reads from known locations.)

4. Launch **all** participating runners in **one assistant turn** with parallel
   `Bash` tool calls. Use the canonical commands:

   ```bash
   # Opus — default effort xhigh (one rung under max; NOT a Principle-V max deviation, local claude -p path)
   bash "${SKILL_DIR}/scripts/run_opus.sh" \
       "${scratch}/prompt.txt" "${opus_out}" xhigh

   # GPT-5.5 — default effort high (pluggable: codex → daemon → drop)
   bash "${SKILL_DIR}/scripts/run_gpt.sh" \
       "${scratch}/prompt.txt" "${gpt_out}" high

   # MiniMax M3 — default effort deep
   bash "${SKILL_DIR}/scripts/run_minimax.sh" \
       "${scratch}/prompt.txt" "${minimax_out}" deep
   ```

   Skip a panelist whose backend is not available (the script exits 127, the
   detect line told you which). **Do not** call any non-participating runner —
   don't pollute the run with a phantom panelist.

   ### Dials (panel composition + per-panelist effort + mode) — FR-012

   The orchestrator is the seam where the user steers the run. Three dials,
   independent of each other, all overridable, all defaulted:

   1. **Panel composition** — which runners actually launch. The `SLUG` from
      STEP 0 names the auto-detected panel. The user may run a **subset**
      (e.g. `opus+minimax` only, or a 2-model panel) by saying so in the
      invocation, e.g. `/fuse --panel opus,minimax "<q>"` or "fuse this with
      opus and minimax only". Only launch the chosen runners; do not call the
      excluded ones. The slug in STEP 4 reflects the **subset that actually
      ran** (e.g. `opus-minimax`), not the auto-detected maximum. A
      `<2 panelist` subset is still flagged `not a true fusion` (FR-011).
   2. **Per-panelist effort** — the **3rd positional arg** to each runner
      (`run_opus.sh <prompt> <out> <effort>`, same shape for `run_gpt.sh` /
      `run_minimax.sh`). The runners already accept it; the orchestrator just
      passes it through.
      - **Defaults**: opus=`max` (Constitution V deviation, local claude -p
        path), gpt=`high`, minimax=`deep`.
      - **Override**: if the user requests a different effort — "fuse this on
        `high`", `/fuse --effort high "<q>"`, "all panelist effort `xhigh`"
        — pass it through to every participating runner. A user can also
        override per-panelist: "opus on `max`, the rest on `low`" → translate
        to per-runner args. The runners enforce their own value set
        (e.g. opus=`max|high|<other>` per the runner header); unknown values
        → exit 64 usage error → treat as absent (FR-011).
   3. **Mode** — `select` vs `combine`. Pinned by `/fuse-pick select|combine`
      or `/fuse --pick select` (FR-007 / FR-012). Judge honors the pin
      verbatim; record `pin_mode=...` in the audit.

   If the user did not pin any dial, defaults stand. If they pinned one or
   more, the pinned values win over defaults for that run only. Pin per-run,
   not session-wide.

   **Reading runner exit codes** (the runner headers document these; re-state here
   so the judge treats them right in STEP 2):
   - **`127` — backend MISSING.** The binary / config the runner needs is not on
     disk or env (e.g. `claude` not installed for Opus, `codex` not at
     `~/.npm-global/bin/codex` and `CODEX_BIN` unset for GPT-5.5, `mm` not found
     or `~/.config/minimax.env` missing for M3). **Action: DROP the panelist.**
     Record a downgrade note naming the missing piece + **how to enable it**
     (e.g. "install codex at `~/.npm-global/bin/codex` or set `CODEX_BIN`";
     "mm not found — install MiniMax CLI; ensure `~/.config/minimax.env` is
     present and has a valid `MINIMAX_API_KEY`"). Run proceeds on the rest.
   - **Other non-zero (`1`, `64`, `65`, timeouts) — backend ERRORED.** The
     backend was reachable but failed mid-run: empty output, exec error, usage
     error (`64`/`65`), timeout. **Action: treat the panelist as ABSENT — not
     agreement** (FR-011). Name it in the audit with the failure shape; do NOT
     count it as a concurring vote on whatever the other panelists said.
   - **Empty output file (race / zero-byte answer) — same as errored.** Treat
     as absent, not agreement.
   - **0 + non-empty output file — OK.** Include in the panel.

   In BOTH `127` and "other non-zero / empty" cases the panelist is **never**
   counted as a concurring vote. Counting it would manufacture a fake
   consensus (FR-011 violation). The audit names the panelist + the reason +
   the how-to-enable, every time.

5. Wait for **all** parallel calls to return. The harness blocks until they
   finish. After they return, do not start reading answer files yet — STEP 2
   does that deliberately, in one pass, so the judge reads them fresh.

**Run record** (kept in scratch for the receipt at STEP 4): prompt path, panel
slug, per-panelist exit codes, output file paths, start/end wall-clock.

## STEP 2 — Judge (you, at ultracode)

You are the judge. You did not author any panelist answer. Read every present
answer file **fresh** in this turn (do not rely on prior summarization, prior
scratchpad, or anything outside the answer files + the original prompt). Apply
`references/judge_rubric.md` exactly:

1. **Classify the task** → `task_class` = `artifact` (Track A) or `research`
   (Track B). Default: code/config/runnable-shaped prompt → A; prose-shaped
   prompt → B. `task_class` is judge-classified; no command pins it in this
   version (only the *mode* is pinnable, via `/fuse-pick` — see next step).
2. **Pick the mode** — `selection` OR `combination` (FR-007). Both are
   first-class outcomes; do not treat `selection` as a degenerate case of
   `combination`.
   - **`selection`** — when one panelist's answer is clearly best, you may
     **present that one answer outright** + a short "why it beat the others"
     that points to the specific strength AND names what each rejected answer
     was missing or got wrong. The winner is the deliverable; the losers are
     named in the audit, not pasted into the body.
   - **`combination`** — when answers are complementary, merge them into one
     new deliverable (Track A → one runnable artifact; Track B → five-section
     synthesis).
   - **Defaults by task_class**: A → `combination` (merge to one runnable
     artifact); B → `combination` (five sections are inherently a synthesis).
   - **Pin overrides defaults (FR-012).** A `pin_mode` from `/fuse-pick
     select|combine` (or `--pick`) **always** wins over the default-by-task;
     record the pin in the audit and honor it verbatim.
3. **Track A — artifact.** Run each candidate if the env can. If `selection`:
   the winner's artifact IS the deliverable; the rejected ones get a one-line
   "what this one missed" in the audit. If `combination`: merge into **one
   complete runnable artifact** (not a diff, not two pasted programs). Take
   the spine from the strongest candidate; graft concrete improvements from
   the others. Run the merged result. If it works → `verified: ran-ok`. If
   exec is impossible in this env → fall back to seam-reasoning and emit
   `verified: unverified` + the reason. Never claim a run that didn't happen.
4. **Track B — research.** If `selection`: emit the winner's answer first
   (lightly edited for flow), then a short rationale naming what each loser
   missed. If `combination`: produce five attributed sections in order:
   **consensus** (≥2 panelists independently), **contradictions** (direct
   disagreements — surface them, do not average away), **partial coverage**
   (one panelist covered a sub-question the others skipped), **unique
   insights** (only one panelist surfaced this — flag as un-corroborated),
   **blind spots** (no panelist addressed — call out the boundary of the
   answer). Then a final grounded answer that is **not** a fifth summary — it
   is the answer a reader should act on.
5. **Attribution (FR-010).** Every claim / decision / line in the deliverable
   carries inline tags `[opus]`, `[gpt]`, `[minimax]`, or `[opus+gpt]` etc.
   A claim with no source is a bug.

**The literal-Opus-judge guarantee (FR-006).** This skill is intended to run in
an Opus Claude Code session. If the active session is not Opus, the judge step
can itself shell out via `run_opus.sh ... ultracode` and read the result back
as the verdict — but prefer running natively so the judge has fresh tool
context. Either shape is acceptable; the verification question is "did the
verdict come from an Opus 4.8 @ultracode pass?".

**Absent panelists (FR-011).** For each non-returning panelist, name it in the
verdict with **why** and **how to enable it**:
- `127` (backend MISSING) — the binary / config is not present. The how-to-enable
  is the install/config command. Example: `gpt: dropped (exit 127); enable:
  install codex at ~/.npm-global/bin/codex or set CODEX_BIN`.
- Other non-zero / empty (backend ERRORED) — the backend was reachable but
  failed mid-run. The how-to-enable is the fix for that specific failure
  (re-auth, raise a timeout, check the prompt file). Example: `minimax:
  absent (exit 1, empty output); enable: rerun with verbose logs at
  ${scratch}/runner_minimax.log`.
- In BOTH cases, **never** count the missing/errored panelist as a concurring
  vote. Counting it would manufacture a fake consensus.

**Degenerate 1-panelist runs (FR-011 edge case).** If — after drops and
errors — only ONE panelist returned a real answer, the run is **not a true
fusion**. Flag it explicitly in the verdict:

> `panel: opus-only | ran: [opus] | dropped: [gpt: ...; minimax: ...]`
> `WARNING: not a true fusion (1 panelist) — single-model answer, no cross-check.`

The single answer is still emitted, but it is labeled as a single-model
answer, not a fused deliverable. Do not present it with the "panel line"
format that implies multi-model agreement. The user can re-run after
restoring the missing backends to get a real fusion.

## STEP 3 — Produce the deliverable

Track A → emit one complete runnable artifact first, then a `verified` note.
Track B → emit the grounded final answer first, then the five attributed
sections. Either way: **the final deliverable comes before the audit trail**.
Never bury the answer under the analysis (FR-015).

## STEP 4 — Present

Structure the response exactly in this order. The panel line + cost/latency
note are **first-class** — they are the audit metadata that makes the answer
trustworthy, not optional asides (FR-013 / FR-015).

1. **Final deliverable** (the artifact, or the grounded answer). Plain, the
   thing the user can act on. **Always first** — never bury it under
   analysis (FR-015).
2. **Attributed audit trail.**
   - For Track A: merge rationale (what was taken from each candidate and why)
     + per-candidate behavior (ran / errored / not-runnable / dropped).
   - For Track B: the five sections from STEP 2, with inline `[opus]` etc.
     attribution. (You may show the grounded answer again here for readers
     who skipped to the audit — that's fine, duplication of the answer is
     fine; burying it is not.)
3. **Panel line** (FR-015) — naming participating + dropped panelists, with
   the how-to-enable for every drop. Emit as a single line, machine- and
   human-readable:
   ```
   panel: <slug> | ran: [<panelist>, ...] | dropped: [<name>: <reason>; enable: <how>, ...]
   ```
   - `slug` is the panel that actually ran this invocation (subset slug if
     the user pinned a subset, e.g. `opus-minimax` — NOT the auto-detected
     maximum).
   - `ran` lists every panelist that returned a real, non-empty answer.
   - `dropped` lists every panelist that was absent (exit 127 / errored /
     empty / timed out / excluded by the user's subset pin). For each,
     name the panelist + the reason + the **how-to-enable**. **No vote of
     agreement** may be implied by absence (FR-011).
   - If a 1-panelist subset was forced (user-pinned subset smaller than 2,
     or all-but-one backends missing), append the FR-011 edge-case flag:
     `| WARNING: not a true fusion (1 panelist)`.
4. **Cost / latency note** (FR-013). First-class block. Use this exact
   template; fill every field you have data for, omit what you don't:
   ```
   cost/latency:
     panelist_count: <N>            # number that actually ran
     cost_estimate:  ≈ N× a single answer
     wall_clock:     ≈ slowest panelist (parallel fan-out)
     per_panelist:   [opus: <Xs> | gpt: <Xs> | minimax: <Xs>]   # if start/end recorded
     effort_dials:   opus=<e> gpt=<e> minimax=<e>   # what was passed
     effort_note:    xhigh/deep/high (panel defaults) cost more than low; users override at their own spend
     reserve_for:    high-stakes questions (architecture, security, irreversible ops)
   ```
   If the run record has per-panelist start/end wall-clock, include elapsed
   per panelist. If it doesn't, omit `per_panelist` — never fabricate times.
   The `effort_dials` line is mandatory: the user needs to see what they paid
   for. Always end with the **reserve_for** reminder — this skill is
   expensive and the user should not reach for it on a trivial question.

## What to read on every `/fuse`

- `references/panel.md` — the why-blind-why-parallel rationale. Skim once.
- `references/judge_rubric.md` — the scoring rubric. **Read fully** before
  STEP 2; it is your operating manual for the judge step.
- The runner scripts under `scripts/` — only if a runner misbehaves; the
  contract is `run_*.sh <prompt_file> <output_file> [effort]` with the exit
  codes listed in their headers (0 = ok, 127 = drop, 64/65 = usage, 1 =
  empty/errored).
