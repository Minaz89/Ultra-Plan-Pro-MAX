#!/usr/bin/env bash
# run_gpt.sh — GPT-5.5 panelist runner for fuse (T007).
#
# Contract (contracts/runner-contract.md):
#   run_gpt.sh <prompt_file> <output_file> [effort]
#
# Pluggable backend (research.md R3):
#   1) codex exec (preferred) — resolved via $CODEX_BIN → $HOME/.npm-global/bin/codex
#      → PATH 'codex'. If the resolved binary is executable, run codex exec inside a
#      make_scratch dir with the canonical R3 invocation, then extract the final
#      assistant message text from the codex output file to <output_file>.
#   2) telegram-daemon GPT-5.5 route — only if a documented entrypoint is exposed
#      ($FUSE_GPT_DAEMON_ROUTE). Per R3 the daemon path is answer-only (no panelist
#      bash/web tools), so this rung is a degraded fallback, never the primary.
#      No documented entrypoint exists today; the rung is dormant code.
#   3) exit 127 — orchestrator drops the panelist + downgrades (FR-011).
#
# Default effort "high" (maps to codex's `model_reasoning_effort=high`). 3rd arg
# overrides. Model is gpt-5.5 — codex's default; we never override, per the brief.
#
# Hard rules (Constitution IV, FR-014, SC-007):
#   - Auth: codex reads ~/.codex/auth.json itself. The runner MUST NEVER place
#     auth on argv, in env vars, in the prompt, in the output, or in any log.
#     This file is never read, sourced, or echoed by the runner.
#   - No other panelist's output may appear in this prompt (orchestrator-enforced).
#   - Run in an isolated scratch dir (mktemp -d + caller-side EXIT trap, FR-014).
#   - All diagnostics go through safe_log.
#   - codex reads its prompt from stdin (`codex exec - < "${prompt_file}"`),
#     so unlike the claude/mm runners it gets NO defensive `</dev/null`
#     (that would just be overridden by the prompt redirect). codex reads
#     the prompt then sees EOF — no tty/pipe-parent stdin block risk.
#
# Exit codes:
#   0   success, <output_file> non-empty
#   127 no GPT backend available (orchestrator drops panelist + downgrades)
#   64  usage error (bad arg count, bad effort)
#   65  prompt_file not readable
#   1   codex ran but produced empty / non-zero / unparseable output

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# --- Arg validation ---
if [[ $# -lt 2 || $# -gt 3 ]]; then
  safe_log "run_gpt: usage: run_gpt.sh <prompt_file> <output_file> [effort]"
  exit 64
fi

prompt_file="$1"
output_file="$2"
effort="${3:-high}"

# Effort must be a single safe word (it lands inside a codex `-c key=value` flag).
# Reject whitespace, quotes, or anything that could smuggle a second `-c` into
# the argv. Allowed: lowercase letter start, then [a-z0-9_-], max 16 chars.
# Codex accepts: low, medium, high, xhigh (per CODEX_EFFORTS in daemon.ts).
if [[ ! "${effort}" =~ ^[a-z][a-z0-9_-]{0,15}$ ]]; then
  safe_log "run_gpt: invalid effort '${effort}' (must match ^[a-z][a-z0-9_-]{0,15}$)"
  exit 64
fi

if [[ ! -r "${prompt_file}" ]]; then
  safe_log "run_gpt: prompt_file not readable: ${prompt_file}"
  exit 65
fi

# --- Resolve codex binary: $CODEX_BIN → $HOME/.npm-global/bin/codex → PATH. ---
# We never read auth.json — codex itself does that. We only resolve the path. ---
codex_bin=""
if [[ -n "${CODEX_BIN:-}" ]]; then
  codex_bin="${CODEX_BIN}"
elif [[ -x $HOME/.npm-global/bin/codex ]]; then
  codex_bin="$HOME/.npm-global/bin/codex"
else
  # `|| true` keeps `set -e` from exiting when codex is genuinely missing —
  # we want a non-fatal absence here so the fallback rung can run.
  codex_bin="$(command -v codex 2>/dev/null || true)"
fi

# --- Backend dispatch: rung 1 = codex. ---
if [[ -n "${codex_bin}" && -x "${codex_bin}" ]]; then
  # Isolated scratch dir (FR-014); caller-side EXIT trap is the only correct
  # shape per lib.sh guidance (a subshell trap would rm the dir before we can
  # use it).
  scratch="$(make_scratch panelist-gpt)"
  trap 'rm -rf "${scratch}"' EXIT

  raw_out="${scratch}/codex-out.json"
  err_log="${scratch}/stderr.log"

  # Canonical R3 invocation. Each `-c` is ONE argv item (quoted) so the value
  # can't be word-split or expanded by the shell. Auth is read by codex from
  # ~/.codex/auth.json — we never put a key on argv, in env, or in the prompt.
  # Prompt is fed via stdin (`-` + `< "${prompt_file}"`) so the verbatim text
  # never lives on argv either.
  # -s read-only: a blind panelist ANSWERS the prompt; it must not edit a
  # workspace (that is the judge's job in Track A). workspace-write made codex
  # go agentic on plain Q&A (spawned a large process tree). read-only keeps it
  # to research + answer. web_search stays on so it can ground its reply.
  # --ignore-user-config drops ~/.codex/config.toml so the caveman SessionStart
  # hook (and any other user-scope hook/plugin) never injects into a blind
  # panelist — keeps the panel hook-clean like the claude runners. Keyring /
  # CODEX_HOME auth is unaffected. Because the config is ignored we re-supply on
  # argv what the panelist needs: -m gpt-5.5 (config model default is dropped),
  # effort, and web_search. --skip-git-repo-check already covers the dropped
  # [projects] trust list.
  set +e
  with_timeout "${GPT_TIMEOUT:-600}" \
    "${codex_bin}" exec \
      --skip-git-repo-check \
      --ignore-user-config \
      --cd "${scratch}" \
      -s read-only \
      -m gpt-5.5 \
      -c "tools.web_search=true" \
      -c "model_reasoning_effort=${effort}" \
      -o "${raw_out}" \
      - \
      < "${prompt_file}" \
      > "${scratch}/stdout.log" 2> "${err_log}"
  codex_rc=$?
  set -e
  if [[ "${codex_rc}" -eq 124 ]]; then
    safe_log "run_gpt: codex timed out after ${GPT_TIMEOUT:-600}s (dropping gpt panelist)"
    exit 1
  fi

  if [[ ${codex_rc} -ne 0 ]]; then
    safe_log "run_gpt: codex exited non-zero (rc=${codex_rc}; err in ${err_log})"
    exit 1
  fi

  if [[ ! -s "${raw_out}" ]]; then
    safe_log "run_gpt: codex produced no output file (path=${raw_out})"
    exit 1
  fi

  # --- Extract the final assistant message text. Codex may write structured
  #     JSON or plain text depending on flags/version; be defensive. Try jq
  #     first across the common field shapes Codex / fusion-fable have used,
  #     then python3, then fall back to the raw file content (some codex
  #     versions write plain text to -o even though the flag name implies
  #     JSON). Empty result from each rung is non-fatal — the next rung may
  #     still find a value. ---
  final_text=""

  if command -v jq >/dev/null 2>&1; then
    # Walk several known shapes: top-level scalars, choices[0].message.content,
    # and a generic items[].content[].text (codex --json JSONL flattened).
    # The trailing `// .` falls back to the whole file coerced to string if
    # nothing structured matches — handled by the raw-text rung below if jq
    # emits empty.
    final_text="$(jq -r '
      (.result // .message // .text // .reply // .output // empty)
      // (.choices[0].message.content // empty)
      // (try (.items[]?.content[]?.text // empty) catch empty)
      // (try (.messages[]?.content // empty | tostring) catch empty)
    ' "${raw_out}" 2>/dev/null)" || final_text=""
  fi

  if [[ -z "${final_text// /}" ]] && command -v python3 >/dev/null 2>&1; then
    final_text="$(python3 - "${raw_out}" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.stdout.write("")
    sys.exit(0)
# Collect every string value in the JSON tree, return the longest non-empty
# one — that is almost always the assistant's final message in a codex output.
buf = []
def walk(o):
    if isinstance(o, dict):
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
    elif isinstance(o, str):
        if o.strip():
            buf.append(o)
walk(data)
sys.stdout.write(max(buf, key=len) if buf else "")
PY
)" || final_text=""
  fi

  if [[ -z "${final_text// /}" ]]; then
    # Last resort: the file IS the answer. Some codex versions write plain
    # text to -o; that's still a valid "final assistant message" and the
    # contract is satisfied as long as the bytes are non-empty.
    final_text="$(cat "${raw_out}")"
  fi

  # --- Empty after all extraction attempts is a failure (contract: 0 requires
  #     non-empty output). ---
  if [[ -z "${final_text// /}" ]]; then
    safe_log "run_gpt: codex reply was empty after extraction (err in ${err_log})"
    exit 1
  fi

  # Write the clean answer text to <output_file>. No trailing newline — the
  # model's text already includes any line breaks it chose to emit.
  printf '%s' "${final_text}" > "${output_file}"
  exit 0
fi

# --- Backend dispatch: rung 2 = telegram-daemon GPT-5.5 route (degraded).
#     Per R3 the daemon path is answer-only; it lacks the panelist's local
#     bash + web tools, so this rung is a degraded fallback, never primary.
#     The contract says "IF a documented entrypoint exists". No such endpoint
#     is documented today; the rung is dormant code that surfaces the gap in
#     the safe_log so the operator can act. ---
if [[ -n "${FUSE_GPT_DAEMON_ROUTE:-}" ]]; then
  safe_log "run_gpt: FUSE_GPT_DAEMON_ROUTE='${FUSE_GPT_DAEMON_ROUTE}' set but no runner is wired (deferred per R3; daemon path is answer-only). Falling through to 127."
fi

# --- Backend dispatch: rung 3 = no backend available. Orchestrator drops the
#     panelist + downgrades (FR-011, SC-004). 127 is the contract signal. ---
safe_log "run_gpt: no GPT backend available (codex not executable; FUSE_GPT_DAEMON_ROUTE unset). Exiting 127 so orchestrator drops the gpt panelist."
exit 127
