--- tests/unit/modules/llm/agent/test_agent_connector_lifecycle.lua

--- ==============================================================================
--- MODULE: Agent Connector Physical Lifetime Regression
--- DESCRIPTION:
--- Retains every accepted helper until native settlement and prevents completed
--- daemon shutdown from leaving an agent tool or publishing a late notification.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Exercises a fresh connector with independently controlled process close ACKs.
--- @param options table Constructor fault and completion controls.
--- @param body function Receives connector and owned process observations.
local function with_owner(options, body)
	local previous = package.loaded["modules.llm.agent_connectors"]
	package.loaded["modules.llm.agent_connectors"] = nil
	local Connector = require("modules.llm.agent_connectors")
	local state = { operations = {}, callbacks = 0, writes = 0, removals = 0, lists = 0, directories = 0, files = {} }
	local file = assert(io.open(helpers.driver_root() .. "/../_shared/modules/llm/agent.json", "r"))
	local config = assert(Json.decode(file:read("*a"))); file:close()
	local function done()
		state.callbacks = state.callbacks + 1
		if options.on_done then options.on_done(Connector, state) end
	end
	local function boundary(name)
		if options.boundary == name then
			options.boundary = nil
			state.boundary_ack = Connector.shutdown()
		end
	end
	local boundaries = {
		run = function(_, _, settings, callback)
			state.last_timeout = settings.timeout_ms
			if options.refuse then return nil, "explicit pre-acquisition refusal" end
			if options.invalid then return false end
			local settled, listeners = false, {}
			local operation = { started = true, cancels = 0 }
			function operation:is_settled() return settled end
			function operation:on_settled(listener)
				if settled then listener() else listeners[#listeners + 1] = listener end
				return true
			end
			function operation:cancel()
				self.cancels = self.cancels + 1
				if options.on_cancel then options.on_cancel(Connector, state) end
				return settled
			end
			function operation:logical() callback({ ok = true, code = 0 }) end
			function operation:ack()
				settled = true
				for _, listener in ipairs(listeners) do listener() end
			end
			state.operations[#state.operations + 1] = operation
			if options.constructing then state.constructor_ack = Connector.shutdown() end
			if options.throw then error("controlled uncertain native constructor") end
			if options.malformed then operation.on_settled = nil end
			if options.legacy then operation.on_settled, operation.is_settled = nil, nil end
			if options.inline then operation:logical(); operation:ack() end
			return operation
		end,
		tools_dir = function() boundary("tools_dir"); return "/owned/agent-tools" end,
		list_executables = function() state.lists = state.lists + 1; boundary("list"); return { "tool" } end,
		clock = function() boundary("clock"); return 0 end,
		private_dir = function()
			state.directories = state.directories + 1
			boundary("private_dir")
			return "/owned/private-calendar-" .. tostring(state.directories)
		end,
		write_file = function(path)
			state.writes = state.writes + 1; state.files[path] = true
			if options.on_write then options.on_write(Connector, state) end
			boundary("write"); return true
		end,
		remove = function(path) state.removals = state.removals + 1; state.files[path] = nil; return true end,
		random_hex = function() boundary("random"); return options.random_nil and nil or "cafe" end,
		utc_stamp = function() boundary("utc"); return "20261018T120000Z" end,
		has_command = function() boundary("has_command"); return true end,
	}
	boundaries.run_tool = boundaries.run
	Connector._set_deps_for_test(boundaries)
	state.run = function() return Connector.run(config, { type = "shortcut", name = "tool" }, done) end
	state.calendar = function() return Connector.run(config, { type = "reminder", title = "synthetic" }, done) end
	state.mail = function() return Connector.run(config, { type = "mail", body = "synthetic" }, done) end
	state.metadata = function(which)
		local settings, action = config, { type = "shortcut", name = "tool" }
		if which == "action" then action = setmetatable({}, { __index = function(_, key)
			state.boundary_ack = Connector.shutdown()
			return key == "type" and "shortcut" or "tool"
		end })
		else settings = setmetatable({}, { __index = function(_, key)
			state.boundary_ack = Connector.shutdown()
			return key == "max_tools" and 4 or config[key]
		end }) end
		return Connector.run(settings, action, done)
	end
	local ok, err = xpcall(function() body(Connector, state) end, debug.traceback)
	-- Every real resource in this fixture is an explicit fake operation. Unknown
	-- acquisition remains asserted debt; unloading it cannot release a native FD.
	for _, operation in ipairs(state.operations) do operation:logical(); operation:ack() end
	package.loaded["modules.llm.agent_connectors"] = previous
	if not ok then error(err, 0) end
end

helpers.describe("agent connector owned shutdown", function()
	helpers.it("(agent-connector-shutdown) normal publication waits for physical close ACK", function()
		with_owner({}, function(Connector, state)
			helpers.assert_true(state.run())
			state.operations[1]:logical()
			helpers.assert_eq(state.callbacks, 0)
			state.operations[1]:ack()
			helpers.assert_eq(state.callbacks, 1)
			helpers.assert_true(Connector.shutdown())
		end)
	end)

	helpers.it("(agent-connector-shutdown) a false constructor receipt retains unknown debt", function()
		with_owner({ invalid = true }, function(Connector, state)
			helpers.assert_eq(state.run(), false)
			helpers.assert_eq(Connector.shutdown(), false)
			helpers.assert_eq(state.callbacks, 0)
			helpers.assert_eq(state.run(), false)
		end)
	end)

	helpers.it("(agent-connector-shutdown) all jobs retain debt and suppress late callbacks", function()
		with_owner({}, function(Connector, state)
			helpers.assert_true(state.run()); helpers.assert_true(state.run())
			helpers.assert_eq(Connector.shutdown(), false)
			helpers.assert_eq(state.operations[1].cancels, 1)
			helpers.assert_eq(state.operations[2].cancels, 1)
			state.operations[1]:logical(); state.operations[1]:ack()
			helpers.assert_eq(Connector.shutdown(), false)
			state.operations[2]:logical(); state.operations[2]:ack()
			helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.callbacks, 0)
			helpers.assert_eq(state.run(), false)
			helpers.assert_eq(#state.operations, 2)
			helpers.assert_true(Connector.shutdown())
		end)
	end)

	helpers.it("(agent-connector-shutdown) closes admission before a native cancellation callback", function()
		local attempted
		with_owner({ on_cancel = function(_, state) attempted = state.run() end }, function(Connector, state)
			helpers.assert_true(state.run())
			helpers.assert_eq(Connector.shutdown(), false)
			helpers.assert_eq(attempted, false)
			helpers.assert_eq(#state.operations, 1)
			state.operations[1]:ack(); helpers.assert_true(Connector.shutdown())
		end)
	end)

	helpers.it("(agent-connector-shutdown) retains a reentrant constructor until it returns its owner", function()
		with_owner({ constructing = true }, function(Connector, state)
			helpers.assert_eq(state.run(), false)
			helpers.assert_eq(state.constructor_ack, false)
			helpers.assert_eq(Connector.shutdown(), false)
			state.operations[1]:ack(); helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.callbacks, 0)
		end)
	end)

	for _, mode in ipairs({ "throw", "malformed" }) do
		helpers.it("(agent-connector-shutdown) retains " .. mode .. " constructor debt without false success", function()
			with_owner({ [mode] = true }, function(Connector, state)
				helpers.assert_eq(state.run(), false)
				helpers.assert_eq(Connector.shutdown(), false)
				state.operations[1]:ack()
				helpers.assert_eq(Connector.shutdown(), false)
				helpers.assert_eq(state.run(), false)
				helpers.assert_eq(state.callbacks, 0)
			end)
		end)
	end

	helpers.it("(agent-connector-shutdown) explicit refusal owns no cleanup and reports once", function()
		with_owner({ refuse = true }, function(Connector, state)
			helpers.assert_eq(state.run(), false)
			helpers.assert_eq(state.callbacks, 1)
			helpers.assert_true(Connector.shutdown())
		end)
	end)

	helpers.it("(agent-connector-shutdown) accepts an inline settled result once", function()
		with_owner({ inline = true }, function(Connector, state)
			helpers.assert_true(state.run())
			helpers.assert_eq(state.callbacks, 1)
			helpers.assert_true(Connector.shutdown())
		end)
	end)

	helpers.it("(agent-connector-shutdown) desktop pending handoff retains input without claiming tool retirement", function()
		with_owner({}, function(Connector, state)
			helpers.assert_true(state.calendar())
			Connector.cleanup()
			helpers.assert_eq(state.removals, 0)
			helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.removals, 0)
			helpers.assert_eq(state.operations[1].cancels, 0)
			state.operations[1]:logical(); helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.removals, 2)
			helpers.assert_eq(state.callbacks, 0)
		end)
	end)

	helpers.it("(agent-connector-shutdown) desktop callbacks keep the original logical 30-second protocol", function()
		with_owner({ legacy = true }, function(Connector, state)
			helpers.assert_true(state.mail())
			helpers.assert_eq(state.last_timeout, 30000)
			state.operations[1]:logical()
			helpers.assert_eq(state.callbacks, 1)
			helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.operations[1].cancels, 0)
		end)
	end)

	helpers.it("(agent-connector-shutdown) pending mail is fenced without cancelling its accepted GUI", function()
		with_owner({ legacy = true }, function(Connector, state)
			helpers.assert_true(state.mail())
			helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.operations[1].cancels, 0)
			state.operations[1]:logical()
			helpers.assert_eq(state.callbacks, 0)
			helpers.assert_eq(state.mail(), false)
		end)
	end)

	helpers.it("(agent-connector-shutdown) terminal admission creates no calendar file or process", function()
		with_owner({}, function(Connector, state)
			helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.calendar(), false)
			helpers.assert_eq(state.run(), false)
			helpers.assert_eq(state.writes, 0)
			helpers.assert_eq(#state.operations, 0)
			helpers.assert_eq(state.lists, 0)
		end)
	end)

	for _, phase in ipairs({ "random", "utc", "private_dir", "write", "clock", "tools_dir", "list", "has_command" }) do
		helpers.it("(agent-connector-shutdown) preparation " .. phase .. " cannot acquire after terminal admission", function()
			with_owner({ boundary = phase }, function(Connector, state)
				local accepted
				if phase == "has_command" then accepted = state.mail()
				elseif phase == "clock" or phase == "tools_dir" or phase == "list" then accepted = state.run()
				else accepted = state.calendar() end
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(state.boundary_ack, false, "shutdown must retain the preparing native frame")
				helpers.assert_eq(#state.operations, 0)
				helpers.assert_eq(state.callbacks, 0)
				helpers.assert_true(Connector.shutdown())
				if phase == "private_dir" then helpers.assert_eq(state.writes, 0); helpers.assert_eq(state.removals, 1) end
				if phase == "write" then helpers.assert_eq(state.removals, 2) end
			end)
		end)
	end

	for _, phase in ipairs({ "action", "config" }) do
		helpers.it("(agent-connector-shutdown) reserves admission before " .. phase .. " metadata", function()
			with_owner({}, function(Connector, state)
				helpers.assert_eq(state.metadata(phase), false)
				helpers.assert_eq(state.boundary_ack, false)
				helpers.assert_eq(#state.operations, 0)
				helpers.assert_eq(state.callbacks, 0)
				helpers.assert_true(Connector.shutdown())
			end)
		end)
	end


	helpers.it("(agent-connector-shutdown) cleanup during a write cannot delete its preparing input", function()
		with_owner({ on_write = function(Connector, state)
			Connector.cleanup()
			helpers.assert_eq(state.removals, 0)
			helpers.assert_true(next(state.files) ~= nil)
		end }, function(Connector, state)
			helpers.assert_true(state.calendar())
			helpers.assert_eq(state.removals, 0)
			helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.removals, 0)
			state.operations[1]:logical(); helpers.assert_true(Connector.shutdown())
			helpers.assert_eq(state.removals, 2)
		end)
	end)

	helpers.it("(agent-connector-shutdown) an inline business result runs after preparation retires", function()
		local acknowledged, successor
		with_owner({ inline = true, on_done = function(Connector, state)
			acknowledged = Connector.shutdown()
			successor = state.run()
		end }, function(_, state)
			helpers.assert_true(state.run())
			helpers.assert_eq(acknowledged, true)
			helpers.assert_eq(successor, false)
			helpers.assert_eq(#state.operations, 1)
			helpers.assert_eq(state.callbacks, 1)
		end)
	end)

	for _, mode in ipairs({ "cancel", "second calendar" }) do
		helpers.it("(agent-connector-shutdown) logger reentry " .. mode .. " retains the first calendar input", function()
			local Logger = require("logger.shim")
			local original = Logger.info
			local ok, why = pcall(function()
				with_owner({}, function(Connector, state)
					local entered = false
					Logger.info = function(tag, format, ...)
						if not entered and tostring(format):find("Opening a %s entry", 1, true) then
							entered = true
							if mode == "cancel" then state.boundary_ack = Connector.shutdown()
							else helpers.assert_true(state.calendar()) end
							helpers.assert_eq(state.removals, 0)
						end
						return original(tag, format, ...)
					end
					local accepted = state.calendar()
					if mode == "cancel" then
						helpers.assert_eq(accepted, false)
						helpers.assert_eq(state.boundary_ack, false)
						helpers.assert_eq(#state.operations, 0)
						helpers.assert_eq(state.removals, 2)
					else
						helpers.assert_true(accepted)
						helpers.assert_eq(#state.operations, 2)
						helpers.assert_eq(state.removals, 0)
						for _, operation in ipairs(state.operations) do operation:logical(); operation:ack() end
					end
					helpers.assert_true(Connector.shutdown())
				end)
			end)
			Logger.info = original
			if not ok then error(why, 0) end
		end)
	end

end)


--- Runs the actual Main registry with all unrelated native owners inactive.
--- @param connector table|nil Exact already-loaded connector module.
--- @param body function Receives coordinator and final-loop observations.
local function with_main(connector, body)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local text = file:read("*a"); file:close()
	local capture = assert(text:match("(local shutdown_runtime = prediction_engine and prediction_engine%.shutdown_runtime.-)\nlocal shutdown = ShutdownCoordinator"))
	local registry = assert(text:match("local shutdown = ShutdownCoordinator%.new%(%{(.-)\n%}%)[\r\n]"))
	local observed = { stops = 0, flushes = 0, imports = 0, loaded = { ["modules.llm.agent_connectors"] = connector } }
	local env = setmetatable({ ShutdownCoordinator = require("infra.shutdown_coordinator"), package = { loaded = observed.loaded },
		keystats = { stop = function() return true end }, privacy_owners = {}, prediction_engine = false,
		dyn_hotstrings = false, updater = false, file_watchers = false, process_lifecycle = false,
		webview_manager = false, tooltip_preview = false, gestures = false, input_capture_gate = false,
		TimerScheduler = { cancelAll = function() return true end },
		require = function(name)
			if name == "modules.llm.agent_connectors" then observed.imports = observed.imports + 1; error("cold connector import") end
			assert(name == "modules.llm.agent_learning", "unexpected Main dependency")
			return { flush = function() observed.flushes = observed.flushes + 1 end }
		end,
		keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
		event_loop = { stop = function() observed.stops = observed.stops + 1 end },
	}, { __index = _G })
	local source = capture .. "\nreturn ShutdownCoordinator.new({" .. registry .. "\n})"
	local chunk
	if setfenv then chunk = assert(loadstring(source, "actual Main connector registry")); setfenv(chunk, env)
	else chunk = assert(load(source, "actual Main connector registry", "t", env)) end
	local ok, why = xpcall(function() body(chunk(), observed) end, debug.traceback)
	if not ok then error(why, 0) end
end

helpers.describe("Main agent connector shutdown ownership", function()
	helpers.it("(agent-connector-main) cold shutdown never imports connectors", function()
		with_main(nil, function(shutdown, seen)
			shutdown.request("cold connector shutdown"); shutdown.poll(); shutdown.request("repeated")
			helpers.assert_eq(seen.imports, 0); helpers.assert_eq(seen.stops, 1)
			helpers.assert_eq(seen.flushes, 1); helpers.assert_eq(shutdown.is_pending(), false)
		end)
	end)
	for _, replacement in ipairs({ "module", "method", "unload" }) do
		helpers.it("(agent-connector-main) pins exact owner after " .. replacement .. " replacement", function()
			local acknowledged, calls = false, 0
			local connector = { shutdown = function() calls = calls + 1; return acknowledged end }
			with_main(connector, function(shutdown, seen)
				shutdown.request("retain exact native owner")
				helpers.assert_true(shutdown.is_pending()); helpers.assert_eq(seen.stops, 0)
				if replacement == "method" then connector.shutdown = function() return true end
				elseif replacement == "module" then seen.loaded["modules.llm.agent_connectors"] = { shutdown = function() return true end }
				else seen.loaded["modules.llm.agent_connectors"] = nil end
				shutdown.poll(); shutdown.request("repeated pending")
				helpers.assert_true(shutdown.is_pending()); helpers.assert_eq(seen.stops, 0)
				helpers.assert_eq(seen.flushes, 1)
				acknowledged = true; shutdown.poll()
				helpers.assert_true(calls >= 2); helpers.assert_eq(shutdown.is_pending(), false)
				helpers.assert_eq(seen.stops, 1); helpers.assert_eq(seen.flushes, 1)
			end)
		end)
	end
	helpers.it("(agent-connector-main) refuses a truthy non-ACK until literal true", function()
		local answer = "logical cancellation only"
		with_main({ shutdown = function() return answer end }, function(shutdown, seen)
			shutdown.request("strict physical acknowledgement"); shutdown.poll()
			helpers.assert_true(shutdown.is_pending()); helpers.assert_eq(seen.stops, 0)
			answer = true; shutdown.poll()
			helpers.assert_eq(shutdown.is_pending(), false); helpers.assert_eq(seen.stops, 1)
		end)
	end)
end)

helpers.describe("agent connector native deadline admission", function()
	for _, mode in ipairs({ "fresh clock", "stop during refresh" }) do
		helpers.it("(agent-connector-clock) " .. mode .. " before native allocation", function()
			local uv = require("luv")
			local old_clock, old_backend = uv.update_time, package.loaded["adapters.owned_process"]
			local old_connector = package.loaded["modules.llm.agent_connectors"]
			package.loaded["modules.llm.agent_connectors"] = nil
			local Connector = require("modules.llm.agent_connectors")
			local refreshed, allocated, callbacks, stop_ack = false, 0, 0, nil
			uv.update_time = function()
				refreshed = true
				if mode == "stop during refresh" then stop_ack = Connector.shutdown() end
			end
			package.loaded["adapters.owned_process"] = { start = function(_, _, options, callback)
				assert(refreshed, "native deadline was armed against a stale loop clock")
				if not options.authorized() then return nil, "revoked before allocation" end
				allocated = allocated + 1
				helpers.assert_eq(options.timeout_ms, 120000)
				callback({ ok = true, exit_code = 0 })
				return { started = true, cancel = function() return true end, is_settled = function() return true end,
					on_settled = function(_, listener) listener(); return true end }
			end }
			Connector._set_deps_for_test({ tools_dir = function() return "/owned/tools" end,
				list_executables = function() return { "tool" } end, clock = function() return 0 end })
			local ok, why = xpcall(function()
				local accepted = Connector.run({ max_tools = 4 }, { type = "shortcut", name = "tool" }, function() callbacks = callbacks + 1 end)
				helpers.assert_true(refreshed)
				if mode == "fresh clock" then
					helpers.assert_true(accepted); helpers.assert_eq(allocated, 1); helpers.assert_eq(callbacks, 1)
				else
					helpers.assert_eq(accepted, false); helpers.assert_eq(allocated, 0); helpers.assert_eq(callbacks, 0)
					helpers.assert_eq(stop_ack, false)
				end
				helpers.assert_true(Connector.shutdown())
			end, debug.traceback)
			uv.update_time, package.loaded["adapters.owned_process"] = old_clock, old_backend
			package.loaded["modules.llm.agent_connectors"] = old_connector
			if not ok then error(why, 0) end
		end)
	end
end)

helpers.describe("native agent connector shutdown", function()
	if pcall(require, "luv") and package.config:sub(1, 1) == "/" then
		for _, mode in ipairs({ "normal", "shutdown", "cold", "spawn-refused" }) do
			helpers.it("(agent-connector-shutdown-native) actual " .. mode .. " helper lifetime", function()
				local uv = require("luv")
				local quote = require("text_utils").shell_quote
				local fixture = helpers.driver_root() .. "/tests/fixtures/native_agent_connector_shutdown.lua"
				local result = os.execute(quote(assert(uv.exepath())) .. " " .. quote(fixture) .. " " .. quote(mode))
				helpers.assert_true(result == true or result == 0, "native connector lifetime must retire all physical resources")
			end)
		end
	end
end)
