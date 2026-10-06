--- tests/unit/ui/test_webview_native_lifecycle.lua

local helpers = require("tests.helpers")

-- Independent actual manager resource identity/retirement assertions.
local run_contract = function(helpers,load_manager,load_host)
 local function fixture(body)
  local loaded={};for name,value in pairs(package.loaded)do loaded[name]=value end
  local controls={windows={},closed={},register=true,release=true,constructor_calls=0,destroy_calls=0,release_calls=0,release_all_calls=0,logs={},views={},view_destroy_calls=0,unregister_calls=0,disconnect_calls=0,signal_serial=0}
  local manager
  local noop=function()end
  package.loaded['logger.shim']={success=noop,info=noop,debug=noop,warn=noop,error=function(_,fmt,...)controls.logs[#controls.logs+1]=string.format(fmt,...)end}
  local window_type=setmetatable({},{__call=function(_,properties)
   controls.constructor_calls=controls.constructor_calls+1
   local window={properties=properties,visible=false,alive=true}
   function window:set_size_request()end
   function window:show_all()self.visible=true end
   function window:present()if controls.present then controls.present(manager)end end
   function window:add()if controls.add then error('private attachment detail')end end
   function window:destroy()
    controls.destroy_calls=controls.destroy_calls+1
    if controls.destroy=='throw' then error('private native detail')end
    if controls.destroy=='false' then return false end
    self.alive=false;if self.on_destroy then self.on_destroy()end
   end
   controls.windows[#controls.windows+1]=window
   if controls.construct then controls.construct(manager)end
   return window
  end})
  package.loaded.lgi={Gtk={Window=window_type,WindowType={TOPLEVEL=1},WindowPosition={CENTER=1}},GLib={},WebKit2={LoadEvent={FINISHED=1},
   UserContentManager=function()
    if controls.ucm=='throw' then error('private constructor detail')end
    local ucm={connected={}}
    local signal={connect=function(_,fn,detail)
     if controls.signal then error('private signal detail')end
     controls.signal_serial=controls.signal_serial+1;local id=controls.signal_serial
     ucm.connected[id]=true;rawset(_,detail,fn);return id
    end}
    setmetatable(signal,{__newindex=function(_,detail,fn)if controls.signal then error('private signal detail')end;rawset(_,detail,fn)end})
    ucm.on_script_message_received=signal
    function ucm:register_script_message_handler()
     if controls.register=='throw'then error('private registration detail')end
     return controls.register
    end
    function ucm:unregister_script_message_handler(name)
     helpers.assert_eq(name=='metrics_typing_bridge' or name=='physical_shortcuts_bridge',true,'Only exact owned registration retires')
     controls.unregister_calls=controls.unregister_calls+1
     if controls.unregister=='throw'then error('private unregister detail')end
     if controls.unregister=='false'then return false end
    end
    return ucm
   end,WebView=function()
    local view={alive=true}
    function view:load_html()if controls.load then error('private load detail')end;if controls.child_during_load then self:destroy()end end
    function view:destroy()
     controls.view_destroy_calls=controls.view_destroy_calls+1
     if self.alive==false then return nil end
     if controls.view_destroy=='throw'then error('private child retirement detail')end
     if controls.view_destroy=='false'then return false end
     if controls.view_destroy=='no_ack'then return nil end
     self.alive=false;if self.on_destroy then self.on_destroy()end
    end
    setmetatable(view,{__newindex=function(self,name,value)
     if name=='on_destroy' and controls.view_observer then error('private child observer detail')end
     rawset(self,name,value)
    end})
    controls.views[#controls.views+1]=view
    if controls.view_construct then controls.view_construct(manager)end
    return view
   end},GObject={signal_handler_disconnect=function(ucm,id)
    controls.disconnect_calls=controls.disconnect_calls+1
    if controls.disconnect=='throw'then error('private disconnect detail')end
    if controls.disconnect=='false'then return false end
    if controls.disconnect~='no_ack'then ucm.connected[id]=false end
   end,signal_handler_is_connected=function(ucm,id)return ucm.connected[id]==true end}}
  package.loaded['adapters.event_loop']={add_idle_handler=function()end}
  package.loaded['infra.i18n']={get=function(key)return key end,get_locale=function()return 'en'end}
  package.loaded['ui.metrics_typing.bridge']={bridge_name='metrics_typing_bridge',on_message=function()return true end,
   on_window_closed=function(epoch)controls.closed[#controls.closed+1]=epoch end}
  local called,detail=pcall(function()
   local titles=require('window_titles');package.loaded['window_titles']={compose=titles.compose,key_for_app=function(app)if app=='physical_shortcuts'then return 'physical_shortcuts.window_title'end;return titles.key_for_app(app)end}
   package.loaded['ui.webkit_host']=nil;manager=load_manager();package.loaded['ui.webview_manager']=manager;manager.build_page_html=function()return'<html>inert owned page</html>'end
   manager.set_daemon_state({input_capture_gate={release=function(_,epoch)
    controls.release_calls=controls.release_calls+1
    if controls.release=='throw'then error('private release detail')end
    if controls.on_release then controls.on_release(manager,epoch)end
    return controls.release
   end,release_all=function()controls.release_all_calls=controls.release_all_calls+1;return true end}})
   body(manager,controls)
   for _,diagnostic in ipairs(controls.logs)do helpers.assert_eq(diagnostic:find('private',1,true),nil,'Private native errors never enter lifecycle diagnostics')end
  end)
  for name in pairs(package.loaded)do if loaded[name]==nil then package.loaded[name]=nil end end
  for name,value in pairs(loaded)do package.loaded[name]=value end
  if not called then error(detail,0)end
 end
 helpers.describe('Actual native WebView acquisition and retirement debt',function()
  for _,mode in ipairs({'ucm','register_false','register_throw','signal','present'})do
   helpers.it('(native-window-owner) acquisition refusal retains exact physical window: '..mode,function()
    fixture(function(m,c)
     c.destroy='false'
     if mode=='ucm'then c.ucm='throw'elseif mode=='register_false'then c.register=false elseif mode=='register_throw'then c.register='throw'elseif mode=='signal'then c.signal=true else c.present=function()error('private present detail')end end
     helpers.assert_eq(m.show('metrics_typing','en'),false)
     helpers.assert_eq(c.constructor_calls,1,'Physical window was acquired before refusal')
     local epoch=m.current_epoch('metrics_typing');helpers.assert_true(type(epoch)=='number','Logical owner retained with unsettled exact native candidate')
     helpers.assert_eq(c.windows[1].alive,true);helpers.assert_eq(#c.closed,0)
     helpers.assert_eq(m.show('metrics_typing','en'),false);helpers.assert_eq(c.constructor_calls,1,'Debt blocks successor allocation')
     c.destroy=nil;helpers.assert_eq(m.hide('metrics_typing',epoch),true);helpers.assert_eq(c.windows[1].alive,false);helpers.assert_eq(m.current_epoch('metrics_typing'),nil);helpers.assert_eq(c.closed,{epoch})
    end)
   end)
  end
  for _,mode in ipairs({'throw','false'})do
   helpers.it('(native-window-owner) destruction refusal preserves exact live page: '..mode,function()
    fixture(function(m,c)
     helpers.assert_eq(m.show('metrics_typing','en'),true);local epoch=m.current_epoch('metrics_typing');c.destroy=mode
     helpers.assert_eq(m.hide('metrics_typing',epoch),false);helpers.assert_eq(m.current_epoch('metrics_typing'),epoch);helpers.assert_eq(c.windows[1].alive,true);helpers.assert_eq(#c.closed,0)
     helpers.assert_eq(m.show('metrics_typing','en'),false);helpers.assert_eq(c.constructor_calls,1)
     c.destroy=nil;helpers.assert_eq(m.hide('metrics_typing',epoch),true);helpers.assert_eq(c.closed,{epoch})
    end)
   end)
  end
  for _,mode in ipairs({'throw',false})do
   helpers.it('(native-window-owner) capture release refusal retains logical debt: '..tostring(mode),function()
    fixture(function(m,c)
     helpers.assert_eq(m.show('metrics_typing','en'),true);local epoch=m.current_epoch('metrics_typing');c.release=mode
     helpers.assert_eq(m.hide('metrics_typing',epoch),false);helpers.assert_eq(m.current_epoch('metrics_typing'),epoch);helpers.assert_eq(#c.closed,0);helpers.assert_eq(c.windows[1].alive,false)
     local destroys=c.destroy_calls;helpers.assert_eq(m.show('metrics_typing','en'),false);helpers.assert_eq(c.constructor_calls,1)
     c.release=true;helpers.assert_eq(m.hide('metrics_typing',epoch),true);helpers.assert_eq(c.destroy_calls,destroys,'Already retired physical owner is not destroyed twice');helpers.assert_eq(c.closed,{epoch})
    end)
   end)
  end
  helpers.it('(native-window-owner) construction reentry cannot acknowledge a provisional page',function()
   fixture(function(m,c)
    c.construct=function(owner)helpers.assert_eq(owner.show('metrics_typing','en'),false,'Nested show cannot claim native acquisition')end
    helpers.assert_eq(m.show('metrics_typing','en'),true);helpers.assert_eq(c.constructor_calls,1)
   end)
  end)
  helpers.it('(native-window-owner) synchronous close during presentation cannot resurrect acquired page',function()
   fixture(function(m,c)
    c.present=function(owner)helpers.assert_eq(owner.hide('metrics_typing',owner.current_epoch('metrics_typing')),false,'Acquisition retains close request until constructor returns')end
    helpers.assert_eq(m.show('metrics_typing','en'),false);helpers.assert_eq(m.current_epoch('metrics_typing'),nil);helpers.assert_eq(c.windows[1].alive,false)
   end)
  end)
  for _,mode in ipairs({'destroy','release'})do
   helpers.it('(native-window-owner) shutdown retains refused exact debt: '..mode,function()
    fixture(function(m,c)
     helpers.assert_eq(m.show('metrics_typing','en'),true);local epoch=m.current_epoch('metrics_typing')
     if mode=='destroy'then c.destroy='false'else c.release=false end
     helpers.assert_eq(m.shutdown(),false);helpers.assert_eq(m.current_epoch('metrics_typing'),epoch)
     helpers.assert_eq(#c.closed,0);helpers.assert_eq(c.release_all_calls,0,'Global release cannot erase exact debt')
     helpers.assert_eq(m.page_current('metrics_typing',epoch),false,'Debt cannot admit private page writes')
     c.destroy=nil;c.release=true;helpers.assert_eq(m.shutdown(),true)
     helpers.assert_eq(m.current_epoch('metrics_typing'),nil);helpers.assert_eq(c.closed,{epoch});helpers.assert_eq(c.release_all_calls,1)
    end)
   end)
  end
  helpers.it('(native-window-owner) release callback cannot reacquire retiring page',function()
   fixture(function(m,c)
    helpers.assert_eq(m.show('metrics_typing','en'),true);local epoch=m.current_epoch('metrics_typing')
    c.on_release=function(owner)helpers.assert_eq(owner.show('metrics_typing','en'),false);helpers.assert_eq(owner.page_current('metrics_typing',epoch),false)end
    helpers.assert_eq(m.hide('metrics_typing',epoch),true);helpers.assert_eq(c.constructor_calls,1)
   end)
  end)
  for _,mode in ipairs({'load','add'})do
   for _,refusal in ipairs({'throw','false','no_ack'})do
    helpers.it('(native-window-owner) unattached acquired WebView retains exact child debt: '..mode..'/'..refusal,function()
     fixture(function(m,c)
      c[mode]=true;c.view_destroy=refusal
      helpers.assert_eq(m.show('metrics_typing','en'),false);local epoch=m.current_epoch('metrics_typing')
      helpers.assert_true(type(epoch)=='number');helpers.assert_eq(#c.views,1);helpers.assert_eq(c.views[1].alive,true)
      helpers.assert_eq(c.destroy_calls,0,'Window cannot substitute for unsettled acquired child')
      helpers.assert_eq(m.show('metrics_typing','en'),false);helpers.assert_eq(c.constructor_calls,1);helpers.assert_eq(#c.closed,0)
      c.view_destroy=nil;helpers.assert_eq(m.hide('metrics_typing',epoch),true)
      helpers.assert_eq(c.views[1].alive,false);helpers.assert_eq(c.windows[1].alive,false)
      helpers.assert_eq(c.unregister_calls,1);helpers.assert_eq(c.closed,{epoch})
     end)
    end)
   end
  end
  helpers.it('(native-window-owner) synchronous WebView retirement cannot acknowledge a destroyed page',function()
   fixture(function(m,c)
    c.child_during_load=true;helpers.assert_eq(m.show('metrics_typing','en'),false)
    helpers.assert_eq(c.views[1].alive,false);helpers.assert_eq(c.windows[1].alive,false);helpers.assert_eq(m.current_epoch('metrics_typing'),nil)
   end)
  end)
  helpers.it('(native-window-owner) native WebView destruction retires exact live page',function()
   fixture(function(m,c)
    helpers.assert_eq(m.show('metrics_typing','en'),true);local epoch=m.current_epoch('metrics_typing')
    c.views[1]:destroy();helpers.assert_eq(m.page_current('metrics_typing',epoch),false);helpers.assert_eq(m.current_epoch('metrics_typing'),nil)
    helpers.assert_eq(c.windows[1].alive,false);helpers.assert_eq(c.closed,{epoch})
   end)
  end)
  helpers.it('(native-window-owner) constructor cancellation adopts child destroy observer before inverse',function()
   fixture(function(m,c)
    c.view_construct=function(owner)helpers.assert_eq(owner.hide('metrics_typing',owner.current_epoch('metrics_typing')),false)end
    helpers.assert_eq(m.show('metrics_typing','en'),false)
    helpers.assert_eq(c.views[1].alive,false);helpers.assert_eq(c.windows[1].alive,false)
    helpers.assert_eq(m.current_epoch('metrics_typing'),nil);helpers.assert_eq(c.view_destroy_calls,1)
   end)
  end)
  helpers.it('(native-window-owner) failed child observer installation retries before destructive retirement',function()
   fixture(function(m,c)
    c.view_observer=true;helpers.assert_eq(m.show('metrics_typing','en'),false)
    local epoch=m.current_epoch('metrics_typing');helpers.assert_true(type(epoch)=='number')
    helpers.assert_eq(c.views[1].alive,true);helpers.assert_eq(c.view_destroy_calls,0,'No blind irreversible child destruction without terminal observer')
    helpers.assert_eq(m.show('metrics_typing','en'),false);helpers.assert_eq(c.constructor_calls,1);helpers.assert_eq(#c.closed,0)
    c.view_observer=false;helpers.assert_eq(m.hide('metrics_typing',epoch),true)
    helpers.assert_eq(c.views[1].alive,false);helpers.assert_eq(c.windows[1].alive,false);helpers.assert_eq(c.view_destroy_calls,1);helpers.assert_eq(c.closed,{epoch})
   end)
  end)
  for _,port in ipairs({'unregister','disconnect'})do
   for _,refusal in ipairs({'throw','false'})do
    helpers.it('(native-window-owner) retains exact bridge capability when '..port..' refuses '..refusal,function()
     fixture(function(m,c)
      helpers.assert_eq(m.show('metrics_typing','en'),true);local epoch=m.current_epoch('metrics_typing');c[port]=refusal
      helpers.assert_eq(m.hide('metrics_typing',epoch),false);helpers.assert_eq(m.current_epoch('metrics_typing'),epoch)
      local children=c.view_destroy_calls;helpers.assert_eq(c.views[1].alive,false)
      helpers.assert_eq(#c.closed,0);helpers.assert_eq(m.show('metrics_typing','en'),false);helpers.assert_eq(c.constructor_calls,1)
      c[port]=nil;helpers.assert_eq(m.hide('metrics_typing',epoch),true)
      helpers.assert_eq(c.view_destroy_calls,children,'Child signal ACK prevents duplicate native destruction')
      helpers.assert_eq(c.closed,{epoch})
     end)
    end)
   end
  end
  helpers.it('(native-window-owner) native disconnect return alone cannot replace exact signal readback',function()
   fixture(function(m,c)
    helpers.assert_eq(m.show('metrics_typing','en'),true);local epoch=m.current_epoch('metrics_typing');c.disconnect='no_ack'
    helpers.assert_eq(m.hide('metrics_typing',epoch),false);helpers.assert_eq(#c.closed,0)
    c.disconnect=nil;helpers.assert_eq(m.hide('metrics_typing',epoch),true);helpers.assert_eq(c.closed,{epoch})
   end)
  end)
  if load_host then
   -- These scopes grant only the fixture's controlled physical authority.
   -- GUI readiness alone must never admit a missing or refused delivery owner.
   for _,mode in ipairs({'missing','false','unknown','throw'})do
    helpers.it('(native-window-owner) actual physical host refuses delivery authority before allocation: '..mode,function()
     fixture(function(m,c)
      local queried,scope_calls=0,0
      local scope={capture_editor_inventory=function()scope_calls=scope_calls+1 end,editor_source_current=function()scope_calls=scope_calls+1 end,edit=function()scope_calls=scope_calls+1 end}
      if mode~='missing'then
       scope.physical_delivery_available=function()
        queried=queried+1
        if mode=='throw'then error('private capability detail')end
        if mode=='unknown'then return 1 end
        return false
       end
      end
      local host=load_host();package.loaded['ui.physical_shortcuts.bridge']=host
      helpers.assert_eq(m.native_available(),true,'Controlled GUI exists independently of physical delivery')
      helpers.assert_eq(host.available(scope),false,'Only literal acknowledged physical authority may admit a host')
      helpers.assert_eq(host.open({scope=scope,is_paused=function()return false end}),false)
      helpers.assert_eq(queried,mode=='missing' and 0 or 2,'Both actual admission paths inspect the owned capability')
      helpers.assert_eq(scope_calls,0,'Refusal cannot read or publish configuration')
      helpers.assert_eq(c.constructor_calls,0,'Refusal allocates no native window')
      helpers.assert_eq(#c.views,0,'Refusal allocates no WebView')
      helpers.assert_eq(m.current_epoch('physical_shortcuts'),nil,'Refusal creates no page debt or epoch')
      helpers.assert_eq(host.close(),true,'No resource debt was acquired')
     end)
    end)
   end
   for _,mode in ipairs({'destroy','release'})do
    helpers.it('(native-window-owner) actual physical host retains failed acquisition debt: '..mode,function()
     fixture(function(m,c)
      local received,retired=0,0
      package.loaded['shortcuts.physical_slots']={new=function()return{candidates=function()return{}end}end}
      package.loaded['infra.paths']={shared=function()return helpers.driver_root() .. '/../_shared/data/keycodes/physical_keys.json'end}
      package.loaded['modules.gestures.manager']={}
      package.loaded['shortcuts.physical_editor_window']={new=function(options)
       local closed=false
       return{retire=function()closed=true;retired=retired+1 end,receive=function()if closed or options.page_current()~=true then return false end;received=received+1;return true end}
      end}
      local host=load_host();package.loaded['ui.physical_shortcuts.bridge']=host
      local options={scope={capture_editor_inventory=function()end,editor_source_current=function()end,edit=function()end,physical_delivery_available=function()return true end},is_paused=function()return false end}
      c.present=function()error('private acquisition detail')end
      if mode=='destroy'then c.destroy='false'else c.release=false end
      helpers.assert_eq(host.open(options),false);local epoch=m.current_epoch('physical_shortcuts')
      helpers.assert_true(type(epoch)=='number',table.concat(c.logs,' | '));helpers.assert_eq(host.open(options),false);helpers.assert_eq(c.constructor_calls,1)
      helpers.assert_eq(host.on_message({action='ready'},{},{app_name='physical_shortcuts',epoch=epoch}),false);helpers.assert_eq(received,0)
      c.present=nil;c.destroy=nil;c.release=true
      helpers.assert_eq(host.close(),true);helpers.assert_eq(m.current_epoch('physical_shortcuts'),nil)
      helpers.assert_eq(host.open(options),true);helpers.assert_eq(c.constructor_calls,2)
      host.on_window_closed(epoch)
      helpers.assert_eq(host.on_message({action='ready'},{},{app_name='physical_shortcuts',epoch=m.current_epoch('physical_shortcuts')}),true)
      helpers.assert_eq(received,1);helpers.assert_eq(host.close(),true)
     end)
    end)
   end
   helpers.it('(native-window-owner) actual host adopts epoch before synchronous ready and close',function()
    fixture(function(m,c)
     local received=0
     package.loaded['shortcuts.physical_slots']={new=function()return{candidates=function()return{}end}end}
     package.loaded['infra.paths']={shared=function()return helpers.driver_root() .. '/../_shared/data/keycodes/physical_keys.json'end}
     package.loaded['modules.gestures.manager']={}
     package.loaded['shortcuts.physical_editor_window']={new=function(options)return{retire=function()end,receive=function()helpers.assert_eq(options.page_current(),true);received=received+1;return true end}end}
     local host=load_host();package.loaded['ui.physical_shortcuts.bridge']=host
     local options={scope={capture_editor_inventory=function()end,editor_source_current=function()end,edit=function()end,physical_delivery_available=function()return true end},is_paused=function()return false end}
     c.present=function()
      helpers.assert_eq(host.on_message({action='ready'},{},{app_name='physical_shortcuts',epoch=m.current_epoch('physical_shortcuts')}),true)
      helpers.assert_eq(received,0,'Provisional native page does not initialize editor')
     end
     helpers.assert_eq(host.open(options),true);helpers.assert_eq(received,1);helpers.assert_eq(host.close(),true)
     c.present=function()m.hide('physical_shortcuts',m.current_epoch('physical_shortcuts'))end
     helpers.assert_eq(host.open(options),false);helpers.assert_eq(m.current_epoch('physical_shortcuts'),nil)
    end)
   end)
  end
  helpers.it('(native-window-owner) old native callbacks cannot retire successor',function()
   fixture(function(m,c)
    helpers.assert_eq(m.show('metrics_typing','en'),true);local old=m.current_epoch('metrics_typing');helpers.assert_eq(m.hide('metrics_typing',old),true)
    helpers.assert_eq(m.show('metrics_typing','en'),true);local current=m.current_epoch('metrics_typing');helpers.assert_true(current>old)
    c.windows[1].on_delete_event();c.windows[1].on_destroy();helpers.assert_eq(m.current_epoch('metrics_typing'),current);helpers.assert_eq(c.windows[2].alive,true);helpers.assert_eq(c.closed,{old})
   end)
  end)
 end)
end

run_contract(helpers,function()package.loaded['ui.webview_manager']=nil;return require('ui.webview_manager')end,function()package.loaded['ui.physical_shortcuts.bridge']=nil;return require('ui.physical_shortcuts.bridge')end)
