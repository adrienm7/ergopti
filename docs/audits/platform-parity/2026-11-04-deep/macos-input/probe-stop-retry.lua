local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local F=require('tests.support.platform.remap.runtime_owner_fixture')
local owner=F.load_owner()
local world=F.new_world()
world.capture_settles_sync=false
assert(owner.init(world.ports))
local marker,restores=true,0
local activation=require('platform.remap.runtime_activation').new({
 owner=owner,restore=function(done) restores=restores+1; done(true) end,
 marker={get=function()return marker end,clear=function()marker=false;return true end},
 reload=function()error('unexpected reload')end,close_other_instances=function()return true end
})
assert(activation.reconcile(true,function()assert(owner.ensure_peers(function()end))end)=='start')
world.capture_state='admitted'; world.tick()
assert(owner.status().state=='ready')
assert(activation.reconcile(false)=='stop')
assert(owner.status().state=='stopping' and world.calls.capture_stop==1 and restores==0)
-- Native retirement was initially refused. It can now settle on retry.
world.capture_settles_sync=true
assert(activation.reconcile(false)=='stop')
assert(owner.status().state=='stopping' and world.calls.capture_stop==1 and restores==0)
print('REPRO: reconcile reports stop but new observer identity prevents native retry; stopping, capture_stop=1, restores=0')
-- Same original owner, same retained capture, no observer replacement: control.
assert(owner.stop()==true)
assert(owner.status().state=='stopped' and world.calls.capture_stop==2 and restores==1)
print('CONTROL: owner.stop() retries original retained capture successfully; stopped, capture_stop=2, restores=1')
-- Refutation of a broader claim: the original registered callback remains live.
-- A healthy capture that later notifies retirement does not require a retry.
local delayed_owner=F.load_owner();local delayed=F.new_world();delayed.capture_settles_sync=false
assert(delayed_owner.init(delayed.ports))
local given_back=0
local a=require('platform.remap.runtime_activation').new({owner=delayed_owner,
 restore=function(done)given_back=given_back+1;done(true)end,
 marker={get=function()return true end,clear=function()return true end},
 reload=function()end,close_other_instances=function()return true end})
a.reconcile(true,function()delayed_owner.ensure_peers(function()end)end)
delayed.capture_state='admitted';delayed.tick();a.reconcile(false)
delayed.capture_stop_callback(true)
assert(delayed_owner.status().state=='stopped' and given_back==1)
print('REFUTATION: ordinary deferred settlement notifies original callback, stops and restores without retry')
