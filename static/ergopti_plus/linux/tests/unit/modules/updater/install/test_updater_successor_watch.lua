--- tests/unit/modules/updater/install/test_updater_successor_watch.lua

--- ==============================================================================
--- MODULE: Updated daemon start watch (linux-update-successor-ready)
--- DESCRIPTION:
--- After an update the Linux restart only smoked the wrapper and asked systemd
--- or a relay to start the new daemon; nothing checked that it came up. The
--- Windows swap keeps a new build only once it signals boot-ready and survives
--- a probation. The watcher must keep an installation whose daemon reports its
--- pid and lives on, and otherwise stop it, move it aside, put the previous
--- installation back and start that one; a Quit or a refused restart must
--- never trigger that rollback.
--- ==============================================================================

local helpers = require("tests.helpers")
local Restarter = require("modules.updater.restarter")

local UNIT_CGROUP = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/ergopti-hotstrings.service\n"

local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function write(path, text)
	local handle = assert(io.open(path, "wb"))
	handle:write(text)
	handle:close()
end

--- Builds an installation root, its previous copy and a fresh token.
--- @param opts table { reporter? } whether the new tree carries the boot reporter.
--- @return table scenario
local function scenario(opts)
	local dir = os.tmpname()
	os.remove(dir)
	assert(os.execute("mkdir -p " .. quote(dir .. "/install/linux/infra") .. " " .. quote(dir .. "/install.old")))
	write(dir .. "/install/marker", "new")
	write(dir .. "/install.old/marker", "old")
	if opts.reporter ~= false then write(dir .. "/install/linux/infra/updater_boot_ready.lua", "-- reporter\n") end
	local token = Restarter.allocate_token()
	assert(token, "a token folder must be allocated")
	return { dir = dir, root = dir .. "/install", token = token, log = dir .. "/watch.log", runs = dir .. "/runs" }
end

