local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('tests.helpers')
local world={app='nautilus',clipboard='saved',emits={},reads=0}
local pending
package.loaded['adapters.shell_runner']={
    has_command=function() return true end,
    exec_checked=function(command)
        world.reads=world.reads+1
        -- The active window changes while the clipboard snapshot is being
        -- obtained, before any probe chord is dispatched.
        if world.reads==1 then world.app='terminal' end
        if command:find('text/uri-list',1,true) then return false,'' end
        return true,world.clipboard
    end,
    with_exact_stdin=function(command,text) pending=text;return command end,
    run=function() world.clipboard=pending;return true end,
}
package.loaded['infra.display_server']={is_x11=function() return true end,is_wayland=function() return false end,
    kind=function() return 'x11' end,UNKNOWN='unknown'}
package.loaded['modules.gestures.combo_emitter']={press=function(combo,publication)
    world.emits[#world.emits+1]={combo=combo,app=world.app,publication=publication}
    return true
end}
package.loaded['adapters.event_loop']={sleep_ms=function() return true end}
local open=require('modules.shortcuts.open_selection')
open._set_deps_for_test({focused_app=function() return world.app end,
    open=function() error('unexpected desktop opening') end,
    notify=function() return true end,notify_success=function() return true end})
local result=open.copy_selected_path(function() return '' end)
print('FILE_COPY_FOCUS','result='..tostring(result),'chords='..#world.emits,
    'target='..world.emits[1].app,'combo='..world.emits[1].combo,
    'publication='..tostring(world.emits[1].publication))
assert(#world.emits==1 and world.emits[1].combo=='ctrl+c' and world.emits[1].app=='terminal'
    and world.emits[1].publication==nil)
