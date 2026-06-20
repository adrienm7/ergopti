--- tests/unit/ui/menu/test_models_manager_ollama_task_forward_declared.lua

--- ==============================================================================
--- MODULE: Regression — models_manager_ollama installed-models refresh closure-nil
--- DESCRIPTION:
--- models_manager_ollama.lua refreshes the list of installed models by spawning
--- `ollama list` via hs.task. The completion callback clears the GC-root pin via
--- _active_tasks[task] = nil, using the task handle as a key.
---
--- The inline `local task = hs.task.new(...)` form compiled the closure before the
--- local was in scope, binding the nil global _G.task. The callback then attempted
--- _active_tasks[nil] = nil → "table index is nil" (swallowed to HS Console),
--- so the GC-root pin was never released and the task object was leaked.
---
--- Note: a second hs.task.new in this file (the `ollama pull` task) uses a
--- hardcoded string key `deps.active_tasks["ollama_pull"]` and is safe inline.
---
--- Fix: forward-declare only the dangerous handle (the one whose callback references
--- the variable as a key). This test pins the ROOT CAUSE (declaration order).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("models_manager_ollama: installed-models refresh task is forward-declared (closure-nil guard)", function()
	local function read_src()
		local path = helpers.driver_root() .. "ui/menu/menu_llm/models_manager_ollama.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "cannot open models_manager_ollama.lua at " .. tostring(path))
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("the installed-models refresh task is forward-declared before the hs.task.new closure", function()
		local src = read_src()
		-- Anchor on the nil-guard that only the dangerous (fixed) site uses:
		-- `if task then _active_tasks[task] = nil end`
		local guard_pos = src:find("if task then _active_tasks[task] = nil end", 1, true)
		helpers.assert_true(guard_pos ~= nil,
			"the installed-models callback must guard the GC-pin clear with `if task then _active_tasks[task] = nil end`")

		-- Extract the source window before the guard and confirm a forward declaration exists
		local window = src:sub(1, guard_pos)
		local decl_pos = window:find("local task\n", 1, true)
		local new_pos  = window:find("task = hs.task.new(", 1, true)

		helpers.assert_true(decl_pos ~= nil,
			"the installed-models task must be forward-declared as `local task` (own line)")
		helpers.assert_true(new_pos ~= nil,
			"the installed-models task must be assigned via `task = hs.task.new(`")
		helpers.assert_true(decl_pos < new_pos,
			"forward declaration must precede the hs.task.new closure so the callback captures the upvalue")
	end)

	helpers.it("the GC-pin release is guarded against nil task", function()
		local src = read_src()
		helpers.assert_true(
			src:find("if task then _active_tasks[task] = nil end", 1, true) ~= nil,
			"_active_tasks[task] = nil must be guarded with `if task then` "
			.. "(_active_tasks[nil] = nil raises 'table index is nil')")
	end)
end)
