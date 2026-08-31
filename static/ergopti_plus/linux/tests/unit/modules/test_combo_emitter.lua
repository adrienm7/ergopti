--- tests/unit/modules/test_combo_emitter.lua

--- ==============================================================================
--- MODULE: Gesture Combos Resolve to Real Keycodes
--- DESCRIPTION:
--- The parse half of emitting a gesture's key combination through uinput.
---
--- WHY THIS EXISTS:
--- Every gesture action ran `xdotool key <combo>`, which is X11 only. Under
--- Wayland xdotool talks to nothing: the command succeeds, the shell exits zero,
--- and the gesture does nothing. There is no error to find, which is why the
--- defect survived — it looks exactly like an unbound slot.
---
--- WHAT THE LAST CASE IS FOR, AND WHY IT MATTERS MOST:
--- The keysym table maps the eighteen names the shared action catalogue actually
--- uses, not all of X11. That bound is only safe if something enforces it, so the
--- last case walks EVERY combo in the generated catalogue and requires it to
--- resolve. Add an action whose combo names a key the table lacks and the suite
--- says so — otherwise that one gesture would quietly do nothing, and quietly is
--- the whole problem here.
---
--- WHAT IS NOT TESTED: that a compositor acts on the chord. That needs a real
--- session and lives in HARDWARE.md.
--- ==============================================================================

local helpers = require("tests.helpers")

local Emitter = helpers.load_module("modules.gestures.combo_emitter")




-- =================================================================
-- =================================================================
-- ======= 1/ Reading a combo ======================================
-- =================================================================
-- =================================================================

helpers.describe("combo emitter: the parse", function()

	helpers.it("separates modifiers from the key they modify", function()
		local parsed = Emitter.parse("ctrl+Right")
		helpers.assert_true(parsed ~= nil, "a catalogue combo must parse")
		helpers.assert_eq(#parsed.mods, 1, "ctrl is the modifier")
		helpers.assert_eq(#parsed.keys, 1, "Right is the key")
		helpers.assert_eq(parsed.mods[1], 29, "KEY_LEFTCTRL")
		helpers.assert_eq(parsed.keys[1], 106, "KEY_RIGHT")
	end)

	helpers.it("handles more than one modifier", function()
		local parsed = Emitter.parse("ctrl+shift+Tab")
		helpers.assert_eq(#parsed.mods, 2, "both modifiers held")
		helpers.assert_eq(#parsed.keys, 1, "one key struck")
	end)

	helpers.it("maps the copy and paste chords used by selection transforms", function()
		local copy = Emitter.parse("ctrl+c")
		local paste = Emitter.parse("ctrl+v")
		helpers.assert_eq(copy.keys[1], 46, "KEY_C")
		helpers.assert_eq(paste.keys[1], 47, "KEY_V")
	end)

	helpers.it("names an unmapped key instead of swallowing it", function()
		local parsed, unknown = Emitter.parse("ctrl+Insert")
		helpers.assert_nil(parsed, "an unmapped name must not half-parse")
		helpers.assert_eq(unknown, "Insert",
			"the failure has to NAME the key: the symptom of a missing entry is one "
				.. "gesture that quietly does nothing, and a generic error would send "
				.. "the reader looking at the gesture rather than at the table")
	end)

	helpers.it("refuses a combo with no key to strike", function()
		helpers.assert_nil(Emitter.parse("ctrl+shift"),
			"holding modifiers and pressing nothing is not a chord")
		helpers.assert_nil(Emitter.parse(""))
		helpers.assert_nil(Emitter.parse(nil))
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The bound is enforced ================================
-- =================================================================
-- =================================================================

helpers.describe("combo emitter: every catalogue combo resolves", function()

	helpers.it("maps every key name the generated action table uses", function()
		-- The table covers what the catalogue uses rather than all of X11, and
		-- that is only defensible while something checks it. This is that check.
		local path = helpers.driver_root() .. "/_generated/gesture_emit_actions.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "the generated emit table must be readable")
		local source = fh:read("*a")
		fh:close()

		local seen, unresolved = 0, {}
		for combo in source:gmatch('=%s*"([^"]+)"') do
			-- Only strings that look like a chord; the file also carries ids.
			if combo:find("+", 1, true) or Emitter.KEYSYM_TO_CODE[combo] then
				seen = seen + 1
				local parsed, unknown = Emitter.parse(combo)
				if not parsed then unresolved[#unresolved + 1] = combo .. " (" .. tostring(unknown) .. ")" end
			end
		end

		helpers.assert_true(seen >= 10, string.format(
			"only %d combo(s) found in the generated table — the pattern has stopped "
				.. "matching and this check now proves nothing", seen))
		helpers.assert_eq(#unresolved, 0,
			"every combo the catalogue emits must resolve; unresolved: "
				.. table.concat(unresolved, ", "))
	end)

end)
