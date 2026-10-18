--- tests/support/main_startup_fixture.lua
--- ==============================================================================
--- MODULE: Actual Main Startup Sequence Fixture
--- DESCRIPTION:
--- Executes the production startup tail in its original source order. Explicit
--- UI, native input and loop ports observe acquisition; no kernel is acquired.
--- ==============================================================================
local M = {}
local helpers = require("tests.helpers")
local Coordinator = require("infra.shutdown_coordinator")
local Gate = require("infra.input_capture_gate")
local Onboarding = require("ui.onboarding.startup")

--- Runs actual Main startup statements through its first real idle callback.
--- @param options table|nil Controlled refusal and synchronous native callback.
--- @return table observed Exact boundary observations and protected result.
function M.run(options)
	options = options or {}
	local file = assert(io.open(os.getenv("ERGOPTI_STARTUP_SOURCE") or helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = file:read("*a"); file:close()
	local first = assert(source:find("\t-- 8.8) Start the keyboard hook adapter", 1, true))
	local last = assert(source:find("\nend\n\n-- The daemon runs under the crash reporter", first, true))
	local installer = assert(source:match("(local function install_signal_handlers%(%).-)%s*%-%- ========================================="))
	local terminal = assert(source:find('local ok_main, err_main =', last, true))
	local observed = { events = {}, grabbed = false, opens = 0, closes = 0, pumps = 0,
		loops = 0, loop_stops = 0, service_stops = 0, callbacks = {}, services = false,
		preparing = false, ui_entered = false, ui_returned = false, signals_active = false, signal_stops = 0,
		application_loops = 0, owner_after_request = false, automation = 0, loop_after_complete = false,
		foreign_loops = 0, layout_refreshes = 0 }
	local env = setmetatable({}, { __index = _G })
	local function record(name) observed.events[#observed.events + 1] = name end
	local function native_callback(boundary)
		if options.on_boundary then options.on_boundary(boundary, observed, env) end
	end
	local function finish_acquisition(boundary)
		if env.shutdown.is_requested() then observed.owner_after_request = true end
		if options.throw_at == boundary then
			observed.preparing = false
			error("controlled acquisition failure at " .. boundary, 0)
		end
		observed.preparing = false
	end
	local function ui(boundary)
		observed.ui_entered, observed.preparing = true, true
		record(boundary)
		native_callback(boundary)
		if options.block == boundary then coroutine.yield("controlled preparation remains blocked") end
		if env.shutdown.is_requested() then observed.acquired_after_request = true end
		observed.services = true
		finish_acquisition(boundary)
		observed.ui_returned = true
		record(boundary .. ".returned")
	end
	local hook = {
		start = function(hook_options)
			observed.hook_options = hook_options
			observed.preparing = true
			record("hook.start"); native_callback("hook.start")
			if options.hook_refused then observed.preparing = false; return false end
			observed.grabbed = true; finish_acquisition("hook.start"); return true
		end,
		isRunning = function() return observed.grabbed end,
		isRecovering = function() return false end,
		stop = function() record("hook.stop"); observed.grabbed = false; return true end,
		emergency_stop = function() record("hook.emergency"); observed.grabbed = false; return true end,
		get_mode = function() return observed.grabbed and "intercept" or "observe" end,
		pump = function()
			record("hook.pump"); observed.pumps = observed.pumps + 1
			observed.pump_blocked = env.input_capture_gate.blocks_text()
			observed.pump_services = observed.services
			if observed.pump_blocked then observed.hook_options.onConsume({}) end
		end,
	}
	local loop = {
		run = function(callbacks)
			record("loop.run"); observed.loops = observed.loops + 1
			if callbacks.onIdle ~= env.shutdown.poll then observed.application_loops = observed.application_loops + 1 end
			if options.loop_throws then error("controlled event loop admission failure", 0) end
			observed.loop_after_complete = observed.loop_after_complete
				or (env.shutdown.is_requested() and not env.shutdown.is_pending())
			callbacks.onIdle()
			if env.shutdown.is_pending() then env.shutdown.poll() end
		end,
		stop = function() record("loop.stop"); observed.loop_stops = observed.loop_stops + 1 end,
		defer = function() return true end,
	}
	local function compile(body)
		if setfenv then return setfenv(assert(loadstring(body, "actual Main startup sequence")), env) end
		return assert(load(body, "actual Main startup sequence", "t", env))
	end
	local noop = function() end
	env.privacy_owners = { watch = { pump = noop } }
	env.shutdown = Coordinator.new({
		pre_wait = { { name = "prepared services", wait_for_ack = true, stop = function()
			record("services.stop")
			observed.service_stops = observed.service_stops + 1
			if observed.preparing then observed.cleanup_inside_preparation = true; return false end
			if options.async_service and observed.service_stops == 1 then return false end
			observed.services = false; return true
		end } },
		final_wait = compile("return " .. assert(source:match("final_wait%s*=%s*(%b{})")))(),
		keyboard_hook = hook, event_loop = loop,
	})
	env.input_capture_gate = Gate.new()
	observed.capture_gate = env.input_capture_gate
	observed.coordinator = env.shutdown
	env.keyboard_hook, env.event_loop = hook, loop
	env.injector = {
		open_fast_channel = function()
			observed.preparing = true
			observed.opens = observed.opens + 1; record("output.open"); native_callback("output.open")
			finish_acquisition("output.open"); return not options.fast_refused
		end,
		close_fast_channel = function() observed.closes = observed.closes + 1; record("output.close"); return true end,
		output_broker = function() return {} end,
		emit_key = noop,
	}
	env.keyboard_layout = {
		refresh = function()
			observed.layout_refreshes = observed.layout_refreshes + 1
			record("layout.refresh"); native_callback("layout.refresh"); return true
		end,
		is_ready = function() return true end,
		publish_current_capture = function()
			observed.preparing = true
			record("layout.publish"); native_callback("layout.publish")
			finish_acquisition("layout.publish")
			return not options.layout_refused
		end,
	}
	env.opts = { tray = true, grab = true, layout = "qwerty", dry_run = false }
	env.device, env.mapping_count, env.config_path, env.SCRIPT_DIR = "/controlled/event0", 1, "/controlled/config.toml", "/controlled/driver"
	env.BootProfiler = { stage = function(name)
		if name == "input hooks" then native_callback("input.stage") end
	end, stage_done = noop, complete = function() record("boot.complete"); return 0 end, elapsed_ms = function() return 0 end }
	env.Logger = { info = function(_, message)
		if message == "Keyboard hook started in %s mode." then native_callback("hook.log") end
	end, error = noop, warn = noop, debug = noop, success = noop, flush_repeats = noop }
	if options.terminal_logger_throws then env.Logger.error = function() error("controlled terminal logger failure", 0) end end
	env.tray_menu = { setIcon = function() ui("tray") end,
		setFallbackMenu = function(_, _, quit) observed.tray_quit = quit end, pump = noop, destroy = noop }
	env.TapHold = { is_active = function() return true end }
	env.MagicKey = { get = function() return "★" end, init = noop }
	env.keylogger = { hold_accounting_token = noop, pump_flush = noop, get_categories = function() return {} end,
		get_session_stats = function() return { keystrokes = 0, words = 0, duration_ms = 0 } end }
	env.capture_owned_scancodes = {}
	env.script_actions = { is_paused = function() return false end }
	env.secure_focus_guard = { has_context_operation = function() return false end, blocks_text = function() return false end }
	env.engine = { reset = function() observed.automation = observed.automation + 1 end }
	env.emit_diagnostic_snapshot = function() record("diagnostics") end
	env.RuntimeGuard = { call = function(_, callback) callback(); return true end, optional_require = function() return nil end }
	env.webview_manager = { set_daemon_state = function(state) observed.daemon_state = state end,
		show = function()
			ui("onboarding")
			env.input_capture_gate.acquire("onboarding", 1)
			return true
		end }
	env.file_watchers = { start = function()
		ui("watchers"); observed.services = true
	end, stop = function() record("watchers.stop") end, has_inotify = function() return true end }
	env.require = function(name)
		if name == "infra.signal_handlers" then
			return { start = function(callbacks)
				observed.callbacks = callbacks; observed.signals_active = true; record("signals.start")
				return not options.signal_refused, "controlled signal admission refusal"
			end, stop = function()
				record("signals.stop"); observed.signal_stops = observed.signal_stops + 1
				observed.signals_active = false; return true
			end }
		elseif name == "infra.input_access" then
			return { report = function() observed.access_reported = true; return 1 end }
		elseif name == "infra.i18n" then
			return { init = noop, set_trigger_provider = noop, get = function(key) return key end }
		elseif name == "infra.config_paths" then
			return { config = function() return "/controlled/config.toml" end }
		elseif name == "ui.onboarding.startup" then
			return { run = function(opts)
				opts.open = function() return nil, "controlled missing config", 2 end
				return Onboarding.run(opts)
			end }
		end
		error("Unexpected startup dependency: " .. tostring(name), 0)
	end
	env.os = setmetatable({ exit = function(code) error("controlled process exit " .. tostring(code), 0) end }, { __index = os })
	env.CrashReporter = { protect = function(_, callback)
		local ok, failure = pcall(callback)
		observed.protected_error = failure
		-- The protected Main frame, including its native constructor, has unwound.
		observed.preparing = false
		if options.reporter_throws then error("controlled crash reporter failure after unwind", 0) end
		return ok, failure
	end }
	local run = coroutine.create(function()
		return pcall(compile("local function main()\n" .. installer .. "\n" .. source:sub(first, last - 1)
			.. "\nend\n" .. source:sub(terminal)))
	end)
	local resumed, result, detail = coroutine.resume(run)
	observed.resumed = resumed
	observed.blocked = coroutine.status(run) == "suspended"
	if observed.blocked then observed.error = result
	elseif resumed then observed.ok, observed.error = result, detail
	else observed.ok, observed.error = false, result end
	return observed
end

return M
