--- tests/unit/meta/test_gc_retention.lua

--- ==============================================================================
--- MODULE: GC Retention Meta Test
--- DESCRIPTION:
--- Static source guard for the "hs.task silent death by GC" bug. Hammerspoon's
--- GC kills any hs.task whose Lua object is held only in a local variable the
--- moment the enclosing function returns, sending a SIGTERM to the subprocess
--- mid-run. This test ensures every module that calls hs.task.new() also
--- maintains a GC-root reference table (_active_tasks) to prevent that.
---
--- HOW TO FIX a failure: add `M._active_tasks = {}` (or `local _active_tasks = {}`)
--- to the affected module, pin the task before :start(), and clear it in the
--- completion callback (using the closure over the local task variable).
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel_path)
	local f = io.open(DRIVER_ROOT .. rel_path, "r")
	if not f then return nil, "cannot open: " .. DRIVER_ROOT .. rel_path end
	local src = f:read("*a")
	f:close()
	return src
end

--- Checks that a source file using hs.task.new also has an _active_tasks table.
--- @param rel_path string Relative path from the macos/ root.
local function assert_gc_pinned(rel_path)
	local src, err = read_source(rel_path)
	assert(src, (err or "missing") .. " — " .. rel_path)
	if not src:find("hs%.task%.new", 1, false) then return end  -- file does not use hs.task; skip
	local has_pin = src:find("_active_tasks", 1, false) ~= nil
	assert(has_pin,
		rel_path .. ": uses hs.task.new but has no _active_tasks GC-root table — "
		.. "add M._active_tasks = {} and pin each task before :start()")
end

helpers.describe("GC retention: hs.task pinning", function()

	-- Regression guard: each of these files was flagged by the expert audit as
	-- spawning bare hs.task.new() with no GC protection. The fix adds an
	-- _active_tasks table so the task survives until its callback fires.

	helpers.it("menu_about: unzip and rm tasks are pinned", function()
		assert_gc_pinned("ui/menu/menu_about.lua")
	end)

	helpers.it("models_manager_ollama: ollama-list task is pinned", function()
		assert_gc_pinned("ui/menu/menu_llm/models_manager_ollama.lua")
	end)

	helpers.it("models_manager_mlx: download/check tasks are pinned", function()
		assert_gc_pinned("ui/menu/menu_llm/models_manager_mlx.lua")
	end)

	helpers.it("models_manager_mlx_server: sweep and probe tasks are pinned", function()
		assert_gc_pinned("ui/menu/menu_llm/models_manager_mlx_server.lua")
	end)

	helpers.it("onboarding: shasum / curl / hdiutil / osascript tasks are pinned", function()
		assert_gc_pinned("modules/karabiner/onboarding.lua")
	end)

	helpers.it("menu_apps: open task is pinned", function()
		assert_gc_pinned("ui/menu/menu_apps.lua")
	end)

	helpers.it("dialog_util: no direct hs.task.new (replaced with hs.timer.doAfter)", function()
		local src = read_source("lib/dialog_util.lua")
		assert(src, "dialog_util.lua must exist")
		-- After the fix, dialog_util uses hs.timer.doAfter instead of hs.task.
		assert(not src:find("hs%.task%.new", 1, false),
			"dialog_util: hs.task.new must be replaced with hs.timer.doAfter to avoid GC kill")
	end)

	helpers.it("shell_runner: canonical GC-root table is present", function()
		local src = read_source("adapters/shell_runner.lua")
		assert(src, "shell_runner.lua must exist")
		assert(src:find("_active_tasks", 1, false),
			"shell_runner: must maintain M._active_tasks as GC root for all spawned tasks")
	end)

end)
