---@class AgentComplete.Config
---@field enabled boolean Whether completion is attached automatically.
---@field backend "auto"|"blink"|"native" Completion backend ("auto" prefers blink.cmp when present).
---@field detect "auto"|"always"|"never" Detection mode: registry detectors, force on, or off.
---@field sources { slash: boolean, file: boolean } Which completion sources to offer.
---@field allowed_sources string[] Blink provider ids kept alongside agentcomplete in detected buffers (blink backend only; each must already be registered in blink).
---@field context AgentComplete.Context.Options Read-only pane showing the agent's last message beside the prompt. `min_width` is the terminal width at or above which it opens as a vertical split rather than a horizontal one.
---@field opencode { show_all_builtin_commands: boolean, resolve_via_cli: boolean } OpenCode-specific options. When `show_all_builtin_commands` is true, built-in commands that are interactive TUI affordances (dialogs, pickers, toggles, lifecycle) are also completed. When `resolve_via_cli` is true (the default), OpenCode prompt buffers also source skills and commands asynchronously from `opencode debug skill` / `opencode debug config` (merged with, and de-duplicated against, the filesystem scan) — the only way plugin-contributed commands are seen.

---@class AgentComplete
local M = {}

local detect = require "agentcomplete.detect"
local backends = require "agentcomplete.backends"
local highlight = require "agentcomplete.highlight"
local context = require "agentcomplete.context"
local scan = require "agentcomplete.scan"

---Default configuration.
---@type AgentComplete.Config
local defaults = {
  enabled = true,
  backend = "auto",
  detect = "auto",
  sources = { slash = true, file = true },
  allowed_sources = {},
  context = { enabled = true, min_width = 160 },
  opencode = { show_all_builtin_commands = false, resolve_via_cli = true },
}

---@type AgentComplete.Config
M.config = vim.deepcopy(defaults)

---Synthesize a session for manual/forced attach when no detector matched.
---@return AgentComplete.Session
local function fallback_session()
  local cwd = vim.loop.cwd() or vim.fn.getcwd()
  local skill_dirs, command_dirs, skill_namespaces = scan.claude_dirs(cwd)
  return {
    tool = "manual",
    cwd = cwd,
    session_id = nil,
    skill_dirs = skill_dirs,
    command_dirs = command_dirs,
    skill_namespaces = skill_namespaces,
  }
end

---Add each of `builtins` to a registry it is not already in, by name. Idempotent, so repeated
---setup calls are safe.
---@param registry { name: string }[]
---@param register fun(item: any)
---@param builtins { name: string }[]
local function ensure_registered(registry, register, builtins)
  for _, item in ipairs(builtins) do
    local present = false
    for _, existing in ipairs(registry) do
      if existing.name == item.name then
        present = true
        break
      end
    end
    if not present then
      register(item)
    end
  end
end

---Register the built-in detectors and last-message resolvers.
local function ensure_builtins()
  -- Detector order is significant (first match wins); Claude Code before OpenCode. The two are
  -- mutually exclusive in practice, so the order is harmless either way.
  ensure_registered(detect.detectors, detect.register, {
    require "agentcomplete.detect.claude_code",
    require "agentcomplete.detect.opencode",
  })
  ensure_registered(context.resolvers, context.register, {
    require "agentcomplete.context.claude_code",
    require "agentcomplete.context.opencode",
  })
end

---Symlink the shipped OpenCode plugin into `<config_home>/plugin/`, so OpenCode loads it and
---the context pane can resolve a session by pointer file rather than by guess. A symlink
---rather than a copy, so the installed plugin tracks the checkout. Anything already at the
---target is left alone: it is the user's, and an older checkout's link reads the same as a
---hand-written plugin.
---@param source string The shipped `agentcomplete.ts`.
---@param config_home string OpenCode's config home.
---@return "created"|"current"|"conflict"|"failed" status
---@return string target Where the plugin was installed, or what stood in the way.
function M.install_opencode_plugin(source, config_home)
  local target = config_home .. "/plugin/agentcomplete.ts"
  local linked = vim.loop.fs_readlink(target)
  if linked == source then
    return "current", target
  end
  if vim.loop.fs_lstat(target) then
    return "conflict", target
  end
  vim.fn.mkdir(config_home .. "/plugin", "p")
  return vim.loop.fs_symlink(source, target) and "created" or "failed", target
end

---@type table<string, string>
local INSTALL_REPORT = {
  created = "installed the OpenCode plugin at ",
  current = "the OpenCode plugin is already installed at ",
  conflict = "refusing to overwrite the file already at ",
  failed = "could not symlink the OpenCode plugin into ",
}

---Attach completion, token highlighting, and the context pane to a buffer if a session is
---detected (or forced).
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
    session.show_all_builtin_commands = M.config.opencode.show_all_builtin_commands
    backends.attach(buf, session, M.config)
    highlight.attach(buf, session)
    context.open(buf, session, M.config.context)
  end
  return session ~= nil
end

---Detach completion, token highlighting, and the context pane from a buffer.
---@param bufnr integer|nil 0/nil → current buffer.
function M.detach(bufnr)
  local buf = bufnr or 0
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  backends.detach(buf)
  highlight.detach(buf)
  context.close(buf)
end

---Set up agentcomplete.nvim.
---@param opts? table User configuration overrides (see AgentComplete.Config).
---@return AgentComplete
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  ensure_builtins()
  backends.install_suppression(M.config)

  vim.api.nvim_create_user_command("AgentCompleteAttach", function()
    M.attach(0, { force = true })
  end, { desc = "Force agentcomplete onto the current buffer" })
  vim.api.nvim_create_user_command("AgentCompleteDetach", function()
    M.detach(0)
  end, { desc = "Detach agentcomplete from the current buffer" })
  -- Never from `setup()`: writing into another tool's config directory unasked is a surprise.
  vim.api.nvim_create_user_command("AgentCompleteInstallOpenCodePlugin", function()
    local source = vim.api.nvim_get_runtime_file("opencode/agentcomplete.ts", false)[1]
    if not source then
      return vim.notify("agentcomplete: no opencode/agentcomplete.ts on the runtimepath", vim.log.levels.ERROR)
    end
    local status, target = M.install_opencode_plugin(source, scan.opencode_config_home())
    local level = (status == "created" or status == "current") and vim.log.levels.INFO or vim.log.levels.ERROR
    vim.notify("agentcomplete: " .. INSTALL_REPORT[status] .. target, level)
  end, { desc = "Symlink agentcomplete's session-pointer plugin into OpenCode's config" })

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
