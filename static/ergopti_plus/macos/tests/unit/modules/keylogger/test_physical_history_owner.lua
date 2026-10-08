--- tests/unit/modules/keylogger/test_physical_history_owner.lua

--- Exercises real boot composition over modelled OS ports, without native authority.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.keylogger_provenance_fixture")
local OWNERS = {
	"hs", "tests.stubs.hs", "infra.logger", "infra.manifest_reader", "infra.config_paths",
	"infra.dialog_util", "infra.teardown_transaction", "infra.preferences", "adapters.file_system",
	"infra.notifications", "infra.i18n", "infra.deferred_work", "ui.menu.menu_state",
	"ui.menu.keymap_lifecycle", "modules.keylogger", "modules.keylogger.init",
	"modules.keylogger.physical_history_owner", "modules.keylogger.physical_history_session",
	"modules.keylogger.physical_capture", "modules.keylogger.physical_clock",
	"modules.keylogger.physical_key_identity", "modules.keylogger.log_manager",
	"modules.keylogger.context_tracker", "modules.keylogger.kc_bridge", "modules.keylogger.watchers",
	"modules.keylogger.timestamp", "modules.keylogger.physical_accounting_mode",
	"modules.shortcuts.script_control", "adapters.shell_runner", "adapters.synthetic_input",
	"adapters.event_provenance", "adapters.process_lifecycle", "adapters.keyboard_hook",
	"adapters.input_source_broker", "adapters.storage", "adapters.timer_scheduler",
	"adapters.physical_observation_clock", "adapters.physical_history_context",
	"keylogger.physical_lifecycle_observation", "keylogger.physical_configuration_observation",
	"modules.keylogger.aggregator.events", "modules.keylogger.aggregator.state",
	"modules.keylogger.aggregator.core", "modules.keylogger.aggregator.physical", "ui.metrics_typing.init",
}
local SCRIPT_CONTROL = { is_paused = function() return false end, pause_bindings = function() return true end }

--- Keeps the old provenance fixture intact while replacing its metadata-only double.
local function with_fixture(callback)
	return helpers.with_stub_scope(OWNERS, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local manifest = require("infra.manifest_reader")
		local loader = helpers.load_with_stubs
		helpers.load_with_stubs = function(name, overrides)
			if name == "modules.keylogger.init" then package.loaded["infra.manifest_reader"] = manifest end
			return loader(name, overrides)
		end
		local loaded, fixture = xpcall(Fixture.load_keylogger, debug.traceback)
		helpers.load_with_stubs = loader
		if not loaded then error(fixture, 0) end
		package.loaded["modules.keylogger"] = fixture.keylogger
		local controls = { notices = 0, producers = 0, cleanups = 0, native_calls = 0, manifest = manifest }
		local function unavailable_port()
			controls.native_calls = controls.native_calls + 1
			error("unavailable boot must not acquire a native stream port")
		end
		fixture.hs.task.new = unavailable_port
		local tracker = package.loaded["modules.keylogger.context_tracker"]
		tracker.bind_physical_correlated_context_observer = unavailable_port
		tracker.sample_physical_context = unavailable_port
		package.loaded["modules.keylogger.watchers"].bind_physical_lifecycle_observer = unavailable_port
		package.loaded["modules.shortcuts.script_control"] = { bind_physical_pause_observer = unavailable_port }
		package.loaded["adapters.shell_runner"] = { spawn = unavailable_port }
		local logs = package.loaded["modules.keylogger.log_manager"]
		logs.log_physical_press, logs.log_physical_release = unavailable_port, unavailable_port
		local original_stop = logs.stop
		logs.stop = function(...)
			controls.cleanups = controls.cleanups + 1
			return original_stop(...)
		end
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.notifications"] = { notify = function(title, body, kind)
			controls.notices = controls.notices + 1
			controls.notice = { title = title, body = body, kind = kind }
			if controls.notice_hook then return controls.notice_hook(fixture, controls) end
			return true
		end }
		local process = package.loaded["adapters.process_lifecycle"]
		process.start = function()
			controls.producers = controls.producers + 1
			if controls.producer_hook then controls.producer_hook(fixture, controls) end
			return true
		end
		fixture.hs.caffeinate = { watcher = { new = function()
			local watcher = {}
			function watcher:start() return self end
			function watcher:stop() return self end
			return watcher
		end } }
		local function body() return callback(fixture, controls) end
		local outcome = table.pack(xpcall(body, debug.traceback))
		if package.loaded["modules.keylogger.physical_history_session"] then
			package.loaded["modules.keylogger.physical_history_session"].stop()
		end
		if not outcome[1] then error(outcome[2], 0) end
		return table.unpack(outcome, 2, outcome.n)
	end)
