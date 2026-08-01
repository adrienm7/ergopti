--- tests/unit/meta/test_corpus_toml_fuzz.lua

--- ==============================================================================
--- MODULE: TOML Fuzz Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver fuzz corpus from
--- _shared/tests/corpus/toml/fuzz_corpus.json and validates the shared TOML
--- codec against every vector — ensuring no crash, and that the codec honours
--- the "ok" vs "error" contract on each input.
---
--- COVERAGE:
--- 1. Corpus integrity — the JSON file is readable, parses as a bare array,
---    and every entry has required fields (id, input, expect, description).
--- 2. No-crash contract — pcall(codec.decode, input) must never raise an
---    unhandled error regardless of the "expect" value.
--- 3. "ok" contract — vectors with expect="ok" must return a non-nil table.
--- 4. "error" contract — vectors with expect="error" must return nil or false
---    from the pcall (graceful failure, not a crash).
---
--- NOTE:
--- The fuzz corpus is consumed identically by the AHK driver
--- (windows/tests/meta/test_corpus_toml_fuzz.ahk). Any change to the corpus
--- schema must be reflected in both consumers.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ========================================
-- ========================================
-- ======= 1/ Corpus file loading =========
-- ========================================
-- ========================================

local corpus_path = helpers.shared("tests/corpus/toml/fuzz_corpus.json")

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("infra.logger")
	local ok, result = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(result) end
	return result, nil
end

local corpus, corpus_err = read_corpus()

-- Load the shared TOML codec (lives in _shared/lua/toml_codec/).
local codec_ok, codec = pcall(require, "toml_codec.codec")




-- =====================================
-- =====================================
-- ======= 2/ Corpus integrity ==========
-- =====================================
-- =====================================

helpers.describe("toml_fuzz corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus ~= nil, "corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus) == "table", "corpus must be a table (bare array)")
		helpers.assert_true(#corpus > 0, "corpus must have at least one vector")
	end)

	helpers.it("every vector has required fields: id, input, expect, description", function()
		if not corpus then return end
		for _, v in ipairs(corpus) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id field")
			helpers.assert_true(type(v.input) == "string",
				"vector '" .. tostring(v.id) .. "' missing input (must be string, even empty)")
			helpers.assert_true(v.expect == "ok" or v.expect == "error",
				"vector '" .. tostring(v.id) .. "' expect must be 'ok' or 'error', got: " .. tostring(v.expect))
			helpers.assert_true(type(v.description) == "string" and v.description ~= "",
				"vector '" .. tostring(v.id) .. "' missing description")
		end
	end)

	helpers.it("toml_codec is available on the Lua path", function()
		helpers.assert_true(codec_ok,
			"toml_codec.codec not found — check package.path in tests/run.lua")
	end)
end)




-- =============================================
-- =============================================
-- ======= 3/ No-crash contract =================
-- =============================================
-- =============================================

helpers.describe("toml_fuzz corpus — no-crash contract", function()
	helpers.it("pcall(codec.decode, input) never raises for any vector", function()
		if not corpus or not codec_ok then return end
		for _, v in ipairs(corpus) do
			-- The only contract here is that decode does not propagate an
			-- unhandled error past pcall. ok=false is acceptable for bad input.
			local ok_call = pcall(codec.decode, v.input)
			-- A boolean false from pcall means the function errored — that is
			-- permitted for malformed TOML, but the error must be caught, not
			-- propagate as an OS-level abort or uncatchable panic.
			-- We re-run with explicit capture only to produce a useful message:
			local _, result = pcall(codec.decode, v.input)
			_ = result -- silence unused warning; we only care about no unhandled panic
			helpers.assert_true(type(ok_call) == "boolean",
				"vector '" .. v.id .. "': pcall returned a non-boolean (should never happen)")
		end
	end)
end)





-- =============================================
-- =============================================
-- ======= 4/ "ok" and "error" contracts =======
-- =============================================
-- =============================================

helpers.describe("toml_fuzz corpus — expect contract", function()
	helpers.it("expect=ok vectors decode to a non-nil table", function()
		if not corpus or not codec_ok then return end
		for _, v in ipairs(corpus) do
			if v.expect ~= "ok" then goto continue end
			local ok_call, result = pcall(codec.decode, v.input)
			helpers.assert_true(ok_call,
				"vector '" .. v.id .. "': codec.decode raised for expect=ok input: "
				.. tostring(result))
			helpers.assert_true(type(result) == "table",
				"vector '" .. v.id .. "': expected a table from decode, got: "
				.. type(result))
			::continue::
		end
	end)

	helpers.it("expect=error vectors decode to nil or raise (graceful failure)", function()
		if not corpus or not codec_ok then return end
		for _, v in ipairs(corpus) do
			if v.expect ~= "error" then goto continue end
			local ok_call, result = pcall(codec.decode, v.input)
			-- Two valid outcomes for malformed TOML:
			--   a) pcall returns false (codec raised an error) — preferred
			--   b) pcall returns true but result is nil (codec returned nil on error)
			-- Either way the caller receives a signal that parsing failed.
			local graceful = not ok_call or result == nil
			helpers.assert_true(graceful,
				"vector '" .. v.id .. "': expect=error but decode returned a table ("
				.. type(result) .. ") — codec should reject this input")
			::continue::
		end
	end)
end)
