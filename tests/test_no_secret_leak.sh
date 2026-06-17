#!/usr/bin/env bash
# test_no_secret_leak.sh — T019
#
# Verifies that the lib.sh safe_log redaction + the three panelist runners
# (run_opus.sh, run_minimax.sh, run_gpt.sh) never echo backend credentials
# into any user-facing artifact (FR-014, SC-007):
#
#   "No backend credential ever appears in any prompt, output, log, or
#    receipt."  (SC-007)
#
# NO live API spend. All backends are stubbed on PATH / MM_BIN / CODEX_BIN
# (same pattern as test_runner_contract.sh). REAL-LOOKING fake secrets are
# set in the runner's environment so that any path that accidentally logs,
# writes, or passes them through is caught by the grep.
#
# Test groups:
#   1) lib.sh unit test — direct calls to safe_log with strings containing
#      fake secrets; assert raw secret does NOT appear in stderr and a
#      `<redacted ...>` marker DOES appear.
#   2) Per-runner integration test (stubbed happy path) — run each runner
#      with fake secrets in env; grep (a) the output file the runner writes
#      and (b) the runner's own captured stdout/stderr. Assert no secret
#      shapes match. (The scratch dir is internal/ephemeral — rm'd on EXIT
#      by the runner's caller-side trap — and is intentionally not in the
#      leak-scope: the runner's job is to keep the user-facing answer
#      clean and use safe_log for diagnostics.)
#   3) Adversarial: the stub backends intentionally echo their env to
#      stderr (simulating a leaky / misbehaving backend). The runner
#      captures that into its scratch dir. We assert the runner's
#      USER-FACING output_file STILL does not contain the leaked value,
#      proving the runner's "write clean answer to <output_file>" path
#      is hermetic regardless of backend noise.
#
# Secret patterns tested (must match spec / FR-014 / SC-007):
#   - sk-[A-Za-z0-9_-]{8,}       (OpenAI / MiniMax key shape)
#   - MINIMAX_API_KEY=           (env var name in any output)
#   - ANTHROPIC_API_KEY=         (env var name in any output)
#   - ANTHROPIC_AUTH_TOKEN=      (env var name in any output)
#   - Bearer <token>             (Authorization header shape)
#
# Style: plain bash assertions; PASS / FAIL printed per case; non-zero
# exit if any leak is found. Deterministic — no sleeps, no retry loops.

set -uo pipefail
# NOTE: deliberately NOT `set -e`. We want each failing assertion to be
# COUNTED and the script to continue through all cases, not abort on the
# first failure. The assertion helpers also keep their own bookkeeping
# so the summary at the end is faithful.

# --- Locate repo paths (no dependency on cwd) ---
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUSE_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
LIB_SH="${FUSE_ROOT}/skills/fuse/scripts/lib.sh"
RUNNERS_DIR="${FUSE_ROOT}/skills/fuse/scripts"
RUN_OPUS="${RUNNERS_DIR}/run_opus.sh"
RUN_MINIMAX="${RUNNERS_DIR}/run_minimax.sh"
RUN_GPT="${RUNNERS_DIR}/run_gpt.sh"

for f in "${LIB_SH}" "${RUN_OPUS}" "${RUN_MINIMAX}" "${RUN_GPT}"; do
  if [[ ! -r "${f}" ]]; then
    printf 'FATAL: file not found: %s\n' "${f}" >&2
    exit 99
  fi
done

# --- Real-looking fake secrets ---
# Intentionally NOT valid API keys — they have the SHAPE of real keys (so
# any redaction logic that pattern-matches "looks like an API key" is
# exercised) but the `sk-fake-` / `sk-ant-fake-` / `anthropic-fake-` /
# `fake-bearer-token-` prefixes make them obviously test-only. They are
# long enough to clear the >=8 char shape gate in lib.sh.
FAKE_MINIMAX_KEY='sk-fake-test-deadbeef1234567890'
FAKE_ANTHROPIC_KEY='sk-ant-fake-aabbccdd11223344'
FAKE_ANTHROPIC_TOKEN='anthropic-fake-token-eeff00112233'
FAKE_BEARER='Bearer fake-bearer-token-zzz9999'
FAKE_SK_SHAPE='sk-shape-test-1234567890'

