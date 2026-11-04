--- tests/unit/platform/remap/runtime_approval_watch/test_runtime_approval_watch.lua

--- ==============================================================================
--- MODULE: Owned Runtime Driver Approval Watch
--- DESCRIPTION:
--- Pins platform/remap/runtime_approval_watch.lua with fake ports: one watch
--- per launch opens the exact System Settings pane, polls the extension
--- listing and reloads as soon as the pinned driver is active.
---
--- ROOT CAUSE ENCODED: after the first install the driver waited for the
--- user's approval and the tap-holds stayed off until a manual restart (WP8).
--- ==============================================================================

local helpers = require("tests.helpers")

local function line(state)
	return "1 extension(s)\n--- com.apple.system_extension.driver_extension\n"
		.. "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n"
		.. "*\t*\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (8.5.0/8.5.0)\t"
		.. "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice\t[" .. state .. "]\n"
end

local function fake(listings)
	package.loaded["platform.remap.runtime_approval_watch"] = nil
	local Watch = require("platform.remap.runtime_approval_watch")
	local world = { opened = {}, reloads = 0, looks = 0, pending = nil }
	local watch = Watch.new({
		listing = function(callback)
			world.looks = world.looks + 1
			callback(listings[math.min(world.looks, #listings)])
		end,
		after = function(_, fn) world.pending = fn; return "handle", true end,
		cancel = function() end,
		open_settings = function(url) world.opened[#world.opened + 1] = url end,
		reload = function() world.reloads = world.reloads + 1 end,
		version = function() return "8.5.0" end,
	})
	return watch, world, Watch
end

helpers.describe("owned runtime driver approval watch", function()
	helpers.it("opens the extension pane once and reloads when the driver is allowed", function()
		local watch, world = fake({ line("activated waiting for user"), line("activated enabled") })
		helpers.assert_eq(watch.start(), true)
		helpers.assert_eq(world.opened, { require("platform.remap.ke_paths").EXTENSIONS_SETTINGS_URL })
		helpers.assert_eq(world.reloads, 0, "no reload while macOS still waits")
		world.pending()
		helpers.assert_eq(world.reloads, 1)
		helpers.assert_eq(watch.active(), false)
		helpers.assert_eq(watch.start(), false, "one watch per launch")
		helpers.assert_eq(#world.opened, 1)
	end)

	helpers.it("gives up at its deadline without a reload", function()
		local watch, world, Watch = fake({ line("activated waiting for user") })
		watch.start()
		for _ = 1, Watch.APPROVAL_TIMEOUT_SEC / Watch.APPROVAL_POLL_SEC do
			if not world.pending then break end
			local next_look = world.pending
			world.pending = nil
			next_look()
		end
		helpers.assert_eq(world.reloads, 0)
		helpers.assert_eq(watch.active(), false)
	end)
end)
