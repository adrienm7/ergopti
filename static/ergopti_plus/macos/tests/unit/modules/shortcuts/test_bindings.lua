--- tests/unit/modules/shortcuts/test_bindings.lua

--- ==============================================================================
--- MODULE: shortcuts.bindings Unit Tests
--- DESCRIPTION:
--- Validates the declarative shortcut registry: list_shortcuts() output shape
--- and ordering, enable/disable lifecycle, and the data validation guards on
--- the public API. Actual hotkey wiring (hs.hotkey.bind side effects) is not
--- asserted — the stub returns an inert table, which is enough to exercise the
--- registry's bookkeeping logic.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

-- Stub lib.keycodes: actions/system.lua calls Keycodes.to_name(F18_WAKE_OS)
-- at module level. The real implementation iterates hs.keycodes.map, which
-- is not populated in the unit-test stub, so to_name would error. We provide
-- the two fields that system.lua actually needs.
package.loaded["lib.keycodes"] = {
	F18_WAKE_OS             = 79,
	F19_VOLUME_SCROLL_MODIFIER = 80,
	to_name = function(code)
		local MAP = { [79] = "f18", [80] = "f19" }
		return MAP[code] or ("keycode_" .. tostring(code))
	end,
}

-- Stub lib.i18n: bindings.lua calls i18n.get() at module level for
-- shortcut labels. The real module depends on locale JSON files unavailable
-- in unit tests.
package.loaded["lib.i18n"] = {
	get = function(key) return key end,
}

local Bindings = helpers.load_with_stubs("modules.shortcuts.bindings")




-- =====================================
--- =====================================
-- ======= 1/ Public API Surface =======
--- =====================================
-- =====================================

