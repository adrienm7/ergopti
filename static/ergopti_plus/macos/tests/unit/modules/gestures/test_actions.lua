--- tests/unit/modules/gestures/test_actions.lua

--- ==============================================================================
--- MODULE: gestures.actions Unit Tests
--- DESCRIPTION:
--- Validates the action registry data structures: AX_NAMES / SG_NAMES coverage,
--- get_label() lookup, and execute_axis / execute_single dispatch contract.
---
--- These tests focus on the lookup-table validation requested in the test sprint:
--- which gesture id maps to which callable action. The actual OS side-effects
--- (keyStroke posting, AppleScript dispatch) are not asserted — that requires a
--- live macOS host and is intentionally out of scope.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local Actions = helpers.load_with_stubs("modules.gestures.actions")





-- =====================================
-- =====================================
-- ======= 1/ Public API Surface =======
-- =====================================
-- =====================================

helpers.describe("gestures.actions: public API", function()
	helpers.it("exposes AX_NAMES as a non-empty list", function()
		helpers.assert_eq(type(Actions.AX_NAMES), "table")
		helpers.assert_true(#Actions.AX_NAMES > 0)
	end)

	helpers.it("exposes SG_NAMES as a non-empty list", function()
		helpers.assert_eq(type(Actions.SG_NAMES), "table")
		helpers.assert_true(#Actions.SG_NAMES > 0)
	end)

	helpers.it("exposes the documented function surface", function()
		helpers.assert_eq(type(Actions.get_label),            "function")
		helpers.assert_eq(type(Actions.execute_single),       "function")
		helpers.assert_eq(type(Actions.execute_axis),         "function")
		helpers.assert_eq(type(Actions.is_scalable),          "function")
		helpers.assert_eq(type(Actions.is_right_click_held),  "function")
		helpers.assert_eq(type(Actions.toggle_right_click),   "function")
		helpers.assert_eq(type(Actions.force_cleanup),        "function")
		helpers.assert_eq(type(Actions.trigger_lookup),       "function")
		helpers.assert_eq(type(Actions.get_action_parameter_spec), "function")
		helpers.assert_eq(type(Actions.validate_action_parameter), "function")
		helpers.assert_eq(type(Actions.get_action_parameter), "function")
		helpers.assert_eq(type(Actions.set_action_parameter), "function")
		helpers.assert_eq(type(Actions.split_action_parameter_key), "function")
	end)
end)

helpers.describe("gestures.actions: parameterized action bindings", function()
	helpers.it("keeps URL and search templates isolated by binding", function()
		Actions.init({ action_params = {} })
		helpers.assert_eq(Actions.get_action_parameter_spec("open_url"), "url")
		helpers.assert_eq(Actions.get_action_parameter_spec("search_web"), "search_url")
		helpers.assert_true(Actions.set_action_parameter("tap_3", "open_url", "https://one.example"))
		helpers.assert_true(Actions.set_action_parameter("swipe_3_left", "open_url", "https://two.example"))
		helpers.assert_eq(Actions.get_action_parameter("tap_3", "open_url"), "https://one.example")
		helpers.assert_eq(Actions.get_action_parameter("swipe_3_left", "open_url"), "https://two.example")
		helpers.assert_true(Actions.validate_action_parameter("search_web", "https://search.example/?q=%s"))
		helpers.assert_eq(Actions.validate_action_parameter("search_web", "https://search.example/?q=%s&again=%s"), false)
		helpers.assert_eq(Actions.validate_action_parameter("open_url", "not-a-url"), false)
		local binding, action = Actions.split_action_parameter_key("keyboard__cmd_k__search_web")
		helpers.assert_eq(binding, "keyboard__cmd_k", "scoped bindings must not be split at their first separator")
		helpers.assert_eq(action, "search_web")
	end)
end)





-- =================================
-- =================================
-- ======= 2/ AX_NAMES Shape =======
-- =================================
-- =================================

helpers.describe("gestures.actions: AX_NAMES contents", function()
	local function contains(t, v)
		for _, x in ipairs(t) do if x == v then return true end end
		return false
	end

	helpers.it("includes the canonical axis ids", function()
		for _, id in ipairs({
			"none", "tabs", "windows", "spaces",
			"volume", "brightness", "tracks",
			"words", "lines", "line_bounds", "paragraphs", "document",
		}) do
			helpers.assert_true(contains(Actions.AX_NAMES, id), "missing AX id: " .. id)
		end
	end)

	helpers.it("starts with 'none' as the disabled-axis sentinel", function()
		helpers.assert_eq(Actions.AX_NAMES[1], "none")
	end)
end)





-- =================================
-- =================================
-- ======= 3/ SG_NAMES Shape =======
-- =================================
-- =================================

helpers.describe("gestures.actions: SG_NAMES contents", function()
	local function contains(t, v)
		for _, x in ipairs(t) do if x == v then return true end end
		return false
	end

	helpers.it("includes the navigation single-action ids", function()
		for _, id in ipairs({
			"right_click_toggle", "lookup",
			"tab_new", "tab_close", "tab_prev", "tab_next",
			"win_prev", "win_next", "space_prev", "space_next",
			"mission_control", "app_expose",
		}) do
			helpers.assert_true(contains(Actions.SG_NAMES, id), "missing SG id: " .. id)
		end
	end)

	helpers.it("includes the media single-action ids", function()
		for _, id in ipairs({
			"vol_up", "vol_down", "brightness_up", "brightness_down", "mute",
			"track_play", "track_next", "track_prev",
		}) do
			helpers.assert_true(contains(Actions.SG_NAMES, id), "missing media SG id: " .. id)
		end
	end)
end)




-- ===============================
-- ===============================
-- ======= 4/ get_label() ========
-- ===============================
-- ===============================

helpers.describe("gestures.actions: get_label", function()
	helpers.it("returns a non-empty string for an axis id", function()
		helpers.assert_true(type(Actions.get_label("tabs"))    == "string" and Actions.get_label("tabs")    ~= "")
		helpers.assert_true(type(Actions.get_label("volume"))  == "string" and Actions.get_label("volume")  ~= "")
		helpers.assert_true(type(Actions.get_label("windows")) == "string" and Actions.get_label("windows") ~= "")
	end)

	helpers.it("returns a non-empty string for a single id", function()
		helpers.assert_true(type(Actions.get_label("mute"))       == "string" and Actions.get_label("mute")       ~= "")
		helpers.assert_true(type(Actions.get_label("track_play")) == "string" and Actions.get_label("track_play") ~= "")
		helpers.assert_true(type(Actions.get_label("lookup"))     == "string" and Actions.get_label("lookup")     ~= "")
	end)

	helpers.it("returns the 'none' label for nil and 'none'", function()
		local none_label = Actions.get_label("none")
		helpers.assert_true(type(none_label) == "string" and none_label ~= "")
		helpers.assert_eq(Actions.get_label(nil), none_label)
	end)

	helpers.it("falls back to the id when unknown", function()
		helpers.assert_eq(Actions.get_label("totally_not_a_real_id"), "totally_not_a_real_id")
	end)

	helpers.it("renders shared modifier chords with language-neutral labels", function()
		helpers.assert_eq(Actions.get_label("ctrl_a"), "Ctrl + A")
		helpers.assert_eq(Actions.get_label("cmd_option_shift_enter"), "Cmd + Option + Shift + Enter")
	end)

	helpers.it("includes every modifier chord in the gesture picker", function()
		local function contains(items, needle)
			for _, item in ipairs(items) do
				if item == needle then return true end
			end
			return false
		end
		helpers.assert_true(contains(Actions.SG_NAMES, "ctrl_a"))
		helpers.assert_true(contains(Actions.SG_NAMES, "cmd_ctrl_option_shift_z"))
		helpers.assert_true(contains(Actions.SG_NAMES, "#Raccourcis"))
		helpers.assert_true(contains(Actions.SG_NAMES, "##Raccourcis Ctrl"))
		helpers.assert_true(contains(Actions.SG_NAMES, "##Raccourcis Cmd + Ctrl + Option + Shift"))
	end)
end)




-- =================================
-- =================================
-- ======= 5/ is_scalable() ========
-- =================================
-- =================================

helpers.describe("gestures.actions: is_scalable", function()
	helpers.it("flags volume / brightness / words / lines / paragraphs as scalable", function()
		helpers.assert_eq(Actions.is_scalable("volume"),     true)
		helpers.assert_eq(Actions.is_scalable("brightness"), true)
		helpers.assert_eq(Actions.is_scalable("words"),      true)
		helpers.assert_eq(Actions.is_scalable("lines"),      true)
		helpers.assert_eq(Actions.is_scalable("paragraphs"), true)
	end)

	helpers.it("does NOT flag tracks / spaces / document / line_bounds as scalable", function()
		-- These axes must trigger exactly once per crossing — scaling them would
		-- dispatch the wrapped keyStroke multiple times and cause runaway navigation.
		helpers.assert_true(not Actions.is_scalable("tracks"))
		helpers.assert_true(not Actions.is_scalable("spaces"))
		helpers.assert_true(not Actions.is_scalable("document"))
		helpers.assert_true(not Actions.is_scalable("line_bounds"))
	end)

	helpers.it("returns falsy for unknown ids", function()
		helpers.assert_true(not Actions.is_scalable("totally_not_real"))
		helpers.assert_true(not Actions.is_scalable("none"))
	end)
end)




-- =================================
-- =================================
-- ======= 6/ Execute Calls ========
-- =================================
-- =================================

helpers.describe("gestures.actions: execute helpers do not crash", function()
	helpers.it("execute_single is a no-op for unknown ids", function()
		-- Must not raise — bad gesture ids reach this code path on user misconfiguration.
		Actions.execute_single("totally_not_real")
	end)

	helpers.it("execute_axis is a no-op for unknown ids", function()
		Actions.execute_axis("totally_not_real", true)
		Actions.execute_axis("totally_not_real", false)
	end)

	helpers.it("execute_single('none') runs the empty action without error", function()
		helpers.assert_eq(Actions.execute_single("none"), true,
			"a registered successful action must report handled to its caller")
	end)

	helpers.it("is_right_click_held returns a boolean", function()
		local v = Actions.is_right_click_held()
		helpers.assert_true(v == true or v == false)
	end)

	-- Dispatch is name-keyed: an action that is not registered must be REFUSED,
	-- not guessed at. This is what makes a paused or partially-initialised driver
	-- silent — a lookup miss returns false instead of reaching the OS. Asserting
	-- the refusal is the only way to know the gate is a gate.
	helpers.it("execute_single refuses an unregistered action instead of dispatching", function()
		helpers.assert_eq(Actions.execute_single("no_such_action_at_all"), false,
			"an unknown action name must be refused, not dispatched")
		helpers.assert_eq(Actions.execute_single(nil), false,
			"a nil action name must be refused too")
	end)

	helpers.it("execute_axis on an unknown axis fires nothing", function()
		-- No return value to check: the assertion is that it completes without
		-- reaching an axis function, which a missing guard would turn into an
		-- index-a-nil error rather than a silent no-op.
		Actions.execute_axis("no_such_axis", true)
		Actions.execute_axis("no_such_axis", false)
		helpers.assert_eq(type(Actions.execute_axis), "function",
			"execute_axis survived two unknown-axis dispatches")
	end)

	-- force_cleanup releases held synthetic clicks. It has to be idempotent:
	-- it runs on quit, on suspend, and on every tap that is not a click toggle,
	-- so a second call must not post a second mouse-up into whatever the user is
	-- doing.
	helpers.it("force_cleanup is idempotent", function()
		Actions.force_cleanup()
		Actions.force_cleanup()
		helpers.assert_eq(Actions.is_right_click_held(), false,
			"after cleanup no synthetic right-click may remain held")
	end)
end)





-- ===============================================================
-- ===============================================================
-- ======= 7/ Throwing actions are traced via Logger.callback ====
-- ===============================================================
-- ===============================================================

-- Regression: execute_single/execute_axis dispatched every registered action (~150+ closures)
-- via a bare pcall(s.fn) with the (ok, err) tuple discarded — a thrown exception left NO trace
-- anywhere and execute_single still reported true. The contextual boundary must
-- log the traceback and return false to its caller.
helpers.describe("gestures.actions: throwing actions are traced via Logger.callback (HS-016)", function()

	-- Loads a fresh actions module with a REAL (not stubbed) lib.logger instance so the
	-- ring buffer genuinely reflects what Logger.pcall wrote, plus hs.timer.doAfter
	-- replaced with a function that raises — driving an actual thrown exception through
	-- the real action registry rather than a synthetic stub action.
	local function make_actions_with_real_logger_and_throwing_timer()
		package.loaded["infra.logger"] = nil
		local FreshLogger = helpers.load_with_stubs("infra.logger")
		FreshLogger.set_level("DEBUG")

		package.loaded["modules.gestures.actions"] = nil
		package.loaded["modules.gestures.actions_click"] = nil
		local Actions2 = helpers.load_with_stubs("modules.gestures.actions", {
			timer = {
				doAfter = function() error("boom: injected hs.timer.doAfter failure") end,
			},
		})
		return Actions2, FreshLogger
	end

	helpers.it("execute_single logs an ERROR when the dispatched action throws ('lookup' via hs.timer.doAfter)", function()
		local Actions2, FreshLogger = make_actions_with_real_logger_and_throwing_timer()

		-- 'lookup' -> M.trigger_lookup() calls hs.timer.doAfter(...) UNPROTECTED
		-- (no internal pcall), so stubbing it to error() reaches Logger.callback's guard.
		-- The containment IS the subject, so the pcall stays. What it was missing is
		-- that the exception was CONTAINED rather than swallowed: Logger.callback is
		-- meant to log it, and a guard that silently discarded every failure would
		-- leave a dead gesture with nothing in the logs to explain it.
		local ok, result = pcall(Actions2.execute_single, "lookup")
		helpers.assert_true(ok, "execute_single itself must never raise — Logger.callback must contain the exception")
		helpers.assert_eq(result, false,
			"a contained exception must be returned as an explicit dispatch refusal")

		local snap = FreshLogger.ring_buffer_snapshot()
		local found_error = false
		for _, line in ipairs(snap) do
			if line:find("[ERROR]", 1, true)
				and line:find("Gesture action 'lookup'", 1, true)
				and line:find("boom: injected", 1, true)
				and line:find("stack traceback", 1, true) then
				found_error = true
			end
		end
		helpers.assert_true(found_error,
			"a throwing action must leave an ERROR-level Logger trace (gestures-actions-silent-pcall)")
	end)

	helpers.it("execute_axis logs an ERROR when the dispatched axis action throws ('lines' via hs.timer.doAfter)", function()
		local Actions2, FreshLogger = make_actions_with_real_logger_and_throwing_timer()

		-- 'lines' next/prev call hs.timer.doAfter(...) UNPROTECTED directly.
		local ok, result = pcall(Actions2.execute_axis, "lines", true)
		helpers.assert_true(ok, "execute_axis itself must never raise — Logger.callback must contain the exception")
		helpers.assert_eq(result, false,
			"a throwing axis action must return an explicit dispatch refusal")

		local snap = FreshLogger.ring_buffer_snapshot()
		local found_error = false
		for _, line in ipairs(snap) do
			if line:find("[ERROR]", 1, true)
				and line:find("Gesture axis action 'lines'", 1, true)
				and line:find("boom: injected", 1, true)
				and line:find("stack traceback", 1, true) then
				found_error = true
			end
		end
		helpers.assert_true(found_error,
			"a throwing axis action must leave an ERROR-level Logger trace (gestures-actions-silent-pcall)")
	end)

	helpers.it("logs a native false from the shared keystroke helper", function()
		local Actions2, FreshLogger = make_actions_with_real_logger_and_throwing_timer()
		local SyntheticInput = require("adapters.synthetic_input")
		local original_emit = SyntheticInput.emit_key_stroke
		SyntheticInput.emit_key_stroke = function() return false end

		local dispatched = Actions2.execute_single("mission_control")
		SyntheticInput.emit_key_stroke = original_emit

		helpers.assert_eq(dispatched, true,
			"the registered action remains owned by the gesture dispatcher")
		local found_refusal = false
		for _, line in ipairs(FreshLogger.ring_buffer_snapshot()) do
			if line:find("[ERROR]", 1, true)
				and line:find("synthetic key stroke was refused", 1, true) then
				found_refusal = true
			end
		end
		helpers.assert_true(found_refusal,
			"a false native dispatch must reach the file logger through a real registered action")
	end)
end)




-- ==================================================
-- ==================================================
-- ======= 5/ Parameterized Actions Execute =========
-- ==================================================
-- ==================================================

--- The blocks above assert SG_NAMES membership and parameter STORAGE. Neither
--- observes an action running, so an entry registered with a broken handler — or
--- one whose parameter never reaches its handler — passes every one of them while
--- doing nothing when the user triggers it. That silent no-op is precisely what
--- made a script-control binding to "Ouvrir un lien" inert: the action was
--- present, the label was right, and pressing the key did nothing.
---
--- Drives execute_single and asserts the observable side effect, mirroring
--- test_actions_modifier_keystrokes.lua, which exists for the same reason.
helpers.describe("gestures.actions: a parameterized action honours its binding", function()
	--- Loads a FRESH actions module with its own state. M.init() warns and returns
	--- early on a second call, so by the time a full-suite run reaches this block
	--- the module is already initialised by an earlier file and init() here is a
	--- no-op operating on that file's state. Reloading makes these cases
	--- order-independent: they passed alone and failed in-suite without it.
	--- @return table A freshly required actions module, initialised and empty.
	local function fresh_actions()
		package.loaded["modules.gestures.actions"] = nil
		local A = helpers.load_with_stubs("modules.gestures.actions")
		A.init({ action_params = {} })
		return A
	end

	helpers.it("opens the URL stored for the binding that triggered it", function()
		_G.hs.urlevent.__reset()
		local Actions = fresh_actions()
		helpers.assert_true(Actions.set_action_parameter("tap_3", "open_url", "https://one.example"))

		Actions.execute_single("open_url", "tap_3")

		helpers.assert_eq(#_G.hs.urlevent.__opened, 1,
			"the action must open exactly one URL — zero means the parameter never reached "
			.. "the handler and the binding is inert despite looking configured")
		helpers.assert_eq(_G.hs.urlevent.__opened[1], "https://one.example",
			"it must open the URL stored for THIS binding, not another binding's")
	end)

	helpers.it("opens nothing when the binding has no parameter", function()
		_G.hs.urlevent.__reset()
		local Actions = fresh_actions()

		Actions.execute_single("open_url", "tap_4")

		helpers.assert_eq(#_G.hs.urlevent.__opened, 0,
			"with no parameter stored the handler must open nothing rather than a malformed "
			.. "URL. This is the state a menu must never leave a binding in — which is why "
			.. "the pickers prompt for the value before assigning the action")
	end)

	helpers.it("keeps two bindings of the same action independent", function()
		_G.hs.urlevent.__reset()
		local Actions = fresh_actions()
		Actions.set_action_parameter("tap_3", "open_url", "https://one.example")
		Actions.set_action_parameter("swipe_3_left", "open_url", "https://two.example")

		Actions.execute_single("open_url", "swipe_3_left")

		helpers.assert_eq(_G.hs.urlevent.__opened[1], "https://two.example",
			"each binding carries its own URL; resolving the wrong one would send the user "
			.. "to a link they configured somewhere else entirely")
	end)
end)
