--- tests/unit/platform/remap/watchers/test_watchers_capsword_auto_off.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Watcher Tests
--- DESCRIPTION:
--- Drives the CapsWord watcher with the [shortcuts.caps_word] settings: each
--- pointer kind ends CapsWord only while it is checked (the watcher used to end
--- it on any pointer event), a keystroke ends it only on a checked delimiter
--- typed as a character (Karabiner used to end it on the Space, Enter and Tab
--- keys whatever was typed), and the inactivity delay ends it from the
--- activation or the last keystroke, its timer torn down with the watcher.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN = "0123456789abcdef0123456789abcdef"
local NBSP = "\xC2\xA0"
local TYPES = {
	mouseMoved = 1, scrollWheel = 2, gesture = 3,
	leftMouseDown = 4, rightMouseDown = 5, otherMouseDown = 6, keyDown = 7,
}




-- =========================================
-- =========================================
-- ======= 1/ Controllable Harness =========
-- =========================================
-- =========================================

--- Builds a running watcher over the real settings owner and policy.
--- @param overrides table|nil Menu-state values replacing the manifest defaults.
--- @return table harness
local function fresh_harness(overrides)
	package.loaded["platform.remap.watchers"] = nil
	package.loaded["infra.capsword_auto_off"] = nil
	package.loaded["modules.keymap.control_sentinels"] = nil
	package.loaded["adapters.synthetic_input"] = {
		defer_after_callback = function(_label, callback) callback(); return true end,
	}
	package.loaded["adapters.shell_runner"] = nil

	local h = {
		clock = 1000, writers = {}, supersede_calls = 0, timers = {}, capslock = {},
		active = false, revision = 0, logged_info = {}, logged_errors = {},
	}
	local logger = helpers.make_logger_stub()
	logger.info = function(_module, format_string, ...)
		h.logged_info[#h.logged_info + 1] = string.format(format_string, ...)
	end
	logger.error = function(_module, format_string, ...)
		h.logged_errors[#h.logged_errors + 1] = string.format(format_string, ...)
	end
	logger.pcall = function(module, fn, ...)
		local results = table.pack(pcall(fn, ...))
		if not results[1] then logger.error(module, "Exception: %s", tostring(results[2])) end
		return table.unpack(results, 1, results.n)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["adapters.timer_scheduler"] = {
		now_ns = function() return h.clock * 1000000000 end,
		after = function(delay, callback)
			local handle = { delay = delay, callback = callback, cancelled = false }
			h.timers[#h.timers + 1] = handle
			return handle, true
		end,
		cancel = function(handle)
			if handle then handle.cancelled = true end
			return true
		end,
	}
	package.loaded["adapters.key_state"] = {
		set_capslock = function(value) h.capslock[#h.capslock + 1] = value end,
	}
	package.loaded["platform.remap.ke_variables"] = {
		capsword_revision = function() return h.revision end,
		capsword_known_active = function() return h.active end,
		observe_capsword_state = function(value, token)
			if token ~= TOKEN then return false, h.revision end
			h.revision = h.revision + 1
			h.active = value == 1
			return true, h.revision
		end,
		supersede_capsword_activation = function(callback)
			h.supersede_calls = h.supersede_calls + 1
			if not h.active then return false, h.revision end
			h.active = false
			h.revision = h.revision + 1
			h.writers[#h.writers + 1] = { callback = callback, revision = h.revision }
			return true, h.revision
		end,
	}
	h.gestures = {
		set_any_touch_hook = function(callback) h.touch = callback end,
	}

	h.settings = require("infra.capsword_auto_off")
	local state = {}
	for key, value in pairs(h.settings.DEFAULT_STATE) do state[key] = value end
	-- Each case names its settings: these pin a known base, "shipped" keeps
	-- the manifest defaults themselves.
	if not (overrides and overrides.shipped) then
		state.caps_word_idle_timeout_seconds = 0
		state.caps_word_terminators = { "space", "tab", "enter" }
	end
	local pointer = {}
	for kind, enabled in pairs(state.caps_word_pointer) do pointer[kind] = enabled end
	state.caps_word_pointer = pointer
	for key, value in pairs(overrides or {}) do
		-- caps_word_pointer_<kind> overrides one kind of the pointer table.
		local kind = key:match("^caps_word_pointer_(.+)$")
		if kind then pointer[kind] = value elseif key ~= "shipped" then state[key] = value end
	end
	helpers.assert_true(h.settings.apply_state(state), "the test settings must compile")

	h.sentinels = require("modules.keymap.control_sentinels")
	h.watchers = helpers.load_with_stubs("platform.remap.watchers", {
		eventtap = {
			new = function(types, callback)
				h.types = types
				h.callback = callback
				return { start = function() return true end, stop = function() end }
			end,
			event = { types = TYPES, properties = { mouseEventButtonNumber = 3 } },
		},
		timer = { secondsSinceEpoch = function() return h.clock end },
	})
	h.watcher = h.watchers.start_gesture_watcher(h.gestures, TOKEN)
	helpers.assert_true(h.watcher ~= nil, "the watcher must start")
	return h
end

--- Switches CapsWord on through its Karabiner control signal.
local function activate(h)
	h.sentinels.claim_key(90, true, { ctrl = true, alt = true, shift = true })
	helpers.assert_true(h.active, "the activation signal must be observed")
end

--- One pointer event of a type, past the pointer throttle.
local function pointer(h, event_type, button)
	h.clock = h.clock + 1
	h.callback({
		getType = function() return event_type end,
		getProperty = function(_self, property)
			helpers.assert_eq(property, 3, "the button number is read from its event property")
			return button
		end,
	})
end

--- One keystroke typing `text`.
local function key(h, text)
	h.callback({
		getType = function() return TYPES.keyDown end,
		getCharacters = function() return text end,
	})
end

--- Asserts one INFO line names the deactivation cause.
local function assert_logged(h, text)
	for _, line in ipairs(h.logged_info) do
		if line:find(text, 1, true) then return end
	end
	error("no INFO line contains " .. text .. ": " .. table.concat(h.logged_info, " | "), 2)
end

--- The pending timers at an exact delay.
local function timers_at(h, delay)
	local found = {}
	for _, handle in ipairs(h.timers) do
		if handle.delay == delay and not handle.cancelled then found[#found + 1] = handle end
	end
	return found
end




-- ===================================
-- ===================================
-- ======= 2/ Pointer Kinds ==========
-- ===================================
-- ===================================

helpers.describe("CapsWord watcher: pointer kinds follow the settings", function()
	helpers.it("pointer motion ends CapsWord only while it is checked", function()
		local h = fresh_harness({ [ "caps_word_pointer_pointer_motion" ] = false })
		activate(h)
		pointer(h, TYPES.mouseMoved)
		pointer(h, TYPES.scrollWheel)
		helpers.assert_eq(h.supersede_calls, 0, "unchecked pointer motion must leave CapsWord on")
		helpers.assert_true(h.active)
		pointer(h, TYPES.leftMouseDown)
		helpers.assert_eq(#h.writers, 1, "a checked left click still ends it")
		assert_logged(h, "pointer left_click")
	end)

	helpers.it("maps button 2 to the middle click and every other button to other buttons", function()
		local h = fresh_harness({ caps_word_pointer_middle_click = false })
		activate(h)
		pointer(h, TYPES.otherMouseDown, 2)
		helpers.assert_eq(h.supersede_calls, 0, "an unchecked middle click must leave CapsWord on")
		pointer(h, TYPES.otherMouseDown, 4)
		helpers.assert_eq(#h.writers, 1, "a back or forward button is an other button")

		local other = fresh_harness({ caps_word_pointer_other_buttons = false })
		activate(other)
		pointer(other, TYPES.otherMouseDown, 3)
		helpers.assert_eq(other.supersede_calls, 0, "an unchecked other button must leave CapsWord on")
		pointer(other, TYPES.otherMouseDown, 2)
		helpers.assert_eq(#other.writers, 1, "the middle button keeps its own setting")
	end)

	helpers.it("the bare-touch hook is a gesture kind", function()
		local h = fresh_harness({ caps_word_pointer_gesture = false })
		activate(h)
		h.clock = h.clock + 1
		h.touch()
		pointer(h, TYPES.gesture)
		helpers.assert_eq(h.supersede_calls, 0, "an unchecked gesture must leave CapsWord on")
		local checked = fresh_harness()
		activate(checked)
		checked.clock = checked.clock + 1
		checked.touch()
		helpers.assert_eq(#checked.writers, 1, "a checked gesture ends it")
	end)

	helpers.it("watches keystrokes too, so a delimiter needs no Karabiner exit", function()
		local h = fresh_harness()
		local watched = {}
		for _, event_type in ipairs(h.types) do watched[event_type] = true end
		helpers.assert_true(watched[TYPES.keyDown], "the CapsWord tap must see keystrokes")
	end)
end)




-- ===================================
-- ===================================
-- ======= 3/ Delimiters =============
-- ===================================
-- ===================================

helpers.describe("CapsWord watcher: a typed delimiter ends CapsWord only when checked", function()
	helpers.it("Space ends CapsWord at once, CapsLock off before the next letter", function()
		local h = fresh_harness()
		activate(h)
		key(h, "a")
		helpers.assert_eq(h.supersede_calls, 0, "a letter is no delimiter")
		key(h, " ")
		helpers.assert_eq(#h.writers, 1, "a checked Space ends CapsWord")
		helpers.assert_eq(h.capslock, { false }, "CapsLock goes off before the write settles")
		assert_logged(h, "delimiter typed")
	end)

	helpers.it("an unchecked Space leaves CapsWord on", function()
		local h = fresh_harness({ caps_word_terminators = { "tab", "enter" } })
		activate(h)
		key(h, " ")
		helpers.assert_eq(h.supersede_calls, 0, "Space was unchecked")
		key(h, "\r")
		helpers.assert_eq(#h.writers, 1, "a checked Enter still ends it")
	end)

	helpers.it("a no-break space ends CapsWord only through its own entry", function()
		local h = fresh_harness()
		activate(h)
		key(h, NBSP)
		helpers.assert_eq(h.supersede_calls, 0, "Space, Tab and Enter exclude the no-break space")
		local checked = fresh_harness({ caps_word_terminators = { "space", "nbsp" } })
		activate(checked)
		key(checked, NBSP)
		helpers.assert_eq(#checked.writers, 1, "a checked no-break space ends it")
	end)

	helpers.it("a keystroke without an active CapsWord costs no write", function()
		local h = fresh_harness()
		key(h, " ")
		helpers.assert_eq(h.supersede_calls, 0)
		helpers.assert_eq(h.capslock, {})
	end)
end)




-- ===================================
-- ===================================
-- ======= 4/ Inactivity =============
-- ===================================
-- ===================================

helpers.describe("CapsWord watcher: the inactivity delay", function()
	helpers.it("never arms a timer at 0 (never)", function()
		local h = fresh_harness()
		activate(h)
		helpers.assert_eq(#h.timers, 0)
	end)

	helpers.it("ends CapsWord when the delay passes after the activation", function()
		local h = fresh_harness({ caps_word_idle_timeout_seconds = 3 })
		activate(h)
		local timer = timers_at(h, 3)[1]
		helpers.assert_true(timer ~= nil, "the activation arms the delay")
		h.clock = h.clock + 3
		timer.callback()
		helpers.assert_eq(#h.writers, 1, "the delay ends CapsWord")
		helpers.assert_eq(h.capslock, { false })
		assert_logged(h, "no keystroke for 3 s")
	end)

	helpers.it("measures from the last keystroke", function()
		local h = fresh_harness({ caps_word_idle_timeout_seconds = 3 })
		activate(h)
		local first = timers_at(h, 3)[1]
		h.clock = h.clock + 2
		key(h, "a")
		h.clock = h.clock + 1
		first.callback()
		helpers.assert_eq(h.supersede_calls, 0, "a keystroke 1 s ago keeps CapsWord on")
		local rearmed = timers_at(h, 2)[1]
		helpers.assert_true(rearmed ~= nil, "the check waits the remaining 2 s")
		h.clock = h.clock + 2
		rearmed.callback()
		helpers.assert_eq(#h.writers, 1)
	end)

	helpers.it("a Karabiner exit and the watcher stop cancel the timer", function()
		local h = fresh_harness({ caps_word_idle_timeout_seconds = 5 })
		activate(h)
		local timer = timers_at(h, 5)[1]
		h.sentinels.claim_key(90, true, { ctrl = true, alt = true, cmd = true })
		helpers.assert_true(timer.cancelled, "a native exit leaves nothing to time out")
		activate(h)
		local second = timers_at(h, 5)[1]
		helpers.assert_true(h.watchers.stop_gesture_watcher(h.watcher))
		helpers.assert_true(second.cancelled, "the stopped lease owns no timer")
		second.callback()
		helpers.assert_eq(h.supersede_calls, 0, "a queued check of a stopped lease is inert")
	end)

	helpers.it("a CapsWord the driver switched on itself starts the delay", function()
		local h = fresh_harness({ caps_word_idle_timeout_seconds = 1 })
		h.active = true
		helpers.assert_true(h.watchers.note_capsword_activated())
		helpers.assert_true(timers_at(h, 1)[1] ~= nil)
	end)
end)





-- ===================================
-- ===================================
-- ======= 5/ Shipped Defaults =======
-- ===================================
-- ===================================

helpers.describe("CapsWord watcher: the shipped defaults end CapsWord on typed punctuation", function()
	-- Karabiner no longer has the "." and "," exits (keys g and v): the typed
	-- characters end CapsWord here, whatever layout key, layer or dead key
	-- produced them, and a French spaced-punctuation carrier counts as typed.
	for _, text in ipairs({ ".", ",", ";", "\xE2\x80\xAF;", "\xC2\xA0", "\xE2\x80\xAF" }) do
		helpers.it(string.format("ends CapsWord on %q", text), function()
			local h = fresh_harness({ shipped = true })
			activate(h)
			key(h, text)
			helpers.assert_eq(#h.writers, 1, "a shipped delimiter ends CapsWord")
		end)
	end

	helpers.it("arms the shipped inactivity delay at the activation", function()
		local h = fresh_harness({ shipped = true })
		activate(h)
		local delay = require("caps_word.auto_off").idle_delay_ms(h.settings.policy()) / 1000
		helpers.assert_eq(delay, require("infra.manifest_reader").default_for("shortcuts.caps_word.idle_timeout_seconds"),
			"the shipped delay is the manifest default")
		helpers.assert_eq(delay, 10, "10 s (maintainer decision of 2026-10-20)")
		helpers.assert_true(timers_at(h, delay)[1] ~= nil, "the delay counts from the activation")
	end)
end)
