--- tests/unit/modules/keymap/test_emit_tokens_key_echo.lua

--- ==============================================================================
--- MODULE: Regression — {Enter}/{Tab} tokens must appear in the physical echo
--- DESCRIPTION:
--- A hotstring expanding to text containing {Enter} or {Tab} left the keylogger
--- attributing one character per token to the human typist.
---
--- ROOT CAUSE ENCODED:
--- emit_tokens returns a "physical echo" string — what the OS will report back
--- through getCharacters() — which the keylogger uses to pre-seed its synth_queue
--- so it can tell its own synthetic keystrokes apart from real ones. Text tokens
--- appended to that echo; key tokens did not. But "return" and "tab" DO produce a
--- character (CR and HT respectively), so the OS echoed one more character than
--- the queue expected. The queue ran one entry short, and the surplus character
--- was recorded as human input, corrupting the typing statistics with keystrokes
--- the user never made.
---
--- Nav and escape tokens ({Left}, {Delete}, {Esc}) produce no character and must
--- stay OUT of the echo — a string-typed echo cannot represent them, and adding
--- them would push the error in the opposite direction.
---
--- WHY IT WAS SILENT:
--- Nothing fails and the expansion is correct on screen. Only the n-gram and WPM
--- aggregates drift, slowly, in a direction nobody can spot by inspection.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ============================================
-- ============================================
-- ======= 1/ Emission Recorder Harness =======
-- ============================================
-- ============================================

--- Loads keymap.utils with every emission path recorded, mirroring the harness in
--- test_emit_tokens_ordering.lua.
--- @return table utils, function fire_pending
local function load_utils()
	local pending = {}

	package.loaded["modules.keymap.utils"] = nil
	local KU = helpers.load_with_stubs("modules.keymap.utils", {
		eventtap = {
			keyStroke  = function(_mods, _key) end,
			keyStrokes = function(_s) end,
			event      = { types = { keyDown = 10 } },
			new        = function() return { start = function() end, stop = function() end } end,
		},
		pasteboard = {
			getContents  = function() return "" end,
			readAllData  = function() return {} end,
			writeAllData = function(_) return true end,
			setContents  = function(_) return true end,
		},
		timer = {
			doAfter = function(delay, fn)
				pending[#pending + 1] = { delay = delay, fn = fn }
				return { stop = function() end }
			end,
			doEvery           = function() return { stop = function() end } end,
			secondsSinceEpoch = function() return 1000 end,
			absoluteTime      = function() return 0 end,
			usleep            = function() end,
		},
	})

	local function fire_pending()
		table.sort(pending, function(x, y) return x.delay < y.delay end)
		for _, p in ipairs(pending) do pcall(p.fn) end
		pending = {}
	end

	return KU, fire_pending
end





-- ================================================
-- ================================================
-- ======= 2/ Character-Producing Keys Echo =======
-- ================================================
-- ================================================

helpers.describe("emit_tokens echoes the characters its key tokens produce", function()
	helpers.it("includes CR for a {Enter} token", function()
		local KU, fire = load_utils()
		local _, echo = KU.emit_tokens({
			{ kind = "text", value = "line one" },
			{ kind = "key",  value = "return" },
			{ kind = "text", value = "line two" },
		})
		fire()

		helpers.assert_eq(echo, "line one\rline two",
			"the return key's synthetic keydown carries a CR back through getCharacters(), so it "
			.. "must appear in the physical echo. Omitting it leaves the keylogger's synth_queue "
			.. "one entry short, and the CR gets recorded as a keystroke the user never made")
	end)

	helpers.it("includes HT for a {Tab} token", function()
		local KU, fire = load_utils()
		local _, echo = KU.emit_tokens({
			{ kind = "text", value = "col a" },
			{ kind = "key",  value = "tab" },
			{ kind = "text", value = "col b" },
		})
		fire()

		helpers.assert_eq(echo, "col a\tcol b",
			"the tab key produces HT and must be echoed for the same reason as return")
	end)

	helpers.it("omits keys that produce no character", function()
		local KU, fire = load_utils()
		local _, echo = KU.emit_tokens({
			{ kind = "text", value = "abc" },
			{ kind = "key",  value = "left" },
			{ kind = "key",  value = "delete" },
			{ kind = "key",  value = "escape" },
		})
		fire()

		helpers.assert_eq(echo, "abc",
			"navigation and escape keys emit no character, so echoing anything for them would "
			.. "overshoot the synth_queue and start swallowing the user's REAL keystrokes — the "
			.. "same defect with the sign flipped")
	end)
end)
