#!/usr/bin/env bash
# test_downgrade.sh — verify graceful-downgrade behavior of detect_panel.sh
# (T020). FR-011 / SC-004:
#
#   "An absent panelist is NEVER treated as agreement (or as a vote).
#    The user is told what was dropped and how to enable it, and the
#    missing panelist is treated as absent, not as a silent agreement."
#
# The detector runs BEFORE any panelist; it inspects CODEX_BIN, MM_BIN,
# MINIMAX_ENV_FILE, and PATH. When a backend's runner would return 127
# (backend missing), the detector reports it as MISSING with a
# human-readable reason, the SLUG excludes it, and the run proceeds on
# the remaining panelists. The missing line is DISTINCT from an
# "available" line — a missing panelist is never in the SLUG.
#
# No live spend: same stub/env-override pattern as test_detect_panel.sh.
#   - Stub claude on PATH (anchor always present per the contract).
#   - CODEX_BIN, MM_BIN, MINIMAX_ENV_FILE point at nonexistent paths to
#     hide a backend. The detector only checks -x / -e; the real
#     backend is never invoked.
#   - Real key never read; the stub env file is checked by -e only.
#
# Style: plain bash assertions; PASS / FAIL per assertion; non-zero
# exit if any FAIL. Deterministic — no sleeps, no retry loops.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="${SCRIPT_DIR}/../skills/fuse/scripts/detect_panel.sh"

if [[ ! -r "${DETECT}" ]]; then
  echo "FATAL: detect_panel.sh not readable at ${DETECT}" >&2
  exit 2
fi

# --- Per-run scratch: isolated stub PATH + stub key file. ---
SCRATCH="$(mktemp -d -t fusedown.XXXXXX)"
trap 'rm -rf "${SCRATCH}"' EXIT

STUB_BIN="${SCRATCH}/bin"
STUB_ENV="${SCRATCH}/minimax.env"
mkdir -p "${STUB_BIN}"

# Stub executables — exit 0; the probe only checks -x. Real binaries
# are never invoked.
for name in claude codex mm gemini; do
  cat >"${STUB_BIN}/${name}" <<STUB
#!/usr/bin/env bash
# stub for tests/test_downgrade.sh — never invoked by the probe
exit 0
STUB
  chmod 755 "${STUB_BIN}/${name}"
done

# Stub minimax env — never read by detect_panel.sh (only -e checked).
# Real key is never touched; this is a fixture only.
cat >"${STUB_ENV}" <<'STUB'
# STUB FIXTURE — not a real key. test_downgrade.sh only.
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

# --- Helpers ---
pass=0
fail=0
case_no=0

# run_probe <env_assignments...>
#   Runs detect_panel.sh with isolated PATH plus caller-supplied env.
#   Echoes the probe's stdout.
run_probe() {
  env -i \
    HOME="${HOME:-/tmp/fuse-test-home}" \
    PATH="${BASE_PATH}" \
    "$@" \
    bash "${DETECT}" 2>/dev/null
}

# extract_line <pattern> <output>
#   Echoes the first line matching the regex pattern, or empty.
extract_line() {
  local pattern="$1" output="$2"
  printf '%s\n' "${output}" | grep -E "^${pattern}" | head -n1
}

# extract_slug <output>
extract_slug() {
  printf '%s\n' "$1" | awk -F= '/^SLUG=/{print $2; exit}'
}

# extract_missing_reason <panelist> <output>
#   Echoes the content inside the parens of a
#   "<panelist>: missing (<reason>)" line, or empty.
extract_missing_reason() {
  local panelist="$1" output="$2"
  printf '%s\n' "${output}" | \
    sed -nE "s/^${panelist}: missing \\((.*)\\)\$/\1/p" | head -n1
}

# assert <label> <0|1> [detail]
#   Records PASS/FAIL, prints one line. detail (optional) prints under
#   a FAIL for fast diagnosis.
assert() {
  local label="$1" condition="$2" detail="${3:-}"
  case_no=$((case_no + 1))
  if [[ "${condition}" == "1" ]]; then
    pass=$((pass + 1))
    printf '  [PASS] %2d  %s\n' "${case_no}" "${label}"
  else
    fail=$((fail + 1))
    printf '  [FAIL] %2d  %s\n' "${case_no}" "${label}" >&2
    if [[ -n "${detail}" ]]; then
      printf '         %s\n' "${detail}" >&2
    fi
  fi
}

