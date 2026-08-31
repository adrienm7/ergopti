--- tests/unit/lib/test_toml_codec_edge_cases.lua

--- ==============================================================================
--- MODULE: TOML Codec Edge-Case Regression Tests
--- DESCRIPTION:
--- Regression tests for three codec bugs fixed together:
---
--- 1. F26 — Single-quote literal string with '#' inside was truncated.
---    The inline-comment stripper only tracked double-quoted regions, so
---    key = 'hello # world' was seen as key = 'hello (missing closing quote)
---    and rejected with PARSE_ERROR. Fix: track single-quoted regions too.
---
--- 2. F28 — \UXXXXXXXX escape with codepoint > 0x10FFFF caused utf8.char to
---    throw, crashing the decode. The original guard substituted U+FFFD.
---
--- 3. F51 — TOML special float literals inf / -inf / nan were treated as bare
---    strings instead of numbers. Fix: match them before the number patterns.
---
--- 4. HS-086 — A table header below a scalar either raised from navigation or
---    silently replaced the scalar for arrays of tables. Fix: reject both
---    collisions through the documented nil-return contract.
---
--- 5. HS-087 — Mixed-type arrays were rejected even though TOML 1.0 permits
---    heterogeneous values. Fix: preserve each independently coerced value.
---
--- 6. HS-088 — Valid numeric literals with separators, non-decimal bases, or
---    a fractional mantissa plus exponent fell through as bare strings. Fix:
---    validate the full TOML numeric grammar before converting the value.
---
--- 7. HS-089 — Surrogate escapes emitted invalid CESU-8 and out-of-range
---    escapes silently became U+FFFD. Fix: accept only Unicode scalar values,
---    while retaining escaped U+0000 as valid TOML data.
---
--- 8. HS-090 — Inline-table duplicates overwrote silently and table headers
---    below arrays of tables resolved against the array container instead of
---    its latest element. Fix: track structural kinds and declaration owners.
---
--- 9. HS-091 — Basic-string writers emitted raw C0/DEL bytes and the decoder's
---    sentinel substitutions corrupted escaped U+0001/U+0002. Fix: escape and
---    unescape basic-string bodies with one control-safe, single-pass codec.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec   = helpers.load_with_stubs("infra.toml.codec")


