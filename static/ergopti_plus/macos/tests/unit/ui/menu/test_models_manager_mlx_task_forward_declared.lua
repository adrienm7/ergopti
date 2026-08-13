--- tests/unit/ui/menu/test_models_manager_mlx_task_forward_declared.lua

--- ==============================================================================
--- MODULE: Regression — models_manager_mlx_server closure-nil forward declarations
--- DESCRIPTION:
--- start_server (extracted to models_manager_mlx_server.lua in the models-manager
--- split) has three hs.task sites whose callbacks reference the task handle itself
--- (not a hardcoded string key):
---
---   1. sweep    — pre-launch port sweep; callback clears _active_tasks[sweep]
---   2. probe_task — HTTP probe loop; callback clears _active_tasks[probe_task]
---   3. task (mlx-server bash kill) — callback compares
---      deps.active_tasks["mlx_server"] == task to guard the cleanup
---
--- An inline `local X = <constructor>(...)` form binds _G.X (nil) inside the
--- callback closure. For sweep/probe_task: _active_tasks[nil] = nil → "table
--- index is nil" (swallowed to HS Console). For the bash-kill task: the comparison
--- would always be `deps.active_tasks["mlx_server"] == nil`, unconditionally
--- clearing the active-task slot even when a different MLX process is running.
---
--- Fix: forward-declare each handle before TaskLifecycle.native constructs the task.
--- This test pins the ROOT CAUSE for each dangerous site.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("models_manager_mlx: three dangerous hs.task closures forward-declare their handle", function()
	-- The three dangerous hs.task sites live inside start_server, which moved to
	-- the server-lifecycle sibling module during the models-manager split.
	--
	-- Selected by a function declaration unique to that production module rather
	-- than by path, so moving it cannot turn these invariants into a path error.
	local function read_src()
		local src = helpers.read_driver_source("function obj.start_server")
		helpers.assert_true(src ~= nil, "models_manager_mlx_server.lua source must be locatable")
		return src
	end


	-- ===== Site 1: sweep =====

	helpers.it("sweep handle is forward-declared before the constructor closure", function()
		local src = read_src()
		local decl_pos = src:find("local sweep\n", 1, true)
		local new_pos  = src:find("sweep = TaskLifecycle.native", 1, true)
		helpers.assert_true(decl_pos ~= nil, "sweep must be forward-declared as `local sweep`")
		helpers.assert_true(new_pos  ~= nil,
			"sweep must be assigned via `sweep = TaskLifecycle.native`")
		helpers.assert_true(decl_pos < new_pos,
			"forward declaration must precede the constructor closure so the callback captures the upvalue")
	end)

	helpers.it("sweep GC-pin release is guarded against nil sweep", function()
		local src = read_src()
		helpers.assert_true(
			src:find("if sweep then _active_tasks[sweep] = nil end", 1, true) ~= nil,
			"sweep callback must guard the GC-pin clear with `if sweep then` "
			.. "(_active_tasks[nil] = nil raises 'table index is nil')")
	end)


	-- ===== Site 2: probe_task =====

	helpers.it("probe_task handle is forward-declared before the constructor closure", function()
		local src = read_src()
		local decl_pos = src:find("local probe_task\n", 1, true)
		local new_pos  = src:find("probe_task = TaskLifecycle.native", 1, true)
		helpers.assert_true(decl_pos ~= nil, "probe_task must be forward-declared as `local probe_task`")
		helpers.assert_true(new_pos  ~= nil,
			"probe_task must be assigned via `probe_task = TaskLifecycle.native`")
		helpers.assert_true(decl_pos < new_pos,
			"forward declaration must precede the constructor closure")
	end)

	helpers.it("probe_task GC-pin release is guarded against nil probe_task", function()
		local src = read_src()
		helpers.assert_true(
			src:find("if probe_task then _active_tasks[probe_task] = nil end", 1, true) ~= nil,
			"probe_task callback must guard the GC-pin clear with `if probe_task then`")
	end)


	-- ===== Site 3: task (mlx-server bash kill) =====

	helpers.it("mlx-server bash-kill task handle is forward-declared before the hs.task.new closure", function()
		local src = read_src()
		-- Anchor on the unique sentinel that only appears in this scope
		local anchor = src:find('deps.active_tasks["mlx_server"] == task', 1, true)
		helpers.assert_true(anchor ~= nil, 'the mlx-server bash-kill callback must contain `deps.active_tasks["mlx_server"] == task`')
		-- Find the `local task` declaration immediately before this closure
		-- (search backwards from the anchor by extracting a window before it)
		local window = src:sub(1, anchor)
		local last_decl = window:match(".*local task\n")
		helpers.assert_true(last_decl ~= nil,
			"the mlx-server bash-kill task must be forward-declared (`local task` on its own line) "
			.. "so the callback captures the upvalue, not nil; otherwise the active-task comparison always evaluates to nil")
	end)
end)
