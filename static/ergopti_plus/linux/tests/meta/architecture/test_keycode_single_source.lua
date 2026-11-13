--- tests/meta/architecture/test_keycode_single_source.lua

--- ==============================================================================
--- MODULE: Keycode Single-Source Regression Guard
--- DESCRIPTION:
--- Verifies that NEITHER keyboard_hook.lua NOR input_reader.lua contains
--- hardcoded keycode→character layout tables. The single source is
--- _shared/layouts/data/keycodes/evdev.json, loaded by input_reader.lua and exposed
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

--- The keyboard hook's source, selected by a declaration unique to it.
--- @return string
local function keyboard_hook_source()
	return assert(helpers.read_driver_unit("local function hold_owner("))
end





-- ==================================================================
-- ==================================================================
-- ======= 1/ Source-level: no hardcoded layout literals =============
-- ==================================================================
-- ==================================================================

helpers.describe("keycode single-source: keyboard_hook has no hardcoded layout tables", function()
	helpers.it("source contains no _KEYCODE_MAP variable", function()
		local src = keyboard_hook_source()
		helpers.assert_true(src:find("_KEYCODE_MAP", 1, true) == nil,
			"_KEYCODE_MAP must be removed — it was a triplicated copy of evdev.json")
	end)

	helpers.it("source contains no _build_keycode_map function", function()
		local src = keyboard_hook_source()
		helpers.assert_true(src:find("_build_keycode_map", 1, true) == nil,
			"_build_keycode_map must be removed — dead code that duplicated evdev.json")
	end)

	helpers.it("source contains no inline layout table literal", function()
		local src = keyboard_hook_source()
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
		local src = keyboard_hook_source()
		helpers.assert_true(src:find("ir.resolve_char", 1, true) ~= nil,
			"the Windows test harness needs one deterministic resolver without FFI")
	end)

	helpers.it("production capture delegates every event to live XKB state", function()
		local src = keyboard_hook_source()
		helpers.assert_true(src:find('require("adapters.xkb_capture")', 1, true) ~= nil,
			"production capture must bind the stateful XKB adapter")
		local role_at = src:find("_modifier_role(ev.code)", 1, true)
		local capture_at = src:find("_capture(ev.code, ev.value)", 1, true)
		local modifier_track_at = src:find(
			"local is_modifier = _track_modifier(source, ev.code, ev.value, role)", 1, true)
		local modifier_return_at = modifier_track_at and src:find("if is_modifier then", modifier_track_at, true)
		helpers.assert_not_nil(role_at, "the dispatch path must ask the live keymap for a modifier's role")
		helpers.assert_not_nil(capture_at, "the dispatch path must pass the exact evdev event to XKB")
		helpers.assert_not_nil(modifier_track_at, "the dispatch path must classify the modifier transition")
		helpers.assert_not_nil(modifier_return_at, "the modifier early-return must remain findable")
		helpers.assert_true(role_at < capture_at,
			"a modifier's role is read from the state its own press is about to change")
		helpers.assert_true(capture_at < modifier_track_at and modifier_track_at < modifier_return_at,
			"XKB must see modifiers, locks and releases before routing can return")
	end)

	helpers.it("capture and injection consume the same server keymap dump", function()
		-- adapters/keyboard_layout, selected by a declaration unique to it.
		local src = assert(helpers.read_driver_unit("local function copy_step("))
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
-- ======= 1b/ Behavioural: input_reader answers from evdev.json only ==
-- =====================================================================
-- =====================================================================

--- Loads a fresh input_reader over a shared-table loader double.
--- @param load function Replacement for keycodes.evdev.load.
--- @return boolean ok, any reader_or_error
local function load_reader_over(load)
	local saved = package.loaded["platform.input.keycodes.evdev"]
	package.loaded["platform.input.keycodes.evdev"] = { load = load }
	local ok, result = pcall(helpers.fresh_module, "modules.hotstrings.input_reader")
	package.loaded["platform.input.keycodes.evdev"] = saved
	return ok, result
end

helpers.describe("keycode single-source: input_reader answers from the shared tables only", function()
	helpers.it("resolves exactly what the shared tables hold, with no inline table filling gaps", function()
		-- One key per layout and shift state, deliberately unlike any real layout:
		-- an inline QWERTY or AZERTY table would answer the other keys, or this one.
		local ok, reader = load_reader_over(function()
			return {
				qwerty = { unshifted = { [30] = "\u{3A9}" }, shifted = { [30] = "\u{3C9}" } },
				azerty = { unshifted = { [16] = "\u{394}" }, shifted = { [16] = "\u{3B4}" } },
			}
		end)
		helpers.assert_true(ok, "the reader must load over readable shared tables: " .. tostring(reader))
		helpers.assert_eq(reader.resolve_char(30, "qwerty", false), "\u{3A9}")
		helpers.assert_eq(reader.resolve_char(30, "qwerty", true), "\u{3C9}")
		helpers.assert_eq(reader.resolve_char(16, "azerty", false), "\u{394}")
		helpers.assert_eq(reader.resolve_char(16, "azerty", true), "\u{3B4}")
		helpers.assert_nil(reader.resolve_char(16, "qwerty", false),
			"a key the shared QWERTY table lacks must resolve to nothing, not to a built-in 'q'")
		helpers.assert_nil(reader.resolve_char(30, "azerty", false),
			"a key the shared AZERTY table lacks must resolve to nothing, not to a built-in 'q'")
	end)

	helpers.it("refuses to load when the shared tables cannot be read (fail-fast)", function()
		local ok, failure = load_reader_over(function() return nil, "fixture: evdev.json unreadable" end)
		helpers.assert_eq(ok, false, "a missing evdev.json must stop the module, never fall back to inline tables")
		helpers.assert_true(tostring(failure):find("evdev.json", 1, true) ~= nil,
			"the failure must name the shared file: " .. tostring(failure))
	end)
end)
