--- tests/unit/modules/keystats/privacy/test_focus_guard_window_mode.lua

--- ==============================================================================
--- MODULE: Focus Guard Window Mode Tests (Linux)
--- DESCRIPTION:
--- Field report, Arch Linux, KDE Plasma 6.8 Wayland, 2026-11-25: no hotstring
--- ever fired, with no error, while remapping worked. The guard admitted text
--- automation only after an accessibility field verdict joined its window
--- context; a desktop whose focused window is not on the accessibility bus never
--- gave one, so every expansion was withheld in silence. These tests drive the
--- real guard through each desktop condition and pin the three modes, the
--- password-field latch and the published reason.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds one contextual guard whose watcher, policy and clock the test drives.
--- @param overrides table|nil { window_policy = false to omit it }
--- @return table guard, table state
local function fixture(overrides)
	overrides = overrides or {}
	local state = { now = 0, field = nil, authority = "unavailable", epoch = 0, secure = true,
		policy_allows = true, policy_reason = nil, policy_calls = 0, states = {}, operations = {} }
	local listener
	local watch = {
		on_change = function(fn) listener = fn end,
		invalidate = function() listener(nil) end,
		pump = function() end,
		barrier = function() return state.field end,
		snapshot = function() return state.field end,
		authority = function() return state.field and "field" or state.authority end,
	}
	local window_policy = nil
	if overrides.window_policy ~= false then
		window_policy = function()
			state.policy_calls = state.policy_calls + 1
			if state.policy_error then error("policy failed") end
			return state.policy_allows, state.policy_reason
		end
	end
	local guard = require("modules.keystats.focus_guard").new({
		watch = watch, retry_ms = 1000, settle_ms = 250,
		detector = {
			invalidateFocus = function() state.epoch = state.epoch + 1; return state.epoch end,
			currentEpoch = function() return state.epoch end,
			publishFocus = function(_, epoch) return epoch == state.epoch end,
			isSecureField = function() return state.secure end,
		},
		keystats = {
			set_secure_field = function(value) state.secure = value end,
			is_context_protected = function() return false end,
		},
		now_ms = function() return state.now end,
		capture_context_async = function(field, options, callback)
			local request = { field = field, callback = callback, settled = false }
			state.operations[#state.operations + 1] = request
			return { is_settled = function() return request.settled end, cancel = function() return request.settled end }
		end,
		publish_context = function() return true, false end,
		window_policy = window_policy,
		on_state = function(mode, reason) state.states[#state.states + 1] = mode .. ":" .. reason end,
	})
	return guard, state
end

local PASSWORD_ROLE = 40
local TEXT_ROLE = 61

helpers.describe("FocusGuard: text automation without a field verdict", function()
	helpers.it("(text-automation-window) a session without the accessibility worker admits hotstrings in window mode", function()
		local guard, state = fixture()
		state.authority = "unavailable"
		local allowed, mode, reason = guard.text_automation()
		helpers.assert_true(allowed, "the silent withholding of the field report")
		helpers.assert_eq(mode, "window")
		helpers.assert_eq(reason, "atspi_unavailable")
		helpers.assert_true(guard.blocks_text(), "metrics and every other reader stay closed outside the field mode")
	end)

	helpers.it("(text-automation-window) a window on no application of the bus is named as such", function()
		local guard, state = fixture()
		state.authority = "absent"
		local allowed, mode, reason = guard.text_automation()
		helpers.assert_true(allowed)
		helpers.assert_eq(mode, "window")
		helpers.assert_eq(reason, "no_accessible_window")
	end)

	helpers.it("(text-automation-window) an unanswered query is named, not confused with an absent window", function()
		local guard, state = fixture()
		state.authority = "unanswered"
		local _, mode, reason = guard.text_automation()
		helpers.assert_eq(mode, "window")
		helpers.assert_eq(reason, "no_focus_answer")
	end)

	helpers.it("(text-automation-window) a password field closes even the window mode until another field is seen", function()
		local guard, state = fixture()
		state.field = { bus = ":1.9", path = "/pw", role = PASSWORD_ROLE }
		local allowed, mode, reason = guard.text_automation()
		helpers.assert_eq(allowed, false)
		helpers.assert_eq(mode, "closed")
		helpers.assert_eq(reason, "password_field")
		-- The worker stops answering while the password field keeps focus.
		state.field, state.authority = nil, "unanswered"
		allowed, mode, reason = guard.text_automation()
		helpers.assert_eq(allowed, false, "a failed answer cannot reopen a password field")
		helpers.assert_eq(reason, "password_field")
		-- An ordinary field releases the latch.
		state.field = { bus = ":1.9", path = "/text", role = TEXT_ROLE }
		guard.text_automation()
		state.field, state.authority = nil, "unanswered"
		allowed, mode = guard.text_automation()
		helpers.assert_true(allowed)
		helpers.assert_eq(mode, "window")
	end)

	helpers.it("(text-automation-window) the window policy (password apps, private windows) still closes", function()
		local guard, state = fixture()
		state.policy_allows, state.policy_reason = false, "protected_context"
		local allowed, mode, reason = guard.text_automation()
		helpers.assert_eq(allowed, false)
		helpers.assert_eq(mode, "closed")
		helpers.assert_eq(reason, "protected_context")
		state.policy_error = true
		allowed, mode, reason = guard.text_automation()
		helpers.assert_eq(allowed, false, "a failing policy closes")
		helpers.assert_eq(reason, "window_policy_failed")
	end)

	helpers.it("(text-automation-window) without a window policy the guard stays fail-closed", function()
		local guard, state = fixture({ window_policy = false })
		state.authority = "absent"
		local allowed, mode, reason = guard.text_automation()
		helpers.assert_eq(allowed, false)
		helpers.assert_eq(mode, "closed")
		helpers.assert_eq(reason, "no_accessible_window")
	end)

	helpers.it("(text-automation-window) the settle delay after navigation and a stopped guard close", function()
		local guard, state = fixture()
		guard.invalidate()
		local allowed, _, reason = guard.text_automation()
		helpers.assert_eq(allowed, false, "a navigation not yet settled closes")
		helpers.assert_eq(reason, "settling")
		state.now = 250
		helpers.assert_true((guard.text_automation()), "the settled window reopens in window mode")
		guard.stop()
		allowed, _, reason = guard.text_automation()
		helpers.assert_eq(allowed, false)
		helpers.assert_eq(reason, "stopped")
	end)

	helpers.it("(text-automation-window) a joined ordinary field is the field mode, with metrics", function()
		local guard, state = fixture()
		state.field = { bus = ":1.9", path = "/text", role = TEXT_ROLE }
		guard.prime()
		local request = state.operations[1]
		request.settled = true
		request.callback({ app_id = "kate", title = "Notes", native_identity = "window:1" })
		helpers.assert_true(guard.refresh(true))
		local allowed, mode, reason = guard.text_automation()
		helpers.assert_true(allowed)
		helpers.assert_eq(mode, "field")
		helpers.assert_eq(reason, "field_admitted")
		helpers.assert_eq(guard.blocks_text(), false)
	end)

	helpers.it("(text-automation-window) the state is published once per change", function()
		local guard, state = fixture()
		guard.text_automation(); guard.text_automation()
		helpers.assert_eq(#state.states, 1)
		helpers.assert_eq(state.states[1], "window:atspi_unavailable")
		helpers.assert_eq(guard.automation_state().mode, "window")
		state.policy_allows = false
		guard.text_automation()
		helpers.assert_eq(state.states[2], "closed:protected_context")
	end)

	helpers.it("(text-automation-window) a window-mode output owner lapses when the policy closes", function()
		local guard, state = fixture()
		guard.text_automation()
		local owner = guard.capture_text_owner()
		helpers.assert_true(owner ~= nil, "the window mode retains an output owner")
		helpers.assert_true(owner.current())
		state.policy_allows = false
		helpers.assert_eq(owner.current(), false)
		helpers.assert_eq(owner.cached(), false)
	end)

	helpers.it("(text-automation-window) a key typed in the window mode never reaches the AI prediction", function()
		-- Fed there, the prediction kept the unjoined field's empty target for
		-- the whole word, and the pause after it asked nothing (mousepad's title
		-- change on the first key, AI inline container proof, 2026-11-25).
		local source = assert(helpers.read_module_source("ergopti_hotstrings"))
		local admitted = source:find('_metrics_admitted = mode == "field"', 1, true)
		local feed = source:find("prediction_engine.on_char(ch,", 1, true)
		helpers.assert_true(admitted ~= nil and feed ~= nil, "the key path admits its mode and feeds the prediction")
		local gate = source:find("if prediction_engine and _metrics_admitted then", admitted, true)
		helpers.assert_true(gate ~= nil and gate < feed, "only the field mode feeds the prediction")
		helpers.assert_true(source:find("prediction_engine.on_char(", feed + 1, true) == nil, "no other key path feeds it")
	end)
end)
