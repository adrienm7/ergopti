--- tests/meta/test_shell_runner_gc_protection.lua

--- ==============================================================================
--- MODULE: ShellRunner GC Protection Meta Test
--- DESCRIPTION:
--- Static source guard ensuring adapters/shell_runner.lua pins every live
--- hs.task in M._active_tasks so the GC cannot collect subprocess objects
--- before they exit.
---
--- hs.task objects not referenced from a GC root are collected by Lua, which
--- Hammerspoon translates to SIGKILL on the underlying OS process — silently
--- killing curl requests, discovery probes, and zombie-kill tasks mid-run.
--- M._active_tasks is the module-level GC root; entries are removed inside
--- the wrapped on_done callback once the process has exited.
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

helpers.describe("adapters/shell_runner.lua: GC protection", function()

	helpers.it("M._active_tasks module-level table is declared", function()
		local src = read_source("adapters/shell_runner.lua")
		helpers.assert_true(
			src:find("M%._active_tasks%s*=") ~= nil,
			"shell_runner.lua must declare M._active_tasks to pin live hs.task objects")
	end)

	helpers.it("spawn() registers the task in M._active_tasks before start()", function()
		local src = strip_comments(read_source("adapters/shell_runner.lua"))
		helpers.assert_true(
			src:find("M%._active_tasks%[_task%]%s*=%s*true") ~= nil,
			"spawn() must set M._active_tasks[_task] = true to prevent GC collection")
	end)

	helpers.it("wrapped_on_done removes the task from M._active_tasks", function()
		local src = strip_comments(read_source("adapters/shell_runner.lua"))
		-- The GC pin must be released via the closure upvalue _task (not the first
		-- callback arg, which is exit_code since hs.task passes no task object).
		helpers.assert_true(
			src:find("M%._active_tasks%[_task%]%s*=%s*nil") ~= nil,
			"spawn() on_done wrapper must set M._active_tasks[_task] = nil (closure upvalue, not callback arg) to release the GC root")
	end)

	helpers.it("hs.task.new uses wrapped_on_done, not the raw on_done", function()
		local src = strip_comments(read_source("adapters/shell_runner.lua"))
		-- Three call-site forms are accepted:
		--   Direct:  hs.task.new(executable, wrapped_on_done, ...)
		--   pcall 2-arg:  hs.task.new, wrapped_on_done
		--   pcall 3-arg:  pcall(hs.task.new, executable, wrapped_on_done, ...) — form used in shell_runner
		helpers.assert_true(
			src:find("hs%.task%.new%s*,%s*wrapped_on_done") ~= nil
			or src:find("hs%.task%.new%([^,]+,%s*wrapped_on_done") ~= nil
			or src:find("hs%.task%.new,%s*[^,]+,%s*wrapped_on_done") ~= nil,
			"hs.task.new must receive wrapped_on_done so the GC-root removal fires on exit")
	end)

end)
