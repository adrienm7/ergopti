--- tests/hardware/run_shortcut_transforms_live.lua

--- ==============================================================================
--- MODULE: Case And Wrap Transforms Inside Real GTK Fields
--- DESCRIPTION:
--- Run by run_gtk_fields_live.sh on Xvfb with openbox and a private session
--- bus. The shortcuts manager (modules/shortcuts/manager.lua) runs its public
--- transforms with the daemon's real text owner: the metrics focus guard's
--- capture_text_owner over the resident AT-SPI watch, as ergopti_hotstrings.lua
--- passes it to shortcuts.init. The copy, the paste and the typed fallback go
--- through the production combo emitter, injector and clipboard adapter
--- (xclip); only the writer's last hop is XTest, since Xvfb reads no evdev
--- device. Every verdict is read back from the GTK fields themselves.
---
--- WHAT IT ASSERTS (flow review, Linux flow receiving):
--- 1. Case: a selected word with accents toggles to uppercase and back, a line
---    becomes title case and lowercase; only the selection changes and the
---    clipboard's previous text is put back.
--- 2. Wrap: a selection is wrapped in the pair; with nothing selected the pair
---    is typed at the caret.
--- 3. Refusal: in a password field nothing is retained, no key reaches the
---    wire, the field and the clipboard are untouched.
--- 4. Destination change: the focus moving to another field between the copy
---    and the paste stops the transform; neither field changes and the
---    clipboard is put back.
--- Exit 0 = every check held; 1 = a failure; 2 = no environment.
--- ==============================================================================

require("core.lifecycle.engine.compat.utf8").install()
if os.getenv("ERGOPTI_LIVE_DEBUG") then
	require("core.logger.engine").set_sink(function(line) io.stderr:write(line, "\n") end)
end

local EXPECTED_CHECKS = 17
local TITLE = "Ergopti shortcut transforms"
local FIELD, SECOND, PASSWORD = 0, 1, 2
-- linux/input-event-codes.h KEY_V: the paste chord's key.
local KEY_V = 47

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
local Shortcuts = require("modules.shortcuts.manager")

print("=== case and wrap transforms inside real GTK fields ===")
local wire = Session.xtest_wire()
local window = Session.open_window(TITLE, { "text", "text", "password" })
local privacy = Session.privacy_owner()
Shortcuts.init({ enabled = true, capture_text_owner = privacy.guard.capture_text_owner })

local SEED = "ERGOPTI-CLIPBOARD-BEFORE-TRANSFORMS"
assert(Clipboard.write(SEED), "the clipboard must be seeded")

--- Whether the clipboard still holds the seed.
local function clipboard_kept()
	local ok, text = Clipboard.read_checked()
	return ok and text == SEED
end

--- Focuses a field with its texts and selection, then joins its privacy context.
local function prepare(target, start, stop, texts, admitted)
	assert(window.control(target, start, stop, texts), "the fixture must focus field " .. target)
	assert(privacy.join(admitted ~= false), "the privacy owner must join field " .. target)
end

--- Waits until field `index` reads `expected`.
local function field_reads(index, expected)
	return window.wait_state(function(state) return state.texts[index + 1] == expected end, 5)
end

local function run()
	print("--- case ---")
	prepare(FIELD, 8, 13, { "bonjour élève", "", "SECRET" })
	check(Shortcuts.transform_uppercase() == true and field_reads(FIELD, "bonjour ÉLÈVE"),
		"the selected accented word toggles to uppercase, the rest of the field kept")
	check(clipboard_kept(), "the clipboard's previous text is put back")
	prepare(FIELD, 8, 13)
	check(Shortcuts.transform_uppercase() == true and field_reads(FIELD, "bonjour élève"),
		"the same toggle brings the uppercase word back to lowercase")
	prepare(FIELD, 0, -1, { "le petit chat", "", "SECRET" })
	check(Shortcuts.transform_to_titlecase() == true and field_reads(FIELD, "Le Petit Chat"),
		"the selected line becomes title case")
	prepare(FIELD, 0, -1, { "MIXED Case", "", "SECRET" })
	check(Shortcuts.transform_lowercase() == true and field_reads(FIELD, "mixed case"),
		"the selected line becomes lowercase")
	check(clipboard_kept(), "the clipboard's previous text is put back after every transform")

	print("--- wrap ---")
	prepare(FIELD, 4, 7, { "x = mot", "", "SECRET" })
	check(Shortcuts.wrap_selection("(", ")") == true and field_reads(FIELD, "x = (mot)"),
		"the selection is wrapped in the pair")
	check(clipboard_kept(), "the clipboard's previous text is put back after the wrap")
	prepare(FIELD, 3, 3, { "abc", "", "SECRET" })
	check(Shortcuts.wrap_selection("[", "]") == true and field_reads(FIELD, "abc[]"),
		"with nothing selected the pair is typed at the caret")

	print("--- refusal in a password field ---")
	prepare(PASSWORD, 0, -1, { "keep", "", "SECRET" }, false)
	local sent = #wire.events
	check(Shortcuts.transform_to_uppercase() == false, "the transform is refused in a password field")
	Session.settle(function() return false end, 0.5)
	check(#wire.events == sent and window.state().texts[PASSWORD + 1] == "SECRET",
		"no key reaches the wire and the password field is untouched")
	check(clipboard_kept(), "the clipboard is untouched by the refusal")

	print("--- destination change between the copy and the paste ---")
	prepare(FIELD, 4, 7, { "abc def", "other", "SECRET" })
	local original = privacy.guard.focused_text_identity()
	local press, moved, moved_at = ComboEmitter.press, false, nil
	ComboEmitter.press = function(combo, publication)
		local ok, outcome = press(combo, publication)
		if combo == "ctrl+c" and not moved then
			-- The user clicks another field while the copy settles.
			moved = window.control(SECOND, 5, 5) and Session.settle(function()
				privacy.guard.refresh(true)
				local now = privacy.guard.focused_text_identity()
				return now ~= nil and now ~= original
			end, 5)
			moved_at = #wire.events
		end
		return ok, outcome
	end
	local transformed = Shortcuts.transform_to_uppercase()
	ComboEmitter.press = press
	check(moved and transformed == false, "the focus moving to another field stops the transform")
	local pasted = false
	for index = (moved_at or #wire.events) + 1, #wire.events do
		if wire.events[index].code == KEY_V and wire.events[index].value == 1 then pasted = true end
	end
	check(moved_at ~= nil and not pasted, "no paste chord reaches the wire once the focus moved")
	Session.settle(function() return false end, 0.5)
	local state = window.state()
	check(state.texts[FIELD + 1] == "abc def" and state.texts[SECOND + 1] == "other",
		"neither the original field nor the newly focused one changes")
	check(clipboard_kept(), "the clipboard is put back after the stopped transform")
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
