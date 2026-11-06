#!/bin/sh
# The plugin copy of the skill is canonical; mirror it for agents that read the repo directly
# (.claude/skills for Claude Code, .agents/skills for Antigravity).
#   scripts/sync-skill.sh          copy the canonical file over the mirrors
#   scripts/sync-skill.sh --check  exit 1 if a mirror differs (used by scripts/test.sh)
set -e
cd "$(dirname "$0")/.."
src=plugins/scantailor-reborn/skills/scantailor-reborn
dests=".claude/skills/scantailor-reborn .agents/skills/scantailor-reborn"
if [ "${1:-}" = "--check" ]; then
  status=0
  for dest in $dests; do
    if ! cmp -s "$src/SKILL.md" "$dest/SKILL.md"; then
      echo "Skill mirror out of date: $dest (run scripts/sync-skill.sh)" >&2
      status=1
    fi
  done
  exit $status
fi
for dest in $dests; do
  mkdir -p "$dest"
  cp "$src/SKILL.md" "$dest/SKILL.md"
done
echo "Synced $src to .claude/skills and .agents/skills"
