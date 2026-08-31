--- tests/unit/meta/test_keycode_single_source.lua

--- ==============================================================================
--- MODULE: Keycode Single-Source Regression Guard
--- DESCRIPTION:
--- Verifies that NEITHER keyboard_hook.lua NOR input_reader.lua contains
--- hardcoded keycode→character layout tables. The single source is
--- _shared/data/keycodes/evdev.json, loaded by input_reader.lua and exposed
--- via M.resolve_char(). keyboard_hook must delegate to it; input_reader must
--- NOT fall back to inline tables on load failure.
---
--- ROOT CAUSE ENCODED:
--- keyboard_hook.lua had three copies of the keycode layout data: (1) a dead
--- _KEYCODE_MAP built by _build_keycode_map, (2) a full hardcoded layout table
--- inside _resolve_char (~70 entries × 2 layouts), and (3) the live copy in
--- input_reader.lua (loaded from evdev.json). Additionally, input_reader itself
--- held a fourth copy as a "fallback" for when evdev.json failed to load —
--- violating the fail-fast rule and silently masking a missing shared file.
--- Any layout change required editing all copies; they had already diverged.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================================
-- ==================================================================
-- ======= 1/ Source-level: no hardcoded layout literals =============
-- ==================================================================
-- ==================================================================

helpers.describe("keycode single-source: keyboard_hook has no hardcoded layout tables", function()
	helpers.it("source contains no _KEYCODE_MAP variable", function()
		local fh = io.open(helpers.driver_root() .. "/adapters/keyboard_hook.lua", "r")
		helpers.assert_true(fh ~= nil, "should open keyboard_hook.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("_KEYCODE_MAP", 1, true) == nil,
			"_KEYCODE_MAP must be removed — it was a triplicated copy of evdev.json")
	end)

	helpers.it("source contains no _build_keycode_map function", function()
		local fh = io.open(helpers.driver_root() .. "/adapters/keyboard_hook.lua", "r")
		helpers.assert_true(fh ~= nil, "should open keyboard_hook.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("_build_keycode_map", 1, true) == nil,
			"_build_keycode_map must be removed — dead code that duplicated evdev.json")
	end)

	helpers.it("source contains no inline layout table literal", function()
		local fh = io.open(helpers.driver_root() .. "/adapters/keyboard_hook.lua", "r")
		helpers.assert_true(fh ~= nil, "should open keyboard_hook.lua")
		local src = fh:read("*a")
		fh:close()
		-- The old code had numeric-keyed table entries with string char values
		-- that only a hardcoded layout map would produce
		helpers.assert_true(src:find('[30]="a"', 1, true) == nil,
			"hardcoded layout entry [30]=\"a\" must be removed — use input_reader.resolve_char")
		helpers.assert_true(src:find('[16]="q"', 1, true) == nil,
			"hardcoded layout entry [16]=\"q\" must be removed — use input_reader.resolve_char")
		helpers.assert_true(src:find('[3]="2"', 1, true) == nil,
			"hardcoded layout entry [3]=\"2\" must be removed — use input_reader.resolve_char")
	end)

	helpers.it("the pure-Lua hook harness delegates to input_reader.resolve_char", function()
		local fh = io.open(helpers.driver_root() .. "/adapters/keyboard_hook.lua", "r")
		helpers.assert_true(fh ~= nil, "should open keyboard_hook.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("ir.resolve_char", 1, true) ~= nil,
			"the Windows test harness needs one deterministic resolver without FFI")
	end)

	helpers.it("production capture delegates every event to live XKB state", function()
		local fh = assert(io.open(helpers.driver_root() .. "/adapters/keyboard_hook.lua", "r"))
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find('require("adapters.xkb_capture")', 1, true) ~= nil,
			"production capture must bind the stateful XKB adapter")
		local capture_at = src:find("_capture(ev.code, ev.value)", 1, true)
		local modifier_return_at = src:find(
			"if _track_modifier(ev.code, ev.value) then return end", 1, true)
		helpers.assert_not_nil(capture_at, "the dispatch path must pass the exact evdev event to XKB")
		helpers.assert_not_nil(modifier_return_at, "the modifier early-return must remain findable")
		helpers.assert_true(capture_at < modifier_return_at,
			"XKB must see modifiers, locks and releases before routing can return")
	end)

	helpers.it("capture and injection consume the same server keymap dump", function()
		local fh = assert(io.open(helpers.driver_root() .. "/adapters/keyboard_layout.lua", "r"))
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("XkbCapture.load(text)", 1, true) ~= nil,
			"one dumped keymap must initialise capture before building the inverse injection table")
	end)
end)





-- ==================================================================
-- ==================================================================
-- ======= 2/ Behavioural: resolve_char matches evdev.json ==========
-- ==================================================================
-- ==================================================================





-- =====================================================================
-- =====================================================================
-- ======= 1b/ Source-level: input_reader has no fallback tables =======
-- =====================================================================
-- =====================================================================

