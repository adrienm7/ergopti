--- tests/hardware/run_sqlite_raw_coherence.lua
--- ==============================================================================
--- MODULE: Native SQLite Raw Batch Coherence Producer (Linux)
--- DESCRIPTION:
--- Public software typing and genuine wall clocks produce owned SQLite snapshots.
--- The sibling Python runner checks them independently. Supplied software event
--- timestamps do not replace host time or represent physical keyboard input.
--- ==============================================================================

-- Actual public software typing, current clock/libc and real SQLite snapshots.
-- Independent oracle reads SQLite directly; no process/SQL/provider/clock doubles.
local uv = require('luv')
require('compat.utf8').install()
local Json = require('json')
local original_date, original_time, original_clock = os.date, os.time, os.clock
local root = assert(os.getenv('OWN_RAW_COHERENCE_ROOT'))
assert(uv.fs_mkdir(root,448))
for _,name in ipairs({'CONFIG','DATA','CACHE','STATE'}) do
 assert(uv.os_setenv('XDG_'..name..'_HOME',root..'/'..name:lower()))
end
assert(uv.fs_mkdir(root..'/config',448))
assert(uv.fs_mkdir(root..'/config/ergopti',448))
local config = assert(io.open(root..'/config/ergopti/config.toml','w'))
assert(config:write('[metrics]\nenabled = true\n') and config:close())
local K = require('modules.keylogger.keylogger')
local W = require('modules.keylogger.sqlite_writer')
local local_day,utc_day = os.date('%Y-%m-%d'),os.date('!%Y-%m-%d')
assert(local_day~=utc_day,'test OWN-24 must produce a distinct actual local day')
K.init({sqlite_path=root..'/metrics.sqlite',log_dir=root..'/logs'})
assert(K.is_enabled() and W.is_available())
assert(W.exec_sql("CREATE TRIGGER owned_partial AFTER INSERT ON events_typing WHEN (SELECT COUNT(*) FROM events_typing)=2 BEGIN SELECT RAISE(FAIL,'owned late refusal'); END;"))
K.on_keydown('a',1000,'owned-rate-a')
K.on_keydown('b',2300,'owned-rate-a')
K.on_keydown('c',3300,'owned-rate-b')
K.on_keydown('d',4600,'owned-rate-b')
local bounds = {}
bounds.refused_before=os.date('!%Y-%m-%d %H:%M:%S')
K.flush()
bounds.refused_after=os.date('!%Y-%m-%d %H:%M:%S')
local pending_refused=K._pending_buffer_count_for_test()
assert(W.exec_sql("VACUUM INTO '"..root.."/refused.sqlite';"))
assert(W.exec_sql('DROP TRIGGER owned_partial;'))
bounds.accepted_before=os.date('!%Y-%m-%d %H:%M:%S')
K.flush()
bounds.accepted_after=os.date('!%Y-%m-%d %H:%M:%S')
local pending_accepted=K._pending_buffer_count_for_test()
assert(W.exec_sql("VACUUM INTO '"..root.."/accepted.sqlite';"))
K.flush()
assert(W.exec_sql("VACUUM INTO '"..root.."/repeat.sqlite';"))
assert(os.date==original_date and os.time==original_time and os.clock==original_clock,'clock identity changed')
assert(os.date('%Y-%m-%d')==local_day and os.date('!%Y-%m-%d')==utc_day,'genuine calendar-day crossing invalidates setup')
W.close_db()
print(Json.encode({root=root,local_day=local_day,utc_day=utc_day,bounds=bounds,pending_refused=pending_refused,pending_accepted=pending_accepted,clock_unchanged=true}))