end

local function accounting() return require("modules.keylogger.physical_accounting_mode") end
local function owner() return package.loaded["modules.keylogger.physical_history_owner"] end
local function select(fixture, value)
	helpers.assert_eq(type(fixture.keylogger.set_physical_source), "function", "the real boot selector must exist")
	return fixture.keylogger.set_physical_source(value)
end
local function sync(fixture, state)
	return require("ui.menu.menu_state").sync_state_to_modules(state, {}, false, {
		core_mods = { keylogger = fixture.keylogger, shortcuts_mod = SCRIPT_CONTROL }, hotstring_editor = {},
	})
end
local function fire_deferred(fixture)
	for _, timer in ipairs(fixture.hs.timer.__timers) do
		if timer.running and (timer.delay == 0.5 or timer.delay == 0) then timer:fire() end
	end
end
local function assert_dormant(controls)
	helpers.assert_eq(owner(), nil, "OFF and the declared ledger default must not load the owner")
	helpers.assert_eq(package.loaded["modules.keylogger.physical_history_session"], nil)
	helpers.assert_eq(controls.native_calls, 0)
	helpers.assert_eq(controls.notices, 0)
end
local function with_source(fixture, source, callback)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
	local called, detail = xpcall(function()
		package.loaded["adapters.file_system"] = nil
		local preferences = require("infra.preferences")
		local flat, status = preferences.load(path)
		callback(preferences, flat, status, path)
		local read = assert(io.open(path, "rb")); local bytes = read:read("*a"); read:close()
		helpers.assert_eq(bytes, source, "boot hydration must preserve the actual source bytes")
	end, debug.traceback)
	os.remove(path)
	if not called then error(detail, 0) end
end




helpers.describe("Physical selector status and callback admission", function()
	for _, value in ipairs({ "ledger", "unknown" }) do
		helpers.it("rejects notice callback selector mutation to " .. value .. " before acquisition", function()
			with_fixture(function(fixture, controls)
				controls.notice_hook = function()
					helpers.assert_eq(fixture.keylogger.set_physical_source(value), false)
					return true
				end
				helpers.assert_eq(select(fixture, "stream"), true)
				helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
				helpers.assert_eq(fixture.state.is_enabled, false)
				helpers.assert_eq(controls.producers, 0); helpers.assert_eq(controls.notices, 1)
			end)
		end)
	end

	helpers.it("reports the retained manager's actual suspended state after ordinary OFF", function()
		with_fixture(function(fixture)
			helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
			helpers.assert_eq(fixture.keylogger.stop(), true)
			helpers.assert_eq(owner().status().state, "suspended")
			helpers.assert_eq(accounting().legacy_credits(), false)
		end)
	end)

	helpers.it("reports actual retirement when root has already stopped the captured Session", function()
		with_fixture(function(fixture)
			helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
			local session = package.loaded["modules.keylogger.physical_history_session"]
			helpers.assert_eq(session.stop(), true); helpers.assert_eq(session.retired(), true)
			helpers.assert_eq(owner().status().state, "retired")
		end)
	end)
end)

