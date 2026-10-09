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
local WinCompat = require("tests.win_compat")
local Restarter = require("modules.updater.restarter")

local UNIT_CGROUP = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/ergopti-hotstrings.service\n"
local TERMINAL_CGROUP = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/vte-spawn-1.scope\n"
local SELF_STAT = "4242 (luajit) S 1 4242 4242 0 -1 4194560 812 0 0 0 3 1 0 0 20 0 1 0 1337\n"

-- The relay and the process id need a Linux kernel's setsid(1) and /proc.
-- A Windows checkout has neither: only there are those two cases deferred,
-- and every decision the restarter makes is tested on text it is handed. On
-- Linux a missing setsid or /proc is a failure.
local ON_WINDOWS = WinCompat.is_windows()

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

	if ON_WINDOWS then
		helpers.it("SKIP [CONF-LINUX-SETSID-RELAY] — a Windows host has no setsid(1) to detach the relay from", function()
			helpers.assert_eq(package.config:sub(1, 1), "\\",
				"this deferral runs only on a host whose separator is Windows'")
		end)
	else
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
	end

	helpers.it("reports a restart it could not start", function()
		helpers.assert_nil(Restarter.restart({ wrapper = "/x", cgroup = UNIT_CGROUP, run = function() return false end }))
		helpers.assert_nil(Restarter.restart({ wrapper = "/x", cgroup = TERMINAL_CGROUP, pid = 1,
			run = function() return false end }))
	end)

	helpers.it("reads its process id from its stat line, and its unit from its cgroup", function()
		helpers.assert_eq(Restarter.own_pid(SELF_STAT), 4242)
		helpers.assert_nil(Restarter.own_pid("(luajit) S"), "a line without a leading id is no id")
		helpers.assert_true(not Restarter.under_unit(TERMINAL_CGROUP))
		helpers.assert_true(Restarter.under_unit(UNIT_CGROUP))
	end)

	if ON_WINDOWS then
		helpers.it("SKIP [CONF-LINUX-PROC-SELF] — a Windows host has no /proc/self/stat to read its own process id from", function()
			helpers.assert_eq(package.config:sub(1, 1), "\\",
				"this deferral runs only on a host whose separator is Windows'")
		end)
	else
		helpers.it("reads its own process id from the kernel", function()
			local pid = Restarter.own_pid()
			helpers.assert_true(type(pid) == "number" and pid > 0, "own_pid() is " .. tostring(pid))
		end)
	end

end)

