#!/usr/bin/env bash
# test_runner_contract.sh — T009
# Verifies each panelist runner obeys the stdin/output/exit contract
# WITHOUT any live backend spend, using stub backends on PATH / MM_BIN /
# CODEX_BIN. Read by auditors before they audit any panelist answer.
#
# Contract under test (specs/014-fuse-panel-judge/contracts/runner-contract.md):
#
#     run_<backend>.sh <prompt_file> <output_file> [effort]
#
#   exit 0   = success, <output_file> non-empty
#   exit 64  = usage error (too few / too many args; invalid effort on gpt)
#   exit 65  = prompt_file not readable
#   exit 127 = backend CLI not installed/resolvable (orchestrator downgrades)
#   exit 1   = backend ran but produced empty / non-zero / unparseable output
#
# Hard rule for this test file: NO live API calls. Every backend is
# replaced by a small bash stub in a temp dir. Stubs echo a canned answer
# driven by $FUSE_STUB_ANSWER; setting it empty simulates a backend that
# ran clean (rc=0) but produced nothing useful.
#
# Cases per runner (6):
#   1. happy path           — stub returns known answer  -> exit 0, output has it
#   2. missing backend      — resolver points at nothing  -> exit 127
#   3. empty output         — stub returns nothing        -> exit NON-ZERO
#   4. usage error          — call with too few args       -> exit 64
#   5. unreadable prompt    — pass /nonexistent as prompt  -> exit 65
#   6. relative output path — cd elsewhere, pass RELATIVE output, assert file
#                             lands at caller cwd (regression for the
#                             absolute-path fix in run_*.sh)
#
# Style: plain bash assertions; PASS/FAIL printed per case; non-zero exit
# if any case fails. Deterministic — no sleeps, no retry loops.

set -uo pipefail
# NOTE: deliberately NOT `set -e`. We want each failing assertion to be
# COUNTED and the script to continue through all cases, not abort on the
# first failure. The assertion helpers also keep their own bookkeeping
# so the summary at the end is faithful.

# --- Locate repo paths (no dependency on cwd) ---
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUSE_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
RUNNERS_DIR="${FUSE_ROOT}/skills/fuse/scripts"
RUN_OPUS="${RUNNERS_DIR}/run_opus.sh"
RUN_MINIMAX="${RUNNERS_DIR}/run_minimax.sh"
RUN_GPT="${RUNNERS_DIR}/run_gpt.sh"

for f in "${RUN_OPUS}" "${RUN_MINIMAX}" "${RUN_GPT}"; do
  if [[ ! -r "${f}" ]]; then
    printf 'FATAL: runner not found: %s\n' "${f}" >&2
    exit 99
  fi
done

# --- Test counters ---
PASS=0
FAIL=0
FAILED_CASES=()
# Global so run_case can hand the runner's exit code back to its caller
# without eval-into-parent-scope gymnastics (eval inside a function can't
# reach the caller's `local` vars). Each test reads LAST_RC right after
# run_case returns.
LAST_RC=0

# --- Assertion helpers (do NOT abort; just count) ---
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    printf '  PASS  %s (got %s)\n' "${label}" "${actual}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "${label}" "${expected}" "${actual}"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("${label}")
  fi
}

assert_ne() {
  local label="$1" forbidden="$2" actual="$3"
  if [[ "${forbidden}" != "${actual}" ]]; then
    printf '  PASS  %s (got %s, not %s)\n' "${label}" "${actual}" "${forbidden}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s (got %s, must NOT be %s)\n' "${label}" "${actual}" "${forbidden}"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("${label}")
  fi
}

assert_file_contains() {
  local label="$1" needle="$2" file="$3"
  if [[ ! -f "${file}" ]]; then
    printf '  FAIL  %s (file does not exist: %s)\n' "${label}" "${file}"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("${label}")
    return
  fi
  if grep -qF -- "${needle}" "${file}"; then
    printf '  PASS  %s (found %q in %s)\n' "${label}" "${needle}" "${file}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s (did not find %q in %s; contents: %s)\n' \
      "${label}" "${needle}" "${file}" "$(cat "${file}" 2>/dev/null | head -c 200)"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("${label}")
  fi
}

