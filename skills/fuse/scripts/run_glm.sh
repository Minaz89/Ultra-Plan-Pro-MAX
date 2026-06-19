#!/usr/bin/env bash
# run_glm.sh — GLM-5.2 (deep) panelist runner for fuse.
#
# Contract (contracts/runner-contract.md):
#   run_glm.sh <prompt_file> <output_file> [effort]
#
# Reads the verbatim panelist prompt from <prompt_file>, invokes the LOCAL
# `claude` binary repointed at z.ai's Anthropic-compatible endpoint (the same
# wiring the `glm-deep` helper uses), parses the JSON output, and writes ONLY
# the clean assistant text to <output_file>. Default effort is "deep"
# (MAX_THINKING_TOKENS=32000 — GLM's deep/Max thinking budget); any non-"deep"
# value drops to the lighter 10k budget.
#
# Hard rules (Constitution III, FR-014, SC-007):
#   - Local `claude -p` only (z.ai is an Anthropic-COMPAT endpoint reached by
#     the same binary). Env vars (ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY/MODEL,
#     MAX_THINKING_TOKENS) are scoped to THIS invocation only — never written
#     to a global config or the caller's repo.
#   - The GLM key is read from ~/.config/glm.env by sourcing it into THIS
#     process only; it is never echoed. safe_log redacts any leak.
#   - Run in a scratch dir from make_scratch (FR-014: never the caller's repo).
#     Cleanup via caller-side EXIT trap.
#
# Exit codes:
#   0   success, <output_file> non-empty
#   127 claude CLI absent, or glm.env / GLM_API_KEY missing (orchestrator
#       drops the glm panelist + downgrades)
#   64  usage error
#   65  prompt_file not readable
#   1   backend ran but produced empty / unparseable / non-zero output

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# --- Arg validation ---
if [[ $# -lt 2 || $# -gt 3 ]]; then
  safe_log "run_glm: usage: run_glm.sh <prompt_file> <output_file> [effort]"
  exit 64
fi

prompt_file="$1"
output_file="$2"
effort="${3:-deep}"

# Resolve output_file to an absolute path BEFORE any cd into the scratch dir.
case "${output_file}" in
  /*) ;;
  *)  output_file="$(pwd)/${output_file}" ;;
esac

if [[ ! -r "${prompt_file}" ]]; then
  safe_log "run_glm: prompt_file not readable: ${prompt_file}"
  exit 65
fi

# --- Backend availability: 127 = missing (orchestrator downgrades) ---
if ! command -v claude >/dev/null 2>&1; then
  safe_log "run_glm: claude CLI not in PATH (dropping glm panelist)"
  exit 127
fi
GLM_ENV_FILE="${GLM_ENV_FILE:-$HOME/.config/glm.env}"
if [[ ! -r "${GLM_ENV_FILE}" ]]; then
  safe_log "run_glm: glm env file not readable: ${GLM_ENV_FILE} (dropping glm panelist)"
  exit 127
fi

# Source the key into THIS process only (never global). The file holds
# GLM_API_KEY (+ optional GLM_BASE_URL / GLM_MODEL). We never echo it.
set -a
# shellcheck disable=SC1090
. "${GLM_ENV_FILE}"
set +a
if [[ -z "${GLM_API_KEY:-}" ]]; then
  safe_log "run_glm: GLM_API_KEY empty in ${GLM_ENV_FILE} (dropping glm panelist)"
  exit 127
fi

# --- Isolated scratch dir (FR-014); caller-side EXIT trap is the only
#     correct shape per lib.sh guidance. ---
scratch="$(make_scratch panelist-glm)"
trap 'rm -rf "${scratch}"' EXIT

# --- Per-panelist CLAUDE_CONFIG_DIR isolation (matches run_opus): when the
#     daemon route arm sets TG_FUSE_ISOLATE=1, give this run its OWN seeded
#     creds dir so concurrent claude panelists never race the same mutable
#     ~/.claude/.credentials.json. (GLM auths via ANTHROPIC_AUTH_TOKEN, but
#     the binary still touches the config dir — isolation is harmless + safe.)
iso_cfg="$(fuse_isolate_config_dir "${scratch}")"
if [[ -n "${iso_cfg}" ]]; then
  export CLAUDE_CONFIG_DIR="${iso_cfg}"
fi

# --- Effort → thinking budget. "deep" = 32k (Max); anything else = 10k. ---
if [[ "${effort}" == "deep" ]]; then
  think_tokens="${GLM_DEEP_THINKING_TOKENS:-32000}"
else
  safe_log "run_glm: effort='${effort}' -> 10k thinking (non-deep)"
  think_tokens="${GLM_THINKING_TOKENS:-10000}"
fi

# --- Build the invocation. Endpoint + model + key are scoped to this single
#     command only (exported inline before claude execs, never globally). ---
prompt_text="$(cat "${prompt_file}")"
raw_json_file="${scratch}/raw.json"

cd "${scratch}"
set +e
ANTHROPIC_BASE_URL="${GLM_BASE_URL:-https://api.z.ai/api/anthropic}" \
ANTHROPIC_AUTH_TOKEN="${GLM_API_KEY}" \
ANTHROPIC_API_KEY="${GLM_API_KEY}" \
ANTHROPIC_MODEL="${GLM_MODEL:-glm-5.2}" \
MAX_THINKING_TOKENS="${think_tokens}" \
  with_timeout "${GLM_TIMEOUT:-900}" \
  claude -p "${prompt_text}" \
         --setting-sources project \
         --permission-mode bypassPermissions \
         --output-format json \
  > "${raw_json_file}" 2> "${scratch}/stderr.log" </dev/null
claude_rc=$?
set -e
if [[ "${claude_rc}" -ne 0 ]]; then
  if [[ "${claude_rc}" -eq 124 ]]; then
    safe_log "run_glm: claude timed out after ${GLM_TIMEOUT:-900}s (dropping glm panelist)"
  else
    safe_log "run_glm: claude exited non-zero rc=${claude_rc} (stderr in ${scratch}/stderr.log)"
  fi
  exit 1
fi

# --- Parse JSON → extract the assistant's clean text (.result field). ---
result_text=""
if command -v jq >/dev/null 2>&1; then
  result_text="$(jq -r '.result // empty' "${raw_json_file}" 2>/dev/null)" || result_text=""
else
  result_text="$(python3 - "${raw_json_file}" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    val = data.get("result", "") or ""
    sys.stdout.write(val)
except Exception:
    pass
PY
)" || result_text=""
fi

# --- Empty output is a failure (contract: "Empty output must be non-zero") ---
if [[ -z "${result_text// /}" ]]; then
  safe_log "run_glm: parsed result was empty (no .result field or empty value)"
  exit 1
fi

# --- Write the clean answer text to <output_file> (overwrite; verbatim). ---
printf '%s' "${result_text}" > "${output_file}"

exit 0
