#!/usr/bin/env bash
# Pulls the memory and skills of the current repo from Servant.
# Usage: pull.sh [claude|cursor]   (run from the repo root)
# Needs: SERVANT_URL, SERVANT_TOKEN (scope app:agent_memory:write), curl, jq.
set -euo pipefail

tool=${1:-claude}
project=$(basename "$PWD")
: "${SERVANT_URL:?set SERVANT_URL}" "${SERVANT_TOKEN:?set SERVANT_TOKEN}"

# ponytail: Claude mangles the cwd by swapping "/" for "-"; adjust here if it ever changes.
claude_memory="$HOME/.claude/projects/$(pwd | tr / -)/memory"
case "$tool" in
  claude) skills_dir="$HOME/.claude/skills" ;;
  cursor) skills_dir="$HOME/.cursor/skills-cursor" ;;
  *) echo "unknown tool: $tool" >&2; exit 1 ;;
esac

local_path() {
  case "$1" in
    memory/*) echo "$claude_memory/${1#memory/*/}" ;;
    skills/shared/*) echo "$skills_dir/${1#skills/shared/}" ;;
    skills/claude/*) echo "$HOME/.claude/skills/${1#skills/claude/}" ;;
    skills/cursor/*) echo "$HOME/.cursor/skills-cursor/${1#skills/cursor/}" ;;
    rules/*) echo "$PWD/.cursor/rules/${1#rules/*/}" ;;
  esac
}

curl -sSf -H "Authorization: Bearer $SERVANT_TOKEN" \
  "$SERVANT_URL/api/agent_memory?project=$project&tool=$tool&include=body" |
  jq -r '.data[] | [.path, .sha256, .updated_at, (.body | @base64)] | @tsv' |
  while IFS=$'\t' read -r path sha updated body64; do
    dest=$(local_path "$path")
    [ -n "$dest" ] || continue
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -c1-64)" = "$sha" ]; then
      continue
    fi
    if [ -f "$dest" ] && [ "$(date -r "$dest" +%s)" -gt "$(date -d "$updated" +%s)" ]; then
      echo "LOCAL NEWER  $path  (push it, or merge by hand then push)"
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    printf '%s' "$body64" | base64 -d > "$dest"
    echo "pulled       $path"
  done
