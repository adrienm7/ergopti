--- tests/unit/meta/test_injector_race.lua

--- ==============================================================================
--- MODULE: Injector — the erase-then-type window
--- DESCRIPTION:
--- An injection replayed against a virtual document, so the ORDER of what
--- reaches the application is asserted rather than the shape of a command.
---
--- ROOT CAUSE ENCODED:
--- On a match the injector erases the trigger and then types the replacement.
--- That window is tens of milliseconds, and until the daemon grabbed the device
--- every key the user kept typing during it went straight to the application and
--- interleaved with the synthetic stream: "abcd" came out as "acd",
--- non-deterministically.
---
--- WHAT CHANGED, AND WHY THE MODEL IS DIFFERENT NOW:
--- The old version of this file modelled ydotool: it parsed `ydotool key 14:1`
--- and `ydotool type -- 'text'` out of shell command strings. That model had a
--- defect of its own — its text pattern could not span the shell escape for an
--- apostrophe, so a French replacement silently appended NOTHING and the
--- corruption assertion passed because the document had never been written to.
---
--- There are no commands to parse now. The injector writes evdev events to its
--- own uinput device, so the document is rebuilt from the events themselves, and
--- an apostrophe is a keystroke like any other.
--- ==============================================================================

local helpers = require("tests.helpers")

-- A layout for the characters these cases type. Keycodes are arbitrary but
-- distinct: the point is that the injector resolves through the layout table
-- rather than assuming anything, so any consistent set proves it.
local LETTERS = "abcdehilorstuwy '"
local LAYOUT = {}
local CHAR_OF = {}
do
	local next_code = 100
	for i = 1, #LETTERS do
		local char = LETTERS:sub(i, i)
		LAYOUT[char] = { keycode = next_code, level = 1, mods = {} }
		CHAR_OF[next_code] = char
		next_code = next_code + 1
	end
end

local KEY_BACKSPACE = 14
local VALUE_DOWN = 1

--- A uinput channel that replays what it is asked to emit into a document.
--- @param doc table { value = string }
--- @param on_backspace function|nil Called as (index, doc) after each erase.
--- @return table channel
local function virtual_device(doc, on_backspace)
	local erased = 0
	return {
		is_open = function() return true end,
		emit = function(code, value)
			-- Only presses change a document; a release is not a character.
			if value ~= VALUE_DOWN then return true end

			if code == KEY_BACKSPACE then
				erased = erased + 1
				-- Pop one UTF-8 codepoint, not one byte.
				local len = #doc.value
				while len > 0 and doc.value:byte(len) >= 0x80 and doc.value:byte(len) < 0xC0 do
					len = len - 1
				end
				if len > 0 then doc.value = doc.value:sub(1, len - 1) end
				if on_backspace then on_backspace(erased, doc) end
				return true
			end

			local char = CHAR_OF[code]
			if char then doc.value = doc.value .. char end
			return true
		end,
	}
end

--- Loads the injector with the stub layout and a virtual device installed.
--- @param doc table
--- @param on_backspace function|nil
--- @return table injector
local function with_document(doc, on_backspace)
	local layout = helpers.load_module("adapters.keyboard_layout")
	layout._set_table_for_test(LAYOUT)
	package.loaded["adapters.keyboard_layout"] = layout

	local injector = helpers.load_module("modules.hotstrings.injector")
	injector._set_uinput(virtual_device(doc, on_backspace))
	return injector
end





-- =================================================================
-- =================================================================
-- ======= 1/ The two phases reach the document ====================
-- =================================================================
-- =================================================================

