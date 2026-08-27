--- tests/unit/meta/test_toml_codec_shared_decode.lua

--- ==============================================================================
--- MODULE: Shared TOML Codec Decode Guard (Linux)
--- DESCRIPTION:
--- Regression guard ensuring the kanata and dynamic_hotstrings managers parse
--- their TOML through the shared toml_codec.decode() API rather than a bespoke
--- mini-parser. The bug this locks down: both managers guarded their "shared
--- codec" branch on toml_codec.parse — a function that never existed (the real
--- API is decode) — so the branch was dead and a hand-rolled parser ran instead.
---
--- WHAT WE CHECK:
--- 1. Behaviour: a value containing a '#' inside a quoted string survives, which
---    only the real TOML decoder does; the old bespoke parser stripped it as an
---    inline comment. This is RED before the fix, GREEN after.
--- 2. Delegation: neither manager references the non-existent .parse API nor
---    keeps a bespoke section-walking parser, so the fork cannot silently return.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe     = helpers.describe
local it           = helpers.it
local assert_true  = helpers.assert_true
local assert_eq    = helpers.assert_eq
local assert_nil   = helpers.assert_nil

local codec = require("toml_codec")

local DRIVER_ROOT = helpers.driver_root()

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return "" end
	local s = fh:read("*a")
	fh:close()
	return s
end





-- ===========================================
-- ===========================================
-- ======= 1/ Behavioural decode guard =======
-- ===========================================
-- ===========================================

