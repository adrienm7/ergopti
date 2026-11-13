--- tests/unit/ai/engine/remote/test_local_server_discovery.lua

--- Catalogue discovery uses actual private source ownership and retained native GETs.
local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
-- The shipped catalogue. These cases drive four of its servers; the others
-- are stopped by the scan fake below, so a longer catalogue changes no case.
local CATALOGUE = Json.decode(assert(io.open(require("core.fs.engine.paths").shared("ai/data/local_servers.json"), "rb")):read("*a"))
local DRIVEN = { omlx = true, lmstudio = true, llamacpp = true, jan = true }
--- The probed sources of one sweep: the driven servers and configured rows.
--- @param servers table modules.llm.local_servers
--- @return table ids
local function probed(servers)
	local ids = {}
	for _, id in ipairs(servers.order()) do
		if DRIVEN[id] or id:match("^configured:") then ids[#ids + 1] = id end
	end
	return ids
end
local function isolated(body)
	local names = { "ai.engine.local_servers.local_servers", "ai.engine.settings.api_entries", "ai.engine.api.api_remote",
		"core.network.adapters.http_client", "core.events.loop", "ai.ui.menu.local_server_rows", "ai.ui.menu.backend_rows",
		"ai.engine.local_servers.ports" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	-- The four servers these cases drive run at their catalogue address; every
	-- other catalogue server is stopped, so a longer catalogue changes no case
	-- (test_local_server_ports covers the scan, test_local_server_detection_native
	-- the real process list).
	local scan_overrides = {}
	for _, id in ipairs(CATALOGUE.server_order) do
		if not DRIVEN[id] then scan_overrides[id] = { running = false, pids = {} } end
	end
	require("tests.support.ai.engine.local_server_scan_fake").install(scan_overrides)
	-- Native scheduling is covered independently by test_local_server_startup.
	package.loaded["core.events.loop"] = { defer = function(fn) fn(); return true end }
	local path = os.tmpname(); os.remove(path)
	local calls = {}
	package.loaded["core.network.adapters.http_client"] = { get_owned = function(url, headers, options, callback)
		local call = { url = url, headers = headers, options = options, callback = callback, cancelled = 0, listeners = {} }
		local operation = { started = true }
		function operation:is_settled()
			if call.on_observe then call.on_observe() end
			return call.settled == true
		end
		function operation:on_settled(fn) if call.settled then fn() else call.listeners[#call.listeners+1] = fn end; return true end
		function operation:cancel() call.cancelled = call.cancelled + 1; return call.settled == true end
		call.operation = operation
		function call.finish(response)
			call.settled = true
			if call.cancelled == 0 then callback(response) end
			local listeners=call.listeners; call.listeners={}
			for _,fn in ipairs(listeners) do fn() end
		end
		calls[#calls+1] = call
		if calls.before_return then calls.before_return(call) end
		return operation
	end }
	local entries = require("ai.engine.settings.api_entries")
	entries._set_path_for_test(path)
	entries._set_private_create_for_test(function(stage, text)
		local out=assert(io.open(stage,"wb")); out:write(text); out:close(); return true
	end)
	local servers = require("ai.engine.local_servers.local_servers")
	local ok, err = pcall(body, servers, entries, calls, path, scan_overrides)
	servers.shutdown()
	os.remove(path); os.remove(path..".tmp"); os.remove(path..".corrupt")
	for _,name in ipairs(names) do package.loaded[name]=previous[name] end
	if not ok then error(err,0) end
end
local function models(...)
	local data={};for _,id in ipairs({...}) do data[#data+1]={id=id} end
	return {ok=true,status=200,body=Json.encode({data=Json.array(data)})}
end
local function find(rows,label)
	for _,row in ipairs(rows) do
		if row.label==label then return row end
		if row.items then local found=find(row.items,label); if found then return found end end
	end
end
helpers.describe("Linux local server discovery ownership", function()
	helpers.it("a shutdown during deferred source reading prevents later target lookup", function()
		isolated(function(servers, entries, calls)
			local loop = require("core.events.loop")
			local defer, source, target = loop.defer, entries.source_is_current, servers.target
			local pending, armed, stopping, ack, after = {}, false, false, nil, 0
			loop.defer = function(fn) pending[#pending + 1] = fn; return true end
			entries.source_is_current = function(...)
				if armed then armed = false; stopping = true; ack = servers.shutdown() end
				return source(...)
			end
			servers.target = function(...)
				if stopping then after = after + 1 end
				return target(...)
			end
			local ok, failure = pcall(function()
				helpers.assert_true(servers.rescan(function() return true end))
				helpers.assert_true(#pending > 0)
				armed = true
				pending[1]()
				helpers.assert_eq(ack, false)
				helpers.assert_eq(after, 0)
				helpers.assert_eq(#calls, 0)
			end)
			loop.defer, entries.source_is_current, servers.target = defer, source, target
			assert(ok, failure)
		end)
	end)

	helpers.it("a replaced GET observation cannot forge retirement", function()
		isolated(function(servers, _, calls, _, scan)
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do scan[id] = { running = false, pids = {} } end
			helpers.assert_true(servers.rescan(function() return true end))
			helpers.assert_eq(#calls, 1)
			local first, original = calls[1], calls[1].operation.is_settled
			first.settled = true
			first.operation.is_settled = function() return true end
			helpers.assert_eq(servers.cancel(), false)
			first.operation.is_settled = original
			helpers.assert_eq(servers.cancel(), true)
		end)
	end)

	helpers.it("a reentrant old GET settlement cannot erase its acquired successor", function()
		isolated(function(servers, _, calls, _, scan)
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do scan[id] = { running = false, pids = {} } end
			helpers.assert_true(servers.rescan(function() return true end))
			helpers.assert_eq(#calls, 1)
			helpers.assert_true(servers.rescan(function() return true end))
			helpers.assert_eq(#calls, 1)
			local first, nested = calls[1], false
			first.settled = true
			first.on_observe = function()
				if not nested then nested = true; first.listeners[1]() end
			end
			first.listeners[1]()
			helpers.assert_eq(#calls, 2, "the successor acquired its own GET")
			helpers.assert_eq(servers.cancel(), false, "the successor GET still owns native resources")
			calls[2].finish(models("successor"))
			helpers.assert_eq(servers.cancel(), true)
		end)
	end)

	helpers.it("shutdown cannot acknowledge an active GET settlement observer", function()
		isolated(function(servers, _, calls, _, scan)
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do scan[id] = { running = false, pids = {} } end
			helpers.assert_true(servers.rescan(function() return true end))
			local first, armed, during = calls[1], true, nil
			first.settled = true
			first.on_observe = function()
				if armed then armed = false; during = servers.shutdown() end
			end
			first.listeners[1]()
			helpers.assert_eq(during, false)
			helpers.assert_eq(servers.shutdown(), true)
		end)
	end)

	helpers.it("review-http-admit: shutdown cannot ACK inside a settled HTTP callback", function()
		isolated(function(servers, _, calls, _, scan)
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do scan[id] = { running = false, pids = {} } end
			local armed, during = false, nil
			assert(servers.rescan(function()
				if armed then armed = false; during = servers.shutdown() end
				return true
			end))
			assert(#calls == 1)
			armed = true
			calls[1].finish(models("qwen3"))
			helpers.assert_eq(during, false, "the settled HTTP delivery frame is still executing")
		end)
	end)

	helpers.it("review-deferred-admit: shutdown cannot ACK before the deferred acquisition frame ends", function()
		isolated(function(servers, entries)
			local loop = require("core.events.loop")
			local original_defer, original_current = loop.defer, entries.source_is_current
			local pending, armed, ack, after = {}, false, nil, 0
			loop.defer = function(fn) pending[#pending + 1] = fn; return true end
			entries.source_is_current = function(...)
				if ack == true then after = after + 1 end
				return original_current(...)
			end
			local ok, err = pcall(function()
				assert(servers.rescan(function()
					if armed then armed = false; ack = servers.shutdown() end
					return true
				end))
				assert(#pending > 0)
				armed = true
				pending[1]()
				helpers.assert_eq(after, 0, "no source read may run after shutdown ACK")
				helpers.assert_eq(ack, false, "the admitted callback still owns a deferred acquisition frame")
			end)
			loop.defer, entries.source_is_current = original_defer, original_current
			assert(ok, err)
		end)
	end)
	-- The maintainer's oMLX listened on 8181 (its settings file) while the sweep
	-- probed the catalogue port 8000 only (field report 2026-10-27)
	helpers.it("probes a server at the port its scan found and skips a server that does not run (local-server-ports)", function()
		isolated(function(servers, _, calls, _, scan)
			scan.omlx = { base_url = "http://127.0.0.1:8181/v1", port = 8181, source = "config" }
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do scan[id] = { running = false, pids = {} } end
			local published = 0
			helpers.assert_true(servers.rescan(function() return true end, function() published = published + 1 end))
			helpers.assert_eq(#calls, 1, "a server whose process does not run is not probed")
			helpers.assert_eq(calls[1].url, "http://127.0.0.1:8181/v1/models")
			calls[1].finish(models("qwen3"))
			helpers.assert_eq(published, 1)
			helpers.assert_eq(table.concat(servers.detected(), ","), "omlx")
			local views = servers.views()
			helpers.assert_eq(views[1], { id = "omlx", display_name = CATALOGUE.servers.omlx.label, port = 8181, port_source = "config",
				base_url = "http://127.0.0.1:8181/v1", models = { "qwen3" }, status = "up" })
			helpers.assert_eq(views[2].reason, "not_running")
			local endpoint = assert(require("ai.engine.api.api_remote").endpoint(
				{ provider = "omlx", base_url = "http://127.0.0.1:8000/v1", token = "" }, "qwen3"))
			helpers.assert_eq(endpoint.url:sub(1, 26), "http://127.0.0.1:8181/v1/c", "a request follows the scanned port")
		end)
	end)
	-- vLLM shares oMLX's port 8000: both rows probe it when both are looked for,
	-- and the answer's owned_by names the one row kept (local_servers.json fingerprint)
	helpers.it("vLLM answering on oMLX's port is one row named vLLM (local-server-fingerprint)", function()
		isolated(function(servers, _, calls, _, scan)
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do scan[id] = { running = false, pids = {} } end
			scan.vllm = { running = true, pids = { 2 } }
			helpers.assert_true(servers.rescan(function() return true end, function() end))
			helpers.assert_eq(#calls, 2)
			helpers.assert_eq(calls[1].url, "http://127.0.0.1:8000/v1/models")
			helpers.assert_eq(calls[2].url, "http://127.0.0.1:8000/v1/models")
			local listing = { ok = true, status = 200,
				body = '{"object":"list","data":[{"id":"Qwen/Qwen3-8B","object":"model","owned_by":"vllm"}]}' }
			calls[1].finish(listing)
			calls[2].finish(listing)
			helpers.assert_eq(table.concat(servers.detected(), ","), "vllm")
			helpers.assert_eq(servers.result("omlx").shadowed_by, "vllm")
			local names = {}
			for _, view in ipairs(servers.views()) do
				if view.status == "up" then names[#names + 1] = view.display_name end
			end
			helpers.assert_eq(names, { "vLLM" })
		end)
	end)
	helpers.it("an oMLX row whose answer is vLLM's is named vLLM (local-server-fingerprint)", function()
		isolated(function(servers, _, calls, _, scan)
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do scan[id] = { running = false, pids = {} } end
			helpers.assert_true(servers.rescan(function() return true end, function() end))
			helpers.assert_eq(#calls, 1)
			calls[1].finish({ ok = true, status = 200,
				body = '{"object":"list","data":[{"id":"Qwen/Qwen3-8B","object":"model","owned_by":"vllm"}]}' })
			helpers.assert_eq(table.concat(servers.detected(), ","), "omlx")
			helpers.assert_eq(servers.views()[1].display_name, "vLLM")
			-- Paused: the rows are built from the published verdicts, with no new sweep
			local rows = require("ai.ui.menu.local_server_rows").rows({ is_enabled = function() return true end,
				get_backend = function() return "ollama" end, can_configure_local_servers = function() return false end },
				{}, nil, { is_paused = function() return true end })
			helpers.assert_true(find(rows, "vLLM 🖥️ — 127.0.0.1:8000") ~= nil, "the menu row names vLLM")
		end)
	end)
	helpers.it("no running server probes nothing and still publishes none (local-server-ports)", function()
		isolated(function(servers, _, calls, _, scan)
			for _, id in ipairs({ "omlx", "lmstudio", "llamacpp", "jan" }) do scan[id] = { running = false, pids = {} } end
			local changed = {}
			helpers.assert_true(servers.rescan(function() return true end, function(value) changed[#changed + 1] = value end))
			helpers.assert_eq(#calls, 0)
			helpers.assert_eq(#changed, 1)
			helpers.assert_eq(#servers.detected(), 0)
			helpers.assert_eq(servers.is_sweeping(), false)
		end)
	end)
	helpers.it("probes four catalogue URLs under independent native owners with optional credentials", function()
		isolated(function(servers,entries,calls)
			assert(entries.add({provider="lmstudio",label="Local",model="old",token=" private ",base_url="http://localhost:4321/v1"}))
			local published=0
			helpers.assert_true(servers.rescan(function() return true end,function() published=published+1 end))
			helpers.assert_eq(#calls,4)
			helpers.assert_eq(calls[1].url,"http://127.0.0.1:8000/v1/models")
			helpers.assert_eq(calls[2].url,"http://localhost:4321/v1/models")
			helpers.assert_eq(calls[3].url,"http://127.0.0.1:8080/v1/models")
			helpers.assert_eq(calls[4].url,"http://127.0.0.1:1337/v1/models")
			for index,id in ipairs({"omlx","lmstudio","llamacpp","jan"}) do
				helpers.assert_eq(calls[index].options.owner,"llm_local_server:"..id)
				helpers.assert_eq(calls[index].options.follow_redirects,false)
			end
			helpers.assert_nil(calls[1].headers.Authorization)
			helpers.assert_eq(calls[2].headers.Authorization,"Bearer  private ")
			for index=1,3 do calls[index].finish(models("model")); helpers.assert_eq(published,0) end
			calls[4].finish({ok=false,status=401,body=""})
			helpers.assert_eq(published,1)
			helpers.assert_eq(servers.result("jan").status,"needs_key")
			helpers.assert_eq(table.concat(servers.detected(),","),"omlx,lmstudio,llamacpp,jan")
		end)
	end)
	helpers.it("logical cancellation cannot replace a GET until exact native exit and close settlement", function()
		isolated(function(servers,_,calls)
			servers.rescan(function() return true end)
			local first=calls[1]
			helpers.assert_eq(servers.cancel(),false)
			helpers.assert_eq(servers.is_sweeping(),false)
			helpers.assert_eq(servers.is_stale(),true)
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,4,"accepted cancellation and inactive logical sweep do not acknowledge handles")
			first.callback(models("stale"))
			helpers.assert_nil(servers.result("omlx"))
			first.finish(models("stale"))
			helpers.assert_eq(#calls,5,"only this exact retired provider may acquire its successor")
			helpers.assert_eq(calls[5].options.owner,"llm_local_server:omlx")
			for index=2,4 do calls[index].finish(models("stale")) end
			helpers.assert_eq(#calls,8)
			for index=5,8 do calls[index].finish(models("current")) end
			helpers.assert_eq(servers.result("omlx").models[1],"current")
		end)
	end)
	helpers.it("held model and private-source changes fence acquisition and publication", function()
		isolated(function(servers,entries,calls,path)
			servers.rescan(function() return true end)
			for _,call in ipairs(calls) do call.finish(models("first","second")) end
			local receipt=servers.capture("lmstudio")
			helpers.assert_true(servers.is_current(receipt,"first"))
			servers.rescan(function() return true end)
			for index=5,8 do calls[index].finish(models("first","second")) end
			helpers.assert_true(servers.is_current(receipt,"second"),"unchanged cache refresh does not invalidate visible rows")
			local out=assert(io.open(path,"wb"));out:write('{"version":2,"entries":[]}');out:close()
			helpers.assert_eq(servers.is_current(receipt,"first"),false)
			helpers.assert_nil(servers.apply(receipt,{model="first"},function() return true end))
			helpers.assert_eq(servers.rescan(function() return true end),false)
			helpers.assert_eq(#calls,8)
			helpers.assert_nil(entries.active())
		end)
	end)
	-- ai-disabled-no-discovery-2026-10-20 (issue #97): every Models menu build
	-- swept the four catalogue servers even with the AI switched off.
	helpers.it("probes no server and keeps the rows inert while the AI is off (issue #97)", function()
		isolated(function(servers,entries,calls)
			local enabled=false
			local llm={get_backend=function() return "ollama" end,get_current_model=function() return "ollama-model" end,
				can_configure_local_servers=function() return true end,is_enabled=function() return enabled end,
				set_backend=function() error("an inert row cannot select a backend") end}
			local dialogs={prompt=function() error("an inert row cannot prompt") end,error=function() end}
			local context={is_paused=function() return false end}
			local ServerRows=require("ai.ui.menu.local_server_rows")
			local function build() return ServerRows.rows(llm,dialogs,function() end,context) end
			local rows=build()
			helpers.assert_eq(#calls,0,"no local server is probed while the AI is off")
			local rescan=find(rows,require("core.i18n.engine.i18n").get("menu.llm.local_servers.rescan"))
			helpers.assert_true(rescan~=nil and rescan.action==nil and rescan.disabled==true,
				"the rescan row is inert while the AI is off")
			local address=find(rows,require("core.i18n.engine.i18n").get("menu.llm.local_servers.other_address"))
			helpers.assert_true(address~=nil)
			for _,item in ipairs(address.items or {}) do
				helpers.assert_nil(item.action,"another address cannot be typed while the AI is off")
			end
			enabled=true
			build()
			helpers.assert_eq(#calls,4,"switching the AI on sweeps every catalogue server")
		end)
	end)
	helpers.it("models rows are usable with the AI on and expose JSON ACK/backend refusal separately", function()
		isolated(function(servers,entries,calls)
			local allowed, backend, setters, changes=true,"ollama",0,0
			local llm={get_backend=function() return backend end,get_current_model=function() return "ollama-model" end,
				can_configure_local_servers=function() return allowed end,is_enabled=function() return true end,
				set_backend=function() setters=setters+1;allowed=false;return false end}
			local dialogs={prompt=function() return nil end,error=function() end}
			local context={is_paused=function() return false end}
			local ServerRows=require("ai.ui.menu.local_server_rows")
			local function build() return ServerRows.rows(llm,dialogs,function() changes=changes+1 end,context) end
			build()
			helpers.assert_eq(#calls,4,"actual backend provider starts catalogue probes")
			for _,call in ipairs(calls) do call.finish(models("local-choice")) end
			local rows=build()
			local row=find(rows,"local-choice")
			helpers.assert_true(row~=nil and type(row.action)=="function")
			local outcome=row.action()
			helpers.assert_eq(outcome.saved,true)
			helpers.assert_eq(outcome.selected,false)
			helpers.assert_eq(setters,1)
			helpers.assert_eq(backend,"ollama")
			helpers.assert_eq(entries.active().model,"local-choice")
			helpers.assert_true(changes>=1)
		end)
	end)
	for _, mode in ipairs({ "nil", "throw", "nonboolean" }) do
		helpers.it("an unreadable pause state refuses local server discovery: " .. mode, function()
			isolated(function(_, _, calls)
				local llm = { get_backend = function() return "ollama" end,
					can_configure_local_servers = function() return true end, is_enabled = function() return true end }
				local rows = require("ai.ui.menu.local_server_rows").rows(llm, {}, function() end,
					{ is_paused = function()
						if mode == "throw" then error("pause unavailable") end
						if mode == "nonboolean" then return "no" end
					end })
				helpers.assert_type(rows, "table")
				helpers.assert_eq(#calls, 0)
			end)
		end)
	end

	helpers.it("does not discover servers if the page closes while the AI state is read", function()
		isolated(function(_, _, calls)
			local live = true
			local llm = { get_backend = function() return "ollama" end,
				can_configure_local_servers = function() return true end,
				is_enabled = function() live = false; return true end }
			local rows = require("ai.ui.menu.local_server_rows").rows(llm, {}, function() end,
				{ is_paused = function() return false end, page_current = function() return live end })
			helpers.assert_type(rows, "table")
			helpers.assert_eq(#calls, 0)
		end)
	end)

	helpers.it("an unavailable AI state refuses local server discovery", function()
		isolated(function(_, _, calls)
			local llm = { get_backend = function() return "ollama" end,
				can_configure_local_servers = function() return true end,
				is_enabled = function() error("AI state unavailable") end }
			local rows = require("ai.ui.menu.local_server_rows").rows(llm, {}, function() end,
				{ is_paused = function() return false end })
			helpers.assert_type(rows, "table")
			helpers.assert_eq(#calls, 0)
		end)
	end)

	helpers.it("an unavailable local configuration owner refuses discovery", function()
		isolated(function(_, _, calls)
			local llm = { get_backend = function() return "ollama" end,
				can_configure_local_servers = function() error("scope unavailable") end,
				is_enabled = function() return true end }
			local rows = require("ai.ui.menu.local_server_rows").rows(llm, {}, function() end,
				{ is_paused = function() return false end })
			helpers.assert_type(rows, "table")
			helpers.assert_eq(#calls, 0)
		end)
	end)

	helpers.it("does not cancel a successor born from a retired scan callback", function()
		isolated(function(servers)
			local ports, previous = require("ai.engine.local_servers.ports"), nil
			previous = ports.scan_owned
			local operations = {}
			ports.scan_owned = function()
				local operation = { closed = false, cancellations = 0 }
				function operation:cancel()
					self.cancellations = self.cancellations + 1
					if #operations == 1 then self.closed = true end
					return self.closed
				end
				function operation:is_settled() return self.closed end
				operations[#operations + 1] = operation
				return operation
			end
			local ok, failure = pcall(function()
				helpers.assert_true(servers.rescan(function() return true end, function()
					helpers.assert_true(servers.rescan(function() return true end))
				end))
				helpers.assert_eq(servers.cancel(), false)
				helpers.assert_eq(#operations, 2)
				helpers.assert_eq(operations[2].cancellations, 0)
				operations[2].closed = true
				helpers.assert_eq(servers.cancel(), true)
			end)
			ports.scan_owned = previous
			assert(ok, failure)
		end)
	end)

	helpers.it("refuses a legacy port scanner that cannot return native ownership", function()
		isolated(function(servers, _, calls)
			local ports = require("ai.engine.local_servers.ports")
			local previous, scans = ports.scan_owned, 0
			local prior_scan = ports.scan
			ports.scan_owned = nil
			ports.scan = function() scans = scans + 1 end
			local ok, failure = pcall(function()
				helpers.assert_eq(servers.rescan(function() return true end), false)
				helpers.assert_eq(scans, 0)
				helpers.assert_eq(#calls, 0)
				helpers.assert_eq(servers.cancel(), true)
			end)
			ports.scan_owned, ports.scan = previous, prior_scan
			assert(ok, failure)
		end)
	end)

	helpers.it("retains a process acquired while its scan constructor is cancelled", function()
		local scanner = require("ai.engine.local_servers.ports")
		local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
		local during, closed, cancelled = nil, false, 0
		scanner._list_proc = function() return { "1" } end
		scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
		local ok, failure = pcall(isolated, function(servers)
			local ports = require("ai.engine.local_servers.ports")
			ports.scan_owned = scanner.scan_owned
			scanner._owned_process = function(_, _, options)
				during = servers.cancel()
				helpers.assert_eq(options.authorized(), false)
				return { started = true, cancel = function() cancelled = cancelled + 1; return false end,
					is_settled = function() return closed end }
			end
			helpers.assert_eq(servers.rescan(function() return true end), false)
			helpers.assert_eq(during, false)
			helpers.assert_true(cancelled > 0)
			helpers.assert_eq(servers.cancel(), false)
			closed = true
			helpers.assert_eq(servers.cancel(), true)
		end)
		scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
		assert(ok, failure)
	end)

	helpers.it("a cancel during owned scan construction prevents subsequent native acquisition", function()
		local scanner = require("ai.engine.local_servers.ports")
		local list, read_cmdline, timer, process = scanner._list_proc, scanner._read_cmdline,
			scanner._owned_timer, scanner._owned_process
		local starts, during = 0, nil
		local pids = {}; for i = 1, 129 do pids[i] = tostring(i) end
		scanner._read_cmdline = function() return nil end
		scanner._owned_timer = function() starts = starts + 1; error("must not arm a timer") end
		scanner._owned_process = function() starts = starts + 1; error("must not spawn a process") end
		local ok, failure = pcall(isolated, function(servers)
			local ports = require("ai.engine.local_servers.ports")
			ports.scan_owned = scanner.scan_owned
			scanner._list_proc = function() during = servers.cancel(); return pids end
			servers.rescan(function() return true end)
			helpers.assert_eq(during, false)
			helpers.assert_eq(starts, 0)
			helpers.assert_eq(servers.cancel(), true)
		end)
		scanner._list_proc, scanner._read_cmdline, scanner._owned_timer, scanner._owned_process = list, read_cmdline, timer, process
		assert(ok, failure)
	end)

	helpers.it("a cancel during rescan admission cannot acknowledge or launch a scan", function()
		isolated(function(servers)
			local ports, during, starts = require("ai.engine.local_servers.ports"), nil, 0
			local previous = ports.scan_owned
			ports.scan_owned = function() starts = starts + 1; error("must not launch") end
			local ok, failure = pcall(function()
				local result = servers.rescan(function()
					during = servers.cancel()
					return true
				end)
				helpers.assert_eq(during, false)
				helpers.assert_eq(result, false)
				helpers.assert_eq(starts, 0)
			end)
			ports.scan_owned = previous
			assert(ok, failure)
		end)
	end)

	helpers.it("a cancel during source capture fences the constructing rescan", function()
		isolated(function(servers, entries)
			local ports, capture = require("ai.engine.local_servers.ports"), entries.capture_source
			local previous, during, starts = ports.scan_owned, nil, 0
			ports.scan_owned = function() starts = starts + 1; error("must not launch") end
			entries.capture_source = function()
				during = servers.cancel()
				return capture()
			end
			local ok, failure = pcall(function()
				helpers.assert_eq(servers.rescan(function() return true end), false)
				helpers.assert_eq(during, false)
				helpers.assert_eq(starts, 0)
			end)
			ports.scan_owned, entries.capture_source = previous, capture
			assert(ok, failure)
		end)
	end)

	helpers.it("review-reentrant-cancel: new synchronously completed scan remains physical debt", function()
		isolated(function(servers)
			local ports = require("ai.engine.local_servers.ports")
			local prior, calls, old_closed, new_closed = ports.scan_owned, 0, false, false
			ports.scan_owned = function(entries, callback)
				calls = calls + 1
				if calls == 1 then
					return { cancel = function() old_closed = true; return true end,
						is_settled = function() return old_closed end }
				end
				local results = {}
				for _, entry in ipairs(entries) do results[entry.id] = { id = entry.id, running = false, pids = {} } end
				callback(results)
				return { cancel = function() return false end, is_settled = function() return new_closed end }
			end
			local ok, err = pcall(function()
				assert(servers.rescan(function() return true end, function()
					assert(servers.rescan(function() return true end))
				end))
				helpers.assert_eq(servers.cancel(), false, "a reentrant successor still owns physical cleanup")
				new_closed = true
			end)
			new_closed = true
			ports.scan_owned = prior
			assert(ok, err)
		end)
	end)


	helpers.it("review-reentrant-cancel: shutdown cannot ACK while a cancelled waiter executes", function()
		isolated(function(servers)
			local ports = require("ai.engine.local_servers.ports")
			local prior, closed, during = ports.scan_owned, false, nil
			ports.scan_owned = function()
				return { cancel = function() closed = true; return true end,
					is_settled = function() return closed end }
			end
			local ok, err = pcall(function()
				assert(servers.rescan(function() return true end, function() during = servers.shutdown() end))
				servers.cancel()
				helpers.assert_eq(during, false, "the waiter callback itself has not returned")
			end)
			ports.scan_owned = prior
			assert(ok, err)
		end)
	end)


	helpers.it("releases a waiter frame after its callback raises", function()
		isolated(function(servers)
			local ports = require("ai.engine.local_servers.ports")
			local prior, closed, during = ports.scan_owned, false, nil
			ports.scan_owned = function()
				return { cancel = function() closed = true; return true end,
					is_settled = function() return closed end }
			end
			local ok, failure = pcall(function()
				helpers.assert_true(servers.rescan(function() return true end, function()
					during = servers.shutdown()
					error("synthetic waiter failure")
				end))
				helpers.assert_eq(servers.cancel(), true)
				helpers.assert_eq(during, false)
				helpers.assert_eq(servers.shutdown(), true)
			end)
			ports.scan_owned = prior
			assert(ok, failure)
		end)
	end)

	helpers.it("a waiter failure diagnostic cannot acknowledge the active delivery", function()
		isolated(function(servers)
			local ports, logger = require("ai.engine.local_servers.ports"), require("core.logger.engine.shim")
			local prior, previous_error, closed, during = ports.scan_owned, logger.error, false, nil
			ports.scan_owned = function()
				return { cancel = function() return false end, is_settled = function() return closed end }
			end
			logger.error = function() during = servers.shutdown() end
			local ok, failure = pcall(function()
				helpers.assert_true(servers.rescan(function() return true end, function()
					error("synthetic waiter failure")
				end))
				helpers.assert_eq(servers.cancel(), false)
				closed = true
				helpers.assert_eq(servers.rescan(function() return true end), false)
				helpers.assert_eq(during, false)
				helpers.assert_eq(servers.shutdown(), true)
			end)
			ports.scan_owned, logger.error = prior, previous_error
			assert(ok, failure)
		end)
	end)

	helpers.it("a waiter retired by a new rescan cannot acknowledge its own active frame", function()
		isolated(function(servers)
			local ports = require("ai.engine.local_servers.ports")
			local prior, closed, during = ports.scan_owned, false, nil
			ports.scan_owned = function()
				return { cancel = function() return false end, is_settled = function() return closed end }
			end
			local ok, failure = pcall(function()
				helpers.assert_true(servers.rescan(function() return true end, function()
					during = servers.shutdown()
				end))
				helpers.assert_eq(servers.cancel(), false)
				closed = true
				helpers.assert_eq(servers.rescan(function() return true end), false)
				helpers.assert_eq(during, false)
				helpers.assert_eq(servers.shutdown(), true)
			end)
			ports.scan_owned = prior
			assert(ok, failure)
		end)
	end)

	helpers.it("keeps unknown native debt when an owned scanner constructor raises", function()
		isolated(function(servers, _, calls)
			local ports = require("ai.engine.local_servers.ports")
			local previous, pending = ports.scan_owned, nil
			local all_down = {}
			for _, id in ipairs(CATALOGUE.server_order) do all_down[id] = { running = false, pids = {} } end
			ports.scan_owned = function(_, callback) pending = callback; error("unknown native owner") end
			local ok, failure = pcall(function()
				helpers.assert_eq(servers.rescan(function() return true end), false)
				helpers.assert_eq(servers.shutdown(), false)
				pending(all_down)
				helpers.assert_eq(servers.shutdown(), false, "a logical callback cannot settle unknown native ownership")
				helpers.assert_eq(#calls, 0)
			end)
			ports.scan_owned = previous
			assert(ok, failure)
		end)
	end)

	helpers.it("joins a real port-scan process exit during server shutdown", function()
		local scanner, uv = require("ai.engine.local_servers.ports"), require("luv")
		local list, read_cmdline, process = scanner._list_proc, scanner._read_cmdline, scanner._owned_process
		scanner._list_proc = function() return { "1" } end
		scanner._read_cmdline = function() return "/usr/bin/omlx-server\0" end
		scanner._owned_process = function(_, _, options, callback)
			return require("core.process.adapters.owned_process").start("/bin/sleep", { "10" }, options, callback)
		end
		local ok, failure = pcall(isolated, function(servers)
			local ports = require("ai.engine.local_servers.ports")
			ports.scan_owned = scanner.scan_owned
			helpers.assert_true(servers.rescan(function() return true end))
			helpers.assert_eq(servers.shutdown(), false)
			for _ = 1, 2000 do
				uv.run("nowait")
				if servers.shutdown() then return end
				uv.sleep(1)
			end
			error("the actual process did not settle")
		end)
		scanner._list_proc, scanner._read_cmdline, scanner._owned_process = list, read_cmdline, process
		assert(ok, failure)
	end)

	helpers.it("joins a real port-scan timer close during server shutdown", function()
		local scanner, uv = require("ai.engine.local_servers.ports"), require("luv")
		local list, read_cmdline = scanner._list_proc, scanner._read_cmdline
		local pids = {}
		for i = 1, 129 do pids[i] = tostring(i) end
		scanner._list_proc = function() return pids end
		scanner._read_cmdline = function() return nil end
		local ok, failure = pcall(isolated, function(servers)
			local ports = require("ai.engine.local_servers.ports")
			ports.scan_owned = scanner.scan_owned
			helpers.assert_true(servers.rescan(function() return true end))
			helpers.assert_eq(servers.shutdown(), false)
			for _ = 1, 100 do uv.run("nowait"); if servers.shutdown() then return end end
			error("the actual timer close did not settle")
		end)
		scanner._list_proc, scanner._read_cmdline = list, read_cmdline
		assert(ok, failure)
	end)

	helpers.it("joins the actual owned port scanner timer on shutdown", function()
		local scanner = require("ai.engine.local_servers.ports")
		local list, read_cmdline, timer = scanner._list_proc, scanner._read_cmdline, scanner._owned_timer
		local pids, closed, cancelled = {}, false, 0
		for i = 1, 129 do pids[i] = tostring(i) end
		scanner._list_proc = function() return pids end
		scanner._read_cmdline = function() return nil end
		scanner._owned_timer = function()
			return { started = true, cancel = function() cancelled = cancelled + 1; return true end,
				is_settled = function() return closed end }
		end
		local ok, failure = pcall(isolated, function(servers, _, calls)
			local ports = require("ai.engine.local_servers.ports")
			ports.scan_owned = scanner.scan_owned
			local completions = {}
			helpers.assert_true(servers.rescan(function() return true end, function(changed)
				completions[#completions + 1] = changed
			end))
			helpers.assert_eq(servers.shutdown(), false)
			helpers.assert_true(cancelled > 0)
			helpers.assert_eq(completions, {})
			closed = true
			helpers.assert_eq(servers.shutdown(), true)
			helpers.assert_eq(completions, { false })
			helpers.assert_eq(#calls, 0)
		end)
		scanner._list_proc, scanner._read_cmdline, scanner._owned_timer = list, read_cmdline, timer
		assert(ok, failure)
	end)

	helpers.it("keeps the original native scan receipt methods after replacement", function()
		isolated(function(servers)
			local ports, closed = require("ai.engine.local_servers.ports"), false
			local prior = ports.scan_owned
			local receipt = { cancel = function() return false end, is_settled = function() return closed end }
			ports.scan_owned = function() return receipt end
			local ok, failure = pcall(function()
				helpers.assert_true(servers.rescan(function() return true end))
				receipt.is_settled = function() return true end
				helpers.assert_eq(servers.shutdown(), false)
				closed = true
				helpers.assert_eq(servers.shutdown(), true)
			end)
			ports.scan_owned = prior
			assert(ok, failure)
		end)
	end)

	helpers.it("retires a cancelled owned port scan without relying on its business callback", function()
		isolated(function(servers, _, calls)
			local ports = require("ai.engine.local_servers.ports")
			local prior, closed, cancelled, completions = ports.scan_owned, false, 0, {}
			ports.scan_owned = function()
				return { cancel = function() cancelled = cancelled + 1; return true end,
					is_settled = function() return closed end }
			end
			local ok, failure = pcall(function()
				helpers.assert_true(servers.rescan(function() return true end, function(changed)
					completions[#completions + 1] = changed
				end))
				helpers.assert_eq(servers.shutdown(), false)
				helpers.assert_true(cancelled > 0)
				helpers.assert_eq(completions, {})
				closed = true
				helpers.assert_eq(servers.shutdown(), true)
				helpers.assert_eq(completions, { false })
				helpers.assert_eq(#calls, 0)
			end)
			ports.scan_owned = prior
			assert(ok, failure)
		end)
	end)

	helpers.it("retains an uncertain port scan after its constructor raises", function()
		isolated(function(servers, _, calls)
			local ports = require("ai.engine.local_servers.ports")
			local previous, pending, completions = ports.scan, nil, {}
			local all_down = {}
			for _, id in ipairs(CATALOGUE.server_order) do all_down[id] = { running = false, pids = {} } end
			ports.scan = function(_, callback) pending = callback; error("constructor failed") end
			local ok, failure = pcall(function()
				helpers.assert_eq(servers.rescan(function() return true end, function(changed)
					completions[#completions + 1] = changed
				end), false)
				helpers.assert_eq(servers.cancel(), false, "a throwing constructor may have started a scan")
				helpers.assert_eq(servers.rescan(function() return true end), false)
				pending(all_down)
				helpers.assert_eq(completions, { false })
				helpers.assert_eq(#calls, 0)
				helpers.assert_eq(servers.cancel(), false, "callback alone cannot settle an unknown native receipt")
			end)
			ports.scan = previous
			assert(ok, failure)
		end)
	end)

	helpers.it("cancelling a pending port scan retains its callback and starts no probe", function()
		isolated(function(servers, _, calls)
			local ports = require("ai.engine.local_servers.ports")
			local previous, pending, completions = ports.scan, nil, {}
			local all_down = {}
			for _, id in ipairs(CATALOGUE.server_order) do all_down[id] = { running = false, pids = {} } end
			ports.scan = function(_, callback) pending = callback end
			local ok, failure = pcall(function()
				helpers.assert_true(servers.rescan(function() return true end, function(changed)
					completions[#completions + 1] = changed
				end))
				helpers.assert_eq(servers.cancel(), false, "a pending scan has not completed")
				helpers.assert_eq(servers.rescan(function() return true end), false,
					"a successor cannot borrow the cancelled scan")
				pending(all_down)
				helpers.assert_eq(servers.cancel(), true)
				helpers.assert_eq(completions, { false })
				helpers.assert_eq(#calls, 0)
			end)
			ports.scan = previous
			assert(ok, failure)
		end)
	end)

	helpers.it("retains a successor scan when an older inline scan subsequently raises", function()
		isolated(function(servers)
			local ports = require("ai.engine.local_servers.ports")
			local previous, earlier, later, starts, completed = ports.scan, nil, nil, 0, 0
			local all_down = {}
			for _, id in ipairs(CATALOGUE.server_order) do all_down[id] = { running = false, pids = {} } end
			ports.scan = function(_, callback)
				starts = starts + 1
				if starts == 1 then earlier = callback; callback(all_down); error("old scan failed") end
				later = callback
				return true
			end
			local ok, failure = pcall(function()
				servers.rescan(function() return true end, function()
					servers.rescan(function() return true end, function() completed = completed + 1 end)
				end)
				helpers.assert_eq(starts, 2)
				helpers.assert_type(later, "function")
				earlier(all_down)
				helpers.assert_eq(completed, 0, "an old duplicate cannot complete the successor")
				later(all_down)
				helpers.assert_eq(completed, 1)
			end)
			ports.scan = previous
			assert(ok, failure)
		end)
	end)

	for _, source in ipairs({ "port scan", "completion" }) do
		helpers.it("does not log private text from a local server " .. source .. " exception", function()
			isolated(function(servers, _, _, _, scan)
				for _, id in ipairs({ "omlx", "lmstudio", "llamacpp", "jan" }) do
					scan[id] = { running = false, pids = {} }
				end
				local ports, logger = require("ai.engine.local_servers.ports"), require("core.logger.engine.shim")
				local original_scan, original_error, messages = ports.scan, logger.error, {}
				if source == "port scan" then ports.scan = function() error("synthetic-private-token") end end
				logger.error = function(_, fmt, ...) messages[#messages + 1] = string.format(fmt, ...) end
				local called, result = pcall(servers.rescan, function() return true end,
					function() if source == "completion" then error("synthetic-private-token") end end)
				ports.scan, logger.error = original_scan, original_error
				assert(called, result)
				helpers.assert_eq(result, source == "completion")
				helpers.assert_true(#messages > 0)
				for _, message in ipairs(messages) do
					helpers.assert_true(not message:find("synthetic-private-token", 1, true))
				end
			end)
		end)
	end

	helpers.it("a closed model page receives no invalid local address error", function()
		isolated(function()
			local live, errors = true, 0
			local llm = { get_backend = function() return "ollama" end,
				can_configure_local_servers = function() return true end, is_enabled = function() return true end }
			local dialogs = { prompt = function() live = false; return "not a URL" end,
				error = function() errors = errors + 1 end }
			local rows = require("ai.ui.menu.local_server_rows").rows(llm, dialogs, function() end,
				{ is_paused = function() return false end, page_current = function() return live end })
			local address = find(rows, require("core.i18n.engine.i18n").get("menu.llm.local_servers.other_address"))
			helpers.assert_true(address ~= nil)
			helpers.assert_eq(address.items[1].action(), false)
			helpers.assert_eq(errors, 0)
		end)
	end)

	helpers.it("a closed model page refuses a local server address entered by its old dialog", function()
		isolated(function(servers, entries, calls)
			local live, setters = true, 0
			local llm = { get_backend = function() return "ollama" end,
				can_configure_local_servers = function() return true end, is_enabled = function() return true end,
				set_backend = function() setters = setters + 1; return true end }
			local dialogs = { prompt = function() live = false; return "http://localhost:9876/v1" end,
				error = function() end }
			local rows = require("ai.ui.menu.local_server_rows").rows(llm, dialogs, function() end,
				{ is_paused = function() return false end, page_current = function() return live end })
			local address = find(rows, require("core.i18n.engine.i18n").get("menu.llm.local_servers.other_address"))
			helpers.assert_true(address ~= nil)
			helpers.assert_eq(address.items[1].action(), false)
			helpers.assert_eq(servers.target("omlx").base_url, "http://127.0.0.1:8000/v1")
			helpers.assert_nil(entries.active())
			helpers.assert_eq(setters, 0)
		end)
	end)

	helpers.it("a scope acquired during a blocking address prompt refuses publication and any backend setter", function()
		isolated(function(servers,entries,calls)
			local allowed,setters=true,0
			local llm={get_backend=function() return "ollama" end,can_configure_local_servers=function() return allowed end,is_enabled=function() return true end,
				set_backend=function() setters=setters+1;return true end}
			local dialogs={prompt=function() allowed=false;return "http://localhost:9876/v1" end,error=function() end}
			local Rows=require("ai.ui.menu.local_server_rows")
			local rows=Rows.rows(llm,dialogs,function() end,{is_paused=function() return false end})
			local address=find(rows,require("core.i18n.engine.i18n").get("menu.llm.local_servers.other_address"))
			helpers.assert_true(address~=nil)
			local result=address.items[1].action()
			helpers.assert_eq(result,false)
			helpers.assert_eq(servers.target("omlx").base_url,"http://127.0.0.1:8000/v1")
			helpers.assert_nil(entries.active())
			helpers.assert_eq(setters,0)
			helpers.assert_eq(#calls,4)
		end)
	end)
end)


helpers.describe("local selection terminal acknowledgement", function()
	helpers.it("a scope acquired after JSON ACK leaves a saved model without acquiring the backend setter", function()
		isolated(function(servers,entries,calls,path)
			local allowed,setters=true,0
			local llm={get_backend=function() return "ollama" end,can_configure_local_servers=function() return allowed end,is_enabled=function() return true end,
				set_backend=function() setters=setters+1;return true end}
			local Rows=require("ai.ui.menu.local_server_rows")
			local function build() return Rows.rows(llm,{prompt=function() return nil end,error=function() end},function() end,
				{is_paused=function() return false end}) end
			build();for _,call in ipairs(calls) do call.finish(models("owned-model")) end
			local row=find(build(),"owned-model")
			local rename=os.rename
			os.rename=function(from,to)
				local ok,err=rename(from,to)
				if to==path and ok==true then allowed=false end
				return ok,err
			end
			local ok,result=pcall(row.action)
			os.rename=rename
			if not ok then error(result,0) end
			helpers.assert_eq(result.saved,true)
			helpers.assert_eq(result.selected,false)
			helpers.assert_eq(setters,0,"late admission refusal occurs before the real setter")
			helpers.assert_eq(entries.active().model,"owned-model")
			local reader=assert(io.open(path,"rb")); local bytes=reader:read("*a"); reader:close()
			local raw=Json.decode_lossless(bytes)
			helpers.assert_eq(raw.active_id,entries.active().id,"the acknowledged JSON is not fictitiously compensated")
		end)
	end)
	helpers.it("late native refusal and bad JSON cannot publish models or retry through another owner", function()
		isolated(function(servers,_,calls)
			servers.rescan(function() return true end)
			calls[1].finish({ok=false,status=0,body="",error="timeout"})
			calls[2].finish({ok=true,status=200,body='{"data":[{}]}'})
			calls[3].finish({ok=true,status=302,body='{"data":[{"id":"foreign"}]}'})
			calls[4].finish(models())
			helpers.assert_eq(servers.result("omlx").status,"down")
			helpers.assert_eq(servers.result("lmstudio").status,"down")
			helpers.assert_eq(servers.result("llamacpp").status,"down")
			helpers.assert_eq(servers.result("jan").status,"up")
			helpers.assert_eq(#servers.result("jan").models,0)
			helpers.assert_eq(#calls,4)
		end)
	end)
end)


helpers.describe("local discovery constructor and terminal source fences", function()
	helpers.it("a reentrant sweep cannot replace a native GET still constructing or continue the older dispatch loop", function()
		isolated(function(servers,_,calls)
			local reentered=false
			calls.before_return=function()
				if not reentered then reentered=true; servers.rescan(function() return true end) end
			end
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,4,"one old constructing request and three current independent owners")
			helpers.assert_eq(calls[1].cancelled,1)
			calls[1].finish(models("obsolete"))
			helpers.assert_eq(#calls,5,"the exact same-provider successor waits for physical retirement")
			for index=2,5 do calls[index].finish(models("fresh")) end
			helpers.assert_eq(servers.result("omlx").models[1],"fresh")
		end)
	end)
	helpers.it("private disk drift after native acquisition refuses every old positive response", function()
		isolated(function(servers,_,calls,path)
			local published=0
			servers.rescan(function() return true end,function() published=published+1 end)
			local writer=assert(io.open(path,"wb"));writer:write('{"version":2,"entries":[]}');writer:close()
			for _,call in ipairs(calls) do call.finish(models("foreign-old-model")) end
			helpers.assert_eq(published,1,"the finished joint negative verdict remains observable")
			helpers.assert_eq(#servers.detected(),0)
			for _,id in ipairs(probed(servers)) do helpers.assert_eq(servers.result(id).status,"down") end
		end)
	end)
end)

helpers.describe("Configured generic loopback discovery (local-configured-affinity)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("probes and persists the originating " .. provider .. " row (local-configured-affinity)", function()
			isolated(function(servers, entries, calls, path)
				local entry = assert(entries.add({ provider = provider, label = "Personal label", model = "before",
					token = "inert-token", base_url = "http://127.0.0.1:8000/v1/" }))
				helpers.assert_eq(servers.target("omlx").entry_id, entry.id)
				helpers.assert_true(servers.rescan(function() return true end))
				helpers.assert_eq(calls[1].url, "http://127.0.0.1:8000/v1/models")
				helpers.assert_eq(calls[1].headers.Authorization, "Bearer inert-token")
				helpers.assert_nil(calls[2].headers.Authorization, "a configured credential never crosses catalogue origins")
				-- The entry's address is also vLLM's default address: the entry belongs
				-- to the address's default row (oMLX) alone, so vLLM is not probed
				helpers.assert_eq(#calls, 4)
				helpers.assert_eq(servers.target("vllm").entry_id, nil)
				calls[1].finish({ ok = true, status = 200, body = '{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"omlx"}]}' })
				for index = 2, 4 do calls[index].finish({ ok = false, status = 0, body = "" }) end
				local receipt = servers.capture("omlx")
				local saved = assert(servers.apply(receipt, { model = "mlx-community/Qwen3-8B-4bit" }, function() return true end))
				helpers.assert_true(saved.saved); helpers.assert_eq(saved.entry.id, entry.id)
				helpers.assert_eq(saved.entry.provider, provider); helpers.assert_eq(saved.entry.label, "Personal label")
				helpers.assert_eq(#entries.list(), 1)
				local file = assert(io.open(path, "rb")); local raw = assert(Json.decode(file:read("*a"))); file:close()
				helpers.assert_eq(raw.entries[1].provider, provider); helpers.assert_eq(raw.entries[1].id, entry.id)
				helpers.assert_eq(raw.entries[1].model, "mlx-community/Qwen3-8B-4bit")
			end)
		end)
	end
end)

helpers.describe("Configured explicit loopback discovery views (local-configured-view)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("discovers a nondefault " .. provider .. " address without rebranding its identity (local-configured-view)", function()
			isolated(function(servers, entries, calls, path)
				local entry = assert(entries.add({provider=provider,label="Personal generic",model="before",token="",
					base_url="http://127.0.0.1:54321/v1"}))
				local id="configured:"..entry.id
				helpers.assert_true(servers.rescan(function() return true end))
				helpers.assert_eq(#calls,5,"the explicit configured loopback source is appended after the four declared defaults")
				helpers.assert_eq(table.concat(servers.order(),","),table.concat(CATALOGUE.server_order,",")..","..id)
				helpers.assert_eq(calls[5].url,"http://127.0.0.1:54321/v1/models")
				helpers.assert_nil(calls[5].headers.Authorization)
				for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
				calls[5].finish({ok=true,status=200,body='{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"omlx"}]}'})
				helpers.assert_eq(servers.result(id).models[1],"mlx-community/Qwen3-8B-4bit")
				helpers.assert_eq(servers.result("omlx").status,"down","generic models metadata does not establish a catalogue identity")
				local saved=assert(servers.apply(servers.capture(id),{model="mlx-community/Qwen3-8B-4bit"},function() return true end))
				helpers.assert_true(saved.saved); helpers.assert_eq(saved.entry.provider,provider)
				helpers.assert_eq(saved.entry.id,entry.id); helpers.assert_eq(saved.entry.label,"Personal generic")
				helpers.assert_eq(#entries.list(),1)
				local reader=assert(io.open(path,"rb"));local raw=assert(Json.decode_lossless(reader:read("*a")));reader:close()
				helpers.assert_eq(raw.entries[1].provider,provider);helpers.assert_eq(raw.entries[1].id,entry.id)
			end)
		end)
	end
end)

helpers.describe("Configured discovery view custody (local-configured-view)", function()
	helpers.it("retains removed configured native owners until exact physical retirement (local-configured-view)", function()
		isolated(function(servers,entries,calls)
			local entry=assert(entries.add({provider="openai",label="Personal",model="before",token="secret",
				base_url="http://localhost:54321/v1"}))
			local id="configured:"..entry.id
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,5);helpers.assert_eq(calls[5].headers.Authorization,"Bearer secret")
			local receipt=servers.capture(id)
			helpers.assert_true(entries.remove(entry.id))
			servers.rescan(function() return true end)
			helpers.assert_eq(#servers.order(),#CATALOGUE.server_order)
			helpers.assert_eq(calls[5].cancelled,1,"removed source does not lose its original physical debt")
			helpers.assert_eq(servers.is_current(receipt),false)
			helpers.assert_nil(servers.apply(receipt,{model="late"},function() return true end))
			calls[5].callback(models("obsolete"))
			helpers.assert_nil(servers.result(id))
			for index=1,4 do calls[index].finish(models("old")) end
			helpers.assert_eq(#calls,9,"only the four retained catalogue owners can reacquire")
			for index=6,9 do calls[index].finish(models("fresh")) end
			helpers.assert_eq(servers.result("omlx").models[1],"fresh")
			helpers.assert_eq(servers.cancel(),false,"the removed configured owner still carries close debt")
			calls[5].finish(models("obsolete"))
			helpers.assert_true(servers.cancel())
		end)
	end)
	helpers.it("preserves foreign private fields and row positions through configured selection (local-configured-view)", function()
		isolated(function(servers,entries,calls,path)
			local writer=assert(io.open(path,"wb"))
			writer:write('{"version":1,"foreign":{"enabled":false},"entries":[{"id":"foreign","provider":"future","token":"foreign-key","label":"Foreign","model":"untouched","base_url":"https://example.invalid/v1","custom":[1,2]},{"id":"personal","provider":"openai_compat","label":"My local","model":"before","token":"","base_url":"http://[::1]:54321/v1","custom":{"null":null,"flag":false}}]}');writer:close()
			entries._set_path_for_test(path)
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,5)
			for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
			calls[5].finish(models("mlx-community/Qwen3-8B-4bit"))
			local saved=assert(servers.apply(servers.capture("configured:personal"),{model="mlx-community/Qwen3-8B-4bit"},function() return true end))
			helpers.assert_eq(saved.entry.id,"personal");helpers.assert_eq(saved.entry.provider,"openai_compat")
			local reader=assert(io.open(path,"rb"));local raw=assert(Json.decode_lossless(reader:read("*a")));reader:close()
			helpers.assert_eq(raw.foreign.enabled,false);helpers.assert_eq(raw.entries[1].id,"foreign")
			helpers.assert_eq(raw.entries[1].custom[2],2);helpers.assert_eq(raw.entries[2].id,"personal")
			helpers.assert_eq(raw.entries[2].custom.flag,false);helpers.assert_true(Json.is_null(raw.entries[2].custom.null))
			entries._set_path_for_test(path)
			helpers.assert_eq(entries.active().model,"mlx-community/Qwen3-8B-4bit")
		end)
	end)
	helpers.it("authentication, malformed bodies, pause and changed configured identities refuse models (local-configured-view)", function()
		isolated(function(servers,entries,calls)
			local first=assert(entries.add({provider="openai",label="First",model="before",token="",base_url="http://127.0.0.1:54321/v1"}))
			local second=assert(entries.add({provider="openai_compat",label="Second",model="before",token="key",base_url="http://localhost:54322/v1"}))
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,6)
			for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
			calls[5].finish({ok=false,status=401,body='{"error":"key required"}'})
			calls[6].finish({ok=true,status=200,body='{"data":{}}'})
			helpers.assert_eq(servers.result("configured:"..first.id).status,"needs_key")
			helpers.assert_eq(servers.result("configured:"..second.id).status,"down")
			local receipt=servers.capture("configured:"..first.id)
			helpers.assert_nil(servers.apply(receipt,{token="new"},function() return false end))
			helpers.assert_eq(entries.get(first.id).token,"")
			servers.rescan(function() return true end)
			helpers.assert_true(entries.remove(first.id))
			for index=7,12 do calls[index].finish(models("obsolete")) end
			helpers.assert_nil(servers.apply(receipt,{model="obsolete"},function() return true end))
			helpers.assert_nil(entries.get(first.id))
		end)
	end)
end)

helpers.describe("Configured native menu publication (local-configured-view)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("selects a checked originating "..provider.." menu row and fences held callbacks (local-configured-view)",function()
			isolated(function(servers,entries,calls)
				local entry=assert(entries.add({provider=provider,label="Personal",model="before",token="",
					base_url="http://127.0.0.1:54321/v1"}))
				local backend,writes="ollama",0
				local llm={get_backend=function() return backend end,can_configure_local_servers=function() return true end,is_enabled=function() return true end,
					set_backend=function(value,admit) if not admit() then return false end;backend=value;writes=writes+1;return true end}
				local Rows=require("ai.ui.menu.local_server_rows")
				local context={is_paused=function() return false end}
				local function build() return Rows.rows(llm,{prompt=function() return nil end,error=function() end},function() end,context) end
				build()
				for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
				calls[5].finish(models("opaque/local-model"))
				local held=find(build(),"opaque/local-model")
				helpers.assert_true(held and type(held.action)=="function")
				local outcome=held.action()
				helpers.assert_true(outcome.saved);helpers.assert_true(outcome.selected)
				helpers.assert_eq(backend,"api");helpers.assert_eq(writes,1)
				helpers.assert_eq(entries.active().id,entry.id);helpers.assert_eq(entries.active().provider,provider)
				for index=6,9 do calls[index].finish({ok=false,status=0,body=""}) end
				calls[10].finish(models("opaque/local-model"))
				local current=find(build(),"opaque/local-model")
				helpers.assert_true(current.checked)
				helpers.assert_eq(held.action(),false,"old source receipt cannot repeat a committed selection")
				servers.cancel()
				helpers.assert_eq(current.action(),false,"explicit cancellation fences displayed configured choices")
				helpers.assert_eq(writes,1)
			end)
		end)
	end
	helpers.it("moves an edited configured address into its canonical view while retaining the same source row (local-configured-view)",function()
		isolated(function(servers,entries,calls)
			local entry=assert(entries.add({provider="openai",label="Personal",model="before",token="",
				base_url="http://127.0.0.1:54321/v1"}))
			servers.rescan(function() return true end)
			for _,call in ipairs(calls) do call.finish(models("model")) end
			local id="configured:"..entry.id
			local saved=assert(servers.apply(servers.capture(id),{base_url="http://localhost:8000/v1"},function() return true end))
			helpers.assert_eq(saved.entry.id,entry.id);helpers.assert_eq(saved.entry.provider,"openai")
			helpers.assert_eq(#servers.order(),#CATALOGUE.server_order);helpers.assert_eq(servers.target("omlx").entry_id,entry.id)
			helpers.assert_nil(servers.target(id));helpers.assert_eq(#entries.list(),1)
		end)
	end)
end)

helpers.describe("Native discovery infrastructure receipts (local-probe-unavailable)",function()
	for _, failure in ipairs({"throw","unsupported","dead_start","observation_false","observation_throw"}) do
		helpers.it("reports native "..failure.." as unavailable while retaining cleanup ownership (local-probe-unavailable)",function()
			isolated(function(servers,_,calls)
				local http=package.loaded["core.network.adapters.http_client"]
				local original=http.get_owned
				http.get_owned=function(url,headers,options,callback)
					if failure=="throw" then error("actual native construction refused") end
					if failure=="unsupported" then return {} end
					local operation=original(url,headers,options,callback)
					if failure=="dead_start" then
						operation.started=false
						callback({ok=false,status=0,body="",error="native admission refused"})
					elseif failure=="observation_false" then operation.on_settled=function() return false end
					elseif failure=="observation_throw" then operation.on_settled=function() error("native settlement registration failed") end end
					return operation
				end
				helpers.assert_true(servers.rescan(function() return true end))
				helpers.assert_eq(servers.is_sweeping(),false)
				helpers.assert_eq(servers.result("omlx").status,"unavailable")
				helpers.assert_eq(#servers.detected(),0)
				local rows=require("ai.ui.menu.local_server_rows").rows({get_backend=function() return "ollama" end,
					can_configure_local_servers=function() return true end,is_enabled=function() return true end}, {},function() end,{is_paused=function() return false end})
				local failed=find(rows,require("core.i18n.engine.i18n").get("healthcheck.status.failed"))
				helpers.assert_true(failed and failed.disabled,"actual menu exposes infrastructure failure")
				helpers.assert_eq(#rows,5,"one failure row replaces the no-server summary")
				local catalogue=require("core.text.engine.json").decode(assert(io.open(require("core.fs.engine.paths").shared("ai/data/local_servers.json"),"rb")):read("*a"))
				local labels={}
				for _,id in ipairs(catalogue.server_order) do labels[#labels+1]=catalogue.servers[id].label end
				local none=require("core.i18n.engine.i18n").get("menu.llm.local_servers.none_detected")
				helpers.assert_nil(find(rows,none),"infrastructure refusal cannot become a no-server claim")
				helpers.assert_eq(servers.cancel(),false,"no flag acknowledges still retained native debt")
				if failure~="throw" and failure~="unsupported" then
					for _,call in ipairs(calls) do call.finish(models("obsolete")) end
					helpers.assert_true(servers.cancel(),"actual settlement, including polling after observer refusal, retires exact owners")
				end
			end)
		end)
	end
	helpers.it("keeps ordinary connection refusal, malformed JSON and HTTP authentication distinct (local-probe-unavailable)",function()
		isolated(function(servers,_,calls)
			servers.rescan(function() return true end)
			calls[1].finish({ok=false,status=0,body="",error="connection refused"})
			calls[2].finish({ok=true,status=200,body='{"error":"constructor failure","probe_error":true,"data":{}}'})
			calls[3].finish({ok=false,status=401,body='{"error":"key required","probe_error":true}'})
			calls[4].finish({ok=true,status=200,body='{"data":[{"id":"valid-model"}],"probe_error":true}'})
			helpers.assert_eq(servers.result("omlx").status,"down")
			helpers.assert_eq(servers.result("lmstudio").status,"down")
			helpers.assert_eq(servers.result("llamacpp").status,"needs_key")
			helpers.assert_eq(servers.result("jan").status,"up")
			helpers.assert_eq(servers.result("jan").models[1],"valid-model","foreign body flags never become native receipts")
		end)
	end)
end)

helpers.describe("Native synchronous discovery ownership (local-probe-unavailable)",function()
	helpers.it("acknowledges a zero-resource dead-start refusal without replaying its body (local-probe-unavailable)",function()
		isolated(function(servers)
			package.loaded["core.network.adapters.http_client"].get_owned=function(_,_,_,callback)
				local operation={started=false}
				function operation:is_settled() return true end
				function operation:cancel() return true end
				function operation:on_settled(listener) listener();return true end
				callback(models("never-acquired"))
				return operation
			end
			servers.rescan(function() return true end)
			helpers.assert_eq(servers.result("omlx").status,"unavailable")
			helpers.assert_eq(#servers.detected(),0)
			helpers.assert_true(servers.cancel(),"actual settled receipt acknowledges no native resources")
		end)
	end)
	helpers.it("preserves a synchronously completed valid response before retirement observation (local-probe-unavailable)",function()
		isolated(function(servers,_,calls)
			calls.before_return=function(call) call.finish(models("synchronous-model")) end
			servers.rescan(function() return true end)
			helpers.assert_eq(servers.is_sweeping(),false)
			helpers.assert_eq(servers.result("omlx").status,"up")
			helpers.assert_eq(servers.result("omlx").models[1],"synchronous-model")
			helpers.assert_true(servers.cancel())
		end)
	end)
	helpers.it("keeps a native dead-start after admission loss as a refused stale source (local-probe-unavailable)",function()
		isolated(function(servers,_,calls)
			local allowed=true
			calls.before_return=function(call)
				allowed=false;call.operation.started=false
				call.callback({ok=false,status=0,body="",error="dispatch refused"})
			end
			servers.rescan(function() return allowed end)
			helpers.assert_eq(servers.result("omlx").status,"down","lost scope cannot publish even a native infrastructure verdict")
			helpers.assert_eq(#calls,1,"lost scope fences later acquisitions")
			calls[1].finish(models("obsolete"))
			helpers.assert_true(servers.cancel())
		end)
	end)
end)

helpers.describe("Native empty models presentation (local-empty-models)",function()
	helpers.it("keeps literal empty OpenAI lists reachable with disabled native no-models rows (local-empty-models)",function()
		isolated(function(servers,entries,calls)
			local entry=assert(entries.add({provider="openai_compat",label="Personal",model="before",token="",
				base_url="http://127.0.0.1:54321/v1"}))
			local setters=0
			local llm={get_backend=function() return "ollama" end,can_configure_local_servers=function() return true end,is_enabled=function() return true end,
				set_backend=function() setters=setters+1;return true end}
			local Rows=require("ai.ui.menu.local_server_rows")
			local function build() return Rows.rows(llm,{},function() end,{is_paused=function() return false end}) end
			build()
			for _,call in ipairs(calls) do call.finish({ok=true,status=200,body='{"object":"list","data":[]}'}) end
			helpers.assert_eq(#servers.detected(),5)
			for _,id in ipairs(probed(servers)) do
				helpers.assert_eq(servers.result(id).status,"up");helpers.assert_eq(#servers.result(id).models,0)
				helpers.assert_nil(servers.apply(servers.capture(id),{model="invented"},function() return true end))
			end
			local count=0
			local label=require("core.i18n.engine.i18n").get("menu.llm.local_servers.no_models")
			for _,row in ipairs(build()) do
				for _,child in ipairs(row.items or {}) do
					if child.label==label then
						count=count+1;helpers.assert_true(child.disabled);helpers.assert_nil(child.action)
					end
				end
			end
			helpers.assert_eq(count,5);helpers.assert_eq(setters,0)
			helpers.assert_eq(entries.get(entry.id).model,"before")
		end)
	end)
	for _,control in ipairs({
		{label="object instead of array",status=200,body='{"object":"list","data":{}}'},
		{label="array root",status=200,body='[{"object":"list","data":[]}]'},
		{label="HTTP 404",status=404,body='{"object":"list","data":[]}'},
	}) do
		helpers.it("keeps "..control.label.." down without reporting infrastructure failure (local-empty-models)",function()
			isolated(function(servers,_,calls)
				servers.rescan(function() return true end)
				for _,call in ipairs(calls) do call.finish({ok=control.status==200,status=control.status,body=control.body}) end
				for _,id in ipairs(probed(servers)) do helpers.assert_eq(servers.result(id).status,"down") end
				helpers.assert_eq(#servers.detected(),0)
				local rows=require("ai.ui.menu.local_server_rows").rows({get_backend=function() return "ollama" end,
					can_configure_local_servers=function() return true end,is_enabled=function() return true end},{},function() end,{is_paused=function() return false end})
				helpers.assert_nil(find(rows,require("core.i18n.engine.i18n").get("healthcheck.status.failed")))
			end)
		end)
	end
end)

helpers.describe("Private discovery cache origin (local-cache-identity)",function()
	for _,change in ipairs({"url","provider","token","root_metadata","foreign_row","same_bytes_reload"}) do
		helpers.it("refreshes actual menu cache after same-ID "..change.." source change (local-cache-identity)",function()
			isolated(function(servers,entries,calls,path)
				local entry=assert(entries.add({provider="openai",label="Personal",model="before",token="initial-token",
					base_url="http://127.0.0.1:54321/v1"}))
				local id="configured:"..entry.id
				local Rows=require("ai.ui.menu.local_server_rows")
				local llm={get_backend=function() return "ollama" end,can_configure_local_servers=function() return true end,is_enabled=function() return true end}
				local function build() return Rows.rows(llm,{},function() end,{is_paused=function() return false end}) end
				build()
				for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
				calls[5].finish(models("old-server-model"))
				helpers.assert_true(find(build(),"old-server-model")~=nil)
				local held=servers.capture(id)
				local reader=assert(io.open(path,"rb"));local bytes=reader:read("*a");reader:close()
				local raw=assert(Json.decode_lossless(bytes))
				if change=="url" then raw.entries[1].base_url="http://127.0.0.1:54322/v1"
				elseif change=="provider" then raw.entries[1].provider="openai_compat"
				elseif change=="token" then raw.entries[1].token="replacement-token"
				elseif change=="root_metadata" then raw.foreign={marker="replacement"}
				elseif change=="foreign_row" then raw.entries[2]={id="foreign",provider="future",label="Foreign",model="opaque",token="foreign-key",base_url="https://example.invalid/v1"} end
				local writer=assert(io.open(path,"wb"));writer:write(change=="same_bytes_reload" and bytes or Json.encode(raw));writer:close()
				entries._set_path_for_test(path)
				local rows=build()
				helpers.assert_nil(find(rows,"old-server-model"),"same-ID source change cannot present the previous server's cached model")
				helpers.assert_eq(#calls,10,"actual rows refresh before the cache age decision")
				helpers.assert_nil(servers.result(id),"new source receipts cannot inherit an old verdict")
				helpers.assert_nil(servers.apply(held,{model="old-server-model"},function() return true end))
				helpers.assert_nil(servers.apply(servers.capture(id),{model="old-server-model"},function() return true end))
				calls[5].callback(models("obsolete-late"))
				for index=6,9 do calls[index].finish({ok=false,status=0,body=""}) end
				calls[10].finish(models("current-server-model"))
				helpers.assert_true(find(build(),"current-server-model")~=nil)
				helpers.assert_eq(servers.result(id).models[1],"current-server-model")
				helpers.assert_eq(entries.get(entry.id).model,"before")
			end)
		end)
	end
end)

helpers.describe("Same-ID native cache retirement (local-cache-identity)",function()
	helpers.it("retains exact native cleanup debt during a same-ID credential-source refresh (local-cache-identity)",function()
		isolated(function(servers,entries,calls,path)
			local entry=assert(entries.add({provider="openai",label="Personal",model="before",token="initial",
				base_url="http://127.0.0.1:54321/v1"}))
			local id="configured:"..entry.id
			local Rows=require("ai.ui.menu.local_server_rows")
			local function build() return Rows.rows({get_backend=function() return "ollama" end,
				can_configure_local_servers=function() return true end,is_enabled=function() return true end},{},function() end,{is_paused=function() return false end}) end
			build()
			for index=1,4 do calls[index].finish({ok=false,status=0,body=""}) end
			calls[5].finish(models("old-model"))
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls,10)
			local reader=assert(io.open(path,"rb"));local raw=assert(Json.decode_lossless(reader:read("*a")));reader:close()
			raw.entries[1].token="replacement"
			local writer=assert(io.open(path,"wb"));writer:write(Json.encode(raw));writer:close()
			entries._set_path_for_test(path)
			helpers.assert_nil(find(build(),"old-model"))
			helpers.assert_eq(#calls,10,"new jobs wait behind five exact original native owners")
			for index=6,10 do helpers.assert_eq(calls[index].cancelled,2,"source fencing and successor admission each request exact cancellation") end
			calls[10].callback(models("obsolete"))
			helpers.assert_nil(servers.result(id))
			calls[6].finish(models("obsolete"))
			helpers.assert_eq(#calls,11,"only one physically retired catalogue owner admits its successor")
			for index=7,10 do calls[index].finish(models("obsolete")) end
			helpers.assert_eq(#calls,15)
			helpers.assert_eq(calls[15].headers.Authorization,"Bearer replacement")
			for index=11,14 do calls[index].finish({ok=false,status=0,body=""}) end
			calls[15].finish(models("new-model"))
			helpers.assert_true(find(build(),"new-model")~=nil)
			helpers.assert_nil(find(build(),"obsolete"))
		end)
	end)
end)

helpers.describe("Scripted startup discovery transport custody (startup-local-http-edge)",function()
	helpers.it("models absent default listeners through acknowledged operations rather than disabling dispatch (startup-local-http-edge)",function()
		isolated(function(servers,_,calls)
			local port=package.loaded["core.network.adapters.http_client"]
			local _,probes=require("tests.support.owned_http_fixture").local_discovery(port)
			local logger=require("core.logger.engine.shim")
			local previous,errors=logger.error,{}
			logger.error=function(_,message) errors[#errors+1]=message end
			local ok,err=pcall(function()
				helpers.assert_true(servers.rescan(function() return true end))
				helpers.assert_eq(servers.is_sweeping(),false)
				helpers.assert_eq(#probes,4);helpers.assert_eq(#calls,0,"only local discovery owns the controlled edge")
				for index,id in ipairs({"omlx","lmstudio","llamacpp","jan"}) do
					helpers.assert_eq(probes[index].id,id)
					helpers.assert_eq(probes[index].owner,"llm_local_server:"..id)
					helpers.assert_eq(servers.result(id).status,"down","scripted connection refusal is not native dispatch unavailability")
				end
				helpers.assert_eq(#errors,0,"faithful startup transport creates no infrastructure error")
				helpers.assert_true(servers.cancel(),"all software operation receipts acknowledge their exact retirement")
			end)
			logger.error=previous
			if not ok then error(err,0) end
		end)
	end)
	helpers.it("forwards every unrelated owner with its original arguments and operation identity (startup-local-http-edge)",function()
		isolated(function(_,_,calls)
			local port=package.loaded["core.network.adapters.http_client"]
			require("tests.support.owned_http_fixture").local_discovery(port)
			local headers,options,callback={Authorization="inert"},{owner="original-updater"},function() end
			local operation=port.get_owned("https://example.invalid/owned",headers,options,callback)
			helpers.assert_eq(#calls,1);helpers.assert_eq(operation,calls[1].operation)
			helpers.assert_eq(calls[1].headers,headers);helpers.assert_eq(calls[1].options,options)
			helpers.assert_eq(calls[1].callback,callback);helpers.assert_eq(calls[1].url,"https://example.invalid/owned")
			calls[1].finish({ok=false,status=0,body=""})
		end)
	end)
end)
