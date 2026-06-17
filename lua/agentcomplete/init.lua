---@class AgentComplete.Config
---@field enabled boolean Whether completion is attached automatically.
---@field backend "auto"|"blink"|"native" Completion backend ("auto" prefers blink.cmp when present).
---@field detect "auto"|"always"|"never" Detection mode: registry detectors, force on, or off.
---@field sources { slash: boolean, file: boolean } Which completion sources to offer.
---@field allowed_sources string[] Blink provider ids kept alongside agentcomplete in detected buffers (blink backend only; each must already be registered in blink).

---@class AgentComplete
local M = {}

local detect = require "agentcomplete.detect"
local backends = require "agentcomplete.backends"
local scan = require "agentcomplete.scan"

---Default configuration.
---@type AgentComplete.Config
local defaults = {
  enabled = true,
  backend = "auto",
  detect = "auto",
  sources = { slash = true, file = true },
  allowed_sources = {},
}

---@type AgentComplete.Config
M.config = vim.deepcopy(defaults)

---Synthesize a session for manual/forced attach when no detector matched.
---@return AgentComplete.Session
local function fallback_session()
  local cwd = vim.loop.cwd() or vim.fn.getcwd()
  local skill_dirs, command_dirs = scan.claude_dirs(cwd)
  return {
    tool = "manual",
    cwd = cwd,
    session_id = nil,
    skill_dirs = skill_dirs,
    command_dirs = command_dirs,
  }
end

---Register built-in detectors (idempotent — safe across repeated setup calls).
local function ensure_detectors()
  local cc = require "agentcomplete.detect.claude_code"
  for _, d in ipairs(detect.detectors) do
    if d.name == cc.name then
      return
    end
  end
  detect.register(cc)
end

---Attach completion to a buffer if a session is detected (or forced).
---@param bufnr integer|nil 0/nil → current buffer.
---@param opts? { force: boolean }
---@return boolean attached
function M.attach(bufnr, opts)
  local buf = bufnr or 0
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  opts = opts or {}

  local session
  if M.config.detect ~= "never" then
    session = detect.detect(buf)
  end
  if not session and (opts.force or M.config.detect == "always") then
    session = fallback_session()
  end
  if session then
    session.sources = M.config.sources
    backends.attach(buf, session, M.config)
  end
  return session ~= nil
end

---Detach completion from a buffer.
---@param bufnr integer|nil 0/nil → current buffer.
function M.detach(bufnr)
  local buf = bufnr or 0
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  backends.detach(buf)
end

---Set up agentcomplete.nvim.
---@param opts? table User configuration overrides (see AgentComplete.Config).
---@return AgentComplete
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  ensure_detectors()
  backends.install_suppression(M.config)

  vim.api.nvim_create_user_command("AgentCompleteAttach", function()
    M.attach(0, { force = true })
  end, { desc = "Force agentcomplete onto the current buffer" })
  vim.api.nvim_create_user_command("AgentCompleteDetach", function()
    M.detach(0)
  end, { desc = "Detach agentcomplete from the current buffer" })

  if M.config.enabled then
    local grp = vim.api.nvim_create_augroup("AgentComplete", { clear = true })
    vim.api.nvim_create_autocmd({ "VimEnter", "BufReadPost" }, {
      group = grp,
      callback = function(args)
        M.attach(args.buf)
      end,
    })
  end

  return M
end

return M
