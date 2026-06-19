---
name: ultraplan
description: Use for `/plan --ultra` ("ultraplan", "ultra plan pro max") — wraps the normal `plan` skill with a panel→judge front-end: specify+clarify ONCE, freeze the spec, fan it to 4 blind planners (Opus @xhigh / GPT-5.5 @high / MiniMax M3 @deep / GLM-5.2 @deep — top-of-ladder-below-max per model), Opus @ultracode judge select-and-grafts into ONE merged plan brief, human gate, then the normal `plan` pipeline formalizes. Execution (pro-max) routes to GLM-5.2-deep via `glm-exec` (replaces MiniMax-M3), opus audits. Opt-in only; ~5x cost; reserve for contested / greenfield / high-stakes plans. DO NOT USE for routine single-file changes, small refactors, or anything normal `/plan` handles fine.
---

# ultraplan — panel→judge over the PLAN stage

You are the **orchestrator**. The opus session that ran this skill is also
the **judge** (separate from every spawned panelist). ultraplan is a thin
mode on top of the normal `plan` skill — it does NOT modify `plan`; it
orchestrates around it. The plan formalization + audit downstream stay
byte-for-byte unchanged (FR-024). **EXECUTOR OVERRIDE (pro-max):** the one
deviation from FR-024 — under `--ultra`, the EXECUTION phase routes to
GLM-5.2-deep via `glm-exec` (it REPLACES MiniMax-M3 / `mm-exec` here), while
opus still plans + audits. Normal `/plan` (no flag) keeps the M3 default. See
the **EXECUTOR (pro-max)** section near the end.

## Hard rules (do not violate)

- **FR-017** — one spec, frozen. Run `speckit-specify` + `speckit-clarify` a
  SINGLE time with the user. Freeze the result. That frozen spec — not the
  raw one-liner, not a re-prompted variant — is fanned to all planners. They
  argue over the HOW against a fixed WHAT.
- **FR-018** — free-form briefs only. Panelists emit a **plan brief**
  (architecture, phased breakdown, risks, files touched, test strategy).
  They MUST NOT produce `spec.md`, `plan.md`, `tasks.md`, speckit artifacts,
  task lists, or GATE tasks. Structure is generated later by the normal
  `plan` path (FR-020).
- **FR-019** — judge = select-and-graft. Take the soundest architecture as
  the **spine**; graft only non-conflicting improvements from the others.
  Incompatible architectures → forced outright selection of one spine (no
  chimera plan that tries to do both). Judge rubric lives at
  `${FUSE_SCRIPTS_DIR}/../references/judge_rubric.md` (T037 added the
  `plan` task-class rule).
- **FR-020** — GATE tasks injected AFTER the merge, by the normal
  `plan` path. Panelists and judge MUST NOT emit GATE tasks. The merge
  step produces a brief; the brief is then handed to `plan` Step 1.3+ for
  `plan.md` / `tasks.md` / `analyze.md`, and `plan` Step 2 injects the
  GATE tasks as it would for any plan.
- **FR-022** — planner effort = the top of each model's ladder that is still
  **below `max`** (Principle V: never `max` on planners): opus = `xhigh`,
  gpt-5.5 = `high` (codex has no xhigh), minimax = `deep` (its --deep/32k mode;
  "high" silently drops --deep → shallow), glm-5.2 = `deep` (z.ai, 32k thinking
  via `run_glm.sh`; a non-"deep" effort drops it to a 10k budget). The Principle V `max` deviation
  (US1, local `claude -p` path) MUST NOT extend to planners — `xhigh` is one
  rung under `max`, so this holds. Judge effort = `ultracode` (user-overridable).
- **FR-023** — non-authoritative provenance trail. Persist
  `specs/NNN-slug/ultraplan/panel_opus.md` / `panel_gpt.md` /
  `panel_minimax.md` / `panel_glm.md` (raw briefs), `merged_brief.md`, `judge_attribution.json`
  (spine + grafts + rejections), `recon.md` (FR-025 codebase-recon findings +
  spec corrections, or a one-line "skipped (greenfield)"), and
  `spec.frozen.md` + `spec.frozen.sha256`.
  `plan-audit` reads the **merged** artifacts only; it MUST NOT score the
  panel trail. Exclusion is by path convention (`plan-audit` only scans
  `spec/plan/tasks/analyze/research` inside `specs/NNN/` — `ultraplan/` is
  a sibling directory and is never scanned). `research.md` remains the
  canonical Phase-0 artifact; the merged brief feeds INTO it (Step 5),
  but `merged_brief.md` itself is provenance, not canon.
