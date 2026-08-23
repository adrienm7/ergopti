--- tests/unit/meta/test_gc_retention.lua

--- ==============================================================================
--- MODULE: GC Retention Meta Test
--- DESCRIPTION:
--- Static source guard for the "hs.task silent death by GC" bug. Hammerspoon's
--- GC kills any hs.task whose Lua object is held only in a local variable the
--- moment the enclosing function returns, sending a SIGTERM to the subprocess
--- mid-run. This test ensures every guarded native-task launch keeps a GC-root
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
--- Raw hs.task sites are judged on their own lexical window. TaskLifecycle sites
--- instead follow the exact assigned handle (including a proven local alias) to
--- an exact GC-root pin and then to the matching TaskLifecycle.start call. That
--- keeps callback-heavy construction transactions valid without letting a fixed
--- source slice associate the launch with another task's pin.
---
--- HOW TO FIX a failure: add `M._active_tasks = {}` (or `local _active_tasks = {}`)
--- to the affected module, pin the task before :start(), and clear it in the
--- completion callback (using the closure over the local task variable).
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

-- Lexical window, in lines, searched around a raw hs.task spawn for its GC-root pin.
-- Measured worst case in the driver is 15 lines forward (shell_runner builds the
-- task, nil-tests it, then pins), so LOOKAHEAD keeps a wide margin while staying
-- far below the size of any enclosing module.
local RAW_PIN_LOOKBACK  = 12
local RAW_PIN_LOOKAHEAD = 40

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

--- True when a raw-task window contains a recognizable root or blocking owner.
--- Exact task identity and start ordering are enforced separately for adapter
--- launches, where callbacks can make a safe transaction much longer than this
--- raw fallback window.
--- @param window string A slice of comment-free source.
--- @return boolean
local function raw_window_has_pin(window)
	return window:find("_active_[%w_]*tasks") ~= nil
		or window:find("%.active_tasks") ~= nil
		or window:find("active_tasks_gc_root", 1, true) ~= nil
		or window:find("waitUntilExit", 1, true) ~= nil
end

--- Finds the outer call containing a function-value token.
--- @param code string Comment-free source.
--- @param token_at number Token byte position.
--- @return number|nil open_at
local function find_enclosing_call_open(code, token_at)
	local depth = 0
	for i = token_at - 1, 1, -1 do
		local char = code:sub(i, i)
		if char == ")" then
			depth = depth + 1
		elseif char == "(" then
			if depth == 0 then return i end
			depth = depth - 1
		end
	end
	return nil
end

--- Resolves the exact assignment target of a direct or wrapped native call.
--- @param code string Comment-free source.
--- @param native_at number TaskLifecycle.native byte position.
--- @return string|nil task_name
local function assigned_native_name(code, native_at)
	local prefix = code:sub(1, native_at - 1)
	local direct = prefix:match("([%a_][%w_]*)%s*=%s*$")
	if direct then return direct end

	local open_at = find_enclosing_call_open(code, native_at)
	if not open_at then return nil end
	local before_call = code:sub(1, open_at - 1)
	local callee = before_call:match("([%a_][%w_%.:]*)%s*$")
	if not callee then return nil end
	local assignment_prefix = before_call:gsub(
		"[%a_][%w_%.:]*%s*$", "")
	return assignment_prefix:match("([%a_][%w_]*)%s*=%s*$")
end

--- Tracks explicit aliases created after native construction.
--- @param window string Source from one native site to the next.
--- @param assigned_name string Exact construction result.
--- @return table<string, number> Alias availability positions.
local function task_aliases(window, assigned_name)
	local aliases = { [assigned_name] = 1 }
	local cursor = 1
	while true do
		local at, finish, lhs, rhs = window:find(
			"([%a_][%w_]*)%s*=%s*([%a_][%w_]*)%f[^%w_]", cursor)
		if not at then break end
		if aliases[rhs] and aliases[rhs] <= at and aliases[lhs] == nil then
			aliases[lhs] = at
		end
		cursor = finish + 1
	end
	return aliases
end

