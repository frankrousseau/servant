#!/usr/bin/env bash
# Pushes local memory/skill/rule files to Servant, one POST per file.
# Usage: push.sh [claude|cursor] <file>...   (run from the repo root)
# Needs: SERVANT_URL, SERVANT_TOKEN (scope app:agent_memory:write), curl, jq.
set -euo pipefail

tool=${1:-claude}
shift || true
project=$(basename "$PWD")
if [[ ! "$project" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "project name \"$project\" is not a valid path segment" >&2
  exit 1
fi
: "${SERVANT_URL:?set SERVANT_URL}" "${SERVANT_TOKEN:?set SERVANT_TOKEN}"
[ $# -gt 0 ] || { echo "usage: push.sh [claude|cursor] <file>..." >&2; exit 1; }

# ponytail: Claude mangles the cwd by swapping "/" for "-"; must match pull.sh's.
claude_memory="$HOME/.claude/projects/$(pwd | tr / -)/memory"

remote_path() {
  local file
  file=$(realpath -s "$1")
  case "$file" in
    "$claude_memory/"*) echo "memory/$project/${file##*/memory/}" ;;
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
  status=$(jq -n --arg path "$remote" --rawfile body "$file" '{files: [{path: $path, body: $body}]}' |
    curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $SERVANT_TOKEN" \
      -H 'Content-Type: application/json' -d @- "$SERVANT_URL/api/agent_memory")
  case "$status" in
    200) echo "pushed       $remote" ;;
    409) echo "DELETED IN SERVANT  $remote  (local file left alone; delete it, or restore it in the app)" ;;
    *) echo "FAILED       $remote  (HTTP $status)" >&2; exit 1 ;;
  esac
done
