# agentcomplete.nvim

Completion of agent-CLI skills, commands, and files inside the prompt buffer that
[Claude Code](https://docs.claude.com/en/docs/claude-code) (`Ctrl+G`) or
[OpenCode](https://opencode.ai) (`/editor`) opens in Neovim. Works through
[blink.cmp](https://github.com/Saghen/blink.cmp) v2 (preferred, auto-detected) or Neovim's
built-in completion.

> Status: proof of concept.

![agentcomplete.nvim demo](assets/demo.gif)

## Requirements

- Neovim 0.10+ (0.12+ for the `vim.pack` install below)
- Optional: [blink.cmp](https://github.com/Saghen/blink.cmp) v2 — without it, the built-in
  completion backend is used

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
the only setup required — there is no companion plugin to install on the Claude Code or
OpenCode side. If detection ever misses (e.g. an unusual launch), force it on with
`:AgentCompleteAttach`.

## Setup gotchas

A few things worth knowing before your first prompt.

### Using blink.cmp? Register the source (required)

If you use [blink.cmp](https://github.com/Saghen/blink.cmp), agentcomplete routes through
it — but **blink cannot register the source for itself**. Add it to your blink config, or
the prompt buffer shows no completions at all:

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

Call `require("agentcomplete").setup()` **after** `blink.cmp` is configured. With
lazy.nvim, add blink as a dependency so it loads first; `opts = {}` then runs
agentcomplete's `setup()` in the right order:

```lua
{
  "macintacos/agentcomplete.nvim",
  dependencies = { "saghen/blink.cmp" },
  opts = {},
}
```

Once registered, the source self-gates — it stays dormant everywhere except a detected
prompt buffer, so listing it above is harmless.

### Prefer zero config?

Without blink.cmp, agentcomplete uses Neovim's built-in completion automatically — no
source registration needed. Set `backend = "native"` to make that explicit, or to force
native even when blink is installed:

```lua
require("agentcomplete").setup({ backend = "native" })
```

### Heads up: the prompt buffer shows only `/` and `@`

With blink.cmp, agentcomplete makes itself the **only** source in a detected prompt buffer
— your other sources (LSP, path, buffer, …) are suppressed there, so it offers nothing but
`/` (skills and commands) and `@` (files). Every other buffer keeps your full completion
stack. To keep specific sources in the prompt buffer too, see
`:help agentcomplete-suppression`. (The native backend doesn't suppress anything — it just
adds `/` and `@` completion.)

## Learn more

- **`:help agentcomplete`** — every configuration option, how detection works for each
  agent CLI, the commands, and in-editor diagnostics. It is the full reference; this
  README only covers installation. You can also read it as
  [`doc/agentcomplete.txt`](doc/agentcomplete.txt).
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — set up, test, and run the plugin from a
  checkout.
- **Not seeing completions?** With blink.cmp, confirm the source is registered (above).
  Otherwise force it on with `:AgentCompleteAttach`, or run the diagnostics described in
  `:help agentcomplete-diagnostics`.