helpers.describe("injector: erase then type, against a virtual document", function()

	helpers.it("removes exactly as many characters as it was asked to", function()
		local doc = { value = "hello" }
		with_document(doc).inject(2, "")
		helpers.assert_eq(doc.value, "hel", "two backspaces on 'hello'")
	end)

	helpers.it("appends the replacement", function()
		local doc = { value = "hel" }
		with_document(doc).inject(0, "lo world")
		helpers.assert_eq(doc.value, "hello world", "the replacement is typed, character by character")
	end)

	helpers.it("erases before it types", function()
		local doc = { value = "btw" }
		with_document(doc).inject(3, "by the way")
		-- Typing first would delete the replacement's own tail instead of the
		-- trigger, which reads as a truncated expansion rather than as an ordering
		-- bug.
		helpers.assert_eq(doc.value, "by the way", "the whole expansion, and nothing of the trigger")
	end)

	helpers.it("types an apostrophe like any other character", function()
		local doc = { value = "" }
		with_document(doc).inject(0, "it's")
		-- The old model could not express this: its command-parsing pattern could
		-- not span the shell escape for a quote, so a French replacement appended
		-- nothing at all and every assertion about the result passed vacuously.
		helpers.assert_eq(doc.value, "it's",
			"an apostrophe is a keystroke now, not a shell-quoting problem")
	end)

	helpers.it("does nothing at all for a non-string replacement", function()
		local doc = { value = "keep" }
		with_document(doc).inject(2, nil)
		helpers.assert_eq(doc.value, "keep",
			"a malformed call must not erase — the guard runs before the first backspace")
	end)

	helpers.it("erases nothing for a zero or negative count", function()
		local doc = { value = "keep" }
		local injector = with_document(doc)
		injector.inject(0, "")
		injector.inject(-3, "")
		helpers.assert_eq(doc.value, "keep", "there is nothing to erase")
	end)

end)





-- =================================================================
-- =================================================================
-- ======= 2/ A keystroke arriving mid-injection ===================
-- =================================================================
-- =================================================================

helpers.describe("injector: input arriving during the erase window", function()

	helpers.it("corrupts the document when the keystroke is applied directly", function()
		-- The defect, modelled. The user typed "btw" and keeps typing: a physical
		-- "c" lands after the second backspace. Applied directly it sits between
		-- the erase and the replacement:
		--   "btw" → "bt" → "b" + "c" = "bc" → "b" → "by the way" = "bby the way"
		local doc = { value = "btw" }
		local landed = false
		local injector = with_document(doc, function(index, d)
			if index == 2 and not landed then
				landed = true
				d.value = d.value .. "c"
			end
		end)
		injector._end_injection()
		injector.inject(3, "by the way")

		helpers.assert_true(landed, "the interleaving must actually have been simulated")
		helpers.assert_eq(doc.value, "bby the way",
			"named exactly, not merely asserted to differ from the correct answer: a "
				.. "~= check passes when the document was never written at all, which "
				.. "is how the previous version of this test passed for years")
	end)

	helpers.it("preserves the document when the keystroke is queued instead", function()
		local doc = { value = "btw" }
		local queued = {}
		local injector = with_document(doc, function(index)
			if index == 2 and #queued == 0 then
				-- With the queue armed the daemon holds the character instead of
				-- letting it reach the engine mid-injection.
				queued[#queued + 1] = "c"
			end
		end)

		injector._begin_injection()
		injector.inject(3, "by the way")
		for _, ch in ipairs(injector._end_injection()) do queued[#queued + 1] = ch end
		for _, ch in ipairs(queued) do doc.value = doc.value .. ch end

		helpers.assert_eq(doc.value, "by the wayc",
			"the replacement, then what the user typed during it, in that order")
	end)

	helpers.it("reports whether an injection is in flight", function()
		local doc = { value = "" }
		local injector = with_document(doc)
		injector._end_injection()
		helpers.assert_eq(injector._is_injecting(), false, "nothing in flight to start with")
		injector._begin_injection()
		helpers.assert_eq(injector._is_injecting(), true, "armed")
		injector._end_injection()
		helpers.assert_eq(injector._is_injecting(), false, "and disarmed")
	end)

	helpers.it("drops characters queued by a previous injection", function()
		local doc = { value = "" }
		local injector = with_document(doc)
		injector._begin_injection()
		injector._queue_char("x")
		injector._begin_injection()
		helpers.assert_eq(#injector._end_injection(), 0,
			"a stale character replayed into the next expansion appears from nowhere, "
				.. "long after the keystroke that produced it")
	end)

end)
