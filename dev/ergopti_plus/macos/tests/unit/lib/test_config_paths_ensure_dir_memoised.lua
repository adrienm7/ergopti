--- tests/unit/lib/test_config_paths_ensure_dir_memoised.lua

--- ==============================================================================
--- MODULE: Config Paths — ensure_dir Memoisation (regression)
--- DESCRIPTION:
--- Locks down that resolving a driver-subdir path does not re-create the
--- directory on every call.
---
--- ROOT CAUSE ENCODED — A SUBPROCESS ON THE TYPING RUN LOOP:
--- ensure_dir() unconditionally ran ``pcall(hs.execute, "mkdir -p %q")``. Every
--- save_prefs() resolves ConfigPaths.get("ConfigTomlPath"), which routes through
--- file_in_driver_subdir → ensure_dir — so EVERY menu toggle forked /bin/sh for a
--- directory that exists from the first boot onwards, on the same run loop that
--- services the typing event tap.
---
--- The load-bearing assertion is that REPEATED resolutions perform NO further
--- directory creation, not that any particular filesystem API is used. Counting
--- the delta after the first resolution keeps the guard honest regardless of how
--- many missing ancestors that first call legitimately had to build.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Three resolutions stand in for "the user toggled three menu items".
local RESOLUTION_COUNT = 3

-- Any key that routes through file_in_driver_subdir; this is the one save_prefs
-- resolves on every single preference write.
local DRIVER_SUBDIR_KEY = "ConfigTomlPath"





-- ==============================================
-- ==============================================
-- ======= 1/ Counting Filesystem Doubles =======
-- ==============================================
-- ==============================================

--- Loads config_paths with both directory-creation mechanisms replaced by counters.
--- @param dirs_exist boolean When true, attributes() reports every path as an
---        existing directory — the real steady state after the first boot.
--- @return table config_paths, table counters
local function load_config_paths(dirs_exist)
	local counters = { shell = 0, mkdir = 0 }
	-- STATEFUL, because the real filesystem is: once a create succeeds the path
	-- exists and attributes() starts reporting it. A stub that kept answering
	-- "missing" after a successful mkdir would require the memo to cache a create
	-- that never happened — which is exactly the defect the sibling assertions here
	-- forbid, so the stub has to model the success it claims to return.
	local made = {}
	local fs_stub = {
		mkdir      = function(path)
			counters.mkdir = counters.mkdir + 1
			made[tostring(path)] = true
			return true
		end,
		attributes = function(path)
			if dirs_exist then return { mode = "directory" } end
			if made[tostring(path)] then return { mode = "directory" } end
			return nil
		end,
		dir        = function() return function() return nil end end,
	}
	local config_paths = helpers.load_with_stubs("infra.config_paths", {
		fs      = fs_stub,
		execute = function(cmd)
			counters.shell = counters.shell + 1
			-- `mkdir -p %q` — mark the quoted path as created, like the real shell would.
			local target = tostring(cmd):match('mkdir %-p "(.-)"')
			if target then made[target] = true end
			return "", true
		end,
	})
	return config_paths, counters
end

--- Total directory-creation attempts observed so far, by either mechanism.
--- @param counters table The counter table from load_config_paths.
--- @return integer
local function creations(counters)
	return counters.shell + counters.mkdir
end





-- ===============================================
-- ===============================================
-- ======= 2/ Repeated Resolution Is Cheap =======
-- ===============================================
-- ===============================================