# --- Forbidden secret pattern (ERE). Matches all shapes called out in
#     the spec / contract; if any of these appear in a user-facing
#     artifact the test fails. ---
SECRET_PATTERN='sk-[A-Za-z0-9_-]{8,}|MINIMAX_API_KEY=|ANTHROPIC_API_KEY=|ANTHROPIC_AUTH_TOKEN=|Bearer[[:space:]]+[A-Za-z0-9._-]{8,}'

# --- Counters ---
PASS=0
FAIL=0
FAILED_CASES=()
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

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf '  PASS  %s (no leak of %q)\n' "${label}" "${needle}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s (LEAKED %q in: %s)\n' "${label}" "${needle}" "${haystack}"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("${label}")
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    printf '  PASS  %s (found %q)\n' "${label}" "${needle}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s (missing %q in: %s)\n' "${label}" "${needle}" "${haystack}"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("${label}")
  fi
}

assert_file_contains() {
  local label="$1" file="$2" needle="$3"
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
    printf '  FAIL  %s (missing %q in %s; contents: %s)\n' \
      "${label}" "${needle}" "${file}" "$(cat "${file}" 2>/dev/null | head -c 200)"
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("${label}")
  fi
}

# file_is_clean <file>
#   Greps a file for the forbidden pattern. Returns 0 if clean, 1 if leak.
file_is_clean() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  if grep -qE "${SECRET_PATTERN}" "${file}"; then
    return 1
  fi
  return 0
}

assert_file_clean() {
  local label="$1" file="$2"
  if file_is_clean "${file}"; then
    printf '  PASS  %s (%s: no forbidden pattern)\n' "${label}" "${file}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s (%s contains forbidden patterns):\n' "${label}" "${file}"
    grep -nE "${SECRET_PATTERN}" "${file}" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
    FAILED_CASES+=("${label}")
  fi
}

# --- Test scratch layout ---
TEST_TMP="$(mktemp -d -t fuse-no-secret-leak.XXXXXX)"
trap 'rm -rf "${TEST_TMP}"' EXIT
STUB_DIR="${TEST_TMP}/stubs"
WORK_DIR="${TEST_TMP}/work"
FAKE_MINIMAX_ENV="${TEST_TMP}/minimax.env"
mkdir -p "${STUB_DIR}" "${WORK_DIR}"
printf 'MINIMAX_API_KEY=stub-test-not-a-real-secret\n' > "${FAKE_MINIMAX_ENV}"
chmod 0600 "${FAKE_MINIMAX_ENV}"

# --- Stub backends ---
# Each stub is NOISY BY DESIGN: it echoes the env values it received to
# its own stderr. This simulates a leaky / misbehaving backend — the
# runner has no way to know the env values, and the stub is effectively
# trying to exfiltrate them via its stderr. The runner captures that
# into its scratch dir (which it then rm's on EXIT). The test asserts
# the runner's USER-FACING artifacts (output_file + its own safe_log
# calls) do not propagate the leak.
#
# The stub also writes a benign answer to stdout (or to the -o file for
# codex), which is what the runner reads as the panelist's answer.

# claude stub: writes JSON {result:"STUB_OPUS_OK"} to stdout
cat > "${STUB_DIR}/claude" <<STUB
#!/usr/bin/env bash
# Stub claude — noisy on purpose. Dumps all known secret env vars to
# stderr, then writes a benign answer on stdout. The runner captures
# both streams; the test asserts the user-facing output_file + safe_log
# output do NOT propagate the leak.
echo "claude stub: would leak MINIMAX_API_KEY=\${MINIMAX_API_KEY:-unset} ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:-unset} ANTHROPIC_AUTH_TOKEN=\${ANTHROPIC_AUTH_TOKEN:-unset} ${FAKE_BEARER}" >&2
printf '{"result":"STUB_OPUS_OK"}'
STUB

# mm stub: writes plain text to stdout
cat > "${STUB_DIR}/mm" <<STUB
#!/usr/bin/env bash
# Stub mm — noisy on purpose.
echo "mm stub: would leak MINIMAX_API_KEY=\${MINIMAX_API_KEY:-unset} ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:-unset} ANTHROPIC_AUTH_TOKEN=\${ANTHROPIC_AUTH_TOKEN:-unset} ${FAKE_BEARER}" >&2
printf 'STUB_MM_OK'
STUB