# --- Test scratch layout ---
# TEST_TMP holds the stubs, the fake env file, the per-case work dirs,
# and the caller-cwd dir for the relative-path regression test. It is
# wiped on EXIT so no detritus is left in /tmp.
TEST_TMP="$(mktemp -d -t fuse-contract-test.XXXXXX)"
trap 'rm -rf "${TEST_TMP}"' EXIT
STUB_DIR="${TEST_TMP}/stubs"
EMPTY_DIR="${TEST_TMP}/empty-path"
WORK_DIR="${TEST_TMP}/work"
mkdir -p "${STUB_DIR}" "${EMPTY_DIR}" "${WORK_DIR}"

# --- Stub: claude (run_opus.sh) ---
# run_opus.sh invokes:
#   MAX_THINKING_TOKENS=32000 claude -p "$prompt_text" \
#       --model claude-opus-4-8 --settings "$settings_json" \
#       --permission-mode bypassPermissions --output-format json \
#       > raw.json 2> stderr.log
# The runner then jq-parses .result out of raw.json. So the stub emits
# a JSON object with a .result field. With FUSE_STUB_ANSWER empty, the
# result field is the empty string -> runner hits "parsed result was empty"
# branch and exits 1.
cat > "${STUB_DIR}/claude" <<'STUB'
#!/usr/bin/env bash
# Stub claude — emits canned JSON answer for run_opus.sh.
ans="${FUSE_STUB_ANSWER-}"
if [[ -z "${ans}" ]]; then
  printf '{"result":""}'
else
  # The canned test answers contain only [A-Za-z0-9_], so a naive printf
  # is safe JSON. If you add a test answer with quotes/backslashes,
  # upgrade this to a real JSON encoder (python3 is on every host we run
  # tests on).
  printf '{"result":"%s"}' "${ans}"
fi
STUB

# --- Stub: mm (run_minimax.sh) ---
# run_minimax.sh invokes:
#   mm --deep -p "$prompt_text" 2> stderr.log      (stdout captured)
# It expects clean text on stdout (no JSON wrapper). Empty stdout with
# rc=0 triggers the "mm produced empty output" branch -> exit 1.
cat > "${STUB_DIR}/mm" <<'STUB'
#!/usr/bin/env bash
# Stub mm — emits canned plain-text answer for run_minimax.sh.
ans="${FUSE_STUB_ANSWER-}"
if [[ -n "${ans}" ]]; then
  printf '%s' "${ans}"
fi
# When FUSE_STUB_ANSWER is empty, we print nothing -> the runner's
# `mm_output` is empty, the second guard fires, exit 1.
STUB

# --- Stub: codex (run_gpt.sh) ---
# run_gpt.sh invokes:
#   codex exec --skip-git-repo-check --cd "$scratch" -s workspace-write \
#       -c "tools.web_search=true" -c "model_reasoning_effort=$effort" \
#       -o "$raw_out" -  < "$prompt_file"
# The runner then reads $raw_out and extracts .result via jq. The stub
# parses argv to find the path that follows `-o` and writes the canned
# JSON there. With FUSE_STUB_ANSWER empty, it writes {"result":""} so
# the parser returns "" and the runner hits the "empty after extraction"
# branch -> exit 1.
cat > "${STUB_DIR}/codex" <<'STUB'
#!/usr/bin/env bash
# Stub codex — writes canned JSON to the path supplied via -o.
ans="${FUSE_STUB_ANSWER-}"
out_file=""
prev=""
for arg in "$@"; do
  if [[ "${prev}" == "-o" ]]; then
    out_file="${arg}"
  fi
  prev="${arg}"
done
if [[ -n "${out_file}" ]]; then
  if [[ -z "${ans}" ]]; then
    # Empty-output mode: write NOTHING. run_gpt.sh has
    #   if [[ ! -s "${raw_out}" ]]; then exit 1; fi
    # which fires immediately. (Writing {"result":""} would NOT trigger
    # the exit-1 path because the runner's "last-resort" cat-the-file
    # step treats any non-empty file as a valid answer.)
    :
  else
    printf '{"result":"%s"}' "${ans}" > "${out_file}"
  fi
fi
STUB

# Make stubs executable. `chmod` may be denied in some sandboxes; fall
# back to `python3 os.chmod` per the task brief.
for s in claude mm codex; do
  if ! chmod 0755 "${STUB_DIR}/${s}" 2>/dev/null; then
    python3 -c "import os; os.chmod('${STUB_DIR}/${s}', 0o755)"
  fi
