--- tests/unit/ui/menu/test_models_manager_mlx_task_forward_declared.lua

--- ==============================================================================
--- MODULE: MLX Server Exact-Task Ownership Regression
--- DESCRIPTION:
--- The readiness probe and server launcher now settle callback work through
--- exact owners. A forward-declaration spelling scan no longer proves safety:
--- ownership must be published and GC-pinned before native start, then released
--- only through the owner after terminal observation.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	local src, err = helpers.read_driver_unit("function obj.start_server")
	helpers.assert_true(src ~= nil,
		"models_manager_mlx_server source must be uniquely locatable: " .. tostring(err))
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

local function remove_once(source, marker)
	local position = source:find(marker, 1, true)
	helpers.assert_true(position ~= nil, "mutation marker must exist: " .. marker)
	return source:sub(1, position - 1) .. source:sub(position + #marker)
end

local function readiness_contract(source)
	return ordered(source, {
		"local function release_readiness_task",
		"local task = task_owner.task",
		"if task ~= nil then _active_tasks[task] = nil end",
		"probe_server_ready = function(retries)",
		"local task_owner = {",
		"task_owner.authorized == true",
		"task_owner.start_committed == true",
		"release_readiness_task(launched_lifecycle, task_owner)",
		"probe_task = TaskLifecycle.native(\"MLX readiness probe\"",
		"task_owner.task = probe_task",
		"launched_lifecycle.readiness_task_owner = task_owner",
		"_active_tasks[probe_task] = true",
		"TaskLifecycle.start(probe_task, \"MLX readiness probe\")",
		"task_owner.start_committed = true",
	})
end

local function server_contract(source)
	return ordered(source, {
		"local function claim_server_completion",
		"owner.task ~= task",
		"local function release_native_server_task",
		"_active_tasks[\"mlx_server\"] == task",
		"deps.active_tasks[\"mlx_server\"] == task",
		"server_completion = function(code)",
		"pending_server_completion = table.pack(code)",
		"local owner = claim_server_completion(task)",
		"task = TaskLifecycle.native(\"MLX server launch\"",
		"obj._server_lifecycle_owner = lifecycle",
		"active_tasks_gc_root[\"mlx_server\"] = task",
		"TaskLifecycle.start(task, \"MLX server launch\")",
		"lifecycle.start_committed = true",
	})
end

helpers.describe("models_manager_mlx: exact native task ownership", function()
	helpers.it("owns only the readiness probe and exact server launcher", function()
		local labels = {}
		for label in read_src():gmatch('TaskLifecycle%.native%(%s*"([^"]+)"') do
			labels[#labels + 1] = label
		end
		helpers.assert_eq(labels, {"MLX readiness probe", "MLX server launch"},
			"a detached pre-launch sweep can race and terminate its successor")
	end)

	helpers.it("publishes the readiness owner before native start", function()
		local source = read_src()
		local ok, missing = readiness_contract(source)
		helpers.assert_true(ok, "missing readiness ownership edge: " .. tostring(missing))
		local mutant = remove_once(source, "_active_tasks[probe_task] = true")
		helpers.assert_true(not readiness_contract(mutant),
			"the guard must fail when the readiness task loses its GC root")
	end)

	helpers.it("publishes and claims the exact server owner", function()
		local source = read_src()
		local ok, missing = server_contract(source)
		helpers.assert_true(ok, "missing server ownership edge: " .. tostring(missing))
		local mutant = remove_once(source, "obj._server_lifecycle_owner = lifecycle")
		helpers.assert_true(not server_contract(mutant),
			"the guard must fail when completion cannot claim the published lifecycle")
	end)
end)
