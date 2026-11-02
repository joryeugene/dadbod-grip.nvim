-- Additive inherited freshness gaps. Partial DDL is a real SQLite commit/error;
-- sidebar ownership uses native metadata plus a controlled URL-rebind delivery.
local H = dofile('tests/fixtures/safety_adversarial_harness.lua')
local completion, db, schema = require('dadbod-grip.completion'), require('dadbod-grip.db'), require('dadbod-grip.schema')
H.test('S08 partial DDL batch failure cannot leave completion knowingly stale',function(c)
 c.exec('CREATE TABLE t(id INTEGER PRIMARY KEY)')
 assert(#completion.get_schema(c.url).t==1)
 local result,err=db.execute('ALTER TABLE t ADD COLUMN committed TEXT; SELECT * FROM missing_table',c.url)
 assert(not result and err,'native last statement must fail')
 local native=vim.system({'sqlite3',c.url:sub(8),'PRAGMA table_info(t)'},{text=true}):wait()
 assert(native.code==0 and native.stdout:find('committed',1,true),'firstDDL actually committed')
 local got=completion.get_schema(c.url).t
 H.eq(got and got[2] and got[2].column_name,'committed')
end)

H.test('S09 stale column expansion cannot repaint a rebound sidebar',function(c)
 schema.close();schema._reset_state()
 c.exec('CREATE TABLE old_table(id INTEGER PRIMARY KEY,old_column TEXT)')
 local other='sqlite:'..c.root..'/other.sqlite'
 local seed=vim.system({'sqlite3',other:sub(8),'CREATE TABLE new_table(id INTEGER PRIMARY KEY,new_column TEXT)'},{text=true}):wait();assert(seed.code==0,seed.stderr)
 schema.toggle(c.url)
 local win=schema.get_winid();local buf=vim.api.nvim_win_get_buf(win);local oldstate=schema.get_state(c.url)
 for i,n in ipairs(oldstate.nodes)do if n.kind=='table'and n.name=='old_table'then vim.api.nvim_win_set_cursor(win,{i+2,0})break end end
 local original=db.get_column_info;local switched=false
 db.get_column_info=function(name,url)
  local cols,err=original(name,url)
  if url==c.url and not switched then
   switched=true;vim.b[buf].db=other -- controlled connection-rebind delivery seam
   schema.refresh(other)
  end
  return cols,err
 end
 local ok,err=pcall(H.key,buf,'l');db.get_column_info=original
 local lines=table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')
 schema.close();schema._reset_state()
 assert(ok,err);assert(switched,'native column query hook never ran')
 assert(lines:find('new_table',1,true) and not lines:find('old_table',1,true),lines)
end)

H.finish('reliability_adversarial_schema_lifecycle_spec')
