--- tests/unit/meta/test_gc_retention.lua

--- ==============================================================================
--- MODULE: GC Retention Meta Test
--- DESCRIPTION:
--- Static source guard for the "hs.task silent death by GC" bug. Hammerspoon's
--- GC kills any hs.task whose Lua object is held only in a local variable the
--- moment the enclosing function returns, sending a SIGTERM to the subprocess
--- mid-run. This test ensures every hs.task.new() call site keeps a GC-root
--- reference (_active_tasks) so the task survives until its callback fires.
---
--- WHY PER-SITE AND NOT PER-FILE (gc-guard-file-granular): this guard used to
--- ask only whether the WORD `_active_tasks` appeared somewhere in the file. One
--- pin — or one `waitUntilExit` — anywhere greenlit every hs.task.new in it, so
--- the second, third and fourth spawn in an already-pinned module could ship
--- completely unprotected with the suite still green. That is not a theoretical
--- hole: it is exactly how the unpinned MLX server probe shipped green. A guard
--- that answers a question about the file cannot protect a call site.
---
--- Each site is therefore judged on its own lexical window. The real spawns pin
--- within 15 lines of the call, so the window is generous enough to accept every
--- legitimate spelling and still far too narrow for an unrelated pin elsewhere
--- in the module to vouch for an unprotected spawn.
---
--- HOW TO FIX a failure: add `M._active_tasks = {}` (or `local _active_tasks = {}`)
--- to the affected module, pin the task before :start(), and clear it in the
--- completion callback (using the closure over the local task variable).
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

-- Lexical window, in lines, searched around a spawn for its GC-root pin.
-- Measured worst case in the driver is 15 lines forward (shell_runner builds the
-- task, nil-tests it, then pins), so LOOKAHEAD keeps a wide margin while staying
-- far below the size of any enclosing module.
local PIN_LOOKBACK  = 12
local PIN_LOOKAHEAD = 40

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end




-- ===============================================
-- ===============================================
-- ======= 1/ The site-granular scanner ==========
-- ===============================================
-- ===============================================

--- True when a window of source contains a recognizable GC-root pin.
---
--- Three spellings are accepted, all of which genuinely root the task:
---   1. The canonical own-module root `_active_tasks` — and any `_active_*_tasks`
---      variant (e.g. `_active_probe_tasks` in keymap/input_sources.lua); the
---      pin is what matters, not its name.
---   2. The DELEGATED pin used by the models_manager_mlx_* split:
---      `deps.active_tasks[...]` / `active_tasks_gc_root`. The task is rooted in
---      a table owned by the PARENT module and injected via ctx/deps — equally
---      valid, since deps is long-lived and held by the caller.
---   3. `waitUntilExit`, which references the task from its local for the whole
---      blocking lifetime, so the GC can never reach it mid-run.
--- @param window string A slice of comment-free source.
--- @return boolean
local function window_has_pin(window)
	return window:find("_active_[%w_]*tasks") ~= nil
		or window:find("%.active_tasks") ~= nil
		or window:find("active_tasks_gc_root", 1, true) ~= nil
		or window:find("waitUntilExit", 1, true) ~= nil
end

