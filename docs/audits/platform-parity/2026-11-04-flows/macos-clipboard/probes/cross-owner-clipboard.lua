local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local helpers=require('tests.helpers')
local World=require('tests.support.modules.shortcuts.apps_fifo_capture_fixture')
local function run(overlap)
helpers.with_fresh_modules({'modules.shortcuts.actions.text'},function()
 World.with_world({},function(w)
  local board=hs.pasteboard
  local revision=0
  local write,clear=board.writeAllData,board.clearContents
  board.changeCount=function()return revision end
  board.writeAllData=function(data)revision=revision+1;return write(data)end
  board.clearContents=function()revision=revision+1;return clear()end
  board.setContents=function(text)return board.writeAllData({['public.utf8-plain-text']=text})end
  local Text=require('modules.shortcuts.actions.text')
  assert(w.original['public.html']~=nil)
  assert(Text.paste_as_plain_text()==true)
  assert(Text.has_pending_text_action()==true)
  assert(w.clipboard()['public.html']==nil,'plain payload must already borrow clipboard')
  if overlap then assert(w.apps.copy_or_open_path()==true,'Apps admission unexpectedly blocks sibling text owner')end
  w.advance(2)
  assert(Text.stop_text_actions()==true)
  assert(w.clipboard()['public.utf8-plain-text']=='ORIGINAL')
  if overlap then
   assert(w.clipboard()['public.html']==nil and w.clipboard()~=w.original)
   print('REPRO: pending actual plain-paste owner and Apps copy capture both admit; Apps snapshots borrowed text-only payload and eventually restores it; original HTML type lost')
  else
   assert(w.clipboard()==w.original and w.clipboard()['public.html']~=nil)
   print('CONTROL: plain-paste owner alone restores original all-type snapshot including HTML')
  end
 end)
end)

end
run(false);run(true)
