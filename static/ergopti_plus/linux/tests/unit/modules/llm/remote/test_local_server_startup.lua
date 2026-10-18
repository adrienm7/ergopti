--- tests/unit/modules/llm/remote/test_local_server_startup.lua

--- ==============================================================================
--- MODULE: Local Discovery Event-Loop Admission
--- DESCRIPTION:
--- Keeps actual discovery source and native event-loop ownership while controlling
--- only HTTP completion. Startup preparation cannot spend an unpumped HTTP budget.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Restores every replaced module and private source after one isolated case.
--- @param body function Receives servers, entries, HTTP calls and the actual loop.
local function isolated(body)
	local names = { "modules.llm.local_servers", "modules.llm.api_entries", "modules.llm.api_remote",
		"adapters.http_client", "adapters.event_loop" }
	local previous, calls = {}, {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local path = os.tmpname(); os.remove(path)
	package.loaded["adapters.http_client"] = { get_owned = function(url, headers, options, callback)
		local call = { url = url, headers = headers, options = options, callback = callback, listeners = {}, cancelled = 0 }
		local operation = { started = true }
		function operation:is_settled() return call.settled == true end
		function operation:on_settled(fn) call.listeners[#call.listeners + 1] = fn; return true end
		function operation:cancel() call.cancelled = call.cancelled + 1; return call.settled == true end
		function call.finish()
			call.settled = true
			if call.cancelled == 0 then callback({ ok = true, status = 200,
				body = Json.encode({ data = Json.array({ { id = "current-model" } }) }) }) end
			local listeners = call.listeners; call.listeners = {}
			for _, fn in ipairs(listeners) do fn() end
		end
		call.operation = operation; calls[#calls + 1] = call
		if calls.on_acquire then calls.on_acquire(call) end
		return operation
	end }
	local entries = require("modules.llm.api_entries")
	entries._set_path_for_test(path)
	entries._set_private_create_for_test(function(stage, text)
		local out = assert(io.open(stage, "wb")); out:write(text); out:close(); return true
	end)
	local servers, loop = require("modules.llm.local_servers"), require("adapters.event_loop")
	local ok, err = pcall(body, servers, entries, calls, loop, path)
	servers.shutdown()
	for _, call in ipairs(calls) do if not call.settled then call.finish() end end
	loop.stop()
	os.remove(path); os.remove(path .. ".tmp"); os.remove(path .. ".corrupt")
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

--- Runs the real native idle callback before its deferred acquisition batch.
--- @param loop table Actual EventLoop module.
--- @param first function|nil First keyboard-pump observation.
local function tick(loop, first)
	local turns = 0
	loop.run({ onIdle = function()
		turns = turns + 1
		if turns == 1 then if first then first() end else loop.stop() end
	end })
	helpers.assert_eq(turns, 2)
end

helpers.describe("Local discovery startup ownership", function()
	helpers.it("publishes loading without acquiring HTTP before the first real keyboard pump", function()
		isolated(function(servers, _, calls, loop)
			local pumped, early = false, false
			calls.on_acquire = function() if not pumped then early = true end end
			helpers.assert_true(servers.rescan(function() return true end))
			helpers.assert_true(servers.is_sweeping())
			helpers.assert_eq(#calls, 0)
			tick(loop, function() helpers.assert_eq(#calls, 0); pumped = true end)
			helpers.assert_eq(#calls, 4)
			helpers.assert_eq(early, false)
			for _, call in ipairs(calls) do call.finish() end
			helpers.assert_eq(servers.result("omlx").status, "up")
		end)
	end)

	helpers.it("shutdown retires queued acquisition and never publishes after the loop begins", function()
		isolated(function(servers, _, calls, loop)
			local published = 0
			servers.rescan(function() return true end, function() published = published + 1 end)
			helpers.assert_true(servers.shutdown())
			tick(loop)
			helpers.assert_eq(#calls, 0)
			helpers.assert_eq(published, 0)
		end)
	end)

	helpers.it("cancelled queued work cannot acquire or notify but a successor can recover", function()
		isolated(function(servers, _, calls, loop)
			local old, fresh = 0, 0
			servers.rescan(function() return true end, function() old = old + 1 end)
			helpers.assert_true(servers.cancel())
			servers.rescan(function() return true end, function() fresh = fresh + 1 end)
			tick(loop)
			helpers.assert_eq(#calls, 4)
			for _, call in ipairs(calls) do call.finish() end
			helpers.assert_eq(old, 0)
			helpers.assert_eq(fresh, 1)
		end)
	end)

	helpers.it("superseding sweeps acquire only the latest captured target", function()
		isolated(function(servers, entries, calls, loop)
			servers.rescan(function() return true end)
			assert(entries.add({ provider = "lmstudio", label = "Changed", token = "", model = "before",
				base_url = "http://127.0.0.1:4321/v1" }))
			servers.rescan(function() return true end)
			helpers.assert_eq(#calls, 0)
			tick(loop)
			helpers.assert_eq(#calls, 4)
			helpers.assert_eq(calls[2].url, "http://127.0.0.1:4321/v1/models")
		end)
	end)

	helpers.it("revoked admission before dispatch acquires no native owner", function()
		isolated(function(servers, _, calls, loop)
			local admitted = true
			servers.rescan(function() return admitted end)
			admitted = false
			tick(loop)
			helpers.assert_eq(#calls, 0)
		end)
	end)

	helpers.it("a source mutation before the queued tick cannot acquire stale credentials", function()
		isolated(function(servers, entries, calls, loop)
			servers.rescan(function() return true end)
			assert(entries.add({ provider = "lmstudio", label = "Changed", token = "", model = "before",
				base_url = "http://127.0.0.1:4321/v1" }))
			tick(loop)
			helpers.assert_eq(#calls, 0)
		end)
	end)


	helpers.it("retirement in the first input pump cannot dispatch on that tick or a later run", function()
		isolated(function(servers, _, calls, loop)
			local publications = 0
			servers.rescan(function() return true end, function() publications = publications + 1 end)
			local retired
			loop.run({ onIdle = function() retired = servers.shutdown(); loop.stop() end })
			helpers.assert_true(retired)
			tick(loop)
			helpers.assert_eq(#calls, 0)
			helpers.assert_eq(publications, 0)
		end)
	end)

	helpers.it("reentrant shutdown inside queued admission cannot acquire or publish", function()
		isolated(function(servers, _, calls, loop)
			local retire, publications = false, 0
			servers.rescan(function()
				if retire then servers.shutdown() end
				return true
			end, function() publications = publications + 1 end)
			retire = true
			tick(loop)
			helpers.assert_eq(#calls, 0)
			helpers.assert_eq(publications, 0)
		end)
	end)

	helpers.it("an exact physical GET debt still fences the deferred successor", function()
		isolated(function(servers, _, calls, loop)
			servers.rescan(function() return true end)
			tick(loop)
			helpers.assert_eq(#calls, 4)
			helpers.assert_eq(servers.cancel(), false)
			servers.rescan(function() return true end)
			tick(loop)
			helpers.assert_eq(#calls, 4)
			calls[1].finish()
			helpers.assert_eq(#calls, 5)
			for index = 2, 4 do calls[index].finish() end
			helpers.assert_eq(#calls, 8)
			for index = 5, 8 do calls[index].finish() end
			helpers.assert_eq(servers.result("omlx").models[1], "current-model")
		end)
	end)
end)
