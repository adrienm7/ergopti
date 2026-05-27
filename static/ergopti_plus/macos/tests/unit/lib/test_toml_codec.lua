--- tests/unit/lib/test_toml_codec.lua

--- ==============================================================================
--- MODULE: TOML Codec Tests
--- DESCRIPTION:
--- Round-trip checks for lib/toml_codec — the generic encoder/decoder
--- behind ui/menu/preferences. Covers the structural shapes the HS state
--- actually uses: scalars, arrays, nested maps, special-character keys,
--- and the empty-table edge case.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec   = helpers.load_with_stubs("lib.toml_codec")

local function deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
	for k, v in pairs(b) do if not deep_equal(v, a[k]) then return false end end
	return true
end

local function rt(value)
	local encoded = codec.encode(value)
	local decoded = codec.decode(encoded)
	return decoded, encoded
end

helpers.describe("toml_codec — scalars round-trip", function()
	helpers.it("preserves strings, booleans and integers", function()
		local input = { name = "moyaux", enabled = true, paused = false, count = 42 }
		local got = rt(input)
		assert(deep_equal(got, input), "scalars must survive round-trip")
	end)

	helpers.it("encodes negative integers", function()
		local got = rt({ offset = -7 })
		assert(got.offset == -7)
	end)

	helpers.it("escapes special characters in strings", function()
		local input = { quote = 'he said "hi"', tab = "a\tb", newline = "a\nb" }
		assert(deep_equal(rt(input), input))
	end)
end)

helpers.describe("toml_codec — arrays round-trip", function()
	helpers.it("preserves arrays of strings", function()
		local input = { apps = { "chrome.exe", "firefox.exe" } }
		assert(deep_equal(rt(input), input))
	end)

	helpers.it("preserves arrays of integers", function()
		local input = { ports = { 80, 443, 8080 } }
		assert(deep_equal(rt(input), input))
	end)

	helpers.it("preserves an empty array", function()
		local input = { selected = {} }
		local got = rt(input)
		assert(type(got.selected) == "table")
		assert(#got.selected == 0)
	end)
end)

helpers.describe("toml_codec — nested maps round-trip", function()
	helpers.it("preserves single-level sections (HS hotstrings shape)", function()
		local input = { hotstrings = { autocorrection = true, magickey = false } }
		assert(deep_equal(rt(input), input))
	end)

	helpers.it("preserves two-level nesting (HS section_states shape)", function()
		local input = {
			section_states = {
				autocorrection = { ie = true, dot = false },
				magickey       = { star = true },
			},
		}
		assert(deep_equal(rt(input), input))
	end)

	helpers.it("preserves a structured shortcut record (mods + key)", function()
		local input = { metrics_shortcut = { mods = { "alt", "cmd" }, key = "m" } }
		assert(deep_equal(rt(input), input))
	end)
end)

helpers.describe("toml_codec — keys with special characters", function()
	helpers.it("quotes keys containing spaces", function()
		local input = { gestures = { ["Slot 1"] = "BackSpace", ["Slot 2"] = "CapsLock" } }
		assert(deep_equal(rt(input), input))
	end)

	helpers.it("preserves UTF-8 keys (accented characters)", function()
		-- Using bare octets to dodge any source-file encoding pitfall in
		-- the Lua loader; the codec should treat them as opaque bytes.
		local accented_key = "cat" .. string.char(0xC3, 0xA9) .. "gorie"  -- catégorie
		local input = { [accented_key] = true }
		local got = rt(input)
		assert(got[accented_key] == true)
	end)
end)

helpers.describe("toml_codec — coexistence of scalars and sub-maps", function()
	helpers.it("emits scalars before sub-maps in the same section", function()
		local input = {
			keylogger_enabled = true,
			trigger_char      = "★",
			section_states    = { autocorrection = { dot = false } },
			metrics_shortcut  = { mods = { "alt" }, key = "m" },
		}
		assert(deep_equal(rt(input), input))
	end)
end)

helpers.describe("toml_codec — deterministic output", function()
	helpers.it("produces identical bytes for identical input", function()
		local input = { z = 1, a = 2, m = { x = "x", a = "a" } }
		local _, e1 = rt(input)
		local _, e2 = rt(input)
		assert(e1 == e2, "two encodes of the same data must be byte-identical")
	end)
end)