helpers.describe("Actual physical settlement and callback debt", function()
	helpers.it("refuses the actual held-modifier settlement before producer acquisition", function()
		with_fixture(function(fixture, controls)
			fixture.state.modifier_down_at = { [9999] = 1 }
			helpers.assert_eq(select(fixture, "stream"), true)
			helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
			helpers.assert_eq(fixture.state.is_enabled, false)
			helpers.assert_eq(controls.producers, 0); helpers.assert_eq(controls.notices, 0)
			helpers.assert_eq(accounting().legacy_credits(), true, "refused selection has not acquired GAP")
			local same_owner = owner()
			fixture.state.modifier_down_at = {}
			helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), true)
			helpers.assert_true(rawequal(owner(), same_owner))
			helpers.assert_eq(accounting().legacy_credits(), false)
			helpers.assert_eq(controls.native_calls, 0)
		end)
	end)

	helpers.it("retains actual final accounting-release debt ahead of context, log and ledger cleanup", function()
		with_fixture(function(fixture, controls)
			helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
			fixture.state.modifier_suppressed_releases = { [9999] = true }
			local cleanups, drains = controls.cleanups, 0
			package.loaded["modules.keylogger.kc_bridge"].stop = function() drains = drains + 1; return true end
			helpers.assert_eq(fixture.keylogger.shutdown(), false)
			helpers.assert_eq(controls.cleanups, cleanups); helpers.assert_eq(drains, 0)
			helpers.assert_eq(accounting().legacy_credits(), false)
			helpers.assert_eq(package.loaded["modules.keylogger.physical_history_session"].retired(), false)
			helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
			fixture.state.modifier_suppressed_releases = {}
			helpers.assert_eq(fixture.keylogger.shutdown(), true)
			helpers.assert_eq(accounting().legacy_credits(), true); helpers.assert_eq(drains, 1)
		end)
	end)

	helpers.it("does not release dependent owners from inside the actual root stop callback", function()
		with_fixture(function(fixture, controls)
			helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
			local session = package.loaded["modules.keylogger.physical_history_session"]
			local cleanups, drains, callbacks, inside = controls.cleanups, 0, 0, nil
			package.loaded["modules.keylogger.kc_bridge"].stop = function() drains = drains + 1; return true end
			helpers.assert_eq(session.stop(function()
				callbacks = callbacks + 1
				inside = fixture.keylogger.shutdown()
				helpers.assert_eq(session.retired(), false)
			end), true)
			helpers.assert_eq(inside, false)
			helpers.assert_eq(controls.cleanups, cleanups); helpers.assert_eq(drains, 0)
			helpers.assert_eq(session.retired(), true)
			helpers.assert_eq(fixture.keylogger.shutdown(), true)
			helpers.assert_eq(callbacks, 1); helpers.assert_eq(drains, 1)
		end)
	end)

	helpers.it("uses one initialization attempt when the captured constructor throws", function()
		with_fixture(function(fixture, controls)
			local session = require("modules.keylogger.physical_history_session")
			local calls = 0
			session.init = function() calls = calls + 1; error("private constructor failure") end
			helpers.assert_eq(select(fixture, "stream"), true)
			helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
			helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(controls.producers, 0); helpers.assert_eq(controls.notices, 0)
			helpers.assert_eq(owner().status().state, "refused")
		end)
	end)
end)

helpers.describe("Captured physical retirement dependency", function()
	for _, action in ipairs({ "stop", "shutdown" }) do
		helpers.it("accepts the same Session already retired by the root fence before " .. action, function()
			with_fixture(function(fixture, controls)
				helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
				local session = package.loaded["modules.keylogger.physical_history_session"]
				local callbacks, inside = 0, nil
				local observer = function()
					callbacks = callbacks + 1; inside = session.retired()
				end
				helpers.assert_eq(session.stop(observer), true)
				helpers.assert_eq(inside, false, "actual callback unwind precedes retirement")
				helpers.assert_eq(session.retired(), true)
				helpers.assert_eq(fixture.keylogger[action](), true)
				helpers.assert_eq(callbacks, 1, "dependent teardown must not steal or replace the root observer")
				helpers.assert_eq(controls.native_calls, 0)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "throw", "replaced" }) do
		helpers.it("blocks dependent terminal drain on " .. mode .. " captured retirement observation", function()
			with_fixture(function(fixture, controls)
				local session = require("modules.keylogger.physical_history_session")
				local actual_retired, refuse = session.retired, false
				local observed = function()
					if refuse then
						if mode == "throw" then error("private observation refusal") end
						return false
					end
					return actual_retired()
				end
				if mode ~= "replaced" then session.retired = observed end
				helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
				local drains = 0
				package.loaded["modules.keylogger.kc_bridge"].stop = function() drains = drains + 1; return true end
				local cleanups = controls.cleanups
				if mode == "replaced" then session.retired = observed else refuse = true end
				helpers.assert_eq(fixture.keylogger.shutdown(), false)
				helpers.assert_eq(drains, 0, "the dependent ledger drain cannot bypass the physical fence")
				helpers.assert_eq(controls.cleanups, cleanups, "log cleanup is dependent on physical retirement")
				refuse = false
				if mode == "replaced" then session.retired = actual_retired end
				helpers.assert_eq(fixture.keylogger.shutdown(), true)
				helpers.assert_eq(drains, 1)
			end)
		end)
	end
end)

