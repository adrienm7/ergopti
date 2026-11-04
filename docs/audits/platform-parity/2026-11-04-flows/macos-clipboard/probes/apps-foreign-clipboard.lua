local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local World=require('tests.support.modules.shortcuts.apps_fifo_capture_fixture')
World.with_world({},function(w)
 local native=hs.pasteboard
 local count,reads=0,0
 local write,clear=native.writeAllData,native.clearContents
 native.changeCount=function()reads=reads+1;return count end
 native.writeAllData=function(value)count=count+1;return write(value)end
 native.clearContents=function()count=count+1;return clear()end
 assert(w.apps.copy_or_open_path()==true)
 w.advance(0.01)
 local copies,restores,urls=w.counts()
 assert(copies==1 and urls==0,'must stop after native copy handoff before selection timer')
 local newer={['public.utf8-plain-text']='NEW USER CLIPBOARD',['public.html']='<b>NEW USER CLIPBOARD</b>'}
 assert(native.writeAllData(newer)==true)
 assert(w.clipboard()==newer)
 w.advance(1)
 assert(w.clipboard()==w.original,'repro not observed: newer clipboard survived')
 assert(reads==0,'Apps unexpectedly consulted clipboard generation')
 copies,restores,urls=w.counts()
 assert(urls==1)
 print('REPRO: copy handoff then independent new clipboard write; Apps reads newer text as selection, opens it, restores ORIGINAL over newer clipboard; changeCount reads=0')
end)
World.with_world({},function(w)
 assert(w.apps.copy_or_open_path()==true)
 w.advance(1)
 local copies,restores,urls=w.counts()
 assert(copies==1 and restores==1 and urls==1 and w.clipboard()==w.original)
 print('CONTROL: no independent writer; one copy, one restore, one URL and original all-type clipboard preserved')
end)
World.with_world({restore_refusals=1},function(w)
 local native=hs.pasteboard
 local count,reads=0,0
 local write,clear=native.writeAllData,native.clearContents
 native.changeCount=function()reads=reads+1;return count end
 native.writeAllData=function(value)count=count+1;return write(value)end
 native.clearContents=function()count=count+1;return clear()end
 assert(w.apps.copy_or_open_path()==true)
 w.advance(0.21)
 local copies,restores,urls=w.counts()
 assert(copies==1 and restores==1 and urls==1,'must stop after selection read and refused restoration')
 assert(w.apps.has_pending_apps_action())
 local newer={['public.utf8-plain-text']='USER COPY AFTER FAILED RESTORE',['public.html']='<b>NEW</b>'}
 assert(native.writeAllData(newer))
 w.advance(1)
 assert(w.clipboard()==w.original and reads==0)
 print('REPRO RETRY: selection read completed and first restore refused; independent new clipboard write is overwritten by retained restore retry without generation check')
end)
