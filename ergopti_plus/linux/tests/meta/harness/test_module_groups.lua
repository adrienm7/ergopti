--- tests/meta/harness/test_module_groups.lua

--- ==============================================================================
--- MODULE: Test Module Group Partition (Linux)
--- DESCRIPTION:
--- `luajit tests/run.lua --module=<group>` runs one CI shard. The shards only
--- replace the whole suite if every manifest module runs in exactly one of them,
--- no shard is empty (an empty run is refused by the runner contract, and an
--- empty row would hide a renamed folder), and a misspelt group fails instead of
--- running nothing. This file proves all three over the real manifest, which
--- run.lua audits against the discovered tree before any shard is selected.
--- ==============================================================================

local helpers = require("tests.helpers")
local ModuleGroups = require("tests.support.module_groups")
local Manifest = require("tests.test_manifest")

helpers.describe("test module groups (linux-test-shards)", function()
	helpers.it("ends with exactly one catch-all and names each group once", function()
		local seen = {}
		for index, group in ipairs(ModuleGroups.GROUPS) do
			helpers.assert_true(seen[group.name] == nil, "duplicate group " .. group.name)
			seen[group.name] = true
			helpers.assert_eq(#group.prefixes == 0, index == #ModuleGroups.GROUPS,
				"only the last group may be the prefix-less catch-all: " .. group.name)
		end
	end)

	helpers.it("runs every manifest module in exactly one non-empty group", function()
		helpers.assert_true(#Manifest > 400, "the partition check must see the whole suite, saw " .. #Manifest)
		local owner, selected_total = {}, 0
		for _, group in ipairs(ModuleGroups.GROUPS) do
			local selected = ModuleGroups.select(Manifest, group.name)
			helpers.assert_true(#selected > 0, "group " .. group.name .. " runs no module")
			for _, name in ipairs(selected) do
				helpers.assert_true(owner[name] == nil,
					name .. " runs in both " .. tostring(owner[name]) .. " and " .. group.name)
				owner[name] = group.name
				selected_total = selected_total + 1
			end
		end
		helpers.assert_eq(selected_total, #Manifest, "the groups must add up to the whole suite")
		helpers.assert_eq(owner["tests.meta.harness.test_module_groups"], "meta",
			"this file must land in the meta group")
	end)

	helpers.it("names only folders that hold tests", function()
		-- A renamed folder would otherwise leave its prefix matching nothing and
		-- silently move its tests into a later shard.
		for _, group in ipairs(ModuleGroups.GROUPS) do
			for _, prefix in ipairs(group.prefixes) do
				local found = false
				for _, name in ipairs(Manifest) do
					if (name:gsub("%.", "/") .. "/"):sub(1, #prefix) == prefix then found = true; break end
				end
				helpers.assert_true(found, group.name .. " prefix matches no test module: " .. prefix)
			end
		end
	end)

	helpers.it("keeps the UI tests in the last group with whatever no prefix claims", function()
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.ui.menu.llm.test_x"), "ui")
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.modules.hotstrings.engine.test_x"), "input")
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.modules.llm.agent.test_x"), "modules")
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.platform.remap.test_x"), "core")
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.test_x"), "ui")
	end)

	helpers.it("refuses an unknown group instead of running nothing", function()
		local ok, err = pcall(ModuleGroups.select, { "tests.meta.harness.test_module_groups" }, "metta")
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("unknown test module group", 1, true) ~= nil, tostring(err))
	end)
end)