helpers.describe("Declared physical source boot composition", function()
	helpers.it("transfers valid stream from actual Preferences through MenuState before the first producer", function()
		with_fixture(function(fixture, controls)
			with_source(fixture, '[metrics]\nenabled = true\nphysical_source = "stream"\n', function(_, flat, status)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(flat.keylogger_physical_source, "stream")
				controls.producer_hook = function()
					helpers.assert_eq(accounting().legacy_credits(), false, "GAP must precede the actual producer call")
				end
				helpers.assert_eq(sync(fixture, flat), true)
				fire_deferred(fixture)
				helpers.assert_eq(fixture.state.is_enabled, true)
				helpers.assert_eq(controls.producers, 1)
				helpers.assert_eq(owner().status().state, "unavailable")
				helpers.assert_eq(controls.native_calls, 0)
			end)
		end)
	end)

	helpers.it("selects GAP for an explicit MenuState stream even before the new owner API exists", function()
		with_fixture(function(fixture, controls)
			controls.producer_hook = function() helpers.assert_eq(accounting().legacy_credits(), false) end
			helpers.assert_eq(sync(fixture, { keylogger_enabled = true, keylogger_physical_source = "stream" }), true)
			fire_deferred(fixture)
			helpers.assert_eq(fixture.state.is_enabled, true)
			helpers.assert_eq(accounting().legacy_credits(), false)
			helpers.assert_eq(controls.producers, 1)
		end)
	end)

	helpers.it("uses the real generated catalogue for the absent production preference", function()
		with_fixture(function(fixture, controls)
			local declared = controls.manifest.default_for("metrics.physical_source")
			helpers.assert_eq(declared, "ledger")
			helpers.assert_eq(fixture.keylogger.DEFAULT_STATE.keylogger_physical_source, declared)
			with_source(fixture, '[metrics]\nenabled = true\n', function(_, flat, status)
				helpers.assert_eq(status, "ok"); helpers.assert_eq(flat.keylogger_physical_source, nil)
				helpers.assert_eq(sync(fixture, flat), true)
				fire_deferred(fixture)
				helpers.assert_eq(fixture.state.is_enabled, true)
				assert_dormant(controls)
			end)
		end)
	end)

	for _, token in ipairs({ 'true', 'false', '7', '"unknown"', '{}' }) do
		helpers.it("keeps typed outdated source " .. token .. " untouched and uses only the admitted default", function()
			with_fixture(function(fixture, controls)
				with_source(fixture, '[metrics]\nenabled = true\nphysical_source = ' .. token .. '\n', function(_, flat, status)
					helpers.assert_eq(status, "ok"); helpers.assert_eq(flat.keylogger_physical_source, nil)
					helpers.assert_eq(sync(fixture, flat), true)
					fire_deferred(fixture)
					helpers.assert_eq(fixture.state.is_enabled, true)
					assert_dormant(controls)
				end)
			end)
		end)
	end

	for _, source in ipairs({ "ledger", "stream" }) do
		helpers.it("records " .. source .. " OFF without loading or spawning an owner", function()
			with_fixture(function(fixture, controls)
				helpers.assert_eq(select(fixture, source), true)
				helpers.assert_eq(fixture.keylogger.stop(), true)
				assert_dormant(controls)
				helpers.assert_eq(fixture.state.is_enabled, false)
			end)
		end)
	end

	helpers.it("preserves the unselected legacy direct-start contract", function()
		with_fixture(function(fixture, controls)
			fixture.start(SCRIPT_CONTROL)
			helpers.assert_eq(accounting().legacy_credits(), true)
			assert_dormant(controls)
			helpers.assert_eq(fixture.keylogger.stop(), true)
		end)
	end)

	for _, row in ipairs({ {}, { value = true }, { value = false }, { value = "unknown" }, { value = 7 } }) do
		helpers.it("refuses explicit invalid source " .. tostring(row.value) .. " before producer acquisition", function()
			with_fixture(function(fixture, controls)
				helpers.assert_eq(select(fixture, row.value), false)
				helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
				helpers.assert_eq(fixture.state.is_enabled, false)
				helpers.assert_eq(controls.producers, 0)
				assert_dormant(controls)
			end)
		end)
	end

	helpers.it("keeps one unavailable identity and one notice across OFF and ON", function()
		with_fixture(function(fixture, controls)
			helpers.assert_eq(select(fixture, "stream"), true)
			fixture.start(SCRIPT_CONTROL)
			local original = owner()
			helpers.assert_eq(original.status().state, "unavailable")
			helpers.assert_eq(controls.notices, 1)
			helpers.assert_eq(controls.notice.kind, "warning")
			helpers.assert_eq(fixture.keylogger.stop(), true)
			helpers.assert_eq(accounting().legacy_credits(), false, "ordinary OFF retains stream GAP custody")
			helpers.assert_eq(select(fixture, "stream"), true)
			helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), true)
			helpers.assert_true(rawequal(owner(), original))
			helpers.assert_eq(controls.notices, 1); helpers.assert_eq(controls.native_calls, 0)
		end)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("records notification " .. mode .. " without inventing delivery or native readiness", function()
			with_fixture(function(fixture, controls)
				controls.notice_hook = function() if mode == "throw" then error("private notice failure") end; return false end
				helpers.assert_eq(select(fixture, "stream"), true)
				fixture.start(SCRIPT_CONTROL)
				helpers.assert_eq(owner().status().state, "unavailable")
				helpers.assert_eq(owner().status().notice_attempted, true)
				helpers.assert_eq(owner().status().notice_delivered, false)
				helpers.assert_eq(controls.notices, 1); helpers.assert_eq(controls.native_calls, 0)
			end)
		end)
	end

	for _, action in ipairs({ "stop", "shutdown", "start" }) do
		helpers.it("refuses notice callback reentry through " .. action .. " without stale activation", function()
			with_fixture(function(fixture, controls)
				controls.notice_hook = function()
					if action == "start" then return fixture.keylogger.start(SCRIPT_CONTROL) end
					fixture.keylogger[action](); return true
				end
				helpers.assert_eq(select(fixture, "stream"), true)
				helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
				helpers.assert_eq(fixture.state.is_enabled, false)
				helpers.assert_eq(controls.producers, 0); helpers.assert_eq(controls.notices, 1)
				helpers.assert_eq(controls.native_calls, 0)
			end)
		end)
	end

	helpers.it("rejects a source transition after activation until controlled reload", function()
		with_fixture(function(fixture, controls)
			helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
			local original = owner()
			helpers.assert_eq(fixture.keylogger.stop(), true)
			helpers.assert_eq(select(fixture, "ledger"), false)
			helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
			helpers.assert_true(rawequal(owner(), original))
			helpers.assert_eq(accounting().legacy_credits(), false)
			helpers.assert_eq(controls.notices, 1)
		end)
	end)

	helpers.it("observes actual final retirement before releasing dependent owners", function()
		with_fixture(function(fixture, controls)
			helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
			local session = package.loaded["modules.keylogger.physical_history_session"]
			local retired = session.retired
			local logs = package.loaded["modules.keylogger.log_manager"]
			logs.stop = function()
				helpers.assert_eq(retired(), true, "final dependent cleanup requires the original observed retirement")
				controls.cleanups = controls.cleanups + 1
				return true
			end
			helpers.assert_eq(fixture.keylogger.shutdown(), true)
			helpers.assert_eq(retired(), true)
			helpers.assert_eq(accounting().legacy_credits(), true)
			helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false, "final shutdown never creates a second owner")
			helpers.assert_eq(controls.native_calls, 0)
		end)
	end)
