--- tests/unit/platform/remap/test_activation_layout_fixture_scope.lua

--- ==============================================================================
--- MODULE: Activation Layout Fixture Scope Tests
--- DESCRIPTION:
--- Preserves real dependency owners and exact controller dispatch across scenarios.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.activation_layout_fixture")
local OWNERS = {
	"adapters.file_system", "infra.fs_dir", "platform.remap.ke_variables",
	"adapters.json_codec", "adapters.shell_runner", "infra.deferred_work",
}

helpers.describe("Activation layout fixture ownership", function()
	for _, predecessor_kind in ipairs({ "absent", "false" }) do
		for _, outcome in ipairs({ "success", "callback failure", "construction failure" }) do
			helpers.it("(activation-fixture-scope) restores " .. predecessor_kind .. " after " .. outcome, function()
				helpers.with_stub_scope(OWNERS, function()
					local predecessor
					if predecessor_kind == "false" then predecessor = false end
					for _, name in ipairs(OWNERS) do package.loaded[name] = predecessor end
					_G.hs = predecessor
					local original_require = require
					local construction_reached = false
					if outcome == "construction failure" then
						_G.require = function(name)
							local loaded = table.pack(original_require(name))
							if name == "platform.remap" then
								construction_reached = true
								error("activation construction marker")
							end
							return table.unpack(loaded, 1, loaded.n)
						end
					end
					local reached = false
					local ok, detail = pcall(Fixture.with_remap, {}, function(remap, calls)
						helpers.assert_true(remap.regenerate())
						helpers.assert_eq(calls.guardian_probe_calls, 1)
						local initial = calls.builds[#calls.builds]
						helpers.assert_type(initial, "table")
						helpers.assert_true(calls.deliver_all_ready(initial.token))
						helpers.assert_true(calls.deliver_resumed(initial.token))
						helpers.assert_eq(calls.phase, "active")
						reached = true
						if outcome == "callback failure" then error("activation callback marker") end
					end)
					_G.require = original_require
					helpers.assert_eq(ok, outcome == "success")
					if outcome == "construction failure" then
						helpers.assert_eq(construction_reached, true)
						helpers.assert_eq(reached, false)
						helpers.assert_contains(detail, "activation construction marker")
					else
						helpers.assert_eq(reached, true)
						if outcome == "callback failure" then helpers.assert_contains(detail, "activation callback marker") end
					end
					for _, name in ipairs(OWNERS) do
						helpers.assert_eq(package.loaded[name], predecessor, "real consumer predecessor: " .. name)
					end
					helpers.assert_eq(rawget(_G, "hs"), predecessor)
				end)
			end)
		end
	end

	for _, outcome in ipairs({ "success", "callback failure" }) do
		helpers.it("(activation-fixture-scope) preserves warm controller dispatch after " .. outcome, function()
			helpers.with_stub_scope(OWNERS, function()
				local saved = {}
				local predecessor_hs, predecessor_controller
				Fixture.with_remap({}, function()
					for _, name in ipairs(OWNERS) do saved[name] = package.loaded[name] end
					predecessor_hs = hs
					predecessor_controller = package.loaded["platform.remap.lease_controller"]
				end)
				for _, name in ipairs(OWNERS) do package.loaded[name] = saved[name] end
				_G.hs = predecessor_hs
				local predecessor_calls = 0
				local predecessor_status = predecessor_controller.status
				predecessor_controller.status = function(...)
					predecessor_calls = predecessor_calls + 1
					return predecessor_status(...)
				end
				local previous_variables = saved["platform.remap.ke_variables"]
				helpers.assert_type(previous_variables.capsword_revision(), "number")
				local calls_before = predecessor_calls
				local reached = false
				local ok, detail = pcall(Fixture.with_remap, {}, function()
					local current = package.loaded["platform.remap.lease_controller"]
					local current_status = current.status
					local current_calls = 0
					current.status = function(...)
						current_calls = current_calls + 1
						return current_status(...)
					end
					local variables = require("platform.remap.ke_variables")
					helpers.assert_type(variables.capsword_revision(), "number")
					helpers.assert_eq(current_calls, 1, "the real bridge must consult the current controller")
					helpers.assert_eq(predecessor_calls, calls_before)
					reached = true
					if outcome == "callback failure" then error("warm activation callback marker") end
				end)
				helpers.assert_eq(reached, true, "the controller dispatch proof must complete: " .. tostring(detail))
				helpers.assert_eq(ok, outcome == "success")
				if outcome == "callback failure" then helpers.assert_contains(detail, "warm activation callback marker") end
				for _, name in ipairs(OWNERS) do
					helpers.assert_eq(package.loaded[name], saved[name], "warm real consumer: " .. name)
				end
				helpers.assert_eq(hs, predecessor_hs)
				previous_variables.capsword_revision()
				helpers.assert_eq(predecessor_calls, calls_before + 1, "the predecessor retains its real controller")
			end)
		end)
	end
end)
