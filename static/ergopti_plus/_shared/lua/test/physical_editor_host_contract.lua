--- _shared/lua/test/physical_editor_host_contract.lua

--- Independent native constructor, page identity and cleanup acknowledgement controls.
return function(helpers, Json, shared_path, load_host, platform)
	local checks=0
	local function eq(a,b,label)checks=checks+1;helpers.assert_eq(a,b,label)end
	local noop=function()end
	local logger={error=noop,info=noop,debug=noop,warn=noop}
	package.loaded['infra.paths']={shared=function(path)return shared_path(path) end}
	package.loaded['infra.i18n']={get=function(key)return key end}
	package.loaded['logger.shim']=logger;package.loaded['infra.logger']=logger
	local catalogue={get_action_label=function(a)return a end,is_assignable=function(a)return a=='send_text' or a=='none' end,get_action_parameter_spec=function(a)return a=='send_text' and 'text' or nil end,validate_action_parameter=function(a,v)return a=='send_text' and v=='★' end,split_action_parameter_key=function(k)return k:match('^(keyboard__.+)__(.+)$')end,get_picker_items=function()return{}end,get_picker_parameter_fields=function()return{}end}
	local function scope()
	 local receipt={};local writes=0
	 return {physical_delivery_available=function()return true end,capture_editor_inventory=function()return{assignments={},parameters={}},receipt end,editor_source_current=function(r)return r==receipt end,edit=function(_,r)eq(r,receipt,'Host returns native source receipt');writes=writes+1;receipt={};return true end,count=function()return writes end}
	end
	if platform == "linux" then
		local epoch,serial,callback,backend,picker,lastjs=0,0,nil,nil,nil,nil
		package.loaded['modules.gestures.manager']=catalogue
		package.loaded['ui.action_picker.bridge']={open=function(_,confirm)picker=confirm;return true end}
		package.loaded['ui.webview_manager']={native_available=function()return true end,current_epoch=function()return epoch>0 and epoch or nil end,page_current=function(_,exact)return epoch>0 and epoch==exact end,show=function()serial=serial+1;epoch=serial;return backend.on_window_acquiring(epoch) end,hide=function(_,exact)if exact~=epoch then return false end;local old=epoch;epoch=0;backend.on_window_closed(old);return true end,eval_js=function(_,js)lastjs=js;return true end}
		backend=load_host()
		local s=scope()
		eq(backend.open({scope=s,is_paused=function()return false end}),true,'Linux actual host opens')
		eq(backend.on_message({action='ready'},{},{app_name='physical_shortcuts',epoch=epoch}),true,'Linux actual epoch initializes shared protocol')
		eq(lastjs:find('"entries":[]',1,true)~=nil,true,'Linux empty inventory remains JSON array')
		eq(backend.on_message({action='choose',request={code='KeyJ',mods={},request_id=1}},{},{app_name='physical_shortcuts',epoch=epoch}),true,'Linux actual host invokes existing picker')
		eq(picker('send_text',{},'★'),true,'Linux native picker returns draft only');eq(s.count(),0,'Linux choose never persists')
		eq(backend.on_message({action='save',token=1},{},{app_name='physical_shortcuts',epoch=epoch}),true,'Linux actual host returns joint commit');eq(s.count(),1,'Linux only Save publishes')
		local old=epoch;eq(backend.on_message({action='close'},{},{app_name='physical_shortcuts',epoch=old}),true,'Linux exact epoch closes')
		eq(backend.open({scope=scope(),is_paused=function()return false end}),true,'Linux successor opens after native close')
		backend.on_window_closed(old);eq(backend.on_message({action='ready'},{},{app_name='physical_shortcuts',epoch=epoch}),true,'Old native close cannot clear successor')
		old=epoch;backend.on_window_closed(old);epoch=0;eq(backend.open({scope=scope(),is_paused=function()return false end}),true,'GTK close also retires session')
	else
		-- Macro host controlled ports. These are tables, not native userdata qualification.
		local callback,picker,lastjs,backend
		local view,bridge,delete_refuse,clear_refuse,early_ready,early_close=false,nil,false,false,false,false
		local delete_false,clear_false=false,false
		hs={json=Json,webview={usercontent={new=function()local b={};function b:setCallback(fn)if fn==nil and clear_refuse then error('private refused cleanup')end;if fn==nil and clear_false then return false end;callback=fn;return self end;bridge=b;return b end}}}
		package.loaded['adapters.file_system']={read=function(path)local f=assert(io.open(path));local bytes=f:read('*a');f:close();return bytes end}
		package.loaded['ui.menu.menu_keyboard_slots']={build_action_items=function()return{}end}
		package.loaded['ui.menu.shortcut_utils']={picker_parameter_fields=function()return{}end}
		package.loaded['ui.action_picker']={open=function(_,confirm)picker=confirm;return true end}
		package.loaded['ui.ui_builder']={get_app_geometry=function()return{width=720,height=580}end,get_centered_frame=function()return{}end,show_webview=function(options)
		 local v=setmetatable({},{__native_owned=true})
		 function v:evaluateJavaScript(js)lastjs=js end
		 function v:delete()if delete_refuse then error('private path should stay out of diagnostic')end;if delete_false then return false end;options.on_close();setmetatable(self,nil);return nil end
		 view=v;options.on_webview_created(v);if early_ready then callback({body={action='ready'}})end;if early_close then options.on_close()end;return v end}
		backend=load_host()
		local s=scope();eq(backend.open({scope=s,gestures=catalogue}),true,'Mac actual host opens');callback({body={action='ready'}});eq(lastjs:find('"entries":[]',1,true)~=nil,true,'Mac empty JSON array preserved')
		callback({body={action='choose',request={code='KeyJ',mods={},request_id=1}}});eq(picker('send_text','★'),true,'Mac native picker returns owned Unicode draft');eq(s.count(),0,'Mac selection never writes');callback({body={action='save',token=1}});eq(s.count(),1,'Mac source receipt reaches joint publication')
		delete_refuse=true;eq(backend.close(),false,'Refused native delete retains exact owner');eq(backend.open({scope=scope(),gestures=catalogue}),false,'Refused delete blocks successor');delete_refuse=false;clear_refuse=true;eq(backend.close(),false,'Refused bridge detach retains debt');clear_refuse=false;eq(backend.close(),true,'Bridge debt retries without resurrecting deleted native view')
		early_ready=true;eq(backend.open({scope=scope(),gestures=catalogue}),true,'Synchronous ready during construction retained');eq(lastjs:sub(1,5),'init(','Owned view receives deferred constructor ready');backend.close();early_ready=false;early_close=true;eq(backend.open({scope=scope(),gestures=catalogue}),false,'Close during constructor refuses admission');early_close=false;eq(backend.open({scope=scope(),gestures=catalogue}),true,'Constructor cancellation retires exact candidate');backend.close()
		delete_false=true;eq(backend.open({scope=scope(),gestures=catalogue}),true,'Mac false-delete candidate opens');eq(backend.close(),false,'Explicit native delete refusal retains debt');delete_false=false;clear_false=true;eq(backend.close(),false,'Explicit bridge release refusal retains debt');clear_false=false;eq(backend.close(),true,'Exact native release debt retries')
	end
end
