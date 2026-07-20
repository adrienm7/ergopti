--- tests/unit/ui/test_menu_paths_ensure_dir_memoised.lua

--- ==============================================================================
--- MODULE: Menu Paths — ensure_dir Memoisation (regression)
--- DESCRIPTION:
--- Locks down that resolving a driver-subdir path does not re-create the
--- directory on every call.
---
--- ROOT CAUSE ENCODED — A SUBPROCESS ON THE TYPING RUN LOOP:
--- ensure_dir() unconditionally ran ``pcall(hs.execute, "mkdir -p %q")``. Every
--- save_prefs() resolves MenuPaths.get("ConfigTomlPath"), which routes through
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

--- Loads menu_paths with both directory-creation mechanisms replaced by counters.
--- @param dirs_exist boolean When true, attributes() reports every path as an
---        existing directory — the real steady state after the first boot.
--- @return table menu_paths, table counters
local function load_menu_paths(dirs_exist)
	local counters = { shell = 0, mkdir = 0 }
	local fs_stub = {
		mkdir      = function() counters.mkdir = counters.mkdir + 1 ; return true end,
		attributes = function()
			if dirs_exist then return { mode = "directory" } end
			return nil
		end,
		dir        = function() return function() return nil end end,
	}
	local menu_paths = helpers.load_with_stubs("ui.menu.menu_paths", {
		fs      = fs_stub,
		execute = function() counters.shell = counters.shell + 1 ; return "", true end,
	})
	return menu_paths, counters
end

--- Total directory-creation attempts observed so far, by either mechanism.
--- @param counters table The counter table from load_menu_paths.
--- @return integer
local function creations(counters)
	return counters.shell + counters.mkdir
end





-- ===============================================
-- ===============================================
-- ======= 2/ Repeated Resolution Is Cheap =======
-- ===============================================
-- ===============================================

helpers.describe("menu_paths does not re-create the driver subdir on every call", function()
	helpers.it("performs zero further creation work after the first resolution", function()
		local menu_paths, counters = load_menu_paths(false)

		local first = menu_paths.get(DRIVER_SUBDIR_KEY)
		helpers.assert_type(first, "string")
		local after_first = creations(counters)

		for _ = 2, RESOLUTION_COUNT do
			helpers.assert_eq(menu_paths.get(DRIVER_SUBDIR_KEY), first,
				"the resolved path must be stable across calls")
		end

		helpers.assert_eq(creations(counters) - after_first, 0,
			"repeated resolutions must do NO directory work — this ran on every menu "
			.. "toggle, on the run loop that services the typing event tap")
	end)

	helpers.it("touches the filesystem at most once when the directory already exists", function()
		-- The real steady state: everything is present from the first boot onwards.
		local menu_paths, counters = load_menu_paths(true)
		for _ = 1, RESOLUTION_COUNT do menu_paths.get(DRIVER_SUBDIR_KEY) end
		helpers.assert_true(creations(counters) <= 1,
			"an existing directory needs no creation call at all, and certainly not "
			.. "one per resolution — observed " .. tostring(creations(counters)))
	end)

	helpers.it("never forks a shell when the filesystem API is available", function()
		local menu_paths, counters = load_menu_paths(false)
		for _ = 1, RESOLUTION_COUNT do menu_paths.get(DRIVER_SUBDIR_KEY) end
		helpers.assert_eq(counters.shell, 0,
			"hs.fs.mkdir handles this in-process; forking /bin/sh on the typing run "
			.. "loop is exactly what this fix removed")
	end)

	-- The memo must not be so eager that a genuinely new directory is skipped:
	-- distinct paths are distinct cache keys.
	helpers.it("still creates a directory it has not seen before", function()
		local menu_paths, counters = load_menu_paths(false)
		menu_paths.get(DRIVER_SUBDIR_KEY)
		local after_first = creations(counters)
		-- PersonalHotstringsDir resolves a DIFFERENT subdirectory (hotstrings/).
		menu_paths.get("PersonalHotstringsDir")
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

helpers.describe("menu_paths falls back to the shell when hs.fs.mkdir is absent", function()
	helpers.it("uses hs.execute once, and only once, without the filesystem API", function()
		local counters = { shell = 0 }
		local menu_paths = helpers.load_with_stubs("ui.menu.menu_paths", {
			-- No mkdir field: emulates a host where the filesystem API is unavailable.
			fs      = { attributes = function() return nil end,
			            dir        = function() return function() return nil end end },
			execute = function() counters.shell = counters.shell + 1 ; return "", true end,
		})

		for _ = 1, RESOLUTION_COUNT do menu_paths.get(DRIVER_SUBDIR_KEY) end

		helpers.assert_eq(counters.shell, 1,
			"the shell fallback must still create the directory, but the memo must "
			.. "keep it to a single fork")
	end)
end)
