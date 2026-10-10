-- Tests for agentcomplete.composer: the prompt window's prose options, applied to it, left alone
-- by the plugins that set their own, and restored on detach.
local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local T = new_set({
  hooks = {
    pre_case = function()
      vim.cmd("silent! only")
    end,
    post_case = function()
      local composer = require("agentcomplete.composer")
      for buf in pairs(composer._composers) do
        composer.detach(buf)
      end
      vim.cmd("silent! only")
    end,
  },
})

---A prompt buffer, focused, in a window with a code buffer's gutter, fold column, cursor line,
---and unwrapped text.
local function prompt()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win][0].number = true
  vim.wo[win][0].relativenumber = true
  vim.wo[win][0].signcolumn = "yes"
  vim.wo[win][0].foldcolumn = "1"
  vim.wo[win][0].cursorline = true
  vim.wo[win][0].wrap = false
  vim.wo[win][0].winbar = "%f"
  return buf, win
end

T["attach"] = new_set()

T["attach"]["drops the gutter and wraps prose with a hanging indent"] = function()
  local buf, win = prompt()
  require("agentcomplete.composer").attach(buf)
  expect.equality({
    vim.wo[win].number,
    vim.wo[win].relativenumber,
    vim.wo[win].signcolumn,
    vim.wo[win].foldcolumn,
    vim.wo[win].cursorline,
  }, { false, false, "no", "0", false })
  expect.equality({
    vim.wo[win].wrap,
    vim.wo[win].linebreak,
    vim.wo[win].breakindent,
    vim.wo[win].breakindentopt,
    vim.wo[win].smoothscroll,
  }, { true, true, true, "list:-1", true })
end

T["attach"]["leaves the statuscolumn, winbar, statusline and fillchars as they were"] = function()
  local buf, win = prompt()
  vim.wo[win][0].statuscolumn = "%l "
  vim.wo[win][0].statusline = "mine"
  vim.wo[win][0].fillchars = "fold:x"
  local function chrome()
    return {
      vim.wo[win].statuscolumn,
      vim.wo[win].winbar,
      vim.wo[win].statusline,
      vim.wo[win].fillchars,
    }
  end
  local before = chrome()
  require("agentcomplete.composer").attach(buf)
  expect.equality(chrome(), before)
end

T["attach"]["leaves the statusline alone"] = function()
  local buf, win = prompt()
  vim.wo[win][0].statusline = "mine"
  require("agentcomplete.composer").attach(buf)
  expect.equality(vim.wo[win].statusline, "mine")
end

-- Plugins re-attach their winbar on window events, and the composer must not undo it.
T["attach"]["keeps a winbar and wrap a plugin sets after attach"] = function()
  local buf, win = prompt()
  require("agentcomplete.composer").attach(buf)
  vim.wo[win].winbar = "%{%v:lua.dropbar()%}"
  vim.wo[win].wrap = false
  vim.api.nvim_exec_autocmds({ "BufWinEnter", "WinEnter" }, { buffer = buf })
  vim.wait(10)
  expect.equality(
    { vim.wo[win].winbar, vim.wo[win].wrap },
    { "%{%v:lua.dropbar()%}", false }
  )
end

-- The composer leaves a winbar a plugin sets from its own `BufWritePost` handler, where
-- `OptionSet` never fires.
T["attach"]["keeps a winbar a plugin sets from its own autocmd"] = function()
  local buf, win = prompt()
  local grp =
    vim.api.nvim_create_augroup("AgentCompleteComposerDropbarTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    callback = function()
      vim.wo[win][0].winbar = "%{%v:lua.dropbar()%}"
    end,
  })
  require("agentcomplete.composer").attach(buf)
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  vim.api.nvim_del_augroup_by_id(grp)
  vim.wait(100)
  expect.equality(vim.wo[win].winbar, "%{%v:lua.dropbar()%}")
end

T["attach"]["keeps a statuscolumn set with :set in the prompt"] = function()
  local buf, win = prompt()
  require("agentcomplete.composer").attach(buf)
  vim.cmd("set statuscolumn=%l")
  local kept = vim.wo[win].statuscolumn
  vim.go.statuscolumn = ""
  expect.equality(kept, "%l")
end

-- A user who sets the number column in the prompt meant to.
T["attach"]["lets the number column be turned back on"] = function()
  local buf, win = prompt()
  require("agentcomplete.composer").attach(buf)
  vim.wo[win][0].number = true
  expect.equality(vim.wo[win].number, true)
end

T["attach"]["is idempotent, so a second attach cannot save its own values as the user's"] = function()
  local buf, win = prompt()
  local composer = require("agentcomplete.composer")
  composer.attach(buf)
  composer.attach(buf)
  composer.detach(buf)
  expect.equality(vim.wo[win].number, true)
end

T["detach"] = new_set()

T["detach"]["restores the window's own options"] = function()
  local buf, win = prompt()
  local composer = require("agentcomplete.composer")
  composer.attach(buf)
  composer.detach(buf)
  expect.equality({
    vim.wo[win].number,
    vim.wo[win].relativenumber,
    vim.wo[win].signcolumn,
    vim.wo[win].foldcolumn,
    vim.wo[win].cursorline,
    vim.wo[win].wrap,
    vim.wo[win].linebreak,
    vim.wo[win].breakindent,
    vim.wo[win].breakindentopt,
    vim.wo[win].smoothscroll,
  }, { true, true, "yes", "1", true, false, false, false, "", false })
end

T["detach"]["forgets a buffer that was wiped"] = function()
  local buf = prompt()
  local composer = require("agentcomplete.composer")
  composer.attach(buf)
  vim.cmd("vnew")
  vim.api.nvim_buf_delete(buf, { force = true })
  expect.equality(composer._composers[buf], nil)
end

return T
