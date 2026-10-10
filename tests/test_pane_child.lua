-- Tests for the pane that need their own Neovim: quitting the editor with the pane open, and
-- opening it from insert mode. The in-process suite cannot quit itself or sit in insert mode.

local MiniTest = require("mini.test")
local new_set, expect = MiniTest.new_set, MiniTest.expect

local child = MiniTest.new_child_neovim()

---Start a child editing a real prompt file, so `:wq` and `:x` have something to write.
local function start()
  child.restart({ "-u", "tests/minimal_init.lua" })
  child.lua([[
    vim.api.nvim_list_uis = function()
      return { { width = 200, height = 50 } }
    end
    local path = vim.fn.tempname()
    vim.fn.writefile({ "draft" }, path)
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    require("agentcomplete.context").register({
      name = "claude-code",
      resolve = function(_, cb)
        cb({ ok = true, resolver = "claude-code", text = "hello" })
        return true
      end,
    })
  ]])
end

local function open_pane()
  child.lua([[
    require("agentcomplete.context").open(
      vim.api.nvim_get_current_buf(),
      { tool = "claude-code", cwd = "/proj", skill_dirs = {}, command_dirs = {} },
      { enabled = true, min_width = 160 },
      { log_path = vim.fn.tempname(), format = function(text) return text end }
    )
  ]])
end

local T = new_set({
  hooks = {
    pre_case = start,
    post_once = child.stop,
  },
})

-- The quit is a notification, so no request is in flight when the child exits.
T["ending the session with the pane open"] = new_set({
  parametrize = {
    { "q", "command" },
    { "wq", "command" },
    { "x", "command" },
    { "ZZ", "input" },
  },
}, {
  ["ends the child in one step"] = function(keys, via)
    open_pane()
    expect.equality(#child.api.nvim_list_wins(), 2)
    if via == "command" then
      child.api_notify.nvim_command(keys)
    else
      child.api_notify.nvim_input(keys)
    end
    expect.equality(vim.fn.jobwait({ child.job.id }, 1000)[1], 0)
  end,
})

T["opening the pane from insert mode keeps the prompt typing"] = function()
  child.type_keys("i", "hello")
  open_pane()
  expect.equality(#child.api.nvim_list_wins(), 2)
  expect.equality(child.api.nvim_get_mode().mode, "i")
  expect.equality(child.api.nvim_win_get_cursor(0), { 1, 5 })
end

return T
