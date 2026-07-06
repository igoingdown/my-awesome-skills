#!/usr/bin/env bash
# Sync skills from this repo to global agent skill directories.
#   - ~/.agents/skills/   (for OpenClaw)
#   - ~/.claude/skills/   (for Claude Code)
#
# Repo is canonical. This script overwrites any local modifications
# inside the destination skill dirs.
#
# This script is intentionally minimal: it only copies. Per-skill install
# logic (dependency checks, config bootstrap, uninstall) lives inside each
# skill's own install.sh — the skill knows how to install itself.
#
# Usage:
#   ./sync.sh                     Sync ALL skills (default)
#   ./sync.sh <skill-name>        Sync only the specified skill
#   ./sync.sh --list              List available skills
#   ./sync.sh --dry-run [<skill>] Preview without touching files
#   ./sync.sh --help              This help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/skills"

DESTS=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
)

DRY_RUN=0

usage() {
  cat <<EOF
Usage:
  $0                        Sync ALL skills (default)
  $0 <skill-name>           Sync only the specified skill
  $0 --list                 List available skills
  $0 --dry-run [<skill>]    Preview without touching files
  $0 --help                 This help

Destinations:
$(for d in "${DESTS[@]}"; do echo "  - $d"; done)

Per-skill install / config / doctor: run <skill>/install.sh --help
(if the skill ships one). This script only copies files.
EOF
}

require_src() {
  if [[ ! -d "$SRC" ]]; then
    echo "Error: source directory not found: $SRC" >&2
    exit 1
  fi
}

list_skills() {
  require_src
  for d in "$SRC"/*/; do
    [[ -d "$d" ]] || continue
    local name marker
    name="$(basename "$d")"
    if [[ -x "$d/install.sh" ]]; then
      marker=" (has install.sh)"
    else
      marker=""
    fi
    echo "  ${name}${marker}"
  done
}

copy_one() {
  local skill_name="$1"
  local src_dir="$SRC/$skill_name"

  if [[ ! -d "$src_dir" ]]; then
    echo "Error: skill not found: $skill_name" >&2
    exit 1
  fi

  for dest in "${DESTS[@]}"; do
    local target="$dest/$skill_name"
    if (( DRY_RUN )); then
      echo "  (dry-run) would rm -rf $target"
      echo "  (dry-run) would cp -R $src_dir $target"
    else
      mkdir -p "$dest"
      rm -rf "$target"
      cp -R "$src_dir" "$target"
      echo "  ✓ $skill_name → $target"
    fi
  done
}

hint_install_if_any() {
  local skill_name="$1"
  local src_install="$SRC/$skill_name/install.sh"
  if [[ ! -x "$src_install" ]]; then
    return
  fi
  echo ""
  echo "Next step for $skill_name (has install.sh):"
  for dest in "${DESTS[@]}"; do
    local target_install="$dest/$skill_name/install.sh"
    echo "  $target_install --help"
  done
  echo "Typical: ./install.sh doctor   → run self-check"
  echo "         ./install.sh init-config → fill required fields interactively"
}

sync_all() {
  require_src
  echo "Source: $SRC"
  echo ""
  for dest in "${DESTS[@]}"; do
    (( DRY_RUN )) || mkdir -p "$dest"
    echo "→ $dest"
    for skill_dir in "$SRC"/*/; do
      [[ -d "$skill_dir" ]] || continue
      local skill_name target
      skill_name="$(basename "$skill_dir")"
      target="$dest/$skill_name"
      if (( DRY_RUN )); then
        echo "  (dry-run) $skill_name"
      else
        rm -rf "$target"
        cp -R "$skill_dir" "$target"
        echo "  ✓ $skill_name"
      fi
    done
    echo ""
  done
}

sync_one() {
  local skill_name="$1"
  require_src
  echo "Source: $SRC"
  echo ""
  copy_one "$skill_name"
  hint_install_if_any "$skill_name"
}

# ---------- arg parsing ----------

ARGS=()
for a in "$@"; do
  if [[ "$a" == "--dry-run" ]]; then
    DRY_RUN=1
  else
    ARGS+=("$a")
  fi
done
set -- "${ARGS[@]:-}"

case "${1:-}" in
  ""|--all)
    sync_all
    ;;
  --help|-h)
    usage
    ;;
  --list)
    list_skills
    ;;
  --*)
    echo "Error: unknown option: $1" >&2
    echo ""
    usage
    exit 1
    ;;
  *)
    sync_one "$1"
    ;;
esac

echo ""
echo "Done."
echo ""
echo "Note: Claude Code loads skills at session start. Restart Claude Code"
echo "to make newly added skills discoverable."