# ============================================================
# Case 1: codex hidden via CODEX_BIN (runner's 127 path)
# ============================================================
# When run_gpt.sh's codex probe fails, run_gpt.sh exits 127; the
# orchestrator treats that as "gpt dropped" (FR-011). The detector
# must mirror that: a missing codex => a "gpt: missing (...)" line,
# NOT in the SLUG, run still proceeds on {opus, minimax}.
out="$(run_probe \
  CODEX_BIN="${HIDDEN_CODEX}" \
  MM_BIN="${STUB_BIN}/mm" \
  MINIMAX_ENV_FILE="${STUB_ENV}")"

printf '\n[case 1: codex hidden — CODEX_BIN=%s]\n' "${HIDDEN_CODEX}"

gpt_missing_line="$(extract_line 'gpt: missing' "${out}")"
gpt_reason="$(extract_missing_reason 'gpt' "${out}")"
gpt_avail_count="$(printf '%s\n' "${out}" | grep -c '^gpt: available')"
actual_slug="$(extract_slug "${out}")"

assert "gpt: missing (...) line emitted" \
  "$([[ -n "${gpt_missing_line}" ]] && echo 1 || echo 0)" \
  "no 'gpt: missing (...)' line in output"

assert "gpt missing reason is non-empty + informative" \
  "$([[ -n "${gpt_reason}" && "${gpt_reason}" != 'missing' ]] && echo 1 || echo 0)" \
  "reason was: '${gpt_reason}'"

assert "gpt: available is NOT present (NOT counted as available)" \
  "$([[ "${gpt_avail_count}" -eq 0 ]] && echo 1 || echo 0)" \
  "found ${gpt_avail_count} 'gpt: available' line(s); expected 0"

assert "SLUG climbs to opus-minimax (run still proceeds)" \
  "$([[ "${actual_slug}" == "opus-minimax" ]] && echo 1 || echo 0)" \
  "expected SLUG=opus-minimax; got SLUG=${actual_slug}"

case "${actual_slug}" in
  *gpt*)
    assert "gpt NOT in SLUG (absent != agreement)" "0" \
      "gpt leaked into SLUG: ${actual_slug}"
    ;;
  *)
    assert "gpt NOT in SLUG (absent != agreement)" "1"
    ;;
esac

# ============================================================
# Case 2: mm hidden via MM_BIN (runner's 127 path)
# ============================================================
# When run_minimax.sh's mm probe fails, run_minimax.sh exits 127; the
# orchestrator treats that as "minimax dropped". Detector must mirror:
# a missing mm => a "minimax: missing (...)" line, NOT in the SLUG,
# run still proceeds on {opus, gpt}.
out="$(run_probe \
  CODEX_BIN="${STUB_BIN}/codex" \
  MM_BIN="${HIDDEN_MM}" \
  MINIMAX_ENV_FILE="${STUB_ENV}")"

printf '\n[case 2: mm hidden — MM_BIN=%s]\n' "${HIDDEN_MM}"

mm_missing_line="$(extract_line 'minimax: missing' "${out}")"
mm_reason="$(extract_missing_reason 'minimax' "${out}")"
mm_avail_count="$(printf '%s\n' "${out}" | grep -c '^minimax: available')"
actual_slug="$(extract_slug "${out}")"

assert "minimax: missing (...) line emitted" \
  "$([[ -n "${mm_missing_line}" ]] && echo 1 || echo 0)" \
  "no 'minimax: missing (...)' line in output"

assert "minimax missing reason is non-empty + informative" \
  "$([[ -n "${mm_reason}" && "${mm_reason}" != 'missing' ]] && echo 1 || echo 0)" \
  "reason was: '${mm_reason}'"

assert "minimax: available is NOT present (NOT counted as available)" \
  "$([[ "${mm_avail_count}" -eq 0 ]] && echo 1 || echo 0)" \
  "found ${mm_avail_count} 'minimax: available' line(s); expected 0"

assert "SLUG climbs to opus-gpt (run still proceeds)" \
  "$([[ "${actual_slug}" == "opus-gpt" ]] && echo 1 || echo 0)" \
  "expected SLUG=opus-gpt; got SLUG=${actual_slug}"

case "${actual_slug}" in
  *minimax*)
    assert "minimax NOT in SLUG (absent != agreement)" "0" \
      "minimax leaked into SLUG: ${actual_slug}"
    ;;
  *)
    assert "minimax NOT in SLUG (absent != agreement)" "1"
    ;;
esac

