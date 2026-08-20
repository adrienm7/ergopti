--- tests/unit/ui/menu/test_menu_apps_task_forward_declared.lua

--- ==============================================================================
--- MODULE: Regression — menu_apps app-launch task closure-nil forward declaration
--- DESCRIPTION:
--- menu_apps.lua spawns an hs.task("/usr/bin/open") through TaskLifecycle to launch
--- each app from the menu. The completion callback clears the GC-root pin
--- M._active_tasks[task]. An inline `local task = <constructor>(...)` form compiles
--- the callback closure before the local is in scope, binding the nil global
--- _G.task. The callback then attempts M._active_tasks[nil] = nil → "table index
--- is nil" (swallowed to HS Console).
---
--- Fix: forward-declare the handle before TaskLifecycle.native constructs the task.
--- This test pins the ROOT CAUSE (declaration order).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_apps: app-launch hs.task handle is forward-declared (closure-nil guard)", function()
	local function read_src()
		-- Selected by a declaration unique to ui/menu/menu_apps.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function discover_bundled_apps")
		helpers.assert_true(src ~= nil, "ui/menu/menu_apps.lua source must be locatable")
		return src
	end

	helpers.it("no callback-captured task handle is assigned inline into a `local`", function()
		local src = read_src()
		local offending
		for line in src:gmatch("[^\n]+") do
			local stripped = line:match("^%s*(.-)%s*$") or line
			if not stripped:match("^%-%-")
				and (stripped:find("local%s+[%w_]+%s*=%s*hs%.task%.new")
					or stripped:find("local%s+[%w_]+%s*=%s*TaskLifecycle%.create")) then
				offending = stripped
				break
			end
		end
		helpers.assert_true(offending == nil,
			"task handles referenced inside callbacks must be forward-declared. Offending: "
			.. tostring(offending))
	end)

	helpers.it("the app-launch task is forward-declared before the constructor closure", function()
		local src = read_src()
		local decl_pos = src:find("local task\n", 1, true)
		local new_pos  = src:find("task = TaskLifecycle.native", 1, true)
		helpers.assert_true(decl_pos ~= nil, "app-launch task must be forward-declared as `local task`")
		helpers.assert_true(new_pos  ~= nil,
			"app-launch task must be assigned via `task = TaskLifecycle.native`")
		helpers.assert_true(decl_pos < new_pos,
			"forward declaration must come before the constructor closure so the callback captures the upvalue")
	end)

	helpers.it("the GC-pin release in the completion callback is guarded against nil task", function()
		local src = read_src()
		helpers.assert_true(
			src:find("if task then M._active_tasks[task] = nil end", 1, true) ~= nil,
			"the in-callback GC-pin clear must be guarded with `if task then` "
			.. "(M._active_tasks[nil] = nil raises 'table index is nil')")
	end)
end)
