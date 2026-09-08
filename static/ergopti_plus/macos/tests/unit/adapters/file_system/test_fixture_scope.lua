--- tests/unit/adapters/file_system/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: FileSystem Fixture Isolation
--- DESCRIPTION:
--- Proves exact environment restoration across construction and callback outcomes.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
local OWNERS = { "hs", "adapters.file_system", "infra.fs_dir", "infra.logger" }

local function with_observer(callback)
	helpers.with_stub_scope(OWNERS, function()
		local saved_open, saved_rename = io.open, os.rename
		local saved_preload = package.preload["adapters.file_system"]
		local outcome = table.pack(xpcall(callback, debug.traceback))
		io.open, os.rename = saved_open, saved_rename
		package.preload["adapters.file_system"] = saved_preload
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("FileSystem fixture isolation", function()
	for _, mode in ipairs({ "success", "callback failure", "construction failure" }) do
		helpers.it("(filesystem-fixture-scope) restores owners after " .. mode, function()
			with_observer(function()
				local expected = {}
				for _, name in ipairs(OWNERS) do
					expected[name] = {}
					package.loaded[name] = expected[name]
				end
				local native = rawget(_G, "hs")
				local open, rename = io.open, os.rename
				local marker = "filesystem fixture injected failure"
				local entered = false
				if mode == "construction failure" then
					package.preload["adapters.file_system"] = function() error(marker, 0) end
				end
				local ok, result = pcall(with_fixture, function(fixture)
					entered = true
					local adapter = fixture.make_adapter()
					helpers.assert_type(adapter.write, "function")
					helpers.assert_true(adapter ~= expected["adapters.file_system"])
					if mode == "callback failure" then
						io.open = function() error("leaked open", 0) end
						os.rename = function() error("leaked rename", 0) end
						error(marker, 0)
					end
					return "completed"
				end)
				helpers.assert_eq(entered, true)
				helpers.assert_eq(ok, mode == "success")
				if mode == "success" then
					helpers.assert_eq(result, "completed")
				else
					helpers.assert_true(tostring(result):find(marker, 1, true) ~= nil)
				end
				helpers.assert_true(rawequal(rawget(_G, "hs"), native))
				helpers.assert_true(io.open == open and os.rename == rename)
				for _, name in ipairs(OWNERS) do
					helpers.assert_true(package.loaded[name] == expected[name], name .. " must be restored")
				end
			end)
		end)
	end

	helpers.it("(filesystem-fixture-scope) releases fresh owners without inheriting native wrappers", function()
		with_observer(function()
			local poison_calls = 0
			local poison = function() poison_calls = poison_calls + 1 end
			local native = { fs = { attributes = poison, symlinkAttributes = poison, mkdir = poison, rmdir = poison } }
			_G.hs = native
			local previous
			for attempt = 1, 2 do
				with_fixture(function(fixture)
					local adapter = fixture.make_adapter()
					helpers.assert_type(adapter.write, "function")
					helpers.assert_true(fixture.HOST_ATTRIBUTES ~= poison)
					helpers.assert_true(fixture.HOST_SYMLINK_ATTRIBUTES ~= poison)
					helpers.assert_true(fixture.HOST_MKDIR ~= poison and fixture.HOST_RMDIR ~= poison)
					if attempt == 2 then helpers.assert_true(adapter ~= previous) end
					previous = adapter
				end)
				helpers.assert_true(rawequal(rawget(_G, "hs"), native))
				for _, name in ipairs(OWNERS) do helpers.assert_nil(package.loaded[name], name) end
			end
			helpers.assert_eq(poison_calls, 0)
		end)
	end)
end)