# ============================================================
# Case 3: minimax env file hidden (the OTHER arm of the OR)
# ============================================================
# The detector gates mm on "-x mm AND -e env_file". Hiding the env
# file (the right half of the AND) yields the same "minimax missing"
# outcome; we assert the same "missing line + reason + SLUG drop"
# contract from a different failure mode.
out="$(run_probe \
  CODEX_BIN="${STUB_BIN}/codex" \
  MM_BIN="${STUB_BIN}/mm" \
  MINIMAX_ENV_FILE="${HIDDEN_ENV}")"

printf '\n[case 3: minimax env absent — MINIMAX_ENV_FILE=%s]\n' "${HIDDEN_ENV}"

mm_missing_line="$(extract_line 'minimax: missing' "${out}")"
mm_reason="$(extract_missing_reason 'minimax' "${out}")"
actual_slug="$(extract_slug "${out}")"

assert "minimax: missing (...) line emitted (env-absent arm)" \
  "$([[ -n "${mm_missing_line}" ]] && echo 1 || echo 0)" \
  "no 'minimax: missing (...)' line in output"

assert "minimax env-absent reason is non-empty + informative" \
  "$([[ -n "${mm_reason}" && "${mm_reason}" != 'missing' ]] && echo 1 || echo 0)" \
  "reason was: '${mm_reason}'"

assert "SLUG=opus-gpt (minimax dropped, run still proceeds)" \
  "$([[ "${actual_slug}" == "opus-gpt" ]] && echo 1 || echo 0)" \
  "expected SLUG=opus-gpt; got SLUG=${actual_slug}"

# ============================================================
# Case 4: opus-only — all non-anchor backends hidden
# ============================================================
# Degenerate panel (FR-011 / SC-004). All non-anchor backends missing;
# SLUG=opus-only AND a WARNING line must be emitted so the orchestrator
# (and the user) can see the panel is not a true fusion.
out="$(run_probe \
  CODEX_BIN="${HIDDEN_CODEX}" \
  MM_BIN="${HIDDEN_MM}" \
  MINIMAX_ENV_FILE="${HIDDEN_ENV}")"

printf '\n[case 4: opus-only — all non-anchor backends hidden]\n'

gpt_missing_line="$(extract_line 'gpt: missing' "${out}")"
mm_missing_line="$(extract_line 'minimax: missing' "${out}")"
gpt_reason="$(extract_missing_reason 'gpt' "${out}")"
mm_reason="$(extract_missing_reason 'minimax' "${out}")"
actual_slug="$(extract_slug "${out}")"
warn_count="$(printf '%s\n' "${out}" | grep -c '^WARNING: degenerate panel')"

assert "gpt: missing (...) line emitted in opus-only" \
  "$([[ -n "${gpt_missing_line}" ]] && echo 1 || echo 0)" \
  "no 'gpt: missing (...)' line in output"

assert "minimax: missing (...) line emitted in opus-only" \
  "$([[ -n "${mm_missing_line}" ]] && echo 1 || echo 0)" \
  "no 'minimax: missing (...)' line in output"

assert "gpt missing reason non-empty in opus-only" \
  "$([[ -n "${gpt_reason}" && "${gpt_reason}" != 'missing' ]] && echo 1 || echo 0)" \
  "reason was: '${gpt_reason}'"

assert "minimax missing reason non-empty in opus-only" \
  "$([[ -n "${mm_reason}" && "${mm_reason}" != 'missing' ]] && echo 1 || echo 0)" \
  "reason was: '${mm_reason}'"

assert "SLUG=opus-only (degenerate)" \
  "$([[ "${actual_slug}" == "opus-only" ]] && echo 1 || echo 0)" \
  "expected SLUG=opus-only; got SLUG=${actual_slug}"

assert "WARNING: degenerate panel line present" \
  "$([[ "${warn_count}" -ge 1 ]] && echo 1 || echo 0)" \
  "expected >=1 WARNING line; got ${warn_count}"

# A missing panelist must NEVER be in the SLUG.
case "${actual_slug}" in
  *gpt*|*minimax*)
    assert "SLUG=opus-only — no leaked panelist" "0" \
      "SLUG=${actual_slug} must not contain gpt or minimax"
    ;;
  *)
    assert "SLUG=opus-only — no leaked panelist" "1"
    ;;
esac

# ============================================================
# Summary
# ============================================================
printf '\n%d assertions: %d passed, %d failed\n' "${case_no}" "${pass}" "${fail}"

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi
exit 0
