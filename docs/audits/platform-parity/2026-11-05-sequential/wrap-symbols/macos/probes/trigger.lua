local root=assert(arg[1]);local base=root..'/static/ergopti_plus/'
package.path=base..'macos/?.lua;'..base..'macos/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local helpers=require('tests.helpers')
local World=require('tests.support.modules.shortcuts.apps_fifo_capture_fixture')
local function run(ch,states,custom,opts)
 opts=opts or {}
 helpers.with_fresh_modules({'modules.shortcuts.actions.text','modules.shortcuts.actions.system','modules.shortcuts.actions.system_pixel','modules.shortcuts.actions.system_mouse','adapters.clipboard','adapters.key_state','infra.keycodes'},function()
  World.with_world({},function(w)
   local board=hs.pasteboard;local revision=0;local writes=0;local restores=0
   local write,clear=board.writeAllData,board.clearContents
   board.changeCount=function()return revision end
   board.writeAllData=function(data)restores=restores+1;if opts.refuse_restore and restores==1 then return false end;revision=revision+1;return write(data)end
   board.clearContents=function()revision=revision+1;return clear()end
   board.setContents=function(text)writes=writes+1;if opts.refuse_write then return false end;revision=revision+1;return write({['public.utf8-plain-text']=text})end
   local ax_reads=0
   package.loaded['hs.axuielement']={systemWideElement=function()return {attributeValue=function()return {attributeValue=function()ax_reads=ax_reads+1;return opts.no_selection and '' or 'é雪\nline' end}end}end}
   package.loaded['modules.gestures']={}
   package.loaded['adapters.shell_runner']=nil
   local Text=require('modules.shortcuts.actions.text')
   local System=require('modules.shortcuts.actions.system')
   local pairs=Text.build_active_wrap_pairs(states or {},custom or {})
   local admitted=true
   local owner=assert(System.bind_wrap_text_if_selected(function()return pairs end,function()return admitted end))
   local tap=w.fixture.taps[#w.fixture.taps];assert(tap and tap.callback)
   local pastes={}
   w.fixture.global_key_observer=function(e)if e.isDown and e.key=='v' then pastes[#pastes+1]=w.clipboard()['public.utf8-plain-text']end end
   local event={getFlags=function()return opts.flags or {}end,getCharacters=function()return ch end,getProperty=function()return 0 end,getType=function()return hs.eventtap.event.types.keyDown end}
   w.synthetic.enter_callback();w.fixture.callback_active=true
   local consumed=select(1,tap.callback(event))
   w.synthetic.leave_callback(true);w.fixture.callback_active=false
   w.advance(2)
   assert(Text.stop_text_actions())
   local final=w.clipboard();assert(final['public.utf8-plain-text']=='ORIGINAL' and final['public.html']=='<b>ORIGINAL</b>','all-type clipboard must be restored')
   local decision=System.wrap_event_decision(opts.flags,ch,pairs,true)
   print(string.format('input=%q decision=%s consumed=%s AXreads=%d writes=%d pastes=%d pasted=%q restores=%d all-types=restored',ch,decision,tostring(consumed),ax_reads,writes,#pastes,pastes[1] or '',restores))
   if opts.expect_paste then assert(consumed==true and pastes[1]==opts.expect_paste)else assert(consumed==false and #pastes==0)end
   if opts.pause_check then admitted=false;assert(tap.callback(event)==false);assert(writes==1);print('paused admission control: no additional write or paste')end
   local oldwrites=writes;assert(owner:delete()~=false);tap.callback(event);assert(writes==oldwrites);print('retired tap control: no additional clipboard mutation')
  end)
 end)
end
run('(',nil,nil,{expect_paste='(é雪\nline)',pause_check=true})
run('«')
run('»')
run('«\u{00A0}')
run('\u{00A0}»')
run('« ',nil,nil,{expect_paste='« é雪\nline »'})
run('(',{['(']=false})
run('(',nil,nil,{no_selection=true})
run('(',nil,nil,{flags={cmd=true}})
run('(',nil,nil,{refuse_write=true})
run('(',nil,nil,{expect_paste='(é雪\nline)',refuse_restore=true})
run('⟦',nil,{{left='⟦',right='⟧'}},{expect_paste='⟦é雪\nline⟧'})
run('“',nil,nil,{expect_paste='„é雪\nline“'})
run('“',{['„']=false})
run('”',{['„']=false},nil,{expect_paste='“é雪\nline”'})
