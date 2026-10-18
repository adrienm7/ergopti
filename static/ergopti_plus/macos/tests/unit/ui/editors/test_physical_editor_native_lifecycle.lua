--- tests/unit/ui/editors/test_physical_editor_native_lifecycle.lua

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
   return{retire=function()
    retired=true;c.retired=c.retired+1
    if c.during_retire then c.during_retire()end
    if c.retire=='throw'then error('controlled editor retirement failure')end
    if c.retire=='false'then return false end
    if c.retire=='nil'then return nil end
    return true
   end,receive=function()
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
    if c.bridge_construct=='throw'then error('controlled bridge construction failure')end
    if c.bridge_construct=='nil'then return nil end
    if c.bridge_construct=='false'then return false end
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
    for _,name in ipairs({'windowTitle','windowStyle','shadow','level','allowTextEntry','allowGestures','show'})do view[name]=function(self)return self end end
    function view:allowNewWindows(value)
     if value==nil then return self.allow_new_windows~=false end
     assert(type(value)=="boolean","allowNewWindows expects a boolean")
     self.allow_new_windows=value;return self
    end
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
  for _,mode in ipairs({'false','throw','nil'})do
   helpers.it('(physical-editor-retirement) literal editor acknowledgement precedes native teardown: '..mode,function()
    fixture(function(host,c,options)
     helpers.assert_eq(host.open(options),true);c.retire=mode
     helpers.assert_eq(host.close(),false,'Editor refusal retains the host')
     helpers.assert_eq(c.delete_calls,0,'No native deletion without editor acknowledgement')
     helpers.assert_eq(c.detach_calls,0,'No bridge release without editor acknowledgement')
     helpers.assert_true(getmetatable(c.views[1])~=nil,'Original native page remains retained')
     helpers.assert_eq(host.open(options),false,'Debt prevents successor allocation')
     helpers.assert_eq(c.created,1);c.bridges[1].callback({body={action='ready'}})
     helpers.assert_eq(c.received,0,'Refused retirement cannot admit the old page')
     c.retire=nil;helpers.assert_eq(host.close(),true,'Same editor acknowledges retry')
     helpers.assert_eq(c.delete_calls,1);helpers.assert_eq(c.detach_calls,1)
     helpers.assert_eq(host.open(options),true,'Only settled debt admits successor')
     helpers.assert_eq(c.created,2);helpers.assert_eq(host.close(),true)
    end)
   end)
  end
  helpers.it('(physical-editor-retirement) reentrant retirement cannot clear or replace its host',function()
   fixture(function(host,c,options)
    helpers.assert_eq(host.open(options),true);local nested_close,nested_open
    c.retire='false';c.during_retire=function()
     c.during_retire=nil;nested_close=host.close();nested_open=host.open(options)
    end
    helpers.assert_eq(host.close(),false)
    helpers.assert_eq(nested_close,false);helpers.assert_eq(nested_open,false)
    helpers.assert_eq(c.created,1);helpers.assert_eq(c.delete_calls,0);helpers.assert_eq(c.detach_calls,0)
    c.retire=nil;helpers.assert_eq(host.close(),true)
   end)
  end)
  helpers.it('(physical-editor-retirement) SDK closing notification retains refused editor debt',function()
   fixture(function(host,c,options)
    helpers.assert_eq(host.open(options),true);c.retire='false'
    setmetatable(c.views[1],nil);c.views[1].closing('closing')
    helpers.assert_eq(c.delete_calls,0);helpers.assert_eq(c.detach_calls,0)
    helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.created,1)
    c.retire=nil;helpers.assert_eq(host.close(),true)
    helpers.assert_eq(c.delete_calls,0,'Already retired SDK page is not deleted again')
    helpers.assert_eq(c.detach_calls,1,'Bridge retires only after editor acknowledgement')
    helpers.assert_eq(host.open(options),true);helpers.assert_eq(c.created,2);helpers.assert_eq(host.close(),true)
   end)
  end)
  for _,mode in ipairs({'false','throw','nil'})do
   helpers.it('(physical-editor-retirement) bridge acquisition refusal retains original editor: '..mode,function()
    fixture(function(host,c,options)
     c.bridge_construct=mode;c.retire='false'
     helpers.assert_eq(host.open(options),false)
     helpers.assert_eq(c.created,0);helpers.assert_eq(#c.bridges,0)
     c.bridge_construct=nil
     helpers.assert_eq(host.open(options),false,'Original editor debt blocks a healthy constructor')
     helpers.assert_eq(c.created,0);helpers.assert_eq(#c.bridges,0)
     c.retire=nil;helpers.assert_eq(host.close(),true,'Original editor retries without native resources')
     helpers.assert_eq(host.open(options),true);helpers.assert_eq(c.created,1);helpers.assert_eq(host.close(),true)
    end)
   end)
  end
  helpers.it('(physical-editor-retirement) late Builder refusal keeps editor and acquired view together',function()
   fixture(function(host,c,options)
    c.retire='false';c.during_html=function()error('controlled late constructor refusal')end
    helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.created,1)
    helpers.assert_eq(c.delete_calls,0);helpers.assert_eq(c.detach_calls,0)
    c.during_html=nil;helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.created,1)
    c.retire=nil;helpers.assert_eq(host.close(),true)
    helpers.assert_eq(c.delete_calls,1);helpers.assert_eq(c.detach_calls,1)
   end)
  end)
  helpers.it('(physical-editor-retirement) pre-Builder frame exception retains bridge until same-owner retirement retry',function()
   fixture(function(host,c,options)
    local builder=package.loaded['ui.ui_builder'];local original_frame=builder.get_centered_frame
    builder.get_centered_frame=function()error('controlled pre-Builder frame provider exception')end
    c.retire='false';helpers.assert_eq(host.open(options),false,'Frame exception becomes a closed construction refusal')
    helpers.assert_eq(c.retired,1,'Construction reservation unwinds before original editor retirement')
    helpers.assert_eq(c.created,0,'Builder has not acquired a native view')
    helpers.assert_eq(#c.bridges,1,'Exact acquired bridge remains retained')
    helpers.assert_eq(c.detach_calls,0,'Editor debt blocks bridge release')
    c.bridges[1].callback({body={action='ready'}});helpers.assert_eq(c.received,0,'Refused constructor leaves page callbacks inert')
    builder.get_centered_frame=original_frame
    helpers.assert_eq(host.open(options),false,'Healthy frame provider cannot bypass original editor debt')
    helpers.assert_eq(c.retired,2,'Same editor receives the retry')
    helpers.assert_eq(c.created,0);helpers.assert_eq(#c.bridges,1);helpers.assert_eq(c.detach_calls,0)
    c.retire=nil;helpers.assert_eq(host.close(),true,'Original editor acknowledgement settles retained bridge')
    helpers.assert_eq(c.retired,3);helpers.assert_eq(c.delete_calls,0);helpers.assert_eq(c.detach_calls,1)
    helpers.assert_eq(c.bridges[1].callback,nil,'Original bridge is detached after acknowledgement')
    helpers.assert_eq(host.open(options),true,'Only settled original debt admits successor')
    helpers.assert_eq(c.created,1);helpers.assert_eq(#c.bridges,2);helpers.assert_eq(host.close(),true)
   end)
  end)
  for _,mode in ipairs({'throw','nil','false'})do
   helpers.it('(physical-editor-constructor) shared constructor refusal precedes native acquisition and permits retry: '..mode,function()
    fixture(function(host,c,options)
     local provider=package.loaded['shortcuts.physical_editor_window'];local original_new=provider.new
     if mode=='throw'then
      local genuine=assert(loadfile(helpers.shared('lua/shortcuts/physical_editor_window.lua')))()
      provider.new=function(ports)
       local constructed,owner=pcall(genuine.new,ports)
       c.constructor_error=owner
       if not constructed then error(owner,0)end
       return owner
      end
     else
      provider.new=function()if mode=='false'then return false end;return nil end
     end
     helpers.assert_eq(host.open(options),false,'Incomplete or refused shared constructor gives a closed refusal')
     if mode=='throw'then
      helpers.assert_true(tostring(c.constructor_error):find('physical editor port is incomplete',1,true)~=nil,
       'Actual shared Editor rejects the missing catalogue label port')
     end
     helpers.assert_eq(c.created,0);helpers.assert_eq(#c.bridges,0)
     helpers.assert_eq(c.delete_calls,0);helpers.assert_eq(c.detach_calls,0);helpers.assert_eq(c.retired,0)
     provider.new=original_new
     helpers.assert_eq(host.close(),true,'Pure constructor refusal leaves no native or editor owner debt')
     helpers.assert_eq(host.open(options),true,'Healthy successor starts after construction reservation unwinds')
     helpers.assert_eq(c.created,1);helpers.assert_eq(#c.bridges,1);helpers.assert_eq(host.close(),true)
    end)
   end)
  end
 end)
 return fixture
end

local capture_fixture=run_contract(helpers,function()package.loaded['ui.physical_shortcuts']=nil;return require('ui.physical_shortcuts')end,function()package.loaded['ui.ui_builder']=nil;return require('ui.ui_builder')end)

-- Reuse the original controlled natives and actual Builder. The existing thirty
-- lifecycle bodies/assertions above are unchanged; these use genuine shared ports.
local function with_observer(body)
 capture_fixture(function(_,c,options)
  local Json=assert(loadfile(helpers.shared('lua/json.lua')))()
  package.loaded['json']=Json
  package.loaded['shortcuts.physical_slots']=assert(loadfile(helpers.shared('lua/shortcuts/physical_slots.lua')))()
  package.loaded['shortcuts.physical_editor_window']=assert(loadfile(helpers.shared('lua/shortcuts/physical_editor_window.lua')))()
  local file=assert(io.open(helpers.shared('data/keycodes/physical_keys.json'),'r'))
  c.catalogue=file:read('*a');file:close();c.native_model=assert(Json.decode(c.catalogue))
  c.receipt={};c.enrollments=0;c.cancellations=0;c.stops=0;c.available_calls=0;c.packets={};c.request_id=0
  options.gestures={get_action_label=function(action)return action end,is_assignable=function(action)return action=='none'end,
   get_action_parameter_spec=function()end,validate_action_parameter=function()return false end,split_action_parameter_key=function()end}
  options.scope.capture_editor_inventory=function()return{assignments={},parameters={}},c.receipt end
  options.scope.editor_source_current=function(receipt)return rawequal(receipt,c.receipt)end
  options.scope.edit=function()error('Observation must not publish configuration')end
  local observer={position_available=function()
   c.available_calls=c.available_calls+1
   if c.on_available then c.on_available()end
   if c.available_mode=='throw'then error('controlled availability refusal')end
   if c.available_mode=='false'then return false end
   if c.available_mode=='string'then return'true'end
   return not c.pending
  end,capture_position=function(exact,receive)
   c.enrollments=c.enrollments+1;c.exact,c.receive,c.token=exact,receive,{}
   if exact()~=true then return nil end
   c.pending,c.revoked=true,false
   if c.on_enroll then c.on_enroll()end
   return c.token
  end,cancel_position=function(token)
   c.cancellations=c.cancellations+1
   helpers.assert_true(rawequal(token,c.token),'Retirement retains the original opaque table')
   c.revoked=true
   if c.cancel_mode=='throw'then error('controlled observer cancellation refusal')end
   if c.cancel_mode=='false'or c.in_frame then return false end
   c.pending=false;return true
  end,stop=function()c.stops=c.stops+1;error('Page cancellation must never stop primary metrics')end}
  c.observer=observer;package.loaded['modules.keylogger.physical_capture']=observer
  local host;package.loaded['ui.physical_shortcuts']=nil;host=require('ui.physical_shortcuts')
  c.host=host
  c.open=function()
   helpers.assert_true(host.open(options))
   local view=c.views[#c.views]
   view.evaluateJavaScript=function(self,script)
    if script:sub(1,9)=='captured('then
     c.packets[#c.packets+1]=assert(Json.decode(script:sub(10,-2)))
     if c.on_captured then c.on_captured()end
    end
    return self
   end
   c.bridges[#c.bridges].callback({body={action='ready'}})
  end
  c.request=function()
   c.request_id=c.request_id+1
   c.bridges[#c.bridges].callback({body={action='capture_position',request={request_id=c.request_id}}})
  end
  c.dispatch=function(facts)
   c.in_frame=true;local called,accepted=pcall(c.receive,facts);c.in_frame=false
   return called and accepted==true
  end
  body(host,c,options)
 end)
end

helpers.describe('Mac optional observational position composition',function()
 helpers.it('(physical-editor-position) uses original loaded observer and stable registry without availability polling after enrollment',function()
  with_observer(function(host,c)
   c.open();c.request();helpers.assert_eq(c.enrollments,1);helpers.assert_true(type(c.token)=='table')
   helpers.assert_eq(c.observer.position_available(),false,'Enrollment availability is not a native request currency poll')
   helpers.assert_true(c.dispatch({native_code=38,mods={ctrl=true}}))
   helpers.assert_eq(c.packets,{{action='captured',request_id=1,code='KeyJ',mods={ctrl=true}}})
   helpers.assert_eq(c.dispatch({native_code=38,mods={ctrl=true}}),false,'The original shared editor refuses duplicate receipt')
   helpers.assert_true(host.close());helpers.assert_eq(c.stops,0)
  end)
 end)
 helpers.it('(physical-editor-position) refuses swapped twins malformed facts modifiers and unknown native codes by stable metadata',function()
  with_observer(function(host,c)
   c.open()
   for _,facts in ipairs({{native_code=10,mods={}},{native_code=50,mods={}},{native_code=9999,mods={}},{native_code=72,mods={}},
    {native_code=59,mods={}},{native_code=38,mods={fn=true}},{native_code=38,mods={'ctrl'}},
    {native_code=38,mods=setmetatable({ctrl=true},{})},{native_code=38,mods={},device='private'},
    setmetatable({native_code=38,mods={}},{})})do
    c.request();helpers.assert_eq(c.enrollments,c.request_id)
    helpers.assert_eq(c.dispatch(facts),false);helpers.assert_eq(#c.packets,0)
    c.bridges[#c.bridges].callback({body={action='cancel_position'}})
    helpers.assert_eq(c.pending,false)
   end
   helpers.assert_true(host.close());helpers.assert_eq(c.stops,0)
  end)
 end)
 for _,kind in ipairs({'export','module','source'})do
  helpers.it('(physical-editor-position) revokes original callback and retains original cancel through replacement: '..kind,function()
   with_observer(function(host,c,options)
    c.open();c.request();helpers.assert_eq(c.enrollments,1)
    local foreign=0
    if kind=='export'then c.observer.capture_position=function()foreign=foreign+1;return{}end
    elseif kind=='module'then package.loaded['modules.keylogger.physical_capture']={cancel_position=function()foreign=foreign+1;return true end}
    else c.receipt={}end
    helpers.assert_eq(c.dispatch({native_code=38,mods={}}),false);helpers.assert_eq(#c.packets,0)
    c.cancel_mode='false';helpers.assert_eq(host.close(),false);helpers.assert_eq(host.open(options),false)
    helpers.assert_eq(c.delete_calls,0);helpers.assert_eq(c.detach_calls,0);helpers.assert_eq(c.created,1)
    c.cancel_mode=nil;helpers.assert_true(host.close());helpers.assert_true(c.cancellations>0)
    helpers.assert_eq(foreign,0);helpers.assert_eq(c.stops,0)
   end)
  end)
 end
 helpers.it('(physical-editor-position) literal availability and original export recheck precede enrollment',function()
  for _,mode in ipairs({'false','throw','string','replacement'})do
   with_observer(function(host,c)
    c.available_mode=mode
    if mode=='replacement'then c.on_available=function()c.observer.capture_position=function()error('Foreign enrollment')end end end
    c.open();c.request();helpers.assert_true(c.available_calls>0)
    helpers.assert_eq(c.enrollments,0);helpers.assert_eq(#c.packets,0);helpers.assert_true(host.close())
   end)
  end
 end)
 for _,mode in ipairs({'false','throw'})do
  helpers.it('(physical-editor-position) post-enrollment source refusal retains unreturned token debt for same-owner retry: '..mode,function()
   with_observer(function(host,c,options)
    c.open();c.cancel_mode=mode;c.on_enroll=function()c.receipt={}end;c.request()
    helpers.assert_eq(c.enrollments,1);helpers.assert_true(c.cancellations>0)
    helpers.assert_eq(host.close(),false);helpers.assert_eq(host.open(options),false)
    helpers.assert_eq(c.created,1);helpers.assert_eq(c.delete_calls,0);helpers.assert_eq(c.detach_calls,0)
    helpers.assert_eq(c.dispatch({native_code=38,mods={}}),false);helpers.assert_eq(#c.packets,0)
    c.cancel_mode=nil;helpers.assert_true(host.close());helpers.assert_eq(c.stops,0)
    c.on_enroll=nil;c.open();helpers.assert_eq(c.created,2);helpers.assert_true(host.close())
   end)
  end)
 end
 helpers.it('(physical-editor-position) own callback-frame cancellation refuses native teardown until unwind retry',function()
  with_observer(function(host,c,options)
   c.open();c.request();helpers.assert_eq(c.enrollments,1)
   local closed;c.on_captured=function()closed=host.close()end
   helpers.assert_eq(c.dispatch({native_code=38,mods={}}),false);helpers.assert_eq(closed,false)
   helpers.assert_eq(c.delete_calls,0);helpers.assert_eq(c.detach_calls,0)
   helpers.assert_true(c.revoked);helpers.assert_true(host.close());helpers.assert_eq(c.stops,0)
   c.on_captured=nil;c.open();helpers.assert_eq(c.created,2);helpers.assert_true(host.close())
  end)
 end)
 helpers.it('(physical-editor-position) absent loaded observer remains optional without constructing the producer',function()
  with_observer(function(host,c,options)
   package.loaded['modules.keylogger.physical_capture']=nil
   local saved=package.preload['modules.keylogger.physical_capture'];local required=0
   package.preload['modules.keylogger.physical_capture']=function()required=required+1;error('Must not acquire producer')end
   local called,detail=pcall(function()
    package.loaded['ui.physical_shortcuts']=nil;c.host=require('ui.physical_shortcuts')
    host=c.host
    helpers.assert_true(host.open(options))
    c.bridges[#c.bridges].callback({body={action='ready'}})
    c.bridges[#c.bridges].callback({body={action='capture_position',request={request_id=1}}})
    helpers.assert_eq(c.enrollments,0);helpers.assert_eq(required,0);helpers.assert_true(host.close())
   end)
   package.preload['modules.keylogger.physical_capture']=saved
   if not called then error(detail,0)end
  end)
 end)
end)