end)

helpers.describe("Unavailable source observation boundaries", function()
	helpers.it("latches the once-only notice attempt before the foreign delivery callback", function()
		with_fixture(function(fixture, controls)
			controls.notice_hook = function()
				helpers.assert_eq(owner().status().notice_attempted, true)
				helpers.assert_eq(owner().status().notice_delivered, false)
				return true
			end
			helpers.assert_eq(select(fixture, "stream"), true); fixture.start(SCRIPT_CONTROL)
			helpers.assert_eq(owner().status().notice_delivered, true)
			helpers.assert_eq(controls.native_calls, 0)
		end)
	end)

	for _, token in ipairs({ 'true', 'false', '7', '"unknown"', '{}' }) do
		helpers.it("reports typed outdated source " .. token .. " instead of granting an admitted current view", function()
			with_fixture(function(fixture)
				with_source(fixture, '[metrics]\nenabled = true\nphysical_source = ' .. token .. '\n', function(preferences, flat, status, path)
					helpers.assert_eq(status, "ok"); helpers.assert_eq(flat.keylogger_physical_source, nil)
					helpers.assert_eq(preferences.current_view(path), nil,
						"the original typed outdated policy must refuse a complete admitted current view")
				end)
			end)
		end)
	end
end)

helpers.describe("Dormant unavailable manager clock boundary", function()
	helpers.it("prepares the actual unavailable manager without reading a clock or spawning a task", function()
		with_fixture(function(fixture, controls)
			fixture.hs.timer.absoluteTime = function() error("unavailable manager must not read native time") end
			local physical_owner = require("modules.keylogger.physical_history_owner")
			helpers.assert_eq(physical_owner.prepare(), true)
			helpers.assert_eq(physical_owner.status().state, "unavailable")
			helpers.assert_eq(controls.producers, 0); helpers.assert_eq(controls.native_calls, 0)
			helpers.assert_eq(fixture.state.is_enabled, false)
			helpers.assert_eq(physical_owner.stop(true), true)
			helpers.assert_eq(physical_owner.retired(), true)
		end)
	end)
end)

