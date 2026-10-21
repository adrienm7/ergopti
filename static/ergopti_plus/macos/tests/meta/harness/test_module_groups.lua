--- tests/meta/harness/test_module_groups.lua

--- ==============================================================================
--- MODULE: Test Module Group Partition
--- DESCRIPTION:
--- `lua tests/run.lua --module=<group>` runs one CI shard. The shards are only
--- a valid replacement for the whole suite if every discovered test file runs
--- in exactly one of them, and if a misspelt group fails instead of running
--- nothing. This file proves both over the real tests/ tree.
--- ==============================================================================

local helpers = require("tests.helpers")
local ModuleGroups = require("tests.support.module_groups")
local CommandLines = require("tests.support.command_lines")

--- Lists every test module the runner discovers, as dotted names.
--- @return string[] modules
local function discovered_modules()
	local root = helpers.driver_root():gsub("[/\\]+$", "")
	local modules = {}
	for _, dir in ipairs({ "tests/meta", "tests/unit" }) do
		local command
		if package.config:sub(1, 1) == "\\" then
			command = 'dir /b /s /a-d "' .. (root .. "/" .. dir):gsub("/", "\\") .. '\\test_*.lua"'
		else
			command = "find '" .. root .. "/" .. dir .. "' -type f -name 'test_*.lua'"
		end
		for _, line in ipairs(CommandLines.read(command)) do
			local path = line:gsub("\\", "/")
			local relative = path:sub(#root + 2):gsub("%.lua$", "")
			modules[#modules + 1] = relative:gsub("/", ".")
		end
	end
	return modules
end

helpers.describe("test module groups (macos-test-shards)", function()
	helpers.it("ends with exactly one catch-all and names each group once", function()
		local seen = {}
		for index, group in ipairs(ModuleGroups.GROUPS) do
			helpers.assert_nil(seen[group.name], "duplicate group " .. group.name)
			seen[group.name] = true
			helpers.assert_eq(#group.prefixes == 0, index == #ModuleGroups.GROUPS,
				"only the last group may be the prefix-less catch-all: " .. group.name)
		end
	end)

	helpers.it("runs every discovered test module in exactly one group", function()
		local modules = discovered_modules()
		helpers.assert_true(#modules > 1000, "the partition check must see the whole suite, saw " .. #modules)
		local owner = {}
		local selected_total = 0
		for _, group in ipairs(ModuleGroups.GROUPS) do
			for _, name in ipairs(ModuleGroups.select(modules, group.name)) do
				helpers.assert_nil(owner[name], name .. " runs in both " .. tostring(owner[name]) .. " and " .. group.name)
				owner[name] = group.name
				selected_total = selected_total + 1
			end
		end
		helpers.assert_eq(selected_total, #modules, "the groups must add up to the whole suite")
		for _, name in ipairs(modules) do
			helpers.assert_not_nil(owner[name], name .. " runs in no group")
		end
		helpers.assert_true(owner["tests.meta.harness.test_module_groups"] == "meta",
			"this file must land in the meta group")
	end)

	helpers.it("names only folders that hold tests", function()
		-- A renamed folder would otherwise leave its prefix matching nothing and
		-- silently move its tests into a later, larger shard.
		local modules = discovered_modules()
		for _, group in ipairs(ModuleGroups.GROUPS) do
			for _, prefix in ipairs(group.prefixes) do
				local found = false
				-- A folder prefix ends in "/"; an integration file entry names one whole file.
				local suffix = prefix:sub(-4) == ".lua" and ".lua" or "/"
				for _, name in ipairs(modules) do
					local path = name:gsub("%.", "/") .. suffix
					if (suffix == ".lua" and path == prefix) or (suffix == "/" and path:sub(1, #prefix) == prefix) then
						found = true; break
					end
				end
				helpers.assert_true(found, group.name .. " prefix matches no test file: " .. prefix)
			end
		end
	end)

	helpers.it("refuses an unknown group instead of running nothing", function()
		local ok, err = pcall(ModuleGroups.select, { "tests.meta.harness.test_module_groups" }, "metta")
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("unknown test module group", 1, true) ~= nil, tostring(err))
	end)

	helpers.it("matches whole folder prefixes, first group first", function()
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.ui.menu.menu_llm.mlx.test_x"), "menu_llm")
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.ui.menu.hotstrings.test_x"), "menu_input")
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.ui.menu.test_x"), "ui")
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.platform.remap.test_x"), "core")
		helpers.assert_eq(ModuleGroups.group_of("tests.unit.test_x"), "other")
	end)

	helpers.it("is what tests/run.lua --module applies before loading anything", function()
		local file = assert(io.open(helpers.driver_root() .. "tests/run.lua", "rb"))
		local runner = file:read("a")
		file:close()
		local select_at = runner:find("ModuleGroups.select(discovered_modules, module_group)", 1, true)
		local only_at = runner:find("OnlySelector.select_modules(", 1, true)
		helpers.assert_not_nil(select_at, "run.lua must narrow discovery through ModuleGroups.select")
		helpers.assert_true(only_at ~= nil and select_at < only_at,
			"the group must narrow discovery before --only and before any require")
	end)
end)
