# Editing README.md

- **Target:** [`README.md`](../../../README.md)
- **Reader of that file:** people installing the plugin (Neovim users adding an AI-tooling
  plugin). Write for someone who has not used agentcomplete and wants to get it working.
- **This reference is for:** agents (and maintainers) about to change the README.

## What belongs in the README

Installation and nothing more: the one-line description, requirements, the install
snippets, the **setup gotchas** that actually block a first run (blink must register the
source; `setup()` runs after `blink.cmp`; the `backend = "native"` escape hatch; the
one-line only-source-suppression heads-up), and the "Learn more" pointers to
`:help agentcomplete` and [`CONTRIBUTING.md`](../../../CONTRIBUTING.md).

## What does NOT belong here

Concepts and the full configuration reference. If you are tempted to explain *how*
detection works, document a non-essential option, or list every command, that goes in the
vimdoc — see [`vimdoc.md`](vimdoc.md). Contributor tooling goes in CONTRIBUTING — see
[`contributing.md`](contributing.md). The test for the README: would a brand-new user be
blocked on first run without this? If not, it belongs elsewhere, with a pointer from here.

## How to edit

Use the `/doc-coauthoring` skill when it is available — it keeps the README scoped to its
audience and reader-tests the result. Keep the screenshots placeholder near the top intact
unless the maintainer is adding the images. Match the existing wrap (rumdl `MD013`,
line-length 90; code blocks exempt).

## Verify

Run `mise run lint` (rumdl must pass). If you added or renamed a `:help` tag in a link,
confirm it resolves — see [`vimdoc.md`](vimdoc.md).
