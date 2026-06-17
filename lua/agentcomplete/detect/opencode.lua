---OpenCode detector.
---
---OpenCode opens its prompt via `/editor` (default `<leader>e`): it writes the prompt to
---`<tmpdir>/<epoch-millis>.md` and opens that file in `$VISUAL`/`$EDITOR`. The temp file
---carries no OpenCode-specific name, so name-matching alone is unreliable. Instead detection
---keys on `vim.env.OPENCODE == "1"` — OpenCode sets `OPENCODE=1` (plus `OPENCODE_PID`) in
---`process.env` for every command via a yargs middleware, and the spawned editor inherits it —
---corroborated by the buffer's `<digits>.md` temp-file shape (so other files opened in the same
---Neovim are not misdetected). The cwd is OpenCode's project root, overridable via
---`$AGENTCOMPLETE_CWD` (per-launch) or `vim.g.agentcomplete_cwd` (static config).
local M = { name = "opencode" }

local scan = require "agentcomplete.scan"

---Whether the buffer is OpenCode's external-editor prompt: OpenCode launched this Neovim
---(`$OPENCODE`) and the buffer is its `<epoch-millis>.md` temp file.
---@param bufnr integer
---@return boolean
local function is_opencode_prompt(bufnr)
  if vim.env.OPENCODE ~= "1" then
    return false
  end
  local base = vim.api.nvim_buf_get_name(bufnr):match "[^/]+$" or ""
  return base:match "^%d+%.md$" ~= nil
end

---Resolve the project cwd: explicit override (env, then `vim.g`) else the editor cwd.
---@return string
local function resolve_cwd()
  local env = vim.env.AGENTCOMPLETE_CWD
  if env and env ~= "" then
    return env
  end
  if vim.g.agentcomplete_cwd and vim.g.agentcomplete_cwd ~= "" then
    return vim.g.agentcomplete_cwd
  end
  return vim.loop.cwd() or vim.fn.getcwd()
end

---@param bufnr integer
---@return AgentComplete.Session|nil
function M.detect(bufnr)
  if not is_opencode_prompt(bufnr) then
    return nil
  end
  local cwd = resolve_cwd()
  local skill_dirs, command_dirs = scan.opencode_dirs(cwd)
  -- Config-map commands first so a user's own command wins the name-dedup in `sources.items`
  -- over a built-in of the same name; OpenCode's built-in TUI commands fill in the rest.
  local extra_commands = scan.opencode_commands(cwd)
  vim.list_extend(extra_commands, scan.opencode_builtin_commands())
  return {
    tool = "opencode",
    cwd = cwd,
    session_id = vim.env.OPENCODE_PID,
    skill_dirs = skill_dirs,
    command_dirs = command_dirs,
    extra_commands = extra_commands,
  }
end

return M
