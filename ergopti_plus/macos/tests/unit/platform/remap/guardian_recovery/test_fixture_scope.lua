--- tests/unit/platform/remap/guardian_recovery/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: Guardian Recovery Fixture Isolation
--- DESCRIPTION:
--- Proves filesystem dependencies follow the current native owner and restore it.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_remap = require("tests.support.guardian_recovery_fixture").with_remap
local OWNERS = {
	"adapters.file_system", "infra.fs_dir", "infra.logger",
	"platform.remap", "hs", "tests.stubs.hs",
}

local function with_observer(callback)
	helpers.with_stub_scope(OWNERS, function()
		local preload = package.preload["platform.remap"]
		local getenv, execute, popen = os.getenv, os.execute, io.popen
		local outcome = table.pack(xpcall(callback, debug.traceback))
		package.preload["platform.remap"] = preload
		os.getenv, os.execute, io.popen = getenv, execute, popen
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("Guardian recovery fixture isolation", function()
	for _, mode in ipairs({ "success", "callback failure", "construction failure" }) do
		helpers.it("(guardian-fixture-scope) restores cold dependencies after " .. mode, function()
			with_observer(function()
				local native = rawget(_G, "hs")
				local getenv, execute, popen = os.getenv, os.execute, io.popen
				local marker = "guardian fixture injected failure"
				if mode == "construction failure" then
					package.preload["platform.remap"] = function() error(marker, 0) end
				end
				local entered = false
				local ok, err = pcall(with_remap, nil, function(remap)
					entered = true
					helpers.assert_type(remap.init, "function")
					helpers.assert_type(package.loaded["adapters.file_system"].exists, "function")
					helpers.assert_type(package.loaded["infra.fs_dir"].try_entries, "function")
					if mode == "callback failure" then error(marker, 0) end
				end)
				helpers.assert_eq(entered, mode ~= "construction failure")
				helpers.assert_eq(ok, mode == "success")
				if not ok then helpers.assert_true(tostring(err):find(marker, 1, true) ~= nil) end
				helpers.assert_true(rawequal(rawget(_G, "hs"), native))
				helpers.assert_true(os.getenv == getenv and os.execute == execute and io.popen == popen)
				for _, name in ipairs(OWNERS) do helpers.assert_nil(package.loaded[name], name) end
			end)
		end)
	end

	helpers.it("(guardian-fixture-scope) refreshes warm native consumers and restores their identities", function()
		with_observer(function()
			local previous = {}
			with_remap(nil, function()
				previous.file_system = require("adapters.file_system")
				previous.fs_dir = require("infra.fs_dir")
				hs.fs.attributes = function() return nil end
				hs.fs.dir = function() error("retired directory host", 0) end
			end)
			package.loaded["adapters.file_system"] = previous.file_system
			package.loaded["infra.fs_dir"] = previous.fs_dir
			for _, fail in ipairs({ false, true }) do
				local marker = "warm guardian callback failure"
				local ok, err = pcall(with_remap, nil, function()
					local attributes_calls, directory_calls = 0, 0
					hs.fs.attributes = function(path)
						helpers.assert_eq(path, "guardian-current-file")
						attributes_calls = attributes_calls + 1
						return { mode = "file" }
					end
					hs.fs.dir = function(path)
						helpers.assert_eq(path, "guardian-current-directory")
						directory_calls = directory_calls + 1
						local state = {}
						return function(actual_state)
							helpers.assert_true(actual_state == state)
							return nil
						end, state
					end
					helpers.assert_eq(require("adapters.file_system").exists("guardian-current-file"), true)
					local entries, listed = require("infra.fs_dir").try_entries("guardian-current-directory")
					helpers.assert_eq(listed, true)
					helpers.assert_eq(#entries, 0)
					helpers.assert_eq(attributes_calls, 1)
					helpers.assert_eq(directory_calls, 1)
					helpers.assert_true(require("adapters.file_system") ~= previous.file_system)
					helpers.assert_true(require("infra.fs_dir") ~= previous.fs_dir)
					if fail then error(marker, 0) end
				end)
				helpers.assert_eq(ok, not fail, tostring(err))
				if not ok then helpers.assert_true(tostring(err):find(marker, 1, true) ~= nil) end
				helpers.assert_true(package.loaded["adapters.file_system"] == previous.file_system)
				helpers.assert_true(package.loaded["infra.fs_dir"] == previous.fs_dir)
			end
		end)
	end)
end)
