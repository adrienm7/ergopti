--- tests/unit/modules/karabiner/test_ke_ownership_needs_a_launch.lua

--- ==============================================================================
--- MODULE: Regression — owning the KE bridge requires having LAUNCHED it
--- DESCRIPTION:
--- Two markers, two very different meanings. The SESSION marker records "remapping
--- is applied in this boot session" and is the honest source for the menu's green
--- indicator. The OWNER marker records "Hammerspoon started this bridge", and it
--- is what authorises the driver to tear the bridge down — at quit, and when the
--- Karabiner integration is disabled.
---
--- `is_remapping_active()` is a read-only status probe. Its lazy-recovery branch
--- wrote BOTH markers, so merely LOOKING at a healthy bridge claimed it. Opening
--- the Karabiner submenu once, with the integration disabled and the user's own
--- Karabiner-Elements running, was enough: from then on the driver believed it
--- owned that bridge and would boot out their launchd agents.
---
--- ROOT CAUSE ENCODED:
--- Ownership derived from OBSERVATION instead of from ACTION. The already-correct
--- short-circuit on the non-forced prime path writes only the session marker for
--- exactly this reason; the lazy branch was the sibling that never got compared
--- against it. The assertions below are on which marker FILE gets written, not on
--- which helper is called, so any restructuring that keeps the distinction passes.
---
--- The paired half is the poll-timeout path, which used to clear the owner marker
--- when the bridge failed to appear in time. That disowns a bridge Hammerspoon
--- really did launch and that may simply have been slow, and a disowned bridge is
--- never torn down — the post-quit-remapping class recorded in PROJECT_MEMORY.
--- Removing the lazy claim without fixing that would have reopened it, so both
--- live in one change.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNER_MARKER   = "ergopti_ke_hs_owner_v1"
local SESSION_MARKER = "ergopti_ke_prime"

-- Any fixed value works; it only has to be the SAME one the fake boot-timestamp
-- source and the fake session marker return, or "primed" is unreachable.
local BOOT_TS = "1234567890"

-- Shape of `sysctl -n kern.boottime` output: get_boot_timestamp matches
-- "sec = (%d+)" out of it, so the stub has to answer in that shape.
local BOOT_STDOUT = "{ sec = " .. BOOT_TS .. ", usec = 0 } Mon Jan  1 00:00:00 2024"


--- Loads a fresh ke_lifecycle. io.open is left alone here: several modules read
--- files at require-time, and overriding it during load breaks the load itself.
--- @return table KE
local function fresh_ke()
	package.loaded["modules.karabiner.ke_lifecycle"] = nil
	package.loaded["lib.logger"] = nil
	_ = helpers.load_with_stubs("lib.logger")
	package.loaded["lib.i18n"] = { get = function(k) return k end }
	package.loaded["lib.notifications"] = { notify = function() end }
	return helpers.load_with_stubs("modules.karabiner.ke_lifecycle")
end


--- Runs `fn` with io.open and os.remove instrumented, and returns what it touched.
--- @param opts table Fields: session_primed boolean, owner_present boolean.
--- @param fn function The call under test.
--- @return table log {writes = {…}, removes = {…}}
local function with_marker_io(opts, fn)
	local log = { writes = {}, removes = {} }
	local real_open, real_remove = io.open, os.remove

	io.open = function(path, mode)
		local p = tostring(path)
		if mode == "w" or mode == "wb" then
			table.insert(log.writes, p)
			return { write = function() end, close = function() end }
		end
		if p:find(SESSION_MARKER, 1, true) then
			if not opts.session_primed then return nil end
			return { read = function() return BOOT_TS end, close = function() end }
		end
		if p:find(OWNER_MARKER, 1, true) then
			if not opts.owner_present then return nil end
			return { read = function() return BOOT_TS end, close = function() end }
		end
		-- Everything else — the boot-timestamp source, binary existence probes —
		-- reads as present, returning the same timestamp so the comparison inside
		-- is_session_primed() is consistent.
		return {
			read  = function() return BOOT_TS end,
			close = function() end,
			lines = function() return function() return nil end end,
		}
	end
	os.remove = function(path)
		table.insert(log.removes, tostring(path))
		return true
	end

	local ok, err = pcall(fn)
	io.open, os.remove = real_open, real_remove
	helpers.assert_true(ok, "the call under test must not raise: " .. tostring(err))
	return log
end


--- @param paths table
--- @param needle string
--- @return boolean
local function any_path(paths, needle)
	for _, p in ipairs(paths) do
		if p:find(needle, 1, true) then return true end
	end
	return false
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ A status probe must not claim ownership ===============
-- ==================================================================
-- ==================================================================

