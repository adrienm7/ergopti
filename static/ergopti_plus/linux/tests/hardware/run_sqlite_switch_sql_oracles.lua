--- tests/hardware/run_sqlite_switch_sql_oracles.lua
--- ==============================================================================
--- MODULE: Native SQLite Directed Switch SQL Oracles (Linux)
--- DESCRIPTION:
--- Actual public Writer and Reader calls preserve grouped counts, typed zeros and filters.
--- Independent SQLite results and owned files exercise software metadata without hardware.
--- ==============================================================================

-- Independent genuine SQLite grouping/filter/zero oracle. No input hardware.
local uv=require("luv")
local root=assert(uv.fs_mkdtemp("/tmp/ergopti-switch-sql-XXXXXX"))
for _,name in ipairs({"CONFIG","DATA","CACHE","STATE"}) do assert(uv.os_setenv("XDG_"..name.."_HOME",root.."/"..name:lower())) end
local W=require("modules.keylogger.sqlite_writer")
local R=require("modules.keylogger.sqlite_reader")
local J=require("json")
local db=root.."/metrics.sqlite"
local source,dest,zero="owned café' source","owned destination","owned zero"
assert(W.open_db(db))
for _,device in ipairs({"device-one","device-two"}) do assert(W.register_device(device,device,"linux","","")) end
local rows={
 {device="device-one",date="1999-12-31",app_from=source,app_to=dest,count=2},
 {device="device-two",date="1999-12-31",app_from=source,app_to=dest,count=4},
 {device="device-one",date="1999-12-31",app_from=dest,app_to=source,count=1},
 {device="device-two",date="2000-01-01",app_from=source,app_to=zero,count=0},
}
for _,row in ipairs(rows) do local before=J.encode(row); assert(W.upsert_switch_to(row.device,row)); assert(J.encode(row)==before) end
assert(W.upsert_app_day("device-one","1999-12-31","owned-control",{chars=7}))
local function sql(q,expected) local actual=assert(W.query_rows(q)); assert(#actual==1 and actual[1]==expected,"independent native SQL oracle: "..tostring(actual[1])); print("SQL ORACLE "..actual[1]) end
sql("SELECT SUM(count),COUNT(*) FROM agg_app_day_switches_to WHERE date='1999-12-31' AND app_from='owned café'' source';","6|2")
sql("SELECT SUM(count),COUNT(*) FROM agg_app_day_switches_to WHERE date='1999-12-31' AND app_from='owned destination';","1|1")
sql("SELECT SUM(count),COUNT(*),typeof(SUM(count)) FROM agg_app_day_switches_to WHERE date='2000-01-01';","0|1|integer")
local before=table.concat(assert(W.query_rows("SELECT hex(device_id),date,hex(app_from),hex(app_to),count FROM agg_app_day_switches_to ORDER BY device_id,date,app_from,app_to;")),"\n")
local checks,failures=0,0
local function check(name,f) checks=checks+1; local ok,err=xpcall(f,debug.traceback); if ok then print("PASS "..name) else failures=failures+1; io.stderr:write("FAIL "..name..": "..err.."\n") end end
local function cell(m,d,a) return m[d] and m[d][a] or {} end
local function count(m,d,a,b) return (cell(m,d,a).switches_to or {})[b] end
check("independent SQL directed grouping",function()
 local m,ok=R.read_manifest(db,"1999-12-31","1999-12-31")
 assert(ok==true and count(m,"1999-12-31",source,dest)==6 and count(m,"1999-12-31",dest,source)==1)
 assert(m["2000-01-01"]==nil)
end)
check("quoted UTF8 source filtering keeps outside destination",function()
 local apps={source}; local old=J.encode(apps)
 local m,ok=R.read_manifest(db,"1999-12-31","2000-01-01",apps)
 assert(ok==true and count(m,"1999-12-31",source,dest)==6)
 assert(m["1999-12-31"][dest]==nil and m["1999-12-31"]["owned-control"]==nil and J.encode(apps)==old)
end)
check("literal SQL zero remains a typed directed count",function()
 local m,ok=R.read_manifest(db,"2000-01-01","2000-01-01",{source})
 assert(ok==true and count(m,"2000-01-01",source,zero)==0)
 assert(type(count(m,"2000-01-01",source,zero))=="number")
end)
check("ordinary optional-map zero defaults remain healthy",function()
 local m,ok=R.read_manifest(db,"1999-12-31","2000-01-01")
 assert(ok==true and cell(m,"1999-12-31","owned-control").chars==7)
 assert(cell(m,"1999-12-31","owned-control").switches_to==nil and cell(m,"2000-01-01",zero).switches_to==nil)
end)
check("inverted dates and independent aggregate bytes remain healthy",function()
 local m,ok=R.read_manifest(db,"2000-01-01","1999-12-31")
 assert(ok==true and next(m)==nil)
 assert(table.concat(assert(W.query_rows("SELECT hex(device_id),date,hex(app_from),hex(app_to),count FROM agg_app_day_switches_to ORDER BY device_id,date,app_from,app_to;")),"\n")==before)
end)
assert(checks==5,"independent SQL subjects floor")
W.close_db()
local function remove_owned(p) local s=assert(uv.fs_lstat(p)); if s.type=="directory" then for n in uv.fs_scandir_next,assert(uv.fs_scandir(p)) do remove_owned(p.."/"..n) end; assert(uv.fs_rmdir(p)) else assert(uv.fs_unlink(p)) end end
remove_owned(root)
print(string.format("Independent native SQLite switches: %d checks, %d failures",checks,failures)); os.exit(failures==0 and 0 or 1)
