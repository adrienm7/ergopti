--- tests/unit/keyboard/engine/test_runtime_approval_watch.lua

--- ==============================================================================
--- MODULE: Owned Runtime Driver Approval Watch
--- DESCRIPTION:
--- Pins keyboard/adapters/runtime/approval_watch.lua with fake ports: one watch
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

--- @param listings table Successive listing texts; the last one repeats.
--- @param options table|nil listing_sec: clock cost of each listing; opener: pane opener.
local function fake(listings, options)
	options = options or {}
	package.loaded["keyboard.adapters.runtime.approval_watch"] = nil
	local Watch = require("keyboard.adapters.runtime.approval_watch")
	local world = { opened = {}, reloads = 0, looks = 0, pending = nil, clock = 1000 }
	local watch = Watch.new({
		listing = function(callback)
			world.looks = world.looks + 1
			world.clock = world.clock + (options.listing_sec or 0)
			callback(listings[math.min(world.looks, #listings)])
		end,
		now = function() return world.clock end,
		after = function(seconds, fn)
			world.pending = function() world.clock = world.clock + seconds; fn() end
			return "handle", true
		end,
		cancel = function() end,
		open_settings = function(url)
			world.opened[#world.opened + 1] = url
			if options.opener then return options.opener(url) end
			return true
		end,
		reload = function() world.reloads = world.reloads + 1 end,
		version = function() return "8.5.0" end,
	})
	return watch, world, Watch
end

helpers.describe("owned runtime driver approval watch", function()
	helpers.it("opens the extension pane once and reloads when the driver is allowed", function()
		local watch, world = fake({ line("activated waiting for user"), line("activated enabled") })
		helpers.assert_eq(watch.start(), true)
		helpers.assert_eq(world.opened, { require("keyboard.adapters.karabiner.ke_paths").EXTENSIONS_SETTINGS_URL })
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

	-- MRT-006: hs.urlevent.openURL answers false when the pane did not open; only
	-- a thrown error was reported, so a refused pane passed for an opened one.
	helpers.it("reports a refused or unknown native pane opening (mrt-006)", function()
		local Logger = require("core.logger.engine.logger")
		local original = Logger.error
		local cases = {
			{ name = "true", opener = function() return true end, errors = 0 },
			{ name = "false", opener = function() return false end, errors = 1 },
			{ name = "nil", opener = function() return nil end, errors = 1 },
			{ name = "throw", opener = function() error("opener crashed") end, errors = 1 },
		}
		for _, case in ipairs(cases) do
			local errors = 0
			Logger.error = function() errors = errors + 1 end
			local ok, failure = pcall(function()
				local watch, world = fake({ line("activated waiting for user") }, { opener = case.opener })
				helpers.assert_eq(watch.start(), true)
				helpers.assert_eq(#world.opened, 1, case.name .. ": the pane is asked once")
				helpers.assert_eq(watch.active(), true, case.name .. ": the listing watch goes on")
			end)
			Logger.error = original
			helpers.assert_true(ok, tostring(failure))
			helpers.assert_eq(errors, case.errors, case.name .. ": opener result must be reported truthfully")
		end
	end)

	-- MRT-001: the deadline counted poll intervals only, so four-second listings
	-- kept the watch alive for 2,104 s instead of 900 s.
	helpers.it("spends its deadline on slow listings too (mrt-001)", function()
		local watch, world, Watch = fake({ line("activated waiting for user") }, { listing_sec = 4 })
		local started = world.clock
		watch.start()
		while world.pending and watch.active() do
			local next_look = world.pending
			world.pending = nil
			next_look()
		end
		helpers.assert_eq(watch.active(), false)
		helpers.assert_true(world.clock - started < Watch.APPROVAL_TIMEOUT_SEC + Watch.APPROVAL_POLL_SEC + 4,
			"the watch must stop within its wall-clock budget, stopped after " .. (world.clock - started) .. " s")
	end)

	helpers.it("does not reload for an approval seen after its deadline (mrt-001)", function()
		local watch, world, Watch = fake({ line("activated waiting for user"), line("activated enabled") })
		watch.start()
		world.clock = world.clock + Watch.APPROVAL_TIMEOUT_SEC
		world.pending()
		helpers.assert_eq(world.reloads, 0, "a late approval is left to the menu, the watch is over")
		helpers.assert_eq(watch.active(), false)
	end)
end)