- **FR-024** — opt-in. `/plan` (no flag) MUST run the normal single-model
  pipeline. `--ultra` is the only trigger. plan-audit downstream is
  unchanged; the ONE pro-max deviation is the executor (GLM via `glm-exec`
  replaces M3 under `--ultra` — STEP 7). Normal `/plan` keeps the M3 default.
- **FR-025** — recon BEFORE freeze. When the spec references an existing
  codebase (extends/modifies/builds-on a shipped CLI/service/test-suite),
  the orchestrator MUST read the real named files and reconcile the spec
  against reality (correct wrong facts, label net-new vs existing, run the
  real test count) BEFORE freezing — so the blind panelists plan over a TRUE
  WHAT. Greenfield specs skip it. Recorded in `ultraplan/recon.md`. See STEP 1.3.
  Defense-in-depth: the judge (STEP 3) re-checks the merged brief against
  `recon.md` and corrects any reality drift the panels reintroduced.

## Non-interactive auto-gate mode (`TG_ULTRAPLAN_AUTO_GATE`)

When the environment variable `TG_ULTRAPLAN_AUTO_GATE=1` is set (the Telegram
daemon sets it for `!ultraplan` / `/plan --ultra` on the async chat surface),
the two **human gates** run AUTOMATICALLY and never block for input. Everything
else is unchanged — freeze-once (FR-017), 4 blind planners at per-model effort (opus xhigh / gpt high / minimax deep / glm deep, FR-022), judge
select-and-graft (FR-019), the **≥2-planner hard floor** (STEP 2), and the full
provenance trail (FR-023) all still apply:

- **STEP 4 (brief acceptance)** → auto-ACCEPT the merged brief; record the
  auto-acceptance in the provenance trail; proceed to STEP 5.
- **STEP 6.2 (dropped-decisions)** → auto-RECORD every dropped/grafted decision
  with its classification (`signed_off` / `recorded_with_warnings`) to
  `dropped_decisions.md` + the trail; proceed.
- **Hard-stops still fire** (never silently emit a degenerate plan): a FATAL
  fidelity conflict against the frozen spec, or planner quorum < 2 — STOP with a
  clear message.

Final chat-facing output in this mode: the merged brief + a short plan summary +
the provenance-trail path + a count of auto-recorded/dropped decisions (surface
the gates that were auto-applied — do not silently rubber-stamp).

## Locating the bundle

```bash
# ultraplan lives at ~/.claude/skills/ultraplan (or the dev mirror
# at ~/dev/fuse/skills/ultraplan). The fuse engine it wraps is a sibling
# skill. Resolve either via the installed location or the dev mirror.
SKILL_DIR="<this skill's base directory>"   # harness prints this on load

# Prefer the installed fuse first, fall back to the dev mirror.
if [[ -d "${HOME}/.claude/skills/fuse/scripts" ]]; then
    FUSE_SCRIPTS_DIR="${HOME}/.claude/skills/fuse/scripts"
    FUSE_REFS_DIR="${HOME}/.claude/skills/fuse/references"
else
    FUSE_SCRIPTS_DIR="${SKILL_DIR}/../fuse/scripts"
    FUSE_REFS_DIR="${SKILL_DIR}/../fuse/references"
fi
```

## STEP 0 — Gate (opt-in, expensive)

ultraplan costs ~5× a normal plan (4 planners + judge + formalize). Refuse
quietly: if the feature is a routine change, single-file fix, refactor
with clear scope, or anything the normal `/plan` handles cleanly, tell the
user:

> "This looks routine — normal `/plan` will be faster and cheaper. Use
> `/plan --ultra` only for contested architecture choices, greenfield
> designs, or plans where a confidently-wrong single planner would set a
> bad spec. Continue with `--ultra` anyway?"

If they confirm (or the request is unmistakably high-stakes: a new
multi-system feature, a security redesign, a contested migration),
proceed. Record `ultraplan_justification=<reason>` in the run record.

## STEP 1 — Specify ONCE, freeze the spec

