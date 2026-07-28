--- tests/unit/modules/keymap/test_french_punctuation_terminators.lua

--- ==============================================================================
--- MODULE: Regression — French punctuation must terminate an expansion, and the
---         resume resync must identify the app the way everything else does
---         (french-punctuation-terminators)
--- DESCRIPTION:
--- Two findings whose common shape is a lookup keyed on the wrong part of a
--- value.
---
---   H10  TERMINATORS MISSED THE TAIL. The macOS layout emits French
---        punctuation as ONE event carrying its typographic space first:
---        ":" arrives as NBSP..":" and ";" / "!" / "?" as NNBSP..<char>. Those
---        spaces are default-DISABLED terminators while the punctuation itself
---        is default-enabled — so is_terminator, which probed the whole string
---        and its FIRST codepoint only, rejected every one of them. The enabled
---        character was always the tail. autocorrection is the flagship feature
---        and is entirely non-auto accent corrections that fire only on a
---        terminator, so the four canonical French sentence endings silently
---        did not fire, while the tooltip had already advertised the row.
---
---   H9   THE RESUME RESYNC READ THE WRONG API. resync_context identified the
---        frontmost app with app:title(); every other part of the pipeline —
---        including SecureFieldDetector.isSecureApp, which exact-matches
---        DISPLAY names — uses app:name(). Its own sibling capture_frontmost_app
---        documents that title() "is absent for some application instances". A
---        password manager whose title is nil or differs from its display name
---        was therefore not re-recognised as secure on resume, so keystrokes
---        typed into it were logged and mis-attributed to the previous app.
---
--- SCOPE, STATED PLAINLY: the terminator half is fully behavioural — the byte
--- sequences are reproduced here and the gate is a pure function. The H9 half
--- is asserted on source: it needs a real Mac with a live hs.application to
--- exercise, and the audit itself rates it deduced rather than measured. What
--- is proven here is the API asymmetry, which is what makes the fix correct;
--- the runtime consequence remains unverified on this platform.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The two typographic spaces the macOS layout prepends. Written as explicit
--- bytes rather than escapes so the fixture cannot drift with source encoding.
local NBSP = string.char(0xC2, 0xA0)          -- U+00A0
local NNBSP = string.char(0xE2, 0x80, 0xAF)   -- U+202F

local function terminators()
	return helpers.load_with_stubs("keymap.terminators", {})
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ A prefixed terminator still terminates =======================
-- =========================================================================
-- =========================================================================

helpers.describe("terminators: French punctuation arrives space-prefixed", function()
	helpers.it("the bare punctuation is a terminator to begin with", function()
		local T = terminators()
		for _, ch in ipairs({ "?", "!", ":", ";" }) do
			helpers.assert_true(T.is_terminator(ch),
				"'" .. ch .. "' must be an enabled terminator by default — if it is not, the "
					.. "prefixed assertions below would be measuring the wrong thing")
		end
	end)

	helpers.it("an NNBSP-prefixed punctuation is recognised", function()
		local T = terminators()
		for _, ch in ipairs({ "?", "!", ";" }) do
			helpers.assert_true(T.is_terminator(NNBSP .. ch),
				"the layout emits '" .. ch .. "' as one event with a leading NNBSP. Probing only "
					.. "the whole string and its FIRST codepoint misses it — NNBSP is a "
					.. "default-disabled terminator, so the enabled character is always the tail. "
					.. "Every French sentence ending then failed to fire the correction, while the "
					.. "tooltip had already offered it")
		end
	end)

	helpers.it("an NBSP-prefixed colon is recognised", function()
		local T = terminators()
		helpers.assert_true(T.is_terminator(NBSP .. ":"),
			"':' arrives with a leading NBSP rather than NNBSP, and must be handled identically")
	end)

	helpers.it("the disabled space alone is still not a terminator", function()
		local T = terminators()
		helpers.assert_true(not T.is_terminator(NNBSP),
			"NNBSP on its own is default-disabled and must stay so. Accepting it would make every "
					.. "typographic space terminate an expansion, which is the opposite failure")
		helpers.assert_true(not T.is_terminator(NBSP),
			"NBSP on its own must likewise stay a non-terminator")
	end)

	helpers.it("an unrelated multi-codepoint event is still rejected", function()
		local T = terminators()
		helpers.assert_true(not T.is_terminator("ab"),
			"the tail probe must not turn arbitrary text into a terminator — only a genuinely "
				.. "enabled terminator character may match")
	end)

	helpers.it("the consume verdict tracks the same tail", function()
		local T = terminators()
		-- Whatever the consume policy is for a given terminator, the prefixed
		-- form must agree with the bare one. A terminator recognised by one probe
		-- and not the other is either consumed when it should be re-typed, or
		-- re-typed when it should be consumed.
		for _, ch in ipairs({ "?", "!", ";" }) do
			helpers.assert_eq(
				T.terminator_is_consumed(NNBSP .. ch),
				T.terminator_is_consumed(ch),
				"the consume verdict for '" .. ch .. "' must not depend on whether the layout "
					.. "prepended its typographic space")
		end
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ The resume resync uses the display-name API ==================
-- =========================================================================
-- =========================================================================

helpers.describe("context_tracker: resync identifies the app by name", function()
	helpers.it("resync_context reads app:name(), not app:title()", function()
		local src = helpers.read_driver_source("resync_context")
		helpers.assert_true(src ~= nil and src ~= "",
			"the context tracker must be locatable by its resync_context symbol")

		-- Comments stripped FIRST. The fix's own comment explains why title() is
		-- wrong and therefore contains the string "app:title()" — scanning raw
		-- source flags the fix as the bug. The repo's meta-test guidance calls
		-- this out explicitly; it caught this test on its first run.
		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("function M.resync_context", 1, true)
		helpers.assert_true(at ~= nil, "M.resync_context must exist")
		local body = code:sub(at, at + 900)

		helpers.assert_true(body:find("app:name()", 1, true) ~= nil,
			"resync_context must resolve the app through name(). The whole pipeline is keyed on "
				.. "display names — SecureFieldDetector.isSecureApp exact-matches them — so reading "
				.. "title() means a vault whose title is nil or differs is not re-recognised as "
				.. "secure on resume, and keystrokes typed into it get logged")
		helpers.assert_true(body:find("app:title()", 1, true) == nil,
			"and it must no longer read title(), which its own sibling documents as absent for "
				.. "some application instances")
	end)

	helpers.it("it rejects an empty name as well as a missing one", function()
		local src = helpers.read_driver_source("resync_context")
		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("function M.resync_context", 1, true)
		local body = code:sub(at, at + 900)

		helpers.assert_true(body:find('app_name == ""', 1, true) ~= nil,
			"an app with a blank name must not be adopted as the active context — the type check "
				.. "alone accepts \"\", which would set an unusable active_app_name and defeat every "
				.. "later comparison against it")
	end)

	helpers.it("it matches the sibling resume helper", function()
		local src = helpers.read_driver_source("capture_frontmost_app")
		helpers.assert_true(src ~= nil and src ~= "",
			"the sibling resume helper must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("capture_frontmost_app", 1, true)
		local body = code:sub(at, at + 900)
		helpers.assert_true(body:find("app:name()", 1, true) ~= nil,
			"capture_frontmost_app must still use name(). It is the reference implementation this "
				.. "fix aligns resync_context with — if it ever changes, the two must change together")
	end)
end)
