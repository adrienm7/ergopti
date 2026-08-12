--- tests/unit/ui/test_preferences_corrupt_not_absent.lua

--- ==============================================================================
--- MODULE: Regression — a corrupt config.toml must not be treated as absent
---         (preferences-corrupt-not-absent)
--- DESCRIPTION:
--- Make config.toml unparseable — a typo in the expert [script]/[features]
--- layer, a git merge-conflict marker, or a torn write from the cloud-synced
--- directory it lives in — then reload Hammerspoon. Every preference is gone,
--- with no warning, no backup and no way back: boot factory-resets every group
--- and then OVERWRITES the file with those defaults.
---
--- ROOT CAUSE ENCODED: Preferences.load collapsed three different outcomes into
--- one silent empty table — file missing, file unreadable, decode failed. The
--- caller derives `config_absent` from `next(saved) == nil`, and that flag
--- legitimately means "fresh install, seed the factory defaults and save them".
--- A corrupt file produced a byte-identical signal, so the recovery path for a
--- brand-new user became the destruction path for an existing one.
---
--- The loss is permanent on macOS: preferences.save keeps a .bak only when
--- package.config's separator is a backslash, i.e. on Windows.
---
--- DECISIVE CORROBORATION: the karabiner loader already fixed this exact class,
--- and test_config_corrupt_toml's own docstring describes the identical
--- "absent vs corrupt both yield nil, then get persisted over the recoverable
--- file" failure. Preferences.load is the parallel loader that never got it.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Write a throwaway config file and return its path.
local function write_temp(contents)
	local path = os.tmpname()
	-- os.tmpname can return a bare name on some platforms; keep it beside the
	-- other temp files rather than in the current working directory.
	local fh = io.open(path, "w")
	if not fh then return nil end
	fh:write(contents)
	fh:close()
	return path
end

--- Reads one throwaway fixture after any filesystem override has been restored.
--- @param path string Fixture path.
--- @return string contents Exact fixture bytes.
local function read_temp(path)
	local fh = assert(io.open(path, "rb"))
	local contents = assert(fh:read("*a"))
	assert(fh:close())
	return contents
end

--- Runs one callback with a temporary io.open implementation.
--- @param replacement function Temporary open implementation.
--- @param callback function Protected operation.
--- @return any result First callback result.
--- @return any extra Second callback result.
local function with_open(replacement, callback)
	local original = io.open
	io.open = replacement
	local ok, result, extra = xpcall(callback, debug.traceback)
	io.open = original
	if not ok then error(result, 0) end
	return result, extra
end

local function preferences()
	package.loaded["adapters.file_system"] = {
		read_with_status = function(path)
			local open_ok, fh, open_detail, open_code = pcall(io.open, path, "r")
			if not open_ok or not fh then
				if open_ok and open_code == 2 then return nil, "absent" end
				return nil, "error", open_detail
			end
			local read_ok, content = pcall(fh.read, fh, "*a")
			local close_ok, closed = pcall(fh.close, fh)
			if not read_ok or type(content) ~= "string" or not close_ok or closed ~= true then
				return nil, "error", "stream did not commit"
			end
			return content, "ok"
		end,
	}
	package.loaded["infra.preferences"] = nil
	return require("infra.preferences")
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ The three outcomes are distinguishable =======================
-- =========================================================================
-- =========================================================================