done

# --- Fake minimax env file (run_minimax.sh refuses to run if its env
#     file is not readable; tests need a readable, harmless stand-in). ---
FAKE_MINIMAX_ENV="${TEST_TMP}/minimax.env"
printf 'MINIMAX_API_KEY=stub-test-key-not-a-real-secret\n' > "${FAKE_MINIMAX_ENV}"
chmod 0600 "${FAKE_MINIMAX_ENV}"

# --- Hermetic tools dir for the missing-backend tests.
#     This box has /usr/bin/claude and /bin/claude installed, so a
#     minimal PATH like "/usr/bin:/bin" still resolves `claude` and
#     the opus missing-backend test would falsely pass. Build a
#     symlink farm with everything the runner needs EXCEPT claude,
#     and use it as PATH for those tests. The runner uses:
#       cat, mktemp, printf, jq, python3, perl, timeout (optional)
#     all via the lib.sh helpers and its own body. ---
TOOLS_DIR="${TEST_TMP}/tools"
mkdir -p "${TOOLS_DIR}"
for tool in cat mktemp printf true false basename dirname jq python3 perl timeout env rm cp mv; do
  src="$(command -v "${tool}" 2>/dev/null || true)"
  if [[ -n "${src}" && -e "${src}" ]]; then
    ln -sf "${src}" "${TOOLS_DIR}/${tool}"
  fi
done
# Sanity: tools dir must have jq, python3, cat, mktemp — those are the
# load-bearing ones for the opus runner. If any is missing, the
# missing-backend test would falsely pass for the wrong reason
# (e.g. cat-not-found → exit 127 via set -e, NOT via the contract check).
for must in cat mktemp jq python3; do
  if [[ ! -e "${TOOLS_DIR}/${must}" ]]; then
    printf 'FATAL: tools dir missing %s — cannot hermetic-test the contract.\n' "${must}" >&2
    exit 98
  fi
done

# --- Common env: stubs on PATH, NO real auth in env. The global
#     PATH/CODEX_BIN/MM_BIN are set per-case so each test is hermetic. ---
unset MINIMAX_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN MINIMAX_ENV_FILE
unset CODEX_BIN MM_BIN

write_prompt() {
  local path="$1"
  printf 'panelist prompt: please answer this verbatim (this is a stub test run, T009)\n' \
    > "${path}"
}

# A small per-case run helper. Args: label, then env-vars, runner, runner-args.
# Sets the GLOBAL LAST_RC to the runner's exit code. Use `env -i` so the
# per-case env is the ONLY thing the runner sees — no surprise from
# inherited CODEX_BIN, MM_BIN, etc.
run_case() {
  local label="$1"
  shift
  set +e
  env -i "$@" >/dev/null 2>&1
  LAST_RC=$?
  set +u
  LAST_RC="${LAST_RC:-0}"
  set -u
}

