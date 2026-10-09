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
local Fixture = require("tests.support.menu_config_watcher_fixture")





-- ==========================================
-- ==========================================
-- ======= 1/ The filter ====================
-- ==========================================
-- ==========================================

helpers.describe("config watcher: a file the driver wrote is not a source edit", function()

	--- Runs one self-write filter scenario with isolated native state.
	--- @param body function Scenario receiving event and timer observations.
	local function with_watcher(body)
		Fixture.with_watcher(function(w)
			return body({
				armed = w.callback() ~= nil,
				changed = function(paths)
					local before = w.armed_count()
					w.fire(paths)
					return w.armed_count() > before
				end,
			})
		end, {
			base_dir = "/tmp/base",
			ignored_dirs = { "/tmp/base/cache" },
			self_written_files = { "/tmp/base/config/config.toml", "/tmp/base/config/config_karabiner.toml" },
		})
	end

	helpers.it("arms and captures its callback", function()
		with_watcher(function(w)
			helpers.assert_true(w.armed,
				"the watcher must arm — every assertion below drives its callback")
		end)
	end)

	helpers.it("ignores config.toml, which it rewrites on every preference toggle", function()
		with_watcher(function(w)
			local hit = w.changed({ "/tmp/base/config/config.toml" })
			helpers.assert_true(not hit,
				"a write the driver made itself must not arm a reload — otherwise ticking a "
					.. "menu item reloads the driver")
		end)
	end)

	helpers.it("ignores the Karabiner config, rewritten on every regenerate", function()
		with_watcher(function(w)
			local hit = w.changed({ "/tmp/base/config/config_karabiner.toml" })
			helpers.assert_true(not hit,
				"the Karabiner config is rewritten by the driver on every regenerate")
		end)
	end)

	helpers.it("still reloads for a real source edit", function()
		-- The half that keeps the exclusion honest. A filter that swallowed
		-- everything would pass the two tests above and silently disable the
		-- watcher.
		with_watcher(function(w)
			local hit = w.changed({ "/tmp/base/modules/keymap/init.lua" })
			helpers.assert_true(hit,
				"a genuine .lua source change must still arm the reload — an exclusion that "
					.. "drops everything is not a fix, it is a disabled watcher")
		end)
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
