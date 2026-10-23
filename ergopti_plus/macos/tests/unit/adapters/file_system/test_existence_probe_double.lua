--- tests/unit/adapters/file_system/test_existence_probe_double.lua

--- ==============================================================================
--- MODULE: Existence probe double for hs fixtures without hs.fs
--- DESCRIPTION:
--- FileSystem.exists() stats through `/bin/test -e` when hs.fs is absent. The
--- Ollama and MLX fixtures used a constant hs.execute stub, so the real adapter
--- classified the bundled network policy as missing and every pull was refused
--- (exists-probe-double-2026-10-21). helpers.existence_probe_execute answers the
--- probe from the real filesystem and leaves every other command to the fixture.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the real adapter's exists() under an hs double with no hs.fs.
--- @param execute function hs.execute double.
--- @param path string Path to classify.
--- @return boolean present
local function exists_with(execute, path)
	local previous_hs = _G.hs
	local result
	local ok, failure = xpcall(function()
		helpers.with_fresh_modules({ "adapters.file_system" }, function()
			_G.hs = { execute = execute }
			result = require("adapters.file_system").exists(path)
		end)
	end, debug.traceback)
	_G.hs = previous_hs
	if not ok then error(failure, 0) end
	return result
end


helpers.describe("Existence probe double (exists-probe-double-2026-10-21)", function()
	helpers.it("lets the real adapter find a bundled driver file", function()
		local policy = helpers.driver_root() .. "modules/llm/network-retry.sh"
		helpers.assert_eq(exists_with(helpers.existence_probe_execute(), policy), true)
	end)

	helpers.it("reports a missing path as absent", function()
		local missing = helpers.driver_root() .. "modules/llm/no-such-policy.sh"
		helpers.assert_eq(exists_with(helpers.existence_probe_execute(), missing), false)
	end)

	helpers.it("unquotes an embedded apostrophe before the stat", function()
		local seen
		local execute = helpers.existence_probe_execute(nil, function(path)
			seen = path
			return true
		end)
		local _, _, kind, rc = execute("/bin/test -e '/tmp/it'\\''s here'")
		helpers.assert_eq(kind, "exit")
		helpers.assert_eq(rc, 0)
		helpers.assert_eq(seen, "/tmp/it's here")
	end)

	helpers.it("hands every other command to the fixture's fallback", function()
		local execute = helpers.existence_probe_execute(function(command) return "fallback:" .. command end)
		helpers.assert_eq(execute("uname -m"), "fallback:uname -m")
	end)

	helpers.it("raises on an unexpected command without a fallback", function()
		local okay, detail = pcall(helpers.existence_probe_execute(), "uname -m")
		helpers.assert_eq(okay, false)
		helpers.assert_contains(tostring(detail), "unexpected hs.execute in fixture")
	end)
end)
