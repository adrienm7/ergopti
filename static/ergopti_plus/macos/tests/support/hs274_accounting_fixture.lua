--- tests/support/hs274_accounting_fixture.lua

--- ==============================================================================
--- MODULE: HS-274 Accounting Fixture
--- DESCRIPTION:
--- Drives the real keylogger event callback and the real metrics aggregator
--- for the HS-274 regressions ported from
--- docs/audits/hammerspoon/2026_09_08/proofs/. Only persistence and OS
--- lifecycle boundaries are doubles (tests.support.keylogger_provenance_fixture):
--- the keyDown and flagsChanged branches, their meta.kc decision and the
--- aggregator's kc_ngram credits are production code.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.keylogger_provenance_fixture")

local M = {}

-- Every module the scenario loads or replaces, restored after each run so no
-- keylogger, aggregator or accounting state leaks into a sibling test.
local OWNED_MODULES = {
	"hs", "tests.stubs.hs", "infra.logger", "infra.manifest_reader", "infra.config_paths",
	"infra.dialog_util", "infra.teardown_transaction", "modules.keylogger.init",
	"modules.keylogger.log_manager", "modules.keylogger.context_tracker",
	"modules.keylogger.kc_bridge", "modules.keylogger.watchers", "modules.keylogger.timestamp",
	"modules.keylogger.physical_accounting_mode", "adapters.synthetic_input", "adapters.event_provenance", "adapters.process_lifecycle",
	"adapters.keyboard_hook", "adapters.input_source_broker", "adapters.storage",
	"adapters.timer_scheduler", "modules.keylogger.aggregator.events",
	"modules.keylogger.aggregator.state", "modules.keylogger.aggregator.core",
	"modules.keylogger.aggregator.physical", "ui.metrics_typing.init",
}

-- The calendar day and application every scenario records under.
local DAY = "2026-09-08"
local APP = "TestApp"

-- The stream owner and the capture it admits in stream scenarios.
local STREAM_OWNER = "hs274-owner"
local STREAM_CAPTURE = "hs274-capture"

--- Returns the named upvalue of a production closure.
--- @param fn function Closure to inspect.
--- @param wanted string Upvalue name.
--- @return any value
local function find_upvalue(fn, wanted)
	for index = 1, 200 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == wanted then return value end
	end
	error("cannot find upvalue " .. tostring(wanted), 2)
end

--- Builds a Quartz-shaped event without an Ergopti provenance tag.
--- @param event_type number hs.eventtap event type.
--- @param keycode number macOS virtual keycode.
--- @param chars string|nil Characters the event carries.
--- @param flags table|nil Modifier flags.
--- @return table event
local function quartz_event(event_type, keycode, chars, flags)
	return {
		getType = function() return event_type end,
		getKeyCode = function() return keycode end,
		getCharacters = function() return chars end,
		getFlags = function() return flags or {} end,
		getProperty = function() return 0 end,
	}
end

--- Runs one scenario against a freshly loaded keylogger and aggregator.
--- The callback receives a scenario table:
---   key_down(keycode, chars)        drives the real keyDown branch;
---   flags_changed(keycode, flags)   drives the real flagsChanged branch;
---   ledger_press(keycode)           appends a Karabiner ledger credit;
---   stream_press(keycode)           appends an admitted producer credit;
---   typing_events()                 every event the keylogger recorded;
---   system_events                   the modifier events the keylogger appended;
---   counts()                        kc_ngram credits after aggregation;
---   aggregate()                     the aggregator state after aggregation;
---   ledger_may_persist()            the gate the bridge asks before a ledger credit;
---   admit_stream()                  selects the stream and admits a complete capture;
---   kc_bridge                       the keylogger's (stubbed) Karabiner bridge;
---   mode                            the physical accounting policy the keylogger uses;
---   state                           the keylogger's CoreState.
--- @param callback function Scenario body.
function M.run(callback)
	helpers.with_stub_scope(OWNED_MODULES, function()
		local fixture = Fixture.load_keylogger()
		local handle_key = find_upvalue(fixture.keylogger.start, "handle_key")
		local types = fixture.hs.eventtap.event.types
		fixture.state.is_enabled = true
		fixture.state.is_secure_field = false
		fixture.state.session_start_time = 1

		local system_events = {}
		local log_manager = package.loaded["modules.keylogger.log_manager"]
		log_manager.log_modifier_press = function(keycode, app)
			system_events[#system_events + 1] = { action = "modifier_press", keycode = keycode, app = app }
		end
		log_manager.log_modifier_hold = function(keycode, app, hold_ms)
			system_events[#system_events + 1] = { action = "modifier_hold", keycode = keycode,
				app = app, hold_ms = hold_ms }
		end

		local credits = {}
		local scenario = {
			kc_bridge = package.loaded["modules.keylogger.kc_bridge"],
			mode = require("modules.keylogger.physical_accounting_mode"),
			state = fixture.state,
			system_events = system_events,
		}

		function scenario.ledger_may_persist()
			return scenario.kc_bridge.may_persist()
		end

		function scenario.admit_stream()
			scenario.mode.select_stream(STREAM_OWNER)
			local admitted, reason = scenario.mode.admit(STREAM_OWNER, STREAM_CAPTURE,
				scenario.mode.COMPLETE_COVERAGE)
			helpers.assert_eq(admitted, true, "a complete capture must be admitted: " .. tostring(reason))
		end

		function scenario.key_down(keycode, chars)
			handle_key(quartz_event(types.keyDown, keycode, chars))
		end

		function scenario.flags_changed(keycode, flags)
			handle_key(quartz_event(types.flagsChanged, keycode, nil, flags))
		end

		function scenario.ledger_press(keycode)
			credits[#credits + 1] = { timestamp = DAY .. " 10:00:00.000",
				action = "karabiner_press", keycode = keycode, app = APP }
		end

		function scenario.stream_press(keycode)
			credits[#credits + 1] = { timestamp = DAY .. " 10:00:00.000", action = "physical_press",
				keycode = keycode, app = APP, capture = STREAM_CAPTURE, device = "41" }
		end

		function scenario.typing_events()
			local events = {}
			for _, flush in ipairs(fixture.flushes) do
				for _, entry in ipairs(flush.events) do events[#events + 1] = entry end
			end
			for _, entry in ipairs(fixture.state.buffer_events) do events[#events + 1] = entry end
			return events
		end

		function scenario.aggregate()
			local Events = require("modules.keylogger.aggregator.events")
			local State = require("modules.keylogger.aggregator.state")
			local Core = require("modules.keylogger.aggregator.core")
			State.initialized = true
			State.device_id = "hs274-accounting"
			Core.reset_batch()
			Core.reset_ngram_ctx()
			for _, entry in ipairs(credits) do Events.walk_system_event(entry) end
			Events.walk_typing({ timestamp = DAY .. " 10:00:00.000", app = APP,
				events = scenario.typing_events() })
			return State
		end

		function scenario.counts()
			local counts = {}
			for _, row in pairs(scenario.aggregate().agg_batch.kc_ngram) do
				counts[row.keycode] = (counts[row.keycode] or 0) + row.count
			end
			return counts
		end

		callback(scenario)
	end)
end

M.DAY = DAY
M.APP = APP
M.STREAM_OWNER = STREAM_OWNER
M.STREAM_CAPTURE = STREAM_CAPTURE

return M
