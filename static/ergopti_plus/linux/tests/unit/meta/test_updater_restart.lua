--- tests/unit/meta/test_updater_restart.lua

--- ==============================================================================
--- MODULE: Restarting On An Installed Update
--- DESCRIPTION:
--- The updater replaced the installation and logged "Restart the daemon to
--- apply", which nobody reads: the old code kept running until the next login.
--- The daemon now starts the installed version in its own place — through
--- systemd when its unit runs it, through a relay that outlives it otherwise —
--- and the tray tells what a check found and what an install did.
--- ==============================================================================

local helpers = require("tests.helpers")
local Restarter = require("modules.updater.restarter")

local UNIT_CGROUP = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/ergopti-hotstrings.service\n"
local TERMINAL_CGROUP = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/vte-spawn-1.scope\n"

helpers.describe("updater restart: starting the installed version", function()

	helpers.it("asks systemd to restart the unit that runs the daemon", function()
		local ran = {}
		local how = Restarter.restart({ wrapper = "/home/u/.local/bin/ergopti-hotstrings", args = { "--tray" },
			cgroup = UNIT_CGROUP, run = function(cmd) ran[#ran + 1] = cmd; return true end })
		helpers.assert_eq(how, "systemd")
		helpers.assert_eq(ran[1], "systemctl --user --no-block restart ergopti-hotstrings.service")
	end)

	helpers.it("otherwise relaunches the installed launcher once this process has exited", function()
		local ran = {}
		local how = Restarter.restart({ wrapper = "/home/u/.local/bin/ergopti-hotstrings", args = { "--tray", "--verbose" },
			cgroup = TERMINAL_CGROUP, pid = 4242, run = function(cmd) ran[#ran + 1] = cmd; return true end })
		helpers.assert_eq(how, "relay", "the caller must now exit")
		helpers.assert_true(ran[1]:find("^setsid sh %-c ") ~= nil, "detached from the dying daemon")
		helpers.assert_true(ran[1]:find("kill -0 4242", 1, true) ~= nil,
			"waits for the old daemon, which still holds the keyboard grab")
		helpers.assert_true(ran[1]:find("/home/u/.local/bin/ergopti-hotstrings", 1, true) ~= nil
			and ran[1]:find("--tray", 1, true) ~= nil and ran[1]:find("--verbose", 1, true) ~= nil,
			"the installed launcher, with the same arguments")
	end)

	helpers.it("really waits for the process and then runs the launcher", function()
		local dir = os.tmpname()
		os.remove(dir)
		os.execute("mkdir -p '" .. dir .. "'")
		local marker = dir .. "/started"
		local launcher = dir .. "/launcher"
		local fh = assert(io.open(launcher, "w"))
		fh:write("#!/bin/sh\necho \"$@\" > '" .. marker .. "'\n")
		fh:close()
		os.execute("chmod +x '" .. launcher .. "'")
		-- A stand-in daemon: a process that lives 0.5 s.
		local pipe = assert(io.popen("sleep 0.5 & echo $!"))
		local pid = tonumber(pipe:read("*l"))
		pipe:close()
		local how = Restarter.restart({ wrapper = launcher, args = { "--tray" }, cgroup = TERMINAL_CGROUP, pid = pid })
		helpers.assert_eq(how, "relay")
		local early = io.open(marker, "r")
		helpers.assert_nil(early, "nothing starts while the old daemon lives")
		os.execute("sleep 1.5")
		local started = io.open(marker, "r")
		helpers.assert_true(started ~= nil, "the launcher ran after the old process exited")
		helpers.assert_eq(started:read("*l"), "--tray")
		started:close()
		os.execute("rm -rf '" .. dir .. "'")
	end)

	helpers.it("reports a restart it could not start", function()
		helpers.assert_nil(Restarter.restart({ wrapper = "/x", cgroup = UNIT_CGROUP, run = function() return false end }))
		helpers.assert_nil(Restarter.restart({ wrapper = "/x", cgroup = TERMINAL_CGROUP, pid = 1,
			run = function() return false end }))
	end)

	helpers.it("reads its own process id and cgroup", function()
		helpers.assert_true(type(Restarter.own_pid()) == "number")
		helpers.assert_true(not Restarter.under_unit(TERMINAL_CGROUP))
		helpers.assert_true(Restarter.under_unit(UNIT_CGROUP))
	end)

end)

helpers.describe("updater restart: the tray tells and acts", function()

	--- The Updates submenu built on a fake updater; returns its rows.
	local function updates_rows(fake, ctx_extra)
		local mb = helpers.load_module("ui.menu.menu_builder")
		local ctx = { _version = "test", on_quit = function() end, updater = fake }
		for key, value in pairs(ctx_extra) do ctx[key] = value end
		local title = require("infra.i18n").get("menu.updates.title")
		for _, item in ipairs(mb.build(ctx)) do
			if item.title == title then return item.menu end
		end
		error("no Updates section")
	end

	local function fake_updater(state, release)
		local fake = {
			INTERVAL_PRESETS = {},
			get_channel = function() return "dev" end,
			get_check_interval = function() return 3600 end,
			current_version = function() return "0.0.0-dev.133" end,
			get_menu_label = function() return "check" end,
			get_state = function() return state end,
			get_cached_release = function() return release end,
			releases_page_url = function() return "https://example.invalid" end,
			set_channel = function() return true end,
			set_check_interval = function() return true end,
			stop_background_checks = function() return true end,
			start_background_checks = function() return true end,
		}
		return fake
	end

	helpers.it("hands a manual check's answer to the daemon", function()
		local fake = fake_updater("idle")
		fake.check_for_updates = function(_, callback) callback(false, nil, nil); return true end
		local told = nil
		local rows = updates_rows(fake, { on_update_checked = function(...) told = { ... } end })
		for _, row in ipairs(rows) do
			if row.title == "check" then row.fn() end
		end
		helpers.assert_true(told ~= nil, "the daemon is told, and redraws the menu")
		helpers.assert_eq(told[1], false)
	end)

	helpers.it("installs a downloaded update and hands the result on for the restart", function()
		local release = { tag = "v0.0.0-dev.134" }
		local fake = fake_updater("available", release)
		local installed_from = nil
		fake.download_update = function(_, callback) callback("/tmp/update.tar.gz", nil); return true end
		fake.install_update = function(path) installed_from = path; return true end
		local finished = nil
		local rows = updates_rows(fake, { on_update_finished = function(...) finished = { ... } end })
		local label = require("infra.i18n").get("menu.updates.download_install"):gsub("{tag}", release.tag)
		for _, row in ipairs(rows) do
			if row.title == label then row.fn() end
		end
		helpers.assert_eq(installed_from, "/tmp/update.tar.gz")
		helpers.assert_eq(finished[1], true)
		helpers.assert_eq(finished[2], "v0.0.0-dev.134")
	end)

	-- The user validates the release the row names. A background check that
	-- replaced the cached release between the menu's rendering and the click
	-- must not turn that consent into a download of another version
	-- (updater-consent-2026-09-25).
	helpers.it("downloads only the release the row showed", function()
		local shown = { tag = "v0.0.0-dev.134", download_url = "https://example.invalid/134.tar.gz" }
		local fake = fake_updater("available", shown)
		local requested = "unset"
		fake.download_update = function(url, callback)
			requested = url
			callback(nil, "stop here")
			return false
		end
		fake.install_update = function() error("nothing to install") end
		local rows = updates_rows(fake, { on_update_finished = function() end })
		local label = require("infra.i18n").get("menu.updates.download_install"):gsub("{tag}", shown.tag)
		for _, row in ipairs(rows) do
			if row.title == label then row.fn() end
		end
		helpers.assert_eq(requested, shown.download_url,
			"the click must name the rendered release so the manager can refuse a changed one")
	end)

	helpers.it("hands a failed download on, which is not installed", function()
		local fake = fake_updater("available", { tag = "v0.0.0-dev.134" })
		fake.download_update = function(_, callback) callback(nil, "offline"); return true end
		fake.install_update = function() error("nothing to install") end
		local finished = nil
		local rows = updates_rows(fake, { on_update_finished = function(...) finished = { ... } end })
		local label = require("infra.i18n").get("menu.updates.download_install"):gsub("{tag}", "v0.0.0-dev.134")
		for _, row in ipairs(rows) do
			if row.title == label then row.fn() end
		end
		helpers.assert_eq(finished[1], false)
		helpers.assert_eq(finished[3], "download")
	end)

end)

helpers.describe("updater restart: the daemon restarts on an installed update", function()

	helpers.it("wires the tray's outcomes to the notifier and the restarter", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(src:find("on_update_finished = function", 1, true) ~= nil)
		helpers.assert_true(src:find('require("modules.updater.restarter").restart', 1, true) ~= nil)
		helpers.assert_true(src:find('shutdown.request("update installed")', 1, true) ~= nil,
			"the old daemon exits so the relay can start the new one")
	end)

end)
