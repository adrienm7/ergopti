--- tests/unit/ui/menu/test_menu_apps_task_forward_declared.lua

--- ==============================================================================
--- MODULE: Regression — menu_apps launch-task ownership transaction
--- DESCRIPTION:
--- menu_apps.lua launches each bundle through TaskLifecycle. The exact native
--- handle must be forward-declared for its callback, retained in M._active_tasks
--- before start, and released by either callback settlement or start refusal.
--- An inline declaration captures the nil global and silently leaks the GC pin.
---
--- These guards follow the current native/start ownership transaction instead
--- of matching the retired raw hs.task.new constructor spelling.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_apps: app launch owns one exact native task", function()
	local function read_src()
		local src, err = helpers.read_driver_unit("local function discover_bundled_apps")
		helpers.assert_true(src ~= nil,
			"the bundled-app menu unit must be uniquely locatable: " .. tostring(err))
		return src
	end

	helpers.it("constructs exactly one app-launch candidate through TaskLifecycle", function()
		local src = read_src()
		local _, constructor_count = src:gsub("task = TaskLifecycle%.native%(", "")
		local _, start_count = src:gsub("TaskLifecycle%.start%(task, \"Bundled app launch\"%)", "")
		helpers.assert_eq(constructor_count, 1,
			"the app menu must construct one native launch candidate")
		helpers.assert_eq(start_count, 1,
			"the exact candidate must have one native start admission")
	end)

	helpers.it("pins the exact handle before start and rolls back a refusal", function()
		local src = read_src()
		local decl_pos = src:find("local task\n", 1, true)
		local new_pos = src:find("task = TaskLifecycle.native", 1, true)
		local pin_pos = src:find("M._active_tasks[task] = true", new_pos, true)
		local start_pos = src:find("TaskLifecycle.start(task, \"Bundled app launch\")",
			pin_pos, true)
		local rollback_pos = src:find("M._active_tasks[task] = nil", start_pos, true)
		helpers.assert_true(decl_pos ~= nil, "app-launch task must be forward-declared as `local task`")
		helpers.assert_true(new_pos ~= nil,
			"app-launch task must be assigned via `task = TaskLifecycle.native`")
		helpers.assert_true(pin_pos ~= nil and start_pos ~= nil and rollback_pos ~= nil,
			"the launch transaction must expose pin, start, and refusal rollback")
		helpers.assert_true(decl_pos < new_pos and new_pos < pin_pos and pin_pos < start_pos,
			"the callback upvalue and GC pin must exist before native start")
		helpers.assert_true(start_pos < rollback_pos,
			"a refused native start must release its exact GC pin")
	end)

	helpers.it("the completion callback releases its captured exact handle", function()
		local src = read_src()
		local constructor = assert(src:find("task = TaskLifecycle.native", 1, true))
		local callback_release = src:find(
			"if task then M._active_tasks[task] = nil end", constructor, true)
		local pin = assert(src:find("M._active_tasks[task] = true", constructor, true))
		helpers.assert_true(callback_release ~= nil and callback_release < pin,
			"the native completion closure must release the captured task before "
				.. "the post-construction ownership block")
	end)
end)
