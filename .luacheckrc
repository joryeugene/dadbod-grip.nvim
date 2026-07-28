-- luacheck configuration. Run via `just lint`; enforced in CI (.github/workflows/test.yml).
--
-- Catches at parse time the class of mistake that otherwise only surfaces when a
-- user reaches the affected code path — a missing `require` read as a global,
-- a typo'd local, a shadowed variable. See tests/spec/globals_spec.lua, which
-- covers the missing-require case from the bytecode side and runs in the same CI.

-- Neovim embeds LuaJIT, so the plugin targets Lua 5.1 + LuaJIT extensions.
std = "luajit"

-- `vim` is writable, not just readable: plugin/ sets vim.g.loaded_* guards and
-- modules assign to vim.b/vim.wo/vim.o.
globals = {
  "vim",
}

read_globals = {
  "Snacks", -- folke/snacks.nvim, probed by lua/dadbod-grip/pickers/snacks.lua
}

-- Unused function arguments are usually signature-driven (autocmd/callback shapes,
-- adapter interfaces implemented uniformly across backends), so naming them is
-- documentation rather than dead code.
unused_args = false

-- Line length is left to review, not the linter.
max_line_length = false

-- The gate covers shipped code only (see the `lint` recipe in the justfile).
-- tests/ is deliberately out: specs legitimately stub read-only fields such as
-- os.exit and os.time, and their remaining warnings are unused locals that look
-- like missing assertions — renaming those to `_` to please the linter would
-- hide the question rather than answer it. Worth its own pass.
exclude_files = {
  ".luarocks",
  "tests",
}