describe("shared toml_codec.decode is live in the managers", function()

	it("recognizes the first section after a UTF-8 BOM", function()
		local bom = string.char(0xEF, 0xBB, 0xBF)
		local got = codec.decode(bom .. '[info]\nfirst_name = "Ada"\n')
		assert_true(type(got) == "table" and type(got.info) == "table",
			"the shared Linux codec must recognize a BOM-prefixed first section")
		assert_eq(got.info.first_name, "Ada")
	end)

	it("rejects scalar-table collisions without raising", function()
		local sources = {
			'tap_hold = "oops"\n[tap_hold.keys]\na = 1\n',
			'a = 1\n[[a]]\nx = 1\n',
		}

		for index, source in ipairs(sources) do
			local ok, got = pcall(codec.decode, source)
			assert_true(ok,
				"shared codec collision #" .. index .. " must return nil, not raise: " .. tostring(got))
			assert_nil(got, "shared codec collision #" .. index .. " must fail closed")
		end
	end)

	it("preserves heterogeneous arrays with typed values", function()
		local decoded = codec.decode('ids = ["a", 1, true]\n')

		assert_true(type(decoded) == "table", "mixed arrays are valid TOML")
		assert_eq(#decoded.ids, 3, "every mixed-array value must survive")
		assert_eq(type(decoded.ids[1]), "string", "first value keeps its string type")
		assert_eq(decoded.ids[1], "a", "first value keeps its exact content")
		assert_eq(type(decoded.ids[2]), "number", "second value keeps its number type")
		assert_eq(decoded.ids[2], 1, "second value keeps its exact content")
		assert_eq(type(decoded.ids[3]), "boolean", "third value keeps its boolean type")
		assert_eq(decoded.ids[3], true, "third value keeps its exact content")
	end)

	it("decodes TOML numeric forms with their numeric type", function()
		local vectors = {
			{ literal = "1_000", expected = 1000 },
			{ literal = "0xFF", expected = 255 },
			{ literal = "0o17", expected = 15 },
			{ literal = "0b1010", expected = 10 },
			{ literal = "1.0e3", expected = 1000 },
			{ literal = "1_2.3_4e2", expected = 1234 },
		}

		for _, vector in ipairs(vectors) do
			local decoded = codec.decode("value = " .. vector.literal .. "\n")
			assert_true(type(decoded) == "table", "numeric literal must decode: " .. vector.literal)
			assert_eq(type(decoded.value), "number",
				"shared codec must preserve the numeric type: " .. vector.literal)
			assert_eq(decoded.value, vector.expected,
				"shared codec numeric value mismatch: " .. vector.literal)
		end
	end)

	it("enforces Unicode scalar values while preserving escaped U+0000", function()
		local invalid = {
			'key = "\\uD800"\n',
			'key = "\\uDFFF"\n',
			'key = "\\uD83D\\uDE00"\n',
			'key = "\\U00110000"\n',
		}

		for index, source in ipairs(invalid) do
			local ok, got = pcall(codec.decode, source)
			assert_true(ok, "invalid scalar #" .. index .. " must not raise")
			assert_nil(got, "invalid scalar #" .. index .. " must fail closed")
		end

		local got = codec.decode(
			'below = "\\uD7FF"\nabove = "\\uE000"\nmaximum = "\\U0010FFFF"\nnull = "\\u0000value"\n')
		assert_true(type(got) == "table", "valid scalar boundaries must decode")
		assert_eq(got.below, "\xED\x9F\xBF")
		assert_eq(got.above, "\xEE\x80\x80")
		assert_eq(got.maximum, "\xF4\x8F\xBF\xBF")
		assert_eq(#got.null, 6, "escaped U+0000 must remain part of the string")
		assert_eq(got.null:byte(1), 0)
		assert_eq(got.null:sub(2), "value")
	end)

	it("preserves array-of-table structure and rejects duplicate definitions", function()
		assert_nil(codec.decode('t = { x = 1, "x" = 2 }\n'),
			"normalized inline-table duplicates must fail closed")

		local got = codec.decode([==[
[[a]]
x = 1
[a.b]
y = 10
[[a]]
x = 2
[a.b]
y = 20
]==])
		assert_true(type(got) == "table", "valid AOT children must decode")
		assert_eq(#got.a, 2)
		assert_eq(got.a[1].b.y, 10)
		assert_eq(got.a[2].b.y, 20)
		assert_eq(got.a.b, nil, "the AOT container must not receive child fields")

		local conflicts = {
			'[a]\nx = 1\n[[a]]\ny = 2\n',
			'[[a]]\nx = 1\n[a]\ny = 2\n',
			'a = []\n[[a]]\nx = 1\n',
		}
		for index, source in ipairs(conflicts) do
			local ok, decoded = pcall(codec.decode, source)
			assert_true(ok, "AOT conflict #" .. index .. " must not raise")
			assert_nil(decoded, "AOT conflict #" .. index .. " must fail closed")
		end
	end)

	it("dynamic_hotstrings preserves a '#' inside a quoted value (decode, not bespoke strip)", function()
		local dh = helpers.load_module("modules.dynamic_hotstrings.manager")

		-- A '#' inside a quoted string is data, not a comment. The bespoke
		-- fallback parser strips everything after the first '#' (even inside
		-- quotes), truncating the value; the shared TOML decoder keeps it.
		local tmp = DRIVER_ROOT .. "/tests/_tmp_shared_decode_hash.toml"
		local fh = io.open(tmp, "w")
		assert_true(fh ~= nil, "could not create temp personal_info.toml")
		fh:write('[info]\nemail_address = "a#b@example.com"\nfirst_name = "Zoe"\n\n[letters]\np = "first_name"\n')
		fh:close()

		dh.init({ trigger_char = "\\", personal_info_path = tmp })
		local info = dh.get_info()
		os.remove(tmp)

		assert_eq(info.email_address, "a#b@example.com",
			"a '#' inside a quoted value must survive — proves decode() runs, not the bespoke '#'-strip parser")
	end)

end)





-- ===========================================
-- ===========================================
-- ======= 2/ Source delegation guards =======
-- ===========================================
-- ===========================================

describe("managers delegate TOML parsing to the shared codec", function()

	local kanata_src  = read_file(DRIVER_ROOT .. "/platform/remap/manager.lua")
	local dynamic_src = read_file(DRIVER_ROOT .. "/modules/dynamic_hotstrings/manager.lua")

	it("kanata manager calls .decode and drops the bespoke parser", function()
		assert_true(kanata_src:find(".decode(", 1, true) ~= nil,
			"kanata manager must call toml_codec .decode().")
		assert_true(kanata_src:find("toml_codec.parse", 1, true) == nil,
			"kanata manager still references the non-existent toml_codec.parse API.")
		assert_true(kanata_src:find("parse_simple_toml", 1, true) == nil,
			"kanata manager still defines the bespoke parse_simple_toml parser.")
	end)

	it("dynamic_hotstrings manager calls .decode and drops the bespoke parser", function()
		assert_true(dynamic_src:find(".decode(", 1, true) ~= nil,
			"dynamic_hotstrings manager must call toml_codec .decode().")
		assert_true(dynamic_src:find("toml_codec.parse", 1, true) == nil,
			"dynamic_hotstrings manager still references the non-existent toml_codec.parse API.")
		assert_true(dynamic_src:find("current_section", 1, true) == nil,
			"dynamic_hotstrings manager still runs the bespoke section-walking parser.")
	end)

end)




-- ==============================================
-- ==============================================
-- ======= 3/ Multi-line array decoding =========
-- ==============================================
-- ==============================================

describe("toml_codec.decode parses multi-line arrays", function()

	-- The decoder used to skip any array whose brackets did not close on the
	-- same line, returning an empty table. The gesture slot-space, the picker
	-- order and any hand-authored list are written as multi-line arrays, so the
	-- daemon could never derive them from the shared TOML. These guards keep the
	-- accumulator alive: RED before the fix (every array decodes to n=0).

	it("populates a multi-line string array spanning several lines", function()
		local t = codec.decode('[slots]\nsingle = [\n\t"tap_2", "tap_3",\n\t"swipe_2_left",\n]\n')
		assert_true(t ~= nil, "decode returned nil on a valid multi-line array")
		assert_eq(#t.slots.single, 3, "multi-line array must keep every element")
		assert_eq(t.slots.single[1], "tap_2", "first element preserved")
		assert_eq(t.slots.single[3], "swipe_2_left", "last element preserved")
	end)

	it("keeps a '#' inside a quoted element of a multi-line array", function()
		local t = codec.decode('[s]\nx = [\n\t"a#b",\n\t"c",\n]\n')
		assert_eq(t.s.x[1], "a#b", "a '#' inside a quoted array element is data, not a comment")
	end)

	it("ignores blank lines and inline comments between elements", function()
		local t = codec.decode('[s]\nx = [\n\t"a",  # first\n\n\t"b",\n]\nz = 5\n')
		assert_eq(#t.s.x, 2, "blank lines and inline comments must not corrupt the array")
		assert_eq(t.s.z, 5, "the key after the array must still decode")
	end)

	it("still parses inline (single-line) arrays unchanged", function()
		local t = codec.decode('[s]\nx = ["a", "b", "c"]\ny = [1, 2, 3]\n')
		assert_eq(#t.s.x, 3, "inline string array unaffected by the multi-line path")
		assert_eq(t.s.y[3], 3, "inline number array still coerces element types")
	end)

	it("rejects an unterminated multi-line array as malformed", function()
		assert_nil(codec.decode('[s]\nx = [\n\t"a",\n'),
			"an array whose bracket never closes is invalid TOML and must decode to nil")
	end)

	it("rejects a key redeclared after a multi-line array", function()
		assert_nil(codec.decode('[s]\nx = [\n"a",\n]\nx = 1\n'),
			"a duplicate key must still be detected when the first value is a multi-line array")
	end)

end)
