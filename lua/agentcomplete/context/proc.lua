---What both last-message resolvers need to find the agent that launched this Neovim: a step up
---the process tree, and a JSON file read that fails soft.
---
---Neither resolver knows which process it is looking for until it has climbed to it, so the
---climb cannot live in either one of them.
---@class AgentComplete.Context.Proc
local M = {}

---@param pid integer
---@param system fun(cmd: string[]): string
---@return integer|nil
function M.parent_pid(pid, system)
  local ok, out = pcall(system, { "ps", "-o", "ppid=", "-p", tostring(pid) })
  return ok and tonumber(vim.trim(out or "")) or nil
end

---@param path string
---@return table|nil
function M.read_json(path)
  local read, lines = pcall(vim.fn.readfile, path)
  if not read then
    return nil
  end
  local decoded, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  return (decoded and type(value) == "table") and value or nil
end

return M
