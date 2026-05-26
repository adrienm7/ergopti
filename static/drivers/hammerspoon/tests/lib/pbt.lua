--- tests/lib/pbt.lua

--- ==============================================================================
--- MODULE: Property-Based Testing Library (PBT)
--- DESCRIPTION:
--- A minimal, self-contained property-based testing framework for the Lua test
--- suite. It provides composable generators (arbitraries), a property runner that
--- executes each property N times with randomly generated inputs, and a simple
--- shrinker that tries smaller counterexamples on failure.
---
--- FEATURES & RATIONALE:
--- 1. Zero dependencies: works under plain Lua 5.4 with no external packages.
--- 2. Composable generators: Gen.string, Gen.integer, Gen.oneof, Gen.record, etc.
---    can be freely combined to describe any input domain.
--- 3. Shrinking: on failure the runner tries smaller inputs to surface the minimal
---    counterexample, making failures dramatically easier to diagnose.
--- 4. Seed control: pass opts.seed to reproduce a failure deterministically.
--- ==============================================================================

local M = {}




-- ======================================
--- =============================
-- ======= 1/ PRNG (LCG) =======
--- =============================
-- ======================================

--- Lightweight 32-bit LCG pseudo-random number generator.
--- Parameters from Numerical Recipes (Knuth).
--- @class Rng
--- @field seed number Current generator state.
local Rng = {}
Rng.__index = Rng

local LCG_A      = 1664525       -- LCG multiplier (Knuth)
local LCG_C      = 1013904223    -- LCG increment (Knuth)
local LCG_MOD    = 2 ^ 32        -- Modulus (32-bit wrap)
local DEFAULT_SEED = 42          -- Reproducible default when no seed supplied

--- Creates a new RNG instance.
--- @param seed number|nil Initial seed. Defaults to DEFAULT_SEED.
--- @return Rng
function Rng.new(seed)
	return setmetatable({ state = seed or DEFAULT_SEED }, Rng)
end

--- Returns the next random integer in [0, 2^32).
--- @return number
function Rng:next_int()
	self.state = (self.state * LCG_A + LCG_C) % LCG_MOD
	return self.state
end

--- Returns a random integer in [lo, hi] inclusive.
--- @param lo number Lower bound.
--- @param hi number Upper bound (>= lo).
--- @return number
function Rng:int_range(lo, hi)
	local range = hi - lo + 1
	return lo + (self:next_int() % range)
end

--- Returns a random float in [0, 1).
--- @return number
function Rng:float()
	return self:next_int() / LCG_MOD
end




-- =============================================
--- ========================================
-- ======= 2/ Generator Combinators =======
--- ========================================
-- =============================================

--- A generator wraps a function (rng, size) → value.
--- `size` is a positive integer that loosely controls the "bigness" of generated
--- values; the runner ramps it from 1 to MAX_SIZE across iterations.
--- @class Gen
local Gen = {}
M.Gen = Gen

local MAX_SIZE = 30  -- Maximum size parameter passed to generators

--- Wraps a raw generation function into a Gen object.
--- @param fn function(rng: Rng, size: number): any
--- @return Gen
function Gen.make(fn)
	return { generate = fn }
end

--- Generates a random boolean.
--- @return Gen
function Gen.boolean()
	return Gen.make(function(rng, _)
		return rng:int_range(0, 1) == 1
	end)
end

--- Generates a random integer in [min, max].
--- @param min number
--- @param max number
--- @return Gen
function Gen.integer(min, max)
	return Gen.make(function(rng, _)
		return rng:int_range(min, max)
	end)
end

--- Generates a random float in [0.0, 1.0].
--- @return Gen
function Gen.float_unit()
	return Gen.make(function(rng, _)
		return rng:float()
	end)
end

