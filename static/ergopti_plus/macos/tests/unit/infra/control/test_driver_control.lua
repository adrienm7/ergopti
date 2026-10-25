--- tests/unit/infra/control/test_driver_control.lua

--- ==============================================================================
--- MODULE: Local Driver Control (macOS)
--- DESCRIPTION:
--- Replays the shared driver-control contract, then drives a genuine session
--- over in-memory files and a fake folder watcher: an authenticated request
--- reaches the termination coordinator and names this process, the reloaded
--- state completes it, and a stale token, a refusing coordinator or an abort
--- is reported as refused.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Policy = require("control.driver_control")

require("test.driver_control_contract").run(helpers, helpers.shared(""))

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a"))
	assert(file:close())
	return text
end

local SPEC_TEXT = read(helpers.shared("modules/control/driver_control.json"))
local SPEC = Policy.validate(Json.decode(SPEC_TEXT))
local TOKEN = Json.decode(read(helpers.shared("tests/corpus/control/driver_control.json"))).token
local FOLDER = "/Users/u/Library/Application Support/ergopti_plus/control"

--- A session over in-memory files; `coordinator(reason, on_aborted)` answers the reload.
local function world(coordinator, files)
	files = files or {}
	local state = { files = files, calls = {}, deferred = {}, watcher = nil, stopped = 0 }
	local ports = {
		read = function(path)
			if files[path] == nil then return nil, "absent" end
			return files[path], "ok"
		end,
		write = function(path, text) files[path] = text; return true end,
		remove = function(path) files[path] = nil; return true end,
		exists = function(path) return files[path] ~= nil end,
		private_dir = function() return true end,
		random_hex = function() return TOKEN end,
		watch = function(path, callback)
			state.watched = path
			state.watcher = callback
			state.watcher_handle = { start = function(candidate)
				state.watcher_starts = (state.watcher_starts or 0) + 1
				if state.on_watch_start then state.on_watch_start() end
				state.watcher_running = true
				if state.start_error then error("native watcher start failed") end
				return candidate
			end, stop = function(candidate)
				state.stopped = state.stopped + 1
				if state.on_stop then state.on_stop() end
				if state.stop_error then error("native watcher stop failed") end
				if state.stop_result == false then return false end
				if state.stop_nil then return nil end
				state.watcher_running = false
				return candidate
			end }
			if state.on_watch_create then state.on_watch_create() end
			return state.watcher_handle
		end,
		defer = function(callback)
			local handle = { cancelled = false }
			state.timer_handle = handle
			state.deferred[#state.deferred + 1] = callback
			if state.on_defer then state.on_defer() end
			return handle, state.defer_committed ~= false
		end,
		cancel = function(handle)
			state.cancelled = (state.cancelled or 0) + 1
			state.cancelled_handle = handle
			if state.cancel_error then error("native timer stop failed") end
			if state.cancel_result == false then return false end
			handle.cancelled = true
			return true
		end,
	}
	local DriverControl = require("infra.driver_control")
	state.session = DriverControl.new({ spec = SPEC, folder = FOLDER, pid = 777, ports = ports,
		request_reload = function(reason, on_aborted)
			state.calls[#state.calls + 1] = reason
			return coordinator(reason, on_aborted)
		end })
	return state
end

--- Exercises the real native ports and singleton without touching user files.
--- @param options table Native fault controls.
--- @param callback function Receives the module and independently observable native state.
local function with_native_world(options, callback)
	helpers.with_stub_scope({ "infra.driver_control", "infra.logger", "adapters.file_system", "adapters.shell_runner", "adapters.timer_scheduler", "app_dirs" }, function()
		local state = { files = {}, stops = 0, starts = 0, created = 0, running = false, options = options }
		state.errors = {}
		local module
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...) state.errors[#state.errors + 1] = string.format(message, ...) end
		logger.start = function() if options.on_log_start then options.on_log_start(module, state) end end
		package.loaded["infra.logger"] = logger
		module = helpers.load_with_stubs("infra.driver_control", {
			fs = { attributes = function() return { mode = "directory", permissions = "rwx------" } end },
			pathwatcher = { new = function(folder, delivery)
				state.folder = folder
				state.created = state.created + 1
				state.delivery = delivery
				if options.on_create then options.on_create(module, state) end
				if options.construct_error then error("native watcher construction failed") end
				if options.construct_nil then return nil end
				if options.construct_false then return false end
				local candidate = {}
				function candidate:start()
					state.starts = state.starts + 1
					if options.on_start then options.on_start(module, state) end
					state.running = true
					if options.start_error then error("native watcher activation failed") end
					if options.start_false then return false end
					if options.start_nil then return nil end
					return self
				end
				function candidate:stop()
					state.stops = state.stops + 1
					if options.stop_error then error("native watcher stop failed") end
					if options.stop_false then return false end
					if options.stop_nil then return nil end
					state.running = false
					return self
				end
				state.candidate = candidate
				return candidate
			end },
		})
		state.deferred = {}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_, callback)
				local handle = { callback = callback }
				state.deferred[#state.deferred + 1] = handle
				return handle, true
			end,
			cancel = function(handle) handle.cancelled = true; return true end,
		}
		package.loaded["adapters.shell_runner"] = { exec = function() return "" end }
		package.loaded["adapters.file_system"] = {
			read = function(path)
				if options.read_error and path:sub(-#"/session.json") == "/session.json" then return nil end
				return path == "declaration" and SPEC_TEXT or state.files[path]
			end,
			read_with_status = function(path)
				if options.read_error then return nil, "error", "native read refused" end
				if state.files[path] == nil then return nil, "absent" end
				return state.files[path], "ok"
			end,
			write = function(path, text)
				if path:sub(-#"/session.json") == "/session.json" then
					if options.on_write then options.on_write(module, state) end
					if options.write_error then error("native session publication failed") end
					if options.write_false then return false end
				end
				state.files[path] = text
				return true
			end,
			delete = function(path)
				if options.remove_false then return false end
				state.files[path] = nil
				return true
			end,
			exists = function(path) return state.files[path] ~= nil end,
		}
		state.start = function()
			local result = module.start({ pid = 777, declaration = "declaration", request_reload = function() return true end })
			return result
		end
		callback(module, state)
	end)
end

local function ring(state, token, id)
	state.files[FOLDER .. "/reload.request"] = string.format('{"schema":1,"token":"%s","request_id":"%s"}', token, id)
	state.watcher({ FOLDER .. "/reload.request" })
	helpers.assert_eq(#state.deferred, 1, "the request runs on a later timer, not in the watcher callback")
	local run = table.remove(state.deferred, 1)
	run()
end

helpers.describe("macOS local driver control", function()
	helpers.it("hands an authenticated request to the termination coordinator", function()
		local state = world(function() return true end)
		state.session:start()
		helpers.assert_eq(state.watched, FOLDER)
		helpers.assert_eq(state.files[FOLDER .. "/session.json"],
			'{"schema":1,"driver":"macos","pid":777,"token":"' .. TOKEN .. '"}\n')
		ring(state, TOKEN, "mac-1")
		helpers.assert_eq(#state.calls, 1, "one controlled reload is requested")
		helpers.assert_eq(state.calls[1], "driver_control")
		helpers.assert_nil(state.files[FOLDER .. "/reload.request"], "the request is consumed")
		helpers.assert_eq(state.files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"mac-1","state":"requested","driver_pid":777,"successor_pid":777}\n')
		helpers.assert_eq(state.session:stop(), true)
		helpers.assert_eq(state.stopped, 1, "the folder watcher is retired")
		helpers.assert_nil(state.files[FOLDER .. "/session.json"], "the session withdraws its own file")
	end)

	helpers.it("retains exact watcher cleanup debt after a native failure (control-stop-debt)", function()
		local state = world(function() return true end)
		state.session:start()
		state.stop_error = true
		local ran, stopped = pcall(state.session.stop, state.session)
		helpers.assert_true(ran and stopped == false, "a native failure is reported without dropping the owner")
		helpers.assert_true(rawequal(state.session.watcher, state.watcher_handle), "the exact watcher remains retryable")
		helpers.assert_eq(state.session.active, false, "callbacks are revoked before native cleanup")
		state.watcher({ FOLDER .. "/reload.request" })
		helpers.assert_eq(#state.deferred, 0, "retired callbacks cannot schedule work")
		state.stop_error = false
		state.stop_result = false
		helpers.assert_eq(state.session:stop(), false, "an explicit stop refusal also retains debt")
		state.stop_result = nil
		state.stop_nil = true
		helpers.assert_eq(state.session:stop(), false, "nil is not the pinned native stop receipt")
		state.stop_nil = false
		helpers.assert_eq(state.session:stop(), true, "the native self-returning stop API commits cleanup")
		helpers.assert_eq(state.stopped, 4, "every retry reaches the same retained watcher")
		helpers.assert_nil(state.session.watcher, "only proven cleanup releases ownership")
	end)

	helpers.it("refuses recursive stop while exact cleanup is in flight (control-stop-reentry)", function()
		local state = world(function() return true end)
		state.session:start()
		local nested
		state.on_stop = function()
			state.on_stop = nil
			nested = state.session:stop()
		end
		helpers.assert_eq(state.session:stop(), true)
		helpers.assert_eq(nested, false, "a reentrant caller cannot claim in-flight cleanup has settled")
		helpers.assert_eq(state.stopped, 1, "the native watcher is stopped exactly once")
	end)

	helpers.it("recovers after a refused timer without admitting its stale callback (control-timer-arming)", function()
		local state = world(function() return true end)
		state.session:start()
		state.defer_committed = false
		state.files[FOLDER .. "/reload.request"] = string.format('{"schema":1,"token":"%s","request_id":"retry"}', TOKEN)
		state.watcher({ FOLDER .. "/reload.request" })
		local stale = table.remove(state.deferred, 1)
		helpers.assert_eq(state.timer_handle.cancelled, true, "the uncommitted candidate is cleaned up")
		state.defer_committed = true
		state.watcher({ FOLDER .. "/reload.request" })
		helpers.assert_eq(#state.deferred, 1, "the refused timer must not strand the pending flag")
		stale()
		helpers.assert_eq(#state.calls, 0, "a callback from refused activation remains inert")
		table.remove(state.deferred, 1)()
		helpers.assert_eq(#state.calls, 1, "the next committed request can reach the coordinator")
	end)

	helpers.it("retains a refused pending timer until exact stop succeeds (control-timer-stop-debt)", function()
		local state = world(function() return true end)
		state.session:start()
		state.watcher({ FOLDER .. "/reload.request" })
		local timer = state.timer_handle
		state.cancel_error = true
		helpers.assert_eq(state.session:stop(), false, "a throwing timer stop is retained as cleanup debt")
		state.cancel_error = false
		state.cancel_result = false
		helpers.assert_eq(state.session:stop(), false, "a timer stop refusal remains retryable")
		table.remove(state.deferred, 1)()
		helpers.assert_eq(#state.calls, 0, "queued delivery after stop cannot request a reload")
		state.cancel_result = true
		helpers.assert_eq(state.session:stop(), true)
		helpers.assert_true(rawequal(state.cancelled_handle, timer), "retry cancels the exact original timer")
		helpers.assert_eq(timer.cancelled, true)
		helpers.assert_eq(state.stopped, 1, "the already stopped watcher is not stopped again")
	end)

	helpers.it("cleans the timer returned after reentrant stop (control-timer-reentry)", function()
		local state = world(function() return true end)
		state.session:start()
		local nested
		state.on_defer = function() nested = state.session:stop() end
		state.watcher({ FOLDER .. "/reload.request" })
		helpers.assert_eq(nested, false, "a timer still being constructed is unsettled ownership")
		helpers.assert_eq(state.timer_handle.cancelled, true, "the returned candidate is retired after revocation")
		table.remove(state.deferred, 1)()
		helpers.assert_eq(#state.calls, 0)
		helpers.assert_eq(state.session:stop(), true)
	end)

	helpers.it("rolls back a watcher that activates before startup throws (control-watcher-start)", function()
		local state = world(function() return true end)
		state.start_error = true
		state.stop_result = false
		local ran = pcall(state.session.start, state.session)
		helpers.assert_eq(ran, false, "an uncertain native activation cannot publish a ready session")
		helpers.assert_eq(state.session.active, false)
		helpers.assert_true(rawequal(state.session.watcher, state.watcher_handle), "rollback debt stays rooted")
		state.watcher({ FOLDER .. "/reload.request" })
		helpers.assert_eq(#state.deferred, 0)
		state.stop_result = nil
		helpers.assert_eq(state.session:stop(), true)
		helpers.assert_eq(state.watcher_running, false)
		helpers.assert_nil(state.files[FOLDER .. "/session.json"], "failed startup withdraws its own session")
	end)

	helpers.it("fences watcher delivery until startup commits (control-watcher-start-delivery)", function()
		local state = world(function() return true end)
		state.on_watch_create = function() state.watcher({ FOLDER .. "/reload.request" }) end
		state.session:start()
		helpers.assert_eq(#state.deferred, 0, "construction-time delivery cannot schedule an uncommitted owner")
		helpers.assert_eq(state.watcher_starts, 1, "the exact constructed watcher is activated")
		helpers.assert_eq(state.session.active, true)
	end)

	helpers.it("rolls back activation completed after a reentrant stop (control-watcher-start-reentry)", function()
		local state = world(function() return true end)
		local nested
		state.on_watch_start = function() nested = state.session:stop() end
		local ran = pcall(state.session.start, state.session)
		helpers.assert_eq(ran, false, "revoked startup cannot republish a ready session")
		helpers.assert_eq(nested, false, "native activation still in flight cannot be settled")
		helpers.assert_eq(state.watcher_running, false, "startup rollback retires the post-stop activation")
		helpers.assert_eq(state.stopped, 2, "the returned activation is cleaned after the reentrant attempt")
		helpers.assert_nil(state.session.watcher)
	end)

	helpers.it("retains native startup debt in the singleton until cleanup commits (control-native-start-debt)", function()
		for _, mode in ipairs({ "start_error", "start_false", "start_nil" }) do
			local options = { [mode] = true, stop_error = true }
			with_native_world(options, function(module, state)
				helpers.assert_eq(state.start(), false)
				helpers.assert_eq(state.running, true, "the uncertain activation remains natively live")
				helpers.assert_eq(module.stop(), false, "startup debt must still own its exact watcher")
				local ran = pcall(state.start)
				helpers.assert_eq(ran, false, "a new session cannot replace unsettled startup debt")
				helpers.assert_eq(state.created, 1)
				options.stop_error = false
				helpers.assert_eq(module.stop(), true)
				helpers.assert_eq(state.running, false)
			end)
		end
	end)

	helpers.it("rolls native activation back after stop reenters start (control-native-start-reentry)", function()
		local nested
		with_native_world({ on_start = function(module) nested = module.stop() end }, function(_, state)
			helpers.assert_eq(state.start(), false)
			helpers.assert_eq(nested, false, "in-flight native activation is not a completed stop")
			helpers.assert_eq(state.running, false, "late activation is cleaned after start returns")
			helpers.assert_true(state.stops >= 2, "cleanup retries the exact candidate after start settles")
		end)
	end)

	helpers.it("retains singleton ownership until its session file is withdrawn (control-native-marker-debt)", function()
		local options = {}
		with_native_world(options, function(module, state)
			helpers.assert_eq(state.start(), true)
			options.remove_false = true
			helpers.assert_eq(module.stop(), false)
			helpers.assert_eq(pcall(state.start), false, "cleanup debt excludes a replacement token owner")
			options.remove_false = false
			helpers.assert_eq(module.stop(), true)
			helpers.assert_eq(state.stops, 1, "withdrawal retry does not restart native cleanup")
		end)
	end)

	helpers.it("refuses constructor failures without publishing startup (control-native-construction)", function()
		for _, mode in ipairs({ "construct_error", "construct_nil", "construct_false" }) do
			local options = { [mode] = true }
			with_native_world(options, function(module, state)
				helpers.assert_eq(state.start(), false)
				helpers.assert_eq(state.starts, 0)
				helpers.assert_eq(state.stops, 0)
				helpers.assert_eq(module.stop(), true)
				for file in pairs(state.files) do
					helpers.assert_true(file:sub(-#"/session.json") ~= "/session.json", "failed construction leaves no owned session marker")
				end
				options[mode] = false
				helpers.assert_eq(state.start(), true, "settled startup failure permits a fresh owner")
				helpers.assert_eq(module.stop(), true)
			end)
		end
	end)

	helpers.it("keeps unreadable marker cleanup retryable and preserves a successor (control-native-marker-read)", function()
		local options = {}
		with_native_world(options, function(module, state)
			helpers.assert_eq(state.start(), true)
			local session_path
			for file in pairs(state.files) do if file:sub(-#"/session.json") == "/session.json" then session_path = file end end
			helpers.assert_true(type(session_path) == "string", "startup published a real owned marker")
			options.read_error = true
			helpers.assert_eq(module.stop(), false, "unreadable is not proof that the owned marker disappeared")
			options.read_error = false
			local old_token = Json.decode(state.files[session_path]).token
			local replacement_token = (old_token:sub(1, 1) == "0" and "1" or "0") .. old_token:sub(2)
			local successor = Policy.session_text(SPEC, "macos", 888, replacement_token)
			state.files[session_path] = successor
			helpers.assert_eq(module.stop(), true)
			helpers.assert_eq(state.files[session_path], successor, "cleanup cannot withdraw a successor's token")
		end)
	end)

	helpers.it("keeps synchronous native watcher delivery outside startup authority (control-native-start-delivery)", function()
		for _, phase in ipairs({ "on_create", "on_start" }) do
			local options = { [phase] = function(_, state)
				state.request_path = state.folder .. "/reload.request"
				state.delivery({ state.request_path })
			end }
			with_native_world(options, function(module, state)
				helpers.assert_eq(state.start(), true)
				helpers.assert_eq(#state.deferred, 0, "uncommitted native callbacks cannot schedule requests")
				state.delivery({ state.request_path })
				helpers.assert_eq(#state.deferred, 1, "the committed native watcher can deliver requests")
				helpers.assert_eq(module.stop(), true)
				helpers.assert_eq(state.deferred[1].cancelled, true, "the real cancellation port retires that request")
			end)
		end
	end)

	helpers.it("publishes its token only after native request delivery is ready (control-native-marker-ready)", function()
		local visible_during_start = false
		with_native_world({ on_start = function(_, state)
			for file in pairs(state.files) do
				if file:sub(-#"/session.json") == "/session.json" then visible_during_start = true end
			end
		end }, function(module, state)
			helpers.assert_eq(state.start(), true)
			helpers.assert_eq(visible_during_start, false, "a tool cannot acquire a token before a watcher accepts requests")
			local marker
			for file, text in pairs(state.files) do if file:sub(-#"/session.json") == "/session.json" then marker = Json.decode(text) end end
			helpers.assert_eq(marker.driver, "macos", "successful startup publishes its session")
			helpers.assert_eq(state.running, true)
			helpers.assert_eq(module.stop(), true)
		end)
	end)

	helpers.it("retains native cleanup if readiness publication fails (control-native-marker-publication)", function()
		for _, mode in ipairs({ "write_error", "write_false" }) do
			local options = { [mode] = true, stop_error = true }
			with_native_world(options, function(module, state)
				helpers.assert_eq(state.start(), false)
				helpers.assert_eq(state.running, true, "failed publication cannot discard the started watcher")
				helpers.assert_eq(module.stop(), false)
				helpers.assert_eq(pcall(state.start), false, "cleanup debt excludes a replacement session")
				options.stop_error = false
				helpers.assert_eq(module.stop(), true)
				helpers.assert_eq(state.running, false)
			end)
		end
	end)

	helpers.it("withdraws readiness published after a reentrant stop (control-native-marker-reentry)", function()
		local nested
		with_native_world({ on_write = function(module) nested = module.stop() end }, function(module, state)
			helpers.assert_eq(state.start(), false)
			helpers.assert_eq(nested, false, "readiness publication still belongs to in-flight startup")
			helpers.assert_eq(state.running, false)
			for file in pairs(state.files) do
				helpers.assert_true(file:sub(-#"/session.json") ~= "/session.json", "a late token cannot resurrect retired startup")
			end
			helpers.assert_eq(module.stop(), true)
		end)
	end)

	helpers.it("retains native stop ownership without the exact watcher receipt (control-native-stop-receipt)", function()
		for _, mode in ipairs({ "stop_error", "stop_false", "stop_nil" }) do
			local options = {}
			with_native_world(options, function(module, state)
				helpers.assert_eq(state.start(), true)
				options[mode] = true
				helpers.assert_eq(module.stop(), false)
				helpers.assert_eq(state.running, true, "an unacknowledged stop keeps exact native debt")
				helpers.assert_eq(pcall(state.start), false, "a new session cannot replace unresolved cleanup")
				options[mode] = false
				helpers.assert_eq(module.stop(), true)
				helpers.assert_eq(state.running, false)
				helpers.assert_eq(state.created, 1, "stop retries the original watcher")
			end)
		end
	end)

	helpers.it("reserves singleton startup before diagnostic reentry (control-native-start-reservation)", function()
		local nested_ran
		local options = {}
		options.on_log_start = function(_, state)
			options.on_log_start = nil
			nested_ran = pcall(state.start)
		end
		with_native_world(options, function(module, state)
			helpers.assert_eq(state.start(), true)
			helpers.assert_eq(nested_ran, false, "reentrant startup cannot acquire a second singleton")
			helpers.assert_eq(state.created, 1, "only one native watcher is constructed")
			helpers.assert_eq(module.stop(), true)
			helpers.assert_eq(state.stops, 1)
		end)
	end)

	helpers.it("honors stop before a startup session exists (control-native-early-stop)", function()
		local nested
		with_native_world({ on_log_start = function(module) nested = module.stop() end }, function(module, state)
			helpers.assert_eq(state.start(), false, "retired startup cannot later publish its native owner")
			helpers.assert_eq(nested, false, "an in-flight startup reservation is not a settled stop")
			helpers.assert_eq(state.created, 0)
			helpers.assert_eq(module.stop(), true)
		end)
	end)

	helpers.it("completes the request in the reloaded Lua state", function()
		local files = { [FOLDER .. "/reload.result"] =
			'{"schema":1,"request_id":"mac-1","state":"requested","driver_pid":777,"successor_pid":777}\n' }
		local state = world(function() return true end, files)
		state.session:start()
		helpers.assert_eq(files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"mac-1","state":"completed","driver_pid":777,"successor_pid":777}\n')
	end)

	helpers.it("refuses a stale token without asking for a reload", function()
		local state = world(function() return true end)
		state.session:start()
		ring(state, (TOKEN:gsub("0", "1")), "stale")
		helpers.assert_eq(#state.calls, 0, "an unauthenticated request never reaches the coordinator")
		helpers.assert_eq(state.files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"stale","state":"refused","driver_pid":777,"reason":"unauthenticated"}\n')
	end)

	helpers.it("reports a coordinator refusal and an abort as refused", function()
		local state = world(function() return false end)
		state.session:start()
		ring(state, TOKEN, "busy-1")
		helpers.assert_eq(state.files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"busy-1","state":"refused","driver_pid":777,"reason":"busy"}\n')
		local aborting = world(function(_, on_aborted) on_aborted(); return true end)
		aborting.session:start()
		ring(aborting, TOKEN, "abort-1")
		helpers.assert_eq(aborting.files[FOLDER .. "/reload.result"],
			'{"schema":1,"request_id":"abort-1","state":"refused","driver_pid":777,"reason":"refused"}\n')
	end)

	-- The reloaded state can only complete a request if boot starts the control
	-- after it is complete, and a controlled teardown must retire its watcher.
	helpers.it("starts after a complete boot on the owned controlled reload and stops in teardown", function()
		local init = assert(helpers.read_driver_unit("Storage.set(HS_BOOT_READY_SETTING_KEY, true)"))
		local ready = assert(init:find("Storage.set(HS_BOOT_READY_SETTING_KEY, true)", 1, true))
		local start = init:find('require("infra.driver_control").start({', 1, true)
		helpers.assert_true(start ~= nil and start > ready, "the control starts once boot is complete")
		helpers.assert_true(init:find("return TerminationCoordinator.request_reload_owned(reason, on_aborted)", start, true) ~= nil,
			"a request goes through the owned controlled reload")
		local step = init:find('name = "driver-control",', 1, true)
		helpers.assert_true(step ~= nil and step < ready, "the local teardown retires the control")
		helpers.assert_true(init:find('package.loaded["infra.driver_control"]', step, true) ~= nil)
	end)

	helpers.it("ignores other files in the folder and refuses a second start", function()
		local state = world(function() return true end)
		state.session:start()
		state.watcher({ FOLDER .. "/reload.result", FOLDER .. "/session.json" })
		helpers.assert_eq(#state.deferred, 0, "only the request file rings the session")
		helpers.assert_true(not pcall(state.session.start, state.session), "a second start is refused")
	end)
end)

return true
