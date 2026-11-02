-- One loading-clock owner per synchronous database write. Keep the retained
-- client duration inside the float callback so window setup/teardown and the
-- subsequent SELECT are not counted as database-client work.
local M = {}

-- A client wait pumps input as well as timers. Only the initiating grid/query
-- may accept completion: navigation or new edits during the wait own their
-- current state, even though the old SQL may have committed successfully.
function M.capture_owner(bufnr, session)
  local state, url, spec, query_sql = session.state, session.url, session.query_spec, session.query_sql
  local generation, current_view = session._refresh_generation, session.current_view
  return function()
    return require("dadbod-grip.view")._sessions[bufnr] == session
      and vim.api.nvim_buf_is_valid(bufnr) and session.state == state and session.url == url
      and session.query_spec == spec and session.query_sql == query_sql
      and session._refresh_generation == generation and session.current_view == current_view
  end
end

function M.execute(sql, url, label)
  local lifecycle = type(sql) == 'table' and { state = 'unattested', settled = false } or nil
  local short = ((label or "SQL"):match("^([^\n]+)") or "SQL"):sub(1, 50)
  local written = require("dadbod-grip.ui").blocking("  writing " .. short .. "...", function()
    local db = require("dadbod-grip.db")
    local opts = { engine_timing = require("dadbod-grip").get_opts().engine_timing,
      write_lifecycle = lifecycle }
    local t0 = vim.uv.hrtime()
    local result, err = db.execute(sql, url, opts)
    -- Use one table: ui.blocking's Lua 5.1 unpack must not lose an error after
    -- a leading nil result. Never retry a failed or interrupted write.
    return { result = result, err = err, elapsed_ms = math.floor((vim.uv.hrtime() - t0) / 1e6) }
  end)
  -- These are the adapters' shared fallback messages for an interrupted wait
  -- or client timeout. The child/server may have committed before it stopped,
  -- or may still be running after vim.wait returned: no automatic retry.
  local unknown = (written.err and written.err:find("write committed but identity result", 1, true) ~= nil)
    or written.err == "command timed out"
    or written.err == "command timed out; process completion unknown"
    or written.err == "query interrupted; database outcome unknown"
    or written.err == "query interrupted; database outcome unknown; process completion unknown"
    or (written.err and written.err:match("^[%w_-]+ exited with code 124$") ~= nil)
    or (written.err and written.err:match("^[%w_-]+ exited with code 130$") ~= nil)
  if written.err and lifecycle and lifecycle.state ~= 'not_started' and not lifecycle.rollback_confirmed then
    unknown = true
  end
  if written.result and lifecycle then lifecycle.state, lifecycle.settled = 'complete', true end
  if unknown then
    written.err = "The database outcome is unknown. Refresh before retrying, after original client completion is confirmed. No automatic retry.\n"
      .. written.err
  end
  return written.result, written.err, written.elapsed_ms, unknown, lifecycle
end

-- A SELECT cannot settle a writer that may still be active. Refuse every
-- refresh entry point until the original child is known to have exited.
function M.refresh_allowed(session)
  if session._write_pending then
    vim.notify('Write in progress; refresh cannot replace its initiating rows.', vim.log.levels.ERROR)
    return false
  end
  if session._write_unknown and (not session._write_lifecycle or not session._write_lifecycle.settled) then
    vim.notify('Write completion is still unknown; refresh cannot discard staging or clear the write guard. Inspect the original client before reopening this grid.', vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.begin_write(session)
  if session._write_pending or session._write_unknown then
    vim.notify('A prior write is pending or uncertain; inspect it before another write.', vim.log.levels.ERROR)
    return false
  end
  -- Invalidate reads already in flight before submission. Even a reaped writer
  -- cannot make those older SELECT snapshots evidence of its final outcome.
  session._refresh_generation = (session._refresh_generation or 0) + 1
  session._write_pending = true
  return true
end

return M