--- Generates a random ASCII string of up to max_len characters.
--- Characters are in the printable ASCII range [32, 126].
--- @param max_len number|nil Maximum length (default 20).
--- @return Gen
local PRINTABLE_ASCII_LO = 32    -- Space — lowest printable ASCII
local PRINTABLE_ASCII_HI = 126   -- Tilde — highest printable ASCII

function Gen.ascii_string(max_len)
	local limit = max_len or 20
	return Gen.make(function(rng, size)
		local len = rng:int_range(0, math.min(limit, size))
		local chars = {}
		for _ = 1, len do
			chars[#chars + 1] = string.char(rng:int_range(PRINTABLE_ASCII_LO, PRINTABLE_ASCII_HI))
		end
		return table.concat(chars)
	end)
end

--- Generates a random UTF-8 string containing a mix of ASCII and common
--- multi-byte codepoints (Latin Extended-A, Cyrillic, CJK sample).
--- @param max_len number|nil Maximum codepoint count (default 20).
--- @return Gen
local UTF8_EXTRA_CODEPOINTS = {
	0xE9, 0xE0, 0xFC, 0xF6, 0xE4,          -- Latin small letters with diacritics
	0xC9, 0xC0, 0xDC, 0xD6, 0xC4,          -- Latin capital letters with diacritics
	0x0430, 0x0431, 0x0432, 0x0433,         -- Cyrillic а б в г
	0x4E2D, 0x6587, 0x65E5, 0x672C,         -- CJK: 中文日本
	0x2605, 0x2606,                         -- ★ ☆
}

local function codepoint_to_utf8(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(
			0xC0 + math.floor(cp / 64),
			0x80 + (cp % 64)
		)
	elseif cp < 0x10000 then
		return string.char(
			0xE0 + math.floor(cp / 4096),
			0x80 + math.floor((cp % 4096) / 64),
			0x80 + (cp % 64)
		)
	else
		return string.char(
			0xF0 + math.floor(cp / 262144),
			0x80 + math.floor((cp % 262144) / 4096),
			0x80 + math.floor((cp % 4096) / 64),
			0x80 + (cp % 64)
		)
	end
end

function Gen.utf8_string(max_len)
	local limit = max_len or 20
	-- All candidate codepoints: ASCII printable + curated extras
	local pool = {}
	for cp = PRINTABLE_ASCII_LO, PRINTABLE_ASCII_HI do pool[#pool + 1] = cp end
	for _, cp in ipairs(UTF8_EXTRA_CODEPOINTS) do pool[#pool + 1] = cp end

	return Gen.make(function(rng, size)
		local len = rng:int_range(0, math.min(limit, size))
		local parts = {}
		for _ = 1, len do
			local cp = pool[rng:int_range(1, #pool)]
			parts[#parts + 1] = codepoint_to_utf8(cp)
		end
		return table.concat(parts)
	end)
end

--- Alias — same as ascii_string for contexts that just need "a string".
--- @param max_len number|nil
--- @return Gen
function Gen.string(max_len)
	return Gen.ascii_string(max_len)
end

--- Generates a random lowercase ASCII identifier (letters only, length 1..max_len).
--- Useful as a trigger or field name where spaces are not allowed.
--- @param max_len number|nil Default 12.
--- @return Gen
local LOWERCASE_A = 97   -- Codepoint of 'a'
local LOWERCASE_Z = 122  -- Codepoint of 'z'

function Gen.identifier(max_len)
	local limit = max_len or 12
	return Gen.make(function(rng, size)
		local len = rng:int_range(1, math.max(1, math.min(limit, size)))
		local chars = {}
		for _ = 1, len do
			chars[#chars + 1] = string.char(rng:int_range(LOWERCASE_A, LOWERCASE_Z))
		end
		return table.concat(chars)
	end)
end

--- Picks uniformly at random from a fixed list of constant values.
--- @param ... any Values to choose among.
--- @return Gen
function Gen.oneof(...)
	local options = { ... }
	assert(#options > 0, "Gen.oneof requires at least one option")
	return Gen.make(function(rng, _)
		return options[rng:int_range(1, #options)]
	end)
end

--- Generates a random array of values produced by `gen`, of length 0..max_len.
--- @param gen Gen Element generator.
--- @param max_len number|nil Default 10.
--- @return Gen
function Gen.array(gen, max_len)
	local limit = max_len or 10
	return Gen.make(function(rng, size)
		local len = rng:int_range(0, math.min(limit, size))
		local result = {}
		for _ = 1, len do
			result[#result + 1] = gen.generate(rng, size)
		end
		return result
	end)
end

--- Generates a non-empty array (at least one element).
--- @param gen Gen Element generator.
--- @param max_len number|nil Default 10.
--- @return Gen
function Gen.non_empty_array(gen, max_len)
	local limit = max_len or 10
	return Gen.make(function(rng, size)
		local len = rng:int_range(1, math.max(1, math.min(limit, size)))
		local result = {}
		for _ = 1, len do
			result[#result + 1] = gen.generate(rng, size)
		end
		return result
	end)
end

--- Generates a table whose fields are produced by the corresponding generators.
--- @param field_gens table<string, Gen> Map of field name → generator.
--- @return Gen
function Gen.record(field_gens)
	return Gen.make(function(rng, size)
		local result = {}
		for k, gen in pairs(field_gens) do
			result[k] = gen.generate(rng, size)
		end
		return result
	end)
end

--- Applies a pure transformation to the output of another generator.
--- @param gen Gen The source generator.
--- @param fn function(value): any Transformation applied to each generated value.
--- @return Gen
function Gen.map(gen, fn)
	return Gen.make(function(rng, size)
		return fn(gen.generate(rng, size))
	end)
end

--- Generates a value and filters until the predicate passes.
--- Attempts up to MAX_FILTER_TRIES times before giving up (returns nil).
--- @param gen Gen Source generator.
--- @param pred function(value): boolean
--- @return Gen
local MAX_FILTER_TRIES = 100  -- Give up after this many rejected samples

function Gen.filter(gen, pred)
	return Gen.make(function(rng, size)
		for _ = 1, MAX_FILTER_TRIES do
			local v = gen.generate(rng, size)
			if pred(v) then return v end
		end
		-- Exhausted retries — return nil to signal failure upstream
		return nil
	end)
end




-- ===========================================
--- ===========================
-- ======= 3/ Shrinker =======
--- ===========================
-- ===========================================

--- Produces a list of "smaller" variants of a string counterexample.
--- Tries: empty string, first half, second half, drop-last-char.
--- @param s string
--- @return table<string> Candidate shrinks, shortest first.
local function shrink_string(s)
	local candidates = {}
	if s == "" then return candidates end
	candidates[#candidates + 1] = ""
	local mid = math.floor(#s / 2)
	if mid > 0 then candidates[#candidates + 1] = s:sub(1, mid) end
	candidates[#candidates + 1] = s:sub(1, #s - 1)
	return candidates
end

--- Produces smaller variants of an integer counterexample.
--- @param n number
--- @return table<number>
local function shrink_int(n)
	if n == 0 then return {} end
	return { 0, math.floor(n / 2), n - (n > 0 and 1 or -1) }
end

--- Produces smaller variants of a table/array counterexample.
--- @param t table
--- @return table<table>
local function shrink_table(t)
	local candidates = {}
	if #t == 0 and next(t) == nil then return candidates end
	candidates[#candidates + 1] = {}
	if #t > 1 then
		-- Drop last element
		local shorter = {}
		for i = 1, #t - 1 do shorter[i] = t[i] end
		candidates[#candidates + 1] = shorter
	end
	return candidates
end

--- Dispatches to the appropriate shrinker for a value.
--- @param v any
--- @return table Candidate shrunken values.
local function shrink_value(v)
	local t = type(v)
	if t == "string"  then return shrink_string(v) end
	if t == "number"  then return shrink_int(v) end
	if t == "table"   then return shrink_table(v) end
	return {}
end




-- ==========================================
--- ==================================
-- ======= 4/ Property Runner =======
--- ==================================
-- ==========================================

local DEFAULT_RUNS       = 500   -- Number of iterations per property by default
local SIZE_GROWTH_FACTOR = 30    -- How quickly size grows across iterations

--- Runs a property-based test.
--- The property_fn receives a generated value and must return true (pass) or
--- false / raise an error (fail). On the first failure the runner attempts to
--- shrink the counterexample, then reports the minimal failing case.
---
--- @param label string Human-readable property name.
--- @param gen Gen The generator that produces inputs.
--- @param property_fn function(value): boolean The property to verify.
--- @param opts table|nil Optional configuration:
---   - runs  number   Override DEFAULT_RUNS.
---   - seed  number   Override the initial RNG seed.
--- @return boolean True if the property holds for all generated inputs.
function M.check(label, gen, property_fn, opts)
	local runs = (opts and opts.runs) or DEFAULT_RUNS
	local seed = (opts and opts.seed) or os.time()
	local rng  = Rng.new(seed)

	for i = 1, runs do
		-- Ramp size from 1 to MAX_SIZE across all runs
		local size  = math.max(1, math.floor(i * MAX_SIZE / runs))
		local value = gen.generate(rng, size)

		local ok, err = pcall(property_fn, value)

		if not ok or err == false then
			-- Attempt to shrink the counterexample
			local minimal = value
			local shrink_steps = 0
			local found_smaller = true

			while found_smaller do
				found_smaller = false
				for _, candidate in ipairs(shrink_value(minimal)) do
					local sok, serr = pcall(property_fn, candidate)
					if not sok or serr == false then
						minimal      = candidate
						found_smaller = true
						shrink_steps = shrink_steps + 1
						break
					end
				end
			end

			local reason = (type(err) == "string") and err or "predicate returned false"
			io.write(string.format(
				"  FAIL  %s\n        Failed after %d run(s) (seed=%d). Counterexample: %s\n        Shrunk %d step(s) to: %s\n        Reason: %s\n",
				label, i, seed,
				tostring(value),
				shrink_steps,
				tostring(minimal),
				reason
			))
			return false
		end
	end

	io.write(string.format("  ok    %s  (%d runs)\n", label, runs))
	return true
end

--- Runs a suite of properties under a named heading.
--- @param name string Suite name.
--- @param fn function Suite body that calls M.check().
--- @return table {passed: number, failed: number}
function M.suite(name, fn)
	print(string.format("\n=== %s ===", name))
	local before_pass = M._pass or 0
	local before_fail = M._fail or 0
	fn()
	return {
		passed = (M._pass or 0) - before_pass,
		failed = (M._fail or 0) - before_fail,
	}
end

-- Module-level counters, incremented by the check() wrapper below.
M._pass = 0
M._fail = 0

--- Convenience wrapper that auto-increments global counters.
--- @param label string
--- @param gen Gen
--- @param property_fn function
--- @param opts table|nil
function M.property(label, gen, property_fn, opts)
	local ok = M.check(label, gen, property_fn, opts)
	if ok then
		M._pass = M._pass + 1
	else
		M._fail = M._fail + 1
	end
end

--- Prints the final pass/fail summary and returns the exit code (0 = all pass).
--- @return number 0 if all passed, 1 otherwise.
function M.summary()
	print(string.rep("-", 50))
	print(string.format("Properties passed: %d", M._pass))
	print(string.format("Properties failed: %d", M._fail))
	print(string.format("Total:             %d", M._pass + M._fail))
	if M._fail > 0 then
		print(string.format("\n✗  %d property(ies) failed.", M._fail))
		return 1
	else
		print(string.format("\n✓  All %d properties passed.", M._pass))
		return 0
	end
end

return M
