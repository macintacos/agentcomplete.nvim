-- Tests for agentcomplete.diagnostics: the pure suppression diagnosis (the
-- EXC-653 root-cause heuristic) and the pure markdown renderer. The glue
-- (collect/run, which read live editor state and write a file) is exercised by
-- the headless smoke check in `mise run diag`, not here.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

-- A blink-suppression state snapshot with every field in its "healthy" value;
-- each case overrides only the field it is exercising.
local function state(overrides)
  local s = {
    resolved_backend = "blink",
    config_reachable = true,
    registered = { agentcomplete = true, path = true },
    wrap_installed = true,
    detected = true,
    allowed_sources = {},
  }
  for k, v in pairs(overrides or {}) do
    s[k] = v
  end
  return s
end

local function has(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

local T = new_set()

T["diagnose_suppression"] = new_set()

T["diagnose_suppression"]["native backend: nothing to suppress"] = function()
  local diag = require "agentcomplete.diagnostics"
  local r = diag.diagnose_suppression(state { resolved_backend = "native" })
  expect.equality(r.active, false)
  expect.equality(has(r.cause, "native backend"), true)
end

T["diagnose_suppression"]["blink active but config not reachable"] = function()
  local diag = require "agentcomplete.diagnostics"
  local r = diag.diagnose_suppression(state { config_reachable = false, registered = nil })
  expect.equality(r.active, true)
  expect.equality(r.config_reachable, false)
  expect.equality(has(r.cause, "not reachable"), true)
end

T["diagnose_suppression"]["agentcomplete not a registered provider"] = function()
  local diag = require "agentcomplete.diagnostics"
  local r = diag.diagnose_suppression(state { registered = { path = true } })
  expect.equality(r.agentcomplete_registered, false)
  expect.equality(has(r.cause, "not a registered blink provider"), true)
end

T["diagnose_suppression"]["registered but wrap not installed (load order)"] = function()
  local diag = require "agentcomplete.diagnostics"
  local r = diag.diagnose_suppression(state { wrap_installed = false })
  expect.equality(r.agentcomplete_registered, true)
  expect.equality(r.wrap_installed, false)
  expect.equality(has(r.cause, "load order"), true)
end

T["diagnose_suppression"]["wrap installed but current buffer not detected"] = function()
  local diag = require "agentcomplete.diagnostics"
  local r = diag.diagnose_suppression(state { detected = false })
  expect.equality(r.wrap_installed, true)
  expect.equality(r.detected, false)
  expect.equality(has(r.cause, "not detected as an agent prompt buffer"), true)
end

T["diagnose_suppression"]["installed and detected: agentcomplete is the only source"] = function()
  local diag = require "agentcomplete.diagnostics"
  local r = diag.diagnose_suppression(state { allowed_sources = { "path" } })
  expect.equality(r.effective, { "agentcomplete", "path" })
  expect.equality(has(r.cause, "only source"), true)
end

T["diagnose_suppression"]["unregistered allowed_sources are reported as dropped"] = function()
  local diag = require "agentcomplete.diagnostics"
  local r = diag.diagnose_suppression(state { allowed_sources = { "path", "ghost" } })
  expect.equality(r.effective, { "agentcomplete", "path" })
  expect.equality(r.dropped, { "ghost" })
end

T["render"] = new_set()

-- A fully-populated report, mirroring what collect() builds in a detected buffer.
local function full_report()
  local diag = require "agentcomplete.diagnostics"
  return {
    nvim_version = "0.11.0",
    config = {
      backend = "auto",
      resolved_backend = "blink",
      detect = "auto",
      enabled = true,
      sources = { slash = true, file = true },
      allowed_sources = { "path" },
    },
    buffer = {
      nr = 7,
      name = "/tmp/claude-1/claude-prompt-abc.md",
      detected = true,
      native_attached = false,
      session_source = "detected",
    },
    session = { tool = "claude-code", cwd = "/proj", session_id = nil },
    discovery = { skills = 3, cli_skills = 0, commands = 2, cli_commands = 0, extra_commands = 0, files = 42 },
    highlighting = {
      attached = true,
      painted = 2,
      groups = { AgentCompleteSkill = "Special", AgentCompleteFile = "Directory" },
      slash_set = 5,
    },
    context = {
      resolver = "claude-code",
      session_id = "sess-1",
      transcript = "/proj/.claude/transcript.jsonl",
      bytes = 1234,
    },
    blink = diag.diagnose_suppression(state { allowed_sources = { "path" } }),
    env = {
      AGENTCOMPLETE_CWD = nil,
      agentcomplete_cwd_g = nil,
      CLAUDE_CONFIG_DIR = nil,
      CLAUDE_CODE_SESSION_ID = "sess-1",
      EDITOR = "nvim",
      VISUAL = nil,
      cwd = "/proj",
    },
  }
end

T["render"]["includes the title and every section header"] = function()
  local diag = require "agentcomplete.diagnostics"
  local out = diag.render(full_report())
  expect.equality(type(out), "string")
  for _, header in ipairs {
    "# agentcomplete.nvim diagnostics",
    "## Config",
    "## Detection",
    "## Discovery",
    "## Highlighting",
    "## Context",
    "## blink suppression",
    "## Environment",
  } do
    expect.equality(has(out, header), true)
  end
  -- The diagnosis cause is surfaced in the body.
  expect.equality(has(out, "only source"), true)
  -- The discovery counts from the report render (42 = files, distinctive here).
  expect.equality(has(out, "42"), true)
end

-- The pane is decoration on someone's prompt buffer, so it fails silently by design; this
-- section is where a missing one becomes legible.
T["render"]["names the resolver, session, transcript, and size of the shown message"] = function()
  local diag = require "agentcomplete.diagnostics"
  local out = diag.render(full_report())
  expect.equality(has(out, "claude-code"), true)
  expect.equality(has(out, "/proj/.claude/transcript.jsonl"), true)
  expect.equality(has(out, "1234"), true)
end

-- A pane showing the wrong conversation looks identical to one showing the right conversation,
-- so the rung that chose the session is what a reader has to be able to see.
T["render"]["names the rung that resolved the session and where pointers are looked for"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.context = { resolver = "opencode", rung = "guessed", session_id = "ses_x", bytes = 12 }
  report.pointer_dir = "/state/opencode/agentcomplete"
  local out = diag.render(report)
  expect.equality(has(out, "guessed"), true)
  expect.equality(has(out, "/state/opencode/agentcomplete"), true)
end

T["render"]["reports the OpenCode session env and what the plugin path holds"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.env.OPENCODE_SESSION_ID = "ses_env"
  report.env.XDG_STATE_HOME = "/state"
  report.opencode_plugin = "/checkout/opencode/agentcomplete.ts"
  local out = diag.render(report)
  expect.equality(has(out, "OPENCODE_SESSION_ID"), true)
  expect.equality(has(out, "XDG_STATE_HOME"), true)
  expect.equality(has(out, "/checkout/opencode/agentcomplete.ts"), true)
end

T["render"]["surfaces the reason no pane opened"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.context = { resolver = "claude-code", err = "no transcript for session sess-1" }
  local out = diag.render(report)
  expect.equality(has(out, "no transcript for session sess-1"), true)
end

T["render"]["a minimal report (no session, blink inactive) renders without error"] = function()
  local diag = require "agentcomplete.diagnostics"
  local out = diag.render {
    nvim_version = "0.11.0",
    config = {
      backend = "native",
      resolved_backend = "native",
      detect = "auto",
      enabled = true,
      sources = { slash = true, file = true },
      allowed_sources = {},
    },
    buffer = { nr = 1, name = "", detected = false, native_attached = false, session_source = "none" },
    session = nil,
    discovery = nil,
    highlighting = { attached = false, painted = 0, groups = {}, slash_set = nil },
    context = nil,
    blink = diag.diagnose_suppression(state { resolved_backend = "native" }),
    env = { cwd = "/proj" },
  }
  expect.equality(type(out), "string")
  expect.equality(has(out, "# agentcomplete.nvim diagnostics"), true)
  -- No session ⇒ the detection section says so rather than erroring on nil.
  expect.equality(has(out, "(none)"), true)
  -- ...and Highlighting degrades the same way rather than sizing a set that isn't there.
  expect.equality(has(out, "(no active session)"), true)
  -- ...as does Context, which never ran at all here.
  expect.equality(has(out, "(no context resolved)"), true)
end

T["render"]["surfaces OpenCode env signals and the session's search dirs"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.session.tool = "opencode"
  report.session.skill_dirs = { "/proj/.opencode/skill" }
  report.session.command_dirs = { "/proj/.opencode/command" }
  report.env.OPENCODE = "1"
  report.env.OPENCODE_PID = "999"
  report.env.OPENCODE_CONFIG_DIR = "/cfg/opencode"
  local out = diag.render(report)
  expect.equality(has(out, "OPENCODE:"), true)
  expect.equality(has(out, "OPENCODE_PID:"), true)
  expect.equality(has(out, "OPENCODE_CONFIG_DIR:"), true)
  -- The session's search dirs tell a debugger WHERE discovery looked.
  expect.equality(has(out, "/proj/.opencode/skill"), true)
  expect.equality(has(out, "/proj/.opencode/command"), true)
end

T["render"]["names both highlight groups and what each resolves to"] = function()
  local diag = require "agentcomplete.diagnostics"
  local out = diag.render(full_report())
  expect.equality(has(out, "AgentCompleteSkill"), true)
  expect.equality(has(out, "Special"), true)
  expect.equality(has(out, "AgentCompleteFile"), true)
  expect.equality(has(out, "Directory"), true)
end

T["render"]["reports the size of the resolved / set"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.highlighting.slash_set = 23
  expect.equality(has(diag.render(report), "set size:      23"), true)
end

-- The count is what separates "nothing resolves" from "it painted, look at your
-- colorscheme" — the fork the diagnostics doc sends a reader here to settle.
T["render"]["reports how many tokens are currently painted"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.highlighting.painted = 9
  expect.equality(has(diag.render(report), "painted: 9"), true)
end

T["render"]["surfaces the CLI resolver toggle and its resolved skill count"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.config.opencode = { show_all_builtin_commands = false, resolve_via_cli = true, install_plugin = false }
  report.discovery.cli_skills = 17
  local out = diag.render(report)
  expect.equality(has(out, "resolve_via_cli"), true)
  expect.equality(has(out, "opencode debug skill"), true)
  expect.equality(has(out, "17"), true) -- the CLI-resolved skill count
end

-- A `guessed` context rung with no plugin installed forks on whether the user ever asked for the
-- install; without this line the report cannot settle it.
T["render"]["surfaces whether setup() was asked to install the OpenCode plugin"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.config.opencode = { show_all_builtin_commands = false, resolve_via_cli = true, install_plugin = true }
  expect.equality(has(diag.render(report), "opencode.install_plugin:            yes"), true)
end

-- Counting commands per source is what makes a discovery path that searched the wrong directory
-- legible: summing them let ~17 static built-ins pass for a healthy command line while the
-- filesystem scan found nothing.
T["render"]["counts each command source separately"] = function()
  local diag = require "agentcomplete.diagnostics"
  local report = full_report()
  report.discovery.commands = 0
  report.discovery.cli_commands = 25
  report.discovery.extra_commands = 17
  local out = diag.render(report)
  expect.equality(has(out, "commands (filesystem):            0"), true)
  expect.equality(has(out, "commands (opencode debug config): 25"), true)
  expect.equality(has(out, "commands (config map + built-in): 17"), true)
end

return T