# codex stub: writes JSON to -o file
cat > "${STUB_DIR}/codex" <<STUB
#!/usr/bin/env bash
# Stub codex — noisy on purpose. Walks argv to find the -o target.
echo "codex stub: would leak MINIMAX_API_KEY=\${MINIMAX_API_KEY:-unset} ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:-unset} ANTHROPIC_AUTH_TOKEN=\${ANTHROPIC_AUTH_TOKEN:-unset} ${FAKE_BEARER}" >&2
out_file=""
prev=""
for arg in "\$@"; do
  if [[ "\${prev}" == "-o" ]]; then out_file="\${arg}"; fi
  prev="\${arg}"
done
[[ -n "\${out_file}" ]] && printf '{"result":"STUB_CODEX_OK"}' > "\${out_file}"
STUB

# Make stubs executable. `chmod` may be denied in some sandboxes; fall
# back to `python3 os.chmod` per the task brief.
for s in claude mm codex; do
  if ! chmod 0755 "${STUB_DIR}/${s}" 2>/dev/null; then
    python3 -c "import os; os.chmod('${STUB_DIR}/${s}', 0o755)"
  fi
done

# --- run_case_capture: run a command in a hermetic env with fake
#     secrets set, capture stdout+stderr to per-case files, set LAST_RC.
#     Args: label, then env-vars, runner, runner-args. ---
run_case_capture() {
  local label="$1"
  shift
  local stdout_file="${TEST_TMP}/${label}.stdout"
  local stderr_file="${TEST_TMP}/${label}.stderr"
  : > "${stdout_file}"
  : > "${stderr_file}"
  set +e
  env -i \
    PATH="${STUB_DIR}:/usr/bin:/bin" \
    HOME="${HOME}" \
    MINIMAX_API_KEY="${FAKE_MINIMAX_KEY}" \
    ANTHROPIC_API_KEY="${FAKE_ANTHROPIC_KEY}" \
    ANTHROPIC_AUTH_TOKEN="${FAKE_ANTHROPIC_TOKEN}" \
    MINIMAX_ENV_FILE="${FAKE_MINIMAX_ENV}" \
    MM_BIN="${STUB_DIR}/mm" \
    CODEX_BIN="${STUB_DIR}/codex" \
    "$@" \
    > "${stdout_file}" 2> "${stderr_file}"
  LAST_RC=$?
  set +u
  LAST_RC="${LAST_RC:-0}"
  set -u
}

