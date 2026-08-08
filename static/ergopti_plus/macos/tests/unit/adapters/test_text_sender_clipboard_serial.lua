--- tests/unit/adapters/test_text_sender_clipboard_serial.lua

--- ==============================================================================
--- MODULE: Regression — text_sender clipboard path serializes save/restore
--- DESCRIPTION:
--- Audit finding F-L8. The clipboard path called Clipboard.save() fresh on every
--- send with no cross-call state. Two clipboard sends within CLIPBOARD_RESTORE_DELAY_S
--- meant call #2's save() captured call #1's still-injected payload as "the user's
--- clipboard", and both restores then clobbered the real original. Fix: serialise —
--- on an overlapping send cancel the pending restore but KEEP the first-captured
--- original (mirrors keymap/utils.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("text_sender clipboard path serializes save/restore", function()
	helpers.it("an overlapping second send does NOT re-save, and the original survives", function()
		local saves = 0
		local restores = {}
		local timers = {}
		package.loaded["adapters.clipboard"] = {
			save    = function() saves = saves + 1; return "ORIGINAL" end,
			write   = function(_) end,
			restore = function(v) restores[#restores + 1] = v end,
		}
		package.loaded["adapters.synthetic_input"] = {
			emit_key_stroke = function() return true end,
		}

		local TS = helpers.load_with_stubs("adapters.text_sender", {
			eventtap = { keyStroke = function() end, keyStrokes = function() end },
			timer    = { doAfter = function(_d, fn) timers[#timers + 1] = fn; return { stop = function() end } end },
		})

		TS.send(("a"):rep(50), { mode = "clipboard" })  -- call #1: saves ORIGINAL, arms restore
		TS.send(("b"):rep(50), { mode = "clipboard" })  -- call #2: overlaps (restore #1 not fired)

		-- Root cause: the second save must NOT run while a restore is pending —
		-- otherwise it would capture call #1's injected "a..." as the user clipboard.
		helpers.assert_eq(saves, 1)

		-- Fire the surviving (last) restore; the clipboard must be the user's ORIGINAL.
		pcall(timers[#timers])
		helpers.assert_true(#restores >= 1, "a restore must fire")
		helpers.assert_eq(restores[#restores], "ORIGINAL")

		package.loaded["adapters.clipboard"]   = nil
		package.loaded["adapters.synthetic_input"] = nil
		package.loaded["adapters.text_sender"] = nil
	end)
end)
