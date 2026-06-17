--- tests/meta/test_shell_runner_gc_protection.lua

--- ==============================================================================
--- MODULE: ShellRunner GC Protection Meta Test
--- DESCRIPTION:
--- Static source guard for the "shell-runner-gc-kill" audit finding in
--- adapters/shell_runner.lua.
---
--- ROOT CAUSE ENCODED:
--- hs.task objects created inside ShellRunner.spawn() were stored only in a
--- local closure variable (_task). Once the caller's handle reference went out
--- of scope, Lua's GC could collect _task, which Hammerspoon translates to
--- SIGKILL on the underlying OS process — silently killing curl requests,
--- discovery probes, and zombie-kill tasks mid-run.
---
--- The fix pins every live task in M._active_tasks (a module-level table) and
--- removes it only inside the wrapped on_done callback, guaranteeing a GC root
--- for the entire subprocess lifetime.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then
			out[#out + 1] = line
		end
	end
	return table.concat(out, "\n")
end


-- ============================================================
-- ============================================================
-- ======= 1/ M._active_tasks table is declared ===============
-- ============================================================
-- ============================================================

helpers.describe("adapters/shell_runner.lua: GC protection (shell-runner-gc-kill)", function()

	helpers.it("M._active_tasks module-level table is declared", function()
		local src = read_source("adapters/shell_runner.lua")
		helpers.assert_true(
			src:find("M%._active_tasks%s*=") ~= nil,
			"shell_runner.lua must declare M._active_tasks to pin live hs.task objects (shell-runner-gc-kill)")
	end)

	helpers.it("spawn() registers the task in M._active_tasks before start()", function()
		local src = strip_comments(read_source("adapters/shell_runner.lua"))
		helpers.assert_true(
			src:find("M%._active_tasks%[_task%]%s*=%s*true") ~= nil,
			"spawn() must set M._active_tasks[_task] = true to prevent GC collection (shell-runner-gc-kill)")
	end)

	helpers.it("wrapped_on_done removes the task from M._active_tasks", function()
		local src = strip_comments(read_source("adapters/shell_runner.lua"))
		helpers.assert_true(
			src:find("M%._active_tasks%[task%]%s*=%s*nil") ~= nil,
			"spawn() on_done wrapper must set M._active_tasks[task] = nil to release the GC root after completion (shell-runner-gc-kill)")
	end)

	helpers.it("hs.task.new uses wrapped_on_done, not the raw on_done", function()
		local src = strip_comments(read_source("adapters/shell_runner.lua"))
		helpers.assert_true(
			src:find("hs%.task%.new%s*,%s*wrapped_on_done") ~= nil
			or src:find("hs%.task%.new%([^,]+,%s*wrapped_on_done") ~= nil,
			"hs.task.new must receive wrapped_on_done so the GC-root removal fires on exit (shell-runner-gc-kill)")
	end)

end)
