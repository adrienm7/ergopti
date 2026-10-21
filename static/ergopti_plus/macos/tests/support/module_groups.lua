--- tests/support/module_groups.lua

--- ==============================================================================
--- MODULE: Test Module Groups
--- DESCRIPTION:
--- Partitions the discovered test modules into domain groups so CI can run the
--- suite as parallel shards (`lua tests/run.lua --module=<group>`).
---
--- FEATURES & RATIONALE:
--- 1. One table owns the groups. Each test file belongs to the FIRST group whose
---    path prefix it starts with, and the last group has no prefix, so the
---    groups partition the suite exactly: no file runs twice and a new folder
---    can never fall outside every shard.
--- 2. The prefixes follow the domain tree of tests/, so a group is a folder.
---    They are sized from the `# lua_timing` lines of CI runs to keep each
---    shard within a few minutes; move a prefix when a group outgrows that.
--- 3. An unknown group name is refused: a typo in a CI matrix must fail the
---    job, not run zero tests and pass.
--- 4. The integration group comes first and names whole files: the tests that
---    wire several real production modules together with only the outer
---    boundaries faked, or round-trip real files through the real persistence
---    stack, or drive real child processes. The Integration stage of
---    ci-macos.yml runs it after the Unit cells, which run every other group.
---    Selecting it refuses a listed file the runner did not discover, so a
---    rename cannot drop a test into Unit.
--- ==============================================================================

local M = {}

--- The group the Integration stage runs; every other group is a Unit cell.
M.INTEGRATION = "integration"

--- Ordered groups: first match wins, the final catch-all has no prefixes.
M.GROUPS = {
	{ name = "integration", prefixes = {
		"tests/meta/harness/test_e2e_corpus_integration.lua",
		"tests/meta/harness/test_property_runner_integration.lua",
		"tests/unit/infra/config/paths/test_bootstrap_toml.lua",
		"tests/unit/modules/llm/agent/test_agent_end_to_end.lua",
		"tests/unit/modules/llm/features/test_live_mode_end_to_end.lua",
		"tests/unit/modules/llm/features/test_screen_answer_end_to_end.lua",
		"tests/unit/modules/llm/features/test_selection_translation_end_to_end.lua",
		"tests/unit/modules/llm/features/test_tone_rewrite_end_to_end.lua",
		"tests/unit/modules/llm/prediction/test_prediction_engine_streaming_ui_failure_integration.lua",
		"tests/unit/modules/llm/prediction/test_prompt_prediction_end_to_end.lua",
		"tests/unit/ui/menu/state/test_preferences_delays_round_trip.lua",
		"tests/unit/ui/menu/wrap/test_wrap_preferences_round_trip.lua",
	} },
	{ name = "meta", prefixes = { "tests/meta/" } },
	{ name = "core", prefixes = { "tests/unit/adapters/", "tests/unit/infra/", "tests/unit/platform/" } },
	{ name = "modules", prefixes = { "tests/unit/modules/" } },
	{ name = "menu_llm", prefixes = { "tests/unit/ui/menu/menu_llm/" } },
	{ name = "menu_input", prefixes = {
		"tests/unit/ui/menu/hotstrings/",
		"tests/unit/ui/menu/shortcuts/",
		"tests/unit/ui/menu/shortcuts_and_gestures/",
		"tests/unit/ui/menu/keyboard_layout/",
	} },
	{ name = "ui", prefixes = { "tests/unit/ui/" } },
	{ name = "other", prefixes = {} },
}





-- ==================================
-- ==================================
-- ======= 1/ Group Selection =======
-- ==================================
-- ==================================

--- Returns the group that owns one discovered test module.
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
--- @param module_names string[] Discovered dotted module names.
--- @param group_name string Requested group.
--- @return string[] selected Modules of that group, in discovery order.
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
