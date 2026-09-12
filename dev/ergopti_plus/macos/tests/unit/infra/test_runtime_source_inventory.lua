--- tests/unit/infra/test_runtime_source_inventory.lua

--- ==============================================================================
--- MODULE: Runtime Source Inventory Regressions
--- DESCRIPTION:
--- Reports every source I/O failure without publishing a failed unit, preserving
--- file boundaries, filtering and valid extensionless executable sources.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.source_read_fixture")
local Inventory = require("tests.support.runtime_source_inventory")
local CommandLines = require("tests.support.command_lines")

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
		for _, relative in ipairs(skipped) do paths[#paths + 1] = root .. relative end
		local bodies = { [root .. "z-tool"] = "#!/bin/sh\nexit 0", [root .. "a.lua"] = "return {}",
			[root .. "not-a-script"] = "plain text" }
		local command_read, open = CommandLines.read, io.open
		local opened = 0
		CommandLines.read = function() return paths end
		io.open = function(path)
			local body = assert(bodies[path], "excluded paths must never be opened")
			opened = opened + 1
			return { read = function() return body end, close = function() return true end }
		end
		local outcome = table.pack(pcall(Inventory.read, root))
		CommandLines.read, io.open = command_read, open
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
end)
