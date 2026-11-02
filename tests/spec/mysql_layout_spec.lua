local ok,layout=pcall(require,'dadbod-grip.mysql_layout')
if not ok then print('mysql_layout_spec: 0 passed, 1 failed (layout witness absent)');os.exit(1) end
local pass,fail=0,0
local function test(name,fn) local good,e=xpcall(fn,debug.traceback);if good then pass=pass+1 else fail=fail+1;print('FAIL: '..name..': '..tostring(e)) end end
local function names(ddl) local n,e=layout.names(ddl);assert(n,e);return n end
test('native quoted declarations preserve order, Unicode, dots and doubled quotes',function()
 local n=names('CREATE TABLE `a.b λ` (`i``d` bigint,`space col` text,`λ.x` text,PRIMARY KEY (`i``d`)) ENGINE=InnoDB')
 assert(vim.deep_equal(n,{'i`d','space col','λ.x'}))
 assert(vim.deep_equal(names('CREATE TABLE "t" ("a""b" int)'),{'a"b'}))
end)
test('nested expressions, literal commas/parentheses and versioned invisible markers do not invent columns',function()
 local n=names([[CREATE TABLE "t" (
 "id" int NOT NULL, "v" enum('a,b','c)(') DEFAULT 'a,b',
 "g" int GENERATED ALWAYS AS ((if("id">0,1,2))) STORED,
 "hidden" text /*!80023 INVISIBLE */ COMMENT 'a''b,(x)',
 PRIMARY KEY ("id"), UNIQUE KEY "u" ("v"), KEY "k" ("g"),
 FULLTEXT KEY "f" ("hidden"), SPATIAL INDEX "s" ("v"),
 CONSTRAINT "fk" FOREIGN KEY ("id") REFERENCES "other" ("id"),
 CONSTRAINT "ck" CHECK (("id" > 0))) ENGINE=InnoDB]])
 assert(vim.deep_equal(n,{'id','v','g','hidden'}))
 assert(vim.deep_equal(names('CREATE TABLE "t" ("hidden" text /*M!110000 INVISIBLE */)'),{'hidden'}))
end)
test('client batch escaping decodes only the known SHOW CREATE field contract',function()
 assert(layout.batch_decode('a\\n\\t\\r\\0\\b\\Z\\\\')=='a\n\t\r\0\b\26\\')
 assert(not layout.batch_decode('bad\\q'));assert(not layout.batch_decode('bad\\'))
end)
for _,ddl in ipairs({
 'CREATE VIEW "t" AS SELECT 1','CREATE TABLE t ("id" int)','CREATE TABLE "t" (id int)',
 'CREATE TABLE "t" ("id" int, MAGIC THING ("id"))','CREATE TABLE "t" ("id" int,)',
 'CREATE TABLE "t" ("id" int, "ID" int)','CREATE TABLE "t" ("id" text DEFAULT \'bad)',
 'CREATE TABLE "t" ("id" int /* bad)','CREATE TABLE "t" ("id" int /* a /* b */ */)',
 'CREATE TABLE "t" (/*!80023 "id" int */)','CREATE TABLE "t" ("id" int); DROP TABLE "t"',
 'CREATE TABLE "t" ()','CREATE TABLE "t" ("bad\nname" int)','CREATE TABLE "t" ("bad\\name" int)',
 'CREATE TABLE "t" ("id" int /*!80023 ,"hidden" text */)',
 'CREATE TABLE "t" ("id" int /*M!110000 ,"hidden" text */)',
 'CREATE TABLE "t" ("id" int /*m!110000 ,"hidden" text */)',
}) do test('ambiguous/unproved layout refuses: '..ddl,function() assert(not layout.names(ddl)) end) end
test('full layout comparison refuses filtered trailing and invisible source prefixes',function()
 local n=names('CREATE TABLE "t" ("id" int,"hidden" text INVISIBLE)')
 assert(not layout.matches(n,{{column_name='id'}}));assert(layout.matches(n,{{column_name='id'},{column_name='hidden'}}))
 assert(not layout.matches(n,{{column_name='hidden'},{column_name='id'}}))
end)
test('visibility profiles require native quoting/mode and nonhidden generated SQL columns',function()
 local mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES'
 assert(layout.profile('8.4.11','MySQL Community Server - GPL','1',mode,'ON'))
 assert(layout.profile('11.8.9-MariaDB','MariaDB Server','1',mode,nil))
 assert(layout.profile('8.0.29','MySQL Community Server - GPL','1',mode,nil))
 assert(layout.profile('8.4.11','MySQL Community Server - GPL','1',mode,'OFF')==false)
 assert(layout.profile('8.4.11','MySQL Community Server - GPL','0',mode,'ON')==false)
 assert(layout.profile('8.4.11','MySQL Community Server - GPL','1',mode,nil)==nil)
 assert(layout.profile('8.0.30','MySQL Community Server - GPL','1',mode,nil)==nil)
 assert(layout.profile('8.4.11','Unknown Server','1',mode,'ON')==nil)
 assert(layout.profile('8.4.11','MySQL Community Server - GPL','1','ANSI_QUOTES','ON')==nil)
 assert(layout.profile('8.4.11','MySQL Community Server - GPL','1',mode..',STRICT_TRANS_TABLES','ON')==nil)
end)
test('Maria native system-boolean ON/OFF representation is normalized only in the quote capability field',function()
 local mode='ANSI_QUOTES,NO_BACKSLASH_ESCAPES'
 local p=layout.profile('11.8.9-MariaDB','mariadb.org binary distribution','ON',mode,nil)
 assert(p and p[3]=='1')
 assert(layout.profile('11.8.9-MariaDB','mariadb.org binary distribution','OFF',mode,nil)==false)
end)
print(('mysql_layout_spec: %d passed, %d failed'):format(pass,fail));if fail>0 then os.exit(1) end