-- =====================================================================
-- =====================================================================
-- ======= 0/ UTF-8 BOM at the stream boundary =========================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: UTF-8 BOM", function()

	helpers.it("decodes the first section instead of leaking its values to root", function()
		local bom = string.char(0xEF, 0xBB, 0xBF)
		local got = codec.decode(bom .. '[info]\nname = "Ada"\n')
		helpers.assert_true(type(got) == "table", "a BOM-prefixed document must decode")
		helpers.assert_true(type(got.info) == "table",
			"the first BOM-prefixed section header must be recognized")
		helpers.assert_eq(got.info.name, "Ada")
		helpers.assert_eq(got.name, nil, "section values must not leak into the root table")
	end)

	helpers.it("preserves BOM bytes that are data rather than the stream prefix", function()
		local bom = string.char(0xEF, 0xBB, 0xBF)
		local got = codec.decode('[info]\nname = "A' .. bom .. 'B"\n')
		helpers.assert_eq(got.info.name, "A" .. bom .. "B",
			"only the exact stream-prefix BOM may be removed")
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 0b/ Scalar-table collisions fail closed =====================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: scalar-table collisions", function()

	helpers.it("returns nil instead of raising for a regular table header", function()
		local sources = {
			'tap_hold = "oops"\n[tap_hold.keys]\na = 1\n',
			'a = 1\n[a.b]\nx = 1\n',
			'a = true\n[a.b]\nx = 1\n',
		}

		for index, source in ipairs(sources) do
			local ok, got = pcall(codec.decode, source)
			helpers.assert_true(ok,
				"scalar/header collision #" .. index .. " must return nil, not raise: " .. tostring(got))
			helpers.assert_eq(got, nil,
				"scalar/header collision #" .. index .. " must fail closed")
		end
	end)

	helpers.it("returns nil instead of replacing a scalar with an array of tables", function()
		local sources = {
			'a = "oops"\n[[a]]\nx = 1\n',
			'a = 1\n[[a]]\nx = 1\n',
			'a = false\n[[a]]\nx = 1\n',
		}

		for index, source in ipairs(sources) do
			local ok, got = pcall(codec.decode, source)
			helpers.assert_true(ok,
				"scalar/AoT collision #" .. index .. " must return nil, not raise: " .. tostring(got))
			helpers.assert_eq(got, nil,
				"scalar/AoT collision #" .. index .. " must preserve the invalid-state signal")
		end
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 0c/ Heterogeneous arrays ====================================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: heterogeneous arrays", function()

	helpers.it("preserves each value with its TOML type", function()
		local decoded = codec.decode('ids = ["a", 1, true]\n')

		helpers.assert_true(type(decoded) == "table", "mixed arrays are valid TOML")
		helpers.assert_eq(#decoded.ids, 3, "every mixed-array value must survive")
		helpers.assert_eq(type(decoded.ids[1]), "string", "first value keeps its string type")
		helpers.assert_eq(decoded.ids[1], "a", "first value keeps its exact content")
		helpers.assert_eq(type(decoded.ids[2]), "number", "second value keeps its number type")
		helpers.assert_eq(decoded.ids[2], 1, "second value keeps its exact content")
		helpers.assert_eq(type(decoded.ids[3]), "boolean", "third value keeps its boolean type")
		helpers.assert_eq(decoded.ids[3], true, "third value keeps its exact content")
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 0c/ Structural definition ownership =========================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: structural definition ownership", function()

	helpers.it("rejects duplicate normalized keys inside inline tables", function()
		local sources = {
			't = { x = 1, x = 2 }\n',
			't = { x = 1, "x" = 2 }\n',
			't = { nested = { y = 1, y = 2 } }\n',
		}

		for index, source in ipairs(sources) do
			helpers.assert_eq(codec.decode(source), nil,
				"inline duplicate #" .. index .. " must reject the whole document")
		end
	end)

	helpers.it("attaches a regular child table to the latest array element", function()
		local got = codec.decode('[[a]]\nx = 1\n[a.b]\ny = 2\n')

		helpers.assert_true(type(got) == "table", "a child of an array element is valid TOML")
		helpers.assert_eq(#got.a, 1)
		helpers.assert_eq(got.a[1].x, 1)
		helpers.assert_eq(got.a[1].b.y, 2,
			"the child table must belong to the latest element")
		helpers.assert_eq(got.a.b, nil,
			"the array container must never masquerade as the latest element")
	end)

	helpers.it("owns repeated child paths independently for each array generation", function()
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

		helpers.assert_true(type(got) == "table", "each AOT element may define its own child table")
		helpers.assert_eq(#got.a, 2)
		helpers.assert_eq(got.a[1].b.y, 10)
		helpers.assert_eq(got.a[2].b.y, 20)
	end)

	helpers.it("supports nested arrays of tables under their latest parent element", function()
		local got = codec.decode([==[
[[fruits]]
name = "apple"
[[fruits.varieties]]
name = "red delicious"
[[fruits.varieties]]
name = "granny smith"
[[fruits]]
name = "banana"
[[fruits.varieties]]
name = "plantain"
]==])

		helpers.assert_true(type(got) == "table", "the canonical nested-AOT form must decode")
		helpers.assert_eq(#got.fruits, 2)
		helpers.assert_eq(#got.fruits[1].varieties, 2)
		helpers.assert_eq(got.fruits[1].varieties[1].name, "red delicious")
		helpers.assert_eq(got.fruits[1].varieties[2].name, "granny smith")
		helpers.assert_eq(#got.fruits[2].varieties, 1)
		helpers.assert_eq(got.fruits[2].varieties[1].name, "plantain")
	end)

	helpers.it("rejects conflicts between regular tables, arrays, and arrays of tables", function()
		local sources = {
			'[a]\nx = 1\n[[a]]\ny = 2\n',
			'[[a]]\nx = 1\n[a]\ny = 2\n',
			'a = []\n[[a]]\nx = 1\n',
			'a = { x = 1 }\n[a.b]\ny = 2\n',
			'[[a]]\n[[a.b]]\nx = 1\n[a.b]\ny = 2\n',
		}

		for index, source in ipairs(sources) do
			local ok, got = pcall(codec.decode, source)
			helpers.assert_true(ok, "structural conflict #" .. index .. " must not raise")
			helpers.assert_eq(got, nil,
				"structural conflict #" .. index .. " must fail closed")
		end
	end)

	helpers.it("still permits repeated headers for one array of tables", function()
		local got = codec.decode('[[a]]\nx = 1\n[[a]]\nx = 2\n')

		helpers.assert_true(type(got) == "table", "repeating an AOT header appends an element")
		helpers.assert_eq(#got.a, 2)
		helpers.assert_eq(got.a[1].x, 1)
		helpers.assert_eq(got.a[2].x, 2)
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 0d/ Basic-string control characters =========================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: basic-string control characters", function()

	helpers.it("escapes every C0 byte and DEL, then decodes the exact bytes", function()
		local bytes = {}
		for value = 0, 31 do bytes[#bytes + 1] = string.char(value) end
		bytes[#bytes + 1] = string.char(127)
		local source = table.concat(bytes)
		local encoded = codec.encode({ k = source })
		local body = encoded:match('\nk = "(.-)"\n')

		helpers.assert_true(type(body) == "string", "the encoded value must be inspectable")
		for index = 1, #body do
			local byte = body:byte(index)
			helpers.assert_true(byte > 31 and byte ~= 127,
				string.format("encoded basic string contains raw control byte 0x%02X", byte))
		end
		helpers.assert_contains(body, "\\u0000")
		helpers.assert_contains(body, "\\u0001")
		helpers.assert_contains(body, "\\u000B")
		helpers.assert_contains(body, "\\u001F")
		helpers.assert_contains(body, "\\u007F")

		local decoded = codec.decode(encoded)
		helpers.assert_true(type(decoded) == "table", "self-produced TOML must decode")
		helpers.assert_eq(decoded.k, source, "every control byte must round-trip exactly")
	end)

	helpers.it("rejects raw forbidden controls but accepts their Unicode escapes", function()
		local raw = 'k = "a' .. string.char(1) .. 'b"\n'
		helpers.assert_eq(codec.decode(raw), nil,
			"a raw C0 control must invalidate a TOML basic string")

		local decoded = codec.decode('k = "a\\u0001b\\u0002c"\n')
		helpers.assert_true(type(decoded) == "table", "escaped C0 controls are valid TOML")
		helpers.assert_eq(decoded.k,
			"a" .. string.char(1) .. "b" .. string.char(2) .. "c",
			"escaped controls must not collide with decoder sentinels")
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 0e/ TOML numeric literals ==================================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: numeric literal forms", function()

	helpers.it("decodes every supported TOML numeric form as a number", function()
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
			helpers.assert_true(type(decoded) == "table",
				"numeric literal must decode: " .. vector.literal)
			helpers.assert_eq(type(decoded.value), "number",
				"numeric literal must not fall through as a string: " .. vector.literal)
			helpers.assert_eq(decoded.value, vector.expected,
				"numeric literal has the wrong value: " .. vector.literal)
		end
	end)

	helpers.it("does not coerce malformed lookalikes by merely deleting underscores", function()
		local literals = { "+0xFF", "1__0", "_1", "1_", "0x_FF", "1_.0", "1._0", "1e_2" }

		for _, literal in ipairs(literals) do
			local decoded = codec.decode("value = " .. literal .. "\n")
			helpers.assert_eq(type(decoded.value), "string",
				"malformed numeric lookalike must retain the codec's bare-string fallback: " .. literal)
			helpers.assert_eq(decoded.value, literal,
				"malformed numeric lookalike must remain byte-exact: " .. literal)
		end
	end)

	helpers.it("round-trips the scientific notation emitted by the encoder", function()
		local encoded = codec.encode({ value = 1.5e-7 })
		local decoded = codec.decode(encoded)

		helpers.assert_eq(type(decoded.value), "number",
			"the codec must decode its own fractional-exponent output as a number")
		helpers.assert_eq(decoded.value, 1.5e-7,
			"scientific notation must round-trip without changing the value")
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 1/ Single-quoted strings with '#' inside ====================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: single-quoted string with hash character", function()

	helpers.it("preserves '#' inside a literal string value", function()
		local src = 'key = \'hello # world\'\n'
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil, "decode must succeed for literal string with '#'")
		helpers.assert_eq(got.key, "hello # world",
			"'#' inside single-quoted value must not be treated as comment delimiter")
	end)

	helpers.it("still strips trailing '#' comments outside quoted strings", function()
		local src = "key = 42 # this is a comment\n"
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil)
		helpers.assert_eq(got.key, 42, "comment outside string must be stripped")
	end)

	helpers.it("double-quoted strings with '#' still work", function()
		local src = 'key = "hello # world"\n'
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil)
		helpers.assert_eq(got.key, "hello # world")
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 2/ \U codepoint range validation ============================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: Unicode escape scalar values", function()

	helpers.it("valid \\U codepoint (U+1F600) decodes to the emoji", function()
		local src = 'key = "\\U0001F600"\n'
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil, "decode must succeed for valid \\U codepoint")
		-- U+1F600 = 😀
		helpers.assert_eq(got.key, "\xF0\x9F\x98\x80",
			"\\U0001F600 must decode to the emoji glyph")
	end)

	helpers.it("rejects surrogate escapes instead of emitting invalid CESU-8", function()
		local sources = {
			'key = "\\uD800"\n',
			'key = "\\uDFFF"\n',
			'key = "\\uD83D\\uDE00"\n',
		}

		for index, source in ipairs(sources) do
			local ok, got = pcall(codec.decode, source)
			helpers.assert_true(ok,
				"surrogate escape #" .. index .. " must return nil rather than raise")
			helpers.assert_eq(got, nil,
				"TOML escapes must be Unicode scalar values, not UTF-16 surrogate units")
		end
	end)

	helpers.it("rejects codepoints above U+10FFFF instead of silently replacing them", function()
		local ok, got = pcall(codec.decode, 'key = "\\U00110000"\n')

		helpers.assert_true(ok, "out-of-range escapes must fail closed without raising")
		helpers.assert_eq(got, nil,
			"an invalid Unicode scalar must not masquerade as a replacement character")
	end)

	helpers.it("accepts the scalar boundaries around the surrogate range", function()
		local got = codec.decode(
			'below = "\\uD7FF"\nabove = "\\uE000"\nmaximum = "\\U0010FFFF"\n')

		helpers.assert_true(type(got) == "table", "valid scalar boundaries must decode")
		helpers.assert_eq(got.below, "\xED\x9F\xBF", "U+D7FF must remain valid")
		helpers.assert_eq(got.above, "\xEE\x80\x80", "U+E000 must remain valid")
		helpers.assert_eq(got.maximum, "\xF4\x8F\xBF\xBF", "U+10FFFF must remain valid")
	end)

	helpers.it("preserves an escaped U+0000 as exact string data", function()
		local got = codec.decode('key = "\\u0000value"\n')

		helpers.assert_true(type(got) == "table", "an escaped null scalar is valid TOML")
		helpers.assert_eq(#got.key, 6, "the escaped null and trailing bytes must all survive")
		helpers.assert_eq(got.key:byte(1), 0, "the first decoded scalar must be U+0000")
		helpers.assert_eq(got.key:sub(2), "value", "the trailing value must remain byte-exact")
	end)

end)


-- =====================================================================
-- =====================================================================
-- ======= 3/ Non-finite float literals ================================
-- =====================================================================
-- =====================================================================

helpers.describe("toml_codec: non-finite float literals", function()

	helpers.it("inf decodes to math.huge", function()
		local got = codec.decode("v = inf\n")
		helpers.assert_true(got ~= nil)
		helpers.assert_true(got.v == math.huge, "inf must decode to math.huge")
	end)

	helpers.it("+inf decodes to math.huge", function()
		local got = codec.decode("v = +inf\n")
		helpers.assert_true(got ~= nil)
		helpers.assert_true(got.v == math.huge, "+inf must decode to math.huge")
	end)

	helpers.it("-inf decodes to -math.huge", function()
		local got = codec.decode("v = -inf\n")
		helpers.assert_true(got ~= nil)
		helpers.assert_true(got.v == -math.huge, "-inf must decode to -math.huge")
	end)

	helpers.it("nan decodes to a number (NaN ~= NaN)", function()
		local got = codec.decode("v = nan\n")
		helpers.assert_true(got ~= nil)
		-- NaN is the only Lua value not equal to itself
		helpers.assert_true(type(got.v) == "number" and got.v ~= got.v,
			"nan must decode to a Lua NaN value")
	end)

	helpers.it("inf and nan are not returned as strings", function()
		local got = codec.decode("a = inf\nb = nan\n")
		helpers.assert_true(got ~= nil)
		helpers.assert_true(type(got.a) == "number", "inf must be a number, not a string")
		helpers.assert_true(type(got.b) == "number", "nan must be a number, not a string")
	end)

end)





-- ======================================================================
-- ======================================================================
-- ======= 4/ Duplicate-section detection via quoted-key spelling =======
-- ======================================================================
-- ======================================================================

helpers.describe("toml_codec: duplicate section detection (F-LOW-3)", function()

	helpers.it("rejects [a] re-opened as [\"a\"]", function()
		-- F-LOW-3: seen_sections used to key off the RAW un-normalized header text
		-- ("a" vs '"a"'), so re-opening the same table through its quoted-key
		-- spelling bypassed the duplicate-section check entirely even though
		-- split_section_path()/nav() resolve both headers to the exact same table.
		local src = "[a]\nx = 1\n[\"a\"]\ny = 2\n"
		local got = codec.decode(src)
		helpers.assert_true(got == nil,
			"[a] followed by [\"a\"] must be rejected as a duplicate section, not silently merged")
	end)

	helpers.it("rejects [\"a\"] re-opened as [a]", function()
		-- Symmetric case: the quoted spelling declared FIRST, re-opened via the
		-- bare spelling second. The dedup key must be direction-independent.
		local src = "[\"a\"]\nx = 1\n[a]\ny = 2\n"
		local got = codec.decode(src)
		helpers.assert_true(got == nil,
			"[\"a\"] followed by [a] must be rejected as a duplicate section")
	end)

	helpers.it("still allows two genuinely distinct sections", function()
		-- Sanity-check companion: the fix must not become over-eager and reject
		-- unrelated sections that merely share a substring.
		local src = "[a]\nx = 1\n[ab]\ny = 2\n"
		local got = codec.decode(src)
		helpers.assert_true(got ~= nil, "distinct sections [a] and [ab] must both decode fine")
		helpers.assert_eq(got.a.x, 1)
		helpers.assert_eq(got.ab.y, 2)
	end)

	helpers.it("still rejects a genuine unquoted duplicate ([a] then [a])", function()
		-- Regression companion: the pre-existing (already-working) case must
		-- keep working after switching the dedup key to the resolved segments.
		local src = "[a]\nx = 1\n[a]\ny = 2\n"
		local got = codec.decode(src)
		helpers.assert_true(got == nil, "[a] followed by [a] must still be rejected as a duplicate")
	end)

end)





-- ==================================================================
-- ==================================================================
-- ======= 4/ Inline table containing a multi-element array =========
-- ==================================================================
-- ==================================================================

--- The inline-table splitter tracked quoted regions but NOT bracket depth, so a
--- comma inside a nested array split the pair list:
---
---     { key = "Left", mods = ["ctrl", "super"] }
---
--- became the three fragments `key = "Left"`, `mods = ["ctrl"` and `"super"]`.
--- The last two have no `=`, split_kv rejected them, and decode returned nil for
--- the WHOLE document — with no error, no line number and no clue.
---
--- A SINGLE-element nested array parsed correctly, which is what made the bug
--- invisible: the obvious smoke test passes. It surfaced only when a two-modifier
--- action (`ctrl + super`) was added to the shared action catalogue, and the
--- symptom was 14 Linux gesture tests failing for what looked like an unrelated
--- reason — the whole catalogue had stopped parsing.
---
--- Same shape as the logger sub-files bug: a scanner tracking quotes but not
--- nesting. Quotes alone are never enough when the delimiter being searched for
--- can also appear one level down.
helpers.describe("TOML codec — inline table with a nested multi-element array", function()

	helpers.it("keeps every element of a two-element nested array", function()
		local got = codec.decode('[a]\nemit = { key = "Left", mods = ["ctrl", "super"] }\n')
		helpers.assert_true(got ~= nil,
			"an inline table with a multi-element nested array must decode — it used to return nil "
			.. "for the entire document, with no error")
		helpers.assert_eq(got.a.emit.key, "Left", "the key preceding the nested array must survive")
		helpers.assert_eq(#got.a.emit.mods, 2, "both modifiers must survive the pair split")
		helpers.assert_eq(got.a.emit.mods[1], "ctrl")
		helpers.assert_eq(got.a.emit.mods[2], "super")
	end)

	helpers.it("keeps a three-element nested array", function()
		local got = codec.decode('[a]\ne = { k = "x", m = ["a", "b", "c"] }\n')
		helpers.assert_true(got ~= nil, "three elements must decode as readily as two")
		helpers.assert_eq(#got.a.e.m, 3)
		helpers.assert_eq(got.a.e.m[3], "c")
	end)

	helpers.it("keeps a nested inline table", function()
		-- Braces nest for the same reason brackets do; splitting on their commas
		-- would break the inner table in exactly the same way.
		local got = codec.decode('[a]\ne = { k = "x", n = { p = 1, q = 2 } }\n')
		helpers.assert_true(got ~= nil, "a nested inline table must decode")
		helpers.assert_eq(got.a.e.n.p, 1)
		helpers.assert_eq(got.a.e.n.q, 2)
	end)

	helpers.it("still does not split on a comma inside a string", function()
		-- The quote tracking the fix builds on must keep working: this is the
		-- case the original code got right.
		local got = codec.decode('[a]\ne = { k = "a,b", m = ["x"] }\n')
		helpers.assert_true(got ~= nil, "a comma inside a quoted value must not split the pair list")
		helpers.assert_eq(got.a.e.k, "a,b")
	end)

	helpers.it("still rejects a trailing comma before the closing brace", function()
		-- Depth tracking must not soften a rejection the codec already made.
		local got = codec.decode('[a]\ne = { k = "x", }\n')
		helpers.assert_true(got == nil, "a trailing comma in an inline table must still be rejected")
	end)

	helpers.it("decodes the shared action catalogue, which is what found this", function()
		-- The real document. A unit case can be satisfied by a fix that still
		-- fails on the file the bug was found in.
		local path = helpers.shared("modules/actions/actions.toml")
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "the shared action catalogue must be readable at " .. tostring(path))
		local raw = fh:read("*a")
		fh:close()
		local got = codec.decode(raw)
		helpers.assert_true(got ~= nil, "the shared action catalogue must decode")
		helpers.assert_true(type(got.sg_actions) == "table", "sg_actions must be present")
	end)

end)

helpers.describe("toml_codec: multiline strings remain data, never table syntax", function()
	helpers.it("decodes a multiline basic string without inventing sections", function()
		local source = [==[[llm]
app_profile_overrides = """
[features]
llm.enabled = false
"""
]==]
		local decoded = codec.decode(source)
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.llm.app_profile_overrides,
			"[features]\nllm.enabled = false\n")
		helpers.assert_nil(decoded.features,
			"a header-looking line inside a value must never become executable configuration")
	end)

	helpers.it("decodes a multiline literal string without inventing sections", function()
		local source = [==[[info]
note = '''
[letters]
p = "credit_card"
'''
]==]
		local decoded = codec.decode(source)
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.info.note, "[letters]\np = \"credit_card\"\n")
		helpers.assert_nil(decoded.letters)
	end)
end)

helpers.describe("toml_codec: literal strings protect array delimiters", function()
	helpers.it("keeps commas inside single-quoted array elements", function()
		local decoded = codec.decode(
			"[metrics.disabled_apps]\nlist = ['com.example,app', 'other']\n")
		helpers.assert_eq(decoded.metrics.disabled_apps.list,
			{ "com.example,app", "other" })
	end)

	helpers.it("keeps closing brackets inside multiline literal array elements", function()
		local decoded = codec.decode([==[[metrics.disabled_apps]
list = [
  'com.example]app',
  'other',
]
]==])
		helpers.assert_type(decoded, "table")
		helpers.assert_eq(decoded.metrics.disabled_apps.list,
			{ "com.example]app", "other" })
	end)
end)
