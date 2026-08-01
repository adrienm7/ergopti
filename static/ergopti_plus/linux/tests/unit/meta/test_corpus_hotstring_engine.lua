--- tests/unit/meta/test_corpus_hotstring_engine.lua

--- ==============================================================================
--- MODULE: Hotstring Engine Corpus Replay (Linux)
--- DESCRIPTION:
--- Replays every vector from the golden cross-driver hotstrings corpus
--- (_shared/tests/corpus/hotstrings/vectors.json) through the shared engine
--- (hotstring_engine). This is the FIRST time the shared engine — the production
--- matcher on Linux — has been exercised against the corpus's UTF-8 and
--- word-boundary vectors.
---
--- The existing test_shared_hotstring_engine.lua is hand-written and ASCII-only
--- (btw/the/afaik). The generic corpus consumer (test_corpus_cross_driver.lua)
--- only asserts that each vector has an id + description, never runs them through
--- the engine. Consequently the corpus's UTF-8 vectors (cé=2 not 4, àèù=3 not 6)
--- and newline/tab word-boundary vectors never exercised utf8_codepoints() and
--- is_word_char() — the exact logic those vectors were written to pin.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_true = helpers.assert_true
local assert_eq   = helpers.assert_eq
local assert_nil  = helpers.assert_nil

local driver_root = helpers.driver_root()
local shared_root = driver_root .. "/../_shared"




-- =========================================
-- =========================================
-- ======= 1/ Bootstrap & JSON Load ========
-- =========================================
-- =========================================

--- Resolves the path to _shared/lua/ from this test file's location.
local function shared_lua_path()
	local this = debug.getinfo(1, "S").source:gsub("^@", "")
	local linux_root = this:match("^(.*[/\\])tests[/\\]")
	if not linux_root then return nil end
	return linux_root .. "../../_shared/lua"
end

-- Bootstrap: inject _shared/lua/ into package.path before requiring the engine.
local _shared = shared_lua_path()
if _shared then
	local entry = _shared .. "/?.lua"
	if not package.path:find(entry, 1, true) then
		package.path = entry .. ";" .. package.path
	end
end

local engine_mod = require("hotstring_engine")

--- Loads the cross-driver hotstrings corpus from disk.
--- @return table|nil Parsed corpus table with .vectors and .collision_vectors.
local function load_corpus()
	local path = shared_root .. "/tests/corpus/hotstrings/vectors.json"

	local f = io.open(path, "r")
	if not f then return nil end
	local raw = f:read("*a")
	f:close()

	local ok, json_mod = pcall(require, "json")
	if ok and json_mod and json_mod.decode then
		return json_mod.decode(raw)
	end
	return nil
end

