--- tests/unit/modules/dynamic_hotstrings/test_synth_echo_includes_tabs.lua

--- ==============================================================================
--- MODULE: Regression — multi-field @-expansion must not under-fill the synth queue
--- DESCRIPTION:
--- Audit finding G3. do_expand's emitter types the field values AND fires a real
--- inter-field Tab keyStroke (counting it in `c`), but returned a TAB-FREE echo
--- string as its physical_echo. perform_text_replacement feeds that value to BOTH
--- synthetic trackers, and they treat a mismatch very differently:
---
---   - keymap (expected_synthetic_chars): on a head mismatch inside its 20 ms
---     window it returns WITHOUT consuming — non-destructive, self-correcting.
---   - keylogger (synth_queue): its fast path POPS an entry on a char mismatch
---     too (init.lua "Pop the queue even on a char-mismatch fast-path"), so the
---     Tab echo consumed a value entry.
---
--- With N fields the queue therefore ran N-1 entries short, and the trailing
--- characters of the payload found an EMPTY queue: classified is_synthetic=false
--- and recorded as HUMAN keystrokes into buffer_text, rich_chunks, the physical
--- WPM window and the n-gram index. For an IBAN+SSN combo that is the tail of the
--- SSN. It was silent because the stale-queue self-heal only warns about LEFTOVER
--- entries — here the queue was UNDER-filled.
---
--- Fix: physical_echo enumerates EVERY keydown the OS delivers (fields joined by
--- "\t"), while the LOGICAL text and CoreState.buffer stay tab-free — a Tab moves
--- focus to the next field, it inserts nothing on screen. That tab-free buffer
--- value is the earlier F-H3 fix and is deliberately preserved here.
---
--- This test drives the REAL interceptor (@ p n ★) so the REAL do_expand runs and
--- the emitter under assertion is production code, not a re-implementation.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Keycode of a plain letter: not escape/return/backspace/navigation, so the
-- interceptor treats these events as ordinary character input.
local KEYCODE_LETTER = 0

local FIRST_NAME = "Prénom"   -- deliberately accented: exercises the codepoint count
local LAST_NAME  = "Nom"


--- Writes a two-field personal_info.toml to a temp path so M.start() does not
--- materialise defaults into the user's config tree.
--- @return string The temp file path.
local function write_personal_info_toml()
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(string.format(
		'[info]\nfirst_name = "%s"\nlast_name = "%s"\n\n[letters]\np = "first_name"\nn = "last_name"\n',
		FIRST_NAME, LAST_NAME))
	fh:close()
	return path
end

--- Builds a synthetic key event for the interceptor.
--- @param chars string The character produced.
--- @return table The fake event.
local function fake_event(chars)
	return {
		getFlags      = function() return {} end,
		getKeyCode    = function() return KEYCODE_LETTER end,
		getCharacters = function() return chars end,
	}
end

--- Loads personal_info, drives the real interceptor through "@pn★", and returns
--- the arguments the production code handed to keymap.inject_dynamic.
--- @return table captured Fields: n_back, result_text, emit_action, variant.
local function drive_real_expansion()
	local PI = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")

	local captured = {}
	local interceptor
	local fake_km = {
		register_interceptor      = function(fn) interceptor = fn end,
		register_preview_provider = function() end,
		inject_dynamic = function(n_back, result_text, emit_action, variant)
			captured.n_back      = n_back
			captured.result_text = result_text
			captured.emit_action = emit_action
			captured.variant     = variant
		end,
	}

	local toml_path = write_personal_info_toml()
	PI.start("", fake_km, toml_path)
	PI.enable()
	os.remove(toml_path)

	helpers.assert_type(interceptor, "function", "personal_info must register its interceptor")

	-- "@" arms collection, "p" and "n" accumulate the combo, the trigger fires it.
	interceptor(fake_event("@"), "")
	interceptor(fake_event("p"), "@")
	interceptor(fake_event("n"), "@p")
	local verdict = interceptor(fake_event(PI.get_trigger_char()), "@pn")
	helpers.assert_eq(verdict, "consume", "the trigger keystroke must be consumed by the expansion")

	return captured
end


helpers.describe("multi-field @-expansion: the physical echo enumerates every keydown", function()
	helpers.it("the emitter fires a real Tab between the two fields", function()
		local captured = drive_real_expansion()
		helpers.assert_type(captured.emit_action, "function", "inject_dynamic must receive an emit callback")

		local before = #hs.eventtap.__keystrokes
		captured.emit_action()
		local tab_strokes, text_strokes = 0, 0
		for i = before + 1, #hs.eventtap.__keystrokes do
			local k = hs.eventtap.__keystrokes[i]
			if k.key == "tab" then tab_strokes = tab_strokes + 1 end
			if k.text then text_strokes = text_strokes + 1 end
		end
		helpers.assert_eq(text_strokes, 2, "both field values must be typed")
		helpers.assert_eq(tab_strokes, 1,
			"a real Tab keyStroke must be fired between the two fields — it echoes back as a keydown")
	end)

	helpers.it("physical_echo contains the tab and its codepoint count equals the emitted count", function()
		local captured = drive_real_expansion()
		local count, physical_echo, logical_text = captured.emit_action()

		helpers.assert_type(physical_echo, "string", "the emitter must return a physical echo string")
		helpers.assert_contains(physical_echo, "\t",
			"physical_echo must include the inter-field Tab: the keylogger's synth_queue pops one "
			.. "entry per echo, so omitting it leaves the queue short and the payload's trailing "
			.. "characters are recorded as HUMAN keystrokes")

		-- One queue entry per emitted keydown — the invariant the bug violated.
		helpers.assert_eq(utf8.len(physical_echo), count,
			"physical_echo must hold exactly as many codepoints as the emitter reported emitting")
		helpers.assert_eq(physical_echo, FIRST_NAME .. "\t" .. LAST_NAME)

		-- The logical text is a DIFFERENT string: a Tab moves focus, it inserts
		-- nothing, so the buffer and the logged record must stay tab-free.
		helpers.assert_type(logical_text, "string", "the emitter must return a logical text")
		helpers.assert_true(not logical_text:find("\t", 1, true),
			"logical_text must stay tab-free — a Tab inserts no character on screen")
		helpers.assert_eq(logical_text, FIRST_NAME .. LAST_NAME)
	end)

	helpers.it("keeps CoreState.buffer tab-free (the earlier F-H3 fix is preserved)", function()
		local captured = drive_real_expansion()
		helpers.assert_type(captured.result_text, "string")
		helpers.assert_true(not captured.result_text:find("\t", 1, true),
			"inject_dynamic's result_text seeds CoreState.buffer and must contain no \t")
		helpers.assert_eq(captured.result_text, FIRST_NAME .. LAST_NAME)
	end)
end)
