# agentcomplete.nvim

Completion of Claude Code skills, commands, and files inside the prompt buffer that Claude
Code opens in Neovim via its `chat:externalEditor` command (`Ctrl+G`). Works through
[blink.cmp](https://github.com/Saghen/blink.cmp) v2 (preferred, auto-detected) or Neovim's
built-in completion.

> Status: proof of concept.

## How it works

When you press `Ctrl+G` in Claude Code, it writes your prompt to a temporary file
(`…/claude-<uid>/claude-prompt-<uuid>.md`) and opens it in `$VISUAL`/`$EDITOR`, with the
editor's working directory set to your project root.

agentcomplete recognizes that buffer **by name** and attaches completion, rooting `@file`
completion at the editor's working directory. `/` completes skills and commands discovered
from your global `~/.claude/{skills,commands}`, every enabled Claude Code plugin (read
from `~/.claude/plugins/installed_plugins.json`), and the project-local
`<cwd>/.claude/{skills,commands}`.

No environment variable, companion plugin, or external dependency is required — the editor
already has everything detection needs. Detection lives behind a per-tool registry, so
support for other agent CLIs can be added by registering another detector without touching
the completion engine.

## Requirements

- Neovim 0.10+
- Optional: [blink.cmp](https://github.com/Saghen/blink.cmp) v2 (otherwise the built-in
  completion backend is used)

## Install

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

Or call `require("agentcomplete").setup({})` with your plugin manager of choice. That is
the only setup required — there is no companion Claude Code plugin to install. If
detection ever misses (e.g. an unusual launch), force it on with `:AgentCompleteAttach`.

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

### Project root

`@file` completion is rooted at the editor's working directory, which Claude Code sets to
your project root — so this needs no configuration in the common case. To override it
(monorepos, unusual launch dirs), set either (env wins over the Vim global):

```sh
AGENTCOMPLETE_CWD=/path/to/project             # per-launch, exported before `claude`
```

```lua
vim.g.agentcomplete_cwd = "/path/to/project"   -- static, in your Neovim config
```

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
