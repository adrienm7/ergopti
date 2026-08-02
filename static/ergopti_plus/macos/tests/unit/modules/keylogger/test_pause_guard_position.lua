--- tests/unit/modules/keylogger/test_pause_guard_position.lua

--- ==============================================================================
--- MODULE: Regression — every keylogger writer entry point is pause-gated (C1)
--- DESCRIPTION:
--- Prior audit C1: handle_key's is_paused() guard sat AFTER the mouse / keyUp /
--- flagsChanged branches, so while paused the keylogger still logged clicks, key
--- releases, and modifier press/hold — violating « pause = tout éteint ». The fix
--- hoisted the guard to the top of handle_key (right after the is_enabled check),
--- but the existing test only checks the string `is_paused` appears in the file,
--- NOT that the guard's POSITION precedes the branches — so a refactor moving it
--- back down would stay green. This test pins the ORDER (the C1 root cause).
---
--- WHY THE SCOPE WAS WIDENED:
--- Section 1 below pinned handle_key and NOTHING ELSE. That single-function scope
--- is exactly why a second violation survived 3099 green tests: context_tracker
--- held no reference to the pause predicate at all, so app switches, window
--- TITLES and native-autocorrect events kept being recorded while paused. Their
--- drivers (hs.window.filter, ProcessLifecycle.onAppActivate, the AX observer)
--- are torn down only by keylogger.M.stop(), which pause never calls.
---
--- Per `project-ahk-guard-tests-must-loop-the-class`, a guard test must enumerate
--- the WHOLE CLASS of entry points, not one member. Section 2 asserts the guard's
--- position in every watcher-driven writer; section 3 fails when a NEW writer
--- appears that is neither gated nor explicitly justified as exempt.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ handle_key Guard Order =======
-- =========================================
-- =========================================

helpers.describe("keylogger: pause guard precedes the mouse/keyUp/flagsChanged branches (C1)", function()
	helpers.it("the is_paused() guard appears before the event-type branches in handle_key", function()
		-- Selected by a declaration unique to modules/keylogger/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function ensure_browser_window_filter")
		helpers.assert_true(src ~= nil, "modules/keylogger/init.lua source must be locatable")

		local hk = src:find("local function handle_key", 1, true)
		helpers.assert_true(hk ~= nil, "handle_key must be locatable")

		-- First is_paused() AFTER handle_key starts = the pause guard.
		local guard = src:find("is_paused()", hk, true)
		local mouse = src:find("leftMouseDown", hk, true)
		local flags = src:find("flagsChanged", hk, true)

		helpers.assert_true(guard ~= nil, "handle_key must contain an is_paused() guard")
		helpers.assert_true(mouse ~= nil and flags ~= nil, "handle_key must branch on mouse + flagsChanged events")
		helpers.assert_true(guard < mouse, "the pause guard must precede the mouse branch (else clicks log while paused)")
		helpers.assert_true(guard < flags, "the pause guard must precede the flagsChanged branch (else modifiers log while paused)")
	end)
end)





-- =========================================================
-- =========================================================
-- ======= 2/ The Whole Class Of Writer Entry Points =======
-- =========================================================
-- =========================================================

--- Reads a driver source file.
--- @param rel string Path relative to the driver root.
--- @return string File contents.
-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

