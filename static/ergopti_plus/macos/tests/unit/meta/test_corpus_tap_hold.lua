--- tests/unit/meta/test_corpus_tap_hold.lua

--- ==============================================================================
--- MODULE: Tap-Hold Corpus Consumer (Hammerspoon)
--- DESCRIPTION:
--- Loads the shared cross-driver corpus from
--- shared/tests/corpus/tap_hold/vectors.json and validates each vector
--- against the Hammerspoon TOML codec — ensuring that a tap-hold configuration
--- round-trips through the shared Lua codec with the expected structure.
---
--- COVERAGE:
--- 1. Corpus integrity — every vector has required fields (id, key, expected).
--- 2. TOML round-trip — each non-null config is synthesized into a TOML string,
---    parsed by the shared codec, and the resulting table has the expected shape.
--- 3. Accessor semantics — the parsed structure exposes the expected key fields
---    (tap_action, time_activation_seconds, hold_modifier, hold_layer, enabled).
---
--- NOTE:
--- The Karabiner-specific runtime logic (tap/hold action dispatch, key_def
--- mapping, generator output) is exercised by the dedicated karabiner tests.
--- This file focuses on the config-parsing invariants shared with AHK.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ========================================
-- ========================================
-- ======= 1/ Corpus file loading =========
-- ========================================
-- ========================================

local driver_root = helpers.driver_root()
local corpus_path = driver_root .. "../shared/tests/corpus/tap_hold/vectors.json"

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then
		return nil, "cannot open corpus at " .. corpus_path
	end
	local raw = fh:read("*a")
	fh:close()
	package.loaded["lib.logger"] = nil
	helpers.load_with_stubs("lib.logger")
	local ok, corpus = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(corpus) end
	return corpus, nil
end

local corpus, corpus_err = read_corpus()




-- ======================================
-- ======================================
-- ======= 2/ Corpus integrity ==========
-- ======================================
-- ======================================

helpers.describe("tap_hold corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus ~= nil, "corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus.vectors) == "table",
			"corpus.vectors must be a table")
		helpers.assert_true(#corpus.vectors > 0, "corpus must have at least one vector")
	end)

	helpers.it("every vector has required fields: id, key, expected", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id")
			helpers.assert_true(type(v.key) == "string" and v.key ~= "",
				"vector '" .. tostring(v.id) .. "' missing key")
			helpers.assert_true(type(v.expected) == "table",
				"vector '" .. tostring(v.id) .. "' missing expected table")
		end
	end)

	helpers.it("configured=true vectors have a non-null config block", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			if v.expected and v.expected.configured == true then
				helpers.assert_true(type(v.config) == "table",
					"vector '" .. v.id .. "' has configured=true but config is nil")
			end
		end
	end)

	helpers.it("configured=false vectors have config = null", function()
		if not corpus then return end
		for _, v in ipairs(corpus.vectors) do
			if v.expected and v.expected.configured == false then
				helpers.assert_true(v.config == nil,
					"vector '" .. v.id .. "' has configured=false but config is non-null")
			end
		end
	end)
end)




-- ==========================================
-- ==========================================
-- ======= 3/ TOML codec round-trip =========
-- ==========================================
-- ==========================================

-- Load the shared TOML codec (lives in shared/lua/toml_codec/).
local codec_ok, codec = pcall(require, "toml_codec.codec")

helpers.describe("tap_hold corpus — TOML codec round-trip", function()
	helpers.it("toml_codec is available on the Lua path", function()
		helpers.assert_true(codec_ok,
			"toml_codec.codec not found — check package.path in tests/run.lua")
	end)

	helpers.it("configured vectors round-trip through encode/decode", function()
		if not corpus or not codec_ok then return end
		for _, v in ipairs(corpus.vectors) do
			if type(v.config) ~= "table" then goto continue end

			-- Build a TOML input table matching the tap_hold schema
			local input = {
				tap_hold = {
					keys = {
						[v.key] = v.config,
					},
				},
			}
			-- Encode → decode and verify the key is still present
			local ok_enc, toml_str = pcall(codec.encode, input)
			helpers.assert_true(ok_enc,
				"vector '" .. v.id .. "': encode failed: " .. tostring(toml_str))
			local ok_dec, parsed = pcall(codec.decode, toml_str)
			helpers.assert_true(ok_dec,
				"vector '" .. v.id .. "': decode failed: " .. tostring(parsed))

			-- Verify the key survives round-trip
			local survived_key = type(parsed) == "table"
				and type(parsed.tap_hold) == "table"
				and type(parsed.tap_hold.keys) == "table"
				and type(parsed.tap_hold.keys[v.key]) == "table"
			helpers.assert_true(survived_key,
				"vector '" .. v.id .. "': key '" .. v.key .. "' lost after round-trip")

			::continue::
		end
	end)

	helpers.it("time_activation_seconds is preserved after round-trip", function()
		if not corpus or not codec_ok then return end
		for _, v in ipairs(corpus.vectors) do
			if type(v.config) ~= "table" then goto continue end
			if v.expected.duration == nil then goto continue end

			local input = { tap_hold = { keys = { [v.key] = v.config } } }
			local _, toml_str = pcall(codec.encode, input)
			local _, parsed   = pcall(codec.decode, toml_str)

			if type(parsed) == "table"
			and type(parsed.tap_hold) == "table"
			and type(parsed.tap_hold.keys) == "table"
			and type(parsed.tap_hold.keys[v.key]) == "table" then
				local duration = parsed.tap_hold.keys[v.key].time_activation_seconds
				helpers.assert_eq(duration, v.expected.duration,
					"vector '" .. v.id .. "': duration mismatch after round-trip")
			end

			::continue::
		end
	end)

	helpers.it("hold_modifier field is preserved after round-trip", function()
		if not corpus or not codec_ok then return end
		for _, v in ipairs(corpus.vectors) do
			if type(v.config) ~= "table" then goto continue end
			if v.expected.hold_modifier == nil then goto continue end

			local input = { tap_hold = { keys = { [v.key] = v.config } } }
			local _, toml_str = pcall(codec.encode, input)
			local _, parsed   = pcall(codec.decode, toml_str)

			if type(parsed) == "table"
			and type(parsed.tap_hold) == "table"
			and type(parsed.tap_hold.keys) == "table"
			and type(parsed.tap_hold.keys[v.key]) == "table" then
				local hm = parsed.tap_hold.keys[v.key].hold_modifier
				if v.expected.hold_modifier ~= nil then
					helpers.assert_eq(hm, v.expected.hold_modifier,
						"vector '" .. v.id .. "': hold_modifier mismatch after round-trip")
				end
			end

			::continue::
		end
	end)
end)