# ============================================================
# Group 1: lib.sh unit test (safe_log)
# ============================================================
group_libsh() {
  printf '\n[lib.sh safe_log unit test]\n'
  # Source lib.sh at function scope. lib.sh defines functions only and
  # has no source-time side effects (per its own contract), so this is
  # safe in the parent shell. We do NOT use a subshell here — a
  # subshell would isolate PASS/FAIL/FAILED_CASES mutations and the
  # summary at the end would be wrong.
  # shellcheck disable=SC1091
  source "${LIB_SH}"

  # Save any pre-existing env values so we can restore them at the end
  # (the parent shell may have these set in its real env; we don't want
  # to clobber them).
  local _saved_minimax="${MINIMAX_API_KEY-}"
  local _saved_anthropic="${ANTHROPIC_API_KEY-}"
  local _saved_token="${ANTHROPIC_AUTH_TOKEN-}"

  local out

  # --- 1.1: env value redaction (MINIMAX_API_KEY) ---
  export MINIMAX_API_KEY="${FAKE_MINIMAX_KEY}"
  out=$(safe_log "debug: env shows MINIMAX_API_KEY=${MINIMAX_API_KEY}" 2>&1)
  unset MINIMAX_API_KEY
  assert_not_contains 'libsh 1.1 MINIMAX_API_KEY value redacted' "${out}" "${FAKE_MINIMAX_KEY}"
  assert_contains    'libsh 1.1 <redacted> marker present'         "${out}" '<redacted'

  # --- 1.2: env value redaction (ANTHROPIC_API_KEY) ---
  export ANTHROPIC_API_KEY="${FAKE_ANTHROPIC_KEY}"
  out=$(safe_log "auth=${ANTHROPIC_API_KEY}" 2>&1)
  unset ANTHROPIC_API_KEY
  assert_not_contains 'libsh 1.2 ANTHROPIC_API_KEY value redacted' "${out}" "${FAKE_ANTHROPIC_KEY}"
  assert_contains    'libsh 1.2 <redacted> marker present'         "${out}" '<redacted'

  # --- 1.3: env value redaction (ANTHROPIC_AUTH_TOKEN) ---
  export ANTHROPIC_AUTH_TOKEN="${FAKE_ANTHROPIC_TOKEN}"
  out=$(safe_log "token=${ANTHROPIC_AUTH_TOKEN}" 2>&1)
  unset ANTHROPIC_AUTH_TOKEN
  assert_not_contains 'libsh 1.3 ANTHROPIC_AUTH_TOKEN value redacted' "${out}" "${FAKE_ANTHROPIC_TOKEN}"
  assert_contains    'libsh 1.3 <redacted> marker present'             "${out}" '<redacted'

  # --- 1.4: shape-based redaction (sk-...) ---
  out=$(safe_log "key=${FAKE_SK_SHAPE}" 2>&1)
  assert_not_contains 'libsh 1.4 sk- shape redacted'       "${out}" "${FAKE_SK_SHAPE}"
  assert_contains    'libsh 1.4 <redacted> marker present' "${out}" '<redacted'

  # --- 1.5: shape-based redaction (Bearer ...) ---
  out=$(safe_log "Authorization: ${FAKE_BEARER}" 2>&1)
  assert_not_contains 'libsh 1.5 Bearer shape redacted'     "${out}" "${FAKE_BEARER}"
  assert_contains    'libsh 1.5 <redacted> marker present' "${out}" '<redacted'

  # --- 1.6: combined message redacts multiple shapes ---
  out=$(safe_log "sk-fake-aaaa1111aaaa1111 and Bearer fake-bbbb2222bbbb2222 and key=value" 2>&1)
  assert_not_contains 'libsh 1.6 sk- shape redacted in combined msg' "${out}" 'sk-fake-aaaa1111aaaa1111'
  assert_not_contains 'libsh 1.6 Bearer shape redacted in combined msg' "${out}" 'Bearer fake-bbbb2222bbbb2222'
  assert_contains    'libsh 1.6 <redacted> marker present in combined msg' "${out}" '<redacted'

  # --- 1.7: plain text passes through unchanged ---
  out=$(safe_log "info: nothing sensitive here" 2>&1)
  assert_contains    'libsh 1.7 plain text passes through' "${out}" 'nothing sensitive here'
  assert_not_contains 'libsh 1.7 no <redacted> for plain text' "${out}" '<redacted'

  # Restore pre-existing env values (or leave unset)
  if [[ -n "${_saved_minimax}" ]]; then export MINIMAX_API_KEY="${_saved_minimax}"; fi
  if [[ -n "${_saved_anthropic}" ]]; then export ANTHROPIC_API_KEY="${_saved_anthropic}"; fi
  if [[ -n "${_saved_token}" ]]; then export ANTHROPIC_AUTH_TOKEN="${_saved_token}"; fi
}

