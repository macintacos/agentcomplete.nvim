#!/usr/bin/env bash
# Stage the Claude Code prompt buffer that assets/demo.tape records.
#
# Runs your own Neovim config on a `claude-prompt-<uuid>.md`, which is all detection
# needs. The context pane finds its session by walking up from Neovim's parent pid, so
# this script registers itself as the Claude Code process for the fixture transcript,
# and must stay Neovim's parent: no `exec`.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
session_id="4e0c7a2d-9b1f-4d8e-a6c3-1f2b3c4d5e6f"
session_file="$HOME/.claude/sessions/$$.json"
# Outside this repo's project slug, so the fixture never shows up in `claude --resume`.
transcript_dir="$HOME/.claude/projects/agentcomplete-demo"
prompt_dir="$(mktemp -d)"
trap 'rm -rf "$session_file" "$transcript_dir" "$prompt_dir"' EXIT

mkdir -p "$(dirname "$session_file")" "$transcript_dir"
printf '{"pid":%d,"sessionId":"%s"}\n' "$$" "$session_id" >"$session_file"
cp "$repo/assets/demo-transcript.jsonl" "$transcript_dir/$session_id.jsonl"

cd "$repo"
# smear-cursor's animation blanks whole frames in vhs's capture and bloats the GIF 5x.
nvim -c 'lua pcall(function() require("smear_cursor").enabled = false end)' \
	"$prompt_dir/claude-prompt-$session_id.md"
