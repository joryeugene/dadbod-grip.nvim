-- Native metadata exposure only; this does NOT claim a source lock/binding.
local url=vim.env.GRIP_SAFETY_URL
if not url or require('dadbod-grip.adapters').kind(url)~='mysql' then print('mysql_source_metadata_spec: SKIPPED (assigned fixture required)');return end
local db,sql=require('dadbod-grip.db'),require('dadbod-grip.sql')
local parsed=assert(sql.parse_dadbod_url(url));assert(parsed.dbname=='grip_safety_core','unassigned fixture')
local name='grip_metadata_guard_'..vim.fn.getpid()
assert(db.execute('CREATE TABLE '..name.."(id INTEGER PRIMARY KEY,hidden VARCHAR(20) INVISIBLE,bytes VARBINARY(16),g INTEGER GENERATED ALWAYS AS(id+1) STORED)",url))
local ok,e=xpcall(function()
 local columns,err=db.get_column_info(name,url);assert(columns,err);assert(#columns==4,'invisible column globally filtered')
 for i,col in ipairs(columns) do
  assert(col.ordinal==i and col.ordinal_position==i,'native ordinal missing')
  assert(col.extra~=nil and col.column_type~=nil and col.metadata_source=='source_schema','full native metadata missing')
  assert(col.source_schema==parsed.dbname and col.source_table==name,'native source identity missing')
  assert(col.visible==(i~=2),'visibility missing or guessed')
 end
 assert(columns[2].extra:find('INVISIBLE',1,true));assert(columns[4].generated==true and columns[4].generation_expression~='')
 local r,query_error=db.query('SELECT * FROM '..name,url);assert(r,query_error);assert(#r.columns==3 and r.columns[2]=='bytes','actual visible projection differs')
end,debug.traceback)
assert(db.execute('DROP TABLE '..name,url))
if not ok then print('FAIL: '..e);print('mysql_source_metadata_spec: 0 passed, 1 failed');os.exit(1) end
print('mysql_source_metadata_spec: 1 passed, 0 failed')
