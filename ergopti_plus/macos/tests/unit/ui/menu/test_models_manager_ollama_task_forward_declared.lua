--- tests/unit/ui/menu/test_models_manager_ollama_task_forward_declared.lua

--- ==============================================================================
--- MODULE: Ollama Installed-Refresh Exact-Task Ownership Regression
--- DESCRIPTION:
--- The refresh completion no longer clears a callback-captured local directly.
--- It settles an exact owner that owns the GC pin, pause join, authorization and
--- start commitment. This guard follows that transaction instead of requiring
--- the obsolete forward-declaration spelling, and includes mutations that prove
--- the owner and publication checks are load-bearing.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	local src, err = helpers.read_driver_unit("local function get_ollama_path")
	helpers.assert_true(src ~= nil,
		"models_manager_ollama source must be uniquely locatable: " .. tostring(err))
	return (src:gsub("%-%-[^\n]*", ""))
end

local function ordered(source, markers)
	local cursor = 1
	for _, marker in ipairs(markers) do
		local position = source:find(marker, cursor, true)
		if not position then return false, marker end
		cursor = position + #marker
	end
	return true
end

local function remove_after(source, anchor, marker)
	local anchor_position = source:find(anchor, 1, true)
	helpers.assert_true(anchor_position ~= nil, "mutation anchor must exist: " .. anchor)
	local marker_position = source:find(marker, anchor_position, true)
	helpers.assert_true(marker_position ~= nil, "mutation marker must exist: " .. marker)
	return source:sub(1, marker_position - 1)
		.. source:sub(marker_position + #marker)
end

local function refresh_contract(source)
	return ordered(source, {
		"local function release_requirement_task(owner)",
		"owner.settled = true",
		"local task = owner.task",
		"if task ~= nil then _active_tasks[task] = nil end",
		"owner.release_slot(task)",
		"local function refresh_installed_async()",
		"local operation = begin_maintenance(\"Ollama installed-model refresh\")",
		"local owner = {",
		"owner.release_slot = function(task)",
		"local function finish_refresh",
		"owner.authorized == true",
		"owner.start_committed == true",
		"operation.is_authorized() == true",
		"release_requirement_task(owner)",
		"if authorized ~= true then return false end",
		"task = TaskLifecycle.native(\"Ollama installed-model refresh\"",
		"owner.task = task",
		"_installed_refresh_owner = owner",
		"_active_tasks[task] = true",
		"operation.lifecycle.adopt(owner, owner.pause_join,",
		"owner.requirement_registered = true",
		"TaskLifecycle.start(task, \"Ollama installed-model refresh\")",
		"owner.dispatching = false",
		"owner.start_committed = true",
	})
end

helpers.describe("models_manager_ollama: exact installed-refresh task ownership", function()
	helpers.it("releases only the task recorded by the exact owner", function()
		local source = read_src()
		local ok, missing = refresh_contract(source)
		helpers.assert_true(ok, "missing installed-refresh ownership edge: " .. tostring(missing))
		helpers.assert_true(
			source:find("if _installed_refresh_owner == owner then "
				.. "_installed_refresh_owner = nil end", 1, true) ~= nil,
			"refresh settlement must clear only the published owner")
		helpers.assert_true(
			source:find("if task == owner.task then _installed_loading = false end",
				1, true) ~= nil,
			"refresh settlement must release the loading slot for the same handle")
	end)

	helpers.it("ownership guard rejects missing release and publication edges", function()
		local source = read_src()
		local mutations = {
			{"local function release_requirement_task(owner)",
				"if task ~= nil then _active_tasks[task] = nil end"},
			{"local function refresh_installed_async()", "_installed_refresh_owner = owner"},
		}
		for _, mutation in ipairs(mutations) do
			local mutant = remove_after(source, mutation[1], mutation[2])
			local ok = refresh_contract(mutant)
			helpers.assert_true(not ok,
				"installed-refresh oracle must reject removal of: " .. mutation[2])
		end
	end)
end)
