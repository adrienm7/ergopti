--- tests/unit/ui/test_physical_shortcut_native_ready.lua

--- Exercises actual cached readiness through controlled initialization ports.
local helpers = require("tests.helpers")
helpers.describe("Physical editor native readiness", function()
	helpers.it("(physical-editor-ui) requires successful current initialization without source writes", function()
		local loaded, preload = {}, {}
		for name, value in pairs(package.loaded) do loaded[name] = value end
		for name, value in pairs(package.preload) do preload[name] = value end
		local called, detail = pcall(function()
			local noop=function()end
			local event=nil
			package.loaded['logger.shim']={debug=noop,success=noop,warn=noop,error=noop,info=function()if event then event()end end}
			package.loaded['infra.monotonic']={now_ms=function()return 0 end}
			package.loaded['window_titles']={compose=function(v)return v end}
			package.loaded['ui.webkit_host']={}
			local file=helpers.driver_root() .. '/ui/webview_manager.lua'
			local count=0
			local function eq(a,b,label)count=count+1;helpers.assert_eq(a,b,label)end
			local function load(value,refusal)
			 package.loaded.lgi=nil
			 package.preload.lgi=function()if refusal then error('probe refused')end;return value end
			 return assert(loadfile(file))()
			end
			local m=load(nil,true);eq(m.native_available(),false,'Missing namespace unavailable')
			m=load({WebKit2=nil});eq(m.native_available(),false,'Nil namespace unavailable even old probe accepts read')
			m=load({WebKit2=false});eq(m.native_available(),false,'False namespace unavailable')
			m=load(setmetatable({},{__index=function()error('namespace unreadable')end}));eq(m.native_available(),false,'Refused namespace read unavailable')
			m=load({WebKit2={}});eq(m.native_available(),true,'Acknowledged original native namespace query ready')
			m.shutdown();eq(m.native_available(),false,'Post-shutdown query unavailable');m.init();eq(m.native_available(),true,'Successful reinit available')
			package.loaded.lgi=nil;package.preload.lgi=function()error('new refusal')end;m.init();eq(m.native_available(),false,'Reinit refusal cannot preserve old ready')
			package.loaded.lgi={WebKit2={}};m.init();eq(m.native_available(),true,'Later successful reinit available')
			event=function()event=nil;m.shutdown()end;m.init();eq(m.native_available(),false,'Synchronous shutdown during init cannot be overwritten')
			m.init();event=function()error('private callback detail')end;local called=pcall(m.init);event=nil;eq(called,false,'Original logger throw propagated');eq(m.native_available(),false,'Thrown init never becomes available')
			package.loaded['logger.shim'].success=function()m.shutdown()end;m.init();eq(m.native_available(),false,'Probe success callback shutdown remains authoritative')
		end)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		for name in pairs(package.preload) do if preload[name] == nil then package.preload[name] = nil end end
		for name, value in pairs(preload) do package.preload[name] = value end
		if not called then error(detail, 0) end
	end)
end)