--- Returns the source slice belonging to one function: from its declaration up
--- to the next top-level declaration. Bounding the slice matters — an unbounded
--- search would happily find the NEXT function's pause guard and report a
--- false green for a writer that has none of its own.
--- @param src string Full file contents.
--- @param decl string Exact declaration text to locate.
--- @return string|nil The function's source slice.
local function function_slice(src, decl)
	local start_pos = src:find(decl, 1, true)
	if not start_pos then return nil end
	local search_from = start_pos + #decl
	local next_fn = src:find("\nfunction ", search_from, true)
	local next_local = src:find("\nlocal function ", search_from, true)
	local stop_pos = math.min(next_fn or #src, next_local or #src)
	return src:sub(start_pos, stop_pos)
end

--- Every keylogger entry point that can reach a writer while an OS watcher is
--- still live during pause. `writer` is the first persistence call in the body:
--- the guard MUST appear before it.
local PAUSE_GATED_ENTRY_POINTS = {
	{
		label  = "keylogger/init.lua handle_key",
		file   = "modules/keylogger/init.lua",
		decl   = "local function handle_key",
		writer = "leftMouseDown",
	},
	{
		label  = "context_tracker update_private_status (logs window TITLES)",
		file   = "modules/keylogger/context_tracker.lua",
		decl   = "function M.update_private_status()",
		writer = "_log_manager.append_log",
	},
	{
		label  = "context_tracker app_watcher_cb (logs app switches)",
		file   = "modules/keylogger/context_tracker.lua",
		decl   = "function M.app_watcher_cb(",
		writer = "_log_manager.log_app_switch",
	},
	{
		label  = "context_tracker handle_ax_value_changed (logs sys_autocorrect)",
		file   = "modules/keylogger/context_tracker.lua",
		decl   = "local function handle_ax_value_changed(",
		writer = "_log_manager.flush_buffer",
	},
}

helpers.describe("keylogger: EVERY watcher-driven writer is pause-gated (project-suspend-pause-invariant)", function()
	for _, spec in ipairs(PAUSE_GATED_ENTRY_POINTS) do
		helpers.it(spec.label .. " — pause guard precedes its first write", function()
			local src   = read_source(spec.file)
			local slice = function_slice(src, spec.decl)
			helpers.assert_true(slice ~= nil, spec.decl .. " must be locatable in " .. spec.file)

			-- Matches both `is_paused()` and `_is_paused()`.
			local guard  = slice:find("is_paused()", 1, true)
			local writer = slice:find(spec.writer, 1, true)

			helpers.assert_true(writer ~= nil,
				spec.label .. " must still contain its writer call (" .. spec.writer
				.. ") — silencing pause by deleting the writer is not a fix")
			helpers.assert_true(guard ~= nil,
				spec.label .. " must contain a pause guard — a paused script records NOTHING")
			helpers.assert_true(guard < writer,
				spec.label .. " must check pause BEFORE writing, not after")
		end)
	end
end)





-- =============================================================
-- =============================================================
-- ======= 3/ No New Ungated Writer May Appear Unnoticed =======
-- =============================================================
-- =============================================================

--- Functions allowed to reach the log manager without a pause guard, with the
--- reason each is safe. They persist an interval that was accumulated while the
--- script was RUNNING; gating them would discard the user's real work instead of
--- protecting anything, and neither is driven by a live watcher during pause.
local PAUSE_EXEMPT_WRITERS = {
	-- Called from the engine stop path to flush the last open interval.
	close_active_app = true,
	-- Called by midnight maintenance, which is explicitly documented to run late
	-- when Ergopti was paused across the boundary.
	split_active_app_at_midnight = true,
}

--- Names of the functions section 2 pins as gated.
local GATED_FUNCTIONS = {
	update_private_status    = true,
	app_watcher_cb           = true,
	handle_ax_value_changed  = true,
}

helpers.describe("keylogger: no context_tracker writer escapes the pause classification", function()
	helpers.it("every _log_manager.* call site sits in a gated or explicitly exempt function", function()
		local src = read_source("local function update_secure_field_state") -- modules/keylogger/context_tracker.lua

		-- Walk the file once, tracking the most recent function declaration so
		-- each writer call can be attributed to its enclosing function.
		local current_fn = "<file scope>"
		local unclassified = {}
		local writer_sites = 0

		for line in src:gmatch("[^\n]*") do
			local declared = line:match("^function M%.([%w_]+)%s*%(")
				or line:match("^local function ([%w_]+)%s*%(")
			if declared then current_fn = declared end

			if line:find("_log_manager%.[%w_]+%(") then
				writer_sites = writer_sites + 1
				if not GATED_FUNCTIONS[current_fn] and not PAUSE_EXEMPT_WRITERS[current_fn] then
					unclassified[#unclassified + 1] = current_fn
				end
			end
		end

		helpers.assert_true(writer_sites > 0,
			"the scan must find the context tracker's writer call sites — otherwise this test is inert")
		helpers.assert_eq(#unclassified, 0,
			"new context_tracker writer(s) in " .. table.concat(unclassified, ", ")
			.. " are neither pause-gated nor listed as exempt — add the guard "
			.. "(and an entry in PAUSE_GATED_ENTRY_POINTS), or justify the exemption")
	end)
end)
