local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
local H=require('tests.helpers')
local original_it=H.it
local target
H.it=function(name,fn) if name=='restores a backup and restarts the daemon on it' then target=fn end end
require('tests.unit.modules.updater.install.test_changelog_release_install')
H.it=original_it
assert(target)
local harness
for index=1,30 do local name,value=debug.getupvalue(target,index);if not name then break end;if name=='harness' then harness=value end end
assert(type(harness)=='function','extract exact repository effect-isolated document/backup fixture')
local Json=require('json')
for _,mode in ipairs({'refused','missing'}) do
 local ctx=harness()
 local restart_calls=0
 if mode=='refused' then ctx.state.restart=function() restart_calls=restart_calls+1;return false end else ctx.state.restart=nil end
 local answer=ctx.bridge.on_message({action='restore_backup',id='pre-install-x'},ctx.state)
 assert(answer.phase=='restored')
 assert(answer.restarted==nil and answer.reason_key==nil)
 assert(ctx.events[1]=='restore:pre-install-x')
 print(mode..' restart_calls='..restart_calls..' answer='..Json.encode(answer))
 ctx.restore_modules()
end
local f=assert(io.open(root..'_shared/data/locales/en.json','rb'));local en=Json.decode(f:read('*a'));f:close()
assert(en['changelog_window.restore_done']=='Configuration restored: ErgoptiPlus restarts on it.')
print('shared restore_done: '..en['changelog_window.restore_done'])
print('PASS reproduction: restored bytes acknowledged by backup fixture, refused/missing restart still publishes unconditional restart success phase.')
