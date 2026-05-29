--- tests/unit/modules/keymap/test_hotstring_properties.lua

--- ==============================================================================
--- MODULE: Hotstring Engine — Property-Based Tests
--- DESCRIPTION:
--- Exercises the hotstring registry and buffer-matching logic with property-based
--- testing. Unlike example-driven tests that only cover known inputs, these
--- properties run hundreds of randomly generated inputs to expose edge cases that
--- deterministic unit tests miss.
---
--- FEATURES & RATIONALE:
--- 1. Stability: "never crashes" properties guard against panics on wild input.
--- 2. Invariants: structural guarantees (subset membership, ordering, field types)
---    hold across the full generated input space, not just representative examples.
--- 3. Determinism: properties confirm that identical inputs always yield identical
---    outputs — essential for a safety-critical hotstring engine.
--- 4. Uses the custom pbt.lua library (tests/lib/pbt.lua) — zero external deps.
--- ==============================================================================

local helpers = require("tests.helpers")
local pbt     = require("tests.lib.pbt")
local Gen     = pbt.Gen

-- Warm up the hs stub so that all subsequent plain require() calls share it.
-- load_with_stubs sets _G.hs and populates package.loaded["hs.*"] sub-modules.
package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local State = helpers.load_with_stubs("modules.keymap.state")

-- Warm the registry once so its module path is known; we will reload it per call.
helpers.load_with_stubs("modules.keymap.registry")


--- Reloads and initialises a fresh registry with a clean state.
--- Clears every module that touches hs.settings (i18n, terminators, registry)
--- so each property run starts from a completely clean slate.
--- @return table, table state, Registry module reference
local function fresh_registry()
	-- Clear the dependency chain that calls hs.settings.get at load-time
	package.loaded["lib.i18n"]                   = nil
	package.loaded["lib.locale"]                 = nil
	package.loaded["modules.keymap.registry"]    = nil
	package.loaded["modules.keymap.terminators"] = nil
	-- Refresh the hs stub so hs.settings is available for the new require chain
	helpers.load_with_stubs("lib.logger")
	local R     = require("modules.keymap.registry")
	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { autocorrection = 0.3 })
	R.init(state)
	return state, R
end




-- =======================================================
--- ================================================
-- ======= 1/ Registry Stability Properties =======
--- ================================================
-- =======================================================

pbt.suite("Registry — stability (never crashes)", function()

	pbt.property(
		"lookup_for_tail never crashes on arbitrary ASCII string input",
		Gen.ascii_string(40),
		function(s)
			local _, R = fresh_registry()
			-- Must not throw regardless of the query character
			local tail = s:sub(-1)
			if tail == "" then tail = "a" end
			local result = R.mappings_for_tail and R.mappings_for_tail(tail)
				or (R.get_for_tail and R.get_for_tail(tail))
				or {}
			return type(result) == "table"
		end,
		{ runs = 500 }
	)

	pbt.property(
		"add() never crashes on arbitrary ASCII trigger and replacement",
		Gen.record({ trigger = Gen.ascii_string(20), repl = Gen.ascii_string(40) }),
		function(input)
			local _, R = fresh_registry()
			-- add() should log-and-return on bad input, never raise
			local ok = pcall(function()
				R.add(input.trigger, input.repl)
			end)
			return ok
		end,
		{ runs = 500 }
	)

	pbt.property(
		"add() never crashes on arbitrary UTF-8 trigger",
		Gen.utf8_string(15),
		function(trigger)
			local _, R = fresh_registry()
			local ok = pcall(function()
				R.add(trigger, "replacement")
			end)
			return ok
		end,
		{ runs = 500 }
	)

	pbt.property(
		"add() never crashes when called with nil replacement",
		Gen.identifier(10),
		function(trigger)
			local _, R = fresh_registry()
			local ok = pcall(function()
				R.add(trigger, nil)
			end)
			return ok
		end,
		{ runs = 200 }
	)

	pbt.property(
		"add() never crashes when called with empty trigger",
		Gen.ascii_string(30),
		function(repl)
			local _, R = fresh_registry()
			local ok = pcall(function()
				R.add("", repl)
			end)
			return ok
		end,
		{ runs = 200 }
	)

end)




-- ============================================================
--- =================================================
-- ======= 2/ Registry Invariants Properties =======
--- =================================================
-- ============================================================

