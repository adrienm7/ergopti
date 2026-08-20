--- tests/unit/modules/hotstrings/test_injector_untypable_text.lua

--- ==============================================================================
--- MODULE: Delivering a Replacement the Layout Cannot Type
--- DESCRIPTION:
--- A Spanish hotstring pack on a French keyboard. A Greek one on a US keyboard.
--- The replacement contains characters that exist on NO key of the layout the
--- user is actually typing on, at any level.
---
--- WHY THIS IS A TEST AND NOT A COMMENT:
--- The driver now types replacements as real keystrokes, resolved against the
--- user's real XKB layout, which is what made accented French text work without a
--- clipboard round-trip. That same change is what creates this case: keystroke
--- synthesis can only produce characters the layout has a key for. `ñ` on an
--- AZERTY layout has none — not unshifted, not shifted, not on AltGr — so there
--- is no keycode to press and the layout path cannot deliver it at all.
---
--- The dangerous failure is not "nothing is typed". It is "half is typed".
--- `inject()` erases the trigger BEFORE sending the replacement, so a planner
--- that emitted the characters it could and skipped the rest would leave the user
--- with `seor` where they had typed a trigger — text destroyed, silently, and
--- only for people whose language is not the layout's. Hence plan() is
--- all-or-nothing and the clipboard carries the whole string or nothing does.
---
--- These tests pin the three outcomes in order: typable → keystrokes and no
--- clipboard; untypable → clipboard, whole and unsplit; untypable with no
--- clipboard tool → an ERROR, because the trigger is already gone and the user
--- deserves to know why rather than to wonder.
--- ==============================================================================

local helpers = require("tests.helpers")


-- A layout with no Spanish letters: exactly what a French or US keymap gives a
-- user who installs the Spanish hotstring pack.
local LAYOUT_WITHOUT_SPANISH = {
	["s"] = { keycode = 31, mods = {} },
	["e"] = { keycode = 18, mods = {} },
	["o"] = { keycode = 24, mods = {} },
	["r"] = { keycode = 19, mods = {} },
	["S"] = { keycode = 31, mods = { "shift" } },
}


--- A uinput channel that records every emitted event.
--- @param open boolean Whether the channel reports itself as open.
--- @return table
local function fake_channel(open)
	local ch = { emitted = {} }
	ch.is_open = function() return open end
	ch.emit = function(code, value)
		ch.emitted[#ch.emitted + 1] = { code = code, value = value }
		return true
	end
	return ch
end


--- Installs a clipboard stub and returns it, along with a restore function.
--- @param succeeds boolean Whether paste_text reports success.
--- @return table stub, function restore
local function stub_clipboard(succeeds)
	local previous = package.loaded["adapters.clipboard"]
	local stub = { calls = {} }
	stub.is_available = function() return succeeds end
	stub.paste_text = function(text)
		stub.calls[#stub.calls + 1] = text
		return succeeds
	end
	package.loaded["adapters.clipboard"] = stub
	return stub, function() package.loaded["adapters.clipboard"] = previous end
end


--- Loads the injector with a layout table and a channel already wired in.
--- @param channel table The fake uinput channel.
--- @return table injector
local function load_injector(channel)
	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test(LAYOUT_WITHOUT_SPANISH)
	local injector = helpers.load_module("modules.hotstrings.injector")
	injector._set_uinput(channel)
	-- Real sleeps would make this suite wait on every backspace for nothing:
	-- the delay is a property of the injection timing, not of the routing.
	injector._set_nanosleep_for_test(function() end)
	return injector
end





-- =========================================================================
-- =========================================================================
-- ======= 1/ Typable text never reaches the clipboard =====================
-- =========================================================================
-- =========================================================================

helpers.describe("injector: a replacement the layout can type is typed", function()

	helpers.it("emits keystrokes and leaves the clipboard untouched", function()
		local clip, restore = stub_clipboard(true)
		local ch = fake_channel(true)
		local injector = load_injector(ch)

		-- "señor" minus the one letter this layout lacks: every character here has
		-- a key, so the whole string must go out as keystrokes.
		injector.inject(0, "seor")

		helpers.assert_eq(#clip.calls, 0,
			"the clipboard must not be used for a string every character of which has a key")
		helpers.assert_true(#ch.emitted > 0,
			"and the replacement must have gone out as real key events")
		restore()
	end)

end)





-- =========================================================================
-- =========================================================================
-- ======= 2/ Untypable text goes out whole, through the clipboard =========
-- =========================================================================
-- =========================================================================

helpers.describe("injector: a replacement the layout cannot type is pasted whole", function()

	helpers.it("sends the entire string to the clipboard, not the typable part of it", function()
		local clip, restore = stub_clipboard(true)
		local ch = fake_channel(true)
		local injector = load_injector(ch)

		injector.inject(0, "señor")

		helpers.assert_eq(#clip.calls, 1,
			"exactly one clipboard delivery — a per-character fallback would paste five times")
		helpers.assert_eq(clip.calls[1], "señor",
			"and it carries the WHOLE replacement; a partial paste after the erase destroys text")
		restore()
	end)

	helpers.it("emits no character keystrokes for the string it could not plan", function()
		local clip, restore = stub_clipboard(true)
		local ch = fake_channel(true)
		local injector = load_injector(ch)

		injector.inject(0, "señor")

		-- The four typable letters of "señor" are s, e, o and r. If any of their
		-- keycodes was pressed, the planner ran per-character and the user got
		-- "seor" followed by a paste of "señor" — the text doubled, not fixed.
		local typable_codes = { [31] = "s", [18] = "e", [24] = "o", [19] = "r" }
		for _, event in ipairs(ch.emitted) do
			helpers.assert_true(typable_codes[event.code] == nil,
				"no character key may be pressed once the plan was refused")
		end
		restore()
	end)

end)





-- =========================================================================
-- =========================================================================
-- ======= 3/ No clipboard route is said out loud ==========================
-- =========================================================================
-- =========================================================================

helpers.describe("injector: an undeliverable replacement is reported, not swallowed", function()

	helpers.it("logs an ERROR when neither the layout nor the clipboard can deliver", function()
		-- The stub's error() is a no-op, so it is replaced with a recorder here
		-- rather than asserted through: what matters is that the ERROR variant was
		-- the one chosen, not that some line was written somewhere.
		local logger = helpers.make_logger_stub()
		local said = {}
		logger.error = function(_, fmt, ...)
			said[#said + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
		end
		local previous_logger = package.loaded["logger.shim"]
		package.loaded["logger.shim"] = logger

		local _, restore = stub_clipboard(false)
		local ch = fake_channel(true)
		local injector = load_injector(ch)

		injector.inject(0, "señor")

		local mentioned = false
		for _, line in ipairs(said) do
			if line:find("señor", 1, true) then mentioned = true end
		end
		helpers.assert_true(mentioned,
			"the trigger has already been erased, so silence here is text lost with no explanation")

		restore()
		package.loaded["logger.shim"] = previous_logger
	end)

end)
