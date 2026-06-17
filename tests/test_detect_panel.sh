#!/usr/bin/env bash
# test_detect_panel.sh — verify detect_panel.sh SLUG logic across
# availability combinations, WITHOUT live backends. T010.
#
# Strategy:
#   1. Build a per-run stub PATH that contains fake `claude`/`codex`/
#      `mm`/`gemini` executables. The stub dir is PREPENDED to a base
#      PATH that includes /usr/bin:/bin, so basic utilities (dirname,
#      awk, grep) resolve, but the stub binaries take precedence for
#      the names the probe actually probes. (Why not stub-only PATH:
#      detect_panel.sh's first line is `dirname "${BASH_SOURCE[0]}"`,
#      and `dirname` lives in /usr/bin — so we must keep /usr/bin in
#      PATH for the script to even start.)
#   2. The two env-overridable backends (gpt/codex via CODEX_BIN,
#      minimax/mm via MM_BIN + MINIMAX_ENV_FILE) are controlled by
#      setting the env to either a stub path (present) or a path
#      under /nonexistent (absent). We never invoke the real backends
#      — the probe is a pure `[[ -x ]]` / `[[ -e ]]` check on paths.
#   3. We never read the real minimax key. The stub minimax.env
#      contains a clearly-marked fixture value.
#
# The probe's machine-readable contract line is `SLUG=...`; the
# orchestrator greps that. We assert on it directly. The degenerate
# opus-only case ALSO emits a "WARNING: degenerate panel ..." line
# per FR-011 / SC-004, which we assert on for the last case.
#
# Cases (per task brief):
#   1. all up (claude+codex+mm+key)  -> SLUG=opus-gpt-minimax
#   2. codex hidden (CODEX_BIN absent) -> SLUG=opus-minimax
#   3. minimax hidden (mm OR env absent) -> SLUG=opus-gpt
#   4. only claude (codex + minimax off)  -> SLUG=opus-only + WARNING

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="${SCRIPT_DIR}/../skills/fuse/scripts/detect_panel.sh"

if [[ ! -r "${DETECT}" ]]; then
  echo "FATAL: detect_panel.sh not readable at ${DETECT}" >&2
  exit 2
fi

# --- Per-run scratch: isolated stub PATH + stub key file. ---
SCRATCH="$(mktemp -d -t fusedetect.XXXXXX)"
trap 'rm -rf "${SCRATCH}"' EXIT

STUB_BIN="${SCRATCH}/bin"
STUB_ENV="${SCRATCH}/minimax.env"
mkdir -p "${STUB_BIN}"

# Stub executables — exit 0; the probe only checks `-x`. Real binaries
# are never invoked.
for name in claude codex mm gemini; do
  cat >"${STUB_BIN}/${name}" <<STUB
#!/usr/bin/env bash
# stub for tests/test_detect_panel.sh — never invoked by the probe
exit 0
STUB
  chmod 755 "${STUB_BIN}/${name}"
done

# Stub minimax env — never read by detect_panel.sh (only `-e` checked),
# but we populate it so a stray inspection never sees an empty file.
# Real key is never touched; this is a fixture only.
cat >"${STUB_ENV}" <<'STUB'
# STUB FIXTURE — not a real key. test_detect_panel.sh only.
MINIMAX_API_KEY=stub-fixture-not-a-real-key
STUB

# Hidden paths — used to simulate an absent backend via env override.
HIDDEN_CODEX="/nonexistent/codex-for-test"
HIDDEN_MM="/nonexistent/mm-for-test"
HIDDEN_ENV="/nonexistent/minimax.env-for-test"

# Base PATH includes /usr/bin:/bin so basic utilities (dirname, awk,
# grep) resolve. Stub bin is prepended so stub binaries take
# precedence over /usr/bin/{claude,codex,mm,gemini}.
BASE_PATH="${STUB_BIN}:/usr/bin:/bin"

# --- Helpers. ---
pass=0
fail=0
case_no=0

# run_probe <env_assignments...>
#   Runs detect_panel.sh with isolated PATH plus any caller-supplied
#   env assignments. Echoes the probe's stdout.
run_probe() {
  env -i \
    HOME="${HOME:-/tmp/fuse-test-home}" \
    PATH="${BASE_PATH}" \
    "$@" \
    bash "${DETECT}" 2>/dev/null
}