--- Writes a stand-in launcher: it records each run and reports pid to the token or stays silent.
--- @param s table Scenario.
--- @param report string|nil "self", a literal pid, or nil for none.
--- @return string path
local function launcher(s, report)
	local path = s.dir .. "/launcher"
	local lines = { "#!/bin/sh", "echo run >> " .. quote(s.runs) }
	if report == "self" then
		lines[#lines + 1] = 'if [ -n "$ERGOPTI_UPDATER_BOOT_READY" ]; then echo $$ > "$ERGOPTI_UPDATER_BOOT_READY.tmp"; mv "$ERGOPTI_UPDATER_BOOT_READY.tmp" "$ERGOPTI_UPDATER_BOOT_READY"; fi'
		lines[#lines + 1] = "echo $$ > " .. quote(s.dir .. "/daemon.pid")
		lines[#lines + 1] = "exec sleep 3"
	elseif report then
		lines[#lines + 1] = 'if [ -n "$ERGOPTI_UPDATER_BOOT_READY" ]; then echo ' .. report .. ' > "$ERGOPTI_UPDATER_BOOT_READY"; fi'
	end
	write(path, table.concat(lines, "\n") .. "\n")
	assert(os.execute("chmod +x " .. quote(path)))
	return path
end

--- Runs the watcher with a short wait so a silent daemon fails fast.
--- @param mode string "relay" or "systemd".
--- @param s table Scenario.
--- @param tail table Launcher argv (relay) or unit (systemd).
--- @param env string|nil Shell prefix (PATH override).
--- @return boolean exited_zero
local function watch(mode, s, tail, env)
	local original = Restarter.WATCH_SCRIPT
	Restarter.WATCH_SCRIPT = original:gsub('%[ "%$ready_ticks" %-gt %d+ %]', '[ "$ready_ticks" -gt 5 ]')
	local command = Restarter.watch_command(mode, { root = s.root, token = s.token, log = s.log }, tail)
	Restarter.WATCH_SCRIPT = original
	local ok = os.execute((env or "") .. command .. " >/dev/null 2>&1")
	return ok == true or ok == 0
end

local function runs(s)
	local _, count = (read(s.runs) or ""):gsub("run\n", "")
	return count
end

local function cleanup(s)
	local pid = (read(s.dir .. "/daemon.pid") or ""):match("^(%d+)")
	if pid then os.execute("kill " .. pid .. " >/dev/null 2>&1") end
	os.execute("rm -rf " .. quote(s.dir) .. " " .. quote((s.token:gsub("/ready$", ""))))
end

helpers.describe("updated daemon start watch (linux-update-successor-ready)", function()
	helpers.it("(update-successor-watch) keeps the installation once the daemon reports ready and survives the probation", function()
		local s = scenario({})
		local ok = watch("relay", s, { launcher(s, "self") })
		helpers.assert_eq(ok, true, tostring(read(s.log)))
		helpers.assert_eq(read(s.root .. "/marker"), "new")
		helpers.assert_eq(read(s.root .. ".old/marker"), "old", "the previous installation stays as the backup")
		helpers.assert_eq(runs(s), 1)
		helpers.assert_contains(read(s.log) or "", "reported a healthy start")
		helpers.assert_nil(read(s.token), "the token folder is removed once decided")
		cleanup(s)
	end)

	helpers.it("(update-successor-watch) puts the previous installation back and starts it when the daemon never reports", function()
		local s = scenario({})
		watch("relay", s, { launcher(s, nil) })
		helpers.assert_eq(read(s.root .. "/marker"), "old", "the previous installation is back")
		local log = read(s.log) or ""
		local failed = log:match("the new one is at (%S+)%.\n")
		helpers.assert_true(failed ~= nil, log)
		helpers.assert_eq(read(failed .. "/marker"), "new", "the build that did not start is kept aside")
		helpers.assert_contains(log, "did not start (no boot report)")
		helpers.assert_eq(runs(s), 2, "the new launcher, then the previous one in its place")
		cleanup(s)
	end)

	helpers.it("(update-successor-watch) rolls back a daemon that quits during the probation or reports garbage", function()
		for _, case in ipairs({ { "999999999", "quit during the probation" }, { "x1", "an invalid boot report" } }) do
			local s = scenario({})
			watch("relay", s, { launcher(s, case[1]) })
			helpers.assert_eq(read(s.root .. "/marker"), "old", case[2])
			helpers.assert_contains(read(s.log) or "", case[2])
			cleanup(s)
		end
	end)

	helpers.it("(update-successor-watch) only starts an installation that predates the boot reporter", function()
		local s = scenario({ reporter = false })
		watch("relay", s, { launcher(s, nil) })
		helpers.assert_eq(read(s.root .. "/marker"), "new", "an older release cannot report and is kept as before")
		helpers.assert_eq(runs(s), 1)
		cleanup(s)
	end)

	helpers.it("(update-successor-watch) under systemd, stops the unit, restores and starts it again", function()
		local s = scenario({})
		local calls = s.dir .. "/systemctl.calls"
		assert(os.execute("mkdir -p " .. quote(s.dir .. "/bin")))
		write(s.dir .. "/bin/systemctl", "#!/bin/sh\necho \"$*\" >> " .. quote(calls) .. "\n")
		assert(os.execute("chmod +x " .. quote(s.dir .. "/bin/systemctl")))
		watch("systemd", s, { Restarter.UNIT }, "PATH=" .. quote(s.dir .. "/bin") .. ":\"$PATH\" ")
		helpers.assert_eq(read(s.root .. "/marker"), "old")
		helpers.assert_eq(read(calls), "--user stop " .. Restarter.UNIT .. "\n"
			.. "--user unset-environment ERGOPTI_UPDATER_BOOT_READY\n"
			.. "--user start " .. Restarter.UNIT .. "\n")
		cleanup(s)
	end)

	helpers.it("(update-successor-watch) arms the watcher outside the unit and hands the token through the manager", function()
		local ran = {}
		local how = Restarter.restart({ wrapper = "/opt/ergopti/bin/ergopti", args = {}, cgroup = UNIT_CGROUP,
			successor = { root = "/opt/ergopti/lib", log = "/tmp/watch.log" },
			run = function(cmd) ran[#ran + 1] = cmd; return true end })
		helpers.assert_eq(how, "systemd")
		helpers.assert_eq(#ran, 3, table.concat(ran, "\n"))
		helpers.assert_contains(ran[1], "systemctl --user set-environment 'ERGOPTI_UPDATER_BOOT_READY=")
		helpers.assert_contains(ran[2], "systemd-run --user --collect --quiet --unit='ergopti-update-watch-")
		helpers.assert_contains(ran[2], "update-watch systemd '/opt/ergopti/lib'")
		helpers.assert_eq(ran[3], "systemctl --user --no-block restart " .. Restarter.UNIT)
		-- A Quit replaces the restart: the watcher is stopped first, so it restores nothing.
		local cancelled = {}
		helpers.assert_eq(Restarter.cancel("systemd", { run = function(cmd) cancelled[#cancelled + 1] = cmd; return true end }), true)
		helpers.assert_contains(cancelled[1], "systemctl --user stop 'ergopti-update-watch-")
		helpers.assert_eq(cancelled[#cancelled], "systemctl --user --no-block stop " .. Restarter.UNIT)
	end)

	helpers.it("(update-successor-watch) stops the watcher of a restart systemd refused", function()
		local ran = {}
		local how = Restarter.restart({ wrapper = "/opt/ergopti/bin/ergopti", args = {}, cgroup = UNIT_CGROUP,
			successor = { root = "/opt/ergopti/lib", log = "/tmp/watch.log" },
			run = function(cmd) ran[#ran + 1] = cmd; return not cmd:find("restart", 1, true) end })
		helpers.assert_nil(how)
		helpers.assert_contains(ran[4], "systemctl --user stop 'ergopti-update-watch-")
		helpers.assert_eq(ran[5], "systemctl --user unset-environment ERGOPTI_UPDATER_BOOT_READY")
	end)

	helpers.it("(update-successor-watch) a relay starts the launcher under the watcher only after an update", function()
		local plain = Restarter.relay_command(42, "/opt/ergopti/bin/ergopti", { "--tray" }, nil, "7")
		helpers.assert_true(plain:find("update-watch", 1, true) == nil, "an ordinary restart is not watched")
		local watched = Restarter.relay_command(42, "/opt/ergopti/bin/ergopti", { "--tray" }, nil, "7",
			{ root = "/opt/ergopti/lib", token = "/tmp/ergopti-boot-ready.abc/ready", log = "/tmp/watch.log" })
		helpers.assert_contains(watched, "update-watch relay")
	end)
end)