helpers.describe("Preferences.load: corrupt is not absent", function()
	helpers.it("a missing file reports absent", function()
		local prefs = preferences()
		local saved, status = prefs.load("/nonexistent/ergopti-test/config.toml")

		helpers.assert_true(type(saved) == "table", "load must still return a table")
		helpers.assert_eq(status, "absent",
			"a genuinely missing file must report absent — that is the fresh-install path, and it "
				.. "is the ONLY case in which seeding factory defaults and saving them is correct")
	end)

	helpers.it("an existing file whose open is refused reports corrupt and preserves its bytes", function()
		local prefs = preferences()
		local sentinel = "PRIVATE-CONFIG-SENTINEL"
		local private_failure = "PRIVATE-OPEN-FAILURE"
		local path = write_temp(sentinel)
		helpers.assert_true(path ~= nil, "the existing fixture file must be writable")
		local original_open = io.open

		local saved, status = with_open(function(candidate, mode)
			if candidate == path and mode == "r" then return nil, private_failure, 13 end
			return original_open(candidate, mode)
		end, function()
			return prefs.load(path)
		end)

		helpers.assert_true(type(saved) == "table", "an unreadable file must remain non-throwing")
		helpers.assert_eq(status, "corrupt",
			"a permission or transient-lock failure must never authorize the fresh-install writer")
		helpers.assert_eq(read_temp(path), sentinel,
			"classification of an unreadable existing config must preserve its exact bytes")
		os.remove(path)
	end)

	helpers.it("read and close failures report corrupt without escaping", function()
		local prefs = preferences()
		local cases = {
			{
				label = "read throw",
				handle = {
					read = function() error("PRIVATE-READ-FAILURE", 0) end,
					close = function() return true end,
				},
			},
			{
				label = "close refusal",
				handle = {
					read = function() return "[script]\nlocale = \"fr\"\n" end,
					close = function() return false end,
				},
			},
		}

		for _, case in ipairs(cases) do
			local call_ok, saved, status = pcall(function()
				return with_open(function() return case.handle end, function()
					return prefs.load("/controlled/config.toml")
				end)
			end)
			helpers.assert_true(call_ok, case.label .. " must not escape Preferences.load")
			helpers.assert_true(type(saved) == "table", case.label .. " must return a safe table")
			helpers.assert_eq(status, "corrupt",
				case.label .. " must never be indistinguishable from a genuinely missing file")
		end
	end)

	helpers.it("an unparseable file reports corrupt, not absent", function()
		local prefs = preferences()
		local path = write_temp("<<<<<<< HEAD\nthis is not = [valid toml\n=======\n")
		helpers.assert_true(path ~= nil, "the fixture file must be writable")

		local saved, status = prefs.load(path)
		os.remove(path)

		helpers.assert_true(type(saved) == "table", "load must stay non-throwing on malformed input")
		helpers.assert_eq(status, "corrupt",
			"an unparseable config.toml must report CORRUPT. Reported as absent it is "
				.. "indistinguishable from a fresh install, and boot then factory-resets every group "
				.. "and overwrites the file with defaults — permanently, because the .bak path is "
				.. "Windows-only")
	end)

	helpers.it("a valid file reports ok and decodes", function()
		local prefs = preferences()
		local path = write_temp("[script]\nlocale = \"fr\"\n")
		helpers.assert_true(path ~= nil, "the fixture file must be writable")

		local saved, status = prefs.load(path)
		os.remove(path)

		helpers.assert_eq(status, "ok",
			"a valid file must report ok — without this the guard could be satisfied by reporting "
				.. "corrupt for everything, which would block every legitimate save")
		helpers.assert_true(type(saved) == "table",
			"a valid file must decode to a table. Whether it is POPULATED depends on KEY_MAP "
				.. "recognising the keys, which is a different concern from this finding — asserting "
				.. "it here would couple the corruption guard to the preference schema")
	end)

	helpers.it("the failure is logged, not swallowed", function()
		-- Source-level, not behavioural: helpers.load_with_stubs installs a NOOP
		-- logger (set_sink is a no-op there), so a sink capture around a stubbed
		-- module observes nothing and would pass vacuously whatever the code did.
		local src = helpers.read_driver_source("flatten_from_disk")
		helpers.assert_true(src ~= nil and src ~= "",
			"the preferences source must be locatable by its flatten_from_disk symbol")

		local at = src:find("function M.load", 1, true)
		helpers.assert_true(at ~= nil, "M.load must exist")
		local body = src:sub(at, at + 1600)

		helpers.assert_true(body:find("Logger.error", 1, true) ~= nil,
			"a corrupt config must be reported at ERROR. Silent, the user's first sign is that "
				.. "every setting reverted overnight, with nothing in the log connecting it to a cause")
		helpers.assert_true(body:find("corrupt", 1, true) ~= nil,
			"and it must return the corrupt status alongside that log line, so the caller can act "
				.. "on it rather than merely being told after the fact")
	end)
end)

package.loaded["adapters.file_system"] = nil
package.loaded["infra.preferences"] = nil




-- =========================================================================
-- =========================================================================
-- ======= 2/ The caller acts on the distinction ===========================
-- =========================================================================
-- =========================================================================

helpers.describe("menu boot: a corrupt config never triggers the factory save", function()
	helpers.it("config_absent is derived from the load status, not just emptiness", function()
		local src = helpers.read_driver_source("config_absent")
		helpers.assert_true(src ~= nil and src ~= "",
			"the menu boot source must be locatable by its config_absent symbol")

		local at = src:find("local config_absent", 1, true)
		helpers.assert_true(at ~= nil, "config_absent must still be derived at boot")

		local line = src:sub(at, (src:find("\n", at) or (at + 200)))
		-- "absent" alone is NOT accepted as evidence: the variable is literally
		-- named config_absent, so that word matches the UNFIXED line too. This
		-- assertion passed against the bug until the alternative was removed.
		-- The loader's status must actually be consulted.
		helpers.assert_true(
			line:find("load_status", 1, true) ~= nil,
			"config_absent must consult the loader's status. Derived from `next(saved) == nil` "
				.. "alone, a corrupt file is indistinguishable from a fresh install — and that flag "
				.. "is what runs the factory reset AND the save that overwrites the user's file. "
				.. "Got: " .. line
		)
	end)

	helpers.it("the save is still reached for a genuine fresh install", function()
		local src = helpers.read_driver_source("config_absent")
		helpers.assert_true(src:find("if config_absent and save_prefs() ~= true then", 1, true) ~= nil,
			"a real fresh install must still persist its seeded defaults — narrowing the flag must "
				.. "not disable the path it exists for")
	end)
end)
