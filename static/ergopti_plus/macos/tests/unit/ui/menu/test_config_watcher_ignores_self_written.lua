--- tests/unit/ui/menu/test_config_watcher_ignores_self_written.lua

--- ==============================================================================
--- MODULE: Config Watcher — Files The Driver Writes Itself
--- DESCRIPTION:
--- Two recursive pathwatchers cover the driver tree: infra/file_watchers' project
--- watcher and ui/menu/menu_watchers' config watcher. init.lua threads the
--- self-written file list into the first, so a file the driver rewrote is not
--- mistaken for a source edit. The second was armed without it.
---
--- WHY THAT MATTERS: config.toml is rewritten on EVERY persisted preference
--- change and the Karabiner config on every regenerate. Under a layout where the
--- config directory sits inside base_dir — the symlink and copy layouts — a menu
--- toggle therefore looked exactly like a source edit to this watcher and armed
--- a reload. The exclusion had been applied to one of two watchers on one tree,
--- which is the shape that makes it invisible: the protected watcher stays
--- quiet, so the reload looks like it came from somewhere else.
---
--- WHAT IS PINNED:
---   1. The filter drops a path in the self-written list.
---   2. It still reloads for a real source edit — an exclusion that swallowed
---      everything would pass (1) and break the feature.
---   3. init.lua actually passes the list. The filter can be perfect and do
---      nothing if the caller supplies no paths, which is exactly the state this
---      fixes.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================
-- ==========================================
-- ======= 1/ The filter ====================
-- ==========================================
-- ==========================================

helpers.describe("config watcher: a file the driver wrote is not a source edit", function()

	--- Arms the watcher with a controlled environment and returns a probe.
	--- @return table { changed = function(paths) -> boolean reloaded }
	local function armed_watcher()
		local Watchers = helpers.load_with_stubs("ui.menu.menu_watchers")
		local captured = nil
		-- The observable is the DEBOUNCE being armed, not the reload happening: a
		-- matched change arms hs.timer.doAfter and the reload only fires once the
		-- burst settles, so driving the callback and looking for a reload would
		-- report false for a match that was perfectly recognised.
		local armed_timers = 0
		local prev_after = hs.timer.doAfter
		hs.timer.doAfter = function(_delay, _fn)
			armed_timers = armed_timers + 1
			return { stop = function() end }
		end

		-- hs.pathwatcher.new hands the callback back rather than watching anything.
		local prev_pw = hs.pathwatcher
		hs.pathwatcher = {
			new = function(_dir, cb)
				captured = cb
				local watcher = {}
				function watcher:start() return self end
				function watcher:stop() return nil end
				return watcher
			end,
		}

		Watchers.start_config_watcher(
			"/tmp/base",
			function() end,
			function() return 0 end,          -- never suppressed
			{ defer_reload = function() end },
			{ "/tmp/base/cache" },
			{ "/tmp/base/config/config.toml", "/tmp/base/config/config_karabiner.toml" }
		)
		hs.pathwatcher = prev_pw

		return {
			--- Feeds a change and reports whether the watcher recognised it.
			--- @param paths table Absolute paths as the pathwatcher reports them.
			--- @return boolean True when the debounce was armed.
			changed = function(paths)
				local before = armed_timers
				if captured then captured(paths) end
				return armed_timers > before
			end,
			restore = function() hs.timer.doAfter = prev_after end,
			armed = captured ~= nil,
		}
	end

	helpers.it("arms and captures its callback", function()
		local w = armed_watcher()
		w.restore()
		helpers.assert_true(w.armed,
			"the watcher must arm — every assertion below drives its callback")
	end)

	helpers.it("ignores config.toml, which it rewrites on every preference toggle", function()
		local w = armed_watcher()
		local hit = w.changed({ "/tmp/base/config/config.toml" })
		w.restore()
		helpers.assert_true(not hit,
			"a write the driver made itself must not arm a reload — otherwise ticking a "
				.. "menu item reloads the driver")
	end)

	helpers.it("ignores the Karabiner config, rewritten on every regenerate", function()
		local w = armed_watcher()
		local hit = w.changed({ "/tmp/base/config/config_karabiner.toml" })
		w.restore()
		helpers.assert_true(not hit,
			"the Karabiner config is rewritten by the driver on every regenerate")
	end)

	helpers.it("still reloads for a real source edit", function()
		-- The half that keeps the exclusion honest. A filter that swallowed
		-- everything would pass the two tests above and silently disable the
		-- watcher.
		local w = armed_watcher()
		local hit = w.changed({ "/tmp/base/modules/keymap/init.lua" })
		w.restore()
		helpers.assert_true(hit,
			"a genuine .lua source change must still arm the reload — an exclusion that "
				.. "drops everything is not a fix, it is a disabled watcher")
	end)

end)





-- ==========================================
-- ==========================================
-- ======= 2/ The caller supplies it ========
-- ==========================================
-- ==========================================

helpers.describe("config watcher: init.lua supplies the self-written list", function()

	helpers.it("passes the same two paths infra/file_watchers is given", function()
		-- The filter can be perfect and do nothing if the caller passes no paths,
		-- which is exactly the state this fixed: the parameter did not exist.
		local src = helpers.read_driver_source("local function reset_menubar")
		helpers.assert_true(src ~= nil, "ui/menu/init.lua source must be locatable")

		local at = src:find("MenuWatchers.start_config_watcher", 1, true)
		helpers.assert_true(at ~= nil, "ui/menu/init.lua must arm the config watcher")
		local call = src:sub(at, at + 1400)
		helpers.assert_true(call:find('MenuPaths.get("ConfigTomlPath")', 1, true) ~= nil,
			"the config watcher must be told about config.toml — the file it rewrites on "
				.. "every persisted preference change")
		helpers.assert_true(call:find('MenuPaths.get("KarabinerConfigPath")', 1, true) ~= nil,
			"and about the Karabiner config, rewritten on every regenerate")
	end)

end)
