---Runtime diagnostics for agentcomplete.nvim.
---
---A Claude Code agent session cannot launch a second Neovim "from" itself (via
---the `Ctrl+G` external editor) to watch how this plugin behaves in the prompt
---buffer. So a human loads `scripts/diagnostics.lua` with `:luafile` in the real
---prompt buffer; this module gathers the live plugin state and writes it to a
---file (and `:messages`) for the agent to read back.
---
---The pure core (`diagnose_suppression`, `render`) is unit-tested; the glue
---(`collect`, `run`, which read live editor state and write a file) is exercised
---by the headless smoke check in `mise run diag`.
---@class AgentComplete.Diagnostics
local M = {}

local blink = require "agentcomplete.backends.blink"

---@class AgentComplete.Diagnostics.SuppressState
---@field resolved_backend "blink"|"native" The backend `backends.select` resolved to.
---@field config_reachable boolean Whether `blink.cmp.config` could be required.
---@field registered table<string, any>|nil Blink's `sources.providers` (keys are provider ids).
---@field wrap_installed boolean Whether the suppression wrap is currently installed.
---@field detected boolean Whether the current buffer is a detected prompt buffer.
---@field allowed_sources string[] The configured `allowed_sources`.

---@class AgentComplete.Diagnostics.Suppression
---@field active boolean blink is the resolved backend.
---@field config_reachable boolean
---@field agentcomplete_registered boolean
---@field wrap_installed boolean
---@field detected boolean
---@field effective string[] Sources blink would use in a detected buffer.
---@field dropped string[] `allowed_sources` entries that are not registered providers.
---@field registered_ids string[] Sorted registered provider ids.
---@field cause string The single most-likely reason suppression is (or isn't) in effect.

---Pure: diagnose the blink only-source suppression mechanism from a state
---snapshot. `cause` walks the mechanism in the order failures actually occur, so
---the report points straight at the fix (this is the EXC-653 root-cause logic).
---@param state AgentComplete.Diagnostics.SuppressState
---@return AgentComplete.Diagnostics.Suppression
function M.diagnose_suppression(state)
  local active = state.resolved_backend == "blink"
  local registered = state.registered or {}
  local agentcomplete_registered = registered.agentcomplete ~= nil
  local effective, dropped = blink.constrain(state.allowed_sources or {}, registered)

  local registered_ids = {}
  for id in pairs(registered) do
    registered_ids[#registered_ids + 1] = id
  end
  table.sort(registered_ids)

  local cause
  if not active then
    cause = "Backend resolves to '"
      .. tostring(state.resolved_backend)
      .. "', not blink. The native backend attaches agentcomplete as the only completion on the buffer, so there are no other sources to suppress."
  elseif not state.config_reachable then
    cause =
      "blink.cmp config is not reachable — blink is not installed or its setup() has not run. With no blink there is nothing to suppress; confirm blink.cmp is installed and configured."
  elseif not agentcomplete_registered then
    cause =
      "'agentcomplete' is not a registered blink provider, so install_suppression() no-ops (it emits a WARN at setup). Register it under blink sources.providers (see README) and make sure agentcomplete.setup() runs after blink.cmp.setup()."
  elseif not state.wrap_installed then
    cause =
      "The suppression wrap is NOT installed even though 'agentcomplete' is registered. The usual cause is load order: agentcomplete.setup() ran before blink.cmp.setup(), so the wrap was skipped or captured a config blink later overwrote. Ensure agentcomplete.setup() runs AFTER blink.cmp.setup()."
  elseif not state.detected then
    cause =
      "The suppression wrap IS installed, but the current buffer is not detected as an agent prompt buffer (a Claude Code 'claude-prompt-<uuid>.md' or an OpenCode '<digits>.md' under $OPENCODE), so blink uses your original (unsuppressed) source list here. Run this from the real prompt buffer (':AgentCompleteAttach' forces a session but does not change blink detection)."
  else
    cause = "Suppression is installed AND this buffer is detected, so agentcomplete should be the only source (plus allowed_sources: "
      .. table.concat(effective, ", ")
      .. "). If path completions still appear, that source was likely added at runtime via blink's add_filetype_source(), which the wrap cannot reach (register it under sources.providers/default instead), or blink.cmp.setup() re-ran after agentcomplete.setup() and replaced the wrapped source lists."
  end

  return {
    active = active,
    config_reachable = state.config_reachable == true,
    agentcomplete_registered = agentcomplete_registered,
    wrap_installed = state.wrap_installed == true,
    detected = state.detected == true,
    effective = effective,
    dropped = dropped,
    registered_ids = registered_ids,
    cause = cause,
  }
end

---@param b boolean|nil
---@return string
local function yn(b)
  return b and "yes" or "no"
end

---@param v any
---@return string
local function val(v)
  if v == nil then
    return "(unset)"
  end
  return tostring(v)
end

---@param t string[]|nil
---@return string
local function list(t)
  if not t or #t == 0 then
    return "(none)"
  end
  return table.concat(t, ", ")
end

---@class AgentComplete.Diagnostics.Report
---@field nvim_version string
---@field config { backend: string, resolved_backend: string, detect: string, enabled: boolean, sources: { slash: boolean, file: boolean }, allowed_sources: string[] }
---@field buffer { nr: integer, name: string, detected: boolean, native_attached: boolean, session_source: string }
---@field session { tool: string, cwd: string, session_id: string|nil, skill_dirs: string[], command_dirs: string[] }|nil
---@field discovery { skills: integer, commands: integer, files: integer }|nil
---@field blink AgentComplete.Diagnostics.Suppression
---@field env table<string, string|nil>

---Pure: render a full report as a markdown string.
---@param report AgentComplete.Diagnostics.Report
---@return string
function M.render(report)
  local cfg = report.config or {}
  local buf = report.buffer or {}
  local b = report.blink or {}
  local env = report.env or {}

  local lines = {}
  local function add(s)
    lines[#lines + 1] = s
  end

  add "# agentcomplete.nvim diagnostics"
  add ""
  add("Neovim: " .. val(report.nvim_version))
  local bufname = (buf.name ~= nil and buf.name ~= "") and buf.name or "(no name)"
  add("Buffer: " .. val(buf.nr) .. " (" .. bufname .. ")")
  add ""

  add "## Config"
  add("- backend (configured): " .. val(cfg.backend))
  add("- backend (resolved):   " .. val(cfg.resolved_backend))
  add("- detect:               " .. val(cfg.detect))
  add("- enabled:              " .. yn(cfg.enabled))
  add("- sources.slash:        " .. yn(cfg.sources and cfg.sources.slash))
  add("- sources.file:         " .. yn(cfg.sources and cfg.sources.file))
  add("- allowed_sources:      " .. list(cfg.allowed_sources))
  add ""

  add "## Detection"
  add("- current buffer detected:  " .. yn(buf.detected))
  add("- native session attached:  " .. yn(buf.native_attached))
  add("- session source:           " .. val(buf.session_source))
  local s = report.session
  if s then
    add("- session.tool:             " .. val(s.tool))
    add("- session.cwd:              " .. val(s.cwd))
    add("- session.session_id:       " .. val(s.session_id))
    add("- session.skill_dirs:       " .. list(s.skill_dirs))
    add("- session.command_dirs:     " .. list(s.command_dirs))
  else
    add "- session:                  (none)"
  end
  add ""

  add "## Discovery"
  local d = report.discovery
  if d then
    add("- skills:   " .. val(d.skills))
    add("- commands: " .. val(d.commands))
    add("- files:    " .. val(d.files))
  else
    add "- (no active session to scan)"
  end
  add ""

  add "## blink suppression"
  add("- active backend is blink:    " .. yn(b.active))
  add("- blink config reachable:     " .. yn(b.config_reachable))
  add("- agentcomplete registered:   " .. yn(b.agentcomplete_registered))
  add("- registered providers:       " .. list(b.registered_ids))
  add("- suppression wrap installed: " .. yn(b.wrap_installed))
  add("- buffer detected:            " .. yn(b.detected))
  add("- effective sources (detected buffer): " .. list(b.effective))
  add("- dropped (unregistered) allowed:      " .. list(b.dropped))
  add ""
  add "### Likely cause"
  add(val(b.cause))
  add ""

  add "## Environment"
  add("- AGENTCOMPLETE_CWD:       " .. val(env.AGENTCOMPLETE_CWD))
  add("- vim.g.agentcomplete_cwd: " .. val(env.agentcomplete_cwd_g))
  add("- CLAUDE_CONFIG_DIR:       " .. val(env.CLAUDE_CONFIG_DIR))
  add("- CLAUDE_CODE_SESSION_ID:  " .. val(env.CLAUDE_CODE_SESSION_ID))
  add("- OPENCODE:                " .. val(env.OPENCODE))
  add("- OPENCODE_PID:            " .. val(env.OPENCODE_PID))
  add("- AGENT:                   " .. val(env.AGENT))
  add("- OPENCODE_CONFIG_DIR:     " .. val(env.OPENCODE_CONFIG_DIR))
  add("- XDG_CONFIG_HOME:         " .. val(env.XDG_CONFIG_HOME))
  add("- EDITOR:                  " .. val(env.EDITOR))
  add("- VISUAL:                  " .. val(env.VISUAL))
  add("- cwd:                     " .. val(env.cwd))

  return table.concat(lines, "\n") .. "\n"
end

---Glue: gather the live plugin state for the current (or given) buffer.
---The session used for discovery is the auto-detected one, else a forced/attached
---native session, else none — `:AgentCompleteAttach` is what produces the latter.
---@param opts? { bufnr?: integer }
---@return AgentComplete.Diagnostics.Report
function M.collect(opts)
  opts = opts or {}
  local buf = opts.bufnr or vim.api.nvim_get_current_buf()

  local ac = require "agentcomplete"
  local backends = require "agentcomplete.backends"
  local detect = require "agentcomplete.detect"
  local native = require "agentcomplete.backends.native"
  local scan = require "agentcomplete.scan"

  local config = ac.config or {}
  local resolved_backend = backends.select(config)

  local detected_session = detect.detect(buf)
  local attached_native = native._sessions and native._sessions[buf] or nil
  local session = detected_session or attached_native
  local session_source = detected_session and "detected" or (attached_native and "attached" or "none")

  local discovery
  if session then
    discovery = {
      skills = #scan.skills(session.skill_dirs),
      commands = #scan.commands(session.command_dirs) + #(session.extra_commands or {}),
      files = #scan.files(session.cwd),
    }
  end

  local ok, bcfg = pcall(require, "blink.cmp.config")
  bcfg = ok and bcfg or nil
  local registered = bcfg and bcfg.sources and bcfg.sources.providers or nil
  local suppression = M.diagnose_suppression {
    resolved_backend = resolved_backend,
    config_reachable = bcfg ~= nil,
    registered = registered,
    wrap_installed = blink._installed ~= nil,
    detected = detected_session ~= nil,
    allowed_sources = config.allowed_sources or {},
  }

  local v = vim.version()
  return {
    nvim_version = string.format("%d.%d.%d", v.major, v.minor, v.patch),
    config = {
      backend = config.backend,
      resolved_backend = resolved_backend,
      detect = config.detect,
      enabled = config.enabled,
      sources = config.sources,
      allowed_sources = config.allowed_sources,
    },
    buffer = {
      nr = buf,
      name = vim.api.nvim_buf_get_name(buf),
      detected = detected_session ~= nil,
      native_attached = attached_native ~= nil,
      session_source = session_source,
    },
    session = session and {
      tool = session.tool,
      cwd = session.cwd,
      session_id = session.session_id,
      skill_dirs = session.skill_dirs,
      command_dirs = session.command_dirs,
    } or nil,
    discovery = discovery,
    blink = suppression,
    env = {
      AGENTCOMPLETE_CWD = vim.env.AGENTCOMPLETE_CWD,
      agentcomplete_cwd_g = vim.g.agentcomplete_cwd,
      CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR,
      CLAUDE_CODE_SESSION_ID = vim.env.CLAUDE_CODE_SESSION_ID,
      OPENCODE = vim.env.OPENCODE,
      OPENCODE_PID = vim.env.OPENCODE_PID,
      AGENT = vim.env.AGENT,
      OPENCODE_CONFIG_DIR = vim.env.OPENCODE_CONFIG_DIR,
      XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME,
      EDITOR = vim.env.EDITOR,
      VISUAL = vim.env.VISUAL,
      cwd = vim.loop.cwd() or vim.fn.getcwd(),
    },
  }
end

---Glue: collect, render, print to `:messages`, and write the report to a file.
---Defaults to `<cwd>/.tmp/agentcomplete-diagnostics.md` (agent-readable, gitignored).
---@param opts? { bufnr?: integer, path?: string, write?: boolean, print?: boolean }
---@return AgentComplete.Diagnostics.Report report
---@return string|nil path The file written, or nil when `write = false`.
function M.run(opts)
  opts = opts or {}
  local report = M.collect(opts)
  local text = M.render(report)

  local path
  if opts.write ~= false then
    path = opts.path or ((vim.loop.cwd() or vim.fn.getcwd()) .. "/.tmp/agentcomplete-diagnostics.md")
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    -- render() ends in a trailing newline; trimempty drops the resulting empty
    -- final element so the file gets a single trailing newline, not a blank line.
    local ok, err = pcall(vim.fn.writefile, vim.split(text, "\n", { trimempty = true }), path)
    if ok then
      text = text .. "\nWrote diagnostics to: " .. path .. "\n"
    else
      text = text
        .. "\n[agentcomplete] failed to write diagnostics to "
        .. tostring(path)
        .. ": "
        .. tostring(err)
        .. "\n"
    end
  end

  if opts.print ~= false then
    print(text)
  end
  return report, path
end

return M
