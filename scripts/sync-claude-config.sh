#!/usr/bin/env bash
#
# Export/import shareable Claude Code configuration (~/.claude) via this
# repository, so custom commands/skills/agents/settings can travel between
# your own devices. Run this locally on each device — it has no effect on
# other machines by itself, you still need to git push/pull in between.
#
# Usage:
#   ./scripts/sync-claude-config.sh export   # local ~/.claude -> repo
#   ./scripts/sync-claude-config.sh import   # repo -> local ~/.claude
#
set -euo pipefail

MODE="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/claude-config"
CLAUDE_HOME="${HOME}/.claude"

SYNCED_ITEMS=(settings.json commands skills agents CLAUDE.md)
SECRET_LIKE_PATTERN='(api[_-]?key|token|secret|authorization|bearer)["\047]?\s*[:=]'

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

check_no_secrets() {
  local f="$1"
  [ -f "$f" ] || return 0
  if grep -Eiq "$SECRET_LIKE_PATTERN" "$f"; then
    die "Possible secret found in $f — remove it (use env vars instead) before syncing."
  fi
}

case "$MODE" in
  export)
    [ -d "$CLAUDE_HOME" ] || die "No ${CLAUDE_HOME} found on this machine."
    mkdir -p "$CONFIG_DIR"
    for item in "${SYNCED_ITEMS[@]}"; do
      src="${CLAUDE_HOME}/${item}"
      [ -e "$src" ] || continue
      if [ -f "$src" ]; then
        check_no_secrets "$src"
      else
        find "$src" -type f -print0 | while IFS= read -r -d '' f; do check_no_secrets "$f"; done
      fi
      rm -rf "${CONFIG_DIR:?}/${item}"
      cp -a "$src" "${CONFIG_DIR}/${item}"
      echo "Exported: ${item}"
    done
    echo
    echo "Now review 'git status' / 'git diff' in ${CONFIG_DIR}, then commit and push."
    ;;

  import)
    [ -d "$CONFIG_DIR" ] || die "No ${CONFIG_DIR} in repo — run 'export' on a source machine first."
    backup="${HOME}/.claude.backup-$(date +%Y%m%d%H%M%S)"
    if [ -d "$CLAUDE_HOME" ]; then
      cp -a "$CLAUDE_HOME" "$backup"
      echo "Backed up existing ${CLAUDE_HOME} to ${backup}"
    fi
    mkdir -p "$CLAUDE_HOME"
    for item in "${SYNCED_ITEMS[@]}"; do
      src="${CONFIG_DIR}/${item}"
      [ -e "$src" ] || continue
      rm -rf "${CLAUDE_HOME:?}/${item}"
      cp -a "$src" "${CLAUDE_HOME}/${item}"
      echo "Imported: ${item}"
    done
    echo
    echo "Done. Restart Claude Code for changes to take effect."
    ;;

  *)
    echo "Usage: $0 {export|import}" >&2
    exit 1
    ;;
esac