helpers.describe("config_paths does not re-create the driver subdir on every call", function()
	helpers.it("performs zero further creation work after the first resolution", function()
		local config_paths, counters = load_config_paths(false)

		local first = config_paths.get(DRIVER_SUBDIR_KEY)
		helpers.assert_type(first, "string")
		local after_first = creations(counters)

		for _ = 2, RESOLUTION_COUNT do
			helpers.assert_eq(config_paths.get(DRIVER_SUBDIR_KEY), first,
				"the resolved path must be stable across calls")
		end

		helpers.assert_eq(creations(counters) - after_first, 0,
			"repeated resolutions must do NO directory work — this ran on every menu "
			.. "toggle, on the run loop that services the typing event tap")
	end)

	helpers.it("touches the filesystem at most once when the directory already exists", function()
		-- The real steady state: everything is present from the first boot onwards.
		local config_paths, counters = load_config_paths(true)
		for _ = 1, RESOLUTION_COUNT do config_paths.get(DRIVER_SUBDIR_KEY) end
		helpers.assert_true(creations(counters) <= 1,
			"an existing directory needs no creation call at all, and certainly not "
			.. "one per resolution — observed " .. tostring(creations(counters)))
	end)

	helpers.it("never forks a shell when the filesystem API is available", function()
		local config_paths, counters = load_config_paths(false)
		for _ = 1, RESOLUTION_COUNT do config_paths.get(DRIVER_SUBDIR_KEY) end
		helpers.assert_eq(counters.shell, 0,
			"hs.fs.mkdir handles this in-process; forking /bin/sh on the typing run "
			.. "loop is exactly what this fix removed")
	end)

	-- The memo must not be so eager that a genuinely new directory is skipped:
	-- distinct paths are distinct cache keys.
	helpers.it("still creates a directory it has not seen before", function()
		local config_paths, counters = load_config_paths(false)
		config_paths.get(DRIVER_SUBDIR_KEY)
		local after_first = creations(counters)
		-- PersonalHotstringsDir resolves a DIFFERENT subdirectory (hotstrings/).
		config_paths.get("PersonalHotstringsDir")
		helpers.assert_true(creations(counters) > after_first,
			"a previously unseen directory must still be created — the memo is keyed "
			.. "per path, not a global 'already ran once' flag")
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 3/ The Shell Fallback Still Exists =======
-- ==================================================
-- ==================================================

helpers.describe("config_paths falls back to the shell when hs.fs.mkdir is absent", function()
	helpers.it("uses hs.execute once, and only once, without the filesystem API", function()
		local counters = { shell = 0 }
		-- The stub is STATEFUL: a real `mkdir -p` makes the directory exist, so
		-- attributes() must start reporting it afterwards. A stub that reported the
		-- path as missing forever would demand that a FAILED create be memoised —
		-- which is the defect this suite's sibling case now forbids.
		local created = false
		local config_paths = helpers.load_with_stubs("infra.config_paths", {
			-- No mkdir field: emulates a host where the filesystem API is unavailable.
			fs      = { attributes = function() return created and {} or nil end,
			            dir        = function() return function() return nil end end },
			execute = function()
				counters.shell = counters.shell + 1
				created = true
				return "", true
			end,
		})

		for _ = 1, RESOLUTION_COUNT do config_paths.get(DRIVER_SUBDIR_KEY) end

		helpers.assert_eq(counters.shell, 1,
			"the shell fallback must still create the directory, but the memo must "
			.. "keep it to a single fork")
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 4/ A Refused Create Is Never Memoised =======
-- =====================================================
-- =====================================================

helpers.describe("config_paths retries a directory it could not create", function()
	helpers.it("does not memoise a path whose creation was refused", function()
		-- hs.fs.mkdir follows LuaFileSystem semantics: it RETURNS nil plus an error
		-- and never raises, so reading the pcall STATUS reported success for a create
		-- that never happened. The path was then memoised as ensured, and every later
		-- resolution skipped it — leaving the config directory missing for the whole
		-- session while every save silently no-opped.
		--
		-- Refusal is usually transient (volume still mounting, TCC not yet granted),
		-- so the correct behaviour is to keep trying rather than to remember failure.
		local attempts = 0
		local config_paths = helpers.load_with_stubs("infra.config_paths", {
			fs = {
				-- Refuses every create the way the real API does: nil + message.
				mkdir      = function() attempts = attempts + 1 ; return nil, "permission denied" end,
				attributes = function() return nil end,
				dir        = function() return function() return nil end end,
			},
			execute = function() return "", true end,
		})

		config_paths.get(DRIVER_SUBDIR_KEY)
		local after_first = attempts
		config_paths.get(DRIVER_SUBDIR_KEY)

		helpers.assert_true(attempts > after_first,
			"a refused create must NOT be memoised — remembering it skips every later "
			.. "attempt, so a directory that was merely unavailable for a moment stays "
			.. "missing for the rest of the session")
	end)
end)