helpers.describe("keycode single-source: input_reader has no hardcoded layout tables", function()
	helpers.it("source contains no QWERTY_UNSHIFTED variable", function()
		local fh = io.open(helpers.driver_root() .. "/modules/hotstrings/input_reader.lua", "r")
		helpers.assert_true(fh ~= nil, "should open input_reader.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("local QWERTY_UNSHIFTED", 1, true) == nil,
			"QWERTY_UNSHIFTED must be removed — it was a hardcoded fallback duplicating evdev.json")
	end)

	helpers.it("source contains no QWERTY_SHIFTED variable", function()
		local fh = io.open(helpers.driver_root() .. "/modules/hotstrings/input_reader.lua", "r")
		helpers.assert_true(fh ~= nil, "should open input_reader.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("local QWERTY_SHIFTED", 1, true) == nil,
			"QWERTY_SHIFTED must be removed — it was a hardcoded fallback duplicating evdev.json")
	end)

	helpers.it("source contains no AZERTY_UNSHIFTED variable", function()
		local fh = io.open(helpers.driver_root() .. "/modules/hotstrings/input_reader.lua", "r")
		helpers.assert_true(fh ~= nil, "should open input_reader.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("local AZERTY_UNSHIFTED", 1, true) == nil,
			"AZERTY_UNSHIFTED must be removed — it was a hardcoded fallback duplicating evdev.json")
	end)

	helpers.it("source contains no AZERTY_SHIFTED variable", function()
		local fh = io.open(helpers.driver_root() .. "/modules/hotstrings/input_reader.lua", "r")
		helpers.assert_true(fh ~= nil, "should open input_reader.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("local AZERTY_SHIFTED", 1, true) == nil,
			"AZERTY_SHIFTED must be removed — it was a hardcoded fallback duplicating evdev.json")
	end)

	helpers.it("source asserts LAYOUTS is not nil (fail-fast guard)", function()
		local fh = io.open(helpers.driver_root() .. "/modules/hotstrings/input_reader.lua", "r")
		helpers.assert_true(fh ~= nil, "should open input_reader.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("assert(LAYOUTS", 1, true) ~= nil,
			"input_reader must assert(LAYOUTS ~= nil) — fail-fast, no silent fallback")
	end)
end)





helpers.describe("keycode single-source: keyboard_hook resolves characters via input_reader (evdev.json)", function()
	helpers.it("KEY_A (code 30) resolves to 'a' in qwerty", function()
		local ir = helpers.load_module("modules.hotstrings.input_reader")
		helpers.assert_eq(ir.resolve_char(30, "qwerty", false), "a",
			"code 30 = 'a' in qwerty unshifted")
	end)

	helpers.it("KEY_A (code 30) resolves to 'A' in qwerty shifted", function()
		local ir = helpers.load_module("modules.hotstrings.input_reader")
		helpers.assert_eq(ir.resolve_char(30, "qwerty", true), "A",
			"code 30 = 'A' in qwerty shifted")
	end)

	helpers.it("KEY_A (code 30) resolves to 'q' in azerty (layout difference)", function()
		local ir = helpers.load_module("modules.hotstrings.input_reader")
		helpers.assert_eq(ir.resolve_char(30, "azerty", false), "q",
			"code 30 = 'q' in azerty unshifted — proves the evdev.json source is used, not a qwerty copy")
	end)

	helpers.it("non-printable keycode returns nil", function()
		local ir = helpers.load_module("modules.hotstrings.input_reader")
		helpers.assert_true(ir.resolve_char(999, "qwerty", false) == nil,
			"code 999 should return nil (non-printable)")
	end)

	helpers.it("get_layouts returns the loaded LAYOUTS table", function()
		local ir = helpers.load_module("modules.hotstrings.input_reader")
		local layouts = ir.get_layouts()
		helpers.assert_true(type(layouts) == "table", "get_layouts returns a table")
		helpers.assert_true(type(layouts.qwerty) == "table", "has qwerty layout")
		helpers.assert_true(type(layouts.azerty) == "table", "has azerty layout")
		helpers.assert_true(type(layouts.qwerty.unshifted) == "table", "qwerty has unshifted")
		helpers.assert_true(type(layouts.qwerty.shifted) == "table", "qwerty has shifted")
	end)
end)





-- =====================================================================
-- =====================================================================
-- ======= 3/ Integration: keyboard_hook pump uses shared source =======
-- =====================================================================
-- =====================================================================

helpers.describe("keycode single-source: keyboard_hook pump resolves via shared evdev.json", function()
	helpers.it("qwerty layout: KEY_Q (code 16) resolves to 'q' through the pump", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		-- code 16 = KEY_Q in evdev; in qwerty this maps to 'q'.
		local received = {}
		kh._test_drive({ { type = 1, code = 16, value = 1 } }, {
			onChar    = function(ch) received[#received + 1] = ch end,
			onEmitRaw = function() return true end,
		}, true)
		helpers.assert_true(#received == 1, "on_char called once")
		helpers.assert_eq(received[1], "q", "code 16 = 'q' in qwerty (default layout)")
	end)

	helpers.it("qwerty shifted: KEY_A (code 30) with shift resolves to 'A' through the pump", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local received = {}
		kh._test_drive({
			{ type = 1, code = 42, value = 1 },   -- Shift down
			{ type = 1, code = 30, value = 1 },   -- A down
		}, {
			onChar    = function(ch) received[#received + 1] = ch end,
			onEmitRaw = function() return true end,
		}, true)
		helpers.assert_true(#received >= 1, "on_char called at least once")
		helpers.assert_eq(received[#received], "A", "code 30 with shift = 'A' in qwerty shifted")
	end)
end)
