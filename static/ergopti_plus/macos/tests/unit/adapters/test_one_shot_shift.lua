--- tests/unit/adapters/test_one_shot_shift.lua

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
	local function event(code, flags, override)
		local raw, unicode = flags or 0, override
		return {
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
		emit = function(text)
			if not calls.allowed then return false end
			calls.emitted[#calls.emitted + 1] = text
			return true
		end,
	})
	return adapter, event, calls
end

helpers.describe("one-shot native boundary", function()
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
		helpers.assert_true(adapter.claim_repeat(event(1)), "the earlier accepted owner must survive")
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
		for _ = 1, 2 do
			local key = event(0, 128)
			helpers.assert_eq(adapter.key_down(key, 0), false)
			adapter.finish(true)
			helpers.assert_eq(key:rawFlags(), 130)
			helpers.assert_eq(key:getCharacters(false), "A")
		end
		local other = event(3)
		adapter.key_down(other, 3)
		adapter.finish(true)
		helpers.assert_eq(other:getCharacters(false), "B")
		adapter.key_up(event(0), 0)
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
		helpers.assert_true(adapter.claim_repeat(event(1)))
		helpers.assert_true(adapter.key_down(event(1), 1))
		helpers.assert_eq(#calls.emitted, 1)
		helpers.assert_true(adapter.key_up(event(1), 1))
		helpers.assert_eq(adapter.claim_repeat(event(1)), false)
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
