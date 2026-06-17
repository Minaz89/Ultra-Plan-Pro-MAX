#!/usr/bin/env bash
# run_minimax.sh — MiniMax M3 panelist runner for fuse (T006).
#
# Contract (contracts/runner-contract.md):
#   run_minimax.sh <prompt_file> <output_file> [effort]
#
# Reads the verbatim panelist prompt from <prompt_file>, invokes the local
# `mm` wrapper (which execs `claude -p` against MiniMax-M3), captures the
# answer text, and writes ONLY that clean text to <output_file>.
# Default effort is "deep" (mm's --deep flag = 32k thinking budget);
# the 3rd arg overrides, and any non-"deep" value drops the --deep flag.
#
# Hard rules (research.md R2, FR-001, FR-014, SC-007, Constitution III/IV):
#   - Call `mm` directly with --deep -p, NOT `mm-exec` (its worker
#     preamble would contaminate the verbatim prompt rule, FR-001).
#   - mm reads MINIMAX_API_KEY itself from ~/.config/minimax.env and
#     scopes ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY to the spawned
#     `claude` only — never global settings.json. The runner must NOT
#     read, echo, or expand the key.
#   - Run in a scratch dir from make_scratch (FR-014: never the
#     caller's repo). Cleanup via caller-side EXIT trap.
#   - safe_log for all diagnostics (redacts any secret that slips into
#     a message; this runner never produces one, but the contract holds).
#   - Defensive `</dev/null` on the runner's stdin (T007): mm gets the
#     prompt as an `-p "<prompt>"` argv, never from stdin, so this
#     cannot break the prompt feed; it just guarantees the nested
#     `claude -p` mm execs cannot block on a tty/pipe parent stdin.
#
# Exit codes:
#   0   success, <output_file> non-empty
#   64  usage error
#   65  prompt_file not readable
#   127 mm binary or key file absent (orchestrator drops panelist + downgrades)
#   1   mm ran but produced empty / non-zero output

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# --- Arg validation ---
if [[ $# -lt 2 || $# -gt 3 ]]; then
  safe_log "run_minimax: usage: run_minimax.sh <prompt_file> <output_file> [effort]"
  exit 64
fi

prompt_file="$1"
output_file="$2"
effort="${3:-deep}"

# Resolve output_file to an absolute path BEFORE any cd into the scratch dir.
# A relative path would otherwise be written inside scratch and removed by the
# EXIT trap, silently losing the panelist's answer.
case "${output_file}" in
  /*) ;;
  *)  output_file="$(pwd)/${output_file}" ;;
esac

if [[ ! -r "${prompt_file}" ]]; then
  safe_log "run_minimax: prompt_file not readable: ${prompt_file}"
  exit 65
fi

# --- Backend availability: 127 = missing (orchestrator downgrades) ---
MM_BIN="${MM_BIN:-$HOME/.local/bin/mm}"
MM_ENV_FILE="${MINIMAX_ENV_FILE:-$HOME/.config/minimax.env}"
if [[ ! -x "${MM_BIN}" ]]; then
  safe_log "run_minimax: mm binary not found or not executable: ${MM_BIN} (dropping minimax panelist)"
  exit 127
fi
if [[ ! -r "${MM_ENV_FILE}" ]]; then
  safe_log "run_minimax: minimax env file not readable: ${MM_ENV_FILE} (dropping minimax panelist)"
  exit 127
fi

# --- Isolated scratch dir (FR-014); caller-side EXIT trap is the only
#     correct shape per lib.sh guidance (subshell traps would fire too
#     early and rm the dir before we can use it). ---
scratch="$(make_scratch panelist-minimax)"
trap 'rm -rf "${scratch}"' EXIT

# --- Build the invocation. Prompt text is read from the prompt file
#     verbatim (FR-001: do not modify); the --deep flag is included
#     only when effort is the default "deep" — any other value drops
#     it, which matches the task brief's "non-deep call drops --deep". ---
prompt_text="$(cat "${prompt_file}")"

# `mm` (per its own help / R2): `mm --deep -p "<prompt>"` execs
# `claude -p <prompt> --model MiniMax-M3 --fallback-model MiniMax-M2.7`
# with MAX_THINKING_TOKENS=32000 and the MiniMax key scoped to the
# child. We deliberately do NOT export MINIMAX_API_KEY ourselves — mm
# reads it from its env file. Calling mm with --deep is order-sensitive
# (it sets MAX_THINKING_TOKENS before the -p branch execs claude).
cd "${scratch}"
set +e
if [[ "${effort}" == "deep" ]]; then
  mm_output="$(with_timeout "${MM_TIMEOUT:-900}" "${MM_BIN}" --deep -p "${prompt_text}" --setting-sources project 2>"${scratch}/stderr.log" </dev/null)"
else
  safe_log "run_minimax: effort='${effort}' -> dropping --deep (mm default thinking applies)"
  mm_output="$(with_timeout "${MM_TIMEOUT:-900}" "${MM_BIN}" -p "${prompt_text}" --setting-sources project 2>"${scratch}/stderr.log" </dev/null)"
fi
mm_rc=$?
set -e

# --- Empty / failed output: contract says non-zero for both ---
if [[ ${mm_rc} -ne 0 ]]; then
  if [[ ${mm_rc} -eq 124 ]]; then
    safe_log "run_minimax: mm timed out after ${MM_TIMEOUT:-900}s (dropping minimax panelist)"
  else
    safe_log "run_minimax: mm exited rc=${mm_rc} (stderr in ${scratch}/stderr.log)"
  fi
  exit 1
fi
if [[ -z "${mm_output// /}" ]]; then
  safe_log "run_minimax: mm produced empty output (stderr in ${scratch}/stderr.log)"
  exit 1
fi

# --- Write the clean answer text to <output_file> (overwrite; verbatim;
#     no trailing newline appended — the model's text already includes
#     any line breaks it chose to emit). ---
printf '%s' "${mm_output}" > "${output_file}"

exit 0