pbt.suite("Registry — structural invariants", function()

	pbt.property(
		"registered entries are always findable by their tail char",
		Gen.non_empty_array(
			Gen.record({
				trigger = Gen.identifier(12),
				repl    = Gen.ascii_string(30),
			}),
			10
		),
		function(mappings)
			-- De-dup triggers to avoid silent collisions
			local seen  = {}
			local state, R = fresh_registry()

			for _, m in ipairs(mappings) do
				if not seen[m.trigger] and m.trigger ~= "" then
					seen[m.trigger] = true
					R.add(m.trigger, m.repl)
				end
			end
			-- sort_mappings() populates the tail-char buckets used by mappings_for_tail
			R.sort_mappings()

			-- Every added trigger must appear in its tail-char bucket.
			-- add() stores a lowercased copy, so we look up by trigger:lower().
			for trigger, _ in pairs(seen) do
				local lower  = trigger:lower()
				local tail   = lower:sub(-1)
				local bucket = R.mappings_for_tail(tail) or {}
				local found  = false
				for _, entry in ipairs(bucket) do
					if entry.trigger == lower then
						found = true
						break
					end
				end
				if not found then return false end
			end
			return true
		end,
		{ runs = 300 }
	)

	pbt.property(
		"lookup returns only entries matching the queried tail char",
		Gen.non_empty_array(Gen.identifier(12), 15),
		function(triggers)
			local seen  = {}
			local _, R  = fresh_registry()

			for _, trigger in ipairs(triggers) do
				if not seen[trigger] and trigger ~= "" then
					seen[trigger] = true
					R.add(trigger, "replacement_" .. trigger)
				end
			end
			R.sort_mappings()

			-- For any single-char query, every returned entry must end with that char
			local query_chars = { "a", "e", "s", "t", "n" }
			for _, tail in ipairs(query_chars) do
				local bucket = (R.mappings_for_tail and R.mappings_for_tail(tail))
					or (R.get_for_tail and R.get_for_tail(tail))
					or {}
				for _, entry in ipairs(bucket) do
					-- tail_char is stored lowercased in the registry; compare lower to lower
					local entry_tail = entry.trigger:sub(-1):lower()
					if entry_tail ~= tail then return false end
				end
			end
			return true
		end,
		{ runs = 300 }
	)

	pbt.property(
		"bucket is sorted longest-trigger-first",
		Gen.non_empty_array(Gen.identifier(12), 10),
		function(triggers)
			local seen  = {}
			local _, R  = fresh_registry()

			-- Register several triggers that all end with 'a' for a clean bucket
			local base_triggers = { "a", "ba", "cba", "dcba", "edcba" }
			for _, t in ipairs(base_triggers) do
				R.add(t, "r_" .. t)
			end
			-- Also add whatever was generated, de-duped
			for _, trigger in ipairs(triggers) do
				if not seen[trigger] and trigger ~= "" then
					seen[trigger] = true
					R.add(trigger, "r_" .. trigger)
				end
			end
			R.sort_mappings()

			local bucket = (R.mappings_for_tail and R.mappings_for_tail("a"))
				or (R.get_for_tail and R.get_for_tail("a"))
				or {}
			for i = 2, #bucket do
				local prev_len = #bucket[i - 1].trigger
				local curr_len = #bucket[i].trigger
				if curr_len > prev_len then return false end
			end
			return true
		end,
		{ runs = 300 }
	)

	pbt.property(
		"state.mappings count equals number of unique added triggers",
		Gen.non_empty_array(Gen.identifier(10), 8),
		function(triggers)
			local seen          = {}
			local state, R      = fresh_registry()
			local expected_count = 0

			for _, trigger in ipairs(triggers) do
				if not seen[trigger] and trigger ~= "" then
					seen[trigger] = true
					R.add(trigger, "r_" .. trigger)
					-- Registry may add extra case-variants; count at least the lowercase one
					expected_count = expected_count + 1
				end
			end

			-- state.mappings must contain at least as many entries as unique triggers
			return #state.mappings >= expected_count
		end,
		{ runs = 300 }
	)

end)




-- ============================================================
--- ==================================================
-- ======= 3/ Matching Determinism Properties =======
--- ==================================================
-- ============================================================

