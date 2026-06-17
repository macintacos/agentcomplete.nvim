---Claude Code detector.
---
---Claude Code opens its prompt via `chat:externalEditor` (Ctrl+G): it writes the
---prompt to `<tmpdir>/claude-<uid>/claude-prompt-<uuid>.md` and opens that file in
---`$EDITOR`. The spawned editor does **not** inherit `CLAUDE_CODE_SESSION_ID`, so
---detection keys on the prompt buffer's name, and roots completion at the editor's
---working directory (which is the project root). The cwd is overridable via
---`$AGENTCOMPLETE_CWD` (per-launch) or `vim.g.agentcomplete_cwd` (static config) for
---non-standard launches.
local M = { name = "claude-code" }

local scan = require "agentcomplete.scan"

---Whether the buffer is Claude Code's external-editor prompt, judged by name.
---@param bufnr integer
---@return boolean
local function is_claude_prompt(bufnr)
  local base = vim.api.nvim_buf_get_name(bufnr):match "[^/]+$" or ""
  return base:match "^claude%-prompt%-.+%.md$" ~= nil
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
  if not is_claude_prompt(bufnr) then
    return nil
  end
  local cwd = resolve_cwd()
  local skill_dirs, command_dirs, skill_namespaces = scan.claude_dirs(cwd)
  return {
    tool = "claude-code",
    cwd = cwd,
    session_id = nil,
    skill_dirs = skill_dirs,
    command_dirs = command_dirs,
    skill_namespaces = skill_namespaces,
  }
end

return M
