--- tests/unit/adapters/synthetic_input/test_one_shot_shift.lua

--- ==============================================================================
--- MODULE: One-shot Shift Native Boundary Tests
--- DESCRIPTION:
--- Uses an explicit keyboard-translation double to exercise flag preservation,
--- Unicode serialization, native-repeat selection and failure ownership. Real
--- Quartz translation is covered by the launcher CI probe.
--- ==============================================================================

local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")
local data = assert(require("json").decode(SourceFile.read(helpers.shared("tap_hold/one_shot_shift.json"))))

local function fixture()
	local text_by_key = { [0] = { "a", "A" }, [1] = { "é", "2" }, [2] = { " ", " " }, [3] = { "b", "B" } }
	local calls = { emitted = {}, allowed = true }
	-- repeat_flag mirrors keyboardEventAutorepeat: 1 for a native auto-repeat.
	local function event(code, flags, override, repeat_flag)
		local raw, unicode = flags or 0, override
		return {
			autorepeat = repeat_flag or 0,
			getKeyCode = function() return code end,
			getFlags = function() return { cmd = (raw & 4) ~= 0, ctrl = (raw & 8) ~= 0, alt = (raw & 16) ~= 0 } end,
			rawFlags = function(_, value) if value ~= nil then raw = value end; return raw end,
			getCharacters = function()
				if unicode ~= nil then return unicode end
				local choices = text_by_key[code]
				return choices and choices[(raw & 2) ~= 0 and 2 or 1] or ""
			end,
			setUnicodeString = function(_, value) unicode = value end,
		}
	end
	package.loaded["adapters.one_shot_shift"] = nil
	local adapter = require("adapters.one_shot_shift").new({
		data = data, magic = function() return "★" end, now = function() return 10 end,
		event = { rawFlagMasks = { shift = 2 } },
		translate = function(code, flags) return event(code, flags):getCharacters(false) end,
		is_repeat = function(e) return e.autorepeat ~= 0 end,
		emit = function(text)
			if not calls.allowed then return false end
			calls.emitted[#calls.emitted + 1] = text
			return true
		end,
	})
	return adapter, event, calls
end

helpers.describe("one-shot native boundary", function()
	-- The generated punctuation of a one-shot Shift reaches the CapsWord output
	-- observer once its returned events are handed off, so a space-only CapsWord
	-- ends on " :" though the physical "." keeps it (one-shot-capsword-relay).
	helpers.it("relays the serialized result to the CapsWord observer on handoff (one-shot-capsword-relay)", function()
		local CapsWordOutput = require("infra.capsword_output")
		local Policy = require("caps_word.auto_off")
		local reported = {}
		helpers.assert_true(CapsWordOutput.set_observer(function(text) reported[#reported + 1] = text end))
		local ok, err = pcall(function()
			local text = "."
			local event = {
				getFlags = function() return {} end,
				rawFlags = function() return 0 end,
				getCharacters = function() return text end,
				setUnicodeString = function(_, value) text = value end,
			}
			local emitted = {}
			package.loaded["adapters.one_shot_shift"] = nil
			local adapter = require("adapters.one_shot_shift").new({
				data = data, magic = function() return "★" end, now = function() return 10 end,
				event = { rawFlagMasks = { shift = 2 } }, is_repeat = function() return false end,
				translate = function(_, flags) return flags == 0 and "." or ":" end,
				emit = function(value) emitted[#emitted + 1] = value; return true end,
			})
			adapter.arm(2)
			helpers.assert_true(adapter.key_down(event, 47), "the special result is serialized")
			helpers.assert_eq(#reported, 0, "nothing is reported before the handoff settles")
			adapter.finish(true)
			helpers.assert_eq(emitted, { " :" })
			helpers.assert_eq(reported, { " :" }, "the CapsWord observer sees the generated text")
			local space_only = assert(Policy.compile({ idle_timeout_seconds = 0, terminators = { "space" },
				pointer = { left_click = false } }, { "left_click" }))
			helpers.assert_true(Policy.ends_on_text(space_only, reported[1]), "the generated \" :\" ends a space-only CapsWord")
			helpers.assert_eq(Policy.ends_on_text(space_only, "."), false, "control: the physical \".\" does not")
			adapter.arm(2)
			helpers.assert_true(adapter.key_down(event, 47))
			adapter.finish(false)
			helpers.assert_eq(#reported, 1, "a refused handoff reports nothing")
		end)
		CapsWordOutput.set_observer(nil)
		if not ok then error(err, 0) end
	end)
	helpers.it("checks the actual shifted Option combination before native emission (one-shot-option-shift)", function()
		local emitted, raw, text = {}, 16, "é"
		local event = {
			getFlags = function() return { alt = true } end,
			rawFlags = function(_, value) if value ~= nil then raw = value end; return raw end,
			getCharacters = function() return text end,
			setUnicodeString = function(_, value) text = value end,
		}
		local adapter = require("adapters.one_shot_shift").new({
			data = data, magic = function() return "★" end, now = function() return 10 end,
			event = { rawFlagMasks = { shift = 2 } }, is_repeat = function() return false end,
			translate = function(_, flags) return ({ [16] = "é", [2] = "É", [18] = "Ω" })[flags] end,
			emit = function(value) emitted[#emitted + 1] = value; return true end,
		})
		adapter.arm(2)
		helpers.assert_true(adapter.key_down(event, 1), "different Option+Shift output needs Unicode emission")
		adapter.finish(true)
		helpers.assert_eq(emitted, { "É" })
	end)
	helpers.it("serializes the title when Caps Lock plus Shift would produce lowercase (one-shot-caps-lock, OSM-001)", function()
		local CAPS, SHIFT = 65536, 2
		local layout = { [0] = "a", [CAPS] = "A", [SHIFT] = "A", [CAPS | SHIFT] = "a" }
		local function build(held, captured)
			local emitted, raw, text = {}, held, captured or layout[held]
			local event = {
				getFlags = function() return {} end,
				rawFlags = function(_, value) if value ~= nil then raw = value end; return raw end,
				getCharacters = function() return text end,
				setUnicodeString = function(_, value) text = value end,
			}
			local adapter = require("adapters.one_shot_shift").new({
				data = data, magic = function() return "★" end, now = function() return 10 end,
				event = { rawFlagMasks = { shift = SHIFT } }, is_repeat = function() return false end,
				translate = function(_, flags) return layout[flags] end,
				emit = function(value) emitted[#emitted + 1] = value; return true end,
			})
			adapter.arm(2)
			return adapter, event, emitted, function() return raw end
		end
		-- The audit's capture: the key read as "a" while Caps Lock is held. Shift on
		-- top would type "a" again, so the title is serialized.
		local adapter, event, emitted, flags = build(CAPS, "a")
		helpers.assert_true(adapter.key_down(event, 0), "the key is replaced by the serialized title")
		adapter.finish(true)
		helpers.assert_eq(emitted, { "A" }, "the first letter is a capital under Caps Lock")
		helpers.assert_eq(flags(), CAPS, "the physical Caps Lock flag is not stripped")
		-- Control: no Caps Lock, Shift alone is the title and stays a native flag.
		adapter, event, emitted, flags = build(0)
		helpers.assert_eq(adapter.key_down(event, 0), false, "an ordinary key gets the native Shift flag")
		adapter.finish(true)
		helpers.assert_eq(emitted, {})
		helpers.assert_eq(flags(), SHIFT)
	end)
	helpers.it("keeps native translation probes private to the synthetic adapter (one-shot-probe)", function()
		helpers.with_stub_scope({ "adapters.synthetic_input", "adapters.event_provenance", "tests.stubs.hs" }, function()
			package.loaded["adapters.synthetic_input"] = nil
			package.loaded["tests.stubs.hs"] = nil
			local eventtap = require("tests.stubs.hs").eventtap
			local probes = 0
			eventtap.event.newKeyEvent = function(modifiers, code, down)
				probes = probes + 1
				helpers.assert_eq(modifiers, {})
				helpers.assert_eq(code, 0)
				helpers.assert_true(down)
				local flags
				return {
					rawFlags = function(_, value) flags = value end,
					getCharacters = function(_, ignore)
						helpers.assert_eq(ignore, false)
						return flags == 2 and "A" or "a"
					end,
					post = function() error("a translation probe must never be posted") end,
				}
			end
			local synthetic = helpers.load_with_stubs("adapters.synthetic_input", { eventtap = eventtap })
			helpers.assert_eq(synthetic.keyboard_characters(0, 2), "A")
			helpers.assert_eq(synthetic.keyboard_characters(0, 0), "a")
			helpers.assert_eq(probes, 2, "every translation must use a fresh private event")
		end)
	end)
	helpers.it("keeps command shortcuts intact without excluding printable Option input (one-shot-shortcut)", function()
		for _, flags in ipairs({ 4, 8 }) do
			local adapter, event = fixture()
			adapter.arm(2)
			local shortcut = event(0, flags)
			helpers.assert_eq(adapter.key_down(shortcut, 0), false)
			adapter.finish(true)
			helpers.assert_eq(shortcut:rawFlags(), flags)
			local next_key = event(0)
			adapter.key_down(next_key, 0)
			adapter.finish(true)
			helpers.assert_eq(next_key:getCharacters(false), "A")
		end
		local adapter, event, calls = fixture()
		adapter.arm(2)
		helpers.assert_true(adapter.key_down(event(1, 16), 1))
		adapter.finish(true)
		helpers.assert_eq(calls.emitted, { "É" })
	end)
	helpers.it("rolls back only the provisional key when callback handoff fails (one-shot-handoff)", function()
		local adapter, event = fixture()
		adapter.arm(2)
		helpers.assert_true(adapter.key_down(event(1), 1))
		adapter.finish(true)
		adapter.arm(2)
		helpers.assert_true(adapter.key_down(event(2), 2))
		adapter.finish(false)
		helpers.assert_true(adapter.claim_repeat(event(1, 0, nil, 1)), "the earlier accepted owner must survive")
		helpers.assert_eq(adapter.claim_repeat(event(2)), false)
		helpers.assert_eq(adapter.key_up(event(2), 2), false)
		adapter.arm(2)
		local original = event(0, 128)
		adapter.key_down(original, 0)
		adapter.finish(false)
		helpers.assert_eq(original:rawFlags(), 128)
		helpers.assert_eq(original:getCharacters(false), "a")
	end)
	helpers.it("preserves unrelated flags and native repetition until the original release (one-shot-native)", function()
		local adapter, event, calls = fixture()
		adapter.arm(2)
		for press = 1, 2 do
			-- The second key-down is the native auto-repeat of the first.
			local key = event(0, 128, nil, press - 1)
			helpers.assert_eq(adapter.key_down(key, 0), false)
			adapter.finish(true)
			helpers.assert_eq(key:rawFlags(), 130)
			helpers.assert_eq(key:getCharacters(false), "A")
		end
		-- A key rolled in while the shifted one is still down is not shifted
		-- (one-shot-roll): the Shift is that press's own, not a held Shift.
		local other = event(3)
		adapter.key_down(other, 3)
		adapter.finish(true)
		helpers.assert_eq(other:getCharacters(false), "b")
		helpers.assert_eq(other:rawFlags(), 0)
		local released = event(0, 128)
		adapter.key_up(released, 0)
		helpers.assert_eq(released:rawFlags(), 130, "the shifted press is released under its own Shift")
		other = event(3)
		adapter.key_down(other, 3)
		helpers.assert_eq(other:getCharacters(false), "b")
		helpers.assert_eq(#calls.emitted, 0)
	end)
	helpers.it("serializes an unavailable capital once and swallows its repeats and release (one-shot-native)", function()
		local adapter, event, calls = fixture()
		adapter.arm(2)
		helpers.assert_true(adapter.key_down(event(1), 1))
		adapter.finish(true)
		helpers.assert_eq(calls.emitted, { "É" })
		adapter.disarm()
		helpers.assert_true(adapter.claim_repeat(event(1, 0, nil, 1)))
		helpers.assert_true(adapter.key_down(event(1, 0, nil, 1), 1))
		helpers.assert_eq(#calls.emitted, 1)
		helpers.assert_true(adapter.key_up(event(1), 1))
		helpers.assert_eq(adapter.claim_repeat(event(1, 0, nil, 1)), false)
	end)
	helpers.it("releases a transformed key with Shift after disarm (one-shot-disarm-native)", function()
		local adapter, event = fixture()
		adapter.arm(2)
		local pressed = event(0, 128)
		adapter.key_down(pressed, 0)
		adapter.finish(true)
		helpers.assert_eq(pressed:rawFlags(), 130)
		adapter.disarm()
		local released = event(0, 128)
		helpers.assert_eq(adapter.key_up(released, 0), false)
		helpers.assert_eq(released:rawFlags(), 130, "the release retains the press's Shift and unrelated flags")
	end)
	helpers.it("types a fresh press whose earlier release was missed (one-shot-stale-claim)", function()
		-- A tap outage lets a release pass unseen. The claim used to outlive it
		-- and swallow the next press of the same key without any output.
		local Integrity = require("infra.keystroke_integrity")
		Integrity.reset()
		local adapter, event, calls = fixture()
		adapter.arm(2)
		helpers.assert_true(adapter.key_down(event(1), 1))
		adapter.finish(true)
		helpers.assert_eq(calls.emitted, { "É" })
		local fresh = event(1)
		helpers.assert_eq(adapter.key_down(fresh, 1), false,
			"a fresh press of a key whose release was missed must reach the application")
		adapter.finish(true)
		helpers.assert_eq(fresh:getCharacters(false), "é")
		helpers.assert_eq(#calls.emitted, 1)
		helpers.assert_eq(adapter.key_up(event(1), 1), false)
		helpers.assert_true(Integrity.summary():find("stale_claim=1", 1, true) ~= nil)
		-- The same holds while paused, where only claim_repeat runs.
		adapter.arm(2)
		helpers.assert_true(adapter.key_down(event(1), 1))
		adapter.finish(true)
		helpers.assert_eq(adapter.claim_repeat(event(1)), false)
		helpers.assert_eq(adapter.claim_repeat(event(1, 0, nil, 1)), false)
	end)
	helpers.it("drops a missed Shift release at the key's next fresh press (one-shot-stale-claim)", function()
		local adapter, event = fixture()
		adapter.arm(2)
		adapter.key_down(event(0), 0)
		adapter.finish(true)
		local fresh = event(0)
		helpers.assert_eq(adapter.key_down(fresh, 0), false)
		adapter.finish(true)
		helpers.assert_eq(fresh:getCharacters(false), "a",
			"a stale Shift claim must not capitalize the next press")
		local other = event(3)
		adapter.key_down(other, 3)
		helpers.assert_eq(other:getCharacters(false), "b")
	end)
	helpers.it("does not invent physical Shift for an IME or explicit Unicode event (one-shot-native)", function()
		local adapter, event, calls = fixture()
		adapter.arm(2)
		helpers.assert_true(adapter.key_down(event(0, 0, "é"), 0))
		helpers.assert_eq(calls.emitted, { "É" })
	end)
	helpers.it("cannot claim a press when the serializer refuses its output (one-shot-native)", function()
		local adapter, event, calls = fixture()
		adapter.arm(2)
		calls.allowed = false
		local ok, detail = pcall(adapter.key_down, event(2), 2)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(detail):find("emission was refused", 1, true) ~= nil)
		helpers.assert_eq(adapter.key_up(event(2), 2), false)
	end)
end)
