--- tests/unit/adapters/test_keyboard_hook_xkb_capture.lua

--- ==============================================================================
--- MODULE: Keyboard Hook to XKB Capture Integration Tests
--- DESCRIPTION:
--- Pins the join between raw evdev routing and the stateful XKB adapter. The XKB
--- unit tests prove state semantics; these cases prove keyboard_hook does not
--- bypass that state for modifiers, locks, releases, repeats or shortcuts.
---
--- ROOT CAUSE ENCODED:
--- The old hook returned early for modifiers and CapsLock, discarded releases,
--- and resolved printable keys through a static table. Even a correct XKB
--- adapter would therefore drift immediately if the hook forwarded only the
--- events that happened to produce text.
--- ==============================================================================

local helpers = require("tests.helpers")

local function key(code, value)
	return { type = 1, code = code, value = value }
end





-- =========================================
-- =========================================
-- ======= 1/ Complete event stream =========
-- =========================================
-- =========================================

helpers.describe("keyboard_hook: live XKB capture stream", function()
	helpers.it("refuses to open a keyboard before live XKB state is ready", function()
		local module_name = "adapters.xkb_capture"
		local saved = package.loaded[module_name]
		package.loaded[module_name] = {
			is_ready = function() return false end,
			reset_state = function() error("must not reset an absent state") end,
			process = function() error("must not process without state") end,
		}
		local hook = helpers.load_module("adapters.keyboard_hook")
		package.loaded[module_name] = saved

		hook.start({ intercept = false })
		helpers.assert_true(not hook.isRunning(),
			"a guessed static layout must never become a valid-looking capture path")
	end)

	helpers.it("forwards every key transition to live XKB before routing", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local seen = {}
		local chars = {}
		local events = {
			key(42, 1),  -- Shift down
			key(30, 1),  -- printable down
			key(30, 2),  -- printable repeat
			key(30, 0),  -- printable release
			key(58, 1),  -- CapsLock down
			key(58, 0),  -- CapsLock release
			key(42, 0),  -- Shift release
		}

		hook._test_drive(events, {
			captureEvent = function(code, value)
				seen[#seen + 1] = { code, value }
				if code == 30 and value ~= 0 then return "q", "q" end
				return nil, nil, nil
			end,
			onChar = function(char) chars[#chars + 1] = char end,
			onEmitRaw = function() end,
		}, true)

		helpers.assert_eq(seen, {
			{ 42, 1 }, { 30, 1 }, { 30, 2 }, { 30, 0 },
			{ 58, 1 }, { 58, 0 }, { 42, 0 },
		}, "modifiers, locks and releases must reach XKB instead of an early return")
		helpers.assert_eq(chars, { "q", "q" }, "only press and repeat become text")
	end)

	helpers.it("keeps the second Shift held after the first Shift is released", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		hook._test_drive({
			key(42, 1),
			key(54, 1),
			key(42, 0),
		}, {
			captureEvent = function() return nil, nil, nil end,
			onEmitRaw = function() end,
		}, true)

		helpers.assert_eq(hook.held_text_modifiers(), { "shift" },
			"one boolean cannot represent two physical Shift keys")
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ Shortcut identity =============
-- =========================================
-- =========================================

helpers.describe("keyboard_hook: XKB shortcut identity", function()
	helpers.it("uses the keysym identity instead of Ctrl-transformed UTF-8", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local shortcut = nil
		hook._test_drive({
			key(29, 1), -- Ctrl down
			key(31, 1), -- S down
		}, {
			captureEvent = function(code)
				if code == 31 then return string.char(19), "s", nil end
				return nil, nil, nil
			end,
			onKey = function(name, payload)
				if name == "shortcut" then shortcut = payload end
			end,
			onEmitRaw = function() end,
		}, true)

		helpers.assert_not_nil(shortcut, "Ctrl+S must remain a shortcut event")
		helpers.assert_eq(shortcut.key, "s",
			"xkb_state UTF-8 is a control byte; the keysym preserves shortcut identity")
		helpers.assert_true(shortcut.mods.ctrl == true, "the physical Ctrl role remains attached")
	end)
end)
