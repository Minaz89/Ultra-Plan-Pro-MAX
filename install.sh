#!/usr/bin/env bash
# fuse installer — copy the dev bundle into the user's Claude config.
# Mirrors the fusion-fable install pattern: skill -> ~/.claude/skills/fuse,
# slash-commands -> ~/.claude/commands, runners made executable, then print
# the panel availability detected at the INSTALLED location.
#
# Idempotent: safe to re-run. Never deletes files in the target that aren't
# part of this bundle. Paths with spaces are handled by quoting every
# expansion. Secrets are never echoed — this script does not read any.

set -euo pipefail

# --- Resolve the script's own directory (so cwd is irrelevant). -----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Target directory (overridable, default ~/.claude). -------------------
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

# --- Source layout (relative to the script). -----------------------------
SRC_SKILLS_ROOT="${SCRIPT_DIR}/skills"      # contains fuse/ + ultraplan/ (+ future)
SRC_SKILL_DIR="${SRC_SKILLS_ROOT}/fuse"     # fuse is the engine; the detector lives here
SRC_COMMANDS_DIR="${SCRIPT_DIR}/commands"

# --- Destination layout. -------------------------------------------------
DST_SKILL_DIR="${CLAUDE_CONFIG_DIR}/skills/fuse"
DST_COMMANDS_DIR="${CLAUDE_CONFIG_DIR}/commands"
DST_SCRIPTS_DIR="${DST_SKILL_DIR}/scripts"

# --- Sanity-check the source tree BEFORE touching anything. --------------
if [[ ! -d "${SRC_SKILL_DIR}" ]]; then
  echo "ERROR: source skill dir not found: ${SRC_SKILL_DIR}" >&2
  echo "       (run this from inside the fuse dev bundle, or fix the path)" >&2
  exit 1
fi
if [[ ! -d "${SRC_COMMANDS_DIR}" ]]; then
  echo "ERROR: source commands dir not found: ${SRC_COMMANDS_DIR}" >&2
  exit 1
fi

# --- Banner. ------------------------------------------------------------
echo "fuse installer"
echo "  source:        ${SCRIPT_DIR}"
echo "  target:        ${CLAUDE_CONFIG_DIR}"
echo "  skill bundle:  ${SRC_SKILL_DIR}  ->  ${DST_SKILL_DIR}"
echo "  slash cmds:    ${SRC_COMMANDS_DIR}  ->  ${DST_COMMANDS_DIR}"
echo

# --- Ensure target directories exist. -----------------------------------
mkdir -p -- "${DST_SKILL_DIR}" "${DST_COMMANDS_DIR}"

# --- Copy every skill bundle under skills/ recursively (preserves attrs). -
# cp -a: archive (recursive + preserve mode/ownership/timestamps), does NOT
# remove files already at the destination that aren't in the source, so
# re-running cleanly overlays our bundle without touching anything else.
# Loop over skills/*/ so new skills (e.g. ultraplan) install automatically —
# not just fuse.
shopt -s nullglob
skill_src_dirs=("${SRC_SKILLS_ROOT}"/*/)
shopt -u nullglob
for src in "${skill_src_dirs[@]}"; do
  name="$(basename -- "${src%/}")"
  dst="${CLAUDE_CONFIG_DIR}/skills/${name}"
  mkdir -p -- "${dst}"
  cp -a -- "${src}." "${dst}/"
  echo "installed skill: ${dst}"
  # +x any scripts/*.sh this skill ships.
  if [[ -d "${dst}/scripts" ]]; then
    shopt -s nullglob
    for s in "${dst}/scripts"/*.sh; do chmod +x -- "${s}"; done
    shopt -u nullglob
  fi
done

# --- Copy any *.md commands that currently exist. -----------------------
# `shopt -s nullglob` makes a glob with zero matches expand to nothing
# (instead of the literal pattern), so the loop is a no-op if a future
# bundle has zero commands. Without nullglob, a missing glob would yield
# the literal string and `cp -- "${literal}" dest/` would fail under
# `set -e`. Today the bundle ships three; tomorrow it may grow or shrink.
shopt -s nullglob
cmd_files=("${SRC_COMMANDS_DIR}"/*.md)
shopt -u nullglob

if [[ ${#cmd_files[@]} -eq 0 ]]; then
  echo "installed commands: (none in source — skipped)"
else
  cp -f -- "${cmd_files[@]}" "${DST_COMMANDS_DIR}/"
  for f in "${cmd_files[@]}"; do
    echo "  installed command: $(basename -- "${f}")"
  done
fi

# --- Make installed scripts executable. ---------------------------------
# All *.sh in the installed scripts/ dir get +x. Covers detect_panel.sh
# plus every run_*.sh panelist runner; idempotent. Use a loop (not find
# -exec) so we can quote the path against spaces.
if [[ -d "${DST_SCRIPTS_DIR}" ]]; then
  shopt -s nullglob
  installed_scripts=("${DST_SCRIPTS_DIR}"/*.sh)
  shopt -u nullglob
  for s in "${installed_scripts[@]}"; do
    chmod +x -- "${s}"
  done
  echo "chmod +x: ${#installed_scripts[@]} script(s) under ${DST_SCRIPTS_DIR}"
else
  echo "WARNING: installed scripts dir missing: ${DST_SCRIPTS_DIR}" >&2
fi

# --- Print panel availability from the INSTALLED location. ---------------
# The detector's contract (contracts/runner-contract.md): always exits 0,
# prints per-backend "available"/"missing" lines and a final "SLUG=..."
# line. Running it from the installed path proves the copy worked AND
# shows the user exactly which panelists will fire.
echo
echo "panel availability (from ${DST_SCRIPTS_DIR}/detect_panel.sh):"
echo "----------------------------------------------------------------"
if [[ -x "${DST_SCRIPTS_DIR}/detect_panel.sh" ]]; then
  "${DST_SCRIPTS_DIR}/detect_panel.sh" || true
else
  echo "ERROR: detect_panel.sh not executable at ${DST_SCRIPTS_DIR}" >&2
  echo "       the bundle copy likely failed — re-run the installer" >&2
  exit 1
fi
echo "----------------------------------------------------------------"

echo
echo "fuse installed. /fuse is now available in this Claude session."
