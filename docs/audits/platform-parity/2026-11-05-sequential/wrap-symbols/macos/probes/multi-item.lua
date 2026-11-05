local root=assert(arg[1]);local self=assert(debug.getinfo(1,'S').source:match('^@(.*)/[^/]+$'));local base=root..'/static/ergopti_plus/'
package.path=base..'macos/?.lua;'..base..'macos/?/init.lua;'..base..'_shared/lua/?.lua;'..base..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs');local helpers=require('tests.helpers');local World=require('tests.support.modules.shortcuts.apps_fifo_capture_fixture')
local function run(count, copied_empty)
 helpers.with_fresh_modules({'modules.shortcuts.actions.text'},function()
  World.with_world({},function(w)
   local initial={{['public.utf8-plain-text']='FIRST', ['public.html']='<b>FIRST</b>'}}
   if count==2 then initial[2]={['public.png']='\137PNG SECOND PRIVATE SYNTHETIC'} end
   local items=initial;local revision=0;local item_probes=0;local pasted={}
   local native={}
   function native.contentTypes()local out={};for k in pairs(items[1] or {})do out[#out+1]=k end;return out end
   function native.allContentTypes()item_probes=item_probes+1;local out={};for i,v in ipairs(items)do out[i]={};for k in pairs(v)do out[i][#out[i]+1]=k end end;return out end
   function native.readDataForUTI(_,uti)for _,v in ipairs(items)do if v[uti]then return v[uti]end end end
   function native.clearContents()items={};revision=revision+1 end
   function native.writeDataForUTI(_,uti,data,add)
    if not add then items={} end
    items[1]=items[1] or {};items[1][uti]=data;revision=revision+1;return true
   end
   function native.setContents(s)native.clearContents();items={{['public.utf8-plain-text']=s}};revision=revision+1;return true end
   function native.getContents()return items[1]and items[1]['public.utf8-plain-text']end
   function native.changeCount()return revision end
   package.loaded['hs.libpasteboard']=native;package.loaded['hs.libpasteboardwatcher']={};package.loaded['hs.timer']=hs.timer
   for _,n in ipairs({'hs.image','hs.sound','hs.styledtext','hs.drawing.color','hs.sharing'})do package.loaded[n]=package.loaded[n]or{} end
   -- Exact upstream 1.1.1 business wrappers, not a modeled readAllData implementation.
   hs.pasteboard=assert(loadfile(self..'/upstream-pasteboard-1.1.1.lua'))()
   local Text=require('modules.shortcuts.actions.text')
   w.fixture.global_key_observer=function(e)if e.isDown and e.key=='v'then pasted[#pasted+1]=native.getContents()end end
   if copied_empty then assert(Text.wrap_copied_selection('**','**')==true)
   else assert(Text.wrap_selection('selected','(',')')==true)end
   w.advance(2);assert(Text.stop_text_actions());if copied_empty then assert(#pasted==0)else assert(#pasted==1 and pasted[1]=='(selected)')end
   assert(items[1]['public.utf8-plain-text']=='FIRST' and items[1]['public.html']=='<b>FIRST</b>')
   assert(#items==1);assert(item_probes==0);local errors=0;for _,log in ipairs(w.fixture.logs)do if log:match('^error:')then errors=errors+1 end end;assert(errors==0);print('native wrapper/control diagnostic errors='..errors)
   print(string.format('%s original-items=%d final-items=%d first-text+html=restored later-PNG=%s item-count-probes=%d paste=%q copied-empty=%s',count==1 and 'CONTROL' or 'WSM-002 REPRO',count,#items,tostring(items[2]and items[2]['public.png']~=nil),item_probes,pasted[1] or '',tostring(copied_empty==true)))
  end)
 end)
end
run(1);run(2);run(1,true);run(2,true)