helpers.describe("updater restart: the tray tells and acts", function()

--- Keeps an installed-build fixture's native owner live through the later click.
--- The real consent bridge is exercised with an explicitly unavailable progress
--- window; these tray fixtures do not claim a native GUI or real download.
local function bind_action_owners(items, source_run)
	local unpack_results = table.unpack or unpack
	local function packed(...) return { n = select("#", ...), ... } end
	for _, item in ipairs(items) do
		if type(item.fn) == "function" then
			local action = item.fn
			item.fn = function(...)
				local Installation = require("infra.installation")
				local original_owner = Installation.is_source_run
				local original_progress = package.loaded["ui.download_window.bridge"]
				Installation.is_source_run = function() return source_run == true end
				package.loaded["ui.download_window.bridge"] = { show = function() return nil end }
				local result = packed(pcall(action, ...))
				Installation.is_source_run = original_owner
				package.loaded["ui.download_window.bridge"] = original_progress
				if not result[1] then error(result[2], 0) end
				return unpack_results(result, 2, result.n)
			end
		end
		if type(item.menu) == "table" then bind_action_owners(item.menu, source_run) end
	end
	return items
end

	--- The About submenu built on a fake updater; returns its update rows.
	--- @param source_run boolean|nil What the installed-build owner answers
	---   (an installed build by default; the suite itself runs from a checkout).
	local function updates_rows(fake, ctx_extra, source_run)
		local Installation = require("infra.installation")
		local real_is_source_run = Installation.is_source_run
		Installation.is_source_run = function() return source_run == true end
		local mb = helpers.load_module("ui.menu.menu_builder")
		local ctx = { _version = "test", on_quit = function() end, updater = fake }
		for key, value in pairs(ctx_extra) do ctx[key] = value end
		local title = require("infra.i18n").get("menu.about.title")
		local ok, items = pcall(mb.build, ctx)
		Installation.is_source_run = real_is_source_run
		if not ok then error(items, 0) end
		for _, item in ipairs(items) do
			if item.title == title then return bind_action_owners(item.menu, source_run) end
		end
		error("no About section")
	end

	local function fake_updater(state, release)
		local real = require("modules.updater.manager")
		local fake = {
			CHANNELS = real.CHANNELS,
			TIMING = real.TIMING,
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

	helpers.it("hands a manual check's answer to the daemon when no window can show it", function()
		local fake = fake_updater("idle")
		fake.check_for_updates = function(_, callback) callback(false, nil, nil); return true end
		local told = nil
		local saved = package.loaded["ui.update_check.bridge"]
		package.loaded["ui.update_check.bridge"] = { open = function() return false end }
		local rows = updates_rows(fake, { on_update_checked = function(...) told = { ... } end })
		for _, row in ipairs(rows) do
			if row.title == "check" then row.fn() end
		end
		package.loaded["ui.update_check.bridge"] = saved
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
		local label = require("infra.i18n").get("menu.about.update_now"):gsub("{tag}", release.tag)
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
		local label = require("infra.i18n").get("menu.about.update_now"):gsub("{tag}", shown.tag)
		for _, row in ipairs(rows) do
			if row.title == label then row.fn() end
		end
		helpers.assert_eq(requested, shown.download_url,
			"the click must name the rendered release so the manager can refuse a changed one")
	end)

	-- A source run has no installation to replace: the row naming the release
	-- stays, greyed, says why, and has no action a click could start.
	helpers.it("greys the update row of a source run, naming why", function()
		local release = { tag = "v0.0.0-dev.134" }
		local fake = fake_updater("available", release)
		fake.download_update = function() error("a source run must download nothing") end
		fake.install_update = function() error("a source run must install nothing") end
		local rows = updates_rows(fake, { on_update_finished = function() end }, true)
		local i18n = require("infra.i18n")
		local plain = i18n.get("menu.about.update_now"):gsub("{tag}", release.tag)
		-- The head of the reason, cut as the renderers cut it: before its first
		-- colon, ASCII or full-width.
		local reason = i18n.get("menu.about.source_run_reason")
		local cut = nil
		for _, mark in ipairs({ ":", "\239\188\154" }) do
			local at = reason:find(mark, 1, true)
			if at and (cut == nil or at < cut) then cut = at end
		end
		local head = ((cut and reason:sub(1, cut - 1) or reason):gsub("^%s+", ""):gsub("%s+$", ""))
		local greyed = plain .. " — " .. head
		local found = nil
		for _, row in ipairs(rows) do
			helpers.assert_true(row.title ~= plain, "no live update row on a source run")
			if row.title == greyed then found = row end
		end
		helpers.assert_true(found ~= nil, "the row stays and names why")
		helpers.assert_eq(found.disabled, true, "greyed")
		helpers.assert_true(found.fn == nil, "with no action to start")
	end)

	helpers.it("hands a failed download on, which is not installed", function()
		local fake = fake_updater("available", { tag = "v0.0.0-dev.134" })
		fake.download_update = function(_, callback) callback(nil, "offline"); return true end
		fake.install_update = function() error("nothing to install") end
		local finished = nil
		local rows = updates_rows(fake, { on_update_finished = function(...) finished = { ... } end })
		local label = require("infra.i18n").get("menu.about.update_now"):gsub("{tag}", "v0.0.0-dev.134")
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
