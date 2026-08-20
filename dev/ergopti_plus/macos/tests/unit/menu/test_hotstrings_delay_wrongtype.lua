--- tests/unit/menu/test_hotstrings_delay_wrongtype.lua

--- ==============================================================================
--- MODULE: Regression — hotstrings delay submenu survives a wrong-typed delay
--- DESCRIPTION:
--- Audit finding F-L13. A hand-edited config.toml `[hotstrings] expansion_delay =
--- "default"` lands in state.expansion_delay as a string. The engine apply is
--- type-guarded, but make_delay_item did `math.floor(cur_val * 1000 + 0.5)` on the
--- raw value, raising "arithmetic on a string" — caught by the builder pcall, which
--- silently drops the whole Paramètres/Settings submenu. Fix: tonumber-coerce
--- cur_val, failing closed to the numeric default_val (the menu_hotstrings pattern).
--- make_delay_item is a deep local; the coercion is pinned at source + as an
--- arithmetic-safety unit on the exact expression.
---
--- PF-4: ui/menu/menu_hotstrings.lua was later split into
--- menu_hotstrings_management.lua + menu_hotstrings_custom.lua, relocating the
--- fix to menu_hotstrings_management.lua — this test's hardcoded path is
--- updated to follow it. The runtime fix itself was never lost.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("hotstrings delay item coerces a wrong-typed delay", function()
	helpers.it("source: cur_val is tonumber-coerced before the *1000 arithmetic", function()
		-- Selected by a declaration unique to ui/menu/menu_hotstrings_management.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function buildBubbleItem")
		helpers.assert_true(src ~= nil, "ui/menu/menu_hotstrings_management.lua source must be locatable")
		helpers.assert_true(src:find("tonumber(is_base and state.expansion_delay", 1, true) ~= nil,
			"cur_val must be tonumber-coerced (fail closed to default_val) before * 1000")
		helpers.assert_true(src:find("local cur_val = is_base and state.expansion_delay or", 1, true) == nil,
			"the raw (uncoerced) cur_val assignment must be gone")
	end)

	helpers.it("the coerce-then-arithmetic expression never raises on a non-number", function()
		-- Mirrors the fixed expression: tonumber(value) or default, then * 1000.
		local default_val = 0.05
		local function cur_ms(value)
			local cur_val = tonumber(value) or default_val
			return math.floor(cur_val * 1000 + 0.5)
		end
		-- Crashed pre-fix, so the pcall is the regression guard. The value matters
		-- too: a coercion that survived by answering nil would put nil into the menu
		-- row's delay, and the expansion timer would never arm.
		local ok_ms, ms = pcall(cur_ms, "default")
		helpers.assert_true(ok_ms, "a non-numeric delay must not crash the arithmetic")
		helpers.assert_eq(type(ms), "number", "and must coerce to a usable millisecond value")
		helpers.assert_eq(cur_ms("default"), 50)        -- falls back to default
		helpers.assert_eq(cur_ms(0.1), 100)             -- a real number passes through
		helpers.assert_eq(cur_ms("0.2"), 200)           -- numeric string coerced
	end)
end)
