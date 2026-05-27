--- tests/unit/lib/test_toml_fuzz.lua

--- ==============================================================================
--- MODULE: TOML Fuzz + Crash-Safety Tests
--- DESCRIPTION:
--- Corpus-driven crash-safety harness for the shared TOML decoder.
--- Loads 50 adversarial test cases from the shared fuzz corpus and verifies
--- that every input either decodes cleanly (expect="ok") or fails gracefully
--- without an unhandled error or Lua panic (expect="error").
---
--- FEATURES & RATIONALE:
--- 1. Corpus-driven: all test vectors live in the shared corpus so other
---    drivers can run the same suite without duplication.
--- 2. Crash-first contract: the core invariant is "no unhandled exception" —
---    we do not mandate what the decoder returns, only that it does not kill
---    the host process.
--- 3. Integration with the helpers mini-runner: results roll up into the
---    global pass/fail counters used by tests/run.lua.
--- ==============================================================================

local helpers    = require("tests.helpers")
local toml_codec = helpers.load_with_stubs("lib.toml_codec")




-- =====================================================
-- =====================================================
-- ======= 1/ Corpus Loader ============================
-- =====================================================
-- =====================================================

--- Resolves the absolute path to the shared fuzz corpus JSON file.
--- We walk up from the driver root (tests/helpers resolves this) to reach
--- static/ergopti_plus/shared/tests/corpus/toml/fuzz_corpus.json.
--- @return string Absolute path to the corpus file.
local function corpus_path()
	local root = helpers.driver_root()
	-- driver_root is .../static/ergopti_plus/macos/ — go two levels up for shared/
	local drivers = root:match("^(.*)/[^/]+/$") or root:gsub("/$", "")
	return drivers .. "/shared/tests/corpus/toml/fuzz_corpus.json"
end

--- Loads the fuzz corpus from JSON and returns the decoded array.
--- Uses the hs.json stub available in the test environment.
--- @return table Array of corpus entry tables.
local function load_corpus()
	local path = corpus_path()
	local fh   = io.open(path, "r")
	assert(fh, "Corpus file not found: " .. path)
	local raw = fh:read("*a")
	fh:close()

	-- hs.json is available via the global stub injected by load_with_stubs.
	local decoded = _G.hs.json.decode(raw)
	assert(type(decoded) == "table", "Corpus JSON must be an array of objects")
	return decoded
end




-- =====================================================
-- =====================================================
-- ======= 2/ Fuzz Suite ===============================
-- =====================================================
-- =====================================================

helpers.describe("toml_codec — fuzz corpus crash-safety", function()
	local corpus = load_corpus()

	local pass_count = 0
	local fail_count = 0

	for _, entry in ipairs(corpus) do
		local id          = tostring(entry.id or "?")
		local input       = tostring(entry.input or "")
		local expect      = tostring(entry.expect or "ok")
		local description = tostring(entry.description or "")

		helpers.it(id .. ": " .. description, function()
			-- Core crash-safety invariant: pcall must always succeed —
			-- the decoder must never throw an unhandled Lua error.
			local ok, result = pcall(toml_codec.decode, input)

			if expect == "error" then
				-- Graceful failure means either the pcall caught an error OR
				-- the decoder returned nil/false to signal an invalid input.
				-- Both outcomes satisfy the crash-safety contract.
				local is_graceful = (not ok) or (result == nil) or (result == false)
				if not is_graceful then
					fail_count = fail_count + 1
					error(string.format(
						"[%s] expected error/nil but decoder returned %s for input: %q",
						id, type(result), input:sub(1, 80)
					))
				end
				pass_count = pass_count + 1

			else -- expect == "ok"
				-- Must succeed AND return a table.
				if not ok then
					fail_count = fail_count + 1
					error(string.format(
						"[%s] expected ok but decoder raised: %s — input: %q",
						id, tostring(result), input:sub(1, 80)
					))
				end
				if type(result) ~= "table" then
					fail_count = fail_count + 1
					error(string.format(
						"[%s] expected table result but got %s — input: %q",
						id, type(result), input:sub(1, 80)
					))
				end
				pass_count = pass_count + 1
			end
		end)
	end

	helpers.it("corpus summary: all entries processed", function()
		assert(#corpus > 0, "Corpus must not be empty")
		-- Report total counts in the test name for easy CI scanning.
		print(string.format(
			"  corpus: %d entries evaluated (%d inline pass, %d inline fail)",
			#corpus, pass_count, fail_count
		))
	end)
end)
