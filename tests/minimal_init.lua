-- Minimal init for headless testing: loads plugin from repo root
vim.opt.rtp:prepend(".")
local lazy_path = vim.fn.stdpath("data") .. "/lazy"
vim.opt.rtp:prepend(lazy_path .. "/vim-dadbod")
-- Do not call setup() for pure module tests (avoids needing vim-dadbod)
