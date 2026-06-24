#!/usr/bin/env bash
# harness_execute.sh — Stage-3 driver for ultraplan --harness (spec 019, FR-6/FR-7).
#
# Runs tasks.md THROUGH the materialized team. The team-design.json's `routing`
# (task_type -> agent) and `guard_topology` (producer -> reviewer[]) already encode
# the chosen pattern, so dispatch is DATA-DRIVEN — one loop follows the maps, not six
# hardcoded pattern branches. Each task: route -> worker (high-quota pool only) ->
# guard-reviewer -> receipt. opus audit is invoked by the caller (STEP 7, unchanged).
#
# Worker model -> binary: glm-5.2 -> glm-exec (primary) · minimax-m3 -> mm-exec (trivial)
# · claude-sonnet -> sonnet-exec (quality). gpt-5.5/codex are impossible here — the
# materializer (R1) already refused any such pin, so no worker can carry them.
#
# v1 is SEQUENTIAL. --dry-run prints the dispatch plan without invoking any worker.
set -euo pipefail

DESIGN=""; STAGING=""; TASKS=""; DRY_RUN=0
RECEIPTS_DIR="${RECEIPTS_DIR:-.worker-receipts}"

die() { printf 'harness_execute: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --design) DESIGN="$2"; shift 2 ;;
    --staging) STAGING="$2"; shift 2 ;;
    --tasks) TASKS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown arg: $1" ;;
  esac
done
[ -n "$DESIGN" ] && [ -r "$DESIGN" ] || die "missing/unreadable --design"
[ -n "$TASKS" ] && [ -r "$TASKS" ] || die "missing/unreadable --tasks"

# Resolve a worker binary to an absolute path: PATH first, then ~/.local/bin
# (the daemon's exec context does not always carry ~/.local/bin on PATH). Fail closed.
resolve_bin() {
  if command -v "$1" >/dev/null 2>&1; then command -v "$1"
  elif [ -x "$HOME/.local/bin/$1" ]; then printf '%s' "$HOME/.local/bin/$1"
  else die "worker binary '$1' not found on PATH or ~/.local/bin"; fi
}

# Map a worker model pin to its executor binary path. Unknown model = fail closed (the
# materializer's pool is glm-5.2|minimax-m3|claude-sonnet; anything else is a bug).
worker_bin_for() {
  case "$1" in
    glm-5.2) resolve_bin glm-exec ;;
    minimax-m3) resolve_bin mm-exec ;;
    claude-sonnet) resolve_bin sonnet-exec ;;
    *) die "model '$1' is not in the executor pool (materializer R1 should have refused it)" ;;
  esac
}

# Resolve the agent assigned to a task id, and that agent's pinned model, from the
# team-design routing map. Python (not jq) so there is no extra dependency.
agent_for_task() {
  python3 - "$DESIGN" "$1" <<'PY'
import json, sys
design = json.load(open(sys.argv[1]))
task_id = sys.argv[2]
routing = design.get("routing", {})
# routing maps a task_type -> agent name; default to the first producer if no match.
agent = routing.get(task_id) or next(iter(routing.values()), "")
by_name = {a["name"]: a for a in design["roster"]}
chosen = by_name.get(agent) or next((a for a in design["roster"] if a["role"] == "producer"), None)
if chosen is None:
    sys.exit("no producer agent in roster")
reviewers = design.get("guard_topology", {}).get(chosen["name"], [])
print(f"{chosen['name']}\t{chosen['model_pin']}\t{','.join(reviewers)}")
PY
}

# Copy the per-run staging tree to the live project-local .claude only at exec start,
# so non-harness runs keep a pristine .claude (spec 019 materializer note).
promote_staging() {
  [ -n "$STAGING" ] && [ -d "$STAGING/.claude" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then printf '[dry-run] would copy %s/.claude -> ./.claude\n' "$STAGING"; return 0; fi
  mkdir -p ./.claude/agents
  cp -n "$STAGING"/.claude/agents/*.md ./.claude/agents/ 2>/dev/null || true
  printf 'promoted staged team into ./.claude/agents/\n'
}

main() {
  promote_staging
  mkdir -p "$RECEIPTS_DIR"
  # Each numbered task line (- [ ] T0xx ...) is routed to its specialist.
  grep -oE '^- \[[ xX]\] T[0-9]+' "$TASKS" | grep -oE 'T[0-9]+' | while read -r task_id; do
    IFS=$'\t' read -r agent model reviewers < <(agent_for_task "$task_id")
    bin="$(worker_bin_for "$model")"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[dry-run] %s -> agent=%s model=%s bin=%s reviewers=[%s]\n' \
        "$task_id" "$agent" "$model" "$bin" "$reviewers"
      continue
    fi
    printf 'dispatch %s via %s (%s) ...\n' "$task_id" "$bin" "$model"
    # --add-dir "$PWD": the worker's FS scope must include the workspace, else it
    # cannot read tasks.md / write outputs (glm-exec scopes tools to --add-dir paths).
    "$bin" --receipt-dir "$RECEIPTS_DIR" --task-id "$task_id" --add-dir "$PWD" \
      "Execute $task_id from $TASKS as agent $agent; then the guard-reviewer ($reviewers) gates the output."
  done
  printf 'harness execution %s.\n' "$([ "$DRY_RUN" -eq 1 ] && echo 'plan complete (dry run)' || echo complete)"
}

main
