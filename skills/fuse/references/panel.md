# Panel — independence-then-synthesis

## Core idea

One verbatim prompt fans out to N models **in parallel** and **blind**.
No panelist sees another panelist's answer. The judge is the *only* meeting
point — it reads all answers fresh, after they have all returned.

```
            ┌─→ Opus 4.8 @xhigh     (run_opus.sh)    ─┐
verbatim ──→├─→ GPT-5.5  @high      (run_gpt.sh)     ─┼─→ judge (Opus 4.8 @ultracode)
prompt     └─→ MiniMax M3 @deep    (run_minimax.sh)  ┘   reads all three, decides
```

## Why blind + parallel (not round-robin, not shared context)

Independence preserves genuine diversity of approach. A model that sees another
panelist's draft is pulled toward the first plausible answer (anchoring); the
panel collapses into N rephrasings of one answer. Parallel launch is what makes
this affordable — wall-clock is the slowest panelist, not the sum.

The reference mechanism (fusion-fable, citing the DRACO deep-research finding)
is that **synthesizing independent answers — even two runs of the same model —
beats a single run**. The whole panel is a bet on that finding, adapted to a
heterogeneous 3-model panel instead of N runs of one model.

## The fuse panel

| Panelist | Effort        | Runner            | What it is                                         |
|----------|---------------|-------------------|----------------------------------------------------|
| Opus 4.8 | `@xhigh`      | `run_opus.sh`     | local `claude -p --model claude-opus-4-8`          |
| GPT-5.5  | `@high`       | `run_gpt.sh`      | pluggable: `codex exec` → daemon route → drop       |
| MiniMax M3 | `@deep`     | `run_minimax.sh`  | `mm --deep -p` (per-invocation env, FR-005)        |

Each panelist is a **literal separate process** via its runner script — never
an in-process `Agent` subagent. That is what guarantees Opus is Opus
regardless of what model the caller is running
(Constitution III; see `research.md` R1).

## No lenses. No personas.

Every panelist receives the **same verbatim prompt**. Diversity comes from
different model weights, different training data, and different reasoning
trajectories — not from assigned roles like "the security lens" or
"the architect lens". A panel with assigned lenses is just one model N
times; the roles re-introduce the anchoring they were meant to prevent
(FR-001: "no assigned lenses, personas, or pre-digestion of the task").

## Invariants

- **Blindness (FR-002).** A panelist's answer is **never** placed in another
  panelist's prompt. Verifiable from the run record: the orchestrator writes
  each panelist's prompt to its own scratch file *before* launching runners,
  launches them in one turn, and only reads the out-files *after* all have
  returned. No inter-panelist channel exists in the engine.
- **Parallelism (FR-002, SC-002).** All participating panelists are launched
  in the same turn. Wall-clock ≤ slowest panelist.
- **Absent ≠ agreement (FR-011, SC-004).** A dropped, errored, or
  timed-out panelist is a missing vote, never a concurring vote. The judge
  reasons over whoever returned; the missing panelist is named in the
  receipt with how to enable it. A 1-panelist degenerate run is flagged
  "not a true fusion" (edge case).
- **No credentials leak (FR-014, SC-007).** Auth is read by the wrappers
  from their canonical files; never placed on argv, in prompts, in outputs,
  or in the run receipt. Prompts are written to `mktemp -d` scratch with
  `trap … EXIT` cleanup.

## What the panel is *not*

- Not a debate. Panelists do not see each other's drafts and do not reply
  to each other.
- Not a vote. There is no majority rule. The judge weighs and either
  selects one answer outright or combines them (see `judge_rubric.md`).
- Not a replacement for thinking. A panel answers the question it was
  given; the *quality* of the question is the caller's job. fusing a
  vague prompt just fuses three vague answers.
