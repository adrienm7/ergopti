--- tests/unit/ui/test_onboarding_startup.lua

--- ==============================================================================
--- MODULE: First-use Startup Tests
--- DESCRIPTION:
--- Verifies that graphical startup opens the wizard exactly when config.toml is
--- absent, as the macOS and Windows drivers do: any existing file, whatever it
--- holds, means the user has configured the driver, and no completion marker is
--- read or written. A displayed window is never mistaken for consent.
--- ==============================================================================

local helpers = require("tests.helpers")
local Startup = require("ui.onboarding.startup")

local function fixture(raw)
	local record = { shown = 0, failed = 0, opened = 0 }
	return {
		graphical = true, path = "/fixture/config.toml",
		open = function(path)
			helpers.assert_eq(path, "/fixture/config.toml")
			record.opened = record.opened + 1
			if raw == nil then return nil, "missing", 2 end
			return { read = function() return raw end, close = function() return true end }
		end,
		show = function(app)
			helpers.assert_eq(app, "onboarding")
			record.shown = record.shown + 1
			return true
		end,
		fail = function() record.failed = record.failed + 1 end,
	}, record
end

helpers.describe("first-use startup", function()
	helpers.it("opens the wizard when config.toml is absent (linux-first-use)", function()
		local opts, record = fixture(nil)
		helpers.assert_true(Startup.run(opts))
		helpers.assert_eq(record.shown, 1)
		helpers.assert_eq(record.failed, 0)
	end)

	helpers.it("never opens it over an existing configuration (linux-first-use)", function()
		for _, raw in ipairs({ "", "[gestures]\nenabled = false\n", "[script]\nonboarding_done = false\n",
			"[_meta]\nschema_version = 2\n" }) do
			local opts, record = fixture(raw)
			helpers.assert_true(Startup.run(opts))
			helpers.assert_eq(record.shown, 0, "an existing file is a configured driver: " .. raw)
			helpers.assert_eq(record.failed, 0)
		end
	end)

	helpers.it("does not inspect configuration in headless or dry-run startup (linux-first-use)", function()
		local opts, record = fixture()
		opts.graphical = false
		helpers.assert_true(Startup.run(opts))
		helpers.assert_eq(record.opened, 0)
	end)

	helpers.it("reports unreadable configuration and unavailable windows (linux-first-use)", function()
		local opts, record = fixture()
		opts.open = function() return nil, "permission denied", 13 end
		helpers.assert_eq(Startup.run(opts), false)
		helpers.assert_eq(record.shown, 0)
		helpers.assert_eq(record.failed, 1)
		opts, record = fixture()
		opts.show = function() return false end
		helpers.assert_eq(Startup.run(opts), false)
		helpers.assert_eq(record.failed, 1)
	end)

	helpers.it("a dismissed wizard opens again while nothing was written (linux-first-use)", function()
		local opts, record = fixture()
		helpers.assert_true(Startup.run(opts))
		helpers.assert_true(Startup.run(opts))
		helpers.assert_eq(record.shown, 2, "opening cannot manufacture a configuration")
		helpers.assert_nil(Startup.should_show, "no completion marker is read any more")
	end)

	helpers.it("the daemon runs the check on its own config.toml once graphical (linux-first-use)", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local code = (fh:read("*a"):gsub("%-%-[^\n]*", ""))
		fh:close()
		local call = code:find('require("ui.onboarding.startup").run({', 1, true)
		helpers.assert_true(call ~= nil, "the daemon starts the first-use check")
		local block = code:sub(call, code:find("})", call, true))
		helpers.assert_true(block:find('config_paths").config("config.toml")', 1, true) ~= nil,
			"the check reads the config.toml every reader uses")
		helpers.assert_true(block:find("graphical = opts.tray == true and not opts.dry_run", 1, true) ~= nil,
			"only a graphical daemon opens a window")
		local wired = code:find("webview_manager.set_daemon_state(", 1, true)
		helpers.assert_true(wired ~= nil and wired < call, "the wizard's bridge state is wired before it opens")
	end)
end)
