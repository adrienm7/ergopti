--- tests/unit/adapters/file_system/test_file_system_exists_without_metadata.lua

--- ==============================================================================
--- MODULE: FileSystem exists() without hs.fs metadata
--- DESCRIPTION:
--- Without hs.fs.attributes, exists() opened the path for reading. An open
--- refusal is not absence: an unreadable file or a file in an unreadable
--- directory was reported missing, and opening a FIFO without a writer blocks
--- (exists-without-metadata-2026-10-21). The fallback now asks the shell's
--- `test -e`, which stats the path and never opens it.
--- ==============================================================================

local helpers = require("tests.helpers")

-- What the modelled filesystem holds; `test -e` answers from stat(2).
local ENTRIES = {
	["/private/unreadable.toml"] = true,
	["/private/fifo"] = true,
	["/tmp/it's here"] = true,
}

--- Runs exists() with no hs.fs, a POSIX `test -e` double and an io.open spy.
--- @param path string Path to probe.
--- @return boolean result, integer opens, table commands
local function probe(path)
	local previous_hs, previous_open = _G.hs, io.open
	local result, opens, commands = nil, 0, {}
	local ok, failure = xpcall(function()
		helpers.with_fresh_modules({ "adapters.file_system" }, function()
			local adapter = helpers.load_with_stubs("adapters.file_system", {
				execute = function(command)
					commands[#commands + 1] = command
					local quoted = command:match("^/bin/test %-e (.+)$")
					if not quoted then return "", nil, "exit", 2 end
					local target = quoted:match("^'(.*)'$"):gsub("'\\''", "'")
					if ENTRIES[target] then return "", true, "exit", 0 end
					return "", nil, "exit", 1
				end,
			})
			hs.fs = nil
			io.open = function(target)
				opens = opens + 1
				if target == "/private/fifo" then error("open(2) of a FIFO without a writer blocks") end
				if ENTRIES[target] then return nil, target .. ": Permission denied", 13 end
				return nil, target .. ": No such file or directory", 2
			end
			result = adapter.exists(path)
			io.open = previous_open
		end)
	end, debug.traceback)
	io.open, _G.hs = previous_open, previous_hs
	if not ok then error(failure, 0) end
	return result, opens, commands
end


helpers.describe("FileSystem.exists without hs.fs never opens the path (exists-without-metadata-2026-10-21)", function()
	helpers.it("reports an unreadable file as present", function()
		local result, opens = probe("/private/unreadable.toml")
		helpers.assert_eq(result, true, "EACCES on open is not absence")
		helpers.assert_eq(opens, 0)
	end)

	helpers.it("reports a FIFO as present without opening it", function()
		local result, opens = probe("/private/fifo")
		helpers.assert_eq(result, true)
		helpers.assert_eq(opens, 0, "opening a FIFO to test existence can block forever")
	end)

	helpers.it("reports a missing path as absent", function()
		helpers.assert_eq((probe("/private/missing")), false)
	end)

	helpers.it("quotes the path for the shell", function()
		local result, _, commands = probe("/tmp/it's here")
		helpers.assert_eq(result, true)
		helpers.assert_eq(#commands, 1)
	end)
end)
