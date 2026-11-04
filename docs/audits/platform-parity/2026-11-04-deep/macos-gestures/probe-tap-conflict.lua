local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local helpers=require('tests.helpers')
local Engine=helpers.load_with_stubs('modules.gestures.engine')
local clock=1000
_G.hs.timer.secondsSinceEpoch=function()return clock end
_G.hs.timer.absoluteTime=function()return clock*1e9 end
local fired,queries={},{}
local state={enabled=true,suspended=false,ga={tap_3='lookup',swipe_3_left='word_prev'},modes={},sensitivities={},
 system_held=function(slot)queries[#queries+1]=slot;return true end}
assert(Engine.init(state,{execute_single=function(action,slot)fired[#fired+1]={action=action,slot=slot};return true end,
 execute_axis=function()error('no axis action expected')end,set_gesture_in_progress=function()end}))
local function frame(dx,empty)
 local touches={}
 if not empty then for i=1,3 do touches[i]={absoluteVector={position={x=40+i*10+(dx or 0),y=50}}}end end
 Engine.process_frame(touches,clock);clock=clock+0.02
end
frame(0);frame(0);frame(0,true)
assert(#fired==1 and fired[1].slot=='tap_3' and #queries==0)
print('REPRO: tap_3 dispatches lookup although system_held always true; conflict predicate not queried')
fired={};clock=clock+1
for i=0,20 do frame(-i*2)end
frame(0,true)
assert(#fired==0 and #queries>0)
print('CONTROL: three-finger swipe queries same system_held predicate and dispatches no action')
assert(Engine.stop()==true)
