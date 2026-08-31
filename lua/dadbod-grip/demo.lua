-- demo.lua: prepare the disposable Softrear databases without touching the project.

local M = {}

M.label = "Softrear Inc. Analyst Portal\xe2\x84\xa2"

function M.spec()
  local has_duck = vim.fn.executable("duckdb") == 1
  local has_sqlite = vim.fn.executable("sqlite3") == 1
  if not has_duck and not has_sqlite then
    return nil, "GripStart requires duckdb or sqlite3 for the demo database."
  end

  local seed_name = has_duck and "demo/softrear.sql" or "demo/softrear_sqlite.sql"
  local seed = vim.api.nvim_get_runtime_file(seed_name, false)[1]
  if not seed then return nil, "Softrear Portal not found. Is the plugin in your runtimepath?" end

  local dir = vim.fn.stdpath("data") .. "/grip"
  local path = dir .. (has_duck and "/softrear.duckdb" or "/softrear.db")
  local supplier_seed = vim.api.nvim_get_runtime_file("demo/softrear_supplier.sql", false)[1]
  return {
    kind = has_duck and "duckdb" or "sqlite",
    path = path,
    url = (has_duck and "duckdb:" or "sqlite:") .. path,
    seed = seed,
    supplier_path = dir .. "/softrear-supplier.db",
    supplier_seed = has_duck and has_sqlite and supplier_seed or nil,
  }
end

local function seed_database(url, path, seed)
  local read_ok, lines = pcall(vim.fn.readfile, seed)
  if not read_ok then return nil, "could not read the bundled demo seed" end

  local existing = vim.fn.getftype(path)
  if existing ~= "" and (existing ~= "file" or vim.fn.delete(path) ~= 0) then
    return nil, "could not replace " .. vim.fn.fnamemodify(path, ":t")
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local result, err = require("dadbod-grip.db").execute(table.concat(lines, "\n") .. "\n", url)
  if not result then
    local message = err or "database client returned no result"
    if vim.fn.getftype(path) ~= "" and vim.fn.delete(path) ~= 0 then
      message = message .. "; the partial demo database could not be removed"
    end
    return nil, message
  end
  return true
end

function M.prepare(reseed)
  local spec, err = M.spec()
  if not spec then return nil, err end

  if spec.kind == "duckdb" then
    require("dadbod-grip.adapters.duckdb").load_attachments(spec.url, nil)
  end
  if reseed or vim.fn.filereadable(spec.path) == 0 then
    local ok
    ok, err = seed_database(spec.url, spec.path, spec.seed)
    if not ok then return nil, "Softrear seed failed: " .. err end
  end

  if spec.supplier_seed and (reseed or vim.fn.filereadable(spec.supplier_path) == 0) then
    local ok
    ok, err = seed_database("sqlite:" .. spec.supplier_path, spec.supplier_path, spec.supplier_seed)
    if not ok then
      spec.supplier_seed = nil
      spec.supplier_error = "Supplier demo seed failed: " .. err
    end
  end
  return spec
end

function M.attach_supplier(spec)
  if spec.kind ~= "duckdb" then return true end
  local duckdb = require("dadbod-grip.adapters.duckdb")
  duckdb.load_attachments(spec.url, nil)
  if not spec.supplier_seed then return true end
  local err = duckdb.attach(spec.url, "sqlite:" .. spec.supplier_path, "supplier")
  if err then return nil, "Supplier demo attachment failed: " .. err end
  return true
end

return M
