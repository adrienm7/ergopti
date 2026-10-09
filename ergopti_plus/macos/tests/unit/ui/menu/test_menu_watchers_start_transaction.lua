--- tests/unit/ui/menu/test_menu_watchers_start_transaction.lua

--- ==============================================================================
--- MODULE: Menu Watcher Startup Transaction Regressions
--- DESCRIPTION:
--- Exercises the config and theme watcher activation boundaries with stateful
--- native doubles. Both Hammerspoon start methods commit by returning the exact
--- candidate; callbacks must remain fenced until that identity is observed.
---
--- FEATURES & RATIONALE:
--- 1. Exact Acquisition: A false start result is refusal, not a live watcher.
--- 2. Partial Activation: A start that activates then raises is rolled back.
--- 3. Callback Admission: Work delivered before exact commit remains inert.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =====================================
-- =====================================
-- ======= 1/ Isolated Fixture =========
-- =====================================
-- =====================================

--- Runs one scenario with fresh native watcher doubles.
--- @param options table Fault-injection options.
--- @param scenario function Scenario receiving the module and runtime state.
local function with_fixture(options, scenario)
	local saved_module = package.loaded["ui.menu.menu_watchers"]
	local saved_pathwatcher = hs.pathwatcher
	local saved_distributed = hs.distributednotifications
	local runtime = {
		config_callbacks = 0,
		config_stops = 0,
		theme_callbacks = 0,
		theme_stops = 0,
	}

	hs.pathwatcher = {
		new = function(_path, callback)
			local watcher = {}
			function watcher:start()
				if options.config_callback_during_start then
					callback({ "/fake/base/modules/change.lua" })
				end
				if options.config_start == "throw" then error("config start refused") end
				if options.config_start == "false" then return false end
				return self
			end
			function watcher:stop()
				runtime.config_stops = runtime.config_stops + 1
				if options.config_stop == "throw" then error("config stop refused") end
				if options.config_stop == "false" then return false end
				if options.config_stop == "false-once" and runtime.config_stops == 1 then return false end
				return nil
			end
			return watcher
		end,
	}

	hs.distributednotifications = {
		new = function(callback)
			local watcher = {}
			function watcher:start()
				if options.theme_callback_during_start then
					callback("AppleInterfaceThemeChangedNotification")
				end
				if options.theme_start == "throw" then error("theme start refused") end
				if options.theme_start == "false" then return false end
				return self
			end
			function watcher:stop()
				runtime.theme_stops = runtime.theme_stops + 1
				if options.theme_stop == "throw" then error("theme stop refused") end
				if options.theme_stop == "false" then return false end
				return self
			end
			return watcher
		end,
	}

	package.loaded["ui.menu.menu_watchers"] = nil
	local ok, err = xpcall(function()
		local MenuWatchers = require("ui.menu.menu_watchers")
		scenario(MenuWatchers, runtime)
	end, debug.traceback)

	package.loaded["ui.menu.menu_watchers"] = saved_module
	hs.pathwatcher = saved_pathwatcher
	hs.distributednotifications = saved_distributed
	if not ok then error(err, 0) end
end

local function start_config(MenuWatchers, runtime)
	return MenuWatchers.start_config_watcher(
		"/fake/base/",
		function() runtime.config_callbacks = runtime.config_callbacks + 1; return true end,
		function() return 0 end,
		{ defer_reload = function(callback) return callback() end }
	)
end





-- ========================================
-- ========================================
-- ======= 2/ Startup Refusal Cases =======
-- ========================================
-- ========================================

helpers.describe("menu watchers publish only exact native start commits", function()
	helpers.it("rolls back a refused config watcher instead of publishing it", function()
		with_fixture({ config_start = "false" }, function(MenuWatchers, runtime)
			local owner = start_config(MenuWatchers, runtime)
			helpers.assert_nil(owner,
				"a false pathwatcher start result must not publish a live owner")
			helpers.assert_eq(runtime.config_stops, 1,
				"the exact refused candidate must be rolled back")
			helpers.assert_eq(runtime.config_callbacks, 0)
		end)
	end)

	helpers.it("fences and rolls back a theme watcher that activates then throws", function()
		with_fixture({
			theme_callback_during_start = true,
			theme_start = "throw",
		}, function(MenuWatchers, runtime)
			local owner = MenuWatchers.start_theme_watcher(function()
				runtime.theme_callbacks = runtime.theme_callbacks + 1
			end)
			helpers.assert_nil(owner,
				"a throwing theme watcher start must not publish a live owner")
			helpers.assert_eq(runtime.theme_stops, 1,
				"the partially activated theme watcher must be rolled back")
			helpers.assert_eq(runtime.theme_callbacks, 0,
				"callbacks delivered before exact start commit must remain fenced")
		end)
	end)

	helpers.it("retains a partially activated config watcher until rollback retry", function()
		with_fixture({
			config_callback_during_start = true,
			config_start = "throw",
			config_stop = "false-once",
		}, function(MenuWatchers, runtime)
			local owner = start_config(MenuWatchers, runtime)
			helpers.assert_true(type(owner) == "table",
				"failed rollback must publish a cleanup owner for the exact candidate")
			helpers.assert_eq(runtime.config_stops, 1)
			helpers.assert_eq(runtime.config_callbacks, 0,
				"the uncertain native watcher must remain logically fenced")
			helpers.assert_eq(owner:stop(), true,
				"a retry must settle the retained candidate")
			helpers.assert_eq(runtime.config_stops, 2,
				"cleanup must retry the same candidate exactly once")
		end)
	end)
end)
