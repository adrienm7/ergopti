--- tests/unit/modules/keymap/lifecycle/test_start_commit_transaction.lua

--- ==============================================================================
--- MODULE: Keymap Native Start Transaction
--- DESCRIPTION:
--- Drives the real modules.keymap.start()/stop() lifecycle against controllable
--- eventtap, timer, watcher, and action-listener capabilities. A start is allowed
--- to return true only when all four taps and the watchdog are observably live;
--- every partial failure must roll back before a later clean retry.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")
local ONE_SHOT_DATA = assert(require("json").decode(SourceFile.read(helpers.shared("tap_hold/one_shot_shift.json"))))

local RESET_MODULES = {
	"modules.keymap", "modules.keymap.init", "modules.keymap.registry",
	"modules.keymap.expander", "modules.keymap.llm_bridge", "modules.keymap.state",
	"modules.keymap.terminator_replay", "modules.keymap.utils",
	"modules.diagnostics.hid_diagnostic_mailbox",
	"adapters.synthetic_input", "adapters.event_provenance",
	"adapters.timer_scheduler",
	"infra.logger", "infra.perf", "infra.hotpath_profiler",
	"infra.manifest_reader", "infra.keycodes", "keymap.terminators",
}

local function noop() end

local function api(overrides)
	return setmetatable(overrides or {}, {
		__index = function(t, key)
			local value = noop
			rawset(t, key, value)
			return value
		end,
	})
end

