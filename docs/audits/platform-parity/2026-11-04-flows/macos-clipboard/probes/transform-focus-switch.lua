local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local helpers=require('tests.helpers')
local World=require('tests.support.modules.shortcuts.apps_fifo_capture_fixture')
local function run(change)
 helpers.with_fresh_modules({'modules.shortcuts.actions.text'},function()
  World.with_world({},function(w)
   local board=hs.pasteboard;local revision=0
   local write,clear=board.writeAllData,board.clearContents
   board.changeCount=function()return revision end
   board.writeAllData=function(data)revision=revision+1;return write(data)end
   board.clearContents=function()revision=revision+1;return clear()end
   board.setContents=function(text)return board.writeAllData({['public.utf8-plain-text']=text})end
   local focused='APP_A'
   require('adapters.window_info').getFocused=function()return {appId=focused,pid=focused=='APP_A' and 101 or 202}end
   local pastes={}
   w.fixture.global_key_observer=function(event)
    if event.isDown and event.key=='v' then pastes[#pastes+1]={focus=focused,text=w.clipboard()['public.utf8-plain-text']}end
   end
   local Text=require('modules.shortcuts.actions.text')
   assert(Text.selection_lowercase()==true)
   w.advance(0.21)
   assert(w.clipboard()['public.utf8-plain-text']=='selected words','must stop after captured selection transformed before paste')
   if change then focused='APP_B' end
   w.advance(2)
   assert(Text.stop_text_actions())
   assert(#pastes==1 and pastes[1].focus==(change and 'APP_B' or 'APP_A'))
   assert(pastes[1].text=='selected words' and w.clipboard()==w.original)
   print((change and 'REPRO' or 'CONTROL')..': original APP_A selection read; native global Cmd+V delivered to '..pastes[1].focus..' with ['..pastes[1].text..']; original clipboard restored')
  end)
 end)
end
run(false);run(true)
