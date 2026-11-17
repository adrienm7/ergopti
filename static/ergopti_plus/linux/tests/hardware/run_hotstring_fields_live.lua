--- tests/hardware/run_hotstring_fields_live.lua

--- ==============================================================================
--- MODULE: Multi-Field Expansions And Character Deletion In Real GTK Fields
--- DESCRIPTION:
--- Run by run_gtk_fields_live.sh on Xvfb with openbox and a private session
--- bus. The hotstring injector (modules/hotstrings/injector.lua) types into
--- real GTK fields with the daemon's text owner (focus_guard.capture_text_owner
--- over the resident AT-SPI watch) and the production writer, whose last hop is
--- XTest. Every verdict is read back from the fields themselves.
---
--- WHAT IT ASSERTS (18-scope review, Linux hotstrings native acceptance):
--- 1. Multi-field Tab settling: inject_fields erases the trigger, types each
---    value and presses a real Tab between them; every value lands in its own
---    field, in order, even with an accented value the layout cannot type
---    (pasted), and the caret ends in the last field. The clipboard is put back.
--- 2. Character deletion: one Backspace deletes exactly one injector caret step
---    (a user-perceived character) in GTK, for an emoji with a skin tone, a ZWJ
---    sequence, a flag and an accent typed as a combining mark, which Undo's
---    erase count relies on; and the injector's own erase of such characters
---    removes them whole and nothing before them.
--- Exit 0 = every check held; 1 = a failure; 2 = no environment.
--- ==============================================================================

require("core.lifecycle.engine.compat.utf8").install()
if os.getenv("ERGOPTI_LIVE_DEBUG") then
	require("core.logger.engine").set_sink(function(line) io.stderr:write(line, "\n") end)
end

local EXPECTED_CHECKS = 11
local TITLE = "Ergopti hotstring fields"
local TRIGGER = "@pn\u{2605}"
local CLUSTERS = {
	{ "an emoji with a skin tone", "\u{1F44D}\u{1F3FD}" },
	{ "a ZWJ sequence", "\u{1F469}\u{200D}\u{1F4BB}" },
	{ "a flag", "\u{1F1EB}\u{1F1F7}" },
	{ "an accent typed as a combining mark", "e\u{301}" },
}

local checks, failures = 0, 0
local function check(condition, text)
	checks = checks + 1
	if not condition then failures = failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

local Session = require("tests.hardware.lib.gtk_fields_session")
local Clipboard = require("adapters.clipboard")
local ComboEmitter = require("modules.gestures.combo_emitter")
local Injector = require("modules.hotstrings.injector")
local Json = require("core.text.engine.json")

print("=== multi-field expansions and character deletion in real GTK fields ===")
Session.xtest_wire()
local window = Session.open_window(TITLE, { "text", "text", "text" })
local privacy = Session.privacy_owner()
local SEED = "ERGOPTI-CLIPBOARD-BEFORE-FIELDS"
assert(Clipboard.write(SEED), "the clipboard must be seeded")

--- Focuses a field with the given texts, caret at the end, and retains it.
--- @return table publication The daemon's retained text destination.
local function prepare(target, texts)
	assert(window.control(target, -1, -1, texts), "the fixture must focus field " .. target)
	assert(privacy.join(true), "the privacy owner must join field " .. target)
	return assert(privacy.guard.capture_text_owner(), "the field must be retained")
end

--- Waits until the fields read `expected` and field `focused` holds the focus;
--- on a miss, prints what the injection answered and what the fields hold.
--- @param result table The injector's result.
local function fields_read(result, expected, focused)
	local read = result.ok == true and window.wait_state(function(state)
		for index, text in ipairs(expected) do
			if state.texts[index] ~= text then return false end
		end
		return state.focused == focused
	end, 8)
	if not read then
		local state = window.state() or {}
		print(string.format("       result ok=%s error=%s phase=%s; fields %s, focused %s", tostring(result.ok),
			tostring(result.error), tostring(result.failed_phase), Json.encode(state.texts or {}), tostring(state.focused)))
	end
	return read
end

--- Whether the clipboard still holds the seed.
local function clipboard_kept()
	local ok, text = Clipboard.read_checked()
	return ok and text == SEED
end

local function run()
	print("--- multi-field Tab settling ---")
	local result = Injector.inject_fields(utf8.len(TRIGGER), { "Ada", "Lovelace" }, true,
		prepare(0, { TRIGGER, "", "" }))
	check(fields_read(result, { "Ada", "Lovelace", "" }, 1),
		"two values: the trigger is erased, each value lands in its own field and the caret ends in the second")
	result = Injector.inject_fields(utf8.len(TRIGGER), { "Ada", "Lovelace", "Londres" }, true,
		prepare(0, { TRIGGER, "", "" }))
	check(fields_read(result, { "Ada", "Lovelace", "Londres" }, 2),
		"three values fill three fields in order and the caret ends in the third")
	result = Injector.inject_fields(utf8.len(TRIGGER), { "H\u{E9}l\u{E8}ne", "Dupont" }, true,
		prepare(1, { "kept", TRIGGER, "" }))
	check(fields_read(result, { "kept", "H\u{E9}l\u{E8}ne", "Dupont" }, 2),
		"from the second field, an accented value the layout cannot type still lands whole in its own field")
	check(clipboard_kept(), "the clipboard's previous text is put back after the expansions")

	print("--- one Backspace deletes one character ---")
	for _, case in ipairs(CLUSTERS) do
		local text = "ab" .. case[2]
		prepare(0, { text, "", "" })
		ComboEmitter.press("BackSpace")
		local deleted = window.wait_state(function(state) return state.texts[1] ~= text end, 5)
		local after = window.state().texts[1]
		check(deleted and after == "ab" and Injector.caret_steps(text) - Injector.caret_steps(after) == 1,
			string.format("GTK deletes %s whole, one injector caret step (left %q)", case[1], tostring(after)))
	end

	print("--- the injector erases characters whole ---")
	local typed = ""
	for _, case in ipairs(CLUSTERS) do typed = typed .. case[2] end
	result = Injector.inject(Injector.caret_steps(typed), "ok", false, nil, prepare(0, { "A" .. typed, "", "" }))
	check(fields_read(result, { "Aok", "", "" }, 0),
		"erasing four multi-code-point characters removes them and nothing before them")
	check(clipboard_kept(), "the clipboard's previous text is still in place")
end

local ran, err = xpcall(run, debug.traceback)
if not ran then
	failures = failures + 1
	print("  FAIL the flow raised: " .. tostring(err))
end
check(privacy.stop(), "the privacy owner retires its native resources")
window.stop()
check(checks == EXPECTED_CHECKS, string.format("every check ran (%d of %d)", checks, EXPECTED_CHECKS))
print(string.format("=== %d check(s), %d failure(s) ===", checks, failures))
os.exit(failures == 0 and 0 or 1)
