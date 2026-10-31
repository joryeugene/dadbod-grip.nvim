-- Separate read-helper profile controls: text bytes are the read contract;
-- hidden ENUM ordinals / SET masks are guarded by the write-profile tests.
if not vim.env.GRIP_SAFETY_MYSQL_URL and not vim.env.GRIP_SAFETY_MARIA_URL then
  print("safety_adversarial_mysql_profile_read_spec: SKIP (assigned fixtures unavailable)")
  return
end
local H = dofile("tests/fixtures/safety_adversarial_harness.lua")
local profiles = dofile("tests/fixtures/safety_mysql_profiles.lua")
local db = require("dadbod-grip.db")
local name = "grip_review_profile_read"
local function unhex(value)
  return (value:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end
for _, key in ipairs({ "GRIP_SAFETY_MYSQL_URL", "GRIP_SAFETY_MARIA_URL" }) do
  local url = vim.env[key]
  if url then
    assert(require("dadbod-grip.sql").parse_dadbod_url(url).dbname == "grip_safety_review", "unassigned fixture")
    for _, family in ipairs({ "ordinary", "ambiguous", "escaped" }) do
      for _, profile in ipairs(profiles[family]) do
        H.test(key .. " F12 read profile " .. profile.id, function(c)
          c.url = url
          c.exec("DROP TABLE IF EXISTS " .. name)
          c.exec("CREATE TABLE " .. name .. "(id INTEGER PRIMARY KEY,payload " .. profile.definition
            .. ",note VARCHAR(30)); INSERT INTO " .. name .. " VALUES " .. profile.values)
          local ok, err = xpcall(function()
            local oracle = "SELECT id,payload+0,HEX(payload),note FROM " .. name .. " ORDER BY id"
            local before = c.rows(oracle)
            -- Ordinary query selects the valid member; zero-value read support
            -- remains separately visible in the unchanged F09 positive.
            local result, failure = db.query("SELECT payload FROM " .. name
              .. (family == "ordinary" and " WHERE id=1" or " ORDER BY id"), url)
            if family == "ordinary" then
              assert(result, failure)
              H.eq(result.rows, { { unhex(before[1][3]) } }, "native HEX spelling differs from helper text")
              H.eq(result.lossless, true)
            else
              H.eq(result, nil, "unproven native definition was advertised as a lossless snapshot")
              assert(type(failure) == "string" and (failure:find("withheld", 1, true)
                or failure:lower():find("unsupported", 1, true) or failure:lower():find("refused", 1, true)),
                "unsupported snapshot needs an explicit refusal")
              print("CONTAINED: unproven " .. profile.id .. " snapshot withheld; no ordinal support claimed")
            end
            H.eq(c.rows(oracle), before, "materialization changed source rows")
          end, debug.traceback)
          c.exec("DROP TABLE " .. name)
          if not ok then error(err) end
        end)
      end
    end
  end
end
H.finish("safety_adversarial_mysql_profile_read_spec")
