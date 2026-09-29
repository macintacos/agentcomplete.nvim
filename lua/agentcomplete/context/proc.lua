---What the resolvers and the OpenCode detector need to find the agent that launched this Neovim:
---a step up the process tree, a climb to a named ancestor, and a JSON file read that fails soft.
---
---None of them knows which process it is looking for until it has climbed to it, so the climb
---cannot live in any one of them.
---@class AgentComplete.Context.Proc
local M = {}

local MAX_HOPS = 5

---@param pid integer
---@param system fun(cmd: string[]): string
---@return integer|nil
function M.parent_pid(pid, system)
  local ok, out = pcall(system, { "ps", "-o", "ppid=", "-p", tostring(pid) })
  return ok and tonumber(vim.trim(out or "")) or nil
end

---The nearest process at or above `pid` whose executable is named `name`. `ps` reports `comm` as
---a full path on macOS and a bare name on Linux, hence the basename.
---@param pid integer|nil
---@param name string
---@param system fun(cmd: string[]): string
---@return integer|nil
function M.find_ancestor(pid, name, system)
  for _ = 1, MAX_HOPS do
    if not pid or pid <= 1 then
      return nil
    end
    local ok, out = pcall(system, { "ps", "-o", "ppid=,comm=", "-p", tostring(pid) })
    local ppid, comm = (ok and out or ""):match("^%s*(%d+)%s+(.-)%s*$")
    if not comm then
      return nil
    end
    if vim.fs.basename(comm) == name then
      return pid
    end
    pid = tonumber(ppid)
  end
  return nil
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
