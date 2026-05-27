--- tests/bench/bench_hotstring_scan.lua

--- ==============================================================================
--- MODULE: Hotstring Scan Benchmark (Lua)
--- DESCRIPTION:
--- Standalone benchmark for the hotstring tail-char bucket scan algorithm.
--- Exercises the same O(1) lookup path used by run_trigger_checks() in the
--- live Hammerspoon engine. Run with LuaJIT for the most representative timings.
---
--- FEATURES & RATIONALE:
--- 1. Self-Contained: Replicates the registry data structures locally so the
---    benchmark runs without a Hammerspoon environment or hs.* APIs.
--- 2. Baseline Comparison: Reads baselines/hotstring_scan.json when present
---    and exits with code 1 if p95 regressed more than 20%.
--- 3. Results Persistence: Always writes results/hotstring_scan_latest.json so
---    CI can archive or diff across runs.
--- ==============================================================================




-- ===========================
--- ============================
-- ======= 1/ Constants =======
--- ============================
-- ===========================

-- Absolute p95 ceiling in milliseconds
local P95_LIMIT_MS        = 5.0

-- Maximum regression fraction allowed vs stored baseline (0.20 = 20%)
local REGRESSION_THRESHOLD = 0.20

-- Number of scan iterations in the timed loop
local ITERATION_COUNT     = 10000

-- Number of synthetic triggers in the fixture registry
local FIXTURE_TRIGGER_COUNT = 3300

-- Paths relative to the script location (resolved at runtime)
local SCRIPT_DIR          = debug.getinfo(1, "S").source:match("^@(.+[/\\])") or "./"
local RESULTS_DIR         = SCRIPT_DIR .. "results/"
local BASELINES_DIR       = SCRIPT_DIR .. "baselines/"
local RESULT_PATH         = RESULTS_DIR .. "hotstring_scan_latest.json"
local BASELINE_PATH       = BASELINES_DIR .. "hotstring_scan.json"




-- ===========================
--- ============================
-- ======= 2/ Utilities =======
--- ============================
-- ===========================

--- Returns the last UTF-8 codepoint of a string. Falls back to the last byte
--- on malformed UTF-8, matching the behaviour of tail_codepoint() in registry.lua.
--- @param s string Input string.
--- @return string Last UTF-8 codepoint, or "" for empty strings.
local function tail_codepoint(s)
	if type(s) ~= "string" or s == "" then return "" end
	-- pcall guard: utf8.offset returns nil on malformed sequences
	local ok, off = pcall(utf8.offset, s, -1)
	if ok and off then return s:sub(off) end
	return s:sub(-1)
end

--- Reads a text file and returns its content, or nil on failure.
--- @param path string Absolute or relative file path.
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Writes text to a file; creates the file if absent.
--- @param path string Destination path.
--- @param content string Text to write.
--- @return boolean True on success.
local function write_file(path, content)
	local fh = io.open(path, "w")
	if not fh then return false end
	fh:write(content)
	fh:close()
	return true
end

--- Naive JSON object serialiser — handles only flat {string → number|string} tables.
--- Sufficient for emitting benchmark result records without a full JSON library.
--- @param t table Key-value table with string keys and scalar values.
--- @return string JSON representation.
local function to_json(t)
	local parts = {}
	for k, v in pairs(t) do
		local val
		if type(v) == "number" then
			val = string.format("%.6f", v)
		else
			val = '"' .. tostring(v):gsub('"', '\\"') .. '"'
		end
		parts[#parts + 1] = string.format('  "%s": %s', k, val)
	end
	table.sort(parts)
	return "{\n" .. table.concat(parts, ",\n") .. "\n}\n"
end

--- Parses a flat JSON object into a Lua table; handles only numeric values.
--- @param s string JSON string.
--- @return table|nil
local function from_json(s)
	if not s then return nil end
	local t = {}
	for k, v in s:gmatch('"([^"]+)"%s*:%s*([%d%.%-e]+)') do
		t[k] = tonumber(v)
	end
	return next(t) and t or nil
end

--- Returns the p-th percentile of a pre-sorted array (0-indexed values).
--- Uses linear interpolation between adjacent ranks.
--- @param sorted table Array sorted in ascending order.
--- @param p number Percentile in [0, 100].
--- @return number
local function percentile(sorted, p)
	local n = #sorted
	if n == 0 then return 0 end
	local idx = (p / 100) * (n - 1) + 1  -- 1-based
	local lo  = math.floor(idx)
	local hi  = math.ceil(idx)
	if lo == hi then return sorted[lo] end
	return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo)
