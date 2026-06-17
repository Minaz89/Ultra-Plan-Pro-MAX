#!/usr/bin/env bash
# run_opus.sh — Opus 4.8 panelist runner for fuse (T005).
#
# Contract (contracts/runner-contract.md):
#   run_opus.sh <prompt_file> <output_file> [effort]
#
# Reads the verbatim panelist prompt from <prompt_file>, invokes the LOCAL
# `claude` binary with model claude-opus-4-8, parses the JSON output, and
# writes ONLY the clean assistant text to <output_file>. Default effort
# is "xhigh" (one rung under max — panelist default, not a Principle-V max
# deviation); the 3rd arg overrides (e.g. "max", "ultracode" for the judge).
#
# Hard rules (Constitution III, FR-014, SC-007):
#   - Local `claude -p` only. Never a direct Anthropic API call.
#   - Never set a global ANTHROPIC_BASE_URL. Env vars are scoped to this
#     invocation only (single command line).
#   - Never echo any credential. safe_log is used for all diagnostics.
#   - Run in a scratch dir from make_scratch (FR-014: never the caller's
#     repo). Cleanup via caller-side EXIT trap.
#
# Exit codes:
#   0   success, <output_file> non-empty
#   127 claude CLI not in PATH (orchestrator drops the panelist + downgrades)
#   64  usage error
#   65  prompt_file not readable
#   1   backend ran but produced empty / unparseable / non-zero output

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# --- Arg validation ---
if [[ $# -lt 2 || $# -gt 3 ]]; then
  safe_log "run_opus: usage: run_opus.sh <prompt_file> <output_file> [effort]"
  exit 64
fi

prompt_file="$1"
output_file="$2"
effort="${3:-xhigh}"

# Resolve output_file to an absolute path BEFORE any cd into the scratch dir.
# A relative path would otherwise be written inside scratch and removed by the
# EXIT trap, silently losing the panelist's answer.
case "${output_file}" in
  /*) ;;
  *)  output_file="$(pwd)/${output_file}" ;;
esac

if [[ ! -r "${prompt_file}" ]]; then
  safe_log "run_opus: prompt_file not readable: ${prompt_file}"
  exit 65
fi

# --- Backend availability: 127 = missing (orchestrator downgrades) ---
if ! command -v claude >/dev/null 2>&1; then
  safe_log "run_opus: claude CLI not in PATH (dropping opus panelist)"
  exit 127
fi

# --- Isolated scratch dir (FR-014); caller-side EXIT trap is the only
#     correct shape per lib.sh guidance (subshell traps would fire too
#     early and rm the dir before we can use it). ---
scratch="$(make_scratch panelist-opus)"
trap 'rm -rf "${scratch}"' EXIT

# --- Per-panelist CLAUDE_CONFIG_DIR isolation (T007). When the daemon route
#     arm sets TG_FUSE_ISOLATE=1, give this run its OWN seeded copy of the
#     creds file so two concurrent claude panelists never race for the same
#     mutable ~/.claude/.credentials.json (proven Phase-0 hang in spec 015).
#     Interactive /fuse does NOT set TG_FUSE_ISOLATE -> the helper is a no-op
#     and the caller's normal config dir is used unchanged. ---
iso_cfg="$(fuse_isolate_config_dir "${scratch}")"
if [[ -n "${iso_cfg}" ]]; then
  export CLAUDE_CONFIG_DIR="${iso_cfg}"
fi

# --- Build the invocation. Prompt text, settings string, and env vars
#     are all scoped to this invocation only — never written to a global
#     config or to the caller's repo. ---
prompt_text="$(cat "${prompt_file}")"
raw_json_file="${scratch}/raw.json"
settings_json="$(printf '{"effortLevel":"%s"}' "${effort}")"

# Run claude inside the scratch dir. Capture stdout (JSON) to a file;
# route stderr to a scratch log we can mention on failure (no live
# streaming to caller, per contract: output is the clean answer only).
cd "${scratch}"
set +e
MAX_THINKING_TOKENS=32000 \
  with_timeout "${OPUS_TIMEOUT:-900}" \
  claude -p "${prompt_text}" \
         --model claude-opus-4-8 \
         --setting-sources project \
         --settings "${settings_json}" \
         --permission-mode bypassPermissions \
         --output-format json \
  > "${raw_json_file}" 2> "${scratch}/stderr.log" </dev/null
claude_rc=$?
set -e
if [[ "${claude_rc}" -ne 0 ]]; then
  if [[ "${claude_rc}" -eq 124 ]]; then
    safe_log "run_opus: claude timed out after ${OPUS_TIMEOUT:-900}s (dropping opus panelist)"
  else
    safe_log "run_opus: claude exited non-zero rc=${claude_rc} (stderr in ${scratch}/stderr.log)"
  fi
  exit 1
fi

# --- Parse JSON → extract the assistant's clean text. The 'result' field
#     of the final JSON object is the answer per the --output-format json
#     contract. Prefer jq; fall back to python3 (always available on this
#     homelab per T005 task brief). The `|| result_text=""` masks any
#     parser failure so `set -e` does not abort — empty result is then
#     caught and re-raised by the empty-output check below. ---
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
  safe_log "run_opus: parsed result was empty (no .result field or empty value)"
  exit 1
fi

# --- Write the clean answer text to <output_file> (overwrite; verbatim;
#     no trailing newline appended — claude's text already includes any
#     line breaks the assistant chose to emit). ---
printf '%s' "${result_text}" > "${output_file}"

exit 0
