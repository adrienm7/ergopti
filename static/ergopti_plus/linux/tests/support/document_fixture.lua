--- static/ergopti_plus/linux/tests/support/document_fixture.lua

--- Controlled native boundary for the ACTUAL manager and document lease.
--- Runs actual load hooks, async nonce-result admission, ACK/close-ACK/ready and
--- route metadata. No privileged document owner is fabricated by the test.
--- This is a pure fixture, not real LGI/WebKit/entropy or native close proof.
local M = {}
local Json = require("json")
function M.new(app_name, handler, state)
	local c = { views = {}, windows = {}, timers = {}, now = 100, scripts = {}, effects = {}, notices = {}, idles = {}, signal_serial = 0 }
	local saved = {}
	local names = {"lgi","infra.monotonic","infra.timings","infra.managed_http_deadline",
		"adapters.event_loop","adapters.notifier","ui.webkit_host","ui.webview_manager"}
	for _,name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
	local real_host = require("ui.webkit_host")
	local host = setmetatable({}, {__index=real_host})
	local nonce_serial = 0
	host.native_nonce = function() nonce_serial=nonce_serial+1;return string.rep("A",20)..string.format("%04d",nonce_serial) end
	host.build_app_html = function() return "<html><body>Controlled local page</body></html>" end
	local Gtk = {WindowPosition={CENTER=1},WindowType={TOPLEVEL=1}}
	function Gtk.Window(properties)
		local w = { properties = properties }
		for _,name in ipairs({"set_size_request","add","show_all","present","set_focus_on_map","set_accept_focus","set_title"}) do w[name]=function()end end
		function w:destroy() if self.on_destroy then self.on_destroy() end end
		c.windows[#c.windows+1]=w;return w
	end
	local WebKit = {LoadEvent={STARTED="STARTED",FINISHED="FINISHED"}}
	function WebKit.UserContentManager()
		local ucm = { connected = {}, signal_details = {} }
		function ucm:register_script_message_handler(name)
			assert(type(name) == "string" and name ~= "", "registration requires the actual owned bridge")
			self.bridge_name = name
			return true
		end
		function ucm:unregister_script_message_handler(name)
			assert(name == self.bridge_name, "only the exact owned bridge registration retires")
			self.bridge_name = nil
			return true
		end
		ucm.on_script_message_received = { connect = function(signal, callback, detail)
			assert(detail == ucm.bridge_name, "detailed signal requires the exact registered bridge")
			assert(type(callback) == "function", "detailed signal requires a callback")
			c.signal_serial = c.signal_serial + 1
			local id = c.signal_serial
			ucm.connected[id], ucm.signal_details[id] = true, detail
			signal[detail] = callback
			return id
		end }
		return ucm
	end
	local Manager
	local function arguments(code)
		local raw=code:match("%.apply%(null,(%b[])%)")
		return raw and Json.decode(raw) or nil
	end
	function WebKit.WebView(options)
		local v={ucm=options.user_content_manager,uri="file:///",loading=false,results={},epoch=Manager.current_epoch(app_name)}
		function v:get_uri() if c.on_uri then c.on_uri() end;return self.uri end
		-- Match LGI's property shape so a method call cannot pass this boundary.
		setmetatable(v, { __index = function(self, key)
			if key == "is_loading" then
				if c.on_loading then c.on_loading() end
				return self.loading
			end
		end })
		function v:destroy()
			if self.destroyed then return end
			self.destroyed = true
			if self.on_destroy then self.on_destroy() end
		end
		function v:load_html(_,uri) self.uri=uri end
		function v:run_javascript(code,_,done)
			c.scripts[#c.scripts+1]={view=self,code=code}
			if code:find("runLinuxOwnedDocumentEffect",1,true) then
				c.effects[#c.effects+1]={app=app_name,code=code}
				if c.on_effect then c.on_effect(code) end
			end
			if done then self.results[#self.results+1]=done;return end
			local args=arguments(code)
			if code:find("initializeLinuxDocumentBridge",1,true) then
				self.metadata={generation=args[2],token=args[3],page_nonce=args[4]}
			elseif code:find("confirmLinuxDocumentBridge",1,true) then
				self.confirmed={generation=args[2],token=args[3],page_nonce=args[4]}
			end
		end
		function v:run_javascript_finish(result)
			if c.on_finish then c.on_finish() end
			return {get_js_value=function()return {is_string=function()return true end,to_string=function()return result end}end}
		end
		c.views[#c.views+1]=v;return v
	end
	package.loaded.lgi={Gtk=Gtk,WebKit2=WebKit,GLib={MainContext={default=function()return {iteration=function()end}end}},
		GObject={signal_handler_disconnect=function(ucm,id)
			assert(ucm.connected[id]==true,"only the exact connected native signal retires")
			ucm.connected[id]=false
			ucm.on_script_message_received[ucm.signal_details[id]]=nil
		end,signal_handler_is_connected=function(ucm,id)return ucm.connected[id]==true end}}
	package.loaded["infra.monotonic"]={now_ms=function()return c.now end,has_hires=function()return true end}
	package.loaded["infra.timings"]={ms=function(section,key)
		assert(section=="ui" and key=="document_initialization_ack_timeout_ms");return 5000 end}
	package.loaded["infra.managed_http_deadline"]={start=function(deadline,expired)
		local t={started=true,settled=false,listeners={},deadline=deadline,expired=expired}
		function t:cancel()if c.on_cancel then c.on_cancel()end;return true end
		function t:is_settled()return self.settled end
		function t:on_settled(cb)self.listeners[#self.listeners+1]=cb;return true end
		function t:ack_close()self.settled=true;local callbacks=self.listeners;self.listeners={};for _,cb in ipairs(callbacks)do cb()end end
		c.timers[#c.timers+1]=t;return t end}
	package.loaded["adapters.event_loop"]={add_idle_handler=function(fn)c.idles[#c.idles+1]=fn end}
	package.loaded["adapters.notifier"]={send_owned=function(message,opts,admit)
		if c.on_notice_probe then c.on_notice_probe() end
		if not admit() then return false end
		c.notices[#c.notices+1]={message=message,title=opts.title};return true end}
	package.loaded["ui.webkit_host"]=host
	package.loaded["ui.webview_manager"]=nil
	Manager=require("ui.webview_manager");c.manager=Manager
	local native_shutdown = Manager.shutdown
	local owned_state={}
	for key,value in pairs(state or {})do owned_state[key]=value end
	owned_state.is_paused=owned_state.is_paused or function()return c.paused==true end
	c.state=owned_state;Manager.set_daemon_state(owned_state)
	-- Preserve the actual module object used by manager._load_handler.
	local module="ui."..app_name..".bridge"
	c.saved_handler={value=package.loaded[module]};package.loaded[module]=handler
	c.handler_module=module
	assert(Manager.show(app_name)==true,"actual manager must create the controlled native window")
	function c.view()return c.views[#c.views]end
	function c.start_load()local v=c.view();v.loading=true;v.on_load_changed(v,"STARTED");return v end
	function c.finish_load(v,page_nonce)
		v=v or c.view();v.loading=false;v.on_load_changed(v,"FINISHED")
		local callback=v.results[#v.results];assert(type(callback)=="function","actual manager must request nonce")
		callback(v,page_nonce or string.rep("a",36));return v.metadata
	end
	function c.ack(v,metadata)
		v=v or c.view();metadata=metadata or v.metadata
		return Manager.route_message(app_name,handler.bridge_name,{__ergopti_document_ack=metadata},v.epoch)
	end
	function c.send(payload,v,metadata)
		v=v or c.view();metadata=metadata or v.confirmed
		return Manager.route_message(app_name,handler.bridge_name,{__ergopti_document=metadata,payload=payload},v.epoch)
	end
	function c.handshake()
		local v=c.start_load();c.finish_load(v);c.ack(v);c.timers[#c.timers]:ack_close()
		assert(v.confirmed,"actual physical-ACK seam must precede ready")
		local result=c.send("ready",v)
		assert(Manager.capture_document_owner(app_name),"actual ready must admit private document")
		return result
	end
	function c.proxy()
		return setmetatable({on_message=function(payload, supplied_state)
			if type(supplied_state)=="table" then
				for key,value in pairs(supplied_state)do c.state[key]=value end
			end
			if not Manager.capture_document_owner(app_name) then
				local initial=c.handshake()
				if payload=="ready" then return initial end
			end
			return c.send(payload)
		end},{__index=handler,__newindex=function(_,key,value)handler[key]=value end})
	end
	local closing_fixture = false
	function c.close()
		if closing_fixture then return false end
		closing_fixture = true
		local primary, retired, has_primary
		local called, first = pcall(native_shutdown)
		if not called then primary, has_primary = first, true end
		-- Initial shutdown can retain the document's original deadline close debt.
		-- Deliver its explicit modeled ACKs, then observe final native retirement.
		for _,timer in ipairs(c.timers)do
			local acknowledged, failure = pcall(function() timer:ack_close() end)
			if not acknowledged and not has_primary then primary, has_primary = failure, true end
		end
		called, retired = pcall(native_shutdown)
		if not called and not has_primary then primary, has_primary = retired, true end
		package.loaded[c.handler_module]=c.saved_handler.value
		for _,name in ipairs(names)do package.loaded[name]=saved[name].value end
		closing_fixture = false
		if has_primary then error(primary, 0) end
		return called and retired == true
	end
	return c
end
return M