# assert_case <label> <expected_slug> <output> [expect_warning]
assert_case() {
  local label="$1" expected_slug="$2" output="$3" expect_warning="${4:-0}"
  case_no=$((case_no + 1))
  local n="${case_no}"

  local actual_slug
  actual_slug="$(printf '%s\n' "${output}" | awk -F= '/^SLUG=/{print $2; exit}')"

  local slug_ok=0
  if [[ "${actual_slug}" == "${expected_slug}" ]]; then
    slug_ok=1
  fi

  local warn_ok=1
  local warn_line
  warn_line="$(printf '%s\n' "${output}" | grep -c '^WARNING: degenerate panel')"
  if [[ "${expect_warning}" == "1" ]]; then
    if [[ "${warn_line}" -lt 1 ]]; then warn_ok=0; fi
  else
    if [[ "${warn_line}" -ge 1 ]]; then warn_ok=0; fi
  fi

  if [[ "${slug_ok}" -eq 1 && "${warn_ok}" -eq 1 ]]; then
    pass=$((pass + 1))
    printf '  [PASS] %d  %-50s  SLUG=%s\n' "${n}" "${label}" "${actual_slug}"
  else
    fail=$((fail + 1))
    printf '  [FAIL] %d  %s\n' "${n}" "${label}" >&2
    printf '         expected SLUG=%s  got SLUG=%s\n' "${expected_slug}" "${actual_slug}" >&2
    if [[ "${expect_warning}" == "1" && "${warn_ok}" -ne 1 ]]; then
      printf '         expected WARNING line, none found\n' >&2
    elif [[ "${expect_warning}" != "1" && "${warn_ok}" -ne 1 ]]; then
      printf '         unexpected WARNING line present\n' >&2
    fi
    printf '         --- full output ---\n%s\n         --- end ---\n' "${output}" >&2
  fi
}

# --- Case 1: all up (claude+codex+mm+key file present). ---
out="$(run_probe \
  CODEX_BIN="${STUB_BIN}/codex" \
  MM_BIN="${STUB_BIN}/mm" \
  MINIMAX_ENV_FILE="${STUB_ENV}")"
assert_case "all up (claude+codex+mm+key)" "opus-gpt-minimax" "${out}" 0

# --- Case 2: codex hidden (CODEX_BIN -> nonexistent). ---
# mm + env still present so the probe climbs to opus-minimax.
out="$(run_probe \
  CODEX_BIN="${HIDDEN_CODEX}" \
  MM_BIN="${STUB_BIN}/mm" \
  MINIMAX_ENV_FILE="${STUB_ENV}")"
assert_case "codex hidden (CODEX_BIN=/nonexistent)" "opus-minimax" "${out}" 0

# --- Case 3a: minimax hidden (mm absent). ---
# Codex present, so the probe climbs to opus-gpt.
out="$(run_probe \
  CODEX_BIN="${STUB_BIN}/codex" \
  MM_BIN="${HIDDEN_MM}" \
  MINIMAX_ENV_FILE="${STUB_ENV}")"
assert_case "minimax hidden (mm absent)" "opus-gpt" "${out}" 0

# --- Case 3b: minimax hidden (env file absent). ---
# Same SLUG expected, different failure mode — exercises the OTHER
# arm of the `-x mm && -e env` check.
out="$(run_probe \
  CODEX_BIN="${STUB_BIN}/codex" \
  MM_BIN="${STUB_BIN}/mm" \
  MINIMAX_ENV_FILE="${HIDDEN_ENV}")"
assert_case "minimax hidden (env absent)" "opus-gpt" "${out}" 0

# --- Case 4: only claude (codex + minimax both off). ---
# Degenerate panel — must emit WARNING + SLUG=opus-only.
out="$(run_probe \
  CODEX_BIN="${HIDDEN_CODEX}" \
  MM_BIN="${HIDDEN_MM}" \
  MINIMAX_ENV_FILE="${HIDDEN_ENV}")"
assert_case "only claude (degenerate)" "opus-only" "${out}" 1

# --- Summary. ---
printf '\n%d cases: %d passed, %d failed\n' "${case_no}" "${pass}" "${fail}"

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
exit 0
