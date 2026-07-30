--- tests/unit/modules/keymap/test_input_sources_probe_task_pin.lua

--- ==============================================================================
--- MODULE: Regression — active-layout probe task is GC-pinned and start() is checked
--- DESCRIPTION:
--- Audit finding F-H2. refresh_active_layouts_async created the probe with a bare
--- `local t = hs.task.new(...)` inside a pcall closure and discarded t:start()'s
--- return. Two failure modes:
---   1. The handle was unreferenced once the closure returned, so the GC could
---      collect it during python3's 300 ms–1 s cold start, dropping the completion
---      callback — finish() never ran, so _active_layouts_refreshing stayed wedged
---      true for the session and every later refresh early-returned (frozen cache).
---   2. hs.task:start() returns false (not raising) on a launch failure; the
---      ignored return meant finish() was never called on that path either —
---      same permanent wedge.
---
--- Fix: forward-declare the handle ABOVE its callback, pin it in a module-level
--- _active_probe_tasks GC root, unpin in the callback, and check :start() so a
--- failed launch still calls finish(nil) and resets the flag.
---
--- Behavioral test: a failed start must NOT wedge the flag — a second refresh must
--- still spawn a task. Source test: pin the GC-root + forward-decl + start-check.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("active-layout probe: a failed start() never wedges the refresh flag", function()
	helpers.it("a second refresh still spawns a task after a start()==false probe", function()
		local new_calls   = 0
		local behavior     -- function(cb) -> fake task; swapped between the two refreshes

		local IS = helpers.load_with_stubs("modules.keymap.input_sources", {
			task = {
				new = function(_path, cb, _args)
					new_calls = new_calls + 1
					return behavior(cb)
				end,
			},
		})

		-- Refresh #1: the launch fails (start() returns false, callback never fires).
		-- With the fix this calls finish(nil) and resets _active_layouts_refreshing.
		behavior = function(_cb)
			return { start = function() return false end, terminate = function() end }
		end
		IS.refresh_active_layouts_async(nil)
		helpers.assert_eq(new_calls, 1)

		-- Refresh #2: a healthy probe. If refresh #1 had wedged the flag (the old
		-- bug), this call would early-return WITHOUT creating a task and new_calls
		-- would stay 1. The fix resets the flag, so a second task IS spawned.
		behavior = function(cb)
			return { start = function() if cb then cb(0, '["French"]', "") end return true end, terminate = function() end }
		end
		IS.refresh_active_layouts_async(nil)
		helpers.assert_eq(new_calls, 2)

		package.loaded["modules.keymap.input_sources"] = nil
	end)
end)


helpers.describe("active-layout probe: handle is forward-declared and GC-pinned", function()
	helpers.it("input_sources pins the probe task and checks start()", function()
		-- Selected by a declaration unique to modules/keymap/input_sources.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function resolve_installed_ergopti_version")
		helpers.assert_true(src ~= nil, "modules/keymap/input_sources.lua source must be locatable")

		-- A module-level GC-root table must exist.
		helpers.assert_true(src:find("_active_probe_tasks", 1, true) ~= nil,
			"missing the _active_probe_tasks GC-root table")

		-- The handle must be forward-declared ABOVE the hs.task.new call (closure-nil
		-- rule) and assigned with `probe_task = hs.task.new`, NOT `local t = hs.task.new`.
		local decl_idx = src:find("local probe_task", 1, true)
		local new_idx  = src:find("probe_task = hs.task.new", 1, true)
		helpers.assert_true(decl_idx ~= nil, "probe task handle must be forward-declared as `local probe_task`")
		helpers.assert_true(new_idx ~= nil, "probe task must be assigned via `probe_task = hs.task.new`")
		helpers.assert_true(decl_idx < new_idx, "`local probe_task` must be declared BEFORE the hs.task.new closure")

		-- The bare unpinned pattern must be gone.
		helpers.assert_true(src:find("local t = hs.task.new", 1, true) == nil,
			"a bare `local t = hs.task.new` re-introduces the un-pinned GC bug")

		-- :start()'s return must be checked so a failed launch resets the flag.
		helpers.assert_true(src:find("if not probe_task:start()", 1, true) ~= nil,
			"probe_task:start() return must be checked (false = launch failure)")
	end)
end)
