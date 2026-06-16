# agentcomplete.nvim

Completion of Claude Code skills, commands, and files inside the prompt buffer that Claude
Code opens in Neovim via its `chat:externalEditor` command (`Ctrl+G`). Works through
[blink.cmp](https://github.com/Saghen/blink.cmp) v2 (preferred, auto-detected) or Neovim's
built-in completion.

> Status: proof of concept.

## How it works

When you press `Ctrl+G` in Claude Code, it writes your prompt to a temporary file and
opens it in `$VISUAL`/`$EDITOR`. The editor it spawns inherits Claude Code's environment —
including `CLAUDE_CODE_SESSION_ID` — and its working directory (your project root).

agentcomplete ships two halves:

1. **A companion Claude Code plugin** whose hooks maintain a small per-session state file
   at `${XDG_CACHE_HOME:-~/.cache}/agentcomplete/<session_id>.json` recording the agent's
   current working directory.
2. **The Neovim plugin**, which on startup reads `CLAUDE_CODE_SESSION_ID` and, if that
   state file exists, recognizes the buffer as a Claude Code prompt and attaches
   completion — rooting `@file` completion at the recorded cwd.

Detection lives behind a per-tool registry, so support for other agent CLIs can be added
by registering another detector without touching the completion engine.

## Requirements

- Neovim 0.10+
- [`jq`](https://jqlang.github.io/jq/) (used by the companion plugin's hook)
- Optional: [blink.cmp](https://github.com/Saghen/blink.cmp) v2 (otherwise the built-in
  completion backend is used)

## Install

### 1. The Neovim plugin

With Neovim's built-in [`vim.pack`](https://neovim.io/doc/user/pack.html) (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/macintacos/agentcomplete.nvim" })
require("agentcomplete").setup({})
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "macintacos/agentcomplete.nvim",
  opts = {},
}
```

Or call `require("agentcomplete").setup({})` with your plugin manager of choice.

### 2. The companion Claude Code plugin

The companion plugin lives in this same repository under `.claude-plugin/`. Point Claude
Code at it:

```sh
# one-off, for a single session
claude --plugin-dir /path/to/agentcomplete.nvim

# or symlink it into your plugins directory so it loads every session
ln -s /path/to/agentcomplete.nvim ~/.claude/plugins/agentcomplete
```

Without the companion plugin the state file is never written, so the Neovim plugin will
not auto-attach. You can still force it on with `:AgentCompleteAttach`.

## Configuration

Defaults shown:

```lua
require("agentcomplete").setup({
  enabled = true,        -- attach automatically on detected buffers
  backend = "auto",      -- "auto" (blink.cmp if present, else native) | "blink" | "native"
  detect  = "auto",      -- "auto" (registry detectors) | "always" (force on) | "never"
  sources = {
    slash = true,        -- complete /skill and /command
    file  = true,        -- complete @path/to/file
  },
})
```

### blink.cmp

When `backend = "auto"` and blink.cmp is installed, agentcomplete routes through it. Like
any blink source, **you must register it** in your blink config — it cannot register
itself, so without this step the blink backend has no source and no completions appear.
(Prefer zero config? Set `backend = "native"`.) Once registered it self-gates, staying
dormant outside detected buffers:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "agentcomplete", "lsp", "path", "buffer" },
    providers = {
      agentcomplete = {
        name = "agentcomplete",
        module = "agentcomplete.backends.blink",
      },
    },
  },
})
```

### Native completion

When blink.cmp is absent (or `backend = "native"`), agentcomplete attaches a buffer-local
`completefunc` and auto-opens the popup as you type `/` or `@`. No extra configuration is
required.

## Commands

| Command                | What it does                              |
| ---------------------- | ----------------------------------------- |
| `:AgentCompleteAttach` | Force completion onto the current buffer  |
| `:AgentCompleteDetach` | Detach completion from the current buffer |

## Development

Tooling is managed by [mise](https://mise.jdx.dev) (tool versions) and
[hk](https://hk.jdx.dev) (format/lint git hooks). Install
[mise](https://mise.jdx.dev/getting-started.html), then:

```sh
mise trust
mise run setup      # install pinned tools, fetch test deps, register git hooks
```

Day-to-day:

| Command              | What it does                                       |
| -------------------- | -------------------------------------------------- |
| `mise run format`    | Format all files (stylua + baseline), write mode   |
| `mise run lint`      | Lint + type-check (selene, lua-language-server, …) |
| `mise run test`      | Run the test suite (headless Neovim + mini.test)   |
| `mise run preflight` | `lint` + `test` — run before pushing               |

The Lua toolchain: **stylua** (format), **selene** (lint hygiene), **lua-language-server**
(LuaCATS type-check), **mini.test** (tests). A `pre-commit` hook formats and lints staged
files; a `pre-push` hook runs the tests.
