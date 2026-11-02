-- Additive public-path regressions; no existing assertions are changed.
local H=dofile('tests/fixtures/safety_adversarial_harness.lua')
local grip,view,db=require('dadbod-grip'),require('dadbod-grip.view'),require('dadbod-grip.db')
for _,case in ipairs({{'',string.char(0)..' WHERE id=2;'}, {'',' /* '..string.char(0)..' */ WHERE id=2;'},
 {'-- leading comment\n',string.char(0)..' WHERE id=2;'}, {'/* leading comment */\n',string.char(0)..' WHERE id=2;'}})do
 local prefix,tail=case[1],case[2]
 H.test('embedded NUL refuses before preview/query/execute '..#tail,function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT);INSERT INTO t VALUES(1,'one'),(2,'two')")
  local original=c.rows('SELECT id,hex(payload) FROM t ORDER BY id')
  local query,execute=db.query,db.execute;local queries,writes=0,{}
  db.query=function(...)queries=queries+1;return query(...)end
  db.execute=function(text,...)writes[#writes+1]=text;return execute(text,...)end
  local text=prefix.."UPDATE t SET payload='changed'"..tail
  local ok,err=xpcall(function()grip.open(text,c.url,{from_pad=true})end,debug.traceback)
  db.query,db.execute=query,execute;assert(ok,err)
  H.eq(c.rows('SELECT id,hex(payload) FROM t ORDER BY id'),original,'refusal preserves all fixture rows')
  H.eq(queries,0,'no preview or fallback query may cross the rejected boundary');H.eq(writes,{},'no original SQL executes')
  for _,session in pairs(view._sessions)do assert(not session.pending_mutation,'rejected SQL cannot remain executable')end
 end)
end
for _,case in ipairs({{expression='char(0)',hex='00'},{expression="CAST(X'0041' AS TEXT)",hex='0041'}})do
 H.test('ordinary SQL-generated NUL remains supported '..case.expression,function(c)
  c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY,payload TEXT);INSERT INTO t VALUES(1,'one'),(2,'two')")
  local text='UPDATE t SET payload='..case.expression..' WHERE id=2;'
  local execute=db.execute;local writes={}
  db.execute=function(sql,...)writes[#writes+1]=sql;return execute(sql,...)end
  local ok,err=xpcall(function()
   grip.open(text,c.url,{from_pad=true});local buf=vim.api.nvim_get_current_buf();local s=assert(view._sessions[buf]);assert(s.pending_mutation)
   H.eq(s.pending_mutation.row_count,1);H.eq(writes,{},'preview never writes')
   H.key(buf,require('dadbod-grip.keymaps').get('grid_apply'))
   H.eq(writes,{text},'confirmed original executes once')
   H.eq(c.rows('SELECT id,typeof(payload),hex(payload) FROM t ORDER BY id'),{{'1','text','6F6E65'},{'2','text',case.hex}},'NUL data remains scoped and exact')
  end,debug.traceback)
  db.execute=execute;assert(ok,err)
 end)
end
H.finish('pr105_nul_admission_spec')
