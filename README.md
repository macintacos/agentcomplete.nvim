# agentcomplete.nvim

Completion of agent-CLI skills, commands, and files inside the prompt buffer that
[Claude Code](https://docs.claude.com/en/docs/claude-code) (`Ctrl+G`) or
[OpenCode](https://opencode.ai) (`/editor`) opens in Neovim. Works through
[blink.cmp](https://github.com/Saghen/blink.cmp) v2 (preferred, auto-detected) or Neovim's
built-in completion.

> Status: proof of concept.

## How it works

### Claude Code

When you press `Ctrl+G` in Claude Code, it writes your prompt to a temporary file
(`…/claude-<uid>/claude-prompt-<uuid>.md`) and opens it in `$VISUAL`/`$EDITOR`, with the
editor's working directory set to your project root. agentcomplete recognizes that buffer
**by name** and attaches completion, rooting `@file` completion at the editor's working
directory. `/` completes skills and commands discovered from your global
`~/.claude/{skills,commands}`, every enabled Claude Code plugin (read from
`~/.claude/plugins/installed_plugins.json`), and the project-local
`<cwd>/.claude/{skills,commands}`.

### OpenCode

OpenCode's external editor (`/editor`, default `<leader>e`) writes your prompt to a bare
`<epoch-millis>.md` file in the system temp dir — a name with nothing OpenCode-specific in
it. So instead of matching the name, agentcomplete keys on `OPENCODE=1`, which OpenCode
sets in the environment for every command and the spawned editor inherits (corroborated by
the `<digits>.md` buffer shape). `@file` is rooted at the editor's working directory (your
project root). `/` completes skills (`{skill,skills}/<name>/SKILL.md`), markdown commands,
and config-defined commands (the `opencode.json[c]` `command` map), discovered from the
global `~/.config/opencode` (honoring `$XDG_CONFIG_HOME` / `$OPENCODE_CONFIG_DIR`), the
project-local `<cwd>/.opencode`, and `opencode.json[c]` at the project root.

No companion plugin or external dependency is required for either tool — the editor
already has everything detection needs. Detection lives behind a per-tool registry, so
support for further agent CLIs can be added by registering another detector without
touching the completion engine.

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
  allowed_sources = {},  -- blink only: extra blink sources to keep in detected buffers
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

#### Only-source suppression

In a detected prompt buffer, agentcomplete makes itself the **only** blink source — every
other source (lsp, path, snippets, buffer, lazydev, …) is suppressed so the buffer offers
nothing but `/` and `@` completions. Every other buffer keeps your full completion stack
untouched. To keep specific sources in the prompt buffer too, list them in
`allowed_sources`:

```lua
require("agentcomplete").setup({
  allowed_sources = { "path" },  -- keep `path` alongside agentcomplete in detected buffers
})
```

`allowed_sources` **re-permits, never registers**: every entry — and `agentcomplete`
itself — must already be registered in your blink `sources.providers` (above); unknown
names are dropped with a one-time warning. Because blink.cmp has no per-buffer source
config, agentcomplete enforces this by wrapping blink's global `sources.default` /
`per_filetype` at setup, so
**`require("agentcomplete").setup()` must run after `require("blink.cmp").setup()`**. This
is blink-only — the native backend has no competing sources and is unaffected.

Two caveats. **Load order:** the wrap reads blink's config at setup time, so configure
blink first — under lazy.nvim, add `dependencies = { "Saghen/blink.cmp" }` to the
agentcomplete spec so its `setup()` runs after blink's; if agentcomplete loads first,
suppression silently no-ops (with a one-time warning). **Runtime-added sources:** sources
injected through blink's `require("blink.cmp").add_filetype_source()` API are appended
outside `sources.default` / `per_filetype`, so they are **not** suppressed — register
sources you want gated the normal way (in `sources.providers` and `default`) instead.

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

| Command              | What it does                                            |
| -------------------- | ------------------------------------------------------- |
| `mise run format`    | Format all files (stylua + baseline), write mode        |
| `mise run lint`      | Lint + type-check (selene, lua-language-server, …)      |
| `mise run test`      | Run the test suite (headless Neovim + mini.test)        |
| `mise run preflight` | `lint` + `test` — run before pushing                    |
| `mise run diag`      | Print a diagnostics report (headless: blink + OpenCode) |

The Lua toolchain: **stylua** (format), **selene** (lint hygiene), **lua-language-server**
(LuaCATS type-check), **mini.test** (tests). A `pre-commit` hook formats and lints staged
files; a `pre-push` hook runs the tests.

### Diagnostics

To debug behavior inside the prompt buffer Claude Code or OpenCode opens, load the
diagnostics script from that buffer:

```vim
:AgentCompleteAttach    " optional: force a session if the buffer wasn't auto-detected
:luafile scripts/diagnostics.lua
```

It gathers the live plugin state — resolved backend, buffer detection and attach state,
discovered skills/commands/files, and the blink only-source suppression diagnosis (with a
likely-cause line) — prints it to `:messages`, and writes it to
`.tmp/agentcomplete-diagnostics.md` under the editor's working directory.

That file exists to hand state to an agent session: an agent can't launch Neovim from its
own session to watch the plugin, but it can read the report. `mise run diag` runs the same
flow headlessly in two passes: a Claude Code / blink pass against a real blink setup (with
`path` as a source) in a simulated prompt buffer — validating that only-source suppression
removes `path` (it uses a pinned blink v1; v2 needs the compiled `blink.lib`, which can't
build in CI, but the suppression wrap reads the same config on both) — and an OpenCode
pass that sets `OPENCODE=1` on a `<digits>.md` buffer and confirms detection reports
`session.tool: opencode` with the resolved OpenCode search dirs.