helpers.describe("KE ownership: a read-only status probe never claims the bridge", function()

	helpers.it("is_remapping_active writes the session marker but NOT the owner marker", function()
		local KE = fresh_ke()

		-- Everything a healthy FOREIGN bridge looks like: the grabber answers, this
		-- boot has not been primed by us, and the runtime probe succeeds.
		-- The boot timestamp is parsed out of `sysctl -n kern.boottime`, and BOTH
		-- markers are keyed on it. A stub returning empty stdout makes
		-- get_boot_timestamp nil, which silently suppresses every marker write and
		-- would have made the assertion below pass against a driver that claims
		-- ownership loudly. The paired case in this file is what caught that.
		_G.hs.execute = function() return BOOT_STDOUT, true, "exit", 0 end
		_G.hs.timer.secondsSinceEpoch = function() return 10000 end

		local log = with_marker_io({ session_primed = false, owner_present = false },
			function() KE.is_remapping_active() end)

		helpers.assert_true(not any_path(log.writes, OWNER_MARKER),
			"the owner marker authorises tearing the bridge down, and this function only "
			.. "LOOKED at it. Writing it here means opening the Karabiner submenu once, with "
			.. "the integration disabled and the user's own Karabiner-Elements running, makes "
			.. "the driver believe it owns their bridge and boot out their launchd agents. "
			.. "Writes seen: " .. table.concat(log.writes, ", "))
	end)

	helpers.it("and it still records that remapping is applied", function()
		local KE = fresh_ke()
		-- The boot timestamp is parsed out of `sysctl -n kern.boottime`, and BOTH
		-- markers are keyed on it. A stub returning empty stdout makes
		-- get_boot_timestamp nil, which silently suppresses every marker write and
		-- would have made the assertion below pass against a driver that claims
		-- ownership loudly. The paired case in this file is what caught that.
		_G.hs.execute = function() return BOOT_STDOUT, true, "exit", 0 end
		_G.hs.timer.secondsSinceEpoch = function() return 10000 end

		local log = with_marker_io({ session_primed = false, owner_present = false },
			function() KE.is_remapping_active() end)

		-- Without this case the assertion above would pass against a lazy branch
		-- deleted outright, which would leave the menu indicator stuck on "not
		-- primed" after any polling timeout — the exact recovery it exists for.
		helpers.assert_true(any_path(log.writes, SESSION_MARKER),
			"the session marker is the honest signal for the menu indicator and must still "
			.. "be written; writes seen: " .. table.concat(log.writes, ", "))
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ Every kill is gated on ownership ======================
-- ==================================================================
-- ==================================================================

helpers.describe("KE ownership: no kill fires on a bridge we do not own", function()

	helpers.it("every KILL command in the lifecycle is ownership-gated", function()
		-- The settle path's extra pkill was the one kill in this driver with no
		-- ownership check, while set_enabled(false) and M.kill() both have one. A
		-- forced prime that found a live bridge it had never started therefore killed
		-- the user's own Karabiner-Elements session - and launchd's KeepAlive respawns
		-- a bare pkill moments later, so the visible effect was their setup flapping.
		local src = helpers.read_driver_source("KARABINER_KILL_FAST_CMD")
		helpers.assert_true(src ~= nil and src ~= "",
			"ke_lifecycle must be locatable by its kill constant")
		local code = src:gsub("%-%-[^\n]*", "")

		local offenders = {}
		local from = 1
		while true do
			local at = code:find("hs.execute(KARABINER_KILL_FAST_CMD)", from, true)
			if not at then break end
			-- The gate must be in the enclosing branch, not merely somewhere in the file.
			local before = code:sub(math.max(1, at - 260), at)
			if not before:find("is_hs_owned_bridge", 1, true) then
				local line_no = select(2, code:sub(1, at):gsub("\n", "")) + 1
				table.insert(offenders, tostring(line_no))
			end
			from = at + 1
		end

		helpers.assert_eq(#offenders, 0,
			"a kill that is not gated on ownership boots out a user-managed Karabiner "
			.. "setup, which is the regression the ownership marker exists to prevent. "
			.. "Ungated kill(s) at line(s): " .. table.concat(offenders, ", "))
	end)

	helpers.it("the kill is still reachable when we do own the bridge", function()
		-- Without this case the assertion above would pass against a change that
		-- deleted the kill outright, which would leave a stuck bridge un-recoverable.
		local code = helpers.read_driver_source("KARABINER_KILL_FAST_CMD"):gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("hs.execute(KARABINER_KILL_FAST_CMD)", 1, true) ~= nil,
			"the fast kill must still exist for the bridge Hammerspoon did start")
	end)

end)
