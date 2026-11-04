local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local World=require('tests.support.modules.gestures.search_fifo_fixture')
World.with_world({},function(w)
 w.restore_refuses=true
 assert(w.start())
 w.advance(0.21)
 local copies,restores,reads=w.counts()
 assert(copies==1 and restores>=1 and reads>=1,'copy/read/restore refusal must occur first')
 w.external('NEW USER CLIPBOARD')
 w.restore_refuses=false
 w.advance(1)
 assert(w.clipboard()['public.utf8-plain-text']=='NEW USER CLIPBOARD')
 print('CONTROL: actual Search owner keeps newer independent clipboard generation after refused restore; stale snapshot revoked')
end)
