-- agentcomplete.nvim diagnostics loader.
--
-- Load from the buffer you want to inspect:
--   :AgentCompleteAttach          (optional — force a session if not auto-detected)
--   :luafile scripts/diagnostics.lua
--
-- Prints a report to :messages and writes it to
-- <cwd>/.tmp/agentcomplete-diagnostics.md for a Claude Code agent session to read.
local ok, diagnostics = pcall(require, "agentcomplete.diagnostics")
if not ok then
  vim.notify(
    "agentcomplete: could not load agentcomplete.diagnostics — is the plugin on your runtimepath?",
    vim.log.levels.ERROR
  )
  return
end

diagnostics.run()
