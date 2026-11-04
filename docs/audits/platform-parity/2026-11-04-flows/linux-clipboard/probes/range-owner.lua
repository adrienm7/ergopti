local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('tests.helpers')
require('tests.support.text_owner_fixture').with(function(guard,state)
    state.selection='source'
    local clipboard,pending,waits='saved',nil,0
    package.loaded['adapters.shell_runner']={
        has_command=function() return true end,
        exec_checked=function() return true,clipboard end,
        with_exact_stdin=function(command,text) pending=text;return command end,
        run=function() clipboard=pending;return true end,
    }
    package.loaded['infra.display_server']={is_x11=function() return true end,is_wayland=function() return false end,
        kind=function() return 'x11' end,UNKNOWN='unknown'}
    package.loaded['adapters.clipboard']=nil
    local emitted={}
    package.loaded['modules.gestures.combo_emitter']={press=function(combo)
        if combo=='ctrl+c' then clipboard=state.selection end
        if combo=='ctrl+v' then
            emitted[#emitted+1]={range=state.selection,text=clipboard}
            state.selection=clipboard
        end
        return true
    end}
    package.loaded['adapters.event_loop']={sleep_ms=function()
        waits=waits+1
        -- A document/app changes the selected range in the SAME accessible
        -- field. Native field bus/path/role and privacy policy remain current.
        if waits==2 then state.selection='other-range' end
        return true
    end}
    package.loaded['modules.hotstrings.injector']={inject=function() error('unexpected direct output') end}
    package.loaded['modules.shortcuts.manager']=nil
    local manager=require('modules.shortcuts.manager')
    manager.init({persist=false,capture_text_owner=guard.capture_text_owner})
    local ok=manager.transform_to_uppercase()
    print('SAME_FIELD_RANGE','ok='..tostring(ok),'writes='..#emitted,'range='..emitted[1].range,'text='..emitted[1].text)
    assert(ok and #emitted==1 and emitted[1].range=='other-range' and emitted[1].text=='SOURCE')
end)
