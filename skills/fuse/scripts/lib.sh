# lib.sh — shared helpers for fuse runner scripts (T003).
#
# USAGE: source this file from a runner script that sets its own strict mode:
#
#   #!/usr/bin/env bash
#   set -euo pipefail
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# We intentionally do NOT call `set -euo pipefail` here. This file is
# sourced, not executed; calling it would leak the strict mode into every
# caller's shell, which may not want it. The functions below are written
# to be safe under `set -euo pipefail` when sourced into a script that
# DOES set it: every variable expansion is quoted, every helper is
# `local`-scoped, and no side effects occur at source time.

# make_scratch <label>
#   Create an isolated scratch directory under $TMPDIR via `mktemp -d`
#   (FR-014: never the caller's repo) and echo the absolute path so the
#   caller can capture it AND register an EXIT trap in its own shell
#   to clean it up:
#
#       scratch=$(make_scratch panelist-opus)
#       trap "rm -rf '${scratch}'" EXIT
#
#   Why the trap lives in the caller, not in this function: this helper
#   is documented to be called as `$(make_scratch ...)`, which runs the
#   function body in a subshell. Any EXIT trap set inside that subshell
#   fires the moment the subshell ends — i.e. before the parent can use
#   the dir — and removes the very thing the caller just asked for. The
#   caller-side trap above is the only correct shape.
#
#   `-t` forces the dir under $TMPDIR (mktemp's default on GNU),
#   never under the caller's CWD. Template `fuse.<label>.XXXXXX` makes
#   scratch dirs easy to spot in `ls /tmp`.
make_scratch() {
  local label="${1:-scratch}"
  mktemp -d -t "fuse.${label}.XXXXXX"
}

# safe_log <message>
#   Write <message> to stderr, redacting any substring that looks like
#   a secret. Recognized shapes (FR-014, SC-007, Constitution IV):
#     - `sk-<token>` (OpenAI-style key, >=8 chars of token)
#     - `Bearer <token>` (Authorization header value, >=8 chars of token)
#     - the literal value of $MINIMAX_API_KEY, $ANTHROPIC_API_KEY, or
#       $ANTHROPIC_AUTH_TOKEN if set in the environment
#   Each match is replaced with `<redacted len=NN>` where NN is the byte
#   length of the original. Plain messages pass through unchanged.
safe_log() {
  local msg="${1-}"
  # 1) Redact any literal value of a known secret env var. The length
  #    is known up front from `${#val}`, so a length-only placeholder
  #    can be produced in a single bash parameter-expansion.
  local var val
  for var in MINIMAX_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    if [[ -n "${!var-}" ]]; then
      val="${!var}"
      msg="${msg//${val}/<redacted len=${#val}>}"
    fi
  done
  # 2) Shape-based redactions. Prefer perl (one pass, length via $&);
  #    fall back to a pure-bash loop if perl is unavailable.
  if command -v perl >/dev/null 2>&1; then
    msg="$(printf '%s' "${msg}" | perl -pe '
      s/sk-[A-Za-z0-9_-]{8,}/"<redacted len=".length($&).">"/ge;
      s/(Bearer\s+)([A-Za-z0-9._-]{8,})/$1."<redacted len=".length($2).">"/ge;
    ')"
  else
    msg="$(_safe_redact_bash "${msg}")"
  fi
  printf '%s\n' "${msg}" >&2
}

# _safe_redact_bash <input>
#   Pure-bash fallback for shape-based redaction (sk-, Bearer). Walks
#   the input once and rebuilds it with each match replaced by
#   `<redacted len=NN>`. Prefer the perl path in safe_log; this exists
#   so a host with no perl still respects the contract.
_safe_redact_bash() {
  local input="$1" out="" rest="$1" match
  local sk_re='sk-[A-Za-z0-9_-]{8,}'
  local br_re='Bearer[[:space:]]+[A-Za-z0-9._-]{8,}'
  while :; do
    if [[ "${rest}" =~ ${sk_re} ]]; then
      match="${BASH_REMATCH[0]}"
      out+="${rest%%${match}*}<redacted len=${#match}>"
      rest="${rest#*${match}}"
    elif [[ "${rest}" =~ ${br_re} ]]; then
      match="${BASH_REMATCH[0]}"
      out+="${rest%%${match}*}<redacted len=${#match}>"
      rest="${rest#*${match}}"
    else
      out+="${rest}"
      break
    fi
  done
  printf '%s' "${out}"
}

# fuse_isolate_config_dir <scratch_dir>
#   Echo an ISOLATED, per-call claude config dir for the panelist when
#   TG_FUSE_ISOLATE=1 is in the env, or echo nothing otherwise.
#
#   Why this exists: two concurrent claude panelists sharing the same
#   HOME race for the same mutable .credentials.json and wedge on its
#   lock (the proven Phase-0 hang in specs/015-fuse-from-telegram).
#   Giving each call its OWN seeded copy eliminates the contention:
#   the file content is shared, the FILE is not.
#
#   Activation: TG_FUSE_ISOLATE=1 is set ONLY by the telegram-daemon
#   fuse/ultraplan route arm. Interactive /fuse does NOT set it, so
#   this is a no-op there (single caller, no contention to fix).
#
#   Behavior when active:
#     - source = CLAUDE_CONFIG_DIR or HOME/.claude
#     - if no .credentials.json there -> echo nothing (no auth to share)
#     - else: make <scratch>/claude-cfg (0700), copy the creds file
#       into it (0600), echo the new dir path. Caller exports
#       CLAUDE_CONFIG_DIR=<that path> for the spawned claude.
#
#   Hard rule: never echo or log the credential CONTENTS -- only the
#   directory path. safe_log is not used here (paths are not secrets).
fuse_isolate_config_dir() {
  local scratch="${1:?fuse_isolate_config_dir: scratch dir required}"
  # No-op unless the daemon route arm set the toggle.
  if [[ "${TG_FUSE_ISOLATE:-0}" != "1" ]]; then
    return 0
  fi
  local src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local creds="${src}/.credentials.json"
  if [[ ! -f "${creds}" ]]; then
    return 0
  fi
  # Fresh subdir of the caller scratch. chmod 700 (runner is the only
  # writer; spawned claude reads it). File copy chmod 600 mirrors the
  # source mode (oauth creds are owner-only). Never log the file --
  # only the path.
  local iso="${scratch}/claude-cfg"
  mkdir -p "${iso}"
  chmod 700 "${iso}"
  # install(1): atomic copy + mode in one call (no 644 window).
  install -m 600 "${creds}" "${iso}/.credentials.json"
  printf "%s" "${iso}"
}


# with_timeout SECONDS cmd args...
#   Run `cmd args...` under coreutils `timeout` if available; otherwise
#   invoke `cmd args...` directly. Graceful degradation: a box without
#   coreutils `timeout` still runs the command, just without a
#   wall-clock cap. Argv boundaries are preserved by using `"$@"` after
#   the seconds argument. The exit code reflects the underlying
#   command (or 124 on timeout, per coreutils).
with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    # --kill-after: if the command ignores SIGTERM at the deadline, follow up
    # with SIGKILL after a 15s grace so a wedged backend (and its children,
    # via the same process group) cannot outlive the cap. Exit 124 on timeout.
    timeout --kill-after=15 "${seconds}" "$@"
  else
    "$@"
  fi
}
