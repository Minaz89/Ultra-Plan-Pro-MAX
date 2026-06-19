# Ultra Plan Pro MAX

> Sanitized distribution of the **ultraplan** planning feature and its **fuse** panel→judge engine.
> User paths are generalized to `$HOME`; no credentials are bundled (keys are read at runtime from the environment / local key files). The `fuse` and `ultraplan` skill identifiers are unchanged — they are the functional skill names this bundle installs.

The two skills:

- **`ultraplan`** (`/plan --ultra`) — specify-once → freeze spec → 4 blind planners → Opus judge select-and-graft → human gate → formalize → fidelity check. Includes the FR-025 recon-before-freeze gate.
- **`fuse`** (`/fuse`) — the underlying panel→judge engine documented below.

---

# fuse

> **One verbatim prompt → parallel, blind 4-model panel → Opus judge selects or merges.**
>
> Modeled on [github.com/duolahypercho/fusion-fable](https://github.com/duolahypercho/fusion-fable). Reference mechanism: synthesizing *independent* answers (even two runs of the same model) beats a single run (DRACO deep-research finding). `fuse` adapts that to a heterogeneous panel.

Designed for **high-stakes questions** where the cost of being wrong is worse than the cost of being slow: architecture, security reviews, irreversible ops, contested design decisions. Do not reach for it on a trivial prompt.

---

## 1. What it is

`fuse` is a Claude Code **skill** + **slash-command** bundle. When you invoke `/fuse "<question>"`, the orchestrator (the Opus session you're talking to) does four things:

1. **Detect** which backends are available right now.
2. **Fan out** the prompt to a parallel, blind panel — each model sees the same verbatim text, none sees another's answer.
3. **Judge** the returned answers at `ultracode` effort: pick the one best answer, *or* merge them into one new deliverable.
4. **Present** the final answer first, then an attributed audit trail, panel line, and cost/latency note.

No assigned personas. No lenses. No "you are a security expert" wrapper. Diversity comes from different model weights + training data, not from scripted roles — a panel with assigned roles collapses into N rephrasings of one answer (anchoring).

---

## 2. The panel

| Role      | Model       | Effort       | Runner             | Backend                                           |
|-----------|-------------|--------------|--------------------|---------------------------------------------------|
| Panelist  | Opus 4.8    | `xhigh`      | `run_opus.sh`      | `claude -p --model claude-opus-4-8`               |
| Panelist  | GPT-5.5     | `high`       | `run_gpt.sh`       | `codex exec -s read-only`                         |
| Panelist  | MiniMax M3  | `deep`       | `run_minimax.sh`   | `mm --deep -p` (→ `claude -p --model MiniMax-M3`) |
| Panelist  | GLM-5.2     | `deep` (32k) | `run_glm.sh`       | `claude -p` repointed at z.ai (Anthropic-compat)  |
| **Judge** | **Opus 4.8**| **`ultracode`** | orchestrator-self | the same Opus session, runnning `fuse`            |

GLM-5.2 (Zhipu) runs through the **same local `claude` binary** as Opus, with the env scoped per-invocation to z.ai's Anthropic-compatible endpoint (`ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`, auth from `~/.config/glm.env`, 32k thinking). The key is sourced into the invocation only and never echoed — same secret-safety contract as every other runner (§10). The same engine powers `ultraplan`'s 4-planner panel under `/plan --ultra`, where GLM-5.2-deep is also the **executor** (Opus still judges + audits).

The **judge is the orchestrator**. You are the Opus session that loaded the skill; the judge step is *that* session, not a separate model. The skill's SKILL.md documents the seam: if you are not already on Opus, the judge step can shell out via `run_opus.sh … ultracode` and read the verdict back. The verification question is *"did the verdict come from an Opus 4.8 @ultracode pass?"*.

GPT-5.5 is read-only (`-s read-only`) on purpose: a blind panelist ANSWERS the prompt — it must not edit a workspace (that's the judge's job on Track A). Read-only also stops codex from going agentic on plain Q&A.

Every panelist is a **literal separate process** via its runner script — never an in-process subagent. That is what guarantees Opus is Opus regardless of what model the caller is running (Constitution III).

---

## 3. Install

```bash
bash install.sh
```

The installer:

- Resolves its own location (cwd doesn't matter).
- Validates the source tree first, then copies the bundle into `~/.claude/skills/fuse/` and `~/.claude/commands/`.
- `chmod +x` every `*.sh` under the installed `scripts/` (idempotent).
- Runs `detect_panel.sh` from the *installed* path and prints the panel availability so you can see exactly which panelists will fire.

Override the destination via `CLAUDE_CONFIG_DIR`:

```bash
CLAUDE_CONFIG_DIR=/path/to/other/.claude bash install.sh
```

Idempotent — safe to re-run. Never deletes files at the target that aren't part of this bundle. Never reads or echoes any credential.

---

## 4. Commands

| Command                       | What it does                                                                                             |
|-------------------------------|----------------------------------------------------------------------------------------------------------|
| `/fuse "<prompt>"`            | Auto-detects the richest available panel and fans to whatever's up; missing backends drop gracefully (named in the audit, FR-011). |
| `/fuse-pick "<prompt>"`       | Same fan-out, but pins `pin_mode=select`. The judge picks **one** best answer outright, no merging, no Track B five-section synthesis. |
| `/fuse-opus-gpt-minimax "<p>"`| Pins the panel to **all three** runners every time. If a backend is down, it surfaces that in the audit (with how-to-enable) rather than silently dropping the panelist — a downgraded run breaks the pin the user asked for. |

All three commands:

- Pass the user's text **byte-for-byte** to the panel — no editing, no persona, no wrapping.
- Need the `Bash` (scratch dirs, prompt files, parallel runner fan-out), `Read`, and `Write` tools — don't narrow the skill's tool set.

---

## 5. How it works

**STEP 0 — Detect the panel.** Run `bash "${SKILL_DIR}/scripts/detect_panel.sh"`. Parse the `SLUG=...` line (machine-readable). The slug is **compositional** — `opus` is the spine and each available panelist appends its tag (`-gpt`, `-minimax`, `-glm`), so the richest panel is `opus-gpt-minimax-glm` and any subset is valid (`opus-gpt-minimax`, `opus-minimax`, `opus-glm`, `opus-only`, …). Pin overrides (the `/fuse-opus-gpt-minimax` command, or a `--panel` flag) skip detection.

**STEP 1 — Fan out parallel + blind.** `mktemp -d` a scratch dir + `trap ... EXIT` to clean it (caller-side — subshell traps fire too early). Write the verbatim prompt to `${scratch}/prompt.txt`. Launch every participating runner in **one assistant turn** with parallel `Bash` calls:

```bash
bash "${SKILL_DIR}/scripts/run_opus.sh"     "${scratch}/prompt.txt" "${scratch}/answer_opus.txt"     xhigh
bash "${SKILL_DIR}/scripts/run_gpt.sh"      "${scratch}/prompt.txt" "${scratch}/answer_gpt.txt"      high
bash "${SKILL_DIR}/scripts/run_minimax.sh"  "${scratch}/prompt.txt" "${scratch}/answer_minimax.txt"  deep
bash "${SKILL_DIR}/scripts/run_glm.sh"      "${scratch}/prompt.txt" "${scratch}/answer_glm.txt"      deep
```

Skip any panelist whose backend is missing (the detector told you which). Do not call the excluded runners — that would pollute the run with a phantom panelist.

**STEP 2 — Judge at `ultracode`.** Read every present answer file fresh in this turn. Classify the task → `artifact` (Track A: code/config/runnable-shaped) or `research` (Track B: prose-shaped). Pick the mode (`selection` or `combination`) — pinned modes from `/fuse-pick` win over defaults. Apply `references/judge_rubric.md`:

- **Track A** — merge to one complete runnable artifact. Run it. `verified: ran-ok` or `verified: unverified` (with the reason). Never claim a run that didn't happen.
- **Track B** — five attributed sections: consensus, contradictions, partial coverage, unique insights, blind spots — then a grounded final answer (not a fifth summary).

Every claim gets an inline `[opus]` / `[gpt]` / `[minimax]` / `[glm]` / `[opus+gpt]` tag. A claim with no source is a bug (FR-010).

**STEP 3 + 4 — Deliverable, audit, panel line, cost note.** Final answer first, always (FR-015 — never bury the answer under the analysis). Then the attributed audit. Then the **panel line**:

```
panel: <slug> | ran: [<panelist>, ...] | dropped: [<name>: <reason>; enable: <how>, ...]
```

Then the **cost/latency block** (first-class, not an aside):

```
cost/latency:
  panelist_count: <N>
  cost_estimate:  ≈ N× a single answer
  wall_clock:     ≈ slowest panelist (parallel fan-out)
  per_panelist:   [opus: <Xs> | gpt: <Xs> | minimax: <Xs> | glm: <Xs>]
  effort_dials:   opus=<e> gpt=<e> minimax=<e> glm=<e>
  effort_note:    max/deep/high cost more than low; users override at their own spend
  reserve_for:    high-stakes questions (architecture, security, irreversible ops)
```

---

## 6. Selection vs combination

The judge has two first-class outcomes (FR-007); neither is a degenerate case of the other.

- **Selection** — one panelist's answer is clearly best. Emit that one answer outright + a short "why it beat the others" that names the specific strength AND what each rejected answer was missing. Losers are named in the audit, not pasted.
- **Combination** — answers are complementary, partial, or one fills another's blind spot. Merge into one new deliverable: Track A → one runnable artifact; Track B → five-section synthesis.

Defaults by task_class: `artifact` → combine, `research` → combine. `/fuse-pick` pins the mode. A pin always wins over the default (FR-012); the audit records it.

---

## 7. Graceful downgrade

A backend can be missing. Detect via the runner's exit code:

| Code | Meaning                          | Orchestrator action                                                        |
|------|----------------------------------|----------------------------------------------------------------------------|
| `0`  | OK, non-empty output             | Include in the panel.                                                      |
| `127`| Backend MISSING (CLI / key file) | **Drop** the panelist. Record a downgrade note + **how to enable it**.     |
| `1`  | Backend ran but errored / empty  | Treat as **absent** — never as a concurring vote (FR-011). Name it + fix.  |
| `64` | Usage error                      | Same as `1` — treat as absent.                                              |
| `65` | Prompt file unreadable           | Same as `1` — treat as absent.                                              |

**Absent ≠ agreement (FR-011, SC-004).** A dropped / errored / empty / timed-out panelist is **named** as a missing vote, never counted as a concurring one. Counting absence as agreement manufactures a fake consensus — that's a violation.

**Degenerate 1-panelist runs.** If only ONE panelist returned a real answer (the other two were dropped or errored), the run is **not a true fusion**. Flag it explicitly:

> `panel: opus-only | ran: [opus] | dropped: [gpt: ...; minimax: ...; glm: ...]`
> `WARNING: not a true fusion (1 panelist) — single-model answer, no cross-check.`

The single answer is still emitted, but it's labeled as a single-model answer. The user can re-run after restoring the missing backends to get a real fusion.

**How to enable each backend:**

| Backend | What's required | Fix when missing |
|---------|-----------------|------------------|
| Opus 4.8 | `claude` on PATH | `command -v claude`; install Claude Code CLI. |
| GPT-5.5  | `codex` executable | `command -v codex`; canonical path `$HOME/.npm-global/bin/codex`; override via `CODEX_BIN=/path/to/codex`. |
| MiniMax M3 | `mm` executable + key file | `mm` at `$HOME/.local/bin/mm` (override `MM_BIN`); key file `~/.config/minimax.env` (override `MINIMAX_ENV_FILE`); `mm` reads the key itself, the runner only checks `-e`. |
| GLM-5.2  | `claude` on PATH + key file | runs via the local `claude` binary (same as Opus); key file `~/.config/glm.env` (override `GLM_ENV_FILE`) holding `GLM_API_KEY` (+ optional `GLM_BASE_URL`/`GLM_MODEL`); the runner checks `-r` and sources it into the invocation only. |

---

## 8. Dials

Three independent dials, all defaulted, all overridable per-run (not session-wide):

1. **Panel composition** — which runners actually launch. Auto-detected by `SLUG`; overridable via `--panel opus,minimax` (e.g.) or "fuse this with opus and minimax only". The slug in the panel line reflects the **subset that actually ran**, not the auto-detected maximum.
2. **Per-panelist effort** — the **3rd positional arg** to each runner: `run_<backend>.sh <prompt_file> <output_file> [effort]`. Defaults: opus=`xhigh`, gpt=`high`, minimax=`deep`, glm=`deep` (32k thinking). Override per-runner (e.g. "opus on `max`, the rest on `low`"). Unknown values → `exit 64` → treat as absent (FR-011).
3. **Mode** — `select` vs `combine`. Pinned by `/fuse-pick select|combine` or `--pick`. A pin always wins over the default-by-task (FR-007 / FR-012).

If the user pinned none, defaults stand. Pin per-run, not session-wide.

---

## 9. Cost / latency

- **Panel cost ≈ N× a single answer** for N panelists that actually ran. Each panelist is a full separate model invocation.
- **Wall-clock = slowest panelist** (parallel fan-out, not sum-of-all). Opus, `mm`, and GLM default to a 900s timeout; GPT-5.5 (codex) defaults to 600s. Override via `OPUS_TIMEOUT` / `GPT_TIMEOUT` / `MM_TIMEOUT` / `GLM_TIMEOUT` env vars.
- **Effort scales cost.** `max` and `deep` and `high` all cost more than `low`. The cost/latency block in every verdict records what effort was passed so you can see what you paid for.
- **Reserve for high-stakes questions** — architecture, security, irreversible ops, contested design decisions. Don't reach for `/fuse` on a typo, a one-liner, or a prompt you can answer with a single shell lookup.

---

## 10. Secret safety

No backend credential ever appears in any prompt, output, log, or run receipt (FR-014, SC-007, Constitution IV).

- **No keys on argv.** `claude` / `codex` / `mm` read auth from their canonical files; runners never put a key on the command line. `run_glm.sh` sources `~/.config/glm.env` into the invocation only and carries the key as the per-command `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` env (both in the `safe_log` redaction set below) — never on argv, never echoed.
- **No keys in prompts.** Prompts are written to a per-run scratch dir (`mktemp -d -t fuse.<label>.XXXXXX`), isolated from the caller's repo, cleaned up by a caller-side `trap ... EXIT` (a subshell trap would fire too early and remove the dir before the parent could use it).
- **No keys in output.** `run_<backend>.sh` writes the **clean answer text** to `<output_file>` — the runner's diagnostics (`safe_log` lines) go to stderr and stay in the scratch dir (gone on EXIT).
- **No keys in logs.** `lib.sh: safe_log` redacts on the way to stderr:
  - any literal value of `$MINIMAX_API_KEY`, `$ANTHROPIC_API_KEY`, or `$ANTHROPIC_AUTH_TOKEN` if set in the environment
  - `sk-<token>` (OpenAI-style key shape, ≥8 chars)
  - `Bearer <token>` (Authorization header value, ≥8 chars)
  - each match replaced with `<redacted len=NN>` where NN is the byte length of the original.
- **Never `set` a global `ANTHROPIC_BASE_URL`.** All env scoping is per-invocation (a single command line). `mm` scopes its base-URL/key to the spawned `claude` child only.

The test `tests/test_no_secret_leak.sh` (T019) verifies all of this with adversarial stubs that try to leak fake secrets.

---

## 11. Constitution note

- **Constitution III (Anthropic via local `claude -p` only).** Enforced: `run_opus.sh` always invokes the LOCAL `claude` binary with `--model claude-opus-4-8`; never a direct Anthropic API call; never a global `ANTHROPIC_BASE_URL`; per-invocation env scoping only. `run_glm.sh` reuses the same local `claude` binary but **deliberately repoints** `ANTHROPIC_BASE_URL` to z.ai for its single invocation (GLM-5.2 is a distinct provider, opt-in) — still per-invocation scoping, never a global base URL, so the Anthropic path stays untouched.
- **Constitution V (effort caps).** **Justified deviation:** `max` and `ultracode` are the deliberate effort levels on the **local `claude -p` path** for this skill (Opus panelist + judge). This is the only place in the system where those effort levels are used, and only on the local `claude` binary, not via any gateway path. The deviation is recorded in the plan's Constitution Check and tracked in the run receipt.
- **Constitution IV (no credential leak).** Enforced by the secret-safety section above + `safe_log` redaction + scratch isolation.

---

## 12. Telegram (design note, NOT wired)

> **Stretch / T030 — deferred.** The `!fuse <prompt>` daemon prefix is **not** wired into `telegram-daemon/daemon.ts` yet. This section is a design note so a future PR can land the wiring without rediscovering the seams.

**Intended shape (when shipped):** `!fuse <prompt>` in the daemon would shell out to the same `run_*.sh` engine this skill uses — the bundle is engine-only and daemon-agnostic. The daemon stays Constitution-III-isolated: it does not parse or interpret the prompt; it just `exec`s `$HOME/.claude/skills/fuse/scripts/run_opus.sh …` (etc.) under the same per-run scratch isolation. The same `/fuse` slash-command front-end stays the primary interface; the Telegram prefix is a thin shim that reuses the engine.

**Why deferred:** shipping a daemon prefix that invokes the judge step (Opus @ultracode) without a clean seam for "the user is talking to an Opus session right now" is risky. The slash-command path inherits Opus from the Claude Code session automatically; the daemon path would need an explicit Opus shell-out. That wiring needs its own design pass and its own review, not a bolt-on.

When this lands: it lands as a follow-up spec (not T030 itself), with the daemon-side `classify()` ladder honored (CRON/PIN/CLASSIFY precedence — see `012-oc-bridge-mm-router`).

---

## 13. Tests

All tests are stubbed — **no live API spend**. Run with plain bash:

```bash
bash tests/test_runner_contract.sh   # T009 — runner stdin/output/exit contract
bash tests/test_detect_panel.sh      # T010 — SLUG logic across availability combos
bash tests/test_no_secret_leak.sh    # T019 — lib.sh safe_log + per-runner redaction
bash tests/test_downgrade.sh         # T020 — graceful downgrade on missing backends
```

Each script prints `PASS` / `FAIL` per assertion and exits non-zero on any failure. All four are green on the current `master` commit.

The runner-contract test covers six cases per runner: happy path, missing backend (→ 127), empty output (→ 1), usage error (→ 64), unreadable prompt (→ 65), and a regression for the relative-output-path fix (verifies the answer lands at the caller's cwd even when the runner `cd`s into scratch).

---

## Layout

```
fuse/
├── README.md                       # this file
├── LICENSE                         # MIT, 2026, mina
├── install.sh                      # bash install.sh
├── commands/
│   ├── fuse.md                     # /fuse              — auto-detect panel
│   ├── fuse-pick.md                # /fuse-pick         — pin mode=select
│   └── fuse-opus-gpt-minimax.md    # /fuse-opus-gpt-minimax — pin panel=full
├── skills/fuse/
│   ├── SKILL.md                    # the orchestrator contract (Claude reads this)
│   ├── references/
│   │   ├── panel.md                # why-blind-why-parallel rationale
│   │   └── judge_rubric.md         # Track A / Track B / mode / evidence rules
│   └── scripts/
│       ├── lib.sh                  # make_scratch / safe_log / with_timeout
│       ├── detect_panel.sh         # SLUG=... probe; always exit 0
│       ├── run_opus.sh             # contract: <prompt> <out> [effort]  → 0/64/65/127/1
│       ├── run_gpt.sh              # contract: <prompt> <out> [effort]  → 0/64/65/127/1
│       ├── run_minimax.sh          # contract: <prompt> <out> [effort]  → 0/64/65/127/1
│       └── run_glm.sh              # contract: <prompt> <out> [effort]  → 0/64/65/127/1
└── tests/
    ├── test_runner_contract.sh
    ├── test_detect_panel.sh
    ├── test_no_secret_leak.sh
    └── test_downgrade.sh
```

`SKILL.md` is the procedural contract the orchestrator follows. `references/panel.md` and `references/judge_rubric.md` are the rationale + the judge's operating manual. Runner headers document the exact exit codes and contract.

---

## See also

- `specs/014-fuse-panel-judge/plan.md` — the design spec; constitution check; FR-001..FR-024; T001..T042.
- `references/panel.md` — independence-then-synthesis rationale (cite: DRACO deep-research finding).
- `references/judge_rubric.md` — full Track A / Track B / mode / evidence / output-order rules.
- `github.com/duolahypercho/fusion-fable` — the upstream pattern `fuse` is modeled on.