# ============================================================
# run_opus.sh
# ============================================================
run_opus_cases() {
  printf '\n[run_opus.sh]\n'
  local prompt="${WORK_DIR}/opus-prompt.txt"
  local out="${WORK_DIR}/opus.out"
  write_prompt "${prompt}"
  local rc
  local answer="STUB_OPUS_HAPPY"

  # 1. happy path
  run_case "opus-happy" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_OPUS}" "${prompt}" "${out}"
  assert_eq  'opus 1. happy path -> exit 0' '0' "${LAST_RC}"
  assert_file_contains 'opus 1. happy path -> output has answer' "${answer}" "${out}"

  # 2. missing backend — TOOLS_DIR has every util the runner needs
  #    (cat, mktemp, jq, python3, perl, timeout) but no `claude`.
  #    A bare /usr/bin:/bin PATH would falsely resolve to the real
  #    /usr/bin/claude installed on this host.
  run_case "opus-missing" \
    PATH="${TOOLS_DIR}" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_OPUS}" "${prompt}" "${out}"
  assert_eq  'opus 2. missing backend -> exit 127' '127' "${LAST_RC}"

  # 3. empty output — stub returns {"result":""}
  run_case "opus-empty" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    FUSE_STUB_ANSWER="" \
    "${RUN_OPUS}" "${prompt}" "${out}"
  assert_ne  'opus 3. empty output -> non-zero exit' '0' "${LAST_RC}"

  # 4. usage error — too few args
  run_case "opus-usage" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_OPUS}" "${prompt}"
  assert_eq  'opus 4. usage error -> exit 64' '64' "${LAST_RC}"

  # 5. unreadable prompt
  run_case "opus-noprompt" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_OPUS}" "/nonexistent/fuse-test-prompt-${$}.txt" "${out}"
  assert_eq  'opus 5. unreadable prompt -> exit 65' '65' "${LAST_RC}"

  # 6. relative output path — cd to a fresh dir, pass a relative path,
  #    assert file lands at that cwd (NOT lost in scratch).
  local rel_cwd="${TEST_TMP}/opus-rel"
  mkdir -p "${rel_cwd}"
  local rel_name="opus-rel.out"
  (
    cd "${rel_cwd}"
    env -i \
      PATH="${STUB_DIR}:/usr/bin:/bin" \
      HOME="${HOME}" \
      FUSE_STUB_ANSWER="STUB_OPUS_RELPATH" \
      "${RUN_OPUS}" "${prompt}" "${rel_name}" >/dev/null 2>&1
  )
  rc=$?
  assert_eq  'opus 6. relative path -> exit 0' '0' "${rc}"
  assert_file_contains 'opus 6. relative path -> file at caller cwd' \
    'STUB_OPUS_RELPATH' "${rel_cwd}/${rel_name}"
}

# ============================================================
# run_minimax.sh
# ============================================================
run_minimax_cases() {
  printf '\n[run_minimax.sh]\n'
  local prompt="${WORK_DIR}/mm-prompt.txt"
  local out="${WORK_DIR}/mm.out"
  write_prompt "${prompt}"
  local rc
  local answer="STUB_MINIMAX_HAPPY"

  # 1. happy path — MM_BIN points at stub, env file is the fake
  run_case "mm-happy" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    MM_BIN="${STUB_DIR}/mm" \
    MINIMAX_ENV_FILE="${FAKE_MINIMAX_ENV}" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_MINIMAX}" "${prompt}" "${out}"
  assert_eq  'minimax 1. happy path -> exit 0' '0' "${LAST_RC}"
  assert_file_contains 'minimax 1. happy path -> output has answer' "${answer}" "${out}"

  # 2. missing backend — MM_BIN points at a nonexistent file
  run_case "mm-missing" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    MM_BIN="${TEST_TMP}/nope-no-such-mm" \
    MINIMAX_ENV_FILE="${FAKE_MINIMAX_ENV}" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_MINIMAX}" "${prompt}" "${out}"
  assert_eq  'minimax 2. missing backend -> exit 127' '127' "${LAST_RC}"

  # 3. empty output — stub prints nothing to stdout, rc=0
  run_case "mm-empty" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    MM_BIN="${STUB_DIR}/mm" \
    MINIMAX_ENV_FILE="${FAKE_MINIMAX_ENV}" \
    FUSE_STUB_ANSWER="" \
    "${RUN_MINIMAX}" "${prompt}" "${out}"
  assert_ne  'minimax 3. empty output -> non-zero exit' '0' "${LAST_RC}"

  # 4. usage error
  run_case "mm-usage" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    MM_BIN="${STUB_DIR}/mm" \
    MINIMAX_ENV_FILE="${FAKE_MINIMAX_ENV}" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_MINIMAX}" "${prompt}"
  assert_eq  'minimax 4. usage error -> exit 64' '64' "${LAST_RC}"

  # 5. unreadable prompt
  run_case "mm-noprompt" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    MM_BIN="${STUB_DIR}/mm" \
    MINIMAX_ENV_FILE="${FAKE_MINIMAX_ENV}" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_MINIMAX}" "/nonexistent/fuse-test-prompt-${$}.txt" "${out}"
  assert_eq  'minimax 5. unreadable prompt -> exit 65' '65' "${LAST_RC}"

  # 6. relative output path
  local rel_cwd="${TEST_TMP}/mm-rel"
  mkdir -p "${rel_cwd}"
  local rel_name="mm-rel.out"
  (
    cd "${rel_cwd}"
    env -i \
      PATH="${STUB_DIR}:/usr/bin:/bin" \
      HOME="${HOME}" \
      MM_BIN="${STUB_DIR}/mm" \
      MINIMAX_ENV_FILE="${FAKE_MINIMAX_ENV}" \
      FUSE_STUB_ANSWER="STUB_MINIMAX_RELPATH" \
      "${RUN_MINIMAX}" "${prompt}" "${rel_name}" >/dev/null 2>&1
  )
  rc=$?
  assert_eq  'minimax 6. relative path -> exit 0' '0' "${rc}"
  assert_file_contains 'minimax 6. relative path -> file at caller cwd' \
    'STUB_MINIMAX_RELPATH' "${rel_cwd}/${rel_name}"
}

