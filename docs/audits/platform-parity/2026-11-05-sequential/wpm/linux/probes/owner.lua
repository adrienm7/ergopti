local root = '/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path = root..'linux/?.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
local log = {}
package.loaded['logger.shim'] = setmetatable({}, {__index=function(_, level) return function(...) log[#log+1]={level,...} end end})
require('compat.utf8').install()
local Preferences = require('tests.support.metrics_preferences_fixture').new({initial={['metrics.wpm_widget_graph']=false}})
package.loaded['infra.metrics_preferences'] = Preferences
local values = {}
package.loaded['adapters.storage']={get=function(k,d) return values[k] or d end,set_many=function(up,del) for k,v in pairs(up) do values[k]=v end; for _,k in ipairs(del or {}) do values[k]=nil end; return true end}
package.loaded['infra.i18n']={get=function() return 'WPM' end}
local native={visible=false, pending=0, paints=0,x=0,y=0,refuse=false,hide_calls=0}
local window=setmetatable({
get_screen=function() return {get_rgba_visual=function() end} end,
get_visible=function() return native.visible end,
show_all=function() native.visible=true end,
hide=function() native.hide_calls=native.hide_calls+1; native.visible=false end,
move=function(_,x,y) native.x,native.y=x,y end,
get_position=function() return native.x,native.y end,
resize=function() if native.refuse then if arg[1]=="throw" then error("private GTK redraw failure") end;return false end end,
queue_draw=function() native.pending=native.pending+1 end,
}, {__index=function() return function() end end})
local Surface=require('adapters.wpm_surface')
Surface._set_binding_for_test({Gtk={Window=function() return window end}, Gdk={EventMask={BUTTON_PRESS_MASK=1,BUTTON_RELEASE_MASK=2,POINTER_MOTION_MASK=4}, Display={get_default=function() return {get_primary_monitor=function() return {get_geometry=function() return {x=0,y=0,width=1920,height=1080} end} end} end}}})
Surface.pointer_position=function() return 0,0 end
local Indicator=require('platform.tray.appindicator')
local pumps=0
-- Faithful native-queue seam only: this does not represent a live display.
Indicator._set_binding_for_test({
ffi={cast=function(_,v) return v end},gobject={},
indicator={app_indicator_new=function() return {} end,app_indicator_set_status=function() end,app_indicator_set_title=function() end,app_indicator_set_menu=function() end},
gtk={gtk_menu_new=function() return {} end,gtk_widget_show_all=function() end,
gtk_events_pending=function() return native.pending>0 and 1 or 0 end,
gtk_main_iteration_do=function() pumps=pumps+1;native.pending=0;native.paints=native.paints+1 end},
})
local Widget=require('ui.wpm.widget')
local Tray=require('adapters.tray_menu')
assert(Widget.start())
assert(Widget.tick({wpm=42,source='none'},100))
assert(native.visible and native.pending==1)
for _=1,10 do Tray.pump() end
print('NO_TRAY show_ack='..tostring(native.visible)..' queued='..native.pending..' dispatched='..pumps)
assert(pumps==0 and native.pending==1)
Tray.setIcon({title='private test'}); assert(Tray.getBackend()=='appindicator')
Tray.pump()
print('STARTED_TRAY queued='..native.pending..' dispatched='..pumps)
assert(pumps==1 and native.pending==0)
-- Existing visible frame plus refused redraw: owner must still hide on idle.
native.refuse=true
Widget.tick({wpm=43,source='none'},101)
local snapshot=Widget.configuration_snapshot()
print('REFUSED_REDRAW native_visible='..tostring(native.visible)..' owner_shown='..tostring(snapshot.shown))
assert(native.visible and not snapshot.shown)
native.refuse=false
local hide_calls_before=native.hide_calls
Widget.tick({wpm=0,source='none'},1000)
print('IDLE_AFTER_REFUSAL native_visible='..tostring(native.visible)..' owner_shown='..tostring(Widget.configuration_snapshot().shown))
assert(native.visible and native.hide_calls==hide_calls_before)
print('IDLE_HIDE_CALLS delta='..(native.hide_calls-hide_calls_before))
assert(Widget.stop())
print('EXPLICIT_STOP native_visible='..tostring(native.visible))
assert(not native.visible)
-- Healthy hide control.
assert(Widget.start());Widget.tick({wpm=42,source='none'},1001);Widget.tick({wpm=0,source='none'},2000)
print('HEALTHY_IDLE native_visible='..tostring(native.visible))
assert(not native.visible)
print('PASS actual Lua owners; GTK-shaped binding; no live desktop proof')
-- Stop rollback debt must have a reachable retry after transient native failure.
assert(Widget.start());assert(Widget.tick({wpm=45,source='none'},2001))
local old_hide=window.hide
window.hide=function() return false end
native.refuse=true
assert(Widget.stop()==false)
window.hide=old_hide; native.refuse=false
assert(Widget.configuration_snapshot()==nil)
local pending_before=native.pending
assert(Widget.tick({wpm=46,source='none'},2002)==nil)
assert(native.pending==pending_before)
assert(Widget.start()==false and Widget.stop()==false and Widget.set_graph(true)==false)
print('WIDGET_RECOVERED_NATIVE public_start=false public_stop=false tick_noop=true snapshot=nil')
assert(Widget.retry_configuration_restore())
assert(Widget.tick({wpm=47,source='none'},2003))
assert(Widget.stop())
print('WIDGET_MANUAL_RETRY helper=true ticks_resume=true')
local lib=Indicator._set_binding_for_test(nil)
Indicator._set_binding_for_test(lib)
lib.gobject.g_object_unref=function() end
lib.indicator.app_indicator_set_icon_full=function() end
local reject_new=false
lib.indicator.app_indicator_new=function() if reject_new then return nil end;return {} end
package.loaded['adapters.shell_runner']={quote=function(v) return v end,run=function() return true end}
package.loaded['infra.config_paths']={data=function() return '/private-probe-unused' end}
local Readout=require('ui.wpm.tray_readout')
Readout._set_painter(function() return true end)
assert(Readout.start());assert(Readout.tick({wpm=45,source='none'},2001))
local old_set=Preferences.set
Preferences.set=function(_,value) if value==false then reject_new=true;return false end;return true end
assert(Readout.stop()==false)
reject_new=false;Preferences.set=old_set
assert(Readout.configuration_snapshot()==nil)
assert(Readout.tick({wpm=46,source='none'},2002)==nil)
assert(Readout.start()==false and Readout.stop()==false and Readout.set_use_source_colors(false)==false)
print('TRAY_RECOVERED_NATIVE public_start=false public_stop=false tick_noop=true snapshot=nil')
assert(Readout.retry_configuration_restore())
assert(Readout.tick({wpm=47,source='none'},2003))
assert(Readout.stop())
print('TRAY_MANUAL_RETRY helper=true ticks_resume=true')