--- Reports every hs.task.new call site in a source that has no pin near it.
---
--- Comments are stripped first, and this is load-bearing rather than cosmetic:
--- two modules DISCUSS `hs.task.new(...)` in prose while spawning nothing there
--- (shell_runner's on_chunk rationale, watchers' CapsWord note). Scanning raw
--- text reports those sentences as unprotected spawns, and a guard that cries
--- wolf on comments gets loosened until it protects nothing.
--- @param src string Lua source.
--- @return table Array of {line = number, text = string} for unpinned sites.
local function scan_unpinned_sites(src)
	local lines = {}
	for line in (src:gsub("%-%-[^\n]*", "") .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end

	local out = {}
	for i, line in ipairs(lines) do
		if line:find("hs%.task%.new") then
			local window = table.concat(lines, "\n",
				math.max(1, i - PIN_LOOKBACK), math.min(#lines, i + PIN_LOOKAHEAD))
			if not window_has_pin(window) then
				out[#out + 1] = { line = i, text = line:gsub("^%s+", "") }
			end
		end
	end
	return out
end

--- Asserts a driver file has no unpinned spawn.
--- @param rel_path string Relative path from the macos/ root.
local function assert_gc_pinned(rel_path)
	local src, err = read_source(rel_path)
	assert(src, (err or "missing") .. " — " .. rel_path)
	local offenders = scan_unpinned_sites(src)
	if #offenders == 0 then return end
	local where = {}
	for _, o in ipairs(offenders) do where[#where + 1] = rel_path .. ":" .. o.line end
	error(table.concat(where, ", ") .. ": hs.task.new with no GC-root pin within "
		.. PIN_LOOKAHEAD .. " lines — add M._active_tasks = {} (own root) or pin via "
		.. "deps.active_tasks / active_tasks_gc_root (delegated root) before :start()", 0)
end





-- ===================================================
-- ===================================================
-- ======= 2/ The scanner catches what it must =======
-- ===================================================
-- ===================================================

helpers.describe("GC retention: the guard is per-site, not per-file", function()
	helpers.it("an unpinned spawn is caught even when the file pins elsewhere", function()
		-- The exact false green this guard was rebuilt to close: a module with a
		-- legitimate pinned spawn at the top and a second, unprotected one far
		-- below. The old substring check saw `_active_tasks` in the file and
		-- passed the whole module.
		local fixture = { "local M = {}", "M._active_tasks = {}", "", "function M.first()",
			"\tlocal t = hs.task.new(\"/bin/ls\", cb)", "\tM._active_tasks[t] = true", "\tt:start()", "end", "" }
		for _ = 1, 60 do fixture[#fixture + 1] = "\t-- padding" end
		fixture[#fixture + 1] = "function M.second()"
		fixture[#fixture + 1] = "\tlocal t = hs.task.new(\"/bin/ls\", cb)"
		fixture[#fixture + 1] = "\tt:start()"
		fixture[#fixture + 1] = "end"

		local offenders = scan_unpinned_sites(table.concat(fixture, "\n"))
		helpers.assert_eq(#offenders, 1,
			"the second spawn is unprotected and must be reported. A guard that answers "
				.. "\"does this FILE mention a pin?\" greenlights every later spawn in an "
				.. "already-pinned module — which is how the unpinned probe shipped")
		helpers.assert_true(offenders[1] and offenders[1].line > 60,
			"and it must report the UNPINNED site, not the pinned one above it")
	end)

	helpers.it("a properly pinned spawn is not reported", function()
		local src = table.concat({
			"local _active_tasks = {}",
			"local t = hs.task.new(\"/bin/ls\", cb)",
			"_active_tasks[t] = true",
			"t:start()",
		}, "\n")
		helpers.assert_eq(#scan_unpinned_sites(src), 0,
			"a spawn pinned on the next line must pass — a guard nobody can satisfy gets deleted")
	end)

	helpers.it("prose about hs.task.new is not mistaken for a spawn", function()
		local src = "-- deactivate_capsword() contains an unguarded hs.task.new(...) call\nreturn false"
		helpers.assert_eq(#scan_unpinned_sites(src), 0,
			"comments must be stripped before scanning: two driver modules discuss hs.task.new "
				.. "in prose without spawning anything, and a guard that reports those sentences "
				.. "gets loosened until it protects nothing")
	end)

	helpers.it("a delegated pin counts, and only within the window", function()
		local near = "local t = hs.task.new(\"/bin/ls\", cb)\ndeps.active_tasks[t] = true"
		helpers.assert_eq(#scan_unpinned_sites(near), 0,
			"the models_manager_mlx_* split roots its tasks in the parent module's table, "
				.. "which is a real GC root")

		local far = { "deps.active_tasks[other] = true" }
		for _ = 1, PIN_LOOKAHEAD + 5 do far[#far + 1] = "local x = 1" end
		far[#far + 1] = "local t = hs.task.new(\"/bin/ls\", cb)"
		far[#far + 1] = "t:start()"
		helpers.assert_eq(#scan_unpinned_sites(table.concat(far, "\n")), 1,
			"but a pin that far away belongs to a DIFFERENT task and must not vouch for this one")
	end)
end)




-- ==================================================
-- ==================================================
-- ======= 3/ Every driver spawn is pinned ==========
-- ==================================================
-- ==================================================

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
		for _, d in ipairs({ "adapters", "infra", "modules", "ui" }) do walk(d .. "/", d .. "/") end
		-- Root-level sources are NOT inside those four directories, and init.lua is
		-- the largest of them. The shell fallback below scans the whole tree, so
		-- coverage silently depended on which of the two paths ran — green on a
		-- machine without lfs, blind on one with it.
		for entry in lfs.dir(DRIVER_ROOT) do
			if entry:match("%.lua$") then out[#out + 1] = entry end
		end
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

helpers.describe("GC retention: EVERY hs.task.new site in the driver is pinned", function()
	helpers.it("no call site spawns without a GC-root pin near it", function()
		local files = all_driver_sources()
		helpers.assert_true(#files > 0,
			"the source walk must find driver .lua files — an empty list would make this guard vacuous")

		local offenders, scanned = {}, 0
		for _, rel in ipairs(files) do
			local src = read_source(rel)
			if src then
				local sites = scan_unpinned_sites(src)
				if src:gsub("%-%-[^\n]*", ""):find("hs%.task%.new") then scanned = scanned + 1 end
				for _, o in ipairs(sites) do
					offenders[#offenders + 1] = rel .. ":" .. o.line .. "  " .. o.text
				end
			end
		end

		helpers.assert_true(scanned >= 10,
			"the walk must actually reach the spawning modules (found " .. scanned
				.. ") — a scan that matches nothing cannot fail")

		-- The walk has two implementations — an lfs recursion and a shell fallback
		-- — and they must enumerate the same tree. The lfs branch descended only
		-- into adapters/infra/modules/ui and skipped every ROOT-level source,
		-- init.lua included, so coverage silently depended on which branch ran:
		-- complete on a machine without lfs, blind on one with it. Asserting a
		-- known root file is present holds whichever branch executes here.
		local saw_root_source = false
		for _, rel in ipairs(files) do
			if rel == "init.lua" then saw_root_source = true end
		end
		helpers.assert_true(saw_root_source,
			"the walk must include root-level sources such as init.lua — otherwise an unpinned "
				.. "hs.task.new there is invisible to this guard on any machine where lfs is "
				.. "installed, and the suite reports coverage it does not have")

		helpers.assert_true(#offenders == 0, string.format(
			"%d hs.task.new call site(s) have no GC-root pin. An unreferenced hs.task is "
			.. "collected mid-run: the subprocess is killed and its completion callback never "
			.. "fires, so whatever it was supposed to finish silently never happens. Pin before "
			.. ":start(), release in the callback:\n  %s",
			#offenders, table.concat(offenders, "\n  ")))
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
		local src = read_source("local function focus_hammerspoon") -- infra/dialog_util.lua
		assert(src, "dialog_util.lua must exist")
		-- After the fix, dialog_util uses hs.timer.doAfter instead of hs.task.
		assert(not src:find("hs%.task%.new", 1, false),
			"dialog_util: hs.task.new must be replaced with hs.timer.doAfter to avoid GC kill")
	end)

	helpers.it("shell_runner: canonical GC-root table is present", function()
		local src = read_source("local function invoke_guarded") -- adapters/shell_runner.lua
		assert(src, "shell_runner.lua must exist")
		assert(src:find("_active_tasks", 1, false),
			"shell_runner: must maintain M._active_tasks as GC root for all spawned tasks")
	end)

end)
