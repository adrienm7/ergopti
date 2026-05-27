--- tests/unit/lib/test_logger_contract.lua

--- ==============================================================================
--- MODULE: Logger Contract Tests
--- DESCRIPTION:
--- Validates the Hammerspoon Logger against the cross-driver test vectors defined
--- in static/ergopti_plus/shared/logger/test_vectors.json. Every vector describes an
--- expected formatted log line; these tests assert that the HS Logger produces
--- exactly that output for each variant/module/message combination.
---
--- RATIONALE:
--- The shared/logger/SPEC.md defines a single line format used by both AHK and HS:
---     YYYY-MM-DD HH:MM:SS:mmm [LEVEL] [Module] message
--- The test_vectors.json replaces the timestamp with the "TIMESTAMP" sentinel so
--- vectors are time-independent. This test loads those vectors and verifies HS
--- compliance, catching any drift from the shared contract.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Path to the shared test vectors file, resolved relative to the driver root.
-- static/ergopti_plus/macos/ and static/ergopti_plus/shared/ are siblings, so
-- shared/ is one level up from the driver root.
local SHARED_VECTORS_PATH = helpers.driver_root() .. "../shared/logger/test_vectors.json"




-- ====================================
--- ====================================
-- ======= 1/ Helpers & Loaders =======
--- ====================================
-- ====================================

--- Reads and decodes the shared logger test vectors.
--- @return table|nil Decoded vectors array, or nil on I/O or parse error.
local function load_vectors()
	local fh = io.open(SHARED_VECTORS_PATH, "r")
	if not fh then
		print("  WARN: cannot open " .. SHARED_VECTORS_PATH)
		return nil
	end
	local raw = fh:read("*a")
	fh:close()
	-- hs.json is available in the test environment via the hs stub
	local ok, data = pcall(hs.json.decode, raw)
	if not ok or type(data) ~= "table" or type(data.vectors) ~= "table" then
		print("  WARN: failed to parse test_vectors.json — " .. tostring(data))
		return nil
	end
	return data.vectors
end

--- Strips the timestamp prefix from a captured log line and normalises whitespace.
--- The timestamp format is "YYYY-MM-DD HH:MM:SS:mmm " (24 chars).
--- DEBUG-axis variants (DEBUG, TRACE, DONE) have a 10-space indent after the
--- timestamp; this is an implementation detail not part of the contract, so we
--- strip it before comparing against the shared expected strings.
--- @param line string Full captured line including timestamp.
--- @return string The normalised "[LEVEL] [Module] message" portion.
local function strip_timestamp(line)
	-- Match the fixed-width timestamp (YYYY-MM-DD HH:MM:SS:mmm) then take the rest
	local rest = line:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d:%d%d%d (.+)$")
	if not rest then return line end
	-- Strip leading whitespace (debug-axis indent)
	return rest:match("^%s*(.+)$") or rest
end




-- ====================================
--- ====================================
-- ======= 2/ Test Registration =======
--- ====================================
-- ====================================

helpers.describe("Logger: shared contract vectors", function()
	-- Load Logger with level forced to DEBUG so every variant is emitted
	local Logger = helpers.load_with_stubs("lib.logger")
	Logger.set_level(Logger.LEVELS.DEBUG)

	local VARIANT_FN = {
		debug   = function(mod, msg, ...) Logger.debug(mod, msg, ...)   end,
		trace   = function(mod, msg, ...) Logger.trace(mod, msg, ...)   end,
		done    = function(mod, msg, ...) Logger.done(mod, msg, ...)    end,
		info    = function(mod, msg, ...) Logger.info(mod, msg, ...)    end,
		start   = function(mod, msg, ...) Logger.start(mod, msg, ...)   end,
		success = function(mod, msg, ...) Logger.success(mod, msg, ...) end,
		warn    = function(mod, msg, ...) Logger.warn(mod, msg, ...)    end,
		error   = function(mod, msg, ...) Logger.error(mod, msg, ...)   end,
	}

	local vectors = load_vectors()

	helpers.it("test_vectors.json is readable", function()
		helpers.assert_true(vectors ~= nil,
			"could not load " .. SHARED_VECTORS_PATH)
		helpers.assert_true(#vectors > 0,
			"test_vectors.json contains no vectors")
	end)

	if not vectors then return end

	for _, vec in ipairs(vectors) do
		local id       = vec.id or "unknown"
		-- Driver-specific fields take priority over the common "message" / "expected"
		local msg      = vec.message_hs or vec.message
		local expected = vec.expected_hs or vec.expected

		-- Vectors without a message or expected string are skipped gracefully;
		-- they may be AHK-only placeholders or documentation entries.
		if type(msg) ~= "string" or type(expected) ~= "string" then goto skip end

		-- Strip the "TIMESTAMP " sentinel prefix from the expected string so we can
		-- compare against just the "[LEVEL] [Module] message" portion.
		local expected_body = expected:match("^TIMESTAMP (.+)$") or expected

		helpers.it(string.format("vector %q: %s", id, vec.description or ""), function()
			local fn = VARIANT_FN[vec.variant]
			helpers.assert_true(fn ~= nil,
				string.format("unknown variant %q in vector %q", tostring(vec.variant), id))

			-- The test stub routes Logger output through hs.console.printStyledtext
			-- (hs.styledtext.new simply returns the string unchanged). We intercept
			-- that path; plain print is a secondary fallback also captured.
			local captured = nil
			local orig_pts  = hs.console and hs.console.printStyledtext
			local orig_print = _G.print
			if hs.console then
				hs.console.printStyledtext = function(line) captured = tostring(line) end
			end
			_G.print = function(line) captured = line end

			-- Build the argument list from the vector's args array
			local args = vec.args or {}
			fn(vec.module, msg, table.unpack(args))

			if hs.console then hs.console.printStyledtext = orig_pts end
			_G.print = orig_print

			helpers.assert_true(captured ~= nil,
				string.format("[%s] logger emitted nothing (level filter?)", id))

			local actual_body = strip_timestamp(captured)
			helpers.assert_eq(actual_body, expected_body,
				string.format("vector %q", id))
		end)

		::skip::
	end
end)
