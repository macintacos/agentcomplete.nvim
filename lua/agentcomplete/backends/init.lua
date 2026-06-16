---Backend selection and attach/detach dispatch.
---@class AgentComplete.Backends
local M = {}

local native = require "agentcomplete.backends.native"

---Whether blink.cmp is installed in this Neovim.
---@return boolean
function M.has_blink()
  local ok = pcall(require, "blink.cmp")
  return ok
end

---Resolve the effective backend from config: "auto" prefers blink, else native.
---@param config { backend?: "auto"|"blink"|"native" }
---@return '"blink"'|'"native"'
function M.select(config)
  local backend = (config and config.backend) or "auto"
  if backend == "blink" then
    return "blink"
  end
  if backend == "native" then
    return "native"
  end
  return M.has_blink() and "blink" or "native"
end

---Attach completion to a buffer using the selected backend.
---blink self-gates globally via the detector registry, so it needs no per-buffer
---attach; only the native backend wires buffer-local state.
---@param buf integer
---@param session AgentComplete.Session
---@param config { backend?: "auto"|"blink"|"native" }
function M.attach(buf, session, config)
  if M.select(config) == "native" then
    native.attach(buf, session, config)
  end
end

---@param buf integer
function M.detach(buf)
  native.detach(buf)
end

return M
