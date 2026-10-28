--- tests/meta/harness/test_runtime_source_inventory.lua

--- ==============================================================================
--- MODULE: Runtime Source Inventory Regressions
--- DESCRIPTION:
--- Reports every source I/O failure without publishing a failed unit, preserving
--- file boundaries, filtering and valid extensionless executable sources.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.source_read_fixture")
local Inventory = require("tests.support.runtime_source_inventory")
local Discovery = require("test.runner_discovery")

helpers.describe("complete runtime source inventory", function()
	for _, mode in ipairs({ "open_refusal", "open_throw", "read_refusal", "read_throw", "close_refusal", "close_throw" }) do
		helpers.it("(runtime-source-inventory) reports " .. mode .. " and recovers after repair", function()
			Fixture.with_fault(helpers.driver_root(), mode, function(state)
				local units, unreadable = Inventory.read(helpers.driver_root())
				helpers.assert_eq(units, { { path = state.paths[1], body = "first source" } })
				helpers.assert_eq(#unreadable, 1, "the owning guard must receive every failed source")
				helpers.assert_true(unreadable[1]:find(state.paths[2], 1, true) ~= nil)
				helpers.assert_true(unreadable[1]:find("controlled " .. mode, 1, true) ~= nil)
				local opened_second = mode ~= "open_refusal" and mode ~= "open_throw"
				helpers.assert_eq(state.closes, opened_second and 2 or 1)
				state.repaired = true
				units, unreadable = Inventory.read(helpers.driver_root())
				helpers.assert_eq(unreadable, {})
				helpers.assert_eq(units, {
					{ path = state.paths[1], body = "first source" },
					{ path = state.paths[2], body = "second source" },
				})
				helpers.assert_eq(state.enumerations, 2)
			end)
		end)
	end

	helpers.it("(runtime-source-inventory) preserves filtering order and separate executable bodies", function()
		local root = helpers.driver_root()
		local skipped = { "image.bin", "tests/source.lua", ".codex-probe/source.lua", ".venv/source.py", ".pytest_cache/source.py" }
		local paths = { root .. "z-tool", root .. "a.lua", root .. "not-a-script" }
		local bodies = { [root .. "z-tool"] = "#!/bin/sh\nexit 0", [root .. "a.lua"] = "return {}",
			[root .. "not-a-script"] = "plain text" }
		local discover, open = Discovery.files, io.open
		local opened = 0
		Discovery.files = function(actual_root, accept, excluded)
			helpers.assert_eq(actual_root, root, "Native discovery receives the original root")
			for _, relative in ipairs(skipped) do
				local directory = relative:match("^([^/]+)/")
				if directory then
					helpers.assert_eq(excluded[directory], true, "Exclude the actual relative directory before walking it")
				else
					helpers.assert_eq(accept(relative), false, "Reject unselected file extensions at native discovery")
				end
			end
			return paths
		end
		io.open = function(path)
			local body = assert(bodies[path], "excluded paths must never be opened")
			opened = opened + 1
			return { read = function() return body end, close = function() return true end }
		end
		local outcome = table.pack(pcall(Inventory.read, root))
		Discovery.files, io.open = discover, open
		helpers.assert_eq(outcome[1], true, tostring(outcome[2]))
		helpers.assert_eq(outcome[2], {
			{ path = root .. "a.lua", body = bodies[root .. "a.lua"] },
			{ path = root .. "z-tool", body = bodies[root .. "z-tool"] },
		})
		helpers.assert_eq(outcome[3], {})
		helpers.assert_eq(opened, 3, "inspect extensionless files without admitting plain text")
	end)

	helpers.it("(runtime-source-inventory) retains a valid empty Lua source", function()
		Fixture.with_fault(helpers.driver_root(), "empty_success", function(state)
			local units, unreadable = Inventory.read(helpers.driver_root())
			helpers.assert_eq(unreadable, {})
			helpers.assert_eq(units[2], { path = state.paths[2], body = "" })
			helpers.assert_eq(state.closes, 2)
		end)
	end)
	helpers.it("(runtime-source-inventory) normalizes only the modeled Windows record display", function()
		-- The formatter contract uses the real SourceFile owner, not a Windows filesystem claim.
		local config, discover, open = package.config, Discovery.files, io.open
		local root = "C:\\native\\driver\\"
		local paths = { root .. "z.lua", root .. "a.lua" }
		local bodies = { [paths[1]] = "last source", [paths[2]] = "first source" }
		local opened = {}
		Discovery.files = function(actual_root)
			helpers.assert_eq(actual_root, root, "The native root must not be rewritten")
			return paths
		end
		io.open = function(path)
			opened[#opened + 1] = path
			local body = assert(bodies[path], "Actual I/O must retain native Windows separators")
			return { read = function() return body end, close = function() return true end }
		end
		package.config = "\\" .. config:sub(2)
		local outcome = table.pack(pcall(Inventory.read, root))
		package.config, Discovery.files, io.open = config, discover, open
		helpers.assert_true(outcome[1], tostring(outcome[2]))
		helpers.assert_eq(outcome[2], {
			{ path = "C:/native/driver/a.lua", body = "first source" },
			{ path = "C:/native/driver/z.lua", body = "last source" },
		})
		helpers.assert_eq(outcome[3], {})
		helpers.assert_eq(opened, { paths[2], paths[1] }, "Only record display is normalized")
	end)

end)