helpers.describe("shortcuts.bindings: public API", function()
	helpers.it("exposes the documented function surface", function()
		helpers.assert_eq(type(Bindings.start),          "function")
		helpers.assert_eq(type(Bindings.stop),           "function")
		helpers.assert_eq(type(Bindings.enable),         "function")
		helpers.assert_eq(type(Bindings.disable),        "function")
		helpers.assert_eq(type(Bindings.is_enabled),     "function")
		helpers.assert_eq(type(Bindings.list_shortcuts), "function")
	end)

	helpers.it("exposes a default ChatGPT URL constant", function()
		helpers.assert_eq(type(Bindings.DEFAULT_CHATGPT_URL), "string")
		helpers.assert_true(#Bindings.DEFAULT_CHATGPT_URL > 0)
	end)
end)




-- ====================================
-- ====================================
-- ======= 2/ list_shortcuts() ========
-- ====================================
-- ====================================

helpers.describe("shortcuts.bindings: list_shortcuts shape", function()
	local list = Bindings.list_shortcuts()

	helpers.it("returns an array of structured entries", function()
		helpers.assert_eq(type(list), "table")
		helpers.assert_true(#list > 0)
		for _, entry in ipairs(list) do
			helpers.assert_eq(type(entry.id),    "string")
			helpers.assert_eq(type(entry.label), "string")
			helpers.assert_true(entry.enabled == true or entry.enabled == false)
		end
	end)

	helpers.it("reports every shortcut as disabled before start()", function()
		for _, entry in ipairs(list) do
			helpers.assert_eq(entry.enabled, false, "expected disabled: " .. entry.id)
		end
	end)

	helpers.it("includes the canonical ctrl+letter shortcuts", function()
		local seen = {}
		for _, entry in ipairs(list) do seen[entry.id] = true end
		for _, id in ipairs({ "ctrl_a", "ctrl_e", "ctrl_t", "ctrl_w", "ctrl_u" }) do
			helpers.assert_true(seen[id], "missing shortcut: " .. id)
		end
	end)

	helpers.it("includes the cmd_star and cmd_shift_v shortcuts", function()
		local seen = {}
		for _, entry in ipairs(list) do seen[entry.id] = true end
		helpers.assert_true(seen.cmd_star)
		helpers.assert_true(seen.cmd_shift_v)
	end)

	helpers.it("includes the standalone at_hash and layer_scroll entries", function()
		local seen = {}
		for _, entry in ipairs(list) do seen[entry.id] = true end
		helpers.assert_true(seen.at_hash)
		helpers.assert_true(seen.layer_scroll)
	end)

	helpers.it("orders ctrl+letter entries before ctrl+punctuation", function()
		-- Group rule: ctrl_<single letter> comes before ctrl_<word> (period/quote).
		local idx = {}
		for i, entry in ipairs(list) do idx[entry.id] = i end
		helpers.assert_true(idx.ctrl_a < idx.ctrl_period)
		helpers.assert_true(idx.ctrl_w < idx.ctrl_quote)
	end)

	helpers.it("orders ctrl_* entries before cmd_* entries", function()
		local idx = {}
		for i, entry in ipairs(list) do idx[entry.id] = i end
		helpers.assert_true(idx.ctrl_a       < idx.cmd_shift_v)
		helpers.assert_true(idx.ctrl_period  < idx.cmd_star)
	end)

	helpers.it("orders cmd_* entries before the catch-all bucket", function()
		local idx = {}
		for i, entry in ipairs(list) do idx[entry.id] = i end
		helpers.assert_true(idx.cmd_star < idx.at_hash)
		helpers.assert_true(idx.cmd_star < idx.layer_scroll)
	end)
end)




-- =================================
--- =================================
-- ======= 3/ enable/disable =======
--- =================================
-- =================================

helpers.describe("shortcuts.bindings: enable/disable", function()
	-- Reload the module so the per-test bookkeeping starts fresh.
	local B = helpers.load_with_stubs("modules.shortcuts.bindings")

	helpers.it("is_enabled is false before enable()", function()
		helpers.assert_eq(B.is_enabled("ctrl_a"), false)
	end)

	helpers.it("enable() flips is_enabled to true", function()
		B.enable("ctrl_a")
		helpers.assert_eq(B.is_enabled("ctrl_a"), true)
	end)

	helpers.it("enable() is idempotent — re-enabling does not crash", function()
		B.enable("ctrl_a")
		B.enable("ctrl_a")
		helpers.assert_eq(B.is_enabled("ctrl_a"), true)
	end)

	helpers.it("disable() flips is_enabled back to false", function()
		B.disable("ctrl_a")
		helpers.assert_eq(B.is_enabled("ctrl_a"), false)
	end)

	helpers.it("disable() is idempotent — disabling an inactive id does nothing", function()
		B.disable("ctrl_a")
		helpers.assert_eq(B.is_enabled("ctrl_a"), false)
	end)
end)




-- ========================================
-- ========================================
-- ======= 4/ Argument Validation =========
-- ========================================
-- ========================================

helpers.describe("shortcuts.bindings: argument validation", function()
	local B = helpers.load_with_stubs("modules.shortcuts.bindings")

	helpers.it("enable() rejects a non-string name without crashing", function()
		B.enable(nil)
		B.enable(42)
		B.enable({})
	end)

	helpers.it("enable() logs an error for an unknown shortcut id", function()
		-- Should be a no-op (no registered factory) — but must not raise.
		B.enable("totally_not_a_real_shortcut")
		helpers.assert_eq(B.is_enabled("totally_not_a_real_shortcut"), false)
	end)

	helpers.it("disable() rejects a non-string name without crashing", function()
		B.disable(nil)
		B.disable(42)
		B.disable({})
	end)

	helpers.it("is_enabled() returns false for unknown ids", function()
		helpers.assert_eq(B.is_enabled("totally_not_a_real_shortcut"), false)
	end)
end)




-- =================================
-- =================================
-- ======= 5/ start/stop ===========
-- =================================
-- =================================

helpers.describe("shortcuts.bindings: start/stop lifecycle", function()
	local B = helpers.load_with_stubs("modules.shortcuts.bindings")

	helpers.it("start() activates every defined shortcut", function()
		B.start()
		local list = B.list_shortcuts()
		for _, entry in ipairs(list) do
			helpers.assert_eq(entry.enabled, true, "expected enabled after start: " .. entry.id)
		end
	end)

	helpers.it("start() called twice is a safe no-op", function()
		-- Already started above — second call must not crash or duplicate.
		B.start()
		local list = B.list_shortcuts()
		helpers.assert_true(#list > 0)
	end)

	helpers.it("stop() flips every shortcut back to disabled", function()
		B.stop()
		local list = B.list_shortcuts()
		for _, entry in ipairs(list) do
			helpers.assert_eq(entry.enabled, false, "expected disabled after stop: " .. entry.id)
		end
	end)

	helpers.it("stop() called when not started is a safe no-op", function()
		B.stop()
	end)
end)