local function earliest_exact_pin(window, task_name, available_at)
	local rhs = task_name .. "%f[^%w_]"
	local earliest = nil
	for _, pattern in ipairs({
		"_active_[%w_]*tasks%s*%[%s*" .. task_name .. "%s*%]%s*=%s*true%f[^%w_]",
		"_active_[%w_]*tasks%s*%b[]%s*=%s*" .. rhs,
		"deps%.active_tasks%s*%b[]%s*=%s*" .. rhs,
		"active_tasks_gc_root%s*%b[]%s*=%s*" .. rhs,
		"owner%.tasks%.[%a_][%w_]*%s*=%s*" .. rhs,
		"owner%.tasks%s*%b[]%s*=%s*" .. rhs,
	}) do
		local at = window:find(pattern, available_at)
		if at then earliest = not earliest and at or math.min(earliest, at) end
	end
	return earliest
end

local function has_exact_start_after(window, task_name, pin_at)
	local exact = task_name .. "%f[^%w_]"
	for _, pattern in ipairs({
		"TaskLifecycle%.start%s*%(%s*" .. exact,
		"TaskLifecycle%.start%s*,%s*" .. exact,
		"TaskLifecycle%.start%s*,%s*debug%.traceback%s*,%s*" .. exact,
	}) do
		local start_at = window:find(pattern, pin_at + 1)
		if start_at then return true end
	end
	return false
end

local function delegates_exact_task(window, task_name, available_at)
	return window:find(
		"start_owned_task%s*%(%s*[%a_][%w_]*%s*,%s*"
			.. task_name .. "%s*,", available_at) ~= nil
end

local function native_site_is_pinned(window, assigned_name)
	if not assigned_name then return false end
	for task_name, available_at in pairs(task_aliases(window, assigned_name)) do
		local pin_at = earliest_exact_pin(window, task_name, available_at)
		if pin_at and has_exact_start_after(window, task_name, pin_at) then return true end
		if delegates_exact_task(window, task_name, available_at) then return true end
	end
	return false
end

local function line_number_at(code, position)
	local _, newlines = code:sub(1, position - 1):gsub("\n", "")
	return newlines + 1
end

