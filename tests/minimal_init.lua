-- Minimal init for headless testing: loads plugin from repo root
vim.opt.rtp:prepend(".")
-- Do not call setup() for pure module tests
