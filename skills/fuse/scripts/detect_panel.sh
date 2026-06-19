#!/usr/bin/env bash
# detect_panel.sh — probe each backend's availability and emit a SLUG=
# line naming the richest available panel. T004.
#
# Per contracts/runner-contract.md ("detect_panel.sh contract"):
#   - opus (claude) is ALWAYS the anchor; treated as available if `claude`
#     is on PATH. Contract states "claude: always" — script tolerates a
#     missing `claude` by reporting it; SLUG falls through to opus-only
#     (which already gets the degenerate flag).
#   - gpt (codex, GPT-5.5) → resolve in order: $CODEX_BIN env →
#     $HOME/.npm-global/bin/codex → `codex` on PATH. Available only
#     if the resolved binary is executable.
#   - minimax (MiniMax M3) → $HOME/.local/bin/mm is executable AND
#     key file $HOME/.config/minimax.env is present.
#   - gemini (optional 4th) → `command -v gemini`. Probe-only; gemini does
#     not appear in the SLUG per the contract precedence.
#   - Richest order: opus-gpt-minimax > opus-minimax > opus-gpt > opus-only.
#   - opus-only is flagged "not a true fusion" (FR-011 / SC-004).
#
# Secret safety (FR-014, SC-007, Constitution IV): the minimax key file is
# checked by `-e` only — it is never read, sourced, echoed, or have its
# contents inspected. CODEX_BIN is a path (not a key) and may be echoed in
# the human-readable "missing" reason line.
#
# Exit: always 0 (this is a probe; the orchestrator greps the SLUG= line).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# --- Probe state (0 = available, 1 = missing). ---
opus_avail=1
gpt_avail=1
minimax_avail=1
glm_avail=1
gemini_avail=1

# --- Human-readable "missing" reason strings. ---
gpt_reason=""
minimax_reason=""
glm_reason=""
gemini_reason=""

# --- opus (claude) — ALWAYS the anchor per the contract. ---
if command -v claude >/dev/null 2>&1; then
  opus_avail=0
fi

# --- gpt (codex) — resolve CODEX_BIN → ~/.npm-global/bin/codex → PATH. ---
codex_resolved=""
if [[ -n "${CODEX_BIN:-}" ]]; then
  codex_resolved="${CODEX_BIN}"
elif [[ -x $HOME/.npm-global/bin/codex ]]; then
  codex_resolved="$HOME/.npm-global/bin/codex"
else
  # PATH fallback. `|| true` keeps `set -e` from exiting when codex is
  # genuinely missing — we WANT that to be a non-fatal absence here.
  codex_resolved="$(command -v codex 2>/dev/null || true)"
fi
if [[ -n "${codex_resolved}" && -x "${codex_resolved}" ]]; then
  gpt_avail=0
else
  # Order of "why" matters: surface the override the user actually set
  # (CODEX_BIN) first, then the canonical path, then the PATH search.
  if [[ -n "${CODEX_BIN:-}" ]]; then
    gpt_reason="codex (CODEX_BIN=${CODEX_BIN}) not executable"
  elif [[ ! -e $HOME/.npm-global/bin/codex ]]; then
    gpt_reason="codex not found"
  else
    gpt_reason="codex not executable"
  fi
fi

# --- minimax (mm + key file). ---
# MM_BIN and MINIMAX_ENV_FILE are env overrides (T010: testability). Defaults
# match the contract; real install paths. Secret-safety preserved — env file
# is still checked by `-e` only, never read or echoed.
mm_bin="${MM_BIN:-$HOME/.local/bin/mm}"
mm_env="${MINIMAX_ENV_FILE:-$HOME/.config/minimax.env}"
if [[ -x "${mm_bin}" && -e "${mm_env}" ]]; then
  minimax_avail=0
else
  # Distinguish the two failure modes so a user can act on the line
  # without re-running the probe.
  if [[ ! -e "${mm_bin}" ]]; then
    minimax_reason="mm not found"
  elif [[ ! -x "${mm_bin}" ]]; then
    minimax_reason="mm not executable"
  else
    minimax_reason="minimax key file absent"
  fi
fi

# --- glm (GLM-5.2 via z.ai) — claude binary (anchor) + glm.env present.
#     Secret-safety: the env file is checked by `-r` only — never read,
#     sourced, or echoed here (run_glm.sh is the authoritative gate on an
#     empty GLM_API_KEY, exiting 127 so the orchestrator drops the panelist). ---
glm_env="${GLM_ENV_FILE:-$HOME/.config/glm.env}"
if [[ ${opus_avail} -eq 0 && -r "${glm_env}" ]]; then
  glm_avail=0
else
  if [[ ${opus_avail} -ne 0 ]]; then
    glm_reason="claude (GLM runs via the claude binary) not in PATH"
  else
    glm_reason="glm env file absent (${glm_env})"
  fi
fi

# --- gemini (optional probe) — only present counts. ---
if command -v gemini >/dev/null 2>&1; then
  gemini_avail=0
else
  gemini_reason="gemini not in PATH"
fi

# --- Print availability lines (human-readable). ---
if [[ ${opus_avail} -eq 0 ]]; then
  echo "opus: available"
else
  echo "opus: missing (claude not in PATH)"
fi

if [[ ${gpt_avail} -eq 0 ]]; then
  echo "gpt: available"
else
  echo "gpt: missing (${gpt_reason})"
fi

if [[ ${minimax_avail} -eq 0 ]]; then
  echo "minimax: available"
else
  echo "minimax: missing (${minimax_reason})"
fi

if [[ ${glm_avail} -eq 0 ]]; then
  echo "glm: available"
else
  echo "glm: missing (${glm_reason})"
fi

if [[ ${gemini_avail} -eq 0 ]]; then
  echo "gemini: available"
else
  echo "gemini: missing (${gemini_reason})"
fi

# --- Compute richest SLUG, COMPOSITIONALLY (anchor is always opus/claude;
#     each available backend appends its token in fixed order). This keeps
#     every legacy slug intact (opus-gpt-minimax, opus-minimax, opus-gpt,
#     opus-only) and adds the 4-model richest "opus-gpt-minimax-glm". ---
if [[ ${opus_avail} -eq 0 ]]; then
  slug="opus"
  [[ ${gpt_avail} -eq 0 ]]     && slug="${slug}-gpt"
  [[ ${minimax_avail} -eq 0 ]] && slug="${slug}-minimax"
  [[ ${glm_avail} -eq 0 ]]     && slug="${slug}-glm"
  [[ "${slug}" == "opus" ]]    && slug="opus-only"
else
  slug="opus-only"
fi

# --- Degenerate flag for opus-only (per FR-011 / SC-004). ---
if [[ "${slug}" == "opus-only" ]]; then
  echo "WARNING: degenerate panel (opus-only) — not a true fusion"
fi

# --- Machine-readable contract line (orchestrator greps this). ---
echo "SLUG=${slug}"

# Always exit 0 — this is a probe; the SLUG= line carries the signal.
exit 0
