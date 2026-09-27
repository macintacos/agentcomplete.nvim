-- Minimal init for headless test runs (see .mise/tasks/test).
--
-- Puts the plugin under test and mini.nvim (which provides mini.test) on the
-- runtimepath, then initializes the test framework.

-- Plugin under test (repo root).
vim.cmd("set rtp+=.")

-- mini.nvim is cloned here by `mise run setup`.
vim.cmd("set rtp+=.tests/site/pack/deps/start/mini.nvim")

-- Git hooks export GIT_DIR, which would aim the tests' git calls at this repo.
vim.env.GIT_DIR = nil

require("mini.test").setup()