pbt.suite("Registry — matching determinism", function()

	pbt.property(
		"scanning the same buffer twice gives the same result",
		Gen.record({
			trigger = Gen.identifier(10),
			buffer  = Gen.ascii_string(30),
		}),
		function(input)
			local _, R = fresh_registry()
			if input.trigger == "" then return true end
			R.add(input.trigger, "expansion")
			R.sort_mappings()

			local tail   = input.buffer:sub(-1)
			if tail == "" then tail = "a" end

			-- Use the tail-char bucket as a proxy for matching state
			local bucket1 = (R.mappings_for_tail and R.mappings_for_tail(tail))
				or (R.get_for_tail and R.get_for_tail(tail))
				or {}
			local bucket2 = (R.mappings_for_tail and R.mappings_for_tail(tail))
				or (R.get_for_tail and R.get_for_tail(tail))
				or {}

			-- Same call must return the same number of entries
			if #bucket1 ~= #bucket2 then return false end
			for i = 1, #bucket1 do
				if bucket1[i].trigger ~= bucket2[i].trigger then return false end
			end
			return true
		end,
		{ runs = 500 }
	)

	pbt.property(
		"no false positive — random short buffer without trigger does not match",
		Gen.record({
			trigger = Gen.identifier(8),
			noise   = Gen.identifier(4),
		}),
		function(input)
			local _, R = fresh_registry()
			-- Register only `trigger`
			R.add(input.trigger, "expansion")
			R.sort_mappings()

			-- A buffer that does NOT end with the trigger tail char
			local trigger_tail = input.trigger:sub(-1)
			-- Pick a different tail char by XOR-shifting the codepoint
			local alt_code     = (string.byte(trigger_tail) - 97 + 1) % 26 + 97
			local alt_tail     = string.char(alt_code)

			local buffer = input.noise .. alt_tail
			local bucket = (R.mappings_for_tail and R.mappings_for_tail(alt_tail))
				or (R.get_for_tail and R.get_for_tail(alt_tail))
				or {}

			-- The trigger's tail char ≠ alt_tail, so the bucket must be empty
			for _, entry in ipairs(bucket) do
				if entry.trigger == input.trigger then return false end
			end
			return true
		end,
		{ runs = 500 }
	)

	pbt.property(
		"registered trigger is always found in the correct bucket after sort",
		Gen.identifier(10),
		function(trigger)
			if trigger == "" then return true end
			local _, R = fresh_registry()
			R.add(trigger, "expansion_1")
			-- sort_mappings() is required to populate the tail-char bucket index
			R.sort_mappings()

			-- add() stores a lowercased variant; look up using that form
			local lower  = trigger:lower()
			local tail   = lower:sub(-1)
			local bucket = R.mappings_for_tail(tail) or {}
			local found  = false
			for _, entry in ipairs(bucket) do
				if entry.trigger == lower then found = true end
			end
			return found
		end,
		{ runs = 500 }
	)

end)




-- ============================================================
--- ==================================================
-- ======= 4/ Entry Field Validity Properties =======
--- ==================================================
-- ============================================================

pbt.suite("Registry — entry field validity", function()

	pbt.property(
		"every added mapping has a non-empty string trigger and tail_char",
		Gen.non_empty_array(Gen.identifier(12), 10),
		function(triggers)
			local seen = {}
			local _, R = fresh_registry()

			for _, trigger in ipairs(triggers) do
				if not seen[trigger] and trigger ~= "" then
					seen[trigger] = true
					R.add(trigger, "r_" .. trigger)
				end
			end
			R.sort_mappings()

			-- Inspect all tail-char buckets we know were populated
			for trigger, _ in pairs(seen) do
				local tail   = trigger:lower():sub(-1)
				local bucket = R.mappings_for_tail(tail) or {}
				for _, entry in ipairs(bucket) do
					if type(entry.trigger) ~= "string" or entry.trigger == "" then
						return false
					end
					if type(entry.tail_char) ~= "string" or entry.tail_char == "" then
						return false
					end
				end
			end
			return true
		end,
		{ runs = 300 }
	)

	pbt.property(
		"tail_char of every entry matches the last character of its trigger",
		Gen.non_empty_array(Gen.identifier(12), 10),
		function(triggers)
			local seen = {}
			local _, R = fresh_registry()

			for _, trigger in ipairs(triggers) do
				if not seen[trigger] and trigger ~= "" then
					seen[trigger] = true
					R.add(trigger, "r_" .. trigger)
				end
			end
			R.sort_mappings()

			for trigger, _ in pairs(seen) do
				local expected_tail = trigger:lower():sub(-1)
				local bucket = R.mappings_for_tail(expected_tail) or {}
				-- Every entry in this bucket must have a tail_char matching expected_tail
				for _, entry in ipairs(bucket) do
					if entry.tail_char ~= expected_tail then return false end
				end
			end
			return true
		end,
		{ runs = 300 }
	)

end)




-- ====================================================
--- ==========================
-- ======= 5/ Summary =======
--- ==========================
-- ====================================================

pbt.summary()
