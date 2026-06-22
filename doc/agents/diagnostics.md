# Diagnosing agentcomplete

agentcomplete attaches completion to the prompt buffer an agent CLI opens in Neovim. An
agent session can't launch a second Neovim from itself to watch the plugin, so when
completion misbehaves there ("no completions", "wrong sources", "not detected") the
diagnostics module dumps the live plugin state to a file the agent can read back. This is
the loop to follow before guessing at a fix.

## Workflow

```graphviz
digraph diagnose_agentcomplete {
    "Completion wrong in an agent prompt buffer?" [shape=doublecircle];
    "Can you reach the live prompt buffer?" [shape=diamond];
    "In that buffer: :luafile scripts/diagnostics.lua" [shape=box];
    "No live buffer: mise run diag (headless Claude/blink + OpenCode passes)" [shape=box];
    "Read .tmp/agentcomplete-diagnostics.md (under the editor cwd)" [shape=box];
    "Inspect: session.tool, buffer detected, discovery counts, blink 'Likely cause'" [shape=box];
    "Wrong tool / not detected?" [shape=diamond];
    "Verify the detection signal (table below)" [shape=box];
    "0 skills / commands / files?" [shape=diamond];
    "Check session.skill_dirs / command_dirs — discovery looked in the wrong place" [shape=box];
    "blink showing extra sources?" [shape=diamond];
    "Read the 'Likely cause' line — it walks the suppression mechanism in failure order" [shape=box];

    "Completion wrong in an agent prompt buffer?" -> "Can you reach the live prompt buffer?";
    "Can you reach the live prompt buffer?" -> "In that buffer: :luafile scripts/diagnostics.lua" [label="yes"];
    "Can you reach the live prompt buffer?" -> "No live buffer: mise run diag (headless Claude/blink + OpenCode passes)" [label="no"];
    "In that buffer: :luafile scripts/diagnostics.lua" -> "Read .tmp/agentcomplete-diagnostics.md (under the editor cwd)";
    "Read .tmp/agentcomplete-diagnostics.md (under the editor cwd)" -> "Inspect: session.tool, buffer detected, discovery counts, blink 'Likely cause'";
    "No live buffer: mise run diag (headless Claude/blink + OpenCode passes)" -> "Inspect: session.tool, buffer detected, discovery counts, blink 'Likely cause'";
    "Inspect: session.tool, buffer detected, discovery counts, blink 'Likely cause'" -> "Wrong tool / not detected?";
    "Wrong tool / not detected?" -> "Verify the detection signal (table below)" [label="yes"];
    "Wrong tool / not detected?" -> "0 skills / commands / files?" [label="no"];
    "0 skills / commands / files?" -> "Check session.skill_dirs / command_dirs — discovery looked in the wrong place" [label="yes"];
    "0 skills / commands / files?" -> "blink showing extra sources?" [label="no"];
    "blink showing extra sources?" -> "Read the 'Likely cause' line — it walks the suppression mechanism in failure order" [label="yes"];
}
```

## Detection signals

How each tool's prompt buffer is recognized (detectors live under
`lua/agentcomplete/detect/`):

| Tool | Signal | cwd |
| --- | --- | --- |
| Claude Code | buffer name matches `claude-prompt-<uuid>.md` | editor cwd (project root) |
| OpenCode | `vim.env.OPENCODE == "1"` (set for every OpenCode command, inherited by the spawned editor) **and** buffer basename matches `<digits>.md` | editor cwd (project root) |

Both honor `$AGENTCOMPLETE_CWD` / `vim.g.agentcomplete_cwd` to override the cwd.
OpenCode's temp file has no tool-specific name — it is a bare `<epoch-millis>.md` in the
system temp dir — which is why detection keys on the inherited `OPENCODE` env var rather
than the buffer name.

## What the report contains

- `## Config` — configured vs. resolved backend, detect mode, `enabled`, the `sources`
  toggles, and `allowed_sources`.
- `## Detection` — whether the current buffer is detected, the session source, the
  resolved `session.tool`, and the `skill_dirs` / `command_dirs` discovery actually
  searched.
- `## Discovery` — counts of skills, commands, and files found for the active session. For
  OpenCode it also reports a separate `skills (opencode debug skill)` count — the
  CLI-resolved set (see `lua/agentcomplete/opencode_skills.lua`) merged into completion.
  That count is async: it populates ~0.7s after the buffer attaches, so a live `:luafile`
  run shows it, but a fresh `mise run diag` (which exits immediately) reports 0.
- `## blink suppression` — the only-source suppression diagnosis, ending in a single
  "Likely cause" line that walks the mechanism in the order failures actually occur, so it
  points straight at the fix.
- `## Environment` — the raw detection signals (`OPENCODE`, `OPENCODE_PID`, `AGENT`,
  `CLAUDE_CODE_SESSION_ID`, `$AGENTCOMPLETE_CWD`, `$OPENCODE_CONFIG_DIR`,
  `$XDG_CONFIG_HOME`, …).

## Running it

- **From a live prompt buffer** (the real one the agent opened):
  `:luafile scripts/diagnostics.lua` — optionally `:AgentCompleteAttach` first to force a
  session if the buffer wasn't auto-detected. It writes
  `.tmp/agentcomplete-diagnostics.md` under the editor's working directory and prints the
  report to `:messages`.
- **Headless, with no live buffer**: `mise run diag` runs the same flow in two passes — a
  Claude Code / blink pass against a real blink setup (validating that only-source
  suppression removes `path`) and an OpenCode pass (`OPENCODE=1` on a `<digits>.md`
  buffer, confirming detection reports `session.tool: opencode` with the resolved OpenCode
  search dirs).