helpers.describe("Direct start freezes boot source admission", function()
	for _, value in ipairs({ "ledger", "stream" }) do
		for _, stopped in ipairs({ false, true }) do
			helpers.it("refuses first selector " .. value .. " after an unselected direct start (stopped=" .. tostring(stopped) .. ")", function()
				with_fixture(function(fixture, controls)
					fixture.start(SCRIPT_CONTROL)
					helpers.assert_eq(fixture.state.is_enabled, true)
					helpers.assert_true(controls.producers > 0)
					if stopped then helpers.assert_eq(fixture.keylogger.stop(), true) end
					local acquired = controls.producers
					helpers.assert_eq(select(fixture, value), false, "first admission after producer acquisition requires controlled reload")
					helpers.assert_eq(fixture.keylogger.start(SCRIPT_CONTROL), false)
					helpers.assert_eq(controls.producers, acquired)
					assert_dormant(controls)
					helpers.assert_eq(accounting().legacy_credits(), true)
				end)
			end)
		end
	end
end)

helpers.describe("Retirement query retains exact Session identity", function()
	for _, action in ipairs({ "retired", "stop" }) do
		helpers.it("refuses query-time public port replacement through " .. action, function()
			with_fixture(function(fixture, controls)
				assert(select(fixture, "stream") == true)
				fixture.start(SCRIPT_CONTROL)
				local session = package.loaded["modules.keylogger.physical_history_session"]
				local original_retired = session.retired
				local callbacks = 0
				fixture.state.modifier_suppressed_releases = { [9999] = true }
				assert(session.stop(function()
					callbacks = callbacks + 1
					session.retired = function() return false end
				end) == true)
				assert(original_retired() == false and callbacks == 0)
				fixture.state.modifier_suppressed_releases = {}
				local result
				if action == "retired" then result = owner().retired()
				else result = owner().stop(false) end
				local replaced = not rawequal(session.retired, original_retired)
				session.retired = original_retired
				assert(original_retired() == true)
				assert(replaced and callbacks == 1)
				helpers.assert_eq(result, false, "actual retirement occurred but exact public-port admission changed during the query")
				helpers.assert_eq(controls.native_calls, 0)
			end)
		end)
	end
end)
