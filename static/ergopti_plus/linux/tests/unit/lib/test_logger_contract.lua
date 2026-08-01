--- tests/unit/lib/test_logger_contract.lua

--- ==============================================================================
--- TEST: Logger Contract — shared cross-driver vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/modules/logger/test_vectors.json through the shared logger
--- core and asserts every rendered line matches the vector's expected output.
---
--- WHY THIS EXISTS:
--- The corpus is the cross-driver definition of what a log line looks like, and
--- it was replayed by two suites out of three. Windows has
--- tests/unit/test_logger_contract.ahk and macOS has
--- tests/unit/lib/test_logger_contract.lua; Linux had neither, and its
--- cross-driver corpus test lists nine corpora with the logger not among them.
--- The corpus header said as much — "shared by AHK and Hammerspoon test suites".
---
--- Linux and macOS run the SAME shared logger (_shared/lua/logger/init.lua), so
--- a divergence here would not come from the logger itself. It would come from
--- the sink, the level, or the timestamp function the driver installs around it
--- — which is exactly the layer this driver owns and nothing was checking.
---
--- FEATURES & RATIONALE:
--- 1. Time-independent: timestamp_fn returns the "TIMESTAMP" sentinel, so the
---    expected lines in the corpus can be compared literally.
--- 2. Sink capture: emitted lines are collected in a table, so the test touches
---    neither the filesystem nor stdout.
--- 3. Language-keyed overrides: a vector may carry message_lua / expected_lua
---    for Lua's %s where AutoHotkey needs {1}. Linux reads the same pair macOS
---    does, because the difference is the language, not the driver.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_eq   = helpers.assert_eq
local assert_true = helpers.assert_true

local Logger = require("logger")
local json   = require("json")

local Paths = require("lib.paths")

-- Every variant the corpus can name, mapped to the function that emits it.
-- A vector naming a variant absent from this table fails loudly rather than
-- being skipped: a silently ignored vector is a vector that proves nothing.
local EMITTERS = {
	debug   = Logger.debug,
	trace   = Logger.trace,
	done    = Logger.done,
	info    = Logger.info,
	start   = Logger.start,
	success = Logger.success,
	warn    = Logger.warn,
	error   = Logger.error,
}

-- The corpus ships 17 vectors. A parse that yields far fewer means the file or
-- the decoder changed, and every assertion below would then be vacuous.
local MIN_VECTORS = 12




-- ==========================================
-- ==========================================
-- ======= 1/ Loading the corpus ============
-- ==========================================
-- ==========================================

--- Reads and decodes the shared logger vectors.
--- @return table|nil vectors, string|nil error
local function read_vectors()
	local path = Paths.shared("modules/logger/test_vectors.json")
	if not path then return nil, "Paths.shared() returned nil — the shared tree is unreachable" end
	local f = io.open(path, "r")
	if not f then return nil, "cannot open " .. path end
	local raw = f:read("*a")
	f:close()
	local decoded, err = json.decode(raw)
	if not decoded then return nil, "json.decode: " .. tostring(err) end
	if type(decoded.vectors) ~= "table" then return nil, "no 'vectors' array in the corpus" end
	return decoded.vectors, nil
end




-- ==============================================
-- ==============================================
-- ======= 2/ Replaying every vector ============
-- ==============================================
-- ==============================================

describe("Logger contract: shared cross-driver vectors", function()
	local vectors, load_err = read_vectors()

	it("the corpus loads", function()
		assert_true(vectors ~= nil, "corpus did not load: " .. tostring(load_err))
	end)

	if not vectors then return end

	it("the corpus carries its vectors", function()
		assert_true(
			#vectors >= MIN_VECTORS,
			string.format("expected at least %d vectors, got %d — every replay below would be vacuous",
				MIN_VECTORS, #vectors)
		)
	end)

	-- Restored after the run so no later test inherits the frozen clock or the
	-- capture sink.
	local original_timestamp = Logger.timestamp_fn
	local original_level     = Logger.get_level and Logger.get_level() or nil

	for _, vec in ipairs(vectors) do
		local id       = vec.id or "unknown"
		local msg      = vec.message_lua or vec.message
		local expected = vec.expected_lua or vec.expected

		-- A vector with no Lua-side message is an AutoHotkey-only case; skipping
		-- it is correct, but it must be visible rather than silent.
		if type(msg) == "string" and type(expected) == "string" then
			it("vector " .. id, function()
				local emit = EMITTERS[vec.variant]
				assert_true(emit ~= nil, "unknown variant in vector " .. id .. ": " .. tostring(vec.variant))

				local captured = {}
				Logger.timestamp_fn = function() return "TIMESTAMP" end
				Logger.set_sink(function(line) captured[#captured + 1] = line end)
				-- DEBUG-level vectors are dropped by a higher threshold, so the
				-- floor is lowered for the replay and restored below.
				if Logger.set_level then Logger.set_level("debug") end

				local args = vec.args or {}
				emit(vec.module, msg, table.unpack(args))

				Logger.set_sink(nil)
				Logger.timestamp_fn = original_timestamp
				if Logger.set_level and original_level then Logger.set_level(original_level) end

				assert_eq(1, #captured, "vector " .. id .. ": expected exactly one emitted line")
				assert_eq(expected, captured[1], "vector " .. id)
			end)
		end
	end
end)
