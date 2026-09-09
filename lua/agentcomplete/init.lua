---@class AgentComplete.Config
---@field enabled boolean Whether completion is attached automatically.
---@field backend "auto"|"blink"|"native" Completion backend ("auto" prefers blink.cmp when present).
---@field detect "auto"|"always"|"never" Detection mode: registry detectors, force on, or off.
---@field sources { slash: boolean, file: boolean } Which completion sources to offer.
---@field allowed_sources string[] Blink provider ids kept alongside agentcomplete in detected buffers (blink backend only; each must already be registered in blink).
---@field context AgentComplete.Context.Options Read-only pane showing the agent's last message beside the prompt. `min_width` is the terminal width at or above which it opens as a vertical split rather than a horizontal one.
---@field opencode AgentComplete.Config.OpenCode OpenCode-specific options.

---@class AgentComplete.Config.OpenCode
---@field show_all_builtin_commands boolean When true, built-in commands that are interactive TUI affordances (dialogs, pickers, toggles, lifecycle) are also completed.
---@field resolve_via_cli boolean When true (the default), OpenCode prompt buffers also source skills and commands asynchronously from `opencode debug skill` / `opencode debug config` (merged with, and de-duplicated against, the filesystem scan) — the only way plugin-contributed commands are seen.
---@field install_plugin boolean When true, `setup()` symlinks the session-pointer plugin just as `:AgentCompleteInstallOpenCodePlugin` does, so a config synced across machines installs it on each of them.

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
  opencode = { show_all_builtin_commands = false, resolve_via_cli = true, install_plugin = false },
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
---rather than a copy, so the installed plugin tracks the checkout.
---
---A symlink to some other `opencode/agentcomplete.ts` is taken to be ours from a checkout that
---has moved, and is re-pointed. A regular file is the user's and is left alone. The two are
---told apart by shape alone, so a hand-written symlink of that name is re-pointed too.
---@param source string The shipped `agentcomplete.ts`.
---@param config_home string OpenCode's config home.
---@return "created"|"current"|"relinked"|"conflict"|"failed" status
---@return string target Where the plugin was installed, or what stood in the way.
function M.install_opencode_plugin(source, config_home)
  local target = config_home .. "/plugin/agentcomplete.ts"
  local linked = vim.loop.fs_readlink(target)
  if linked == source then
    return "current", target
  end
  if linked and vim.endswith(linked, "opencode/agentcomplete.ts") then
    local ok = vim.loop.fs_unlink(target) and vim.loop.fs_symlink(source, target)
    return ok and "relinked" or "failed", target
  end
  if vim.loop.fs_lstat(target) then
    return "conflict", target
  end
  -- `mkdir` raises rather than returning 0 on an unwritable parent, which would escape the
  -- command as a traceback while the rarer symlink failure came back as a tidy report.
  if not pcall(vim.fn.mkdir, config_home .. "/plugin", "p") then
    return "failed", target
  end
  return vim.loop.fs_symlink(source, target) and "created" or "failed", target
end

-- Each message is a prefix the target path completes; `missing` has no target to name.
---@type table<string, string>
local INSTALL_MESSAGES = {
  created = "installed the OpenCode plugin at ",
  current = "the OpenCode plugin is already installed at ",
  relinked = "re-pointed the OpenCode plugin at this checkout: ",
  conflict = "remove it and re-run — refusing to overwrite the file already at ",
  failed = "could not symlink the OpenCode plugin into ",
  missing = "no opencode/agentcomplete.ts on the runtimepath",
}

---Resolve the shipped plugin on the runtimepath and symlink it into OpenCode's config home.
---@return "created"|"current"|"relinked"|"conflict"|"failed"|"missing" status
---@return string target Where it landed, what stood in the way, or "" when unresolved.
local function install_opencode_plugin_from_rtp()
  local source = vim.api.nvim_get_runtime_file("opencode/agentcomplete.ts", false)[1]
  if not source then
    return "missing", ""
  end
  -- A runtimepath entry may be relative; the symlink is resolved from another directory.
  return M.install_opencode_plugin(vim.fn.fnamemodify(source, ":p"), scan.opencode_config_home())
end

---Report an install outcome, at ERROR unless the plugin ended up in place.
---@param status "created"|"current"|"relinked"|"conflict"|"failed"|"missing"
---@param target string
local function notify_install(status, target)
  local installed = status == "created" or status == "current" or status == "relinked"
  local level = installed and vim.log.levels.INFO or vim.log.levels.ERROR
  vim.notify("agentcomplete: " .. INSTALL_MESSAGES[status] .. target, level)
end

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
  vim.api.nvim_create_user_command("AgentCompleteInstallOpenCodePlugin", function()
    notify_install(install_opencode_plugin_from_rtp())
  end, { desc = "Symlink agentcomplete's session-pointer plugin into OpenCode's config" })

  -- Opt-in: writing into another tool's config directory unasked is a surprise. And opting in
  -- travels with a synced config, so the machine has to have OpenCode before this writes to it
  -- — typing the command is the explicit request that installs anywhere.
  if M.config.opencode.install_plugin and vim.fn.executable "opencode" == 1 then
    local status, target = install_opencode_plugin_from_rtp()
    -- `current` is every launch after the first; report only what changed or broke.
    if status ~= "current" then
      notify_install(status, target)
    end
  end

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
