--- tests/hardware/run_sqlite_ngram_extra_sources.lua
--- ==============================================================================
--- MODULE: Native SQLite Additional Synthetic Sources (Linux)
--- DESCRIPTION:
--- Public Reader projections retain accepted source labels and system controls.
--- Owned SQLite software data only; no physical or foreign runtime claims.
--- ==============================================================================

-- Bounded native public Reader source audit using accepted production Writer data.
local uv=require("luv")
require("compat.utf8").install()
local Json=require("json")
local root=assert(uv.fs_mkdtemp("/tmp/ergopti-source-reader-XXXXXX"))
local W=require("modules.keylogger.sqlite_writer")
local R=require("modules.keylogger.sqlite_reader")
local db=root.."/metrics.sqlite"
assert(W.open_db(db) and W.is_available())
local checks,failures=0,0
local function check(name,fn)
 checks=checks+1
 local ok,err=xpcall(fn,debug.traceback)
 if ok then print("PASS "..name) else failures=failures+1;io.stderr:write("FAIL "..name..": "..tostring(err).."\n") end
end
check("healthy empty public ngram scaffold",function()
 local out=R.read_ngrams(db,"2026-10-01","2026-10-02")
 assert(type(out.c)=="table" and next(out.c)==nil and type(out.sc_kb)=="table")
end)
assert(W.upsert_ngrams("owned-a","2026-10-01","owned-app",{known={c=10,td=35,cd=5,e=2,sources={hotstring=1,llm=2,other=3,none=4}}}))
check("known source counts and manual none exclusion remain healthy",function()
 local v=R.read_ngrams(db,"2026-10-01","2026-10-01",{"owned-app"}).c.known
 assert(v.c==10 and v.t==35 and v.e==2 and v.hs==1 and v.llm==2 and v.o==3)
end)
local row={c=20,td=45,cd=4,e=3,sources={hotstring=1,llm=3,other=2,none=9,["case-transform"]=4,["owned-extension"]=1}}
assert(W.upsert_ngrams("owned-a","2026-10-01","owned-app",{custom=row}))
assert(W.upsert_ngrams("owned-b","2026-10-01","owned-app",{custom=row}))
local literal=assert(W.query_rows("SELECT SUM(c),SUM(td),SUM(e),SUM((SELECT SUM(value) FROM json_each(esrc_json) WHERE key NOT IN ('hotstring','llm','none'))) FROM ngram_chars WHERE token='custom';"))[1]
assert(literal=="40|90|6|14","independent native literal source/numeric oracle")
print("SQL_ORACLE "..literal)
check("unrecognized valid synthetic sources join other across identical device blobs",function()
 local v=R.read_ngrams(db,"2026-10-01","2026-10-01",{"owned-app"}).c.custom
 print("OBSERVED custom",v.c,v.t,v.e,v.hs,v.llm,v.o)
 assert(v.c==40 and v.t==90 and v.e==6 and v.hs==2 and v.llm==6 and v.o==14)
end)
check("date and app filters preserve source omission and healthy selected values",function()
 assert(next(R.read_ngrams(db,"2026-10-02","2026-10-02",{"owned-app"}).c)==nil)
 assert(next(R.read_ngrams(db,"2026-10-01","2026-10-01",{"absent"}).c)==nil)
 assert(R.read_ngrams(db,"2026-10-01","2026-10-01",{}).c.known.c==10)
end)
assert(W.upsert_system_day("owned-a",{date="2026-10-01",wifi_changes=2,space_switches=3,battery_sum=140,battery_count=2,battery_min=60,battery_max=80,sleep_ms=1000,awake_ms=4000}))
assert(W.upsert_system_day("owned-b",{date="2026-10-01",wifi_changes=1,space_switches=4,battery_sum=40,battery_count=1,battery_min=40,battery_max=40,sleep_ms=2000,awake_ms=5000}))
check("system sums and battery bounds aggregate independent devices",function()
 local v=R.read_system_days(db,"2026-10-01","2026-10-01")["2026-10-01"]
 assert(v.wifi_changes==3 and v.space_switches==7 and v.battery_sum==180 and v.battery_count==3)
 assert(v.battery_min==40 and v.battery_max==80 and v.sleep_ms==3000 and v.awake_ms==9000)
end)
assert(W.upsert_system_day("owned-a",{date="2026-10-02",wifi_changes=0}))
check("nullable system battery and date filters preserve unknown vs zero",function()
 local v=R.read_system_days(db,"2026-10-02","2026-10-02")["2026-10-02"]
 assert(v.battery_sum==0 and v.battery_count==0 and v.battery_min==nil and v.battery_max==nil)
 assert(next(R.read_system_days(db,"2026-10-03","2026-10-03"))==nil)
end)
assert(checks==6,"all six bounded native Reader subjects must execute")
W.close_db()
local function remove_owned(path)
 local st=assert(uv.fs_lstat(path))
 if st.type=="directory" then for name in uv.fs_scandir_next,assert(uv.fs_scandir(path)) do remove_owned(path.."/"..name) end;assert(uv.fs_rmdir(path)) else assert(uv.fs_unlink(path)) end
end
remove_owned(root)
print(string.format("Native Reader sources/system boundary: %d checks, %d failures",checks,failures))
os.exit(failures==0 and 0 or 1)
