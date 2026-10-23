--- tests/hardware/run_sqlite_completion_public_cache.lua
--- ==============================================================================
--- MODULE: Native SQLite Manifest Completion Public Cache (Linux)
--- DESCRIPTION:
--- Public software output and independent SQL values expose same-revision cache loss.
--- Owned schema obstructions exercise native refusal and recovery without hardware.
--- ==============================================================================

-- Independent real-SQLite public cache proof. Software output only.
local uv=require("luv")
require("compat.utf8").install()
local root=assert(uv.fs_mkdtemp("/tmp/ergopti-cache-independent-XXXXXX"))
for _, name in ipairs({"CONFIG","DATA","CACHE","STATE"}) do assert(uv.os_setenv("XDG_"..name.."_HOME",root.."/"..name:lower())) end
assert(uv.fs_mkdir(root.."/config",448)); assert(uv.fs_mkdir(root.."/config/ergopti",448))
local config=assert(io.open(root.."/config/ergopti/config.toml","w")); assert(config:write("[metrics]\nenabled = true\n") and config:close())
local K=require("modules.keystats.keystats")
local W=require("modules.keystats.sqlite_writer")
K.init({sqlite_path=root.."/metrics.sqlite",log_dir=root.."/logs"})
assert(K.is_enabled() and W.is_available())
K.record_synthetic_output("owned-cache","abc","llm",1000); require("tests.support.sqlite_flush_native").flush(K)
local date=assert(W.query_rows("SELECT date FROM agg_app_day;"))[1]
local app=assert(W.query_rows("SELECT app FROM agg_app_day;"))[1]
assert(W.upsert_errors("owned-extra",{date=date,app=app,bs_total=7}))
assert(W.upsert_session("owned-extra",{date=date,app=app,count_total=2,durations={4,5}}))
local revision=assert(W.get_revision())
local function oracle()
 local rows=assert(W.query_rows("SELECT llm_chars,llm_triggers FROM agg_app_day;"))
 assert(#rows==1 and rows[1]=="3|1", "independent native software-output SQL oracle")
 assert(assert(W.query_rows("SELECT SUM(bs_total) FROM agg_app_day_errors;"))[1]=="7")
 assert(assert(W.query_rows("SELECT SUM(count_total) FROM agg_app_day_session;"))[1]=="2")
end
local function payload()
 local result,reason=K.get_dashboard_payload({include_prefetch=false})
 assert(type(result)=="table" and reason==nil,"healthy public cache must acknowledge its dashboard payload")
 assert(type(result.metrics_manifest)=="table","healthy public cache must retain its manifest")
 return result.metrics_manifest
end
local function cell(manifest) return manifest[date] and manifest[date][app] or {} end
local checks, failures=0,0
for _,tbl in ipairs({"agg_app_day","agg_app_day_errors","agg_app_day_session"}) do
 oracle(); K.clear_cache()
 assert(W.exec_sql("ALTER TABLE "..tbl.." RENAME TO owned_hidden;"))
 local result,reason=K.get_dashboard_payload({include_prefetch=false})
 local partial=type(result)=="table" and type(result.metrics_manifest)=="table" and cell(result.metrics_manifest) or nil
 assert(W.exec_sql("ALTER TABLE owned_hidden RENAME TO "..tbl..";"))
 local recovered=cell(payload())
 oracle(); assert(W.get_revision()==revision)
 print(string.format("OBSERVED %s public_refused=%s recovered=%s,%s,%s revision=%s",tbl,tostring(result==nil),tostring(recovered.llm_chars),tostring(recovered.bs_total),tostring(recovered.session_count_total),tostring(revision)))
 checks=checks+1
 local ok,err=xpcall(function()
  if tbl=="agg_app_day" then
   assert(result==nil and reason=="SQLite projection unavailable","unreadable categories must refuse the complete public dashboard")
  else
   assert(type(result)=="table" and reason==nil and partial~=nil,"derived refusal must preserve the independently available partial manifest")
   assert(partial.llm_chars==3,"derived refusal lost the independently stored software chars")
   if tbl=="agg_app_day_errors" then
    assert(partial.bs_total==nil and partial.session_count_total==2,"partial manifest misreported the refused error source")
   else
    assert(partial.bs_total==7 and partial.session_count_total==nil,"partial manifest misreported the refused session source")
   end
  end
  assert(recovered.llm_chars==3,"same-revision public cache omitted accepted software chars")
  assert(recovered.bs_total==7,"same-revision public cache omitted SQL-proven error data")
  assert(recovered.session_count_total==2,"same-revision public cache omitted SQL-proven session data")
 end,debug.traceback)
 if ok then print("PASS independent public cache "..tbl) else failures=failures+1; io.stderr:write("FAIL independent public cache "..tbl..": "..err.."\n") end
end
assert(checks==3,"independent public cache subject floor")
W.close_db()
local function remove_owned(p)
 local st=assert(uv.fs_lstat(p))
 if st.type=="directory" then for n in uv.fs_scandir_next,assert(uv.fs_scandir(p)) do remove_owned(p.."/"..n) end; assert(uv.fs_rmdir(p)) else assert(uv.fs_unlink(p)) end
end
remove_owned(root)
print(string.format("Independent public SQLite completion cache: %d checks, %d failures",checks,failures))
os.exit(failures==0 and 0 or 1)
