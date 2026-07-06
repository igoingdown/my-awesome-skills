#!/usr/bin/env bash
# Sync skills from this repo to global agent skill directories.
#   - ~/.agents/skills/   (for OpenClaw)
#   - ~/.claude/skills/   (for Claude Code)
#
# Repo is canonical. Running this script will overwrite any local
# modifications made directly inside the destination skill dirs.
#
# Usage:
#   ./sync.sh                     Sync ALL skills (default)
#   ./sync.sh <skill-name>        Sync only the specified skill
#   ./sync.sh --info <skill-name> Print the skill's INSTALL.md, do NOT sync
#   ./sync.sh --list              List available skills
#   ./sync.sh --dry-run [<skill>] Show what would happen without touching files
#   ./sync.sh --help              This help
#
# For skills that ship an INSTALL.md (tools / credentials / porting notes),
# single-skill sync will print it after the copy so you don't miss setup steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/skills"

DESTS=(
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
)

DRY_RUN=0

# ---------- helpers ----------

usage() {
  cat <<EOF
Usage:
  $0                        Sync ALL skills (default)
  $0 <skill-name>           Sync only the specified skill
  $0 --info <skill-name>    Print the skill's INSTALL.md, do NOT sync
  $0 --list                 List available skills
  $0 --dry-run [<skill>]    Preview without touching files
  $0 --help                 This help

Destinations:
$(for d in "${DESTS[@]}"; do echo "  - $d"; done)

After sync, restart Claude Code / OpenClaw so newly added skills are discovered.
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
    local name has_install
    name="$(basename "$d")"
    if [[ -f "$d/INSTALL.md" ]]; then
      has_install=" (has INSTALL.md)"
    else
      has_install=""
    fi
    echo "  ${name}${has_install}"
  done
}

show_info() {
  local skill_name="$1"
  local install_md="$SRC/$skill_name/INSTALL.md"
  if [[ ! -d "$SRC/$skill_name" ]]; then
    echo "Error: skill not found: $skill_name" >&2
    exit 1
  fi
  if [[ ! -f "$install_md" ]]; then
    echo "Error: no INSTALL.md at $install_md" >&2
    echo "This skill does not ship an install manual. Run './sync.sh $skill_name' to just copy it." >&2
    exit 1
  fi
  cat "$install_md"
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
      echo "  ✓ $skill_name → $dest/$skill_name"
    fi
  done
}

print_install_if_any() {
  local skill_name="$1"
  local install_md="$SRC/$skill_name/INSTALL.md"
  if [[ -f "$install_md" ]]; then
    echo ""
    echo "================ INSTALL.md for $skill_name ================"
    cat "$install_md"
    echo "============================================================"
  fi
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
  print_install_if_any "$skill_name"
}

# ---------- arg parsing ----------

# Peel --dry-run wherever it sits.
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
  --info)
    if [[ -z "${2:-}" ]]; then
      echo "Error: --info requires a skill name" >&2
      echo ""
      usage
      exit 1
    fi
    show_info "$2"
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
