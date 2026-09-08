#!/usr/bin/env bash
# Pushes local memory/skill/rule files to Servant, one POST per file.
# Usage: push.sh [claude|cursor] <file>...   (run from the repo root)
# Needs: SERVANT_URL, SERVANT_TOKEN (scope app:agent_memory:write), curl, jq.
set -euo pipefail

tool=${1:-claude}
shift || true
project=$(basename "$PWD")
: "${SERVANT_URL:?set SERVANT_URL}" "${SERVANT_TOKEN:?set SERVANT_TOKEN}"
[ $# -gt 0 ] || { echo "usage: push.sh [claude|cursor] <file>..." >&2; exit 1; }

remote_path() {
  local file
  file=$(realpath -s "$1")
  case "$file" in
    "$HOME/.claude/projects/"*/memory/*) echo "memory/$project/${file##*/memory/}" ;;
    "$HOME/.claude/skills/"*) echo "skills/$tool/${file#"$HOME/.claude/skills/"}" ;;
    "$HOME/.cursor/skills-cursor/"*) echo "skills/$tool/${file#"$HOME/.cursor/skills-cursor/"}" ;;
    */.cursor/rules/*) echo "rules/$project/${file##*/.cursor/rules/}" ;;
  esac
}

for file in "$@"; do
  remote=$(remote_path "$file")
  if [ -z "$remote" ]; then
    echo "skipped      $file (not a memory, skill or rule file)" >&2
    continue
  fi
  jq -n --arg path "$remote" --rawfile body "$file" '{files: [{path: $path, body: $body}]}' |
    curl -sSf -H "Authorization: Bearer $SERVANT_TOKEN" -H 'Content-Type: application/json' \
      -d @- "$SERVANT_URL/api/agent_memory" > /dev/null
  echo "pushed       $remote"
done
