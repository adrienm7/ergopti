--- tests/support/system_actions_fixture.lua

--- ==============================================================================
--- MODULE: System Action Fixture Support
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================
local helpers = require("tests.helpers")

local NATIVE_CONSUMERS = {
	"adapters.storage", "adapters.task_lifecycle", "adapters.mouse_control",
	"infra.deferred_work", "infra.fs_dir",
}

local function refresh_native_consumers()
	for _, name in ipairs(NATIVE_CONSUMERS) do package.loaded[name] = nil end
end

--- Loads the system facade using the current scenario overrides.
--- @param overrides table|nil Native contract overrides.
--- @return table system
local function load_system(overrides)
	refresh_native_consumers()
	return helpers.load_with_stubs("modules.shortcuts.actions.system", overrides)
end

--- Executes one complete scenario, including its deferred callbacks.
--- @param callback function Scenario body.
local function with_fixture(callback)
	return helpers.with_stub_scope({
		"hs", "tests.stubs.hs", "modules.shortcuts.actions.system",
		"modules.shortcuts.actions.screenshot_save", "modules.shortcuts.actions.text",
		"modules.gestures", "infra.keycodes", "infra.logger", "infra.notifications",
		"adapters.event_provenance", "adapters.file_system", "adapters.key_state",
		"adapters.shell_runner", "adapters.synthetic_input", "adapters.timer_scheduler",
		"adapters.storage", "adapters.task_lifecycle", "adapters.mouse_control",
		"infra.deferred_work", "infra.fs_dir", "modules.keymap.utils",
		"modules.keymap.terminator_replay", "adapters.text_sender", "adapters.clipboard",
	}, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.gestures"] = {}
		return callback()
	end)
end



--- Adds the Quartz property accessor that distinguishes an explicitly untagged
--- physical event from a malformed/unreadable test double.
--- @param event table Partial event double.
--- @return table event
local function as_physical(event)
	event.getProperty = event.getProperty or function() return 0 end
	return event
end