local function load_fixture(prepare_input)
	for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()

	local controls = {
		tap_failure_ordinal = nil,
		tap_failure_mode = nil,
		watchdog_failure_mode = nil,
		watchdog_stop_mode = nil,
		reconcile_start_mode = nil,
		reconcile_stop_mode = nil,
		listener_raises = false,
		listener_result = true,
		mailbox_start_mode = "ok",
		mailbox_stop_mode = "ok",
		llm_setter_mode = "ok",
	}
	local taps = {}
	hs_stub.eventtap.new = function(_types, callback)
		local ordinal = #taps + 1
		local candidate = {
			ordinal = ordinal,
			callback = callback,
			enabled = false,
			starts = 0,
			stops = 0,
		}
		function candidate:start()
			self.starts = self.starts + 1
			if controls.tap_failure_ordinal == ordinal then
				if controls.tap_failure_mode == "throw" then error("TAP_START_FAILURE_" .. ordinal) end
				if controls.tap_failure_mode == "disabled" then return self end
			end
			self.enabled = true
			return self
		end
		function candidate:stop()
			self.stops = self.stops + 1
			self.enabled = false
			return self
		end
		function candidate:isEnabled() return self.enabled end
		taps[#taps + 1] = candidate
		return candidate
	end

	local watchdogs = {}
	hs_stub.timer.new = function(delay, callback)
		local timer = {
			callback = callback,
			delay = delay,
			live = false,
			starts = 0,
			stops = 0,
		}
		function timer:start()
			self.starts = self.starts + 1
			if self.delay == 0 and controls.reconcile_start_mode then
				self.live = true
				if controls.reconcile_start_mode == "throw" then
					error("RECONCILE_START_FAILURE")
				end
				if controls.reconcile_start_mode == "false" then return false end
				if controls.reconcile_start_mode == "nil" then return nil end
			end
			if controls.watchdog_failure_mode == "throw" then error("WATCHDOG_START_FAILURE") end
			if controls.watchdog_failure_mode ~= "disabled" then self.live = true end
			return self
		end
		function timer:stop()
			self.stops = self.stops + 1
			if self.delay == 0 and controls.reconcile_stop_mode then
				if controls.reconcile_stop_mode == "throw" then
					error("RECONCILE_STOP_FAILURE")
				end
				if controls.reconcile_stop_mode == "false" then return false end
				if controls.reconcile_stop_mode == "nil" then return nil end
			end
			if controls.watchdog_stop_mode == "truthy_running_once" then
				controls.watchdog_stop_mode = nil
				return self
			end
			self.live = false
			return self
		end
		function timer:running() return self.live end
		watchdogs[#watchdogs + 1] = timer
		return timer
	end

	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local epoch = {}
	local register_calls, unregister_calls = 0, 0
	package.loaded["adapters.synthetic_input"] = api({
		current_action_epoch = function() return epoch, 0 end,
		register_action_listener = function()
			register_calls = register_calls + 1
			if controls.listener_raises then error("LISTENER_START_FAILURE") end
			return controls.listener_result
		end,
		unregister_action_listener = function()
			unregister_calls = unregister_calls + 1
			return true
		end,
	})
	package.loaded["adapters.event_provenance"] = api({
		STATUS_OWNED = "owned",
		STATUS_FOREIGN = "foreign",
		STATUS_UNREADABLE = "unreadable",
	})

	local state = {
		buffer = "",
		start_is_word_boundary = false,
		processing_paused = false,
		ignored_window_titles = {},
		ignored_window_patterns = {},
		last_key_time = 0,
		WORD_TIMEOUT_SEC = 0,
		no_rescan_until = 0,
		last_key_was_complex = false,
		magic_key = "★",
		DELAYS = { STAR_TRIGGER = 0 },
		groups = {},
		interceptors = {},
		preview_providers = {},
		shift_side = nil,
	}
	package.loaded["modules.keymap.state"] = { new = function() return state end }
	package.loaded["modules.keymap.registry"] = api({
		init = function() return true end,
		is_repeat_feature_enabled = function() return false end,
		set_repeat_feature_enabled = noop,
		registry_transaction = function(_, mutation) return mutation() end,
	})
	package.loaded["modules.keymap.expander"] = api({
		init = function() return true end,
	})
	local llm_setter_values = {}
	local quarantine_values = {}
	local reconcile_calls = 0
	local reset_quarantined_calls = 0
	local runtime_sentinel = {source = "prediction-engine-runtime"}
	package.loaded["modules.keymap.llm_bridge"] = api({
		init = function() return true end,
		invalidate_hotstring_preview = function() return true end,
		reset_for_teardown = function() return true end,
		stop = function() return true end,
		is_runtime_available = function() return true end,
		get_llm_runtime_setting = function(key)
			if key ~= "llm_debounce" then return false, nil end
			return true, runtime_sentinel
		end,
		set_llm_debounce = function(value)
			llm_setter_values[#llm_setter_values + 1] = value
			if controls.llm_setter_mode == "throw" then error("LLM_SETTER_FAILURE") end
			if controls.llm_setter_mode == "false" then return false end
			return true
		end,
		set_runtime_quarantined = function(value)
			quarantine_values[#quarantine_values + 1] = value
			return true
		end,
		reconcile_observation_gap = function()
			reconcile_calls = reconcile_calls + 1
			return true
		end,
		reset_quarantined_context = function()
			reset_quarantined_calls = reset_quarantined_calls + 1
			return true
		end,
	})
	package.loaded["modules.keymap.terminator_replay"] = api({
		flush_now = function() return controls.replay_pending ~= true end,
		is_pending = function() return controls.replay_pending == true end,
		is_settled = function()
			return controls.replay_pending ~= true and controls.replay_settling ~= true
		end,
	})
	local mailbox_running = false
	local mailbox_start_calls, mailbox_stop_calls = 0, 0
	package.loaded["modules.diagnostics.hid_diagnostic_mailbox"] = {
		start = function()
			mailbox_start_calls = mailbox_start_calls + 1
			if controls.mailbox_start_mode == "throw" then error("MAILBOX_START_FAILURE") end
			if controls.mailbox_start_mode == "false" then return false end
			if controls.mailbox_start_mode == "nil" then return nil end
			mailbox_running = true
			return true
		end,
		stop = function()
			mailbox_stop_calls = mailbox_stop_calls + 1
			if controls.mailbox_stop_mode == "throw" then error("MAILBOX_STOP_FAILURE") end
			if controls.mailbox_stop_mode == "false" then return false end
			if controls.mailbox_stop_mode == "nil" then return nil end
			mailbox_running = false
			return true
		end,
		is_running = function() return mailbox_running end,
	}
	local tracking_stops = 0
	package.loaded["modules.keymap.utils"] = api({
		start_ignored_win_tracking = function() return 1 end,
		prewarm_ignored_win_watchers = function() return true end,
		stop = function() tracking_stops = tracking_stops + 1; return true end,
		is_ignored_window = function() return false, 1 end,
		is_secure_field = function() return false, 1 end,
	})
	package.loaded["keymap.terminators"] = api({ matches_magic_event = function() return false end })
	package.loaded["infra.logger"] = api({
		LEVELS = { DEBUG = 10 },
		is_enabled = function() return false end,
		pcall = function(_, fn, ...) return pcall(fn, ...) end,
	})
	package.loaded["infra.perf"] = api({ is_enabled = function() return false end })
	package.loaded["infra.hotpath_profiler"] = api({ now = function() return 0 end })
	package.loaded["infra.manifest_reader"] = {
		default_for = function(key)
			if key == "hotstrings.expansion_delay" then return 0 end
			if key == "hotstrings.trigger_char" then return "★" end
			-- The word-reset policy stays neutral: these scenarios are not about pauses.
			if key == "hotstrings.idle_reset_seconds" then return 0 end
			return false
		end,
	}
	package.loaded["infra.keycodes"] = { ESCAPE = 53, BACKSPACE = 51, RETURN = 36 }

	if prepare_input then prepare_input(controls) end

	local keymap = require("modules.keymap.init")
	return {
		keymap = keymap,
		state = state,
		controls = controls,
		taps = taps,
		watchdogs = watchdogs,
		register_calls = function() return register_calls end,
		unregister_calls = function() return unregister_calls end,
		tracking_stops = function() return tracking_stops end,
		mailbox_start_calls = function() return mailbox_start_calls end,
		mailbox_stop_calls = function() return mailbox_stop_calls end,
		mailbox_running = function() return mailbox_running end,
		llm_setter_values = llm_setter_values,
		quarantine_values = quarantine_values,
		reconcile_calls = function() return reconcile_calls end,
		reset_quarantined_calls = function() return reset_quarantined_calls end,
		runtime_sentinel = runtime_sentinel,
	}
end

local function trigger_observation_gap(fixture)
	local watchdog = fixture.watchdogs[1]
	fixture.taps[1].enabled = false
	watchdog.callback()
	local reconcile_timer = fixture.watchdogs[#fixture.watchdogs]
	helpers.assert_eq(reconcile_timer.delay, 0,
		"the outage must publish its exact deferred reconcile timer")
	helpers.assert_true(reconcile_timer.live,
		"the committed reconcile timer must be observably live")
	helpers.assert_eq(fixture.quarantine_values, {true},
		"the synchronous outage fence must close LLM delivery before deferral")
	return reconcile_timer
end

local function assert_all_taps_disabled(fixture, message)
	for index, event_tap in ipairs(fixture.taps) do
		helpers.assert_eq(event_tap.enabled, false,
			(message or "rollback") .. " must disable tap " .. tostring(index))
	end
end

helpers.describe("keymap start: exact native commitment", function()
	helpers.it("acknowledges effective replacement transitions to the existing ordinary owner", function()
		helpers.with_stub_scope({ "modules.shortcuts.keyboard_shortcuts", "modules.keymap.magic_key_source" }, function()
			local fixture, selected
			local observed = {}
			package.loaded["modules.keymap.magic_key_source"] = {
				set = function(value) selected = value; return value end,
				keycode = function() return selected == "KeyJ" and 38 or nil end,
			}
			package.loaded["modules.shortcuts.keyboard_shortcuts"] = {
				refresh_magic_editor = function()
					observed[#observed + 1] = { effective = fixture.keymap.is_magic_key_replacement_effective() }
					return true
				end,
			}
			fixture = load_fixture()
			package.loaded["modules.keymap.registry"].is_group_enabled = function() return true end
			package.loaded["modules.keymap.registry"].is_section_enabled = function() return true end
			package.loaded["adapters.synthetic_input"].admission_open = function() return true end
			helpers.assert_eq(fixture.keymap.start(), true)
			helpers.assert_eq(fixture.keymap.set_magic_key_source("KeyJ"), true)
			helpers.assert_eq(fixture.keymap.pause_processing(), true)
			helpers.assert_eq(fixture.keymap.resume_processing(), true)
			helpers.assert_eq(observed, { { effective = false }, { effective = true },
				{ effective = false }, { effective = true } })
			local tap = fixture.taps[1]
			local is_enabled, stop = tap.isEnabled, tap.stop
			tap.isEnabled = function() error("native source ownership unreadable") end
			helpers.assert_nil(fixture.keymap.is_magic_key_replacement_effective())
			tap.isEnabled = is_enabled
			tap.stop = function() return false end
			helpers.assert_eq(fixture.keymap.stop(), false)
			helpers.assert_nil(fixture.keymap.is_magic_key_replacement_effective(),
				"a live tap retained after teardown cannot prove source inactivity")
			helpers.assert_eq(#observed, 4, "a refused lifecycle edge cannot publish an acknowledgment")
			tap.stop = stop
			helpers.assert_eq(fixture.keymap.stop(), true)
			helpers.assert_eq(observed[5], { effective = false })
		end)
	end)

	for _, teardown in ipairs({ false, true }) do
		helpers.it("(terminator-stop-settle-fence) retains context guards until replay settles, teardown="
			.. tostring(teardown), function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.keymap.start())
			fixture.state.buffer = "owned text"
			local generation = fixture.state.lifecycle_generation
			fixture.controls.replay_pending = true
			helpers.assert_eq(fixture.keymap.stop(teardown), false)
			helpers.assert_eq(fixture.state.lifecycle_generation, generation)
			helpers.assert_eq(fixture.state.buffer, "owned text")
			helpers.assert_eq(fixture.unregister_calls(), 0)
			helpers.assert_eq(fixture.tracking_stops(), 0)
			for _, tap in ipairs(fixture.taps) do helpers.assert_true(tap.enabled) end
			fixture.controls.replay_pending = false
			fixture.controls.replay_settling = true
			helpers.assert_eq(fixture.keymap.stop(teardown), false,
				"activation is not native settlement")
			helpers.assert_eq(fixture.unregister_calls(), 0)
			fixture.controls.replay_settling = false
			helpers.assert_true(fixture.keymap.stop(teardown))
			assert_all_taps_disabled(fixture)
		end)
	end

	helpers.it("revives the keyDown tap without invalidating context while PAUSED", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.keymap.start())
		helpers.assert_true(fixture.keymap.pause_processing())
		fixture.state.buffer = "pause-owned"
		fixture.state.start_is_word_boundary = true
		fixture.taps[1].enabled = false

		fixture.watchdogs[1].callback()

		helpers.assert_true(fixture.taps[1].enabled,
			"the watchdog may repair the native tap while business processing is paused")
		helpers.assert_eq(fixture.state.buffer, "pause-owned",
			"tap repair may not invalidate the paused text snapshot")
		helpers.assert_eq(fixture.state.start_is_word_boundary, true)
		helpers.assert_eq(#fixture.quarantine_values, 0,
			"watchdog repair may not quarantine or reopen prediction state under PAUSED")
		helpers.assert_true(fixture.keymap.stop(true))
	end)

	helpers.it("exports the exact LLM runtime getter and setter result through the real facade", function()
		local fixture = load_fixture()
		helpers.assert_eq(type(fixture.keymap.get_llm_runtime_setting), "function",
			"modules.keymap.init must publish the bridge runtime snapshot boundary")
		local found, value = fixture.keymap.get_llm_runtime_setting("llm_debounce")
		helpers.assert_eq(found, true)
		helpers.assert_true(value == fixture.runtime_sentinel,
			"the facade must not copy or substitute the bridge runtime snapshot")

		fixture.controls.llm_setter_mode = "false"
		helpers.assert_eq(fixture.keymap.set_llm_debounce(0.71), false,
			"the facade must expose a literal bridge refusal to SettingsManager")

		fixture.controls.llm_setter_mode = "throw"
		local ok, err = pcall(fixture.keymap.set_llm_debounce, 0.92)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("LLM_SETTER_FAILURE", 1, true) ~= nil,
			"the caller must observe the exact bridge exception")
		helpers.assert_eq(fixture.llm_setter_values, {0.71, 0.92})
	end)

	helpers.it("forwards exact registry transactions to feature starters", function()
		local fixture = load_fixture()
		local calls = 0
		local committed = fixture.keymap.registry_transaction("feature_start", function()
			calls = calls + 1
			return true
		end)
		helpers.assert_eq(committed, true)
		helpers.assert_eq(calls, 1)
	end)

	for ordinal = 1, 4 do
		for _, mode in ipairs({ "throw", "disabled" }) do
			helpers.it("rolls back tap " .. ordinal .. " after " .. mode .. " start", function()
				local fixture = load_fixture()
				fixture.controls.tap_failure_ordinal = ordinal
				fixture.controls.tap_failure_mode = mode
				helpers.assert_eq(fixture.keymap.start(), false)
				assert_all_taps_disabled(fixture)
				helpers.assert_eq(fixture.register_calls(), 1)
				helpers.assert_eq(fixture.unregister_calls(), 1,
					"partial start must unregister the exact listener")
				helpers.assert_eq(fixture.tracking_stops(), 1,
					"partial start must release off-tap window tracking")

				fixture.controls.tap_failure_ordinal = nil
				fixture.controls.tap_failure_mode = nil
				helpers.assert_true(fixture.keymap.start(), "a clean retry must be possible")
				for _, event_tap in ipairs(fixture.taps) do helpers.assert_true(event_tap.enabled) end
				helpers.assert_true(fixture.watchdogs[#fixture.watchdogs].live)
				helpers.assert_true(fixture.keymap.stop(true))
			end)
		end
	end

	for _, mode in ipairs({ "throw", "disabled" }) do
		helpers.it("rolls back all taps after " .. mode .. " watchdog start", function()
			local fixture = load_fixture()
			fixture.controls.watchdog_failure_mode = mode
			helpers.assert_eq(fixture.keymap.start(), false)
			assert_all_taps_disabled(fixture)
			helpers.assert_eq(fixture.unregister_calls(), 1)
			helpers.assert_eq(fixture.watchdogs[1].live, false)

			fixture.controls.watchdog_failure_mode = nil
			helpers.assert_true(fixture.keymap.start())
			helpers.assert_true(fixture.keymap.stop(true))
		end)
	end

	helpers.it("fences a watchdog whose chainable stop leaves it running", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.keymap.start())
		local watchdog = fixture.watchdogs[1]
		fixture.taps[1].enabled = false
		watchdog.callback()
		helpers.assert_true(fixture.taps[1].enabled,
			"the committed watchdog callback must be live in the behavioral fixture")

		fixture.controls.watchdog_stop_mode = "truthy_running_once"
		helpers.assert_eq(fixture.keymap.stop(true), false,
			"a truthy stop result cannot commit while running() remains true")
		helpers.assert_true(watchdog.live,
			"the exact native watchdog must remain retained for cleanup retry")
		assert_all_taps_disabled(fixture)
		watchdog.callback()
		assert_all_taps_disabled(fixture,
			"a queued callback from retained cleanup debt")

		helpers.assert_true(fixture.keymap.stop(true),
			"a later teardown must retry the exact retained watchdog")
		helpers.assert_eq(watchdog.stops, 2)
		local watchdog_count = 0
		for _, timer in ipairs(fixture.watchdogs) do
			if timer.delay ~= 0 then watchdog_count = watchdog_count + 1 end
		end
		helpers.assert_eq(watchdog_count, 1,
			"cleanup retry must not allocate a sibling watchdog")
		helpers.assert_eq(watchdog.live, false)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and fences a context reconcile timer after " .. mode
			.. " stop", function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.keymap.start())
			local reconcile_timer = trigger_observation_gap(fixture)

			fixture.controls.reconcile_stop_mode = mode
			helpers.assert_eq(fixture.keymap.pause_processing(), false,
				"PAUSE must reject an unsettled native reconcile capability")
			helpers.assert_true(fixture.keymap.is_processing_paused(),
				"delivery must close synchronously before native cancellation")
			helpers.assert_true(reconcile_timer.live,
				"the exact refused timer must remain retained")
			helpers.assert_eq(reconcile_timer.stops, 1)

			reconcile_timer.callback()
			helpers.assert_eq(reconcile_timer.stops, 2,
				"a queued native delivery may only retry the same cleanup debt")
			helpers.assert_eq(fixture.reconcile_calls(), 0,
				"the retained callback must stay business-inert while paused")

			fixture.controls.reconcile_stop_mode = nil
			reconcile_timer.callback()
			helpers.assert_eq(reconcile_timer.stops, 3)
			helpers.assert_eq(reconcile_timer.live, false)
			helpers.assert_eq(fixture.reconcile_calls(), 0)
			helpers.assert_true(fixture.keymap.pause_processing(),
				"same-state PAUSE must observe the settled exact timer")

			local timers_before_resume = #fixture.watchdogs
			helpers.assert_true(fixture.keymap.resume_processing())
			helpers.assert_eq(#fixture.watchdogs, timers_before_resume + 1,
				"RESUME must re-arm the one preserved reconcile intent once")
			local successor = fixture.watchdogs[#fixture.watchdogs]
			helpers.assert_true(successor ~= reconcile_timer)
			successor.callback()
			helpers.assert_eq(fixture.reconcile_calls(), 1,
				"only the post-RESUME successor may reconcile observed context")
			successor.callback()
			reconcile_timer.callback()
			helpers.assert_eq(fixture.reconcile_calls(), 1,
				"duplicate successor and predecessor callbacks must be inert")
			helpers.assert_true(fixture.keymap.stop(true))
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains a due reconcile timer whose self-stop returns "
			.. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.keymap.start())
			local reconcile_timer = trigger_observation_gap(fixture)
			fixture.controls.reconcile_stop_mode = mode

			reconcile_timer.callback()
			helpers.assert_eq(fixture.reconcile_calls(), 1,
				"the committed due callback may reconcile business work once")
			helpers.assert_true(reconcile_timer.live,
				"a refused self-stop must retain the exact native timer")
			helpers.assert_eq(reconcile_timer.stops, 1)
			helpers.assert_eq(fixture.keymap.pause_processing(), false,
				"PAUSE must still see and join the retained due timer")
			helpers.assert_eq(reconcile_timer.stops, 2,
				"PAUSE must retry the same native identity")

			reconcile_timer.callback()
			helpers.assert_eq(reconcile_timer.stops, 3)
			helpers.assert_eq(fixture.reconcile_calls(), 1,
				"duplicate native delivery may only retry cleanup")
		fixture.controls.reconcile_stop_mode = nil
			helpers.assert_true(fixture.keymap.pause_processing())
			helpers.assert_eq(reconcile_timer.stops, 4)
			helpers.assert_eq(reconcile_timer.live, false)
			reconcile_timer.callback()
			helpers.assert_eq(fixture.reconcile_calls(), 1)
			helpers.assert_eq(#fixture.watchdogs, 2,
				"settlement retry may not allocate a reconcile sibling")
			helpers.assert_true(fixture.keymap.stop(true))
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact context reconcile timer when STOP returns "
			.. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.keymap.start())
			local reconcile_timer = trigger_observation_gap(fixture)
			fixture.controls.reconcile_stop_mode = mode

			helpers.assert_eq(fixture.keymap.stop(true), false,
				"full teardown cannot publish success above timer cleanup debt")
			helpers.assert_true(reconcile_timer.live)
			helpers.assert_eq(reconcile_timer.stops, 1)
			reconcile_timer.callback()
			helpers.assert_eq(reconcile_timer.stops, 2)
			helpers.assert_eq(fixture.reconcile_calls(), 0,
				"the stopped engine must fence queued context reconciliation")

			fixture.controls.reconcile_stop_mode = nil
			helpers.assert_true(fixture.keymap.stop(true),
				"STOP retry must settle the retained native identity")
			helpers.assert_eq(reconcile_timer.live, false)
			helpers.assert_eq(reconcile_timer.stops, 3)
			helpers.assert_eq(#fixture.watchdogs, 2,
				"teardown retry must not allocate any timer sibling")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rolls back a " .. mode
			.. " reconcile acquisition during RESUME", function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.keymap.start())
			local predecessor = trigger_observation_gap(fixture)
			helpers.assert_true(fixture.keymap.pause_processing())
			helpers.assert_eq(predecessor.live, false)

			fixture.controls.reconcile_start_mode = mode
			fixture.controls.reconcile_stop_mode = mode
			helpers.assert_eq(fixture.keymap.resume_processing(), false,
				"RESUME must reject a live but uncommitted reconcile candidate")
			helpers.assert_true(fixture.keymap.is_processing_paused(),
				"failed acquisition must restore the synchronous pause fence")
			local candidate = fixture.watchdogs[#fixture.watchdogs]
			helpers.assert_true(candidate ~= predecessor)
			helpers.assert_true(candidate.live,
				"the exact rollback debt must remain owned")
			helpers.assert_eq(candidate.stops, 2,
				"acquisition rollback and local re-pause must target one handle")

			candidate.callback()
			helpers.assert_eq(candidate.stops, 3)
			helpers.assert_eq(fixture.reconcile_calls(), 0,
				"an uncommitted candidate cannot perform reconciliation")

			fixture.controls.reconcile_start_mode = nil
			fixture.controls.reconcile_stop_mode = nil
			local timers_before_retry = #fixture.watchdogs
			helpers.assert_true(fixture.keymap.resume_processing(),
				"a retry must first settle the exact candidate, then re-arm intent")
			helpers.assert_eq(candidate.live, false)
			helpers.assert_eq(candidate.stops, 4)
			helpers.assert_eq(#fixture.watchdogs, timers_before_retry + 1)
			local successor = fixture.watchdogs[#fixture.watchdogs]
			successor.callback()
			helpers.assert_eq(fixture.reconcile_calls(), 1)
			candidate.callback()
			successor.callback()
			helpers.assert_eq(fixture.reconcile_calls(), 1,
				"settled acquisition debt and duplicate successors must stay inert")
			helpers.assert_true(fixture.keymap.stop(true))
		end)
	end

	helpers.it("rolls back a listener registration throw before starting taps", function()
		local fixture = load_fixture()
		fixture.controls.listener_raises = true
		helpers.assert_eq(fixture.keymap.start(), false)
		assert_all_taps_disabled(fixture)
		helpers.assert_eq(fixture.unregister_calls(), 0,
			"a listener whose constructor raised was never published as owned")
		fixture.controls.listener_raises = false
		helpers.assert_true(fixture.keymap.start())
		helpers.assert_true(fixture.keymap.stop(true))
	end)

	for _, rejected in ipairs({ false, "nil" }) do
		helpers.it("rejects a listener registration returning " .. tostring(rejected), function()
			local fixture = load_fixture()
			if rejected == "nil" then
				fixture.controls.listener_result = nil
			else
				fixture.controls.listener_result = rejected
			end
			helpers.assert_eq(fixture.keymap.start(), false)
			assert_all_taps_disabled(fixture)
			helpers.assert_eq(fixture.unregister_calls(), 0,
				"an uncommitted listener must not be unregistered as owned")
			fixture.controls.listener_result = true
			helpers.assert_true(fixture.keymap.start())
			helpers.assert_true(fixture.keymap.stop(true))
		end)
	end

	helpers.it("repairs an externally disabled tap instead of trusting the started latch", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.keymap.start())
		fixture.taps[2].enabled = false
		local first_register_count = fixture.register_calls()
		helpers.assert_true(fixture.keymap.start())
		helpers.assert_eq(fixture.register_calls(), first_register_count + 1,
			"repair must rebuild the listener after rolling back partial ownership")
		for _, event_tap in ipairs(fixture.taps) do helpers.assert_true(event_tap.enabled) end
		helpers.assert_true(fixture.keymap.stop(true))
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("refuses key capture when the diagnostic pump returns " .. mode, function()
			local fixture = load_fixture()
			fixture.controls.mailbox_start_mode = mode
			helpers.assert_eq(fixture.keymap.start(), false)
			assert_all_taps_disabled(fixture)
			helpers.assert_eq(fixture.mailbox_start_calls(), 1)
			helpers.assert_eq(fixture.mailbox_running(), false)
			helpers.assert_eq(fixture.unregister_calls(), 1,
				"pump arm failure must roll back the pre-tap action listener")

			fixture.controls.mailbox_start_mode = "ok"
			helpers.assert_true(fixture.keymap.start())
			helpers.assert_true(fixture.mailbox_running())
			helpers.assert_true(fixture.keymap.stop(true))
		end)
	end

	helpers.it("keeps the diagnostic pump alive across pause and restarts it after stop", function()
		local fixture = load_fixture()
		helpers.assert_true(fixture.keymap.start())
		helpers.assert_eq(fixture.mailbox_start_calls(), 1)
		fixture.keymap.pause_processing()
		fixture.keymap.resume_processing()
		helpers.assert_eq(fixture.mailbox_start_calls(), 1,
			"pause/resume must not allocate a replacement pump")
		helpers.assert_eq(fixture.mailbox_stop_calls(), 0,
			"pause must keep diagnostics deliverable")

		helpers.assert_true(fixture.keymap.stop(true))
		helpers.assert_eq(fixture.mailbox_stop_calls(), 1)
		helpers.assert_true(fixture.keymap.start())
		helpers.assert_eq(fixture.mailbox_start_calls(), 2)
		helpers.assert_true(fixture.keymap.stop(true))
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains diagnostic ownership when pump stop returns " .. mode, function()
			local fixture = load_fixture()
			helpers.assert_true(fixture.keymap.start())
			fixture.controls.mailbox_stop_mode = mode
			helpers.assert_eq(fixture.keymap.stop(true), false)
			helpers.assert_true(fixture.mailbox_running(),
				"failed pump stop must remain retryable")

			fixture.controls.mailbox_stop_mode = "ok"
			helpers.assert_true(fixture.keymap.stop(true))
			helpers.assert_eq(fixture.mailbox_running(), false)
		end)
	end
end)


-- Keep these input scenarios inside a separate fixture scope: the historical
-- lifecycle scenarios above intentionally reuse their own construction helpers.
local INPUT_MODULES = {
	"hs", "tests.stubs.hs", "adapters.one_shot_shift",
	"modules.keymap.one_shot_shift", "modules.keymap.control_sentinels",
	"modules.keymap.magic_key_source", "adapters.event_clock",
	"infra.key_event_health", "infra.keystroke_integrity", "infra.deferred_work",
	"adapters.text_sender", "adapters.keyboard_geometry", "modules.llm.app_filter",
	"infra.hotstring_engine", "hotstring_engine", "infra.text_utils", "text_utils",
	"compat.utf8", "keycodes", "keymap.control_signals", "tap_hold.one_shot_shift",
	"unicode_case", "unicode_case.init", "unicode_case.data", "error_description", "number_policy",
	"logger.shim", "hotstrings.personal_files", "native_path", "toml_codec.key_path", "toml_codec.basic_string",
	"platform.remap", "modules.shortcuts.keyboard_shortcuts",
}
for _, name in ipairs(RESET_MODULES) do INPUT_MODULES[#INPUT_MODULES + 1] = name end

local function with_input_fixture(callback)
	helpers.with_stub_scope(INPUT_MODULES, function()
		local calls = { emitted = {}, errors = {}, signals = {} }
		local factory, owner, synthetic
		local host_ns = 3600 * 1000000000
		local fixture = load_fixture(function(controls)
			controls.input_open = true
			hs.timer.absoluteTime = function() return host_ns end
			synthetic = package.loaded["adapters.synthetic_input"]
			synthetic.STALE_PHYSICAL_EVENT_MS = 500
			synthetic.admission_open = function() return controls.input_open end
			synthetic.enter_callback = function() return true end
			synthetic.leave_callback = function(consume) return consume end
			synthetic.abort_callback = function() return true, false end
			package.loaded["adapters.event_provenance"].classify_with_fence = function()
				return nil, "foreign", nil, controls.physical_replay == true
			end
			package.loaded["infra.logger"].error = function(_, message)
				calls.errors[#calls.errors + 1] = message
			end
			package.loaded["adapters.text_sender"] = {}
			package.loaded["modules.llm.app_filter"] = {}
			package.loaded["adapters.keyboard_geometry"] = {}
			package.loaded["modules.keymap.magic_key_source"] = {
				needs_geometry = function() return false end,
				owns = function(code) return controls.magic_code == code end,
				remaps = function(code) return controls.magic_code == code end,
			}
			factory = require("adapters.one_shot_shift")
			package.loaded["adapters.one_shot_shift"] = { new = function(deps)
				owner = factory.new({
					data = ONE_SHOT_DATA, magic = deps.magic,
					event = { rawFlagMasks = { shift = 2 } },
					now = function() return 10 end,
					is_repeat = function(event) return event.repeat_flag == 1 end,
					translate = function(code, flags)
						if code == 0 then return flags == 2 and "A" or "a" end
						if code == 1 then return flags == 2 and "2" or "é" end
						return " "
					end,
					emit = function(text)
						calls.emitted[#calls.emitted + 1] = text
						return true
					end,
				})
				return owner
			end }
			package.loaded["platform.remap"] = { get_sticky_timeout = function() return 2000 end }
		end)
		local clock = require("adapters.event_clock")
		clock.reset()
		require("infra.key_event_health").reset()
		local properties = hs.eventtap.event.properties
		local function event(code, text, age, repeat_flag, is_up)
			local raw, unicode = 0, text
			local current = { repeat_flag = repeat_flag or 0, unicode_writes = 0 }
			current.getKeyCode = function() return code end
			current.getType = function()
				return is_up and hs.eventtap.event.types.keyUp or hs.eventtap.event.types.keyDown
			end
			current.getFlags = function() return {} end
			current.getCharacters = function() return unicode end
			current.rawFlags = function(_, value) if value ~= nil then raw = value end; return raw end
			current.setUnicodeString = function(_, value)
				current.unicode_writes = current.unicode_writes + 1
				unicode = value
			end
			current.timestamp = function() return host_ns - (age or 1) * 1000000 end
			current.getProperty = function(_, property)
				if property == properties.keyboardEventAutorepeat then return repeat_flag or 0 end
				return 0
			end
			return current
		end
		helpers.assert_eq(clock.lateness_ms(event(0, "a", 1)), 0)
		helpers.assert_true(fixture.keymap.start())
		fixture.down = fixture.taps[1].callback
		fixture.up = fixture.taps[2].callback
		fixture.event, fixture.calls, fixture.owner = event, calls, owner
		local sentinels = require("modules.keymap.control_sentinels")
		sentinels.set_listener("test.stale-input", function(signal) calls.signals[#calls.signals + 1] = signal end)
		local ok, detail = xpcall(function() callback(fixture) end, debug.traceback)
		local stopped, stop_result = pcall(fixture.keymap.stop, true)
		helpers.assert_true(stopped and stop_result == true, "the input fixture must retire its native owners")
		helpers.assert_eq(calls.errors, {}, "a passing input scenario must not hide a callback error")
		if not ok then error(detail, 0) end
	end)
end

helpers.describe("ordinary stale input before transformations (stale-physical-transform)", function()
	helpers.it("does not add native Shift to an already-late physical key", function()
		with_input_fixture(function(fixture)
			helpers.assert_true(fixture.keymap.arm_one_shot_shift())
			local late = fixture.event(0, "a", 1200)
			helpers.assert_eq(fixture.down(late), false)
			helpers.assert_eq(late:rawFlags(), 0)
			helpers.assert_eq(late:getCharacters(), "a")
			helpers.assert_eq(late.unicode_writes, 0)
			helpers.assert_eq(fixture.calls.emitted, {})
		end)
	end)

	helpers.it("does not emit a Unicode replacement or own the stale key's release", function()
		with_input_fixture(function(fixture)
			helpers.assert_true(fixture.keymap.arm_one_shot_shift())
			helpers.assert_eq(fixture.down(fixture.event(1, "é", 1200)), false)
			helpers.assert_eq(fixture.calls.emitted, {})
			helpers.assert_eq(fixture.up(fixture.event(1, "é", 1, 0, true)), false)
			-- Observation-gap invalidation disarms Shift. A fresh explicit arm must
			-- still transform and own a genuinely fresh physical press.
			helpers.assert_true(fixture.keymap.arm_one_shot_shift())
			helpers.assert_true(fixture.down(fixture.event(1, "é")))
			helpers.assert_eq(fixture.calls.emitted, { "É" })
			helpers.assert_true(fixture.up(fixture.event(1, "é", 1, 0, true)))
		end)
	end)

	for _, repeat_flag in ipairs({ 0, 1 }) do
		helpers.it("retires only the passed stale key's consumed claim, repeat=" .. tostring(repeat_flag), function()
			with_input_fixture(function(fixture)
				helpers.assert_true(fixture.keymap.arm_one_shot_shift())
				helpers.assert_true(fixture.down(fixture.event(1, "é")))
				helpers.assert_true(fixture.keymap.arm_one_shot_shift())
				helpers.assert_true(fixture.down(fixture.event(2, " ")))
				helpers.assert_eq(fixture.calls.emitted, { "É", "-" })
				helpers.assert_eq(fixture.down(fixture.event(1, "é", 1200, repeat_flag)), false)
				helpers.assert_eq(fixture.up(fixture.event(1, "é", 1, 0, true)), false,
					"the release of a passed late press belongs to the application")
				helpers.assert_true(fixture.up(fixture.event(2, " ", 1, 0, true)),
					"an unrelated consumed press still owns its release")
				helpers.assert_eq(fixture.calls.emitted, { "É", "-" })
			end)
		end)
	end

	for _, boundary in ipairs({ "paused", "admission-closed" }) do
		helpers.it("retains preexisting consumed repeats and releases while " .. boundary, function()
			with_input_fixture(function(fixture)
				helpers.assert_true(fixture.keymap.arm_one_shot_shift())
				helpers.assert_true(fixture.down(fixture.event(1, "é")))
				if boundary == "paused" then fixture.state.processing_paused = true
				else fixture.controls.input_open = false end
				fixture.state.buffer = "owned at boundary"
				helpers.assert_true(fixture.down(fixture.event(1, "é", 1200, 1)))
				helpers.assert_true(fixture.up(fixture.event(1, "é", 1, 0, true)))
				helpers.assert_eq(fixture.state.buffer, "owned at boundary")
				helpers.assert_eq(fixture.calls.emitted, { "É" })
			end)
		end)
	end

	helpers.it("keeps reserved stale controls consumed and publishes their existing signals", function()
		with_input_fixture(function(fixture)
			local codes = require("keycodes")
			for _, code in ipairs({ codes.F20_LAYER_NAV_ENTERED, codes.F19_LAYER_NAV_EXITED }) do
				helpers.assert_true(fixture.down(fixture.event(code, "", 1200)))
				helpers.assert_true(fixture.up(fixture.event(code, "", 1, 0, true)))
			end
			helpers.assert_eq(fixture.calls.signals, { "nav_layer_entered", "nav_layer_exited" })
			helpers.assert_eq(fixture.calls.emitted, {})
		end)
	end)

	helpers.it("keeps stale fast-exit controls outside ordinary context invalidation", function()
		with_input_fixture(function(fixture)
			helpers.assert_true(fixture.keymap.arm_one_shot_shift())
			fixture.state.buffer = "observed text"
			fixture.state.llm_buffer = "observed prediction"
			fixture.state.start_is_word_boundary = true
			fixture.state.start_is_line_start = true
			-- Every production fast-exit identity represents a pass-through control.
			for _, code in ipairs({ 105, 107, 113, 79, 64, 131, 134, 135 }) do
				helpers.assert_eq(fixture.down(fixture.event(code, utf8.char(0xF700), 1200)), false)
				helpers.assert_eq(fixture.state.buffer, "observed text")
				helpers.assert_eq(fixture.state.llm_buffer, "observed prediction")
				helpers.assert_true(fixture.state.start_is_word_boundary)
				helpers.assert_true(fixture.state.start_is_line_start)
			end
			helpers.assert_eq(fixture.quarantine_values, {})
			helpers.assert_eq(require("infra.key_event_health").counts().stale_passed, 0)
			helpers.assert_eq(fixture.calls.emitted, {})
			helpers.assert_true(fixture.down(fixture.event(1, "é")),
				"pass-through controls must not spend the existing one-shot arm")
			helpers.assert_eq(fixture.calls.emitted, { "É" })
			helpers.assert_true(fixture.up(fixture.event(1, "é", 1, 0, true)))
		end)
	end)

	helpers.it("keeps the physical replay exemption when an armed key has an old stamp", function()
		with_input_fixture(function(fixture)
			helpers.assert_true(fixture.keymap.arm_one_shot_shift())
			fixture.controls.physical_replay = true
			helpers.assert_true(fixture.down(fixture.event(1, "é", 1200)))
			helpers.assert_eq(fixture.calls.emitted, { "É" })
			helpers.assert_true(fixture.up(fixture.event(1, "é", 1, 0, true)))
			local counts = require("infra.key_event_health").counts()
			helpers.assert_eq(counts.downs + counts.ups, 0,
				"the already-observed physical replay must not be counted twice")
			helpers.assert_eq(counts.stale_passed, 0)
		end)
	end)

	helpers.it("does not rewrite a late configured physical magic key", function()
		with_input_fixture(function(fixture)
			fixture.controls.magic_code = 3
			local late = fixture.event(3, "j", 1200)
			helpers.assert_eq(fixture.down(late), false)
			helpers.assert_eq(late:getCharacters(), "j")
			helpers.assert_eq(late.unicode_writes, 0)
			helpers.assert_eq(fixture.calls.emitted, {})
		end)
	end)
end)