# ============================================================
# Group 2: per-runner integration test
# ============================================================
group_runners() {
  printf '\n[runner integration test (stubbed, secrets in env)]\n'

  local prompt="${WORK_DIR}/prompt.txt"
  printf 'panelist prompt: this is a stub test run (T019) - answer verbatim\n' > "${prompt}"

  # --- 2.1: run_opus.sh ---
  printf '\n  -- run_opus.sh --\n'
  local opus_out="${WORK_DIR}/opus.out"
  run_case_capture 'opus' "${RUN_OPUS}" "${prompt}" "${opus_out}"
  assert_eq 'opus exit 0' '0' "${LAST_RC}"
  assert_file_contains 'opus output_file has answer'    "${opus_out}" 'STUB_OPUS_OK'
  assert_file_clean    'opus output_file no secret'     "${opus_out}"
  assert_file_clean    'opus captured stdout no secret' "${TEST_TMP}/opus.stdout"
  assert_file_clean    'opus captured stderr no secret' "${TEST_TMP}/opus.stderr"
  # Adversarial: the stub IS leaking env to its own stderr. That goes
  # into the scratch dir (rm'd on EXIT). The runner did NOT propagate
  # that to the user-facing output_file.
  local opus_body
  opus_body="$(cat "${opus_out}" 2>/dev/null || true)"
  assert_not_contains 'opus output_file no leaked env value'  "${opus_body}" "${FAKE_MINIMAX_KEY}"
  assert_not_contains 'opus output_file no leaked Bearer'     "${opus_body}" "${FAKE_BEARER}"
  assert_not_contains 'opus output_file no env var name'      "${opus_body}" 'MINIMAX_API_KEY='
  assert_not_contains 'opus output_file no ANTHROPIC_API_KEY=' "${opus_body}" 'ANTHROPIC_API_KEY='

  # --- 2.2: run_minimax.sh ---
  printf '\n  -- run_minimax.sh --\n'
  local mm_out="${WORK_DIR}/mm.out"
  run_case_capture 'mm' "${RUN_MINIMAX}" "${prompt}" "${mm_out}"
  assert_eq 'minimax exit 0' '0' "${LAST_RC}"
  assert_file_contains 'minimax output_file has answer'    "${mm_out}" 'STUB_MM_OK'
  assert_file_clean    'minimax output_file no secret'     "${mm_out}"
  assert_file_clean    'minimax captured stdout no secret' "${TEST_TMP}/mm.stdout"
  assert_file_clean    'minimax captured stderr no secret' "${TEST_TMP}/mm.stderr"
  local mm_body
  mm_body="$(cat "${mm_out}" 2>/dev/null || true)"
  assert_not_contains 'minimax output_file no leaked env value' "${mm_body}" "${FAKE_MINIMAX_KEY}"
  assert_not_contains 'minimax output_file no leaked Bearer'    "${mm_body}" "${FAKE_BEARER}"
  assert_not_contains 'minimax output_file no env var name'     "${mm_body}" 'MINIMAX_API_KEY='
  assert_not_contains 'minimax output_file no ANTHROPIC_API_KEY=' "${mm_body}" 'ANTHROPIC_API_KEY='

  # --- 2.3: run_gpt.sh ---
  printf '\n  -- run_gpt.sh --\n'
  local gpt_out="${WORK_DIR}/gpt.out"
  run_case_capture 'gpt' "${RUN_GPT}" "${prompt}" "${gpt_out}"
  assert_eq 'gpt exit 0' '0' "${LAST_RC}"
  assert_file_contains 'gpt output_file has answer'    "${gpt_out}" 'STUB_CODEX_OK'
  assert_file_clean    'gpt output_file no secret'     "${gpt_out}"
  assert_file_clean    'gpt captured stdout no secret' "${TEST_TMP}/gpt.stdout"
  assert_file_clean    'gpt captured stderr no secret' "${TEST_TMP}/gpt.stderr"
  local gpt_body
  gpt_body="$(cat "${gpt_out}" 2>/dev/null || true)"
  assert_not_contains 'gpt output_file no leaked env value' "${gpt_body}" "${FAKE_MINIMAX_KEY}"
  assert_not_contains 'gpt output_file no leaked Bearer'    "${gpt_body}" "${FAKE_BEARER}"
  assert_not_contains 'gpt output_file no env var name'     "${gpt_body}" 'MINIMAX_API_KEY='
  assert_not_contains 'gpt output_file no ANTHROPIC_API_KEY=' "${gpt_body}" 'ANTHROPIC_API_KEY='
}

# ============================================================
# Run
# ============================================================
group_libsh
group_runners

printf '\n========== test_no_secret_leak summary ==========\n'
printf 'PASS: %d\nFAIL: %d\n' "${PASS}" "${FAIL}"
if (( FAIL > 0 )); then
  printf '\nFailed cases:\n'
  for c in "${FAILED_CASES[@]}"; do
    printf '  - %s\n' "${c}"
  done
  exit 1
fi
printf 'All no-leak assertions passed (zero secret-pattern matches in user-facing artifacts).\n'
exit 0
