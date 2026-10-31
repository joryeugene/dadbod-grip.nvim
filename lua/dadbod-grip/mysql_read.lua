-- One original SELECT evaluation; explicit byte receipts and post-read source
-- proof on the same native transaction. No TEMP tables, fallback or retry.
local adapters = require("dadbod-grip.adapters")
local transport = require("dadbod-grip.transport")
local M = {}
local derived_plan = require("dadbod-grip.mysql_read_plan")
M.plan = derived_plan.plan
M.resolve_plan = derived_plan.resolve
M.derived_sql = derived_plan.sql

local function split(line) return vim.split(line, "\t", { plain = true }) end
local function unhex(value)
  assert(type(value) == "string" and #value % 2 == 0 and value:match("^%x*$"), "invalid hex receipt")
  return transport.unhex(value)
end

local function utf8_valid(s)
  local i = 1
  while i <= #s do
    local a = s:byte(i)
    if a < 0x80 then i = i + 1
    else
      local count = a >= 0xc2 and a <= 0xdf and 2 or a >= 0xe0 and a <= 0xef and 3 or a >= 0xf0 and a <= 0xf4 and 4
      if not count or i + count - 1 > #s then return false end
      local b = s:byte(i + 1)
      if (a == 0xe0 and b < 0xa0) or (a == 0xed and b >= 0xa0)
          or (a == 0xf0 and b < 0x90) or (a == 0xf4 and b >= 0x90) then return false end
      for j = 1, count - 1 do local c = s:byte(i + j); if c < 0x80 or c > 0xbf then return false end end
      i = i + count
    end
  end
  return true
end

-- Diagnostic counts are metadata, not user values. Only deprecation warning
-- 1287 is permitted; truncation/conversion and unknown warnings withhold the
-- result. SHOW COUNT/SHOW WARNINGS preserve the original diagnostics.
function M.warnings(lines)
  assert(lines[1] and lines[1]:match("^%d+$"), "missing warning-count receipt")
  local count = tonumber(lines[1])
  assert(count == #lines - 1, "incomplete warning receipt")
  for i = 2, #lines do
    local fields = split(lines[i])
    assert(#fields == 3 and fields[1] == "Warning" and fields[2] == "1287",
      "unsafe SQL warning; exact values are unproven")
  end
end

-- N/T/X is an encoding receipt, never a physical-type guess. Only an
-- independently admitted bound column can restore a physical cell kind.
function M.decode_derived(lines, plan)
  local diagnostic
  for i, line in ipairs(lines) do if line:match("^%d+$") then diagnostic = i; break end end
  assert(diagnostic, "missing result warning receipt")
  M.warnings({ unpack(lines, diagnostic) })
  local provenance = require("dadbod-grip.provenance")
  if plan.source_bound then
    local admitted, err = provenance.validate_source(plan.source_schema_proof, plan.source_columns, "read_complete")
    assert(admitted, err or "source read completion was not admitted")
  end
  local all_restorable = plan.source_bound == true
  for _, info in ipairs(plan.column_info) do if info.restorable ~= true then all_restorable = false end end
  local result = { columns = vim.deepcopy(plan.columns), column_info = vim.deepcopy(plan.column_info),
    source_columns = vim.deepcopy(plan.source_columns), header_provenance = vim.deepcopy(plan.header_provenance),
    source_schema_proof = vim.deepcopy(plan.source_schema_proof), rows = {}, cell_types = {}, primary_keys = {},
    storage_adapter = "mysql", transport_provenance = "mysql_derived_v1", byte_exact = true,
    readonly = plan.readonly == true, lossless = all_restorable,
    restorable = all_restorable, editable = all_restorable and plan.readonly ~= true }
  local encodings = {}
  for ri = 1, diagnostic - 1 do
    local fields, row, types = split(lines[ri]), {}, {}
    assert(#fields == #plan.columns, "invalid derived result width")
    for ci, field in ipairs(fields) do
      local tag, payload, meta = field:sub(1, 1), field:sub(2), result.column_info[ci]
      if tag == "N" then
        assert(payload == "", "invalid NULL receipt"); row[ci], types[ci] = vim.NIL, "null"
      else
        assert(tag == "T" or tag == "X", "invalid derived encoding tag")
        assert(not encodings[ci] or encodings[ci] == tag, "inconsistent derived column encoding")
        encodings[ci] = tag
        local bytes = unhex(payload)
        if tag == "T" then
          assert(utf8_valid(bytes), "invalid UTF8 text receipt"); meta.encoding_proven = true
          if not meta.restorable and result.source_columns[ci] then meta.kind = "text" end
        end
        if meta.restorable then
          if meta.kind == "blob" then assert(tag == "X", "bound binary source returned a text encoding")
          elseif meta.kind == "text" then
            local json = (meta.data_type or ""):lower() == "json"
            assert(tag == "T" or json, "bound text source returned an unexpected binary encoding")
            assert(utf8_valid(bytes), "bound text source is not valid UTF8")
          else
            assert(tag == "X" and utf8_valid(bytes), "bound scalar returned an unexpected encoding")
          end
          types[ci] = meta.kind
        else types[ci] = tag == "T" and result.source_columns[ci] and "text" or "raw_unknown" end
        row[ci] = bytes
      end
    end
    result.rows[ri], result.cell_types[ri] = row, types
  end
  return result
end

M._token = function()
  return vim.fn.sha256(vim.fn.tempname() .. tostring(vim.uv.hrtime())):sub(1, 24)
end

-- All waits pump the main loop. The deadline belongs to the whole read,
-- including capability and metadata phases. No SQL or password enters argv.
local function session(config)
  if config.deadline and config.deadline <= vim.uv.hrtime() / 1e6 then return nil, "query deadline expired before client start" end
  local args = vim.deepcopy(config.args)
  vim.list_extend(args, { "--skip-column-names", "--unbuffered", "--skip-force", "--skip-reconnect",
    "--binary-mode", "--default-character-set=utf8mb4" })
  local out, errors, done, completed, stream_error = "", {}, false, nil, nil
  local deadline = config.deadline or (vim.uv.hrtime() / 1e6 + config.timeout)
  local ok, process = pcall(vim.system, args, {
    stdin = true, text = false, env = config.env,
    stdout = function(err, data) if err then stream_error = err end; if data then out = out .. data end end,
    stderr = function(err, data) if err then stream_error = err end; if data then errors[#errors + 1] = data end end,
  }, function(value) completed, done = value, true end)
  if not ok then return nil, tostring(process) end
  local s = { submitted = false, phase = "setup", readonly = config.readonly == true }
  local function remaining() return math.max(0, math.ceil(deadline - vim.uv.hrtime() / 1e6)) end
  local function stop()
    pcall(process.write, process, nil)
    if not done then pcall(process.kill, process, 15); pcall(process.wait, process, 100) end
    if not done then pcall(process.kill, process, 9); pcall(process.wait, process, 1000) end
  end
  function s.close() stop() end
  local started = false
  function s.start()
    if started then return end
    local written, err = pcall(process.write, process, config.setup)
    assert(written, "client setup failed: " .. tostring(err))
    started = true
  end
  local function wait(predicate)
    local waited, success, reason = pcall(vim.wait, remaining(), function() return predicate() or done or stream_error ~= nil end, 1)
    if not waited or not success then
      local interrupted = not waited or reason == -2
      stop()
      error((interrupted and "query interrupted" or "query timed out")
        .. (s.submitted and "; original read outcome unknown" or "; original read was not submitted")
        .. (not done and "; process completion unknown" or ""), 0)
    end
    assert(not stream_error, "client stream failed: " .. tostring(stream_error))
  end
  function s.exchange(sql, marker, phase, original)
    s.phase = phase
    assert(not done, "client exited before " .. phase)
    if original then s.submitted = true end
    local begin_marker, end_marker = marker .. "_BEGIN", marker .. "_END"
    local written, write_error = pcall(process.write, process,
      "SELECT '" .. begin_marker .. "';\n" .. sql .. "\nSELECT '" .. end_marker .. "';\n")
    assert(written, "client input failed: " .. tostring(write_error))
    local finish
    wait(function()
      finish = ("\n" .. out):find("\n" .. end_marker .. "\r?\n")
      return finish ~= nil
    end)
    if not finish then
      error((table.concat(errors) ~= "" and table.concat(errors) or ("client exited with code " .. tostring(completed and completed.code))) , 0)
    end
    local lines = vim.split(out, "\n", { plain = true })
    local frame, found, consumed = {}, false, 0
    assert(lines[1]:gsub("\r$", "") == begin_marker, "unexpected client output before " .. phase)
    for index = 2, #lines do
      local line = lines[index]:gsub("\r$", "")
      if line == end_marker then found, consumed = true, index; break end
      frame[#frame + 1] = line
    end
    assert(found, "incomplete client receipt")
    out = table.concat(lines, "\n", consumed + 1)
    return frame
  end
  function s.original(sql, marker)
    s.phase = "original read"
    s.start()
    assert(not done, "client exited before original read")
    assert(out == "", "unexpected client output before original read")
    local end_marker = marker .. "_END"
    s.submitted = true
    local written, err = pcall(process.write, process, sql
      .. "\nSHOW COUNT(*) WARNINGS;\nSHOW WARNINGS;\nSELECT '" .. end_marker .. "';\n")
    assert(written, "client input failed: " .. tostring(err))
    local finish
    wait(function() finish = ("\n" .. out):find("\n" .. end_marker .. "\r?\n"); return finish ~= nil end)
    if not finish then error(table.concat(errors) ~= "" and table.concat(errors)
      or ("client exited with code " .. tostring(completed and completed.code)), 0) end
    local lines, frame, consumed = vim.split(out, "\n", { plain = true }), {}, nil
    for index, value in ipairs(lines) do
      local line = value:gsub("\r$", "")
      if line == end_marker then consumed = index; break end
      frame[#frame + 1] = line
    end
    assert(consumed, "incomplete original result receipt")
    out = table.concat(lines, "\n", consumed + 1)
    s.original_completed = true
    return frame
  end
  function s.commit(marker)
    local receipt = s.exchange("COMMIT;", marker, "commit")
    assert(#receipt == 0, "unexpected commit receipt")
    s.committed = true
  end
  function s.finish()
    local closed, err = pcall(process.write, process, nil)
    assert(closed, tostring(err))
    wait(function() return done end)
    assert(done and completed.code == 0, table.concat(errors) ~= "" and table.concat(errors) or "client did not complete successfully")
    assert(out:match("^%s*$"), "unexpected client output after cleanup")
    s.finished = true
    s.completion = { client = s, committed = s.committed == true, reaped = true, code = completed.code,
      readonly = s.readonly }
    return s.completion
  end
  return s
end

local function legacy_query(sql, config)
  local timeout = config.deadline and math.ceil(config.deadline - vim.uv.hrtime() / 1e6) or config.timeout
  if timeout <= 0 then return nil, "query deadline expired; original read was not submitted" end
  local args = vim.deepcopy(config.args)
  vim.list_extend(args, { "--xml", "--skip-force", "--skip-reconnect", "--binary-mode", "--default-character-set=utf8mb4" })
  local stdout, stderr, code = adapters.run_cmd(args, timeout,
    { stdin = config.setup .. sql, env = config.env, raw_output = true, terminate_on_interrupt = true })
  if code ~= 0 then return nil, stderr ~= "" and stderr or ("mysql exited with code " .. tostring(code)) end
  local result, err = transport.mysql_xml(stdout)
  if not result then return nil, err end
  result.primary_keys, result.readonly, result.lossless, result.byte_exact = {}, true, false, false
  result.column_info, result.source_columns, result.header_provenance, result.cell_types = {}, {}, {}, {}
  for ci = 1, #result.columns do
    result.column_info[ci] = { kind = "raw_unknown", encoding_proven = false, restorable = false,
      metadata_source = "native_legacy_unproven" }
    result.source_columns[ci], result.header_provenance[ci] = false, "native_legacy"
  end
  for ri in ipairs(result.rows) do
    result.cell_types[ri] = {}
    for ci = 1, #result.columns do result.cell_types[ri][ci] = "raw_unknown" end
  end
  result.storage_adapter = "mysql"
  result.transport_provenance, result.restorable, result.editable = "mysql_legacy_unproven", false, false
  return result
end

-- Header metadata is a candidate only. The original is the first source
-- access in its transaction; source metadata follows while SELECT MDL holds.
function M.derived_query(sql, config)
  local plan, plan_error = M.plan(sql)
  if not plan then return nil, "MySQL read refused before execution: " .. plan_error end
  local readonly = config.readonly == true or adapters.session_opts().readonly == true
  if plan.route == "custom" and readonly then return nil, "Connection is read-only; custom SQL was not submitted" end
  if plan.route == "legacy" or plan.route == "custom" then return legacy_query(sql, config) end
  local token = M._token()
  if type(token) ~= "string" or not token:match("^%x+$") or #token > 32 then return nil, "invalid private read token" end
  local marker = "__grip_read_" .. token
  config = vim.tbl_extend("force", config, { deadline = vim.uv.hrtime() / 1e6 + config.timeout, readonly = readonly })
  local provider = config.source_provider
  local direct = false
  for _, value in ipairs(plan.slots) do if value.kind == "direct" or value.kind == "star" then direct = true end end
  local candidate
  if plan.source and direct and provider then
    local header, header_error = session(config)
    if not header then return nil, "MySQL header metadata failed before original submission: " .. header_error end
    local ok, value = xpcall(function()
      header.start()
      local index = 0
      local function fetch(statement, phase)
        index = index + 1
        return header.exchange(statement, marker .. "_HEADER_" .. index, phase or "header metadata")
      end
      local described, err = provider.describe(plan.source, config.identity, fetch)
      assert(described, err or "source header metadata unavailable")
      header.finish()
      return described
    end, function(err) return tostring(err) end)
    header.close()
    if not ok then return nil, "MySQL header metadata failed; original read was not submitted: " .. value end
    candidate = value
    -- A successfully classified non-base object preserves existing access.
    -- The header client is already reaped; no original attempt preceded this
    -- deliberate native route. Denials/unknown capability never reach here.
    if candidate.route == "legacy" then return legacy_query(sql, config) end
  end
  local layout, layout_error = M.resolve_plan(plan, candidate)
  if not layout then return nil, "MySQL header planning failed; original read was not submitted: " .. layout_error end
  if plan.needs_schema and not candidate then return nil, "MySQL wildcard headers require source metadata; original read was not submitted" end
  local client, spawn_error = session(config)
  if not client then return nil, "MySQL derived read setup failed: " .. spawn_error end
  local ok, result = xpcall(function()
    client.start()
    if candidate then
      client.exchange("START TRANSACTION;", marker .. "_TX", "transaction start")
      client.transaction_started = true
    end
    local cells = client.original(M.derived_sql(layout), marker .. "_ROWS")
    local resolved = layout
    if candidate then
      local context, inspect_error = provider.inspect(client, candidate, marker .. "_SOURCE")
      assert(context, inspect_error or "post-read source metadata unavailable")
      local post, post_error = M.resolve_plan(plan, context.descriptor)
      local mismatch = context.mismatch or post_error
      if post and not vim.deep_equal(post.columns, layout.columns) then mismatch = "source/header layout changed" end
      -- A known successful original must finish once even when its result is
      -- withheld by a signature, type or codec check. Actual metadata/client
      -- errors above close the connection without force-continuing anything.
      client.commit(marker .. "_COMMIT")
      local completion = client.finish()
      assert(not mismatch, tostring(mismatch) .. "; query ran; result withheld")
      local proof, complete_error = provider.complete(context, completion, post.source_columns)
      assert(proof, tostring(complete_error or "source completion was not admitted") .. "; query ran; result withheld")
      local descriptor = { columns = context.descriptor.columns, source_schema_proof = proof }
      local err
      resolved, err = M.resolve_plan(plan, descriptor)
      assert(resolved and resolved.source_bound, tostring(err or "source receipt was not admitted") .. "; query ran; result withheld")
    else client.finish() end
    client.phase = "result validation"
    local decoded = M.decode_derived(cells, resolved)
    if readonly then decoded.readonly, decoded.editable = true, false end
    return decoded
  end, function(err) return tostring(err) end)
  client.close()
  if not ok then
    result = result .. (client.committed and not client.finished and "; COMMIT acknowledged but successful client completion unproven; result withheld; do not retry automatically"
      or client.committed and "; query ran; result withheld; do not retry automatically"
      or client.submitted and "; original read outcome unknown; do not retry automatically"
      or "; original read was not submitted")
    return nil, "MySQL derived " .. client.phase .. " failed: " .. result
  end
  return result
end

M.query = M.derived_query

return M