--- Fires the most recently scheduled retained timer.
--- @param hs_table table Active Hammerspoon stub.
local function fire_latest_timer(hs_table)
	local timers = hs_table.timer.__timers
	local latest = timers[#timers]
	helpers.assert_not_nil(latest, "the eventtap action must schedule a post-return timer")
	if latest then latest:fire() end
end


--- Fires the retained FIFO dispatcher used by SyntheticInput.defer_after_callback.
--- It is created before any per-action timer, so selecting the first running
--- zero-delay handle avoids accidentally firing a broker/confirmation timer.
--- @param hs_table table Active Hammerspoon stub.
local function fire_post_callback_actions(hs_table)
	for _, candidate in ipairs(hs_table.timer.__timers or {}) do
		if candidate.running and candidate.delay == 0 and type(candidate.fire) == "function" then
			candidate:fire()
			return
		end
	end
	error("no retained post-eventtap dispatcher is running", 2)
end


--- Returns a shallow contract-preserving override table.
--- Tests replace only the native methods they observe; every other field stays
--- available so fail-fast adapters still load against a realistic hs surface.
--- @param base table Shared hs stub API.
--- @param overrides table Methods replaced by the fixture.
--- @return table merged
local function extend_contract(base, overrides)
	local merged = {}
	for key, value in pairs(base) do merged[key] = value end
	for key, value in pairs(overrides) do merged[key] = value end
	return merged
end


--- Loads an isolated complete hs contract for a partial native-API fixture.
--- @return table hs_contract
local function fresh_hs_contract()
	package.loaded["tests.stubs.hs"] = nil
	local contract = require("tests.stubs.hs")
	contract.__reset()
	return contract
end


local function load_capslock_fixture(toggle_impl)
	package.loaded["modules.shortcuts.actions.system"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.key_state"] = {
		toggle_capslock = toggle_impl,
	}
	package.loaded["infra.keycodes"] = nil

	local logs = { debug = {}, error = {} }
	local logger = helpers.make_logger_stub()
	logger.debug = function(_, format, ...)
		local message = string.format(format, ...)
		if message:find("CapsLock", 1, true) then
			logs.debug[#logs.debug + 1] = message
		end
	end
	logger.error = function(_, format, ...)
		logs.error[#logs.error + 1] = string.format(format, ...)
	end
	package.loaded["infra.logger"] = logger

	local raw_key_attempts = 0
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function()
			raw_key_attempts = raw_key_attempts + 1
			return true
		end,
	}
	local system = load_system()
	return system, logs, function() return raw_key_attempts end
end


-- Guards the fix for the 7b16a3f5 regression that replaced math.huge with 2.0
-- seconds (banner disappeared after 2s), and the close path on auto-deactivation.
-- Rules:
--   1. toggle ON  → hs.alert.show called with math.huge duration
--   2. toggle OFF → the banner is closed (unconditionally)
--   3. auto-deactivation → same, regardless of what show returned
--
-- The close MECHANISM is deliberately not asserted here beyond "the banner went
-- away": closeAll used to dismiss every alert on screen, so the normal path now
-- targets the stored id via closeSpecific and only the no-id path falls back to
-- closeAll. These tests therefore count either call as "banner closed", which is
-- the invariant they were written to protect. The collateral-dismissal guard
-- itself lives in its own test below.


-- Locks the two hard-won wrap-eventtap rules:
--   1. Alt (Option) must NOT block wrapping — Ergopti's wrap symbols sit on the
--      AltGr layer and carry the alt flag (the original bug excluded alt, so no
--      AltGr symbol ever wrapped).
--   2. When no selection is readable (nothing selected, or an app like VS Code
--      that hides AXSelectedText), the symbol must pass through (never swallowed).


-- Shared factory used by shortcuts-actions-1 and shortcuts-actions-2 tests.
-- Returns (sys, spy) where spy = { captured_cb, do_after_calls, exec_calls }.
-- Uses a table reference for captured_cb so updates made when bind_instant_screenshot()
-- calls eventtap.new are visible AFTER the call (Lua scalars are returned by value;
-- updating an upvalue after the function returns cannot be seen by the caller).
-- window_override: optional `window` stub table (defaults to a window with id=42).
local function make_sys_screenshot_spies(window_override)
	package.loaded["infra.keycodes"] = nil
	package.loaded["modules.shortcuts.actions.system"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil
	package.loaded["adapters.file_system"] = nil
	package.loaded["modules.shortcuts.actions.screenshot_save"] = nil
	-- lib.notifications uses hs.notify under the hood — stub it so the deferred
	-- screencapture callback (and the nil-id guard branch) don't crash in headless tests.
	package.loaded["infra.notifications"] = { notify = function() end }
	-- The capture goes through adapters.shell_runner, which captures `local hs = hs`
	-- at require-time. Cached from an earlier test file it stays bound to THAT file's
	-- hs stub, so the module under test spawns correctly while the assertions below
	-- read a different stub's records and see nothing. Cleared here rather than in
	-- load_with_stubs: several tests install their own adapter doubles into
	-- package.loaded before calling it, and a blanket adapter sweep wipes those.
	package.loaded["adapters.shell_runner"] = nil

	local spy = { captured_cb = nil, do_after_calls = {}, exec_calls = {}, tasks = {} }
	local contract = fresh_hs_contract()
	local eventtap = extend_contract(contract.eventtap, {
		new = function(_types, cb)
			spy.captured_cb = cb
			return { start = function() end, stop = function() end, isEnabled = function() return true end }
		end,
	})
	local timer = extend_contract(contract.timer, {
		doAfter  = function(delay, fn) table.insert(spy.do_after_calls, { delay = delay, fn = fn }) return { stop = function() end } end,
		doEvery  = function(_d, _fn) return { start = function() end, stop = function() end } end,
		new      = function(_d, _fn) return { start = function() end, stop = function() end } end,
		secondsSinceEpoch = function() return 0 end,
		absoluteTime      = function() return 0 end,
		usleep   = function() end,
	})
	local fs = extend_contract(contract.fs, {
		pathToAbsolute = function(path)
			if path == "~" then return "/tmp/hs015-home" end
			return path
		end,
	})

	local sys = load_system({
		eventtap = eventtap,
		timer    = timer,
		fs       = fs,
		execute  = function(cmd) table.insert(spy.exec_calls, cmd) return "", true, "exit", 0 end,
		-- hs.task is stubbed rather than the ShellRunner module: the capture now
		-- goes through the real adapter, so stubbing at the OS boundary exercises
		-- that wiring instead of asserting against a hand-written double. It also
		-- keeps package.loaded clean — a leaked adapter stub would make every later
		-- test observe a driver that spawns nothing, silently.
		--
		-- The arity is the real one: hs.task.new(path, on_done, args) in the
		-- 3-argument form, and start() RETURNS a boolean (a stub returning nil
		-- would let a refused launch pass as success).
		task = {
			new = function(path, on_done, args)
				local rec = { path = path, on_done = on_done, args = args, started = false }
				table.insert(spy.tasks, rec)
				return {
					start     = function() rec.started = true return true end,
					terminate = function() end,
				}
			end,
		},
		window   = window_override or {
			frontmostWindow = function()
				return { id = function() return 42 end }
			end,
		},
	})
	spy.hs = _G.hs

	return sys, spy
end


--- Delivers the most recent post-eventtap callback in the screenshot fixture.
--- @param spy table Fixture spy.
local function run_screenshot_deferred(spy)
	fire_post_callback_actions(spy.hs)
end

--- Returns the first recorded spawn whose binary basename matches, or nil.
--- @param spy table The spy table from make_sys_screenshot_spies.
--- @param basename string e.g. "mkdir", "screencapture".
--- @return table|nil
local function spawn_of(spy, basename)
	for _, rec in ipairs(spy.tasks) do
		if type(rec.path) == "string" and rec.path:find(basename, 1, true) then return rec end
	end
	return nil
end


--- Flattens a spawn's argv into one searchable string.
--- @param rec table|nil A recorded spawn.
--- @return string
local function argv_of(rec)
	if not rec or type(rec.args) ~= "table" then return "" end
	local parts = {}
	for _, a in ipairs(rec.args) do table.insert(parts, tostring(a)) end
	return table.concat(parts, " ")
end


-- Regression: two synchronous hs.execute calls (mkdir + screencapture) were running
-- inline on the CGEventTap thread, regularly exceeding the dispatch deadline and
-- silently disabling the tap (kCGEventTapDisabledByTimeout).
--
-- The first fix deferred them with hs.timer.doAfter(0, ...). That protected the tap
-- deadline but NOT the driver: the timer body runs on the same single runloop, so
-- the freeze simply moved one tick later, and every keystroke during mkdir +
-- screencapture was still lost. They are now real asynchronous subprocesses, and
-- these cases assert that — a doAfter would no longer satisfy them.


-- Regression: when hs.window.frontmostWindow():id() returns nil (borderless or
-- system windows without a CGWindowID), the old code fell through to
-- "screencapture -l " .. id which concat'd nil and raised an error inside the
-- deferred closure — the screenshot was silently skipped and the eventtap
-- consumed the keystroke without providing feedback.
-- Fix: validate id before constructing the command and show the same warning
-- the "no active window" branch already shows.


-- Regression: bind_wrap_text_if_selected's eventtap callback called text_acts.read_ax_selection()
-- (two synchronous cross-process AX calls) on every keystroke matching a wrap symbol, with zero
-- caching. infra/vscode_bridge.lua documents this exact failure mode and mitigates it with a
-- short-lived TTL cache; this call site had none — a slow AX call risks
-- kCGEventTapDisabledByTimeout, killing the tap. The fix mirrors vscode_bridge's cache pattern.


-- Regression: math.random(m, n) requires integer-representable bounds in Lua 5.4.
-- AWAKE_TICK_MIN_SEC and AWAKE_TICK_MAX_SEC come from Timings.sec() which returns
-- floats (ms / 1000). If a maintainer sets tick_min_ms to e.g. 1500 (→ 1.5),
-- math.random(1.5, 5.0) raises "no integer representation". The fix switches to
-- the float-safe uniform form: min + math.random() * span.


local SyntheticInputStack = require("tests.support.synthetic_input_stack")


--- Loads system.lua and the real provenance producer/consumer against one hs stub.
--- @param options table|nil Optional dependency doubles.
--- @return table fixture
local function load_h01_system(options)
	options = options or {}
	refresh_native_consumers()
	package.loaded["adapters.key_state"] = nil
	package.loaded["infra.notifications"] = nil
	local previous_logger = package.loaded["infra.logger"]
	package.loaded["modules.shortcuts.actions.system"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["modules.shortcuts.actions.text"] = nil
	package.loaded["modules.gestures"] = options.gestures or {}
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["adapters.file_system"] = nil
	package.loaded["modules.shortcuts.actions.screenshot_save"] = nil
	if options.logger then package.loaded["infra.logger"] = options.logger end
	if options.text_actions then
		package.loaded["modules.shortcuts.actions.text"] = options.text_actions
	end
	local system, synthetic = SyntheticInputStack.load(
		"modules.shortcuts.actions.system", options.hs_overrides)
	if options.logger then package.loaded["infra.logger"] = previous_logger end
	return { system = system, synthetic = synthetic, hs = _G.hs }
end


--- Creates one real adapter-tagged keyDown and adds only the native accessors
--- needed by a target tap. The Quartz user-data accessor remains production-real.
--- @param fixture table H01 fixture.
--- @param key string|number Synthetic key value.
--- @param keycode number Native keycode observed by the target tap.
--- @param characters string|nil Decoded characters.
--- @param flags table|nil Modifier flags.
--- @return table event
local function owned_key_down(fixture, key, keycode, characters, flags)
	local tx = fixture.synthetic.begin("unit.system.owned", "replacement")
	local batch = fixture.synthetic.begin_callback(tx)
	fixture.synthetic.keyStroke(batch, {}, key)
	local _, events = fixture.synthetic.finish_callback(batch, true)
	fixture.synthetic.seal(tx)
	local event = events[1]
	event.getType = function() return fixture.hs.eventtap.event.types.keyDown end
	event.getKeyCode = function() return keycode end
	event.getCharacters = function() return characters or "" end
	event.getFlags = function() return flags or {} end
	event.location = function() return { x = 0, y = 0 } end
	return event
end


--- Builds one explicitly untagged physical key event.
local function physical_key_down(fixture, keycode, characters, flags)
	return as_physical({
		getType = function() return fixture.hs.eventtap.event.types.keyDown end,
		getKeyCode = function() return keycode end,
		getCharacters = function() return characters or "" end,
		getFlags = function() return flags or {} end,
		location = function() return { x = 0, y = 0 } end,
	})
end


--- Builds one explicitly untagged physical scroll event.
local function physical_scroll(fixture, delta)
	local delta_property = fixture.hs.eventtap.event.properties.scrollWheelEventDeltaAxis1
	return {
		getType = function() return fixture.hs.eventtap.event.types.scrollWheel end,
		getProperty = function(_, property)
			if property == delta_property then return delta end
			return 0
		end,
	}
end


--- Reinterprets a genuinely tagged adapter event as a scroll event while
--- preserving its exact user-data property.
local function owned_scroll(fixture, delta)
	local event = owned_key_down(fixture, "x", 0, "", {})
	local base_get_property = event.getProperty
	local delta_property = fixture.hs.eventtap.event.properties.scrollWheelEventDeltaAxis1
	event.getType = function() return fixture.hs.eventtap.event.types.scrollWheel end
	event.getProperty = function(self, property)
		if property == delta_property then return delta end
		return base_get_property(self, property)
	end
	return event
end

return {
	load_system = load_system,
	with_fixture = with_fixture,
	as_physical = as_physical,
	fire_latest_timer = fire_latest_timer,
	fire_post_callback_actions = fire_post_callback_actions,
	extend_contract = extend_contract,
	fresh_hs_contract = fresh_hs_contract,
	load_capslock_fixture = load_capslock_fixture,
	make_sys_screenshot_spies = make_sys_screenshot_spies,
	run_screenshot_deferred = run_screenshot_deferred,
	spawn_of = spawn_of,
	argv_of = argv_of,
	load_h01_system = load_h01_system,
	owned_key_down = owned_key_down,
	physical_key_down = physical_key_down,
	physical_scroll = physical_scroll,
	owned_scroll = owned_scroll,
}
