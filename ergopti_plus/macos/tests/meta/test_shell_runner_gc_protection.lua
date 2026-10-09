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

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
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
		local src = read_source("local function invoke_guarded") -- adapters/shell_runner.lua
		helpers.assert_true(
			src:find("M%._active_tasks%s*=") ~= nil,
			"shell_runner.lua must declare M._active_tasks to pin live hs.task objects")
	end)

	helpers.it("spawn() registers the task in M._active_tasks before start()", function()
		local src = strip_comments(read_source("local function invoke_guarded"))
		helpers.assert_true(
			src:find("M%._active_tasks%[_task%]%s*=%s*true") ~= nil,
			"spawn() must set M._active_tasks[_task] = true to prevent GC collection")
	end)

	helpers.it("wrapped_on_done removes the task from M._active_tasks", function()
		local src = strip_comments(read_source("local function invoke_guarded"))
		local done_start = assert(src:find("local function wrapped_on_done", 1, true))
		local done_end = assert(src:find("local function wrapped_on_chunk", done_start, true))
		local done_body = src:sub(done_start, done_end - 1)
		-- Capture the closure upvalue before clearing it. The first callback arg is
		-- only exit_code, and indexing the GC root with that integer leaks the task.
		helpers.assert_true(
			done_body:find("local%s+completed_task%s*=%s*_task") ~= nil
				and done_body:find("M%._active_tasks%[completed_task%]%s*=%s*nil") ~= nil
				and done_body:find("_task%s*=%s*nil") ~= nil,
			"wrapped_on_done must capture and release the exact closure task before clearing it")
	end)

	helpers.it("hs.task.new uses wrapped_on_done, not the raw on_done", function()
		local src = strip_comments(read_source("local function invoke_guarded"))
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
