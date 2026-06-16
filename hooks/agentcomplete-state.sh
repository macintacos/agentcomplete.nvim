#!/usr/bin/env bash
# Companion hook for agentcomplete.nvim.
#
# Claude Code invokes this on SessionStart / UserPromptSubmit / PostToolUse(Bash)
# / SessionEnd, passing the hook payload as JSON on stdin. It maintains a
# per-session state file at ${XDG_CACHE_HOME:-$HOME/.cache}/agentcomplete/<id>.json
# holding the agent's current working directory, which the Neovim plugin reads to
# detect the external-editor prompt buffer and root @file completion.
set -euo pipefail

input="$(cat)"

# jq parses the JSON payload; without it we no-op rather than guess.
command -v jq >/dev/null 2>&1 || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"

[ -n "$session_id" ] || exit 0

state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentcomplete"
state_file="$state_dir/$session_id.json"

if [ "$event" = "SessionEnd" ]; then
	rm -f "$state_file"
	exit 0
fi

mkdir -p "$state_dir"
jq -n --arg cwd "$cwd" '{cwd: $cwd}' >"$state_file"
