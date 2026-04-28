#!/usr/bin/env bash
# Sync skills from this repo to global agent skill directories.
#   - ~/.agents/skills/   (for OpenClaw)
#   - ~/.claude/skills/   (for Claude Code)
#
# Repo is canonical. Running this script will overwrite any local
# modifications made directly inside the destination skill dirs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/skills"

DESTS=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
)

if [[ ! -d "$SRC" ]]; then
  echo "Error: source directory not found: $SRC" >&2
  exit 1
fi

echo "Source: $SRC"
echo ""

for dest in "${DESTS[@]}"; do
  mkdir -p "$dest"
  echo "→ $dest"
  for skill_dir in "$SRC"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    target="$dest/$skill_name"
    rm -rf "$target"
    cp -R "$skill_dir" "$target"
    echo "  ✓ $skill_name"
  done
  echo ""
done

echo "Done."
echo ""
echo "Note: Claude Code loads skills at session start. Restart Claude Code"
echo "to make newly added skills discoverable."
