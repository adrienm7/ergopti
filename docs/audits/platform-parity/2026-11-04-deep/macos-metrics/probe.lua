local root = '/workspace/ergopti/static/ergopti_plus/'
package.path = root .. 'macos/?.lua;' .. root .. '_shared/lua/?.lua;' .. package.path
local function noop() end
package.loaded['infra.logger'] = setmetatable({}, {__index=function() return noop end})
package.loaded['infra.timings'] = {ms=function() return 999999 end}
package.loaded['adapters.task_lifecycle'] = {native=function() return nil end}
package.loaded['adapters.timer_scheduler'] = {after=function() return {timer=nil},true end,cancel=function() return true end}
local state = {is_enabled=true,collection_suspended=false,mouse_distance_px=0,
 current_battery_level=90, active_app_name='Editor',active_app_start=0}
local now, events, space_cb = 1000, {}, nil
local function append(e) e.timestamp='2026-11-04 12:00:00.000'; events[#events+1]=e end
package.loaded['modules.keystats.log_manager'] = {
 log_system_event=function(action,meta) local e={action=action}; for k,v in pairs(meta or {}) do e[k]=v end; append(e) end,
 log_passive_period=function(kind,duration) append({action='passive_period',kind=kind,duration_ms=duration}) end,
 log_app_switch=noop, flush_buffer=noop,
}
_G.hs = {timer={absoluteTime=function() return now*1000000 end},
 mouse={absolutePosition=function() return {x=now,y=0} end},
 caffeinate={watcher={systemWillSleep=1,screensDidSleep=2,systemDidWake=3,screensDidWake=4,screensDidLock=5,screensDidUnlock=6}},
 spaces={watcher={new=function(cb) space_cb=cb; local w={}; w.start=function() return w end; w.stop=function() return w end; return w end}}}
local watchers = require('modules.keystats.watchers')
assert(watchers.init(state,function() return false end))
assert(watchers.init_hardware_watchers())
assert(watchers.caffeinate_cb(1)); now=61000; assert(watchers.caffeinate_cb(3))
assert(watchers.caffeinate_cb(5)); now=91000; assert(watchers.caffeinate_cb(6))
package.loaded['modules.keystats.aggregator.state'] = {agg_batch={system_day={}}}
local S=package.loaded['modules.keystats.aggregator.state']
package.loaded['modules.keystats.aggregator.core'] = {require_init=function() return true end,ensure_batch=noop,
 gc=function(t,k,v) if not t[k] then t[k]=v end; return t[k] end}
package.loaded['modules.keystats.aggregator.physical'] = {}
package.loaded['keystats.walker'] = {}
local aggregator=require('modules.keystats.aggregator.events')
for _,entry in ipairs(events) do aggregator.walk_system_event(entry) end
local sys=S.agg_batch.system_day['2026-11-04']
assert(sys.sleep_ms==0 and sys.locked_ms==0 and sys.passive_count==2)
print('CONFIRMED: real watcher->real aggregator: 60000ms sleep + 30000ms lock yield sleep_ms='..sys.sleep_ms..', locked_ms='..sys.locked_ms..', passive_count='..sys.passive_count)
watchers.perform_maintenance() -- seed absolute pointer at 91000
state.collection_suspended=true
now=92000; watchers.perform_maintenance()
space_cb(42)
assert(state.mouse_distance_px==1000)
assert(events[#events].action=='space_change')
print('CONFIRMED: collection_suspended=true accumulates mouse_distance_px='..state.mouse_distance_px..' and appends '..events[#events].action)
-- Exercise exact unmodified snapshot functions from log_manager, with only dependencies injected.
local file=assert(io.open(root..'macos/modules/keystats/log_manager.lua')); local source=file:read('*a'); file:close()
local a=assert(source:find('local function _capture_typing_context',1,true))
local b=assert(source:find('local function _typing_entry_from_snapshot',a,true))
local chunk=source:sub(a,b-1)..'\nreturn _detach_buffer_snapshot()'
state.collection_suspended=false
state.buffer_events={{'a',0,{}}};state.buffer_text='a';state.rich_chunks={};state.session_mouse_clicks=0;state.session_mouse_scrolls=0
local snapshot=assert(load(chunk,'@log_manager_snapshot','t',{_state=state,Timestamp={now_epoch=function() return 1 end},hs=_G.hs,type=type}))()
assert(snapshot.mouse_distance_px==1000)
print('CONFIRMED: paused movement survives resume and is detached into next typing entry: '..snapshot.mouse_distance_px)
aggregator.walk_system_event({action='awake_focus',app='Editor',duration_ms=120000,timestamp='2026-11-04 12:02:00.000'})
assert(sys.awake_ms==0)
print('CONFIRMED: awake_focus(duration_ms=120000) leaves system awake_ms=0')
package.loaded['infra.i18n']={get=function(key) return key end}
package.loaded['adapters.secure_field_detector']={}
package.loaded['adapters.accessibility_permission']={frontmost_pid=function() return 42 end,is_askable=function() return true end,note_read=function() return false end}
local title='Ordinary page'
_G.hs.window={focusedWindow=function() return {title=function() return title end,isFullScreen=function() return false end} end}
_G.hs.axuielement={windowElement=function() return nil end}
local tracker=require('modules.keystats.context_tracker')
local captured={}
local context_state={active_app_name='Browser',private_filter_enabled=true,secure_field_filter_enabled=true,system_auth_filter_enabled=true}
assert(tracker.init(context_state,{append_log=function(e) captured[#captured+1]=e end},function() return false end))
now=100000; tracker.update_private_status()
now=102000; title='SECRET TITLE - Private Browsing'; tracker.update_private_status()
assert(context_state.is_private_window==true)
assert(require('modules.keystats.privacy_context').allows_logging(context_state)==false)
assert(captured[#captured].next_title==title)
print('CONFIRMED: private_filter_enabled=true and policy denied, but window_switch next_title='..captured[#captured].next_title)
context_state.collection_suspended=true
now=104000; title='PAUSED SECRET'; tracker.update_private_status()
assert(captured[#captured].next_title==title)
print('CONFIRMED: collection_suspended=true appends window_switch title='..captured[#captured].next_title)
-- Nested physical edge sequence uses the same exact live watchers, with fresh counters.
events={};state.passive_started_at=nil;state.passive_kind=nil
now=200000;assert(watchers.caffeinate_cb(5)) -- lock
now=201000;assert(watchers.caffeinate_cb(2)) -- display sleep
now=202000;assert(watchers.caffeinate_cb(1)) -- system sleep
now=203000;assert(watchers.caffeinate_cb(3)) -- system wake
now=204000;assert(watchers.caffeinate_cb(4)) -- display wake
now=205000;assert(watchers.caffeinate_cb(6)) -- unlock
local periods={};for _,e in ipairs(events) do if e.action=='passive_period' then periods[#periods+1]=e end end
assert(#periods==1 and periods[1].kind=='sleep' and periods[1].duration_ms==1000)
print('CONFIRMED: lock/display-sleep/system-sleep/system-wake/display-wake/unlock emits only one passive_period(kind=sleep,duration_ms=1000), losing lock and prior display-sleep ownership')
aggregator.walk_system_event({action='passive_period',kind='awake',duration_ms=120000,timestamp='2026-11-04 12:02:00.000'})
assert(sys.awake_ms==0)
print('CONFIRMED: full keep-awake pair (passive_period kind=awake + awake_focus) still leaves system awake_ms=0')
-- Follow real window events through the unmodified FIFO/public append body to its Rotation boundary.
local start=assert(source:find('local function _has_deferred_logs()',1,true))
local finish=assert(source:find('function M.defer_entry_builder(builder)',start,true))
local fifo_source='local _drain_deferred_logs\n'..source:sub(start,finish-1)..'\nreturn M'
local pending_callback, disk_boundary={},{}
local fifo_env=setmetatable({M={},_state=context_state,_deferred_log_head=1,_deferred_log_tail=0,_deferred_log_queue={},
 TimerScheduler={after=function(_,cb) pending_callback=cb;return {timer=nil,committed=true},true end},
 Rotation={append_log=function(e) disk_boundary[#disk_boundary+1]=e;return true end},
 Logger=package.loaded['infra.logger'],DEFERRED_LOG_RETRY_SEC=1}, {__index=_G})
local fifo=assert(load(fifo_source,'@log_manager_FIFO','t',fifo_env))()
fifo.append_log(captured[#captured]);pending_callback()
assert(disk_boundary[1].next_title=='PAUSED SECRET')
print('CONFIRMED: exact real LogManager.append_log + FIFO drain send PAUSED SECRET to Rotation.append_log; no downstream admission gate')