end




-- ============================
-- ============================
-- ======= 3/ Registry ========
-- ============================
-- ============================

--- Builds a synthetic registry with FIXTURE_TRIGGER_COUNT entries bucketed by
--- tail codepoint, mirroring the data structures built by add_raw() /
--- rebuild_tail_indexes() in modules/keymap/registry.lua.
--- @return table Registry with a mappings array and a mappings_by_tail_char table.
local function build_fixture_registry()
	-- Representative short triggers from the real TOML corpus
	local bodies = {
		"qd", "dc", "pr", "av", "ap", "ds", "en", "et", "le", "la",
		"les", "des", "une", "un", "ces", "ses", "que", "qui", "pas",
		"mais", "donc", "car", "qqch", "qqn", "pdt", "pdv", "rdv",
		"stp", "svp", "bjr", "bsr", "mdr", "tjs", "bcp", "ns", "vs",
	}

	local alpha   = "abcdefghijklmnopqrstuvwxyz"
	local mappings = {}
	local by_tail  = {}
	local seq      = 0

	local function add_entry(trigger)
		seq = seq + 1
		local tc = tail_codepoint(trigger)
		local entry = {
			trigger       = trigger,
			trigger_bytes = #trigger,
			tlen          = utf8.len(trigger) or #trigger,
			tail_char     = tc,
			seq           = seq,
			auto          = false,
			is_word       = false,
		}
		mappings[#mappings + 1] = entry
		if not by_tail[tc] then by_tail[tc] = {} end
		by_tail[tc][#by_tail[tc] + 1] = entry
	end

	-- Seed with representative bodies
	for _, b in ipairs(bodies) do add_entry(b) end

	-- Fill to target count with generated triggers
	local done = false
	for len = 2, 8 do
		if done then break end
		for i = 1, #alpha do
			if done then break end
			for j = 1, #alpha do
				local t = alpha:sub(i, i):rep(math.max(1, len - 1)) .. alpha:sub(j, j)
				add_entry(t)
				if #mappings >= FIXTURE_TRIGGER_COUNT then done = true; break end
			end
		end
	end

	-- Sort each bucket longest-first (mirrors sort_mappings / rebuild_tail_indexes)
	for _, bucket in pairs(by_tail) do
		table.sort(bucket, function(a, b)
			if a.tlen ~= b.tlen then return a.tlen > b.tlen end
			return a.seq < b.seq
		end)
	end

	return { mappings = mappings, mappings_by_tail_char = by_tail }
end




-- ======================================
--- =======================================
-- ======= 4/ Hot-Path Scan Kernel =======
--- =======================================
-- ======================================

--- Simulates a single keystroke scan: fetches the tail-char bucket for `keystroke`
--- and iterates it checking buffer suffix match. Same algorithmic path as
--- run_trigger_checks() → Registry.mappings_for_tail() in the live engine.
--- @param registry table Fixture registry.
--- @param buffer string Current typing buffer.
--- @param keystroke string Character just typed.
--- @return boolean True if a trigger matched.
local function simulate_scan(registry, buffer, keystroke)
	local tc     = tail_codepoint(keystroke)
	local bucket = registry.mappings_by_tail_char[tc]
	if not bucket then return false end

	local full_buf = buffer .. keystroke
	local buf_len  = #full_buf

	for _, m in ipairs(bucket) do
		-- Buffer must be at least as long as the trigger (byte comparison)
		if buf_len >= m.trigger_bytes then
			if full_buf:sub(-m.trigger_bytes) == m.trigger then return true end
		end
	end
	return false
end




-- ==============================
--- ================================
-- ======= 5/ Benchmark Run =======
--- ================================
-- ==============================

--- Generates a random string of `len` characters drawn from `charset`.
--- @param len number Length of the desired string.
--- @param charset string Pool of characters.
--- @return string
local function rand_str(len, charset)
	local chars = {}
	for _ = 1, len do
		chars[#chars + 1] = charset:sub(math.random(#charset), math.random(#charset))
	end
	return table.concat(chars)
end

--- Runs the timed benchmark loop and returns latency statistics in milliseconds.
--- @param registry table Fixture registry.
--- @return table Statistics: min, p50, p95, p99, max, iterations.
local function run_benchmark(registry)
	local charset = "abcdefghijklmnopqrstuvwxyz,;.eaui "

	-- Pre-generate inputs outside the timed loop
	local buffers    = {}
	local keystrokes = {}
	math.randomseed(42)
	for i = 1, ITERATION_COUNT do
		buffers[i]    = rand_str(math.random(1, 20), charset)
		keystrokes[i] = charset:sub(math.random(#charset), math.random(#charset))
	end

	-- Warm-up (first 200 iterations discarded)
	for i = 1, 200 do
		simulate_scan(registry, buffers[i], keystrokes[i])
	end

	-- Timed loop
	local latencies_ms = {}
	for i = 1, ITERATION_COUNT do
		local t0 = os.clock()
		simulate_scan(registry, buffers[i], keystrokes[i])
		local t1 = os.clock()
		-- os.clock() resolution is typically 1 µs on Linux/macOS
		latencies_ms[i] = (t1 - t0) * 1000
	end

	table.sort(latencies_ms)

	return {
		min        = latencies_ms[1],
		p50        = percentile(latencies_ms, 50),
		p95        = percentile(latencies_ms, 95),
		p99        = percentile(latencies_ms, 99),
		max        = latencies_ms[#latencies_ms],
		iterations = ITERATION_COUNT,
	}
end




-- ===========================
--- ===========================
-- ======= 6/ Main Run =======
--- ===========================
-- ===========================

print("=== Hotstring scan benchmark (Lua) ===")
print(string.format("Building fixture registry (%d triggers)…", FIXTURE_TRIGGER_COUNT))

local registry = build_fixture_registry()
local bucket_count = 0
for _ in pairs(registry.mappings_by_tail_char) do bucket_count = bucket_count + 1 end
print(string.format("Registry built: %d mappings, %d tail-char buckets.", #registry.mappings, bucket_count))

print(string.format("Running %d iterations…", ITERATION_COUNT))
local results = run_benchmark(registry)

print("\nResults:")
print(string.format("  min  : %.4f ms", results.min))
print(string.format("  p50  : %.4f ms", results.p50))
print(string.format("  p95  : %.4f ms", results.p95))
print(string.format("  p99  : %.4f ms", results.p99))
print(string.format("  max  : %.4f ms", results.max))

-- Write results
local ok_w = write_file(RESULT_PATH, to_json(results))
if ok_w then
	print(string.format("\nResults written to %s", RESULT_PATH))
else
	print(string.format("\nWARN: could not write results to %s", RESULT_PATH))
end

-- Absolute gate
local fail = false
if results.p95 > P95_LIMIT_MS then
	io.stderr:write(string.format(
		"\nFAIL: p95 %.4f ms exceeds absolute limit of %.1f ms.\n",
		results.p95, P95_LIMIT_MS
	))
	fail = true
else
	print(string.format("\nAbsolute gate: p95 %.4f ms <= %.1f ms  OK", results.p95, P95_LIMIT_MS))
end

-- Baseline comparison
local baseline_raw = read_file(BASELINE_PATH)
local baseline     = from_json(baseline_raw)
if not baseline then
	print("\nNo baseline found — writing new baseline.")
	write_file(BASELINE_PATH, to_json(results))
	print(string.format("Baseline written to %s", BASELINE_PATH))
else
	local regression = (results.p95 - baseline.p95) / baseline.p95
	if regression > REGRESSION_THRESHOLD then
		io.stderr:write(string.format(
			"\nFAIL: p95 regressed %.1f%% vs baseline (%.4f ms -> %.4f ms). Threshold: %.0f%%.\n",
			regression * 100, baseline.p95, results.p95, REGRESSION_THRESHOLD * 100
		))
		fail = true
	elseif regression < 0 then
		print(string.format("\nImprovement: p95 improved %.1f%% vs baseline — updating baseline.", math.abs(regression) * 100))
		write_file(BASELINE_PATH, to_json(results))
	else
		print(string.format("\nRegression check: p95 +%.1f%% vs baseline (limit: %.0f%%)  OK",
			regression * 100, REGRESSION_THRESHOLD * 100))
	end
end

if fail then
	os.exit(1)
end

print("\nAll checks passed.")
os.exit(0)