Run the normal specify + clarify pipeline **exactly once** via the Skill
tool (don't paraphrase from memory):

1. `speckit-specify` → `spec.md` (user stories, FRs, success criteria).
2. `speckit-clarify` — only if `spec.md` still has `[NEEDS CLARIFICATION]`
   markers AND the user is available. Otherwise resolve with the
   reasonable call + record the assumption. (No-clarifying-questions
   rule, per `plan` skill.)

### 1.3 — Codebase recon BEFORE freeze (FR-025) — CONDITIONAL, but MANDATORY when the spec extends existing code

**Why this exists:** the panels plan BLIND from the spec (that is what makes them
diverse). So any false premise the spec encodes about an existing codebase —
wrong test count, a command signature that doesn't exist, a server that can't do
what the spec assumes, a token/auth model that differs — is inherited by all 3
planners AND survives the STEP-6 fidelity check (FR-021), which compares the
merged brief against the formalized plan (brief-vs-plan), never against the real
code (brief-vs-reality). No ultraplan stage reads the target code. The result is a
confidently-wrong frozen spec. (This is exactly what happened on `016-design-studio-v2`:
"28/28 tests" was 29; "extend bin/studio" hid a net-new generator, a 405-static
server, and a global-token-vs-tier collision — none caught until a manual post-freeze
audit.) Recon-before-freeze is the structural fix: reconcile the spec with reality
so the planners argue over a TRUE WHAT.

**Trigger detection.** Scan `spec.md` + the originating prompt for references to an
existing codebase: named paths (`~/foo`, repo dirs), "extend/modify/build on X",
"existing", a shipped CLI/service/test-suite, version/test-count claims. 
- **No such reference → greenfield → SKIP recon.** Record `recon: skipped (greenfield)`
  in the provenance and proceed straight to the freeze.
- **Any such reference → run recon (below) before freezing.**

**Recon procedure (orchestrator is already Opus — do it inline; for a large surface,
fan read-only `Explore`/recon subagents):**
1. **Read the real named files** — the actual CLI/dispatch, the server, the auth/token
   path, the data/artifact model, and run the real **test count** (`pytest --collect-only`
   / equivalent). Do NOT trust the spec's description of them.
2. **Diff spec claims vs reality.** For every load-bearing assertion the spec makes
   about the existing code, confirm it against bytes. Classify each: *accurate* /
   *wrong (spec says X, code is Y)* / *net-new mislabelled "extend"*.
3. **Reconcile the spec IN PLACE** — fix wrong facts, label net-new vs existing,
   add any reality-forced invariant the spec missed. Genuine design choices (not
   factual errors) are left but flagged for the planners.
4. **Write `specs/NNN-slug/ultraplan/recon.md`** — the read facts + every correction
   (file:line evidence). This is provenance (non-authoritative, FR-023).
5. Only THEN freeze (below). The frozen spec is the **reconciled** one.

If recon surfaces a contradiction you cannot resolve from the code alone (a real
design ambiguity), take it to the user at STEP 1 — do not freeze over it.

**Freeze the spec.** Write the final (reconciled) spec text to
`specs/NNN-slug/ultraplan/spec.frozen.md` and capture its SHA256. That
file is the single source of truth fanned to every panelist — its bytes
ARE the prompt for STEP 2.

```bash
spec_dir="specs/$(ls specs/ | grep -E '^[0-9]{3}-' | sort | tail -1)"
mkdir -p "${spec_dir}/ultraplan"
cp "${spec_dir}/spec.md" "${spec_dir}/ultraplan/spec.frozen.md"
sha256sum "${spec_dir}/ultraplan/spec.frozen.md" \
    | tee "${spec_dir}/ultraplan/spec.frozen.sha256"
```

**Do not** paraphrase, summarize, or reformat the frozen spec when
fanning it out. The whole point of freezing is that all planners argue
over the same WHAT. If a planner says "the spec is unclear about X", the
fix is to go back to STEP 1 with the user — NOT to loosen the freeze
mid-fan-out.

## STEP 2 — Fan the FROZEN SPEC to 4 blind planners

Reuse the fuse engine. Each panelist gets the **frozen spec** as the
verbatim prompt, with a thin instruction header that constrains output
shape (no speckit artifacts, free-form plan brief, effort = high):

```bash
prompt_file="${scratch}/prompt.txt"
{
    echo "You are one of four blind planners. Produce a free-form PLAN"
    echo "BRIEF (architecture, approach, phased breakdown, risks, files"
    echo "touched, test strategy). DO NOT produce spec.md / plan.md /"
    echo "tasks.md / task lists / GATE tasks — those are generated later."
    echo "DO NOT propose speckit artifacts. Output = plan brief only."
    echo
    echo "--- FROZEN SPEC (do not modify, do not summarize back) ---"
    cat "${spec_dir}/ultraplan/spec.frozen.md"
    echo
    echo "--- END FROZEN SPEC ---"
} > "${prompt_file}"
```

Detect the panel (reuse fuse's detector) and launch all participating
runners **in the same assistant turn** (parallel + blind, FR-002):

```bash
# Detect panel (same as fuse STEP 0). Only the SLUG= line is machine-readable;
# the other lines are human-readable status, so extract SLUG, do NOT eval the
# whole output.
SLUG="$(bash "${FUSE_SCRIPTS_DIR}/detect_panel.sh" | sed -n 's/^SLUG=//p')"
echo "ultraplan panel slug: ${SLUG:-unknown}"

# Resolve output paths (absolute — mktemp is already absolute)
opus_out="${scratch}/brief_opus.txt"
gpt_out="${scratch}/brief_gpt.txt"
minimax_out="${scratch}/brief_minimax.txt"
glm_out="${scratch}/brief_glm.txt"

# Per-planner effort (FR-022) — each model gets the top of ITS OWN ladder
# that is still BELOW max (Principle V: never max on planners):
#   opus    = xhigh  (one rung under max; NOT max)
#   gpt-5.5 = high   (codex caps at high — no xhigh exists; xhigh would fall back to high anyway)
#   minimax = deep   (M3's thinking mode = --deep/32k; passing "high" here SILENTLY DROPS --deep
#                     → shallow. "deep" is the correct top-effort token for run_minimax.sh.)
#   glm-5.2 = deep   (z.ai, 32k thinking via run_glm.sh; a non-"deep" effort drops to a 10k budget)
bash "${FUSE_SCRIPTS_DIR}/run_opus.sh"    "${prompt_file}" "${opus_out}"    xhigh
bash "${FUSE_SCRIPTS_DIR}/run_gpt.sh"     "${prompt_file}" "${gpt_out}"     high
bash "${FUSE_SCRIPTS_DIR}/run_minimax.sh" "${prompt_file}" "${minimax_out}" deep
bash "${FUSE_SCRIPTS_DIR}/run_glm.sh"     "${prompt_file}" "${glm_out}"     deep
```

Reuse the fuse runner contract verbatim: `run_*.sh <prompt> <out> [effort]`,
exit codes (0 ok / 127 missing → drop / 64-65 usage / 1 errored →
absent). Apply FR-011: a dropped or errored panelist is **never** a
concurring vote. With 4 panelists fanned to 4, you can absorb at most
2 drops; if 3+ are absent (fewer than 2 returned), **STOP and warn**:

> "Only N/4 planners returned — ultraplan needs ≥2 to add value over a
> single plan. Continue with reduced panel, or abort and re-run normal
> `/plan`?"

Persist each returned brief to the provenance trail:

```bash
cp "${opus_out}"    "${spec_dir}/ultraplan/panel_opus.md"
cp "${gpt_out}"     "${spec_dir}/ultraplan/panel_gpt.md"
cp "${minimax_out}" "${spec_dir}/ultraplan/panel_minimax.md"
cp "${glm_out}"     "${spec_dir}/ultraplan/panel_glm.md"
```

The trail is the audit-trail, not the deliverable. It is
non-authoritative (FR-023) — `plan-audit` ignores this directory.

## STEP 3 — Judge (Opus @ultracode): select-and-graft

You are the judge. You did not author any brief. Read every present
brief **fresh** in this turn. Apply the `plan` task-class rules from
`${FUSE_REFS_DIR}/judge_rubric.md` (T037 added these):

1. **Classify**: `task_class = plan` (Track-B subtype — research-shaped
   output, not a runnable artifact). No code execution, no Track A.
2. **Mode = select-and-graft** (FR-019). Default. Read the rubric for
   the full rule, but the spine of it:
   - Pick the **soundest architecture** as the spine.
   - Graft only **non-conflicting** improvements from the other briefs
     (test strategy additions, risk-callouts, alternative file layouts
     that compose with the spine).
   - **Incompatible architectures force outright selection** — pick one
     spine, drop the conflicting alternative, do NOT try to do both.
     A plan that mixes two architectures is a chimera and is worse than
     either alone.
3. **Brief format**: the merged brief is a **plan brief** (free-form,
   FR-018), NOT a speckit artifact. It has the same shape as a single
   panelist's brief — architecture, phased breakdown, files touched,
   risks, test strategy — only better. **No `plan.md` / `tasks.md` /
   GATE tasks** in this output. Structure comes later from `plan`.
4. **Attribution (FR-010)**: every architectural decision / risk-callout
   / test-strategy choice in the merged brief carries an inline tag
   `[opus]` / `[gpt]` / `[minimax]` / `[glm]` / `[opus+gpt]` etc. A claim with no
   source is a bug.
5. **Reality re-check (FR-025 defense-in-depth).** If `ultraplan/recon.md`
   exists (the spec extended existing code), read it and verify the merged
   brief does not REINTRODUCE any reality drift the panels may have carried
   (a panel can still assume a thing the recon corrected, since panels reason
   freely). For every brief claim about the existing code, confirm it against
   `recon.md`; correct any drift IN the brief and tag the correction
   `[recon]`. The merged brief must be true-to-code, not just true-to-spec.

Write the merged brief to:

```bash
# Judge emits the brief; orchestrator persists it as canonical input
# to the plan formalization step.
merged_brief_path="${spec_dir}/ultraplan/merged_brief.md"
# (write the judge's merged brief to "${merged_brief_path}")
```

Persist attribution metadata alongside:

```bash
cat > "${spec_dir}/ultraplan/judge_attribution.json" <<EOF
{
  "spine": "<opus|gpt|minimax|glm>",
  "grafts": [
    {"from": "<panelist>", "item": "<one-line>", "section": "<where>"}
  ],
  "rejected": [
    {"panelist": "<x>", "reason": "<architecture conflict / weaker spine / etc.>"}
  ],
  "absent": [
    {"panelist": "<x>", "reason": "<127|errored|empty>", "how_to_enable": "..."}
  ]
}
EOF
```

## STEP 4 — Human gate (brief acceptance)

Present the merged brief to the user for approval. The brief is the
**single most important checkpoint** in ultraplan — the human can:

- Approve as-is → STEP 5 formalizes.
- Edit / annotate → update `merged_brief.md` (the canonical input to
  `plan`), re-record SHA256, then STEP 5.
- Reject → abort. The user can re-run with a different panel subset,
  different effort, or fall back to normal `/plan`.

**Auto-gate (`TG_ULTRAPLAN_AUTO_GATE=1`):** do NOT present or block — auto-accept
the merged brief, record the auto-acceptance in the provenance trail, and proceed
to STEP 5.

**Fidelity check (FR-021) lives in STEP 6**, not here. ultraplan's own
gate here is only for **brief acceptance**; the fidelity warning +
final plan approval is the gate in STEP 6, which fires AFTER the
normal `plan` pipeline has derived `plan.md` / `tasks.md` /
`analyze.md` from the brief.

## STEP 5 — Hand to the normal `plan` pipeline

The merged brief is now `research.md` (canonical). Run the normal `plan`
skill from **Step 1.3 onwards** (Step 1.1 specify + Step 1.2 clarify
already happened in STEP 1):

```bash
# Promote merged_brief.md to research.md so the normal plan pipeline
# can copy/derive spec.md, plan.md, tasks.md from it (per plan Step 3).
cp "${spec_dir}/ultraplan/merged_brief.md" "${spec_dir}/research.md"
# (Banner the original prompt file with a MOVED pointer per plan Step 3
# if one exists; ultraplan does not have one, so this is a no-op.)
```

Then invoke `plan` normally. The plan skill will:

1. `speckit-plan` → derive `plan.md` from the frozen spec + `research.md`.
2. `speckit-tasks` → derive `tasks.md` AND **inject GATE tasks** (clean-code-guard
   / test-guard / docs-guard / etc.) per `plan` Step 2. **These are the
   ONLY GATE tasks in the deliverable** — panelists and judge did not
   emit any (FR-020).
3. `speckit-analyze` → fix any cross-artifact drift.
4. Stop with `plan.md` + `tasks.md` + `analyze.md` materialized.

Do NOT have `plan` stop at its own human gate (Step 4) before STEP 6
runs — the fidelity check is a real diff over those artifacts and
needs them on disk. Invoke `plan` end-to-end (Steps 1.3 → 2 → 3), then
hand off to STEP 6.

ultraplan has produced a brief and the normal `plan` skill has
formalized it. Do not re-run `plan` from Step 0 — STEP 6 runs next,
not a re-invocation.

## STEP 6 — Fidelity check (FR-021) + provenance finalization (FR-023)

This is the **second human gate** in ultraplan — and the last one before
execution. It runs AFTER the normal `plan` pipeline has materialized
`plan.md` / `tasks.md` / `analyze.md` from the merged brief, and BEFORE
`m3-worker` starts. Two things happen here, in order:

### 6.1 — Fidelity check (FR-021)

Diff the **derived** artifacts against the **merged brief** and surface
any judge-decision that got DROPPED in speckit formalization. The
formalizer (speckit-plan / speckit-tasks) is mechanical and will happily
drop a hand-picked insight from the brief if no template field fits it.
The judge (Opus) is the part that did the actual selection-and-grafting,
so the merge's BEST ideas are exactly the ones most likely to die here.
Catch them before the user signs off.

```bash
brief="${spec_dir}/ultraplan/merged_brief.md"
plan_md="${spec_dir}/plan.md"
tasks_md="${spec_dir}/tasks.md"

# 1. Extract every attributed decision from the merged brief. The judge
#    tagged each with [opus] / [gpt] / [minimax] / [opus+gpt] etc. (FR-010).
grep -oE '\[(opus|gpt|minimax)([+]gpt|[+]minimax|[+]opus)*\]' "${brief}" \
    | sort -u > "${spec_dir}/ultraplan/attribution_tags.txt"

# 2. Walk every tagged decision and check survival. A decision "survives"
#    if a phrase derived from it appears in plan.md OR tasks.md (case-
#    insensitive substring match against the brief's own wording for that
#    decision). Anything that does not survive is a DROP.
#
#    Output: specs/NNN/ultraplan/dropped_decisions.md, one bullet per drop
#    with: tag, decision text (one line from the brief), and a hint about
#    WHERE in plan.md / tasks.md it might re-incorporate (e.g. as a new
#    task, an expanded risk row, an additional file-touch list).
```

**Two classes of drop are HIGH-PRIORITY** (flag with `!! ` in the report):

- **UNIQUE INSIGHTS** — a decision attributed to a single panelist
  (e.g. `[minimax]`, `[opus]`, `[gpt]`, `[glm]` alone) that did not survive.
  The whole point of fanning to 4 planners was to surface ideas one
  planner would miss. Losing one of those to the formalizer is
  unforgivable.
- **BLIND-SPOT items** — risks, edge cases, or test-strategy points
  raised by exactly one panelist that the other two ignored. The judge
  chose to keep them deliberately; do not let `speckit-tasks` swallow
  them.

Multi-panelist decisions (`[opus+gpt]`, etc.) that drop are lower
priority — they had corroboration, and a drop there is more likely a
deliberate simplification than a formalizer bug.

### 6.2 — Human gate: dropped-decisions list

**STOP HERE** (interactive mode). Do not proceed to STEP 7 until the user has
signed off on the dropped-decisions list. **Auto-gate
(`TG_ULTRAPLAN_AUTO_GATE=1`):** do NOT stop — auto-record every drop with its
classification (`signed_off` / `recorded_with_warnings`) to `dropped_decisions.md`
+ the trail and proceed to STEP 7; a FATAL fidelity conflict against the frozen
spec or planner quorum < 2 still hard-stops with a clear message. Present the
report:

> **Fidelity check (FR-021) — N decisions dropped from merged brief:**
>
> 1. `!! [minimax] use advisory file-locks over flock for concurrent judge runs`
>    — no match in plan.md / tasks.md. (Re-incorporate as new task under
>    Phase 2, or consciously drop.)
> 2. `!! [gpt] risk: 3-min timeout on `mm --deep` is tight for 3-call probe`
>    — present in plan.md risk table but not propagated to a verification
>    step in tasks.md. (Add as explicit gate, or consciously drop.)
> 3. `[opus+gpt] phased rollout behind `--canary` flag` — no match.
>    (Lower priority: two-panelist agreement, likely deliberate cut.)
> ...
>
> Approve: re-incorporate, consciously drop, or hand-edit tasks.md?

The user picks one of three actions for each `!!` item:
- **Re-incorporate** → edit `tasks.md` (or `plan.md`) directly, re-run
  the formalizer's analyze step if the diff is non-trivial, then re-run
  the fidelity check. Repeat until clean.
- **Consciously drop** → record the decision in
  `specs/NNN/ultraplan/dropped_decisions.md` with a one-line rationale
  (why we accept the loss: e.g. "out of MVP scope per user", "covered
  by existing task X", "judge misjudged"). This is the audit trail of
  consciously-dropped items — it goes in the provenance dir, not in
  the canonical plan.
- **Hand-edit** → user makes the call themselves and the orchestrator
  updates the artifacts.

Lower-priority drops (multi-panelist) can be batched as a single
"consciously drop" line; the user does not need to rule on each one.

### 6.3 — Provenance trail finalization (FR-023)

After the fidelity gate is signed off, the provenance trail under
`specs/NNN-slug/ultraplan/` MUST be complete. Verify the full list and
write the manifest:

```
specs/NNN-slug/ultraplan/
├── spec.frozen.md          # bytes fanned to all planners (Step 1)
├── spec.frozen.sha256      # hash of the above (Step 1)
├── panel_opus.md           # raw Opus brief (Step 2)
├── panel_gpt.md            # raw GPT-5.5 brief (Step 2)
├── panel_minimax.md        # raw MiniMax M3 brief (Step 2)
├── panel_glm.md            # raw GLM-5.2 brief (Step 2)
├── merged_brief.md         # judge output (Step 3) — promoted to research.md
├── judge_attribution.json  # spine + grafts + rejections + absent (Step 3)
├── attribution_tags.txt    # extracted [opus]/[gpt]/[minimax] tags (Step 6.1)
├── dropped_decisions.md    # fidelity-check report + conscious drops (Step 6.2)
└── PROVENANCE.md           # this manifest + exclusion notice (Step 6.3)
```

`PROVENANCE.md` is a one-pager that says, in plain text:

> This directory is the **non-authoritative** provenance trail for the
> ultraplan run on this spec (FR-023). It is intentionally **excluded**
> from `plan-audit`, which audits only the merged artifacts
> (`spec.md`, `research.md`, `plan.md`, `tasks.md`, `analyze.md`)
> directly under `specs/NNN-slug/`.
>
> Why: the briefs are evidence-of-why, not evidence-of-what. The
> canonical Phase-0 artifact is `research.md` (= `merged_brief.md`,
> promoted in Step 5). The briefs are the audit trail of how the
> canonical artifact came to be; they are not themselves part of the
> plan. Scoring them in `plan-audit` would conflate "the judge's
> reasoning" with "the formalized plan's conformance" — they answer
> different questions.
>
> Path filter: `plan-audit` scans `specs/NNN-slug/{spec,research,plan,
> tasks,analyze}.md`. `ultraplan/` is a sibling directory and is never
> scanned.

Write it as a real file so that anyone landing in that directory —
human or auditor — sees the exclusion notice before reading the briefs:

```bash
# Verify all expected files exist; abort if any are missing — that is a
# provenance gap and a FR-023 violation.
for f in spec.frozen.md spec.frozen.sha256 \
         panel_opus.md panel_gpt.md panel_minimax.md panel_glm.md \
         merged_brief.md judge_attribution.json \
         attribution_tags.txt dropped_decisions.md; do
    [[ -s "${spec_dir}/ultraplan/${f}" ]] || {
        echo "PROVENANCE GAP: ${spec_dir}/ultraplan/${f} missing or empty" >&2
        exit 1
    }
done

# Write the manifest / exclusion notice.
cat > "${spec_dir}/ultraplan/PROVENANCE.md" <<'EOF'
# Provenance trail — ultraplan (non-authoritative, FR-023)
...
EOF
```

### 6.4 — research.md canonicality reminder

`research.md` (under `specs/NNN-slug/`, NOT under `ultraplan/`) is the
**canonical Phase-0 artifact** the rest of the pipeline reads from. It
was created in Step 5 by `cp merged_brief.md research.md`. The
`merged_brief.md` copy in `ultraplan/` is provenance, not canon — both
files have the same bytes at the moment of the copy, but
`plan-audit`, `m3-worker`, and the constitution check all read
`research.md` (or `plan.md` / `tasks.md` derived from it), never
`ultraplan/merged_brief.md`. If the user hand-edits the brief in
Step 4, re-run the `cp` after re-recording the SHA256 so
`research.md` is the current copy.

## STEP 7 — EXECUTOR (pro-max) + audit

After STEP 6 sign-off, **audit** is byte-for-byte the same as any other
plan; **execution** is the one pro-max deviation from FR-024:

- **EXECUTION → GLM-5.2-deep via `glm-exec` (replaces MiniMax-M3 / `mm-exec`).**
  Run each implementation task through `glm-exec` exactly as the `m3-worker`
  loop would use `mm-exec` — same role rule (Claude plans + audits, the worker
  executes), same per-task receipt, same fail-loud discipline:
  ```bash
  glm-exec --receipt-dir specs/NNN/.worker-receipts --task-id T0xx \
      "Execute T0xx: <task text + the files/context it needs>"
  ```
  `glm-exec` carries a DESIGN-TASTE MANDATE in its worker preamble: any task
  touching frontend/UI code MUST apply `design-taste-frontend`,
  `emil-design-eng`, and `impeccable` (non-UI tasks are exempt). The GLM key
  is read per-invocation from `~/.config/glm.env`; never echo it, never set a
  global `ANTHROPIC_BASE_URL`. On an audit FAIL, do NOT auto-re-dispatch — get
  operator approval first (runaway-spend guard). The Telegram `!work` surface
  still uses M3; the GLM executor is the `--ultra` pro-max path. (Normal
  `/plan` execution keeps the M3 default per CLAUDE.md.)
- **AUDIT — opus, unchanged.** `plan-audit` audits the **merged artifacts** under `specs/NNN/` —
  spec.md, research.md (= merged brief), plan.md, tasks.md, analyze.md.
- The provenance trail at `specs/NNN/ultraplan/` is **excluded** from
  `plan-audit` (FR-023). `plan-audit`'s path filter is
  `specs/NNN/{spec,plan,tasks,analyze,research}.md` — `ultraplan/` is
  a sibling directory and is never scanned. The exclusion is also
  stated explicitly in `ultraplan/PROVENANCE.md` (Step 6.3) for any
  auditor who lands in the directory.

## What to read on every `/plan --ultra`

- `~/.claude/skills/fuse/SKILL.md` — the engine this wraps (fan-out,
  judge, present). Read the contract once.
- `~/.claude/skills/fuse/references/judge_rubric.md` — the `plan`
  task-class rules added by T037. **Read fully** before STEP 3.
- `~/.claude/skills/plan/SKILL.md` — the pipeline STEP 5 hands off to.
  Skim once so you know what `plan` expects at handoff.
- `specs/NNN-slug/ultraplan/PROVENANCE.md` (when one exists) — the
  manifest + exclusion notice for the run's provenance trail. Read it
  before STEP 6 so you know what is and is not auditable.
- The runner scripts under `~/.claude/skills/fuse/scripts/` — only if
  a runner misbehaves; the contract is `run_*.sh <prompt> <out>
  [effort]`. The ultraplan contract with each runner overrides only the
  effort default, per model: opus `xhigh` (vs runner default `max`),
  gpt `high` (vs `high`), minimax `deep` (vs `deep`), glm `deep` (32k) — i.e.
  top-of-ladder below max for each.

## Red flags — stop and restart this skill

- "I'll just run 4 planners inline in chat" → use the fuse runners; FR-002
  + FR-022 (effort override) require the runner contract.
- "Spec needs one more pass" → freeze it (STEP 1) before fanning. If it
  really needs more, abort, re-run normal `plan`, then re-invoke `--ultra`.
- "The judge will also write the plan.md" → no. The judge writes a brief
  (FR-018). `plan.md` is for `plan` to derive.
- "Let me add a GATE task from the planner" → no. GATE tasks are injected
  by `plan` Step 2 (FR-020).
- "ultraplan-audit should also grade the briefs" → no. Trail is
  non-authoritative (FR-023); `plan-audit` reads merged artifacts only.
- "Skip the fidelity check, the brief was thorough" → no. FR-021 fires
  in STEP 6, not in STEP 4 brief acceptance, and not in the user's
  good-faith. The formalizer is mechanical and WILL drop judge-decisions
  that don't fit its template. The check is a real diff over
  `plan.md` / `tasks.md` after Step 5; skipping it is a silent-loss bug.
- "Conscious drops don't need to be recorded" → record them in
  `ultraplan/dropped_decisions.md` anyway. The audit trail of WHY a
  unique insight was dropped is more valuable than the insight itself
  once execution starts.
