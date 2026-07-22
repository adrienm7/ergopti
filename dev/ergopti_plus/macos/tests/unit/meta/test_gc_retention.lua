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

--- Checks that a source file using hs.task.new also has a recognizable
--- GC-root pin. Two spellings are recognized (F-MED-20):
---   1. The canonical own-module root: `_active_tasks` (M._active_tasks or
---      a local _active_tasks table declared in the same file).
---   2. The DELEGATED-pin spelling used by the models_manager_mlx_* split:
---      `deps.active_tasks[...]` / `active_tasks_gc_root` — the task is
---      pinned in a GC-root table owned by the PARENT module and injected
---      via ctx/deps, not redeclared locally. This is an equally valid pin
---      (deps is a long-lived table held by the caller) but the original
---      substring check (bare "_active_tasks") does not match "active_tasks"
---      preceded by a "." instead of "_", so these files silently passed by
---      accident (their hs.task.new calls happened to also contain a
---      DIFFERENT unrelated occurrence, or were never checked at all because
---      they were missing from the file list below).
--- @param rel_path string Relative path from the macos/ root.
local function assert_gc_pinned(rel_path)
	local src, err = read_source(rel_path)
	assert(src, (err or "missing") .. " — " .. rel_path)
	if not src:find("hs%.task%.new", 1, false) then return end  -- file does not use hs.task; skip
	local has_own_pin      = src:find("_active_tasks", 1, false) ~= nil
		-- Any *_tasks GC-root table counts (e.g. _active_probe_tasks in
		-- keymap/input_sources.lua) — the pin is what matters, not its exact name.
		or src:find("_active_[%w_]*tasks") ~= nil
	local has_delegated_pin = src:find("%.active_tasks") ~= nil
		or src:find("active_tasks_gc_root", 1, false) ~= nil
	-- A task awaited with waitUntilExit() is referenced by its local for the whole
	-- (blocking) lifetime, so the GC can never reach it mid-run: no pin required.
	local is_synchronous = src:find("waitUntilExit", 1, true) ~= nil
	assert(has_own_pin or has_delegated_pin or is_synchronous,
		rel_path .. ": uses hs.task.new but has no recognizable GC-root pin — "
		.. "add M._active_tasks = {} (own root) or pin via deps.active_tasks / "
		.. "active_tasks_gc_root (delegated root) before :start()")
end

--- Lists every driver .lua file, so the guard covers the whole CLASS instead of a
--- hand-maintained allowlist. Seven files using hs.task.new were absent from that
--- list and shipped unpinned for exactly that reason
--- (project-ahk-guard-tests-must-loop-the-class).
--- @return table Array of paths relative to the driver root.
local function all_driver_sources()
	local out = {}
	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(dir, prefix)
			for entry in lfs.dir(DRIVER_ROOT .. dir) do
				if entry ~= "." and entry ~= ".." then
					local rel  = prefix .. entry
					local attr = lfs.attributes(DRIVER_ROOT .. rel)
					if attr and attr.mode == "directory" then
						walk(rel .. "/", rel .. "/")
					elseif entry:match("%.lua$") then
						out[#out + 1] = rel
					end
				end
			end
		end
		for _, d in ipairs({ "adapters", "lib", "modules", "ui" }) do walk(d .. "/", d .. "/") end
		return out
	end

	local sep = package.config:sub(1, 1)
	local cmd = (sep == "\\")
		and ('cmd /c dir /b /s /a-d "' .. DRIVER_ROOT:gsub("/", "\\") .. '*.lua"')
		or ("find '" .. DRIVER_ROOT .. "' -type f -name '*.lua'")
	local pipe = io.popen(cmd)
	if not pipe then return out end
	for line in pipe:lines() do
		local norm = line:gsub("\\", "/"):gsub("%s+$", "")
		local rel  = norm:gsub("^.*/macos/", "")
		if rel:match("%.lua$")
			and not rel:match("^tests/") and not rel:match("^vendor/") and not rel:match("^_generated/") then
			out[#out + 1] = rel
		end
	end
	pipe:close()
	return out
end

helpers.describe("GC retention: EVERY driver source using hs.task.new is pinned", function()
	helpers.it("no driver file calls hs.task.new without a GC-root pin", function()
		local files = all_driver_sources()
		helpers.assert_true(#files > 0,
			"the source walk must find driver .lua files — an empty list would make this guard vacuous")

		local offenders = {}
		for _, rel in ipairs(files) do
			local ok = pcall(assert_gc_pinned, rel)
			if not ok then offenders[#offenders + 1] = rel end
		end

		helpers.assert_true(#offenders == 0, string.format(
			"%d file(s) call hs.task.new with no GC-root pin. An unreferenced hs.task is "
			.. "collected mid-run: the subprocess is killed and its completion callback never "
			.. "fires, so whatever it was supposed to finish silently never happens. Add a "
			.. "_active_tasks root, pin before :start(), release in the callback: %s",
			#offenders, table.concat(offenders, ", ")))
	end)
end)

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

	-- F-MED-20: these 2 of the 6 files split out of the old
	-- models_manager_mlx.lua monolith were missing from this allowlist
	-- entirely — their hs.task.new call sites pin via the DELEGATED spelling
	-- (deps.active_tasks[...]), which the original bare "_active_tasks"
	-- substring check did not recognize. New unpinned hs.task.new() calls in
	-- these files could previously ship with the suite still green.
	helpers.it("models_manager_mlx_download: pull/tail tasks are pinned (F-MED-20)", function()
		assert_gc_pinned("ui/menu/menu_llm/models_manager_mlx_download.lua")
	end)

	helpers.it("models_manager_mlx_hf: hf_login task is pinned (F-MED-20)", function()
		assert_gc_pinned("ui/menu/menu_llm/models_manager_mlx_hf.lua")
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
