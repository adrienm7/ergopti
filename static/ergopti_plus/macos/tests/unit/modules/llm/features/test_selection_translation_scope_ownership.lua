--- tests/unit/modules/llm/features/test_selection_translation_scope_ownership.lua

--- ==============================================================================
--- MODULE: Selection Translation Fixture Scope Ownership
--- DESCRIPTION:
--- Builds the real selection pipeline with a cold MLX retirement dependency.
--- Successful construction and an assertion failure must restore every exact
--- package entry, native hs identity and the preloaded logger/profile owners.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.modules.llm.selection_translation_fixture")
local Scope = require("tests.support.modules.llm.selection_translation_scope")
local SharedLogger = require("logger")

--- Captures exact cache identities without clearing unrelated owners.
--- @return table snapshot
local function snapshot()
	local entries = {}
	for name, value in pairs(package.loaded) do entries[name] = value end
	return { entries = entries, hs = rawget(_G, "hs"), logger = package.loaded["infra.logger"] }
end

--- Checks both removed entries and newly published transitive dependencies.
--- @param before table Snapshot from before fixture construction.
local function assert_restored(before)
	local changed = {}
	for name, value in pairs(before.entries) do
		if not rawequal(package.loaded[name], value) then changed[name] = true end
	end
	for name, value in pairs(package.loaded) do
		if not rawequal(before.entries[name], value) then changed[name] = true end
	end
	local names = {}
	for name in pairs(changed) do names[#names + 1] = name end
	table.sort(names)
	helpers.assert_eq(#names, 0, "fixture changed package.loaded entries: " .. table.concat(names, ", "))
	helpers.assert_true(rawequal(rawget(_G, "hs"), before.hs), "fixture changed the native hs identity")
	helpers.assert_true(rawequal(package.loaded["infra.logger"], before.logger), "fixture replaced the native logger owner")
	helpers.assert_true(rawequal(package.loaded.logger, SharedLogger), "fixture replaced the preloaded shared logger")
end

helpers.describe("selection translation fixture restores transitive owners", function()
	for _, forced in ipairs({ false, true }) do
		helpers.it("restores the exact cold fixture scope after " .. (forced and "an assertion failure" or "successful construction"), function()
			-- These are fixture preconditions, not a whole-cache rollback. The inner
			-- scope itself must restore its cold dependency and a pre-existing owner.
			helpers.with_fresh_modules({ "modules.llm.profiles", "modules.llm.mlx_stream_retirement", "adapters.event_provenance",
				"json", "llm.translate", "compat.utf8", "tests.support.modules.llm.selection_translation_destination" }, function()
				local profile = {}
				package.loaded["modules.llm.profiles"] = profile
				for _, name in ipairs({ "modules.llm.mlx_stream_retirement", "adapters.event_provenance",
					"json", "llm.translate", "compat.utf8", "tests.support.modules.llm.selection_translation_destination" }) do
					helpers.assert_nil(package.loaded[name], "the transitive fixture owner must start cold: " .. name)
				end
				local before = snapshot()
				local ok, detail = pcall(function()
					Scope.run(function()
						local world = World.build_world()
						helpers.assert_type(world.flow.run, "function", "the actual selection pipeline must be constructed")
						helpers.assert_type(package.loaded["modules.llm.mlx_stream_retirement"], "table",
							"the real MLX transport must acquire its transitive retirement helper")
						if forced then helpers.assert_true(false, "forced selection fixture scope failure") end
					end)
				end)
				if forced then
					helpers.assert_true(not ok and tostring(detail):find("forced selection fixture scope failure", 1, true) ~= nil,
						"the fixture must unwind the intended assertion failure")
				else
					helpers.assert_true(ok, tostring(detail))
				end
				assert_restored(before)
				helpers.assert_true(rawequal(package.loaded["modules.llm.profiles"], profile), "the exact prior profile must survive")
			end)
		end)
	end
end)
