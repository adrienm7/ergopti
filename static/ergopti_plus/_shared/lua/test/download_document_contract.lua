--- _shared/lua/test/download_document_contract.lua

--- Actual Linux network-progress caller with independently controlled native ports.
--- Does not qualify GTK or the producer's real transport/cancellation semantics.
local M = {}
function M.register(helpers)
	local function run(callback)
		local saved_host = package.loaded["ui.webview_manager"]
		local saved_bridge = package.loaded["ui.download_window.bridge"]
		local s = { writes = {}, retry = 0, cancel = 0, diagnostics = 0, paused = false }
		local lease = { active = true }; s.lease = lease
		local host = {}
		function host.show() return true end
		function host.hide() return true end
		function host.document_owner_current(owner)
			if s.on_native_read then s.on_native_read() end
			return owner == lease and owner.active == true
		end
		function host.document_owner_retained(owner) return owner == lease and owner.active == true end
		-- Untouched predecessor uses this unowned port. The independent replay
		-- records its real successor selection rather than faking a missing API.
		function host.eval_js(_, code)
			if s.on_eval then s.on_eval() end
			local target = lease.active and lease or s.successor
			s.writes[#s.writes + 1] = { owner = target, code = code }
			return true
		end
		function host.eval_owned_js(_, owner, code)
			if s.on_eval then s.on_eval() end
			if not host.document_owner_retained(owner) then return false end
			s.writes[#s.writes + 1] = { owner = owner, code = code }
			return true
		end
		function s.reload() lease.active = false; s.successor = { active = true } end
		local state = { is_paused = function() return s.paused end }
		package.loaded["ui.webview_manager"] = host
		package.loaded["ui.download_window.bridge"] = nil
		local ok, err = pcall(function()
			local Bridge = require("ui.download_window.bridge"); s.bridge = Bridge
			s.id = Bridge.show({kind="app_update",label="Pinned release",
				on_retry=function() s.retry=s.retry+1;return true end,
				on_cancel=function() s.cancel=s.cancel+1;return true end,
				on_diagnostics=function() s.diagnostics=s.diagnostics+1;return true end,
				can_open_diagnostics=function() if s.on_capabilities then s.on_capabilities() end; return true end})
			helpers.assert_eq(type(s.id),"number")
			function s.ready(owner) return Bridge.on_message("ready",state,{document_owner=owner or lease}) end
			function s.fail()
				Bridge.complete(s.id,false,"Honest terminal",{stage="unknown"})
				return s.ready().failure_epoch
			end
			function s.action(epoch,id,owner)
				return Bridge.on_message({action="failure_action",session=s.id,epoch=epoch,id=id},state,{document_owner=owner or lease})
			end
			callback(s)
		end)
		package.loaded["ui.webview_manager"], package.loaded["ui.download_window.bridge"] = saved_host,saved_bridge
		if not ok then error(err) end
	end
	helpers.describe("Actual network progress retained document ownership",function()
		helpers.it("retains admitted original document for progress and terminal",function()
			run(function(s)
				helpers.assert_eq(s.ready().pushed,true)
				helpers.assert_eq(s.bridge.update(s.id,20,"Fetching"),true)
				helpers.assert_eq(s.bridge.complete(s.id,false,"Honest terminal"),true)
				for _,write in ipairs(s.writes) do helpers.assert_eq(write.owner,s.lease) end
			end)
		end)
		helpers.it("refuses managed actions before actual document admission",function()
			run(function(s)
				helpers.assert_eq(s.bridge.on_message("ready"),nil)
				helpers.assert_eq(s.bridge.on_message({action="cancel",session=s.id}),nil)
				helpers.assert_eq(s.cancel,0);helpers.assert_eq(#s.writes,0)
			end)
		end)
		helpers.it("same-URI reload cannot borrow an active operation for progress",function()
			run(function(s)
				s.ready();local before=#s.writes;s.reload()
				helpers.assert_eq(s.bridge.update(s.id,50,"Still fetching"),false)
				helpers.assert_eq(s.ready(s.successor),nil);helpers.assert_eq(#s.writes,before)
			end)
		end)
		helpers.it("same-URI reload cannot borrow terminal publication or retry",function()
			run(function(s)
				s.ready();local epoch=s.fail();local before=#s.writes;s.reload()
				helpers.assert_eq(s.action(epoch,"retry",s.successor),nil)
				helpers.assert_eq(s.action(epoch,"retry"),nil)
				helpers.assert_eq(s.retry,0);helpers.assert_eq(#s.writes,before)
			end)
		end)
		helpers.it("document replacement during capability probe refuses old retry",function()
			run(function(s)
				s.ready();local epoch=s.fail();s.on_capabilities=function()s.on_capabilities=nil;s.reload()end
				local answer=s.action(epoch,"retry")
				helpers.assert_eq(answer.accepted,false);helpers.assert_eq(s.retry,0)
			end)
		end)
		helpers.it("fresh pause after native document observation refuses old retry",function()
			run(function(s)
				s.ready();local epoch=s.fail();s.on_native_read=function()s.on_native_read=nil;s.paused=true end
				local answer=s.action(epoch,"retry")
				helpers.assert_eq(answer.accepted,false);helpers.assert_eq(s.retry,0)
			end)
		end)
		helpers.it("actual navigation during queued evaluate cannot publish to successor",function()
			run(function(s)
				s.ready();local before=#s.writes;s.on_eval=function()s.on_eval=nil;s.reload()end
				helpers.assert_eq(s.bridge.update(s.id,70,"Fetching"),false)
				helpers.assert_eq(#s.writes,before)
			end)
		end)
		helpers.it("current unknown failure retry preserves exact session identity",function()
			run(function(s)
				s.ready();local epoch=s.fail();helpers.assert_eq(s.action(epoch,"retry").retried,true)
				helpers.assert_eq(s.retry,1);helpers.assert_eq(s.bridge.session_id(),s.id)
			end)
		end)
		helpers.it("fresh pause blocks cancel without cancelling another producer",function()
			run(function(s)
				s.ready();s.paused=true
				local answer=s.bridge.on_message({action="cancel",session=s.id},{is_paused=function()return true end},{document_owner=s.lease})
				helpers.assert_eq(s.cancel,0);helpers.assert_eq(answer,nil)
			end)
		end)
	end)
end
return M
