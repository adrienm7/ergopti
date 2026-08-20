--- tests/unit/meta/test_chord_notation.lua

--- ==============================================================================
--- MODULE: Chord Notation Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Runs the shared chord corpus (_shared/lua/chord/vectors.json) against the
--- shared notation core. The AutoHotkey driver runs the SAME file against its own
--- twin (windows/tests/meta/test_chord_notation.ahk), which is the only thing that
--- makes "one notation, two implementations" a fact rather than an intention: a
--- chord that canonicalises differently on two drivers means one config file
--- produces two different bindings.
---
--- COVERAGE:
--- 1. Corpus integrity — the file is readable, holds all three sections, and none
---    is empty. A corpus that shrank to nothing would let every case below pass
---    while testing nothing.
--- 2. canonicalize — every accepted spelling maps to its one canonical label.
--- 3. rejects — every malformed chord is refused with a reason, never accepted as
---    a half-chord that would bind to nothing and report success.
--- 4. equals — two spellings of one chord compare equal; different chords do not;
---    an unparseable chord is not even equal to itself.
--- ==============================================================================

local helpers = require("tests.helpers")
local json    = require("json")
local Chord   = require("chord")





-- ======================================
-- ======================================
-- ======= 1/ Corpus File Loading =======
-- ======================================
-- ======================================

local CORPUS_PATH = helpers.shared("lua/chord/vectors.json")

--- Reads and decodes the shared chord corpus.
--- Fails loudly rather than skipping: a corpus that cannot be read must not let
--- the suite report success on zero vectors.
--- @return table The decoded corpus.
local function read_corpus()
	local fh = io.open(CORPUS_PATH, "r")
	assert(fh, "chord corpus not found at " .. CORPUS_PATH)
	local raw = fh:read("*a")
	fh:close()
	local decoded = json.decode(raw)
	assert(type(decoded) == "table", "chord corpus did not decode into a table")
	return decoded
end

local CORPUS = read_corpus()





-- ===================================
-- ===================================
-- ======= 2/ Corpus Integrity =======
-- ===================================
-- ===================================

helpers.describe("Chord corpus: integrity", function()
	helpers.it("holds all three sections, none of them empty", function()
		for _, section in ipairs({ "canonicalize", "rejects", "equals" }) do
			helpers.assert_eq(type(CORPUS[section]), "table",
				"corpus section '" .. section .. "' must be an array")
			helpers.assert_true(#CORPUS[section] > 0,
				"corpus section '" .. section .. "' is empty — every case below would pass vacuously")
		end
	end)

	helpers.it("every vector carries an id, so a failure names itself", function()
		local seen = {}
		for _, section in ipairs({ "canonicalize", "rejects", "equals" }) do
			for _, vector in ipairs(CORPUS[section]) do
				helpers.assert_eq(type(vector.id), "string",
					"a vector in '" .. section .. "' has no id")
				helpers.assert_true(not seen[vector.id],
					"duplicate vector id: " .. tostring(vector.id))
				seen[vector.id] = true
			end
		end
	end)
end)





-- ===================================
-- ===================================
-- ======= 3/ Canonicalisation =======
-- ===================================
-- ===================================

helpers.describe("Chord corpus: canonicalize", function()
	for _, vector in ipairs(CORPUS.canonicalize) do
		helpers.it(vector.id .. ": '" .. vector.input .. "' → '" .. vector.expect .. "'", function()
			local got, err = Chord.canonicalize(vector.input)
			helpers.assert_nil(err, "'" .. vector.input .. "' must parse: " .. tostring(err))
			helpers.assert_eq(got, vector.expect, "canonical spelling of '" .. vector.input .. "'")
		end)
	end

	helpers.it("canonicalisation is idempotent across the whole corpus", function()
		-- A canonical label that re-canonicalises to something else would mean the
		-- format is not a fixed point, so a value round-tripped through config.toml
		-- would drift a little further on every save.
		for _, vector in ipairs(CORPUS.canonicalize) do
			helpers.assert_eq(Chord.canonicalize(vector.expect), vector.expect,
				"re-canonicalising '" .. vector.expect .. "' changed it")
		end
	end)
end)





-- ============================
-- ============================
-- ======= 4/ Rejection =======
-- ============================
-- ============================

helpers.describe("Chord corpus: rejects", function()
	for _, vector in ipairs(CORPUS.rejects) do
		helpers.it(vector.id .. ": '" .. tostring(vector.input) .. "' is refused", function()
			local got, err = Chord.canonicalize(vector.input)
			helpers.assert_nil(got, "'" .. tostring(vector.input) .. "' must not canonicalise to " .. tostring(got))
			helpers.assert_eq(type(err), "string",
				"a refusal must carry a reason the caller can log, got " .. type(err))
			helpers.assert_true(#err > 0, "the refusal reason must not be empty")
		end)
	end

	helpers.it("non-string input is refused rather than coerced", function()
		-- A config reader that handed the parser a number must be told, not have
		-- its value silently stringified into a chord nobody asked for.
		for _, bad in ipairs({ 42, true, {} }) do
			local got, err = Chord.parse(bad)
			helpers.assert_nil(got, tostring(bad) .. " must not parse as a chord")
			helpers.assert_eq(type(err), "string", "and must carry a reason")
		end
	end)
end)





-- ===========================
-- ===========================
-- ======= 5/ Equality =======
-- ===========================
-- ===========================

helpers.describe("Chord corpus: equals", function()
	for _, vector in ipairs(CORPUS.equals) do
		helpers.it(vector.id .. ": '" .. vector.a .. "' vs '" .. vector.b .. "'", function()
			helpers.assert_eq(Chord.equals(vector.a, vector.b), vector.expect,
				"equality of '" .. vector.a .. "' and '" .. vector.b .. "'")
		end)
	end

	helpers.it("equality is symmetric", function()
		for _, vector in ipairs(CORPUS.equals) do
			helpers.assert_eq(Chord.equals(vector.b, vector.a), vector.expect,
				"swapping the operands of '" .. vector.id .. "' changed the answer")
		end
	end)
end)
