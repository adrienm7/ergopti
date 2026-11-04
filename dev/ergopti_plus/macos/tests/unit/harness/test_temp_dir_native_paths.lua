--- tests/unit/harness/test_temp_dir_native_paths.lua

--- ==============================================================================
--- MODULE: Native Scratch Directory Paths
--- DESCRIPTION:
--- A scratch directory is an existing native pathname, not a display spelling.
--- Real allocations prove that environment path bytes still name the owned root.
--- ==============================================================================

local helpers = require("tests.helpers")
local Native = require("luv")
local PRIVATE_DIRECTORY_MODE = tonumber("700", 8)

helpers.describe("Native scratch directory paths", function()
	local cases = { { label = "quote", basename = "literal'quote" } }
	if package.config:sub(1, 1) == "\\" then
		-- Windows cannot represent a backslash or newline inside a basename.
		cases[#cases + 1] = { label = "space", basename = "literal space" }
	else
		cases[#cases + 1] = { label = "backslash", basename = "literal\\backslash" }
		cases[#cases + 1] = { label = "newline", basename = "literal\nnewline" }
	end
	for _, fixture in ipairs(cases) do
		helpers.it("(native-temp-dir) allocates beneath an existing " .. fixture.label .. " TMPDIR", function()
			for _, operation in ipairs({ "fs_mkdtemp", "fs_mkdir", "fs_realpath", "fs_rmdir", "fs_lstat" }) do
				helpers.assert_eq(debug.getinfo(Native[operation], "S").what, "C", "use the real native " .. operation)
			end
			local root = assert(Native.fs_mkdtemp(helpers.temp_dir() .. "/ergopti-native-temp.XXXXXX"))
			local owned = { root }
			local original_getenv = os.getenv
			local ok, failure = xpcall(function()
				local expected = root .. "/" .. fixture.basename
				assert(Native.fs_mkdir(expected, PRIVATE_DIRECTORY_MODE))
				owned[#owned + 1] = expected
				os.getenv = function(name)
					if name == "TMPDIR" then return expected end
					return original_getenv(name)
				end
				local called, returned = pcall(helpers.temp_dir)
				os.getenv = original_getenv
				if not called then error(returned, 0) end
				local resolved, reason = Native.fs_realpath(returned)
				helpers.assert_true(resolved ~= nil, "returned TMPDIR must exist: " .. returned .. " (" .. tostring(reason) .. ")")
				local expected_root = assert(Native.fs_realpath(expected))
				helpers.assert_eq(resolved, expected_root, "the returned directory must be the exact owned root")
				if package.config:sub(1, 1) ~= "\\" then
					helpers.assert_eq(returned, expected, "POSIX filename bytes must be preserved")
				end
				local allocation = assert(Native.fs_mkdtemp(returned .. "/allocated.XXXXXX"))
				owned[#owned + 1] = allocation
				helpers.assert_eq(assert(Native.fs_realpath(allocation .. "/..")), expected_root,
					"the actual allocation must stay beneath the owned root")
			end, debug.traceback)
			os.getenv = original_getenv
			local cleanup = {}
			for index = #owned, 1, -1 do
				local retired, reason = Native.fs_rmdir(owned[index])
				if retired ~= true then cleanup[#cleanup + 1] = owned[index] .. ": " .. tostring(reason) end
				local remaining, detail, code = Native.fs_lstat(owned[index])
				if remaining ~= nil or code ~= "ENOENT" then
					cleanup[#cleanup + 1] = owned[index] .. ": removal not observed (" .. tostring(detail) .. ")"
				end
			end
			if #cleanup > 0 then
				error(tostring(failure or "scratch cleanup refused") .. "\nScratch retirement failures: " .. table.concat(cleanup, "; "), 0)
			end
			if not ok then error(failure, 0) end
		end)
	end
	if package.config:sub(1, 1) ~= "\\" then
		helpers.it("(native-temp-dir) refuses a drive-qualified relative path on POSIX", function()
			local provided = "C:/relative-on-posix"
			helpers.assert_eq(require("native_path").is_absolute(provided), false,
				"the real native path owner classifies the supplied value")
			local original_getenv = os.getenv
			os.getenv = function(name)
				if name == "TMPDIR" then return provided end
				return original_getenv(name)
			end
			local accepted, result = pcall(helpers.temp_dir)
			os.getenv = original_getenv
			helpers.assert_eq(accepted, false, "a scratch directory must be absolute on its actual host")
			helpers.assert_true(tostring(result):find("no absolute scratch directory", 1, true) ~= nil,
				"the invalid path must fail with its admission reason: " .. tostring(result))
		end)
	end
end)
