--- tests/support/module_groups.lua

--- ==============================================================================
--- MODULE: Test Module Groups (Linux)
--- DESCRIPTION:
--- Partitions the manifest's test modules into domain groups so CI can run the
--- suite as parallel shards (`luajit tests/run.lua --module=<group>`).
---
--- FEATURES & RATIONALE:
--- 1. One table owns the groups; the CI matrix of ci-linux.yml lists the same
---    names in the same order (tools/test/test-linux-ci-evidence.cjs).
--- 2. Each test module belongs to the FIRST group whose folder prefix it
---    starts with. The last group has no prefix and takes everything else, so
---    the groups partition the suite: no module runs twice, and a new folder
---    can never fall outside every shard. It is also a real group (the UI
---    tests), so no CI row can ever run zero tests.
--- 3. The prefixes follow the domain tree of tests/ and are sized from the
---    `# lua_timing` lines of CI runs, to keep each shard near a minute of
---    test time; move a prefix when a group outgrows that.
--- 4. An unknown group name is refused: a typo in a CI matrix must fail the
---    job, not run zero tests and pass.
--- 5. The integration group comes first and names whole files: the tests that
---    wire several real production modules together, or drive a real child
---    process, real signals, a real sqlite3 or real files through production
---    code. The Integration stage of ci-linux.yml runs it after the Unit rows,
---    which run every other group. Selecting it refuses a listed file the
---    runner did not discover, so a rename cannot drop a test into Unit.
--- ==============================================================================

local M = {}

--- The group the Integration stage runs; every other group is a Unit row.
M.INTEGRATION = "integration"

--- Ordered groups: first match wins, the final group has no prefixes.
M.GROUPS = {
	{ name = "integration", prefixes = {
		"tests/meta/boot/test_daemon_cli.lua",
		"tests/unit/adapters/processes/test_owned_process_deadline.lua",
		"tests/unit/infra/lifecycle/test_callback_error_description.lua",
		"tests/unit/infra/lifecycle/test_native_timer.lua",
		"tests/unit/modules/keystats/storage/test_sqlite_first_open.lua",
		"tests/unit/modules/llm/prediction/test_llm_prediction_engine_integration.lua",
		"tests/unit/modules/updater/install/test_config_backup_files.lua",
		"tests/unit/platform/remap/tap_hold/test_tap_hold_integration.lua",
	} },
	{ name = "meta", prefixes = { "tests/meta/" } },
	{ name = "core", prefixes = { "tests/unit/adapters/", "tests/unit/platform/" } },
	{ name = "infra", prefixes = { "tests/unit/infra/" } },
	{ name = "input", prefixes = {
		"tests/unit/modules/hotstrings/",
		"tests/unit/modules/dynamic_hotstrings/",
		"tests/unit/modules/shortcuts/",
		"tests/unit/modules/keymap/",
		"tests/unit/modules/gestures/",
	} },
	{ name = "modules", prefixes = { "tests/unit/modules/" } },
	{ name = "ui", prefixes = {} },
}





-- ==================================
-- ==================================
-- ======= 1/ Group Selection =======
-- ==================================
-- ==================================

--- Returns the group that owns one test module.
--- @param module_name string Dotted module name, e.g. "tests.meta.boot.test_x".
--- @return string group_name Name of the first matching group.
function M.group_of(module_name)
	assert(type(module_name) == "string" and module_name ~= "", "module name required")
	local path = module_name:gsub("%.", "/") .. ".lua"
	for _, group in ipairs(M.GROUPS) do
		if #group.prefixes == 0 then return group.name end
		for _, prefix in ipairs(group.prefixes) do
			if path:sub(1, #prefix) == prefix then return group.name end
		end
	end
	error("test module groups must end with a catch-all group")
end

--- Keeps only the modules owned by one group, refusing an unknown name.
--- @param module_names string[] Dotted module names, in run order.
--- @param group_name string Requested group.
--- @return string[] selected Modules of that group, in the given order.
function M.select(module_names, group_name)
	local known = false
	for _, group in ipairs(M.GROUPS) do
		if group.name == group_name then known = true end
	end
	if not known then
		local names = {}
		for _, group in ipairs(M.GROUPS) do names[#names + 1] = group.name end
		error(string.format("unknown test module group %q; known groups: %s",
			tostring(group_name), table.concat(names, ", ")), 2)
	end
	local selected = {}
	for _, module_name in ipairs(module_names) do
		if M.group_of(module_name) == group_name then selected[#selected + 1] = module_name end
	end
	if group_name == M.INTEGRATION then
		local found = {}
		for _, module_name in ipairs(selected) do found[module_name:gsub("%.", "/") .. ".lua"] = true end
		for _, group in ipairs(M.GROUPS) do
			if group.name == M.INTEGRATION then
				for _, prefix in ipairs(group.prefixes) do
					if not found[prefix] then
						error(string.format("integration test %s was not discovered; update M.GROUPS", prefix), 2)
					end
				end
			end
		end
	end
	return selected
end

return M
