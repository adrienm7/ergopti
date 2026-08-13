--- tests/unit/ui/test_menu_about_install_task_capture.lua

--- ==============================================================================
--- MODULE: Regression — menu_about self-update install task capture (F-CRIT-2)
--- DESCRIPTION:
--- The in-place install spawns `unzip` via hs.task and pins the handle in
--- M._active_tasks so the GC cannot SIGTERM it. The completion callback clears
--- that pin on its first line. The handle MUST be forward-declared so the closure
--- captures it as a real UPVALUE:
---
---     local task = hs.task.new(..., function() M._active_tasks[task] = nil ... end)
---
--- binds the NIL GLOBAL `task` inside the callback (Lua scopes a local only AFTER
--- its full declaration statement completes), so `M._active_tasks[nil] = nil`
--- raises "table index is nil" on the callback's FIRST line. Hammerspoon swallows
--- hs.task callback errors to the Console (never the file logger), so the whole
--- install aborts silently and the update wedges at "installing" forever.
---
--- This test pins the ROOT CAUSE (declaration order → upvalue capture), not a
--- symptom: it fails on the `local <id> = hs.task.new(` form and passes only when
--- the handle is forward-declared and the in-callback clear is guarded.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu_about: install task must be forward-declared (F-CRIT-2)", function()
	local function read_src()
		-- Selected by a declaration unique to ui/menu/menu_about.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function get_update_menu_label")
		helpers.assert_true(src ~= nil, "ui/menu/menu_about.lua source must be locatable")
		return src
	end

	helpers.it("never assigns an hs.task.new handle into a `local` on the same line", function()
		local src = read_src()
		-- The dangerous inline form: the closure literal on the RHS is compiled in a
		-- scope where the local does not yet exist, so it binds the nil global of
		-- that name. Forbidding it forces forward-declaration for every GC-pinned task.
		-- Scan line by line and ignore comment lines (a comment may legitimately
		-- spell out the dangerous form to document why it is forbidden).
		local offending
		for line in src:gmatch("[^\n]+") do
			local stripped = line:match("^%s*(.-)%s*$") or line
			if not stripped:match("^%-%-") and stripped:find("local%s+[%w_]+%s*=%s*hs%.task%.new") then
				offending = stripped
				break
			end
		end
		helpers.assert_true(offending == nil,
			"hs.task.new handles must be forward-declared (local X; X = hs.task.new(...)), never "
			.. "`local X = hs.task.new(...)` — a callback referencing X would bind the nil global. Offending: "
			.. tostring(offending))
	end)

	helpers.it("forward-declares the install task before the hs.task.new closure", function()
		local src = read_src()
		local decl_pos = src:find("local unzip_task", 1, true)
		local new_pos  = src:find("unzip_task = TaskLifecycle.native", 1, true)
		helpers.assert_true(decl_pos ~= nil, "install task must be forward-declared as `local unzip_task`")
		helpers.assert_true(new_pos ~= nil, "install task must be assigned via `unzip_task = TaskLifecycle.native`")
		helpers.assert_true(decl_pos < new_pos,
			"the local declaration must come BEFORE the hs.task.new closure so the callback captures the upvalue")
	end)

	helpers.it("guards the GC-pin clear so a nil key is never written", function()
		local src = read_src()
		helpers.assert_true(
			src:find("if unzip_task then M._active_tasks[unzip_task] = nil end", 1, true) ~= nil,
			"the in-callback clear must be guarded with `if unzip_task then` "
			.. "(writing M._active_tasks[nil] itself raises 'table index is nil')")
	end)
end)