--- Reports every raw or TaskLifecycle.native task site with no valid ownership.
---
--- Comments are stripped first, and this is load-bearing rather than cosmetic:
--- two modules DISCUSS `hs.task.new(...)` in prose while spawning nothing there
--- (shell_runner's on_chunk rationale, watchers' CapsWord note). Scanning raw
--- text reports those sentences as unprotected spawns, and a guard that cries
--- wolf on comments gets loosened until it protects nothing.
--- @param src string Lua source.
--- @return table Array of {line = number, text = string} for unpinned sites.
local function scan_unpinned_sites(src)
	local code = src:gsub("%-%-[^\n]*", "")
	local lines = {}
	for line in (code .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end

	local out = {}
	for i, line in ipairs(lines) do
		if line:find("hs%.task%.new%s*%(")
				or line:find("pcall%s*%(%s*hs%.task%.new") then
			local window = table.concat(lines, "\n",
				math.max(1, i - RAW_PIN_LOOKBACK),
				math.min(#lines, i + RAW_PIN_LOOKAHEAD))
			if not raw_window_has_pin(window) then
				out[#out + 1] = { line = i, text = line:gsub("^%s+", "") }
			end
		end
	end

	local cursor = 1
	while true do
		local native_at = code:find("TaskLifecycle.native", cursor, true)
		if not native_at then break end
		local next_at = code:find("TaskLifecycle.native", native_at + 1, true)
		local window = code:sub(native_at, (next_at or (#code + 1)) - 1)
		local assigned_name = assigned_native_name(code, native_at)
		if not native_site_is_pinned(window, assigned_name) then
			local line = line_number_at(code, native_at)
			out[#out + 1] = {
				line = line,
				text = (lines[line] or "TaskLifecycle.native"):gsub("^%s+", ""),
			}
		end
		cursor = next_at or (#code + 1)
		if not next_at then break end
	end
	return out
end

--- Asserts a driver file has no unpinned spawn.
--- @param rel_path string Relative path from the macos/ root.
-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function assert_gc_pinned(selector)
	local src, err = read_source(selector)
	assert(src, (err or "missing") .. " — " .. selector)
	local offenders = scan_unpinned_sites(src)
	if #offenders == 0 then return end
	local where = {}
	for _, o in ipairs(offenders) do where[#where + 1] = selector .. ":" .. o.line end
	error(table.concat(where, ", ") .. ": task launch with no GC-root ownership — "
		.. "raw sites need a nearby root; TaskLifecycle sites need the exact handle pinned "
		.. "through _active_tasks, deps.active_tasks, active_tasks_gc_root, or owner.tasks "
		.. "before its exact TaskLifecycle.start", 0)
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

	helpers.it("a delegated raw pin counts, and only within the raw window", function()
		local near = "local t = hs.task.new(\"/bin/ls\", cb)\ndeps.active_tasks[t] = true"
		helpers.assert_eq(#scan_unpinned_sites(near), 0,
			"the models_manager_mlx_* split roots its tasks in the parent module's table, "
				.. "which is a real GC root")

		local far = { "deps.active_tasks[other] = true" }
		for _ = 1, RAW_PIN_LOOKAHEAD + 5 do far[#far + 1] = "local x = 1" end
		far[#far + 1] = "local t = hs.task.new(\"/bin/ls\", cb)"
		far[#far + 1] = "t:start()"
		helpers.assert_eq(#scan_unpinned_sites(table.concat(far, "\n")), 1,
			"but a pin that far away belongs to a DIFFERENT task and must not vouch for this one")
	end)

	helpers.it("binds a callback-heavy native site to its exact owner slot and start", function()
		local fixture = {
			"local launcher_task",
			"launcher_task = run_owner_task_acquisition(owner,",
			"\t\"construction\", TaskLifecycle.native, \"launcher\", bin, cb)",
		}
		for _ = 1, RAW_PIN_LOOKAHEAD + 5 do
			fixture[#fixture + 1] = "callback_state = callback_state"
		end
		fixture[#fixture + 1] = "owner.tasks.launcher = launcher_task"
		fixture[#fixture + 1] = "local started = run_owner_task_acquisition(owner,"
		fixture[#fixture + 1] = "\t\"start\", TaskLifecycle.start, launcher_task, \"launcher\")"

		helpers.assert_eq(#scan_unpinned_sites(table.concat(fixture, "\n")), 0,
			"the exact owner.tasks slot remains a valid root even when construction callbacks "
				.. "place it beyond the old fixed lookahead")
	end)

	helpers.it("rejects a different pin, a different start, and reversed ordering", function()
		local wrong_pin = table.concat({
			"local task = TaskLifecycle.native(\"worker\", bin, cb)",
			"owner.tasks.worker = other_task",
			"TaskLifecycle.start(task, \"worker\")",
		}, "\n")
		helpers.assert_eq(#scan_unpinned_sites(wrong_pin), 1,
			"another task's owner slot must not certify this native identity")

		local wrong_start = table.concat({
			"local task = TaskLifecycle.native(\"worker\", bin, cb)",
			"owner.tasks.worker = task",
			"TaskLifecycle.start(other_task, \"worker\")",
		}, "\n")
		helpers.assert_eq(#scan_unpinned_sites(wrong_start), 1,
			"a real pin must still lead to TaskLifecycle.start for the same identity")

		local start_before_pin = table.concat({
			"local task = TaskLifecycle.native(\"worker\", bin, cb)",
			"TaskLifecycle.start(task, \"worker\")",
			"owner.tasks.worker = task",
		}, "\n")
		helpers.assert_eq(#scan_unpinned_sites(start_before_pin), 1,
			"publication after native start is too late to protect synchronous completion")
	end)

	helpers.it("the onboarding owner helper must be called at the launch site", function()
		local owned = table.concat({
			"local task = TaskLifecycle.native(\"installer\", bin, cb, args)",
			"start_owned_task(owner, task, \"download\", \"installer\", cb, gate)",
		}, "\n")
		helpers.assert_eq(#scan_unpinned_sites(owned), 0,
			"the installer helper behaviorally pins the exact task before native start")

		local mention_only = table.concat({
			"local task = TaskLifecycle.native(\"installer\", bin, cb, args)",
			"local start_owned_task = false",
			"task:start()",
		}, "\n")
		helpers.assert_eq(#scan_unpinned_sites(mention_only), 1,
			"a nearby identifier must not certify an unowned task without invoking the owner helper")
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
		for _, d in ipairs({ "adapters", "infra", "modules", "platform", "ui" }) do walk(d .. "/", d .. "/") end
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

helpers.describe("GC retention: EVERY native task site in the driver is pinned", function()
	helpers.it("no call site spawns without exact GC-root ownership", function()
		local files = all_driver_sources()
		helpers.assert_true(#files > 0,
			"the source walk must find driver .lua files — an empty list would make this guard vacuous")

		local offenders, scanned = {}, 0
		for _, rel in ipairs(files) do
			local src = read_source(rel)
			if src then
				local code = src:gsub("%-%-[^\n]*", "")
				-- TaskLifecycle owns construction only; its callers own the handle and
				-- pin before start. Judge each caller launch, not the adapter's return.
				local sites = rel == "adapters/task_lifecycle.lua" and {}
					or scan_unpinned_sites(src)
				if code:find("hs%.task%.new%s*%(")
						or code:find("pcall%s*%(%s*hs%.task%.new")
						or code:find("TaskLifecycle%.native") then
					scanned = scanned + 1
				end
				for _, o in ipairs(sites) do
					offenders[#offenders + 1] = rel .. ":" .. o.line .. "  " .. o.text
				end
			end
		end

		helpers.assert_true(scanned >= 10,
			"the walk must actually reach the native-task launchers (found " .. scanned
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
				"%d native task launch site(s) have no GC-root pin. An unreferenced hs.task is "
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
		assert_gc_pinned("local function get_update_menu_label") -- ui/menu/menu_about.lua
	end)

	helpers.it("models_manager_ollama: ollama-list task is pinned", function()
		assert_gc_pinned("local function get_ollama_path") -- ui/menu/menu_llm/models_manager_ollama.lua
	end)

	helpers.it("models_manager_mlx: download/check tasks are pinned", function()
		assert_gc_pinned("\"Cause inconnue. Consultez la console Hammerspoon.\"") -- ui/menu/menu_llm/models_manager_mlx.lua
	end)

	helpers.it("models_manager_mlx_server: sweep and probe tasks are pinned", function()
		assert_gc_pinned("\"a healthy mlx_lm.server is answering on the configured port\"") -- ui/menu/menu_llm/models_manager_mlx_server.lua
	end)

	-- F-MED-20: these 2 of the 6 files split out of the old
	-- models_manager_mlx.lua monolith were missing from this allowlist
	-- entirely — their hs.task.new call sites pin via the DELEGATED spelling
	-- (deps.active_tasks[...]), which the original bare "_active_tasks"
	-- substring check did not recognize. New unpinned hs.task.new() calls in
	-- these files could previously ship with the suite still green.
	helpers.it("models_manager_mlx_download: pull/tail tasks are pinned (F-MED-20)", function()
		assert_gc_pinned("\"mlx.download_interrupted_body\"") -- ui/menu/menu_llm/models_manager_mlx_download.lua
	end)

	helpers.it("models_manager_mlx_hf: hf_login task is pinned (F-MED-20)", function()
		assert_gc_pinned("local HF_TOKEN_FILE") -- ui/menu/menu_llm/models_manager_mlx_hf.lua
	end)

	helpers.it("onboarding: shasum / curl / hdiutil / osascript tasks are pinned", function()
		assert_gc_pinned("local function run_pkg_with_sudo_async") -- platform/remap/onboarding.lua
	end)

	helpers.it("menu_apps: open task is pinned", function()
		assert_gc_pinned("local function discover_bundled_apps") -- ui/menu/menu_apps.lua
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
