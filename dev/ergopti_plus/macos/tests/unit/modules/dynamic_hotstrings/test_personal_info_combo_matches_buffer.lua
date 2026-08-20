--- tests/unit/modules/dynamic_hotstrings/test_personal_info_combo_matches_buffer.lua

--- ==============================================================================
--- MODULE: Regression — a pending @-combo must still be on screen to fire
--- DESCRIPTION:
--- personal_info kept two independent answers to "what @-combo is pending": a
--- private state machine fed only from keyDown, and the preview provider, which
--- reads the keymap buffer. The state machine resets on modifiers, navigation,
--- backspace and any non-letter — but a MOUSE CLICK produces no keyDown at all,
--- and neither does a focus change.
---
--- ROOT CAUSE ENCODED:
--- do_expand derives its backspace count from #_combo alone and never checks that
--- the buffer still ends with "@" .. combo. A combo begun in one place and
--- triggered after the caret moved therefore erased that many characters wherever
--- the caret now sat, and injected the personal data there. Two representations
--- of the same fact, one of which cannot observe the event that invalidates it.
---
--- The fix makes the keymap buffer the single authority, the same move the
--- 2026-07-21 pass made for would_fire. These cases drive the real interceptor.
--- ==============================================================================

local helpers = require("tests.helpers")

local TRIGGER = "\u{2605}"


--- Fake keymap capturing the interceptor and every inject_dynamic call.
--- @return table
local function make_fake_keymap()
	local rec = { interceptors = {}, injects = {} }
	rec.km = {
		get_trigger_char          = function() return TRIGGER end,
		is_section_enabled        = function() return true end,
		is_group_enabled          = function() return true end,
		register_lua_group        = function() end,
		set_post_load_hook        = function() end,
		set_group_context         = function() end,
		sort_mappings             = function() end,
		add                       = function() end,
		register_preview_provider = function() end,
		register_interceptor      = function(fn) rec.interceptors[#rec.interceptors + 1] = fn end,
		inject_dynamic            = function(deletes, text)
			rec.injects[#rec.injects + 1] = { deletes = deletes, text = text }
			return true
		end,
	}
	return rec
end


--- @param char string
--- @return table Fake keyDown event.
local function key(char)
	return {
		getFlags      = function() return { cmd = false, ctrl = false } end,
		getKeyCode    = function() return 0 end,
		getCharacters = function() return char end,
	}
end


--- Boots personal_info alone against a fake keymap.
--- @return table interceptor, table rec
local function boot()
	package.loaded["modules.dynamic_hotstrings.personal_info"] = nil
	local PI  = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")
	local rec = make_fake_keymap()
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write('[info]\nemail_address = "a@b.fr"\n\n[letters]\ne = "email_address"\n')
	fh:close()
	PI.start("", rec.km, path)
	PI.enable()
	os.remove(path)
	helpers.assert_type(rec.interceptors[1], "function", "personal_info must register an interceptor")
	return rec.interceptors[1], rec
end




-- ==========================================================
-- ==========================================================
-- ======= 1/ The buffer is the authority ===================
-- ==========================================================
-- ==========================================================

helpers.describe("personal_info: a pending @-combo the buffer no longer shows must not expand", function()

	helpers.it("does not expand when the caret moved away between the combo and the trigger", function()
		local interceptor, rec = boot()

		-- The user types "@e" …
		interceptor(key("@"), "")
		interceptor(key("e"), "@")
		-- … then CLICKS somewhere else. No keyDown is delivered for that, so the
		-- state machine still believes "@e" is pending; only the buffer knows.
		local verdict = interceptor(key(TRIGGER), "Bonjour")

		helpers.assert_eq(#rec.injects, 0,
			"a combo the keymap buffer no longer shows must not expand — its backspaces would "
			.. "erase unrelated text and drop the personal data at the wrong caret")
		helpers.assert_eq(verdict, nil,
			"the trigger keystroke must fall through rather than be consumed, so the user still "
			.. "gets the character they typed")
	end)

	helpers.it("still expands normally when the buffer does show the combo", function()
		local interceptor, rec = boot()

		interceptor(key("@"), "")
		interceptor(key("e"), "@")
		local verdict = interceptor(key(TRIGGER), "@e")

		helpers.assert_eq(verdict, "consume", "the ordinary path must keep working")
		helpers.assert_eq(#rec.injects, 1,
			"without this case the check above would pass against an engine that never expands")
		helpers.assert_eq(rec.injects[1].deletes, 2,
			"the two erased characters are the '@' and the one combo letter")
	end)

	helpers.it("does not expand when the buffer shows the combo without its @ sentinel", function()
		local interceptor, rec = boot()

		interceptor(key("@"), "")
		interceptor(key("e"), "@")
		-- A buffer ending in "e" but not "@e": the '@' was erased by something the
		-- interceptor never saw. Erasing two characters here eats a real one.
		local verdict = interceptor(key(TRIGGER), "une")

		helpers.assert_eq(#rec.injects, 0,
			"the '@' sentinel is part of what gets erased, so its absence must block the expansion")
		helpers.assert_eq(verdict, nil)
	end)

end)
