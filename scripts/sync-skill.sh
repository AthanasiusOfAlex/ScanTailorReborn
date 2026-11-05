#!/bin/sh
# The plugin copy of the skill is canonical; mirror it for agents that read the repo directly.
set -e
cd "$(dirname "$0")/.."
src=plugins/scantailor-reborn/skills/scantailor-reborn
for dest in .claude/skills/scantailor-reborn .agents/skills/scantailor-reborn; do
  mkdir -p "$dest"
  cp "$src/SKILL.md" "$dest/SKILL.md"
done
echo "Synced $src to .claude/skills and .agents/skills"
