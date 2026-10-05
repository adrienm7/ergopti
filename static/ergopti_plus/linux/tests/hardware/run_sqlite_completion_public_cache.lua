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
local K=require("modules.keylogger.keylogger")
local W=require("modules.keylogger.sqlite_writer")
K.init({sqlite_path=root.."/metrics.sqlite",log_dir=root.."/logs"})
assert(K.is_enabled() and W.is_available())
K.record_synthetic_output("owned-cache","abc","llm",1000); K.flush()
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
local function payload() return K.get_dashboard_payload({include_prefetch=false}).metrics_manifest end
local function cell(manifest) return manifest[date] and manifest[date][app] or {} end
local checks, failures=0,0
for _,tbl in ipairs({"agg_app_day","agg_app_day_errors","agg_app_day_session"}) do
 oracle(); K.clear_cache()
 assert(W.exec_sql("ALTER TABLE "..tbl.." RENAME TO owned_hidden;"))
 local partial=cell(payload())
 assert(W.exec_sql("ALTER TABLE owned_hidden RENAME TO "..tbl..";"))
 local recovered=cell(payload())
 oracle(); assert(W.get_revision()==revision)
 print(string.format("OBSERVED %s partial=%s,%s,%s recovered=%s,%s,%s revision=%s",tbl,tostring(partial.llm_chars),tostring(partial.bs_total),tostring(partial.session_count_total),tostring(recovered.llm_chars),tostring(recovered.bs_total),tostring(recovered.session_count_total),tostring(revision)))
 checks=checks+1
 local ok,err=xpcall(function()
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
