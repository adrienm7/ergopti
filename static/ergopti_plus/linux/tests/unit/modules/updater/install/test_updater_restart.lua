--- tests/unit/modules/updater/install/test_updater_restart.lua

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
local BOOT_ID = "01234567-89ab-cdef-0123-456789abcdef"

helpers.describe("updater restart: starting the installed version", function()

	helpers.it("(quit-wins-over-reload) cancels a pending systemd restart with a stop job", function()
		local ran = {}
		local cancelled = Restarter.cancel("systemd", { run = function(cmd) ran[#ran + 1] = cmd; return true end })
		helpers.assert_eq(cancelled, true)
		helpers.assert_eq(ran, { Restarter.OWN_UNIT_JOB_PREFIX .. "systemctl --user --no-block stop ergopti-hotstrings.service" })
		local refused, detail = Restarter.cancel("systemd", { run = function() return false end })
		helpers.assert_eq(refused, false)
		helpers.assert_contains(detail, "systemctl")
	end)

	helpers.it("(quit-wins-over-reload) cancels a relay by its marker with no XDG_RUNTIME_DIR", function()
		local ran = {}
		local run = function(cmd) ran[#ran + 1] = cmd; return true end
		local path = Restarter.cancel_path(4242, "1337", BOOT_ID)
		helpers.assert_eq(path, require("core.fs.adapters.storage").path() .. ".relay-cancel-4242-1337-" .. BOOT_ID)
		helpers.assert_eq(Restarter.cancel("relay", { run = run, pid = 4242, start_tick = "1337", boot_id = BOOT_ID }), true)
		helpers.assert_eq(ran, { "touch '" .. path .. "'" })
		local refused, detail = Restarter.cancel("relay", { run = function() return false end, pid = 4242, start_tick = "1337", boot_id = BOOT_ID })
		helpers.assert_eq(refused, false)
		helpers.assert_contains(detail, "marker")
		local none, why = Restarter.cancel("nothing", {})
		helpers.assert_eq(none, false)
		helpers.assert_contains(why, "no restart")
	end)

	helpers.it("(relay-cancel-identity) keeps stale markers distinct across process and boot reuse", function()
		local original = Restarter.cancel_path(4242, "1337", BOOT_ID)
		local different_process = Restarter.cancel_path(4242, "1338", BOOT_ID)
		local different_boot = Restarter.cancel_path(4242, "1337", "11234567-89ab-cdef-0123-456789abcdef")
		helpers.assert_true(original ~= different_process and original ~= different_boot)
		helpers.assert_nil(Restarter.cancel_path(4242, "1337", "not-a-boot-id"))
		helpers.assert_nil(Restarter.cancel_path(4242, "1/escape", BOOT_ID))
	end)

	helpers.it("(relay-cancel-identity) a stale cancellation does not suppress the new launcher", function()
		if ON_WINDOWS then return end
		local Shell, Storage = require("adapters.shell_runner"), require("core.fs.adapters.storage")
		local directory = os.tmpname(); os.remove(directory); assert(Shell.run("mkdir " .. Shell.quote(directory)))
		local original = Storage.path
		local ok, detail = xpcall(function()
			Storage.path = function() return directory .. "/storage.json" end
			local pid = assert(Restarter.own_pid())
			local stale = assert(Restarter.cancel_path(pid, "0", BOOT_ID))
			local legacy = Storage.path() .. ".relay-cancel-" .. tostring(pid)
			local current = assert(Restarter.cancel_path(pid, "0", "11234567-89ab-cdef-0123-456789abcdef"))
			local file = assert(io.open(stale, "w")); assert(file:close())
			file = assert(io.open(legacy, "w")); assert(file:close())
			local launcher, launched = directory .. "/launcher", directory .. "/launched"
			file = assert(io.open(launcher, "w")); file:write("#!/bin/sh\necho yes > " .. Shell.quote(launched) .. "\n"); file:close()
			assert(Shell.run("chmod 700 " .. Shell.quote(launcher)))
			assert(Shell.run(Restarter.relay_command(pid, launcher, {}, current, "0")))
			local present = false
			for _ = 1, 30 do
				local probe = io.open(launched, "r")
				if probe then probe:close(); present = true; break end
				os.execute("sleep 0.05")
			end
			helpers.assert_true(present, "the new relay must ignore another boot's stale marker")
			local remaining = io.open(stale, "r")
			helpers.assert_true(remaining ~= nil, "the new relay cannot consume the old marker")
			if remaining then remaining:close() end
			remaining = io.open(legacy, "r")
			helpers.assert_true(remaining ~= nil, "the legacy marker also stays untouched")
			if remaining then remaining:close() end
		end, debug.traceback)
		Storage.path = original
		os.execute("rm -rf " .. Shell.quote(directory))
		if not ok then error(detail, 0) end
	end)

	helpers.it("(relay-cancel-identity) refuses to arm a relay with an invalid boot identity", function()
		local calls = 0
		local how = Restarter.restart({ wrapper = "/x", cgroup = TERMINAL_CGROUP, pid = 4242,
			start_tick = "1337", boot_id = "invalid", run = function() calls = calls + 1; return true end })
		helpers.assert_nil(how)
		helpers.assert_eq(calls, 0, "an unqualified marker cannot safely cancel the relay")
	end)

	helpers.it("(relay-cancel-identity) cancellation uses the dispatched identity despite later read failure", function()
		local old = Restarter.process_start_time
		local commands = {}
		local function run(command) commands[#commands + 1] = command; return true end
		local how = Restarter.restart({ wrapper = "/x", args = {}, cgroup = TERMINAL_CGROUP,
			pid = 4243, start_tick = "1337", boot_id = BOOT_ID, run = run })
		helpers.assert_eq(how, "relay")
		Restarter.process_start_time = function() return nil end
		local ok, detail = pcall(function()
			helpers.assert_true(Restarter.cancel("relay", { pid = 4243, run = run }))
			helpers.assert_contains(commands[2], ".relay-cancel-4243-1337-" .. BOOT_ID)
			local refused = Restarter.cancel("relay", { pid = 4244, run = run })
			helpers.assert_eq(refused, false, "a different PID cannot borrow a fresh identity")
			helpers.assert_eq(#commands, 2)
		end)
		Restarter.process_start_time = old
		if not ok then error(detail, 0) end
	end)

	helpers.it("(relay-cancel-identity) quits the actual relay without rereading unavailable proc identity", function()
		if ON_WINDOWS then return end
		local Shell, Storage = require("adapters.shell_runner"), require("core.fs.adapters.storage")
		local directory = os.tmpname(); os.remove(directory); assert(Shell.run("mkdir " .. Shell.quote(directory)))
		local old_path, old_open = Storage.path, io.open
		local child
		local ok, detail = xpcall(function()
			Storage.path = function() return directory .. "/storage.json" end
			local launcher, launched = directory .. "/launcher", directory .. "/launched"
			local file = assert(io.open(launcher, "w")); file:write("#!/bin/sh\necho yes > " .. Shell.quote(launched) .. "\n"); file:close()
			assert(Shell.run("chmod 700 " .. Shell.quote(launcher)))
			local pipe = assert(io.popen("sleep 1 & echo $!")); child = assert(tonumber(pipe:read("*l"))); pipe:close()
			local tick, boot = assert(Restarter.process_start_time(child)), assert(Restarter.boot_id())
			local marker = assert(Restarter.cancel_path(child, tick, boot))
			helpers.assert_eq(Restarter.restart({ wrapper = launcher, cgroup = TERMINAL_CGROUP,
				pid = child, start_tick = tick, boot_id = boot, run = Shell.run }), "relay")
			io.open = function(path, ...)
				if path == "/proc/self/stat" or path == "/proc/" .. child .. "/stat"
					or path == "/proc/sys/kernel/random/boot_id" then return nil, "controlled refusal" end
				return old_open(path, ...)
			end
			helpers.assert_true(Restarter.cancel("relay", { run = Shell.run }), "Quit must use the dispatch identity")
			io.open = old_open
			local exists = io.open(marker, "r"); helpers.assert_true(exists ~= nil); if exists then exists:close() end
			local consumed = false
			for _ = 1, 40 do
				local probe = io.open(marker, "r")
				if not probe then consumed = true; break end
				probe:close(); os.execute("sleep 0.05")
			end
			helpers.assert_true(consumed, "the actual relay must consume the exact marker")
			helpers.assert_nil(io.open(launched, "r"), "Quit must win")
		end, debug.traceback)
		io.open, Storage.path = old_open, old_path
		if child then os.execute("kill " .. child .. " 2>/dev/null") end
		os.execute("rm -rf " .. Shell.quote(directory))
		if not ok then error(detail, 0) end
	end)

	helpers.it("(quit-wins-over-reload) a relay command checks the cancellation marker after the wait", function()
		local command = Restarter.relay_command(4242, "/home/u/launcher", {}, "/run/user/1/ergopti/relay-cancel-4242", "1337")
		local wait, check, launch = command:find("sleep 0.2; done;", 1, true), command:find("relay-cancel-4242", 1, true), command:find("exec ", 1, true)
		helpers.assert_true(wait and check and launch and wait < check and check < launch,
			"the marker is read after the old daemon exited and before the launcher starts")
		helpers.assert_nil(Restarter.relay_command(4242, "/home/u/launcher", {}, nil, "1337"):find("relay-cancel", 1, true),
			"without a marker the relay command is unchanged")
	end)

	helpers.it("(quit-wins-over-reload) a relay whose marker exists does not start the launcher", function()
		if ON_WINDOWS then return end
		local dir = os.tmpname()
		os.remove(dir)
		os.execute("mkdir -p '" .. dir .. "'")
		local started, marker = dir .. "/started", dir .. "/cancel"
		local launcher = dir .. "/launcher"
		local fh = assert(io.open(launcher, "w"))
		fh:write("#!/bin/sh\necho started > '" .. started .. "'\n")
		fh:close()
		os.execute("chmod +x '" .. launcher .. "'")
		local pipe = assert(io.popen("sleep 0.4 & echo $!"))
		local pid = tonumber(pipe:read("*l"))
		pipe:close()
		os.execute("touch '" .. marker .. "'")
		helpers.assert_true(os.execute(Restarter.relay_command(pid, launcher, {}, marker, assert(Restarter.process_start_time(pid)))) ~= nil)
		local gone = false
		for _ = 1, 100 do
			local handle = io.open(marker, "r")
			if handle then handle:close() else gone = true; break end
			os.execute("sleep 0.1")
		end
		helpers.assert_true(gone, "the relay consumed the marker once the daemon exited")
		os.execute("sleep 0.3")
		helpers.assert_nil(io.open(started, "r"), "a cancelled relay never starts the launcher")
		os.execute("rm -rf '" .. dir .. "'")
	end)

	helpers.it("(restart-relay-pid-reuse) does not wait on a different process with the same numeric pid", function()
		if ON_WINDOWS then return end
		local Shell = require("adapters.shell_runner")
		local dir = os.tmpname(); os.remove(dir); assert(Shell.run("mkdir " .. Shell.quote(dir)))
		local marker, launcher = dir .. "/started", dir .. "/launcher"
		local file = assert(io.open(launcher, "w")); file:write("#!/bin/sh\necho started > " .. Shell.quote(marker) .. "\n"); file:close()
		assert(Shell.run("chmod 700 " .. Shell.quote(launcher)))
		local pipe = assert(io.popen("sleep 4 & echo $!"))
		local pid = assert(tonumber(pipe:read("*l"))); pipe:close()
		-- Zero is not this live sleep's start tick: model a PID already reused.
		local command = Restarter.relay_command(pid, launcher, {}, nil, "0")
		assert(Shell.run(command))
		local observed = false
		for _ = 1, 15 do
			local probe = io.open(marker, "r")
			if probe then probe:close(); observed = true; break end
			os.execute("sleep 0.1")
		end
		os.execute("kill " .. pid .. " 2>/dev/null")
		os.remove(marker); os.remove(launcher); os.remove(dir)
		helpers.assert_true(observed, "a reused pid must not delay the new daemon")
	end)

	helpers.it("asks systemd to restart the unit that runs the daemon", function()
		local ran = {}
		local how = Restarter.restart({ wrapper = "/home/u/.local/bin/ergopti-hotstrings", args = { "--tray" },
			cgroup = UNIT_CGROUP, run = function(cmd) ran[#ran + 1] = cmd; return true end })
		helpers.assert_eq(how, "systemd")
		helpers.assert_eq(ran[1], Restarter.OWN_UNIT_JOB_PREFIX .. "systemctl --user --no-block restart ergopti-hotstrings.service")
	end)

	helpers.it("otherwise relaunches the installed launcher once this process has exited", function()
		local ran = {}
		local how = Restarter.restart({ wrapper = "/home/u/.local/bin/ergopti-hotstrings", args = { "--tray", "--verbose" },
			cgroup = TERMINAL_CGROUP, pid = 4242, start_tick = "1337", boot_id = BOOT_ID, run = function(cmd) ran[#ran + 1] = cmd; return true end })
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
		helpers.it("(restart-relay-dispatch-ack) refuses shutdown when native relay dispatch exits unsuccessfully", function()
			local Shell = require("adapters.shell_runner")
			local folder = os.tmpname()
			os.remove(folder)
			helpers.assert_true(Shell.run("mkdir " .. Shell.quote(folder)))
			local fake = assert(io.open(folder .. "/setsid", "w"))
			fake:write("#!/bin/sh\nexit 73\n")
			fake:close()
			helpers.assert_true(Shell.run("chmod 700 " .. Shell.quote(folder .. "/setsid")))
			local called, failure = xpcall(function()
				local how = Restarter.restart({ wrapper = "/unreached/launcher", args = {},
					cgroup = TERMINAL_CGROUP, pid = Restarter.own_pid(),
					run = function(command)
						return Shell.run("PATH=" .. Shell.quote(folder) .. ":\"$PATH\" " .. command)
					end })
				helpers.assert_nil(how, "a failed native setsid must not authorize the daemon to exit")
			end, debug.traceback)
			os.remove(folder .. "/setsid")
			os.remove(folder)
			if not called then error(failure, 0) end
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
			-- Poll for the launcher instead of a fixed wait: it runs once the
			-- stand-in exits, after 0.5 s; 5 s is the ceiling, not the cost.
			-- The redirect creates the file before echo writes it, so wait for a line.
			local line
			for _ = 1, 100 do
				local started = io.open(marker, "r")
				if started then
					line = started:read("*l")
					started:close()
				end
				if line then break end
				os.execute("sleep 0.05")
			end
			helpers.assert_true(line ~= nil, "the launcher ran after the old process exited")
			helpers.assert_eq(line, "--tray")
			os.execute("rm -rf '" .. dir .. "'")
		end)
	end

	helpers.it("(restart-cgroup-read-refusal) never guesses the restart route", function()
		local original_open = io.open
		local calls = 0
		io.open = function(path, ...)
			if path == "/proc/self/cgroup" then return nil, "controlled read refusal", 13 end
			return original_open(path, ...)
		end
		local ok, detail = pcall(function()
			helpers.assert_nil(Restarter.under_unit())
			local how = Restarter.restart({ wrapper = "/x", args = {}, pid = 4242, start_tick = "1337",
				run = function() calls = calls + 1; return true end })
			helpers.assert_nil(how)
			helpers.assert_eq(calls, 0, "unreadable cgroup must not dispatch a guessed relay")
			local daemon = helpers.load_module("infra.daemon_restart")
			local outer = daemon.restart({ reason = "test", args = {},
				installation = function() return { kind = "standalone", wrapper = "/x" } end,
				run = function() calls = calls + 1; return true end })
			helpers.assert_nil(outer)
			helpers.assert_eq(calls, 0, "the daemon must also refuse an unknown cgroup")
		end)
		io.open = original_open
		if not ok then error(detail, 0) end
	end)

	helpers.it("(restart-cgroup-invalid) refuses empty or malformed cgroup records", function()
		for _, cgroup in ipairs({ "", "invalid", "0::relative\n", UNIT_CGROUP .. "broken\n", "0::/\n\n", "0::/unit\r\n" }) do
			local calls = 0
			helpers.assert_nil(Restarter.under_unit(cgroup), "invalid native records cannot identify the route")
			local how = Restarter.restart({ wrapper = "/x", args = {}, cgroup = cgroup, pid = 4242,
				start_tick = "1337", run = function() calls = calls + 1; return true end })
			helpers.assert_nil(how)
			local daemon = helpers.load_module("infra.daemon_restart")
			local outer = daemon.restart({ reason = "test", args = {}, cgroup = cgroup,
				installation = function() return { kind = "standalone", wrapper = "/x" } end,
				run = function() calls = calls + 1; return true end })
			helpers.assert_nil(outer)
			helpers.assert_eq(calls, 0)
		end
	end)

	helpers.it("(restart-relay-pid-reuse) refuses relay dispatch without a valid start tick", function()
		local calls = 0
		local how = Restarter.restart({ wrapper = "/x", cgroup = TERMINAL_CGROUP, pid = 4242,
			start_tick = "invalid", run = function() calls = calls + 1; return true end })
		helpers.assert_nil(how)
		helpers.assert_eq(calls, 0, "uncertain process identity must not arm a relay")
	end)

	helpers.it("reports a restart it could not start", function()
		helpers.assert_nil(Restarter.restart({ wrapper = "/x", cgroup = UNIT_CGROUP, run = function() return false end }))
		helpers.assert_nil(Restarter.restart({ wrapper = "/x", cgroup = TERMINAL_CGROUP, pid = 1,
			run = function() return false end }))
	end)

	helpers.it("reads its process id from its stat line, and its unit from its cgroup", function()
		helpers.assert_eq(Restarter.own_pid(SELF_STAT), 4242)
		helpers.assert_eq(Restarter.process_start_time(4242, SELF_STAT), "1337")
		local unusual = SELF_STAT:gsub("%(luajit%)", "(name) with\nparentheses)")
		helpers.assert_eq(Restarter.process_start_time(4242, unusual), "1337")
		helpers.assert_eq(Restarter.process_start_time(4242, "4242 (name with ) parentheses) S 1"), nil)

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
		local mb = helpers.load_module("ui.menu.builder")
		local ctx = { _version = "test", on_quit = function() end, updater = fake }
		for key, value in pairs(ctx_extra) do ctx[key] = value end
		local title = require("core.i18n.engine.i18n").get("menu.about.title")
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
		fake.check_for_updates = function(_, callback)
			callback(false, nil, nil, { state = "up_to_date", channel = "dev", current = "0.0.0-dev.133", others = {} })
			return true
		end
		local told = nil
		local saved = package.loaded["ui.update_check.bridge"]
		package.loaded["ui.update_check.bridge"] = { open = function() return false end }
		local rows = updates_rows(fake, { on_update_checked = function(...) told = { ... } end })
		for _, row in ipairs(rows) do
			if row.title == "check" then row.fn() end
		end
		package.loaded["ui.update_check.bridge"] = saved
		helpers.assert_true(told ~= nil, "the daemon is told, and redraws the menu")
		helpers.assert_eq(told[1].state, "up_to_date", "with the check's structured answer (UPL-002)")
	end)

	helpers.it("installs a downloaded update and hands the result on for the restart", function()
		local release = { tag = "v0.0.0-dev.134" }
		local fake = fake_updater("available", release)
		local installed_from = nil
		fake.download_update = function(_, callback) callback("/tmp/update.tar.gz", nil); return true end
		fake.install_update = function(path) installed_from = path; return true end
		local finished = nil
		local rows = updates_rows(fake, { on_update_finished = function(...) finished = { ... } end })
		local label = require("core.i18n.engine.i18n").get("menu.about.update_now"):gsub("{tag}", release.tag)
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
		local label = require("core.i18n.engine.i18n").get("menu.about.update_now"):gsub("{tag}", shown.tag)
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
		local i18n = require("core.i18n.engine.i18n")
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
		local label = require("core.i18n.engine.i18n").get("menu.about.update_now"):gsub("{tag}", "v0.0.0-dev.134")
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


helpers.describe("Main restart pause wiring", function()
	local function main_source()
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		return source
	end

	helpers.it("passes pause through both actual Main helpers", function()
		local source = main_source()
		for _, name in ipairs({ "restart_daemon", "restart_on_installed_release" }) do
			local first = assert(source:find("local function " .. name .. "(", 1, true))
			local last = assert(source:find("\nend\n", first, true))
			local text = source:sub(first, last + 4):gsub("^local function " .. name, "return function", 1)
			local received, shutdowns
			local environment = setmetatable({ arg = { "--tray", "space ' apostrophe" },
				updater = { installed_launcher = function() return "/installed/launcher" end,
					installed_root = function() return "/installed" end },
				shutdown = { request = function() shutdowns = true end },
				require = function(module)
					helpers.assert_true(module == "infra.daemon_restart" or module == "modules.updater.restarter")
					return { restart = function(opts) received = opts; return "relay" end }
				end }, { __index = _G })
			local chunk
			if loadstring then chunk = assert(loadstring(text)); setfenv(chunk, environment)
			else chunk = assert(load(text, "Main restart pause helper", "t", environment)) end
			local helper = chunk()
			if name == "restart_daemon" then helpers.assert_true(helper("configuration restored", true))
			else helpers.assert_true(helper(true)) end
			helpers.assert_eq(received.paused, true, "the Main helper must forward live pause")
			helpers.assert_eq(received.args, { "--tray", "space ' apostrophe" })
			if name == "restart_on_installed_release" then
				-- The installed tree is watched until its daemon reports ready.
				helpers.assert_eq(received.successor, { root = "/installed" })
			end
			helpers.assert_true(shutdowns)
		end
	end)

	helpers.it("captures current pause at all three complete-restart callsites", function()
		local source = main_source()
		local _, update_calls = source:gsub("restart_on_installed_release%(script_actions%.is_paused%(%)%)", "")
		helpers.assert_eq(update_calls, 2, "both update completion and Versions must pass live controller state")
		helpers.assert_contains(source,
			"restart = function(reason) return restart_daemon(reason, script_actions.is_paused()) end",
			"wizard and restore share the controller-local restart closure")
	end)
end)
