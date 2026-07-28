--- tests/unit/lib/test_file_watchers_ignore_self_writes.lua

--- ==============================================================================
--- MODULE: Regression — the driver's own config writes must not reload it
---         (file-watchers-self-trigger)
--- DESCRIPTION:
--- Every menu toggle reloaded the whole driver half a second later.
---
--- ROOT CAUSE ENCODED: `hotstrings_dir` falls back to the bundled directory only
--- when the config root holds NO ordinary .toml — and the real tree holds
--- wrap_symbols.toml, so it stays the config ROOT. hs.pathwatcher is recursive,
--- so that one watcher also covers hammerspoon/config.toml, and the callback
--- matched every `*.toml`. save_prefs — which every single menu toggle calls —
--- therefore looked exactly like a user hand-editing a hotstring file, and the
--- settle timer reloaded the session it had just been asked to change.
--- config_karabiner.toml is the same story on every layout change.
---
--- WHY IT WAS SILENT: a reload looks like the driver working. The notification
--- says the config changed, which is true; nothing indicates the change was our
--- own write, or that toggling one checkbox tore down and rebuilt every
--- subsystem.
---
--- The exclusion is by resolved PATH, handed in by the boot script from
--- menu_paths, so the watcher cannot disagree with the writers about where these
--- files live.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.ui_restore"] = {
	defer_reload = function(fn) if type(fn) == "function" then fn() end end,
	snapshot     = function() end,
	restore      = function() end,
}
-- git idle throughout: isolate self-write filtering from the git gate.
package.loaded["lib.git_status"] = { operation_in_progress = function() return false end }

package.loaded["lib.file_watchers"] = nil
local FW = require("lib.file_watchers")

local CONFIG_ROOT   = "/fake/config/"
local CONFIG_TOML   = CONFIG_ROOT .. "hammerspoon/config.toml"
local KARABINER_TOML = CONFIG_ROOT .. "hammerspoon/config_karabiner.toml"
local HOTSTRING_TOML = CONFIG_ROOT .. "francais.toml"

--- Arms the watchers against a fake config root and returns a driver for them.
--- @return table { fire = function(path), scheduled = function(), reloads = function(), restore = function() }
local function arm_watchers()
	local prev_pw, prev_timer, prev_attr, prev_reload =
		hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload

	local clock       = 0
	local watch_cbs   = {}
	local captured_fn = nil
	local reloads     = 0

	hs.pathwatcher = { new = function(_path, cb)
		watch_cbs[#watch_cbs + 1] = cb
		return { start = function() end }
	end }
	hs.timer = {
		doAfter = function(_s, fn) captured_fn = fn; return { stop = function() end } end,
		secondsSinceEpoch = function() return clock end,
	}
	hs.fs.attributes = function(_p) return nil end
	hs.reload = function() reloads = reloads + 1 end

	_G.script_watchers = nil
	FW.start({
		hotstrings_dir          = CONFIG_ROOT,
		base_dir                = "/fake/base/",
		personal_hotstrings_dir = "/fake/personal",
		self_written_files      = { CONFIG_TOML, KARABINER_TOML },
	})

	-- Past the post-boot FSEvents-replay suppression window, so a dropped event
	-- below is attributable to the self-write filter and not to that guard.
	clock = 30

	return {
		fire = function(path)
			captured_fn = nil
			for _, cb in ipairs(watch_cbs) do pcall(cb, { path }) end
		end,
		scheduled = function() return captured_fn end,
		settle    = function()
			clock = clock + 10
			if captured_fn then captured_fn() end
		end,
		reloads = function() return reloads end,
		restore = function()
			hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload =
				prev_pw, prev_timer, prev_attr, prev_reload
			_G.script_watchers = nil
		end,
	}
end




-- ================================================================
-- ================================================================
-- ======= 1/ Our own writes are not external changes =============
-- ================================================================
-- ================================================================

helpers.describe("file_watchers: a write the session made itself does not reload it", function()
	helpers.it("ignores config.toml, which every menu toggle rewrites", function()
		local w = arm_watchers()

		w.fire(CONFIG_TOML)

		helpers.assert_true(w.scheduled() == nil,
			"save_prefs writes config.toml on every menu toggle. Treating that as an external "
				.. "edit reloads the entire driver half a second after the user flips a checkbox — "
				.. "tearing down and rebuilding every subsystem to apply a change already applied")
		helpers.assert_eq(w.reloads(), 0, "and must not reload")

		w.restore()
	end)

	helpers.it("ignores config_karabiner.toml, regenerated on every layout change", function()
		local w = arm_watchers()

		w.fire(KARABINER_TOML)

		helpers.assert_true(w.scheduled() == nil,
			"the driver regenerates config_karabiner.toml itself whenever the layout changes — "
				.. "the same self-trigger, on a file written far more often")
		helpers.assert_eq(w.reloads(), 0, "and must not reload")

		w.restore()
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 2/ Real hotstring edits still reload ===================
-- ================================================================
-- ================================================================

helpers.describe("file_watchers: a genuine hotstring edit still reloads", function()
	helpers.it("reloads on an ordinary .toml in the same directory", function()
		local w = arm_watchers()

		w.fire(HOTSTRING_TOML)

		helpers.assert_true(type(w.scheduled()) == "function",
			"a hotstring file edited by the user must still schedule a reload. The two config "
				.. "files sit in the SAME watched tree, so an exclusion that swallowed the whole "
				.. "directory would silence the auto-reload this module exists for")

		w.settle()
		helpers.assert_eq(w.reloads(), 1, "and must reload exactly once")

		w.restore()
	end)
end)

-- Restore the real modules for later test files: the stubs above would
-- otherwise leak through package.loaded into whichever module loads next.
package.loaded["lib.ui_restore"] = nil
package.loaded["lib.git_status"] = nil
package.loaded["lib.file_watchers"] = nil
