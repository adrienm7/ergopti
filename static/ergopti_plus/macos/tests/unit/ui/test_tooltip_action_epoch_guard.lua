--- tests/unit/ui/test_tooltip_action_epoch_guard.lua

--- ==============================================================================
--- MODULE: Tooltip action-epoch quarantine behavioural regression tests
--- DESCRIPTION:
--- Drives the real LLM tooltip with captured eventtap and timer callbacks. A
--- callback created for an older action epoch must become inert as soon as the
--- live runtime predicate closes: no event consumption, acceptance, navigation,
--- or paint may occur. Hotstring rendering is tested separately at the bridge
--- boundary because it deliberately remains available during the LLM quarantine.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_fixture()
	helpers.load_with_stubs("infra.logger")

	local watchers = {}
	local timers = {}
	local calls = {
		accept = 0,
		cancel = 0,
		navigate = 0,
		render = 0,
		hide = 0,
		partial_render = 0,
	}

	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["adapters.event_tap_guard"] = {
		handle_disabled = function() return false end,
	}
	package.loaded["infra.hotpath_profiler"] = {
		now = function() return 0 end,
		log_if_slow = function() end,
	}
	package.loaded["infra.keycodes"] = {
		RETURN = 36,
		ENTER = 76,
		TAB = 48,
		LEFT_ARROW = 123,
		RIGHT_ARROW = 124,
		DOWN_ARROW = 125,
		UP_ARROW = 126,
		ESCAPE = 53,
		F13_KARABINER_RETURN = 105,
		F14_KARABINER_BACKSPACE = 107,
		F15_KARABINER_ESCAPE = 113,
		F16_LLM_CHAIN_SIGNAL = 106,
		F17_CYCLE_WINDOWS = 64,
		F20_LAYER_NAV_ENTERED = 90,
		LAYER_SYN_1 = 79,
		LAYER_SYN_2 = 80,
		LAYER_SYN_3 = 81,
	}

	package.loaded["ui.tooltip.renderer"] = {
		ELEM_INFO = 9,
		canvas = {
			minimumTextSize = function() return { w = 100, h = 20 } end,
		},
		render = function(_blocks, _state, on_shown)
			calls.render = calls.render + 1
			if type(on_shown) == "function" then on_shown() end
		end,
		hide = function() calls.hide = calls.hide + 1 end,
		set_element_text = function()
			calls.partial_render = calls.partial_render + 1
		end,
	}

	local previous_eventtap_new = hs.eventtap.new
	local previous_do_after = hs.timer.doAfter
	hs.eventtap.new = function(types, callback)
		local watcher = {
			types = types,
			callback = callback,
			started = false,
			stopped = false,
			enabled = false,
		}
		function watcher:start() self.started = true; self.enabled = true; return self end
		function watcher:stop() self.stopped = true; self.enabled = false; return self end
		function watcher:isEnabled() return self.enabled end
		watchers[#watchers + 1] = watcher
		return watcher
	end
	hs.timer.doAfter = function(delay, callback)
		local timer = { delay = delay, callback = callback, stopped = false, running = true }
		function timer:stop() self.stopped = true; self.running = false end
		timers[#timers + 1] = timer
		return timer
	end

	-- The tooltip captures both adapters at require time. A leaked instance from a
	-- prior test would own different timer/property stubs and turn these callbacks
	-- into fixture accidents instead of production behavior.
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_provenance"] = nil
	package.loaded["ui.tooltip.tooltip_llm"] = nil
	local TooltipLLM = require("ui.tooltip.tooltip_llm")
	local available = true
	TooltipLLM.set_runtime_guard(function() return available end)
	TooltipLLM.set_accept_callback(function() calls.accept = calls.accept + 1 end)
	TooltipLLM.set_cancel_callback(function() calls.cancel = calls.cancel + 1 end)
	TooltipLLM.set_navigate_callback(function() calls.navigate = calls.navigate + 1 end)

	local function restore()
		hs.eventtap.new = previous_eventtap_new
		hs.timer.doAfter = previous_do_after
		package.loaded["ui.tooltip.tooltip_llm"] = nil
		package.loaded["adapters.event_provenance"] = nil
		package.loaded["adapters.synthetic_input"] = nil
	end

	local function set_available(value) available = value == true end
	return TooltipLLM, calls, watchers, timers, set_available, restore
end


local function prediction(text)
	return {
		to_type = text,
		chunks = { { type = "insert", text = text } },
		nw = "",
		has_corrections = false,
	}
end


local function event(keycode, flags, characters)
	local reads = 0
	local property_reads = 0
	local e = {}
	function e:getProperty() property_reads = property_reads + 1; return 0 end
	function e:getKeyCode() reads = reads + 1; return keycode end
	function e:getFlags() reads = reads + 1; return flags or {} end
	function e:getCharacters() reads = reads + 1; return characters or "" end
	function e:read_count() return reads end
	function e:property_read_count() return property_reads end
	return e
end


local function find_watcher(watchers, event_type)
	for _, watcher in ipairs(watchers) do
		for _, watched_type in ipairs(watcher.types) do
			if watched_type == event_type then return watcher end
		end
	end
	return nil
end


helpers.describe("tooltip_llm: stale action-epoch callbacks are inert", function()
	helpers.it("isolates a throwing accept callback after the eventtap returns", function()
		local T, _, watchers, _, _, restore = load_fixture()
		local ok, err = xpcall(function()
			T.set_accept_callback(function() error("accept callback exploded") end)
			helpers.assert_true(T.show_predictions({ prediction("alpha") }, 1, true))
			local key_watcher = find_watcher(watchers, hs.eventtap.event.types.keyDown)
			helpers.assert_not_nil(key_watcher)

			local callback_ok, consume = pcall(key_watcher.callback, event(48, {}, "\t"))
			helpers.assert_true(callback_ok,
				"acceptance must never throw from the CGEventTap callback")
			helpers.assert_true(consume,
				"a successfully queued acceptance still owns the physical Tab")

			local synthetic = require("adapters.synthetic_input")
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1,
				"the throwing callback must remain queued until after the HID callback")
			local drain_ok, drain_err = pcall(hs.timer.__fire_all)
			if not drain_ok then
				error("the retained dispatcher leaked a callback error: " .. tostring(drain_err), 0)
			end
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 0,
				"a failed acceptance must not poison the post-callback FIFO")
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("never accepts a tagged replacement Tab as physical input", function()
		local T, calls, watchers, timers, _, restore = load_fixture()
		local ok, err = xpcall(function()
			helpers.assert_true(T.show_predictions({ prediction("alpha") }, 1, true))
			local key_watcher = find_watcher(watchers, hs.eventtap.event.types.keyDown)
			helpers.assert_not_nil(key_watcher)

			local synthetic = require("adapters.synthetic_input")
			local tx = synthetic.begin("test.tooltip.replacement", "replacement")
			local batch = synthetic.begin_callback(tx)
			helpers.assert_true(synthetic.keyStroke(batch, {}, "tab"))
			local _, events = synthetic.finish_callback(batch, true)
			synthetic.seal(tx)
			local accepts_before = calls.accept
			helpers.assert_eq(key_watcher.callback(events[1]), false,
				"owned replacement Tab must pass this observer without accepting")
			helpers.assert_eq(calls.accept, accepts_before)
			-- Provenance must short-circuit before the tooltip asks an owned event for
			-- keyboard fields; the generic Quartz fixture intentionally exposes none.
			helpers.assert_eq(type(events[1].getKeyCode), "nil")

			-- Close the direct callback transaction so the fixture proves terminal
			-- lifecycle as well as classification.
			for _, timer in ipairs(timers) do
				if timer.delay == 0 and not timer.stopped then timer.callback() end
			end
			hs.timer.__fire_all()
			helpers.assert_eq(synthetic.stats().active_transactions, 0)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("stale watchers neither read nor consume input and stale navigation cannot repaint", function()
		local T, calls, watchers, timers, set_available, restore = load_fixture()
		local ok, err = xpcall(function()
			helpers.assert_true(T.show_predictions(
				{ prediction("alpha"), prediction("beta") }, 1, true,
				nil, "alt", 0, {}, nil, nil, 2
			), "positive control: the open epoch must render")
			helpers.assert_eq(calls.render, 1)

			local key_watcher = find_watcher(watchers, hs.eventtap.event.types.keyDown)
			local mouse_watcher = find_watcher(watchers, hs.eventtap.event.types.leftMouseDown)
			local flags_watcher = find_watcher(watchers, hs.eventtap.event.types.flagsChanged)
			helpers.assert_not_nil(key_watcher, "show_predictions must arm the key watcher")
			helpers.assert_not_nil(mouse_watcher, "show_predictions must arm the mouse watcher")
			helpers.assert_not_nil(flags_watcher, "show_predictions must arm the modifier watcher")

			local open_tab = event(48, {}, "\t")
			helpers.assert_eq(key_watcher.callback(open_tab), true,
				"positive control: an open-epoch Tab must be accepted")
			local synthetic = require("adapters.synthetic_input")
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1,
				"acceptance must be queued outside the HID callback")
			hs.timer.__fire_all()
			helpers.assert_eq(calls.accept, 1)
			calls.accept = 0

			set_available(false)
			local stale_tab = event(48, {}, "\t")
			helpers.assert_eq(key_watcher.callback(stale_tab), false,
				"a stale Tab must pass through rather than accept a prediction")
			helpers.assert_eq(stale_tab:read_count(), 0,
				"the epoch guard must run before stale keyboard fields are read")
			helpers.assert_eq(stale_tab:property_read_count(), 1,
				"exact provenance remains the one mandatory read before the runtime gate")
			helpers.assert_eq(calls.accept, 0)

			local stale_mouse = event(0, {}, "")
			helpers.assert_eq(mouse_watcher.callback(stale_mouse), false)
			helpers.assert_eq(stale_mouse:read_count(), 0,
				"the stale mouse path must stay before all event reads")
			helpers.assert_eq(calls.cancel, 0,
				"a stale mouse callback must not mutate the prediction lifecycle")

			local stale_flags = event(56, { shift = true }, "")
			helpers.assert_eq(flags_watcher.callback(stale_flags), false)
			helpers.assert_eq(stale_flags:read_count(), 0,
				"the stale flags path must stay before all event reads")

			-- Positive control: while the epoch is open, an arrow is consumed and
			-- schedules the AX-bearing render for the next run-loop tick.
			set_available(true)
			local arrow = event(124, {}, "")
			helpers.assert_eq(key_watcher.callback(arrow), true)
			helpers.assert_eq(synthetic.stats().pending_post_callback_actions, 1,
				"arrow navigation must have a deferred callback")

			-- The action epoch changes after the eventtap returns but before the
			-- deferred AX render runs. That callback belongs to the old epoch.
			set_available(false)
			hs.timer.__fire_all()
			helpers.assert_eq(calls.navigate, 0)
			helpers.assert_eq(calls.render, 1,
				"a stale deferred navigation callback must not repaint")
			helpers.assert_eq(T.navigate(1), false)
			helpers.assert_eq(T.show_predictions({ prediction("stale") }, 1, true), false)
			helpers.assert_eq(calls.render, 1,
				"direct stale navigation/render entry points must remain closed too")
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)


	helpers.it("a stale chain-completion callback cannot paint timing text", function()
		local T, calls, _, _, set_available, restore = load_fixture()
		local ok, err = xpcall(function()
			T.set_chain_start(hs.timer.secondsSinceEpoch() - 0.25)
			helpers.assert_true(T.show_predictions({ prediction("alpha") }, 1, true))
			T.set_timing(10, 20)
			helpers.assert_eq(calls.partial_render, 1,
				"positive control: the timing renderer must be observable while open")
			local paints_before = calls.partial_render
			set_available(false)
			T.mark_chain_complete()
			helpers.assert_eq(calls.partial_render, paints_before,
				"a completion from an older epoch must not update the shared canvas timing zone")
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("tooltip facade: quarantine is LLM-only", function()
	helpers.it("keeps stacked hotstring output available while every LLM paint is closed", function()
		helpers.load_with_stubs("infra.logger")
		local calls = { stacked = 0, loading = 0, predictions = 0, navigate = 0 }
		local llm_guard
		package.loaded["ui.tooltip.config"] = {
			setup = function() end,
			set_timeout = function() end,
			set_llm_timeout = function() end,
			set_colorization_enabled = function() end,
			tint = function() return nil end,
			set_accent_color = function() end,
		}
		package.loaded["ui.tooltip.tooltip_llm"] = {
			set_runtime_guard = function(guard) llm_guard = guard end,
			hide = function() return true end,
			hide_silent = function() return true end,
			is_visible = function() return false end,
			show_predictions = function() calls.predictions = calls.predictions + 1; return true end,
			navigate = function() calls.navigate = calls.navigate + 1 end,
			set_navigate_callback = function() end,
			set_accept_callback = function() end,
			set_cancel_callback = function() end,
			set_enter_validates = function() end,
			get_current_index = function() return 1 end,
			make_diff_styled = function() return true end,
			reset_timer = function() end,
			set_chain_start = function() end,
			mark_chain_complete = function() end,
		}
		package.loaded["ui.tooltip.tooltip_hotstring"] = {
			hide = function() return true end,
			hide_forced = function() return true end,
			is_visible = function() return false end,
			show = function() return true end,
			show_stacked = function() calls.stacked = calls.stacked + 1; return true end,
			show_loading = function() calls.loading = calls.loading + 1; return true end,
			dismiss_silent = function() return true end,
		}
		package.loaded["ui.tooltip"] = nil
		local Tooltip = require("ui.tooltip")
		Tooltip.set_runtime_guard(function() return false end)
		helpers.assert_eq(type(llm_guard), "function")
		helpers.assert_eq(llm_guard(), false)

		Tooltip.show_stacked({ { text = "hotstring output" } }, true)
		helpers.assert_eq(calls.stacked, 1,
			"the action epoch quarantines only LLM output, not the hotstring engine")
		helpers.assert_eq(Tooltip.show_loading("stale", true), false)
		helpers.assert_eq(Tooltip.show_predictions({ prediction("stale") }, 1, true), false)
		helpers.assert_eq(Tooltip.navigate(1), false)
		helpers.assert_eq(calls.loading, 0)
		helpers.assert_eq(calls.predictions, 0)
		helpers.assert_eq(calls.navigate, 0)
	end)
end)
