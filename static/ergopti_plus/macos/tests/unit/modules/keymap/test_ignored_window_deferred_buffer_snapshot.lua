--- tests/unit/modules/keymap/test_ignored_window_deferred_buffer_snapshot.lua

--- ==============================================================================
--- MODULE: Ignored-window eventtap pass-through regression
--- DESCRIPTION:
--- Ignored windows are a privacy and ownership boundary: their keystrokes must
--- never enter interceptors, the rolling buffer, preview providers, or hotstrings.
--- Only the off-eventtap window-classification refresh may be deferred. A
--- historical branch below the early return claimed to run
--- repeatable features asynchronously in ignored windows, but that branch was
--- unreachable. Its source-only snapshot test stayed green without loading the
--- production eventtap. This test drives the real tap and asserts the observable
--- pass-through contract at the boundary where the old false green could not.
--- ==============================================================================

local helpers = require("tests.helpers")

local function install_collaborators(effects)
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^adapters%.")
		) then
			package.loaded[name] = nil
		end
	end

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() effects.llm_calls = effects.llm_calls + 1; return false end,
	}
	package.loaded["modules.llm.prediction_engine"] = {
		init = function() return true end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function()
			effects.llm_calls = effects.llm_calls + 1
			-- Preserve the real engine.reset() contract that this integration test
			-- exercises: a committed reset revokes native tooltip pixels.
			local tooltip = package.loaded["ui.tooltip"]
			return tooltip and tooltip.hide_forced_silent()
		end,
		handle_chain_signal = function() effects.llm_calls = effects.llm_calls + 1; return false end,
		is_visible = function() return false end,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() effects.keylogger_calls = effects.keylogger_calls + 1 end,
		log_hotstring_dismissed = function() effects.keylogger_calls = effects.keylogger_calls + 1 end,
		log_llm_accepted = function() effects.keylogger_calls = effects.keylogger_calls + 1 end,
		log_hotstring = function() effects.keylogger_calls = effects.keylogger_calls + 1 end,
		notify_synthetic = function(text, source)
			effects.keylogger_calls = effects.keylogger_calls + 1
			if source == "hotstring" then effects.emitted[#effects.emitted + 1] = text end
		end,
		set_buffer = function() effects.keylogger_calls = effects.keylogger_calls + 1 end,
	}
	package.loaded["ui.tooltip"] = {
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		set_colorization_enabled = function() end,
		set_accent_color = function() end,
		tint = function() return {} end,
		show_stacked = function()
			effects.tooltip_calls = effects.tooltip_calls + 1
			effects.tooltip_shows = (effects.tooltip_shows or 0) + 1
			effects.tooltip_visible = true
			return true
		end,
		hide = function()
			effects.tooltip_calls = effects.tooltip_calls + 1
			effects.tooltip_hides = (effects.tooltip_hides or 0) + 1
			effects.tooltip_visible = false
			return true
		end,
		hide_forced = function()
			effects.tooltip_calls = effects.tooltip_calls + 1
			effects.tooltip_hides = (effects.tooltip_hides or 0) + 1
			effects.tooltip_visible = false
			return true
		end,
		hide_forced_silent = function()
			effects.tooltip_calls = effects.tooltip_calls + 1
			effects.tooltip_hides = (effects.tooltip_hides or 0) + 1
			effects.tooltip_visible = false
			return true
		end,
		is_visible = function() return effects.tooltip_visible == true end,
		is_hotstring_visible = function() return effects.tooltip_visible == true end,
		has_visible_hotstring_lease = function() return effects.tooltip_visible == true end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = { resolve = function() return nil end }
	package.loaded["adapters.tooltip_renderer"] = { hide = function() return true end }
end

local function find_keydown_tap(hs_stub)
	for _, tap in ipairs(hs_stub.eventtap.__taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then return tap end
	end
	return nil
end


local function watcher_capable_window(app_name, title_fn)
	local function watcher()
		return {
			start = function(self) return self end,
			stop = function(self) return self end,
		}
	end
	local app = {
		pid = function() return 9001 end,
		name = function() return app_name end,
		newWatcher = function() return watcher() end,
	}
	return {
		id = function() return 42 end,
		application = function() return app end,
		title = title_fn,
		newWatcher = function() return watcher() end,
	}
end


-- Drain only immediate work, one runloop turn at a time. Production deliberately
-- keeps a future TTL timer alive; hs_stub.__fire_all() would execute and re-arm
-- that future work forever because the stub has no wall-clock scheduler.
local function drain_immediate_timers(hs_stub)
	for _ = 1, 32 do
		local snapshot = {}
		for _, timer in ipairs(hs_stub.timer.__timers) do
			if timer.running and timer.delay == 0 then snapshot[#snapshot + 1] = timer end
		end
		if #snapshot == 0 then return end
		for _, timer in ipairs(snapshot) do
			if timer.running then timer:fire() end
		end
	end
	error("immediate timer queue did not settle", 0)
end

helpers.describe("ignored-window eventtap boundary", function()
	helpers.it("classifies off-tap, then passes ignored keys without reading their text", function()
		local effects = {
			interceptor_calls = 0,
			interceptor_buffers = {},
			preview_calls = 0,
			tooltip_calls = 0,
			keylogger_calls = 0,
			llm_calls = 0,
			emitted = {},
		}
		install_collaborators(effects)
		local Keymap = helpers.load_with_stubs("modules.keymap")
		local hs_stub = _G.hs
		Keymap.ignore_window_title("Sensitive Entry")
		Keymap.register_interceptor(function(_event, buffer)
			effects.interceptor_calls = effects.interceptor_calls + 1
			effects.interceptor_buffers[#effects.interceptor_buffers + 1] = buffer
		end)
		Keymap.register_preview_provider(function()
			effects.preview_calls = effects.preview_calls + 1
		end)
		Keymap.start()

		local tap = find_keydown_tap(hs_stub)
		helpers.assert_not_nil(tap, "the production keymap must install a key-down eventtap")

		local reads = { keycode = 0, flags = 0, characters = 0 }
		local event = {
			getProperty = function() return 0 end,
			getKeyCode = function() reads.keycode = reads.keycode + 1; return 0 end,
			getFlags = function()
				reads.flags = reads.flags + 1
				return { cmd = false, ctrl = false, alt = false, shift = false }
			end,
			getCharacters = function() reads.characters = reads.characters + 1; return "a" end,
		}

		local original_focused_window = hs_stub.window.focusedWindow
		local original_timer_new = hs_stub.timer.new
		local original_do_after = hs_stub.timer.doAfter
		local original_subscribe = hs_stub.window.filter.default.subscribe
		local scheduled = 0
		local focused_reads = 0
		local filter_subscriptions = 0
		hs_stub.window.focusedWindow = function()
			focused_reads = focused_reads + 1
			return watcher_capable_window("Password Manager", function() return "Sensitive Entry" end)
		end
		hs_stub.timer.new = function(...)
			scheduled = scheduled + 1
			return original_timer_new(...)
		end
		hs_stub.timer.doAfter = function(...)
			scheduled = scheduled + 1
			return original_do_after(...)
		end
		hs_stub.window.filter.default.subscribe = function(self, events, callback)
			filter_subscriptions = filter_subscriptions + 1
			return original_subscribe(self, events, callback)
		end

		local first_consumed, second_consumed
		local tooltip_calls_in_tap, llm_calls_in_tap
		local ok, err = xpcall(function()
			first_consumed = tap.fn(event)
			tooltip_calls_in_tap = effects.tooltip_calls
			llm_calls_in_tap = effects.llm_calls
			helpers.assert_eq(focused_reads, 0,
				"the keyDown callback must not perform the focused-window AX probe")
			helpers.assert_eq(filter_subscriptions, 0,
				"cold hs.window.filter setup must not run in the keyDown callback")
			drain_immediate_timers(hs_stub)
			second_consumed = tap.fn(event)
		end, debug.traceback)
		hs_stub.window.focusedWindow = original_focused_window
		hs_stub.timer.new = original_timer_new
		hs_stub.timer.doAfter = original_do_after
		hs_stub.window.filter.default.subscribe = original_subscribe
		if not ok then error(err, 0) end

		helpers.assert_eq(first_consumed, false,
			"an unclassified physical key must pass through while AX refreshes off-tap")
		helpers.assert_eq(second_consumed, false,
			"a classified ignored physical key must pass through to its application")
		helpers.assert_eq(reads.keycode, 2, "the fast-exit keycode gate may read each keycode once")
		helpers.assert_eq(reads.flags, 0, "ignored input must exit before modifier decoding")
		helpers.assert_eq(reads.characters, 0,
			"ignored input must exit before text is read, so it cannot enter the rolling buffer")
		helpers.assert_eq(effects.interceptor_calls, 0, "ignored input must not reach interceptors")
		helpers.assert_eq(effects.preview_calls, 0, "ignored input must not reach preview providers")
		helpers.assert_eq(tooltip_calls_in_tap, 0,
			"unknown input must not mutate native tooltip state inside CGEventTap")
		helpers.assert_eq(llm_calls_in_tap, 0,
			"unknown input must not reset the LLM engine inside CGEventTap")
		helpers.assert_eq(effects.tooltip_calls, 1,
			"off-tap ownership cleanup must revoke any surface before ignored state settles")
		helpers.assert_eq(effects.keylogger_calls, 0, "ignored input must not reach keylogger sinks")
		helpers.assert_eq(effects.llm_calls, 1,
			"off-tap ownership cleanup must reset, but never reopen, the LLM runtime")
		helpers.assert_eq(scheduled, 2,
			"the dirty cache must arm one classification and one ownership cleanup, never loop")
		helpers.assert_eq(focused_reads, 1,
			"the deferred refresh must perform one real probe instead of recursively re-entering the cache")
		helpers.assert_eq(filter_subscriptions, 0,
			"ignored-window tracking must never subscribe the global window filter")
		local running_zero_timers = 0
		for _, timer in ipairs(hs_stub.timer.__timers) do
			if timer.running and timer.delay == 0 then running_zero_timers = running_zero_timers + 1 end
		end
		helpers.assert_eq(running_zero_timers, 0,
			"one refresh must settle; a dirty/clean timer loop must not survive it")
	end)

	helpers.it("severs the buffer across normal to ignored to normal transitions", function()
		local effects = {
			interceptor_calls = 0,
			interceptor_buffers = {},
			preview_calls = 0,
			tooltip_calls = 0,
			keylogger_calls = 0,
			llm_calls = 0,
			emitted = {},
		}
		install_collaborators(effects)
		local Keymap = helpers.load_with_stubs("modules.keymap")
		local hs_stub = _G.hs
		local Utils = package.loaded["modules.keymap.utils"]
		Keymap.ignore_window_title("Sensitive Entry")
		Keymap.register_interceptor(function(_event, buffer)
			effects.interceptor_calls = effects.interceptor_calls + 1
			effects.interceptor_buffers[#effects.interceptor_buffers + 1] = buffer
		end)
		Keymap.add("aeu", "eau", {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		})
		Keymap.sort_mappings()
		Keymap.set_base_delay(0)
		Keymap.start()

		local tap = find_keydown_tap(hs_stub)
		helpers.assert_not_nil(tap, "the production keymap must install a key-down eventtap")
		local focused_title = "Normal Editor"
		local original_focused_window = hs_stub.window.focusedWindow
		hs_stub.window.focusedWindow = function()
			return watcher_capable_window("Test App", function() return focused_title end)
		end

		local function physical_key(character)
			return {
				getProperty = function() return 0 end,
				getKeyCode = function() return 0 end,
				getFlags = function()
					return { cmd = false, ctrl = false, alt = false, shift = false }
				end,
				getCharacters = function() return character end,
			}
		end

		local ok, err = xpcall(function()
			-- Establish a known normal cache off the HID callback, as production boot does.
			Utils.prewarm_ignored_win_watchers({ ["Sensitive Entry"] = true }, {})
			helpers.assert_eq(tap.fn(physical_key("a")), false)

			focused_title = "Sensitive Entry"
			hs_stub.application.__emit(
				"Test App", hs_stub.application.watcher.activated, {})
			helpers.assert_eq(tap.fn(physical_key("e")), false,
				"the first key after a dirty transition must pass through untransformed")

			focused_title = "Normal Editor"
			hs_stub.application.__emit(
				"Test App", hs_stub.application.watcher.activated, {})
			helpers.assert_eq(tap.fn(physical_key("x")), false,
				"the first key returning to the normal app must also pass through")
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(tap.fn(physical_key("u")), false)

			-- Runtime rule mutation is itself a context transition. No focus watcher
			-- fires here: the writer must invalidate the already-clean false cache.
			focused_title = "Runtime Secret"
			Keymap.ignore_window_title("Runtime Secret")
			helpers.assert_eq(tap.fn(physical_key("z")), false)
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(tap.fn(physical_key("z")), false)

			-- A disable/enable cycle also crosses an unobserved typing interval.
			-- The prefix seen before stop must not survive into the restarted engine.
			focused_title = "Normal Editor"
			hs_stub.application.__emit(
				"Test App", hs_stub.application.watcher.activated, {})
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(tap.fn(physical_key("a")), false)
			helpers.assert_eq(Keymap.stop(), true)
			Keymap.start()
			helpers.assert_eq(tap.fn(physical_key("e")), false,
				"feature restart must process the first known-normal key from a cleared buffer")
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(tap.fn(physical_key("u")), false)
			helpers.assert_eq(Keymap.stop(), true)
		end, debug.traceback)
		hs_stub.window.focusedWindow = original_focused_window
		Keymap.set_base_delay(0.4)
		if not ok then error(err, 0) end

		helpers.assert_eq(#effects.emitted, 0,
			"stale normal/ignored text must never assemble the shipped aeu correction")
		helpers.assert_eq(effects.interceptor_calls, 5,
			"only known-normal keys may reach interceptors; ignored and unknown keys must not")
		helpers.assert_eq(effects.interceptor_buffers[1], "",
			"the initial normal key must start from an empty context")
		helpers.assert_eq(effects.interceptor_buffers[2], "",
			"the post-transition key must see a severed buffer, not the old app's 'a'")
		helpers.assert_eq(effects.interceptor_buffers[4], "",
			"the first post-restart key must not see the prefix typed before stop")
		helpers.assert_eq(effects.interceptor_buffers[5], "e",
			"the next post-restart key must continue from the first key, not a stale pre-stop prefix")
	end)

	helpers.it("hides an old tooltip while ownership is unknown and rebuilds it after normal recovery", function()
		local effects = {
			interceptor_calls = 0,
			interceptor_buffers = {},
			preview_calls = 0,
			tooltip_calls = 0,
			tooltip_shows = 0,
			tooltip_hides = 0,
			tooltip_visible = false,
			keylogger_calls = 0,
			llm_calls = 0,
			emitted = {},
		}
		install_collaborators(effects)
		local Keymap = helpers.load_with_stubs("modules.keymap")
		local hs_stub = _G.hs
		local Utils = package.loaded["modules.keymap.utils"]
		local LLMBridge = package.loaded["modules.keymap.llm_bridge"]
		Keymap.ignore_window_title("Sensitive Entry")
		Keymap.set_preview_autocorrect_enabled(true)
		local preview_action = {}
		Keymap.register_preview_provider(function(buffer)
			effects.preview_calls = effects.preview_calls + 1
			if buffer == "a" then return "visible preview", preview_action end
			return nil
		end)

		local tap = find_keydown_tap(hs_stub)
		helpers.assert_not_nil(tap, "the production keymap must install a key-down eventtap")
		local focused_title = "Normal Editor"
		local original_focused_window = hs_stub.window.focusedWindow
		hs_stub.window.focusedWindow = function()
			return watcher_capable_window("Test App", function() return focused_title end)
		end
		local function physical_key(character)
			return {
				getProperty = function() return 0 end,
				getKeyCode = function() return 0 end,
				getFlags = function()
					return { cmd = false, ctrl = false, alt = false, shift = false }
				end,
				getCharacters = function() return character end,
			}
		end

		local ok, err = xpcall(function()
			-- Align the keymap's observed generation with a known-normal cache, then
			-- drive the real preview pipeline until a physical tooltip is committed.
			Keymap.start()
			Utils.prewarm_ignored_win_watchers({ ["Sensitive Entry"] = true }, {})
			helpers.assert_eq(tap.fn(physical_key("a")), false)
			drain_immediate_timers(hs_stub)
			helpers.assert_true(effects.tooltip_visible,
				"the fixture must first commit a real visible tooltip in the normal window")
			helpers.assert_true(effects.tooltip_shows > 0,
				"the setup must reach tooltip.show_stacked, not seed a fake visibility flag")

			-- The first key can overtake the off-tap AX refresh. It must close the
			-- runtime in O(1), while the actual canvas hide happens only after return.
			focused_title = "Sensitive Entry"
			hs_stub.application.__emit(
				"Test App", hs_stub.application.watcher.activated, {})
			local hides_before_unknown = effects.tooltip_hides
			helpers.assert_eq(tap.fn(physical_key("x")), false)
			helpers.assert_true(effects.tooltip_visible,
				"the eventtap must not perform canvas teardown synchronously")
			helpers.assert_eq(effects.tooltip_hides, hides_before_unknown,
				"the visible surface must be hidden only by deferred work")
			helpers.assert_eq(LLMBridge.is_runtime_available(), false,
				"unknown ownership must close the LLM runtime before the key passes")
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(effects.tooltip_visible, false,
				"the old normal-window tooltip must be hidden after the off-tap reset")
			helpers.assert_true(effects.tooltip_hides > hides_before_unknown,
				"the deferred reset must reach a real tooltip hide operation")
			helpers.assert_eq(LLMBridge.is_runtime_available(), false,
				"an ignored destination must stay quarantined after cleanup")

			-- Classify the destination as normal before its one physical key arrives.
			-- That key is processed while reconciliation is queued; after the timer
			-- resets and reopens the runtime, catch-up must rebuild its preview.
			focused_title = "Normal Editor"
			hs_stub.application.__emit(
				"Test App", hs_stub.application.watcher.activated, {})
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(LLMBridge.is_runtime_available(), false,
				"classification alone must not reopen stale prediction state")
			local shows_before_recovery = effects.tooltip_shows
			helpers.assert_eq(tap.fn(physical_key("a")), false)
			helpers.assert_eq(effects.tooltip_shows, shows_before_recovery,
				"the preview render must remain off the keyDown callback")
			drain_immediate_timers(hs_stub)
			helpers.assert_eq(LLMBridge.is_runtime_available(), true,
				"known-normal reconciliation must reopen the runtime")
			helpers.assert_true(effects.tooltip_visible,
				"the one post-transition key must own a visible preview after reconciliation")
			helpers.assert_true(effects.tooltip_shows > shows_before_recovery,
				"post-reconcile catch-up must re-run the preview for the authoritative buffer")
		end, debug.traceback)
		hs_stub.window.focusedWindow = original_focused_window
		Keymap.set_preview_autocorrect_enabled(false)
		pcall(Keymap.stop)
		if not ok then error(err, 0) end
	end)
end)
