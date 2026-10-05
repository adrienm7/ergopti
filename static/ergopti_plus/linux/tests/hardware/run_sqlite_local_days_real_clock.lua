--- tests/hardware/run_sqlite_local_days_real_clock.lua
--- ==============================================================================
--- MODULE: Native SQLite Local Event Days with the Genuine Clock
--- DESCRIPTION:
--- Validates software public APIs with the real clock and owned SQLite.
--- Start only this process with POSIX TZ=OWN-24; no physical input is exercised.
--- ==============================================================================

-- Actual current clock and libc timezone conversion; process starts with TZ=OWN-24.
-- Software public APIs, real owned SQLite, no clock/process/SQL/provider replacement.
local uv = require('luv')
require('compat.utf8').install()
local original_date, original_time = os.date, os.time
local root = assert(uv.fs_mkdtemp('/tmp/ergopti-real-local-days-XXXXXX'))
for _, name in ipairs({'CONFIG','DATA','CACHE','STATE'}) do
  assert(uv.os_setenv('XDG_'..name..'_HOME',root..'/'..name:lower()))
end
assert(uv.fs_mkdir(root..'/config',448))
assert(uv.fs_mkdir(root..'/config/ergopti',448))
local config = assert(io.open(root..'/config/ergopti/config.toml','w'))
assert(config:write('[metrics]\nenabled = true\n') and config:close())
local K = require('modules.keylogger.keylogger')
local W = require('modules.keylogger.sqlite_writer')
local R = require('modules.keylogger.sqlite_reader')
local Json = require('json')
local path, local_day, utc_day = root..'/metrics.sqlite',os.date('%Y-%m-%d'),os.date('!%Y-%m-%d')
assert(local_day ~= utc_day,'OWN-24 must produce a distinct real local calendar day')
print('real TZ='..tostring(os.getenv('TZ'))..'; local='..os.date('%Y-%m-%d %H:%M:%S')..'; UTC='..os.date('!%Y-%m-%d %H:%M:%S'))
K.init({sqlite_path=path,log_dir=root..'/logs'})
assert(K.is_enabled() and W.is_available())
local checks, failures = 0,0
local function check(name, fn)
  checks=checks+1
  local ok,err=xpcall(fn,debug.traceback)
  if ok then print('PASS '..name) else failures=failures+1; io.stderr:write('FAIL '..name..': '..tostring(err)..'\n') end
end
local begin_ts=os.date('!%Y-%m-%d %H:%M:%S')
K.record_hotstring('owned-real-day','q','abc',1000,'static',0,false)
K.record_shortcut('owned-real-day','owned-action',1000)
K.flush()
local end_ts=os.date('!%Y-%m-%d %H:%M:%S')
for _,table_name in ipairs({'events_typing','events_hotstring','events_shortcut'}) do
  check('actual public '..table_name..' uses local day and retains UTC timestamp',function()
    local rows=assert(W.query_rows('SELECT date,ts FROM '..table_name..';'))
    assert(#rows==1)
    local day,ts=rows[1]:match('^([^|]+)|(.+)$')
    print(table_name..'='..rows[1])
    assert(day==local_day and ts>=begin_ts and ts<=end_ts)
  end)
end
check('actual Reader and public dashboard retain local daily synthetic totals',function()
  local manifest=R.read_manifest(path)
  local public=K.get_dashboard_payload({include_prefetch=false}).metrics_manifest
  assert(manifest[local_day]['owned-real-day'].hs_chars==3)
  assert(public[local_day]['owned-real-day'].hs_chars==3)
end)
assert(W.register_device('owned-real-defaults','owned-real-defaults','linux','',''))
local families={
  {'events_typing','insert_typing_events',{app='owned-real-defaults',text='owned',events_json='[]',wpm=12}},
  {'events_hotstring','insert_hotstring_events',{app='owned-real-defaults',trigger='owned',replacement='owned'}},
  {'events_shortcut','insert_shortcut_events',{app='owned-real-defaults',key='owned'}},
  {'events_app_switch','insert_app_switch_events',{prev_app='owned-real-defaults',next_app='owned-next'}},
}
for _,family in ipairs(families) do
  for _,explicit in ipairs({false,true}) do
    local event=family[3]
    if explicit then event.date,event.ts='1999-12-31','1999-12-31 23:59:59' end
    local before=Json.encode(event)
    local before_ts=os.date('!%Y-%m-%d %H:%M:%S')
    assert(W[family[2]]('owned-real-defaults',{event}))
    local after_ts=os.date('!%Y-%m-%d %H:%M:%S')
    check(family[2]..(explicit and ' preserves explicit historical bytes' or ' defaults to real local day'),function()
      local rows=assert(W.query_rows("SELECT date,ts FROM "..family[1].." WHERE device_id='owned-real-defaults' ORDER BY id DESC LIMIT 1;"))
      assert(#rows==1 and Json.encode(event)==before)
      local day,ts=rows[1]:match('^([^|]+)|(.+)$')
      print(family[1]..(explicit and ':explicit=' or ':default=')..rows[1])
      assert(day==(explicit and event.date or local_day))
      assert(explicit and ts==event.ts or not explicit and ts>=before_ts and ts<=after_ts)
    end)
  end
end
local function packed()
  return table.concat(assert(W.query_rows('SELECT id,date,ts FROM events_typing UNION ALL SELECT id,date,ts FROM events_hotstring UNION ALL SELECT id,date,ts FROM events_shortcut UNION ALL SELECT id,date,ts FROM events_app_switch ORDER BY id;')),'\n')
end
local durable=packed()
K.flush()
check('second public flush preserves accepted raw bytes and duplicate-free IDs',function()
  assert(packed()==durable)
  assert(W.query_rows('SELECT COUNT(*),COUNT(DISTINCT id) FROM (SELECT id FROM events_typing UNION ALL SELECT id FROM events_hotstring UNION ALL SELECT id FROM events_shortcut UNION ALL SELECT id FROM events_app_switch);')[1]=='11|11')
end)
assert(os.date==original_date and os.time==original_time,'no wall-clock function replacement')
assert(os.date('%Y-%m-%d')==local_day and os.date('!%Y-%m-%d')==utc_day,'real clock crossed calendar day; setup invalid')
W.close_db()
local function remove_owned(path)
  local stat=assert(uv.fs_lstat(path))
  if stat.type=='directory' then
    for name in uv.fs_scandir_next,assert(uv.fs_scandir(path)) do remove_owned(path..'/'..name) end
    assert(uv.fs_rmdir(path))
  else assert(uv.fs_unlink(path)) end
end
remove_owned(root)
assert(checks == 13, "all 13 local-day checks must execute")
print(string.format('Actual clock native local event days: %d checks, %d failures',checks,failures))
os.exit(failures==0 and 0 or 1)
