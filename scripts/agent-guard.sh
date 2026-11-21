#!/bin/bash
# Runs the repo checks before a coding agent commits, and blocks the commit if they fail.
# Wired up in .claude/settings.json (PreToolUse on Bash) and .cursor/hooks.json (beforeShellExecution).
# Usage: scripts/agent-guard.sh [claude-code|cursor]  (the hook's JSON on stdin)
set -uo pipefail
tool="${1:-claude-code}"
input="$(cat)"
cmd="$(printf '%s' "$input" | plutil -extract tool_input.command raw -o - - 2>/dev/null \
    || printf '%s' "$input" | plutil -extract command raw -o - - 2>/dev/null || true)"
[[ "$cmd" =~ git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+commit ]] || exit 0

cd "$(dirname "$0")/.."
problems=""
out="$(scripts/leakcheck.sh 2>&1)" || problems+="Leak check failed (make leakcheck):"$'\n'"$out"$'\n'
out="$(scripts/check-core.sh 2>&1)" || problems+="$out"$'\n'
[ -z "$problems" ] && exit 0

if [ "$tool" = cursor ]; then
    msg="$(printf '%s' "$problems" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g' | awk '{printf "%s\\n", $0}')"
    printf '{"permission":"deny","user_message":"Commit blocked: repo checks failed","agent_message":"%s"}\n' "$msg"
    exit 0
fi
printf '%s\nFix these before committing.\n' "$problems" >&2
exit 2
