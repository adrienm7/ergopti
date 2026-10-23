--- _shared/lua/layouts/composer_check.lua

--- ==============================================================================
--- MODULE: Layout Composer Check (Shared)
--- DESCRIPTION:
--- The steps of the Debug menu's one-click « Test the composed layout » on
--- macOS and Linux (the Windows host does the same in
--- windows/ui/layout_manager/composer_check.ahk, with the same step identities):
--- builds the shipped small composition, installs it through the composer's
--- real save path, verifies the installed copy against its record, asks the
--- driver whether the host is ready to type the layout, removes the
--- composition again, and reports each step to the report of
--- field_check_report.lua.
---
--- FEATURES & RATIONALE:
--- 1. Never overwrites the user's work: when a composition is already stored,
---    installed or in use, the check only verifies that one (no save, no
---    removal) and says so in its mode step. Otherwise what it installs is
---    removed at the end, whatever happened in between.
--- 2. Nothing is selected: the save runs with use = false, so the typing
---    layout and the input source in use stay as they were.
--- 3. PURE Lua: every operation is injected through env, so the same steps run
---    against fixtures in the portable suite and against the real driver
---    through the adapters (macos/modules/keymap/composer_check.lua,
---    linux/modules/keymap/composer_check.lua).
--- 4. Settle once: finish runs exactly once, even if a port calls back twice.
--- ==============================================================================

local Report = require("field_check_report")

local M = {}

--- Identity of the check in its evidence record; the Windows record carries the same.
M.CHECK_ID = "composer"

local PASS, FAIL, INFO, SKIP = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO, Report.STATE_SKIP

--- Runs the check.
--- env: composer_id, declaration_path, registry (composer_save, composer_remove),
---   deps (what the registry takes as its last argument, or nil), snapshot() ->
---   { installed, active, record_error }, read_fixture() -> { declaration,
---   keylayout } | nil, err, exists(path), read_copy() -> text | nil, sha256(text,
---   callback), host_ready(installed_info, entry) -> state, value, log(level,
---   message, ...).
--- @param env table
--- @param report table From field_check_report.new_report.
--- @param finish function Called once when the report is complete.
function M.run(env, report, finish)
	local settled = false
	local function done()
		if settled then return end
		settled = true
		finish()
	end
	--- Records a step unless it is already there: a late callback of a run that
	--- already failed must not raise.
	local function step(id, state, value)
		if not report.has(id) then report.step(id, state, value) end
	end

	local fresh = false
	local cleanup, verify

	--- Removes what a fresh run installed, then reports.
	cleanup = function()
		if not fresh then
			step("composer_cleanup", SKIP, "kept")
			done()
			return
		end
		local answered = false
		local dispatched, dispatch_err = pcall(env.registry.composer_remove, function(ok, code)
			answered = true
			if not ok then
				env.log("error", "The check composition was not removed (%s).", tostring(code))
				step("composer_cleanup", FAIL, code or "failed")
				done()
				return
			end
			local snapshot = env.snapshot()
			local left = (snapshot.installed or {})[env.composer_id] ~= nil or env.exists(env.declaration_path)
			step("composer_cleanup", left and FAIL or PASS, left and "left_behind" or nil)
			done()
		end, env.deps)
		if not dispatched and answered then error(dispatch_err, 0) end
		if not dispatched then
			env.log("error", "The check composition could not be removed: %s", tostring(dispatch_err))
			step("composer_cleanup", FAIL, "refused")
			done()
		end
	end

	--- The installed copy against its record, then the driver's readiness.
	verify = function(info)
		local snapshot = env.snapshot()
		local entry = (snapshot.installed or {})[env.composer_id]
		local text = env.read_copy()
		if entry == nil or type(text) ~= "string" then
			env.log("error", "The installed composition is missing or unreadable.")
			step("composer_copy", FAIL, "unreadable")
			step("composer_ready", SKIP, "no_copy")
			cleanup()
			return
		end
		env.sha256(text, function(digest)
			if digest ~= entry.sha256 then
				env.log("error", "The installed composition no longer matches its record.")
				step("composer_copy", FAIL, "digest_mismatch")
				step("composer_ready", SKIP, "no_copy")
				cleanup()
				return
			end
			step("composer_copy", PASS)
			local ok, state, value = pcall(env.host_ready, info, entry)
			if ok then
				step("composer_ready", state, value)
			else
				env.log("error", "The readiness probe raised: %s", tostring(state))
				step("composer_ready", FAIL, "probe_raised")
			end
			cleanup()
		end)
	end

	local fixture, fixture_err = env.read_fixture()
	if type(fixture) ~= "table" or type(fixture.declaration) ~= "string" or type(fixture.keylayout) ~= "string" then
		env.log("error", "The shipped check composition cannot be read: %s", tostring(fixture_err))
		step("composer_fixture", FAIL, "unreadable")
		done()
		return
	end
	step("composer_fixture", PASS)

	local snapshot = env.snapshot()
	if snapshot.record_error ~= nil then
		env.log("error", "The installed layouts cannot be read: %s", tostring(snapshot.record_error))
		step("composer_mode", FAIL, "record_unreadable")
		done()
		return
	end
	local existing = (snapshot.installed or {})[env.composer_id] ~= nil or snapshot.active == env.composer_id
		or env.exists(env.declaration_path)
	if existing then
		step("composer_mode", INFO, "existing")
		step("composer_install", SKIP, "kept")
		verify(nil)
		return
	end
	step("composer_mode", INFO, "fresh")
	fresh = true
	local answered = false
	local dispatched, dispatch_err = pcall(env.registry.composer_save,
		{ declaration = fixture.declaration, keylayout = fixture.keylayout, use = false },
		function(ok, code, _detail, _used, info)
			answered = true
			if not ok then
				env.log("error", "The check composition was not installed (%s).", tostring(code))
				step("composer_install", FAIL, code or "failed")
				cleanup()
				return
			end
			step("composer_install", PASS)
			verify(info)
		end, env.deps)
	if not dispatched and answered then error(dispatch_err, 0) end
	if not dispatched then
		env.log("error", "The check composition could not be installed: %s", tostring(dispatch_err))
		step("composer_install", FAIL, "refused")
		cleanup()
	end
end

return M