# ============================================================
# run_gpt.sh
# ============================================================
run_gpt_cases() {
  printf '\n[run_gpt.sh]\n'
  local prompt="${WORK_DIR}/gpt-prompt.txt"
  local out="${WORK_DIR}/gpt.out"
  write_prompt "${prompt}"
  local rc
  local answer="STUB_GPT_HAPPY"

  # 1. happy path — CODEX_BIN points at stub
  run_case "gpt-happy" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    CODEX_BIN="${STUB_DIR}/codex" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_GPT}" "${prompt}" "${out}"
  assert_eq  'gpt 1. happy path -> exit 0' '0' "${LAST_RC}"
  assert_file_contains 'gpt 1. happy path -> output has answer' "${answer}" "${out}"

  # 2. missing backend — CODEX_BIN points at nothing, real npm-global
  #    codex is also not on PATH for this hermetic env (`env -i`).
  run_case "gpt-missing" \
    PATH="${EMPTY_DIR}:/usr/bin:/bin" \
    CODEX_BIN="${TEST_TMP}/nope-no-such-codex" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_GPT}" "${prompt}" "${out}"
  assert_eq  'gpt 2. missing backend -> exit 127' '127' "${LAST_RC}"

  # 3. empty output — stub writes {"result":""} to the -o file
  run_case "gpt-empty" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    CODEX_BIN="${STUB_DIR}/codex" \
    FUSE_STUB_ANSWER="" \
    "${RUN_GPT}" "${prompt}" "${out}"
  assert_ne  'gpt 3. empty output -> non-zero exit' '0' "${LAST_RC}"

  # 4. usage error — too few args
  run_case "gpt-usage" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    CODEX_BIN="${STUB_DIR}/codex" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_GPT}" "${prompt}"
  assert_eq  'gpt 4. usage error -> exit 64' '64' "${LAST_RC}"

  # 5. unreadable prompt
  run_case "gpt-noprompt" \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    CODEX_BIN="${STUB_DIR}/codex" \
    FUSE_STUB_ANSWER="${answer}" \
    "${RUN_GPT}" "/nonexistent/fuse-test-prompt-${$}.txt" "${out}"
  assert_eq  'gpt 5. unreadable prompt -> exit 65' '65' "${LAST_RC}"

  # 6. relative output path
  local rel_cwd="${TEST_TMP}/gpt-rel"
  mkdir -p "${rel_cwd}"
  local rel_name="gpt-rel.out"
  (
    cd "${rel_cwd}"
    env -i \
      PATH="${STUB_DIR}:/usr/bin:/bin" \
      HOME="${HOME}" \
      CODEX_BIN="${STUB_DIR}/codex" \
      FUSE_STUB_ANSWER="STUB_GPT_RELPATH" \
      "${RUN_GPT}" "${prompt}" "${rel_name}" >/dev/null 2>&1
  )
  rc=$?
  assert_eq  'gpt 6. relative path -> exit 0' '0' "${rc}"
  assert_file_contains 'gpt 6. relative path -> file at caller cwd' \
    'STUB_GPT_RELPATH' "${rel_cwd}/${rel_name}"
}

# ============================================================
# Run
# ============================================================
run_opus_cases
run_minimax_cases
run_gpt_cases

printf '\n========== test_runner_contract summary ==========\n'
printf 'PASS: %d\nFAIL: %d\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  printf '\nFailed cases:\n'
  for c in "${FAILED_CASES[@]}"; do
    printf '  - %s\n' "${c}"
  done
  exit 1
fi
printf 'All runner contract assertions passed.\n'
exit 0
