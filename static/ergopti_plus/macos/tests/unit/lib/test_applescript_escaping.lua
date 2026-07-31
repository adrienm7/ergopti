--- tests/unit/lib/test_applescript_escaping.lua

--- ==============================================================================
--- MODULE: Regression — values interpolated into AppleScript and /bin/sh must be
---         escaped for the layer they land in (applescript-escaping)
--- DESCRIPTION:
--- Three call sites built commands by escaping only the double quote, or by
--- escaping for the wrong language entirely.
---
--- ROOT CAUSE ENCODED:
---   * AppleScript string literals treat the BACKSLASH as an escape character.
---     Replacing only `"` leaves a path like `~/My\Folder` producing a literal
---     the interpreter was never meant to receive: at best the script errors, at
---     worst a crafted value closes the string and appends statements. The
---     folder-picker seed is the user-configurable config directory — the value
---     most likely to carry one.
---   * `string.format("%q", path)` escapes for a LUA literal. It handles
---     backslashes and quotes but leaves `$`, backticks and `!` untouched, every
---     one of which /bin/sh expands. The shell-quoting guard cannot see a %q
---     call, so this site was invisible to the check that exists for it.
---
--- This is the same class as the canonical shell_quote fix, one layer up: the
--- escape has to match the interpreter that will parse the string, and the
--- backslash has to be escaped FIRST or the backslashes introduced while
--- escaping the quotes get escaped in turn.
--- ==============================================================================

local helpers = require("tests.helpers")

local text_utils = require("lib.text_utils")




-- ==============================================================
-- ==============================================================
-- ======= 1/ The escape matches the interpreter ================
-- ==============================================================
-- ==============================================================

helpers.describe("applescript_escape: escapes for an AppleScript string literal", function()
	helpers.it("doubles a backslash", function()
		helpers.assert_eq(type(text_utils.applescript_escape), "function",
			"the shared text utils must expose an AppleScript escaper, so the three call sites "
				.. "cannot each invent their own half of the rule")

		-- Byte-level: "\" is 0x5C. A path with one backslash must arrive with two.
		local out = text_utils.applescript_escape("/Users/x/My\\Folder")
		local backslashes = select(2, out:gsub("\\", ""))
		helpers.assert_eq(backslashes, 2,
			"AppleScript treats the backslash as an escape character, so one in the input must "
				.. "become two in the literal. Left alone it consumes the character after it and "
				.. "the script the interpreter sees is not the one that was written")
	end)

	helpers.it("escapes a double quote", function()
		local out = text_utils.applescript_escape('say "hi"')
		helpers.assert_true(out:find('\\"', 1, true) ~= nil,
			"an embedded quote must be escaped, or it closes the literal early")
	end)

	helpers.it("escapes the backslash BEFORE the quote", function()
		-- Order matters and is not cosmetic. Escaping quotes first turns `"` into
		-- `\"`, and a later backslash pass then doubles THAT backslash, producing
		-- `\\"` — which ends the string and leaves a stray quote in the script.
		local out = text_utils.applescript_escape('a\\"b')
		helpers.assert_eq(out, 'a\\\\\\"b',
			"the backslash pass must run first: escaping quotes first makes the second pass "
				.. "escape the backslashes it just introduced, which re-opens the very injection "
				.. "the escaping is there to close")
	end)

	helpers.it("leaves an ordinary value untouched", function()
		helpers.assert_eq(text_utils.applescript_escape("/Users/x/Config"), "/Users/x/Config",
			"a path with nothing to escape must pass through unchanged — an escaper that "
				.. "mangles the common case would be caught by every user, not just the edge one")
	end)
end)




-- ==============================================================
-- ==============================================================
-- ======= 2/ Every call site uses it ===========================
-- ==============================================================
-- ==============================================================

