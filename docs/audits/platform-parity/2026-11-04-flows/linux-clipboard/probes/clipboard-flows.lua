local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('tests.helpers')
local function world(kind, callback)
    local names={'adapters.clipboard','adapters.shell_runner','infra.display_server'}
    local saved={};for _,name in ipairs(names) do saved[name]=package.loaded[name] end
    local state={text='saved',formats={['text/plain']='saved',['text/html']='<b>saved</b>'},writes={},reads={},pastes={}}
    local shell={has_command=function() return true end}
    function shell.exec_checked(command) state.reads[#state.reads+1]=command;return true,state.text end
    function shell.with_exact_stdin(command,text) state.pending={command=command,text=text};return command end
    function shell.run(command)
        assert(state.pending and command==state.pending.command)
        state.writes[#state.writes+1]=state.pending
        state.text=state.pending.text
        -- Native xclip/wl-copy text publication replaces ownership and offers
        -- its text MIME target; no HTML bytes were supplied by the adapter.
        state.formats={['text/plain']=state.text};state.pending=nil
        return true
    end
    package.loaded['adapters.shell_runner']=shell
    package.loaded['infra.display_server']={is_x11=function() return kind=='x11' end,
      is_wayland=function() return kind=='wayland' end,kind=function() return kind end,UNKNOWN='unknown'}
    package.loaded['adapters.clipboard']=nil
    local clip=require('adapters.clipboard')
    local function emit(combo)
        if combo=='ctrl+c' then state.text='selected';state.formats={['text/plain']='selected'} end
        if combo=='ctrl+v' then state.pastes[#state.pastes+1]=state.text end
        return true
    end
    local ok,err=pcall(callback,clip,state,emit)
    for _,name in ipairs(names) do package.loaded[name]=saved[name] end
    assert(ok,err)
end
for _,kind in ipairs({'x11','wayland'}) do
    world(kind,function(clip,state,emit)
        assert(clip.transform_selection(require('unicode_case').upper,emit,function() return true end))
        print('RICH_FORMATS',kind,'plain='..state.text,'html='..tostring(state.formats['text/html']),
          'writes='..#state.writes,'pasted='..state.pastes[1])
        assert(state.text=='saved' and state.formats['text/html']==nil)
    end)
    world(kind,function(clip,state,emit)
        local waits=0
        assert(clip.transform_selection(require('unicode_case').upper,emit,function()
            waits=waits+1
            if waits==3 then state.text='external-copy';state.formats={['text/plain']=state.text} end
            return true
        end))
        print('FOREIGN_COPY_TRANSFORM',kind,'final='..state.text,'waits='..waits)
        assert(state.text=='saved')
    end)
    world(kind,function(clip,state)
        local waits=0
        package.loaded['adapters.keyboard_layout']={shortcut_keycode=function(_,fallback) return fallback end}
        assert(clip.paste_text('payload',{emit=function() return true end},function()
            waits=waits+1
            if waits==2 then state.text='external-copy';state.formats={['text/plain']=state.text} end
            return true
        end))
        print('FOREIGN_COPY_PASTE_CONTROL',kind,'final='..state.text)
        assert(state.text=='external-copy')
        package.loaded['adapters.keyboard_layout']=nil
    end)
end
