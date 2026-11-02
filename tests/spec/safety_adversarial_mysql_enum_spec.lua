-- Native ENUM ordinal / SET mask semantics: identical display text is not
-- evidence of identical stored values. Only disposable assigned tables.
if not vim.env.GRIP_SAFETY_MYSQL_URL and not vim.env.GRIP_SAFETY_MARIA_URL then
  print("safety_adversarial_mysql_enum_spec: SKIP (assigned review fixtures unavailable)")
  return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local data = require("dadbod-grip.data")
local function open_or_contain(c, name, kind, oracle, before)
  local notices = #c.notices
  local ok, buf, session = pcall(c.open, name)
  if ok then return buf, session end
  local emitted = table.concat(c.notices, "\n", notices + 1):lower()
  assert(emitted:find(kind:lower(), 1, true) and emitted:find("definition", 1, true),
    "grid-open refusal must identify the unsupported type definition: " .. emitted .. ": " .. tostring(buf))
  assert(not emitted:find("applied ", 1, true), "refused grid reported a write")
  H.eq(c.rows(oracle), before, "early capability refusal changed native ordinal/mask or data")
  print("CONTAINED: " .. kind .. " unsupported definition refused at grid open; no write attempted")
  return nil
end
for _, key in ipairs({ "GRIP_SAFETY_MYSQL_URL", "GRIP_SAFETY_MARIA_URL" }) do
  local url = vim.env[key]
  if url then
    assert(require("dadbod-grip.sql").parse_dadbod_url(url).dbname == "grip_safety_review", "unassigned fixture")
    for _, kind in ipairs({ "ENUM", "SET" }) do
      H.test(key .. " F07 " .. kind .. " DELETE Undo retains ordinal/mask or refuses before write", function(c)
        c.url = url
        local name = "grip_review_enum_fidelity"
        c.exec("DROP TABLE IF EXISTS " .. name)
        local ok, err = xpcall(function()
          c.exec("CREATE TABLE " .. name .. "(id INTEGER PRIMARY KEY,payload " .. kind .. "('','a'),note VARCHAR(30));"
            .. "INSERT INTO " .. name .. " VALUES(1," .. (kind == "ENUM" and "'invalid'" or "1") .. ",'before')")
          local oracle = "SELECT id,payload+0,HEX(payload),note FROM " .. name
          local before = c.rows(oracle)
          H.eq(before[1][2], kind == "ENUM" and "0" or "1", "native special value was not seeded")
          H.eq(before[1][3], "", "special value should have empty display spelling")
          local buf, session = open_or_contain(c, name, kind, oracle, before)
          if not buf then return end
          session.on_delete(buf, 1)
          c.action("grid_apply")
          if c.scalar("SELECT count(*) FROM " .. name) == "1" then
            H.eq(c.rows(oracle), before)
            assert(session.state.readonly or data.has_changes(session.state))
            assert(not table.concat(c.notices):find("Applied ", 1, true), "refused write reported success")
            print("CONTAINED: " .. kind .. " ambiguous native value refused before mutation")
          else
            c.action("grid_undo")
            H.eq(c.rows(oracle), before, "empty display text lost original ordinal/mask")
          end
        end, debug.traceback)
        c.exec("DROP TABLE " .. name)
        if not ok then error(err) end
      end)
      H.test(key .. " F08 " .. kind .. " storage-only concurrent change must conflict", function(c)
        c.url = url
        local name = "grip_review_enum_fidelity"
        c.exec("DROP TABLE IF EXISTS " .. name)
        local ok, err = xpcall(function()
          c.exec("CREATE TABLE " .. name .. "(id INTEGER PRIMARY KEY,payload " .. kind .. "('','a'),note VARCHAR(30));"
            .. "INSERT INTO " .. name .. " VALUES(1," .. (kind == "ENUM" and "'invalid'" or "0") .. ",'before')")
          local oracle = "SELECT id,payload+0,HEX(payload),note FROM " .. name
          local before = c.rows(oracle)
          local buf, session = open_or_contain(c, name, kind, oracle, before)
          if not buf then return end
          c.edit(buf, session, 1, "note", "ours")
          c.exec("UPDATE " .. name .. " SET payload=1 WHERE id=1")
          H.eq(c.scalar("SELECT payload+0 FROM " .. name), "1")
          c.action("grid_apply")
          H.eq(c.scalar("SELECT note FROM " .. name), "before", "display-equal native value passed stale snapshot guard")
          assert(session.state.readonly or data.has_changes(session.state), "conflict lost pending edit")
        end, debug.traceback)
        c.exec("DROP TABLE " .. name)
        if not ok then error(err) end
      end)
    end
  end
end
H.finish("safety_adversarial_mysql_enum_spec")