helpers.describe("the AppleScript call sites escape through the shared helper", function()
	helpers.it("no site escapes the quote without also escaping the backslash", function()
		local sources = {
			{ symbol = "pickConfigDir",  what = "the onboarding folder picker" },
			{ symbol = "_terminal_cmd",  what = "the download window's Terminal bridge" },
		}

		for _, entry in ipairs(sources) do
			local src = helpers.read_driver_source(entry.symbol)
			helpers.assert_true(src ~= nil and src ~= "",
				entry.what .. " must be locatable by '" .. entry.symbol .. "'")

			local code = src:gsub("%-%-[^\n]*", "")

			-- Every line that escapes a double quote must also handle the
			-- backslash — either inline, as the correct two-step chain does, or by
			-- delegating to the shared helper. Forbidding a particular SPELLING
			-- instead would flag the correct chain, whose second step looks
			-- identical to the broken one-step version.
			local offenders = {}
			local lineno = 0
			for line in (code .. "\n"):gmatch("([^\n]*)\n") do
				lineno = lineno + 1
				local escapes_quote = line:find('gsub%(\'"\'') or line:find('gsub%("\\""')
				local handles_backslash = line:find('gsub%("\\\\"') or line:find("applescript_escape", 1, true)
				if escapes_quote and not handles_backslash then
					offenders[#offenders + 1] = lineno .. ": " .. line:gsub("^%s+", "")
				end
			end

			-- This check passes on an empty result, so an unreadable or renamed source
			-- would retire it rather than fail it.
			helpers.assert_true(lineno > 0,
				entry.what .. ": the scan walked no lines at all — the source is empty or was "
					.. "not found, so finding no offenders proves nothing")

			helpers.assert_eq(#offenders, 0,
				entry.what .. " escapes the double quote without touching the backslash. "
					.. "AppleScript treats the backslash as an escape character, so the value the "
					.. "interpreter receives is not the one that was written:\n  "
					.. table.concat(offenders, "\n  "))

			-- Either shared entry point satisfies the invariant, and the formatter is
			-- the stronger of the two: applescript_escape is opt-in per VALUE, so a
			-- site can escape one of its two interpolated values and leave the other
			-- raw — which is precisely how ui/menu/menu_paths.lua shipped a folder
			-- picker with an escaped path and a raw prompt. applescript_format
			-- escapes every string argument, so the choice no longer exists.
			--
			-- Asserting the ESCAPE symbol by name would now reject that better shape,
			-- which is why the invariant is stated as "routes through the shared
			-- layer" rather than as one function's name.
			local routes_through_shared_layer =
				code:find("applescript_escape", 1, true) ~= nil
				or code:find("applescript_format", 1, true) ~= nil
			helpers.assert_true(routes_through_shared_layer,
				entry.what .. " must escape through the shared layer (applescript_escape or "
					.. "applescript_format), so the rule has one owner rather than a copy per "
					.. "call site")

			-- And it must not ALSO hand-roll one alongside the shared call: a file
			-- can satisfy the assertion above with a single correct site while a
			-- sibling site in the same file stays broken.
			helpers.assert_true(code:find("string.format", 1, true) == nil
					or code:find("applescript_format", 1, true) ~= nil
					or code:find("applescript_escape", 1, true) ~= nil,
				entry.what .. " builds an AppleScript with a bare string.format")
		end
	end)

	helpers.it("the Ollama launch path is shell-quoted, not %q-quoted", function()
		local src = helpers.read_driver_source("OLLAMA_KILL_SETTLE_SEC")
		helpers.assert_true(src ~= nil and src ~= "", "api_ollama must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")

		helpers.assert_true(code:find('string.format%("%%q"') == nil,
			"the log path is interpolated into /bin/sh, so it must not be quoted with %q. That "
				.. "escapes for a LUA literal and leaves $, backticks and ! for the shell to "
				.. "expand — and the path derives from the configurable config directory")
		helpers.assert_true(code:find("shell_quote", 1, true) ~= nil,
			"it must go through shell_quote, which is also the spelling the shell-quoting guard "
				.. "can see — a %q call is invisible to the check that exists for exactly this")
	end)
end)




-- ====================================================================
-- ====================================================================
-- ======= 4/ applescript_format escapes by construction ==============
-- ====================================================================
-- ====================================================================

-- applescript_escape is opt-in PER VALUE, and that is what kept regressing: a
-- call site would escape one of its two interpolated values and leave the other
-- raw. ui/menu/menu_paths.lua shipped exactly that — an escaped default path and
-- a raw prompt, inside one string.format. No shape-based check can see a missing
-- escape in an argument list, so the formatter removes the choice instead.

helpers.describe("applescript_format escapes every interpolated string", function()

	helpers.it("escapes the backslash before the quote, in one pass over each value", function()
		local out = text_utils.applescript_format('do script "%s"', [[C:\My"Dir]])

		-- The expected value spelled out: `C:\My"Dir` must arrive as
		-- `C:\\My\"Dir` — backslash doubled, quote escaped, in that order.
		helpers.assert_eq(out, 'do script "C:\\\\My\\"Dir"',
			"the backslash must be doubled and the quote escaped, in that order: escaping "
			.. "the quote first would leave the introduced backslash to be doubled in turn")
	end)

	helpers.it("escapes EVERY string argument, not just the first", function()
		local out = text_utils.applescript_format('a "%s" b "%s"', [[x\y]], [[p"q]])

		helpers.assert_true(out:find([[x\\y]], 1, true) ~= nil,
			"the first value must be escaped")
		helpers.assert_true(out:find([[p\"q]], 1, true) ~= nil,
			"and so must the second — this is the whole reason the formatter exists, and the "
			.. "assertion that would have failed on the menu_paths folder picker")
	end)

	helpers.it("passes numbers through untouched so %d still works", function()
		local out = text_utils.applescript_format('answer "%d" of "%s"', 250, "ok")

		helpers.assert_eq(out, 'answer "250" of "ok"',
			"escaping a number would coerce it to a string and break %d; numbers cannot "
			.. "carry a backslash or a quote, so there is nothing to escape")
	end)

	helpers.it("does not double-escape a value that is already safe", function()
		local out = text_utils.applescript_format('x "%s"', "plain text")

		helpers.assert_eq(out, 'x "plain text"',
			"without this case the assertions above would pass against a formatter that "
			.. "mangles every value it touches")
	end)

	helpers.it("handles a nil argument without raising", function()
		-- The picker prompt is `i18n.get(key) or ""`, so a missing translation
		-- reaches this layer as nil in the shape just above the `or`. Raising here
		-- would abort inside a menu callback, where the throw is invisible.
		local ok, out = pcall(text_utils.applescript_format, 'x "%s"', nil)

		helpers.assert_true(ok, "a nil argument must not raise: %s")
		helpers.assert_true(type(out) == "string" and out:find("nil", 1, true) ~= nil,
			"string.format's own nil handling is preserved — the formatter only escapes "
			.. "strings and leaves everything else to string.format")
	end)

end)
