--- tests/unit/ui/test_physical_editor_native_lifecycle.lua

local helpers = require("tests.helpers")

-- Actual Builder early acquisition and public SDK release semantics, controlled natives.
local run_contract = function(helpers, load_host, load_builder)
 local function fixture(body)
  local saved,oldhs={},_G.hs;for name,value in pairs(package.loaded)do saved[name]=value end
  local c={views={},bridges={},created=0,delete_calls=0,detach_calls=0,received=0,retired=0,diagnostics={}}
  local noop=function()end
  local logger={info=noop,debug=noop,warn=noop,error=function(_,fmt,...)c.diagnostics[#c.diagnostics+1]=fmt end}
  package.loaded['infra.logger']=logger
  package.loaded['infra.paths']={shared=function(p)return p end}
  package.loaded['infra.i18n']={get=function(k)return k end}
  package.loaded['webview.i18n_seed']={}
  package.loaded['infra.deferred_work']={after=function()return true end}
  package.loaded['adapters.timer_scheduler']={now_ns=function()return 0 end}
  package.loaded['adapters.json_codec']=nil -- Use the actual codec over the controlled native JSON port.
  package.loaded['window_titles']={compose=function(k)return k end}
  package.loaded['json']={encode=function()return '{}'end}
  package.loaded['adapters.file_system']={read=function()return c.catalogue or '{}'end}
  package.loaded['shortcuts.physical_slots']={new=function(model)c.decoded_model=model;return{candidates=function()return{}end}end}
  package.loaded['shortcuts.physical_editor_window']={new=function(options)
   local retired=false
   return{retire=function()retired=true;c.retired=c.retired+1 end,receive=function()
    if retired or options.page_current()~=true then return false end
    c.received=c.received+1;return true
   end}
  end}
  _G.hs={json={decode=function()
   c.decode_calls=(c.decode_calls or 0)+1
   if c.decode_mode=='throw'then error('malformed bundled JSON')end
   if c.decode_mode=='nil'then return nil end
   return c.native_model or {}
  end},drawing={windowLevels={normal=0}},focus=noop,screen={mainScreen=function()return {}end},
   webview={windowMasks={titled=1,closable=2},usercontent={new=function()
    local bridge={};function bridge:setCallback(fn)
     if fn==nil then
      c.detach_calls=c.detach_calls+1
      if c.detach=='throw'then error('private callback detail')end
      if c.detach=='nil'then return nil end
      if c.detach=='false'then return false end
      if c.detach=='foreign'then return {}end
     end
     self.callback=fn;return self
    end
    c.bridges[#c.bridges+1]=bridge;return bridge
   end},new=function()
    c.created=c.created+1
    local view=setmetatable({},{__native_live=true})
    for _,name in ipairs({'windowTitle','windowStyle','shadow','level','allowTextEntry','allowGestures','allowNewWindows','show'})do view[name]=function(self)return self end end
    function view:windowCallback(fn)self.closing=fn;return self end
    function view:navigationCallback(fn)self.navigation=fn;return self end
    function view:evaluateJavaScript()return self end
    function view:hswindow()
     local window={raise=noop,focus=noop,moveToScreen=noop}
     function window:unminimize()
      c.restore_calls=(c.restore_calls or 0)+1
      return self
     end
     return window
    end
    function view:html()
     if c.during_html then c.during_html(self,c.bridges[#c.bridges])end
     return self
    end
    function view:delete(delay)
     helpers.assert_eq(delay,0,'Exact public no-delay deletion requested')
     c.delete_calls=c.delete_calls+1
     if c.delete=='throw'then error('private deletion detail')end
     if c.delete=='false'then return false end
     if self.closing then self.closing('closing')end
     if c.delete~='pending'then setmetatable(self,nil)end
     return nil
    end
    c.views[#c.views+1]=view;return view
   end}}
  local called,detail=pcall(function()
   local builder=load_builder()
   builder.get_app_geometry=function()return{width=700,height=600}end
   builder.get_centered_frame=function()return{}end
   builder.build_injected_html=function()return'<html></html>'end
   package.loaded['ui.ui_builder']=builder
   local host=load_host()
   local options={scope={physical_delivery_available=function()return true end,capture_editor_inventory=noop,editor_source_current=noop,edit=noop},gestures={}}
   body(host,c,options)
  end)
  for name in pairs(package.loaded)do if saved[name]==nil then package.loaded[name]=nil end end
  for name,value in pairs(saved)do package.loaded[name]=value end;_G.hs=oldhs
  if not called then error(detail,0)end
 end
 helpers.describe('Actual Builder physical editor exact native ownership',function()
  helpers.it('(physical-editor-codec) bundled catalogue becomes an unaliased tree through the actual codec',function()
   fixture(function(host,c,options)
    local shared={code='KeyJ'};c.native_model={left=shared,right=shared}
    helpers.assert_eq(host.open(options),true)
    helpers.assert_eq(c.decode_calls,1,'Catalogue decoded exactly once through the native codec port')
    helpers.assert_true(not rawequal(c.decoded_model.left,c.decoded_model.right),'Equal native tables become distinct occurrences')
    c.decoded_model.left.code='KeyK'
    helpers.assert_eq(c.decoded_model.right.code,'KeyJ','Editing one decoded occurrence cannot mutate another')
    helpers.assert_eq(shared.code,'KeyJ','The native shared graph is not mutated')
    helpers.assert_eq(host.close(),true)
   end)
  end)
  for _,mode in ipairs({'throw','nil'})do
   helpers.it('(physical-editor-codec) decoder refusal precedes native window acquisition: '..mode,function()
    fixture(function(host,c,options)
     c.decode_mode=mode
     helpers.assert_eq(host.open(options),false)
     helpers.assert_eq(c.created,0,'No native view after catalogue decode refusal')
     helpers.assert_eq(#c.bridges,0,'No native bridge after catalogue decode refusal')
     helpers.assert_eq(c.decoded_model,nil,'No physical model after catalogue decode refusal')
     c.decode_mode=nil
     helpers.assert_eq(host.open(options),true,'A healthy fresh decode still opens normally')
     helpers.assert_eq(host.close(),true)
    end)
   end)
  end
  helpers.it('(physical-editor-codec) valid top-level null is not a physical catalogue',function()
   fixture(function(host,c,options)
    c.catalogue='null';c.decode_mode='nil'
    helpers.assert_eq(host.open(options),false,'A successful JSON null lacks the catalogue object')
    helpers.assert_eq(c.created,0);helpers.assert_eq(#c.bridges,0)
    c.catalogue=nil;c.decode_mode=nil
    helpers.assert_eq(host.open(options),true);helpers.assert_eq(host.close(),true)
   end)
  end)
  for _,mode in ipairs({'throw','false','pending'})do
   helpers.it('(physical-editor-lifecycle) exact view retained after deletion refusal: '..mode,function()
    fixture(function(host,c,options)
     helpers.assert_eq(host.open(options),true,table.concat(c.diagnostics,' | '));c.delete=mode
     helpers.assert_eq(host.close(),false);helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.created,1)
     c.bridges[1].callback({body={action='ready'}});helpers.assert_eq(c.received,0,'Closing debt cannot publish or admit page callbacks')
     c.delete=nil;helpers.assert_eq(host.close(),true);helpers.assert_eq(c.bridges[1].callback,nil)
     helpers.assert_eq(host.open(options),true);helpers.assert_eq(c.created,2);helpers.assert_eq(host.close(),true)
    end)
   end)
  end
  for _,mode in ipairs({'nil','false','throw','foreign'})do
   helpers.it('(physical-editor-lifecycle) detached bridge must acknowledge exact controller: '..mode,function()
    fixture(function(host,c,options)
     helpers.assert_eq(host.open(options),true);c.detach=mode
     helpers.assert_eq(host.close(),false);helpers.assert_eq(getmetatable(c.views[1]),nil)
     local deletes=c.delete_calls
     helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.created,1);helpers.assert_eq(c.delete_calls,deletes,'Retired view is not recreated or deleted twice')
     c.bridges[1].callback({body={action='ready'}});helpers.assert_eq(c.received,0)
     c.detach=nil;helpers.assert_eq(host.close(),true);helpers.assert_eq(c.bridges[1].callback,nil)
    end)
   end)
  end
  helpers.it('(physical-editor-lifecycle) user closing callback preserves bridge debt after explicit native retirement',function()
   fixture(function(host,c,options)
    helpers.assert_eq(host.open(options),true);c.detach='false';c.views[1].closing('closing')
    helpers.assert_eq(getmetatable(c.views[1]),nil,'User closing notification does not substitute for explicit deletion')
    helpers.assert_eq(c.delete_calls,1);helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.created,1)
    c.detach=nil;helpers.assert_eq(host.close(),true);helpers.assert_eq(c.bridges[1].callback,nil)
   end)
  end)
  for _,mode in ipairs({'throw','closing'})do
   helpers.it('(physical-editor-lifecycle) early acquired view survives Builder late refusal: '..mode,function()
    fixture(function(host,c,options)
     c.delete='false';c.during_html=function(view)
      if mode=='throw'then error('private late constructor detail')else view.closing('closing')end
     end
     helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.created,1)
     helpers.assert_true(getmetatable(c.views[1])~=nil,'Acquired candidate remains physically live before acknowledgement')
     helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.created,1,'No second constructor while exact candidate cleanup refuses')
     c.delete=nil;c.during_html=nil;helpers.assert_eq(host.close(),true);helpers.assert_eq(host.open(options),true);helpers.assert_eq(host.close(),true)
    end)
   end)
  end
  helpers.it('(physical-editor-lifecycle) asynchronous deletion later GC settles without double deletion or private page callbacks',function()
   fixture(function(host,c,options)
    helpers.assert_eq(host.open(options),true);c.delete='pending';helpers.assert_eq(host.close(),false)
    setmetatable(c.views[1],nil);local deletes=c.delete_calls
    c.bridges[1].callback({body={action='ready'}});helpers.assert_eq(c.received,0)
    helpers.assert_eq(host.close(),true);helpers.assert_eq(c.delete_calls,deletes,'Terminal SDK readback acknowledges already deleted view')
   end)
  end)
  helpers.it('(physical-editor-lifecycle) old native closing callback cannot retire successor',function()
   fixture(function(host,c,options)
    helpers.assert_eq(host.open(options),true);local old=c.views[1].closing;helpers.assert_eq(host.close(),true)
    helpers.assert_eq(host.open(options),true);old('closing');helpers.assert_true(getmetatable(c.views[2])~=nil)
    c.bridges[2].callback({body={action='ready'}});helpers.assert_eq(c.received,1);helpers.assert_eq(host.close(),true)
   end)
  end)
  helpers.it('(physical-editor-lifecycle) foreground restoration receives the exact native window acknowledgement',function()
   fixture(function(host,c,options)
    helpers.assert_eq(host.open(options),true)
    helpers.assert_eq(c.restore_calls,1,'Actual Builder restores the acquired window before accepting the host')
    helpers.assert_eq(host.close(),true)
   end)
  end)
 end)
end

run_contract(helpers,function()package.loaded['ui.physical_shortcuts']=nil;return require('ui.physical_shortcuts')end,function()package.loaded['ui.ui_builder']=nil;return require('ui.ui_builder')end)
