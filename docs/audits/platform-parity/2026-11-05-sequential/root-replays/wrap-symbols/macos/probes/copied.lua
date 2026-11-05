local root=assert(arg[1]);local base=root..'/static/ergopti_plus/'
package.path=base..'macos/?.lua;'..base..'macos/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs');local helpers=require('tests.helpers');local World=require('tests.support.modules.shortcuts.apps_fifo_capture_fixture')
World.with_world({},function(w)
 local pb=hs.pasteboard;local revision=0;local last=w.clipboard();local write,clear=pb.writeAllData,pb.clearContents
 pb.changeCount=function()local now=w.clipboard();if now~=last then revision=revision+1;last=now end;return revision end
 pb.setContents=function(s)return write({['public.utf8-plain-text']=s})end
 local pastes={};w.fixture.global_key_observer=function(e)if e.isDown and e.key=='v'then pastes[#pastes+1]=w.clipboard()['public.utf8-plain-text']end end
 local Text=require('modules.shortcuts.actions.text');local Parser=require('wrap_pair')
 local left,right=Parser.parse('**|**',Text.wrap_pair_list());assert(left=='**' and right=='**')
 assert(Text.wrap_copied_selection(left,right,'shortcut_bindings'));w.advance(2);assert(Text.stop_text_actions());assert(pastes[1]=='**SELECTED WORDS**');assert(w.clipboard()==w.original)
 print('healthy copied selection: actual custom parameter parser **|** -> actual copy/wrap/native CmdV; pasted **SELECTED WORDS**; full text+HTML restored')
 left,right=Parser.parse('«',Text.wrap_pair_list());assert(left=='« 'and right==' »');assert(Parser.parse('bad\n|value',Text.wrap_pair_list())==nil)
 print('healthy action parser: bare guillemet resolves spaced delimiters; newline parameter refused; copied route is distinct from exact physical-symbol lookup')
end)