--- Splits a UTF-8 string into individual codepoint strings using a Lua pattern.
--- Matches one leading byte (0x01-0x7F or 0xC2-0xF4) followed by zero or more
--- continuation bytes (0x80-0xBF). The leading-byte range 0xC2-0xF4 covers all
--- valid 2/3/4-byte UTF-8 sequences; overlong encodings (0xC0-0xC1) and bytes
--- beyond Unicode (0xF5-0xFF) are excluded.
--- @param s string UTF-8 input.
--- @return table Array of single-codepoint strings.
local function split_codepoints(s)
	local cps = {}
	-- \1-\127 = ASCII (byte 0x01-0x7F); \194-\244 = multi-byte leaders
	for ch in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
		cps[#cps + 1] = ch
	end
	return cps
end

local CORPUS_PATH = shared_root .. "/tests/corpus/hotstrings/vectors.json"




-- ===========================================
-- ===========================================
-- ======= 2/ Corpus File Integrity ==========
-- ===========================================
-- ===========================================

describe("Corpus replay: hotstrings/vectors.json — shared engine", function()

	it("corpus file exists on disk", function()
		local f = io.open(CORPUS_PATH, "r")
		assert_true(f ~= nil, "hotstrings corpus must exist at: " .. CORPUS_PATH)
		if f then f:close() end
	end)

	local corpus = load_corpus()

	it("corpus JSON decodes without error", function()
		assert_true(corpus ~= nil, "hotstrings/vectors.json must decode — is _shared/lua/json.lua available?")
	end)

	if not corpus then return end

	local vectors = corpus.vectors
	local vector_count = vectors and #vectors or 0

	it("corpus has at least 10 vectors", function()
		assert_true(vector_count >= 10,
			"expected >=10 vectors, got: " .. vector_count)
	end)

	it("every vector has the required keys", function()
		for _, v in ipairs(vectors) do
			assert_true(type(v.id) == "string",
				"vector missing 'id'")
			assert_true(type(v.trigger) == "string",
				"vector " .. v.id .. " missing 'trigger'")
			assert_true(type(v.buffer) == "string",
				"vector " .. v.id .. " missing 'buffer'")
			assert_true(type(v.expected) == "table",
				"vector " .. v.id .. " missing 'expected'")
			assert_true(v.expected.matched ~= nil,
				"vector " .. v.id .. " missing 'expected.matched'")
		end
	end)




-- ===================================================
-- ===================================================
-- ======= 3/ Replay — all corpus vectors ============
-- ===================================================
-- ===================================================

	it("replay: all " .. vector_count .. " vector(s) match expected outcomes", function()
		local failures = {}
		local passed   = 0

		for _, v in ipairs(vectors) do
			local mapping = {
				trigger           = v.trigger,
				replacement       = v.replacement or "",
				is_word           = v.is_word == true,
				is_case_sensitive = v.is_case_sensitive == true,
			}

			local e = engine_mod.new()
			e:load_mappings({ mapping })

			-- Split buffer into codepoints and feed them to the engine.
			local cps = split_codepoints(v.buffer)
			local result = nil

			if #cps == 0 then
				-- Empty buffer: no characters to feed.
				result = nil
			else
				-- Feed all but the last codepoint without expecting a match.
				for i = 1, #cps - 1 do
					e:on_char(cps[i])
				end

				-- Feed the final codepoint with the terminator_consumed flag.
				-- Per the engine API: {terminator_consumed = true} adds 1 to
				-- backspace_count so the injector erases the terminator too.
				local opts = { terminator_consumed = v.terminator_consumed == true }
				result = e:on_char(cps[#cps], opts)
			end

			local expected = v.expected

			local matched_ok = (result ~= nil) == (expected.matched == true)

			local repl_ok = true
			if expected.matched and result then
				repl_ok = result.replacement == expected.replacement
			end

			local bc_ok = true
			if expected.matched and expected.backspace_count ~= nil and result then
				bc_ok = result.backspace_count == expected.backspace_count
			end

			if matched_ok and repl_ok and bc_ok then
				passed = passed + 1
			else
				local details = {}
				if not matched_ok then
					details[#details + 1] = "matched=" .. tostring(result ~= nil)
						.. " (expected " .. tostring(expected.matched) .. ")"
				end
				if not repl_ok and result then
					details[#details + 1] = "replacement='" .. tostring(result.replacement)
						.. "' (expected '" .. tostring(expected.replacement) .. "')"
				end
				if not bc_ok and result then
					details[#details + 1] = "backspace_count=" .. tostring(result.backspace_count)
						.. " (expected " .. tostring(expected.backspace_count) .. ")"
				end
				failures[#failures + 1] = v.id .. ": " .. table.concat(details, ", ")
			end
		end

		if #failures > 0 then
			local msg = passed .. "/" .. vector_count .. " passed. FAILURES:\n"
				.. table.concat(failures, "\n")
			assert_true(false, msg)
		else
			assert_true(true, "all " .. vector_count .. " vector(s) passed")
		end
	end)




-- ===============================================
-- ===============================================
-- ======= 4/ Collision vectors (SKIP) ===========
-- ===============================================
-- ===============================================

	local collisions = corpus.collision_vectors

	it("collision vectors present: " .. (collisions and #collisions or 0) .. " vector(s)", function()
		assert_true(collisions ~= nil and #collisions >= 1,
			"collision_vectors must be present in the corpus")
	end)

	-- The shared engine sorts each bucket by trigger length only. It has no
	-- priority field — but "collisions need priority" was too broad a reason to
	-- skip all six: three of them turn on rules the engine DOES implement, and
	-- those are replayed for real below.
	local ENGINE_DECIDED = {
		longer_trigger_beats_higher_priority          = true, -- length is primary (the longest-first sort)
		equal_priority_falls_back_to_first_registered = true, -- first-registered IS the engine's rule
		no_match_when_buffer_ends_outside_any_trigger = true,
	}

	--- Loads every mapping of a collision vector and types its buffer.
	--- @return string The winning replacement, or "<none>".
	local function play_collision(v, mappings)
		local e = engine_mod.new()
		e:load_mappings(mappings)
		local result
		for _, cp in ipairs(split_codepoints(v.buffer)) do
			result = e:on_char(cp)
		end
		return result and result.replacement or "<none>"
	end

	if collisions then
		for _, v in ipairs(collisions) do
			if ENGINE_DECIDED[v.id] then
				it("collision replay: " .. v.id, function()
					local want = (v.expected.matched == false) and "<none>" or v.expected.winner
					assert_eq(want, play_collision(v, v.mappings),
						"collision vector '" .. v.id .. "' turns on a rule the shared engine implements")
				end)
			end
		end

		-- The remaining three DO need priority, and the skip now asserts its own
		-- premise instead of `assert_true(true)`. Two of them would PASS by
		-- accident if replayed naively — their expected winner happens to be the
		-- mapping registered first — so a future "just enable the rest" would
		-- read as Linux honouring priority when it is blind to it. What is true
		-- and checkable is that the engine always yields the FIRST-REGISTERED
		-- mapping; the day that stops being true, priority arrived and this
		-- ledger entry needs revisiting.
		for _, v in ipairs(collisions) do
			if not ENGINE_DECIDED[v.id] then
				it("SKIP [CONF-LINUX-HOTSTRING-COLLISION] priority-blind: " .. v.id, function()
					assert_eq(v.mappings[1].replacement, play_collision(v, v.mappings),
						"the shared engine must resolve '" .. v.id
							.. "' to the first-registered mapping — if it no longer does, it has gained "
							.. "priority resolution and the conformance ledger entry is stale")
				end)
			end
		end
	end
end)
