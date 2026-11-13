--- tests/unit/core/lifecycle/engine/test_updater_boot_ready.lua

--- ==============================================================================
--- MODULE: Updater boot ready (release-successor-boot-ready)
--- DESCRIPTION:
--- The macOS release swap renamed the chosen app in and opened it, without
--- knowing whether it started; Windows keeps a new build only once its boot
--- signals ready. The boot must write the launcher pid to the swap's token
--- once, atomically, only for a token of the swap's shape, and treat a token
--- whose swap is gone as harmless.
--- ==============================================================================

local helpers = require("tests.helpers")

local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end

--- Runs body against a fresh reporter and a scratch token folder.
--- @param body function Receives the reporter, the folder and an environment table.
local function with_reporter(body)
	package.loaded["updater.engine.boot_ready"] = nil
	local Ready = require("updater.engine.boot_ready")
	local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
	local dir = base .. "/ergopti-boot-ready." .. tostring(os.time()) .. tostring(math.random(1e6))
	assert(os.execute("mkdir -p " .. quote(dir)))
	local env = { ERGOPTI_LAUNCHER_PID = "4242", ERGOPTI_UPDATER_BOOT_READY = dir .. "/ready" }
	local ok, err = xpcall(body, debug.traceback, Ready, dir, env)
	os.execute("rm -rf " .. quote(dir))
	package.loaded["updater.engine.boot_ready"] = nil
	if not ok then error(err, 0) end
end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

helpers.describe("updater boot ready (release-successor-boot-ready)", function()
	helpers.it("writes the launcher pid to the swap's token once", function()
		with_reporter(function(Ready, dir, env)
			local deps = { getenv = function(name) return env[name] end }
			helpers.assert_eq(Ready.report("boot complete", deps), true)
			helpers.assert_eq(read(dir .. "/ready"), "4242\n")
			helpers.assert_nil(read(dir .. "/ready.tmp"), "no temporary file is left behind")
			os.remove(dir .. "/ready")
			helpers.assert_eq(Ready.report("boot complete", deps), false, "one report per boot")
			helpers.assert_nil(read(dir .. "/ready"))
		end)
	end)

	helpers.it("(update-quit-kept) a user exit writes the quit report once, even after the ready report", function()
		with_reporter(function(Ready, dir, env)
			local deps = { getenv = function(name) return env[name] end }
			helpers.assert_eq(Ready.report("boot complete", deps), true)
			helpers.assert_eq(Ready.report_quit("menu_quit", deps), true, "a Quit in the probation still counts")
			helpers.assert_eq(read(dir .. "/ready"), Ready.QUIT_REPORT .. "\n")
			helpers.assert_nil(read(dir .. "/ready.tmp"), "no temporary file is left behind")
			helpers.assert_eq(Ready.report_quit("menu_quit", deps), false, "one Quit report per boot")
			Ready.reset_for_tests()
			env.ERGOPTI_UPDATER_BOOT_READY = "/tmp/elsewhere/ready"
			helpers.assert_eq(Ready.report_quit("menu_quit", deps), false, "a foreign token is never written")
			env.ERGOPTI_UPDATER_BOOT_READY = nil
			helpers.assert_eq(Ready.report_quit("menu_quit", deps), false, "no swap, no report")
		end)
	end)

	helpers.it("publishes through a rename, so the swap never reads a partial pid", function()
		with_reporter(function(Ready, dir, env)
			local renames = {}
			local deps = {
				getenv = function(name) return env[name] end,
				rename = function(from, to)
					renames[#renames + 1] = { from, to }
					helpers.assert_nil(read(to), "the token appears only by the rename")
					return os.rename(from, to)
				end,
			}
			helpers.assert_eq(Ready.report("waiting for Accessibility", deps), true)
			helpers.assert_eq(#renames, 1)
			helpers.assert_eq(renames[1][1], dir .. "/ready.tmp")
		end)
	end)

	helpers.it("does nothing without a swap and refuses a token of another shape", function()
		with_reporter(function(Ready, dir, env)
			env.ERGOPTI_UPDATER_BOOT_READY = nil
			helpers.assert_eq(Ready.report("boot complete", { getenv = function(name) return env[name] end }), false)
			for _, token in ipairs({ dir .. "/elsewhere", "/etc/ergopti-boot-ready.x/ready", "relative/ready",
				dir .. "/../ergopti-boot-ready.y/ready" }) do
				Ready.reset_for_tests()
				env.ERGOPTI_UPDATER_BOOT_READY = token
				helpers.assert_eq(Ready.report("boot complete", { getenv = function(name) return env[name] end }), false,
					token)
			end
			helpers.assert_nil(read(dir .. "/elsewhere"))
		end)
	end)

	helpers.it("treats a token whose swap is gone as harmless", function()
		with_reporter(function(Ready, dir, env)
			os.execute("rm -rf " .. quote(dir))
			helpers.assert_eq(Ready.report("boot complete", { getenv = function(name) return env[name] end }), false)
		end)
	end)

	helpers.it("the boot reports at boot complete and when it hands over to the user", function()
		local unit, err = helpers.read_driver_unit("Boot.complete()")
		helpers.assert_true(unit ~= nil, tostring(err))
		local complete_at = unit:find("Boot.complete()\n", 1, true)
		helpers.assert_true(complete_at ~= nil and unit:find(
			'require("updater.engine.boot_ready").report("boot complete")', complete_at, true) ~= nil,
			"boot complete reports ready")
		helpers.assert_true(unit:find('report("waiting for Accessibility")', 1, true) ~= nil,
			"a new signature's Accessibility wait is a healthy start")
		helpers.assert_true(unit:find('report("onboarding")', 1, true) ~= nil, "onboarding is a healthy start")
	end)

	helpers.it("(update-quit-kept) every user quit of the boot reports to the release swap", function()
		local unit, err = helpers.read_driver_unit("Boot.complete()")
		helpers.assert_true(unit ~= nil, tostring(err))
		-- Menu Quit, the Quit action and uninstall go through request_user_exit.
		helpers.assert_true(unit:find("report_update_quit = function(reason)\n"
			.. '\t\t\t\treturn require("updater.engine.boot_ready").report_quit(reason)', 1, true) ~= nil,
			"the termination coordinator reports a user exit")
		local shutdown_at = unit:find("local function shutdown_all_resources", 1, true)
		helpers.assert_true(shutdown_at ~= nil and unit:find(
			'require("updater.engine.boot_ready").report_quit("hammerspoon_quit")', shutdown_at, true) ~= nil,
			"quitting the launcher or Hammerspoon reports too")
	end)

	helpers.it("refuses to report without the launcher pid", function()
		with_reporter(function(Ready, dir, env)
			env.ERGOPTI_LAUNCHER_PID = "0x10"
			helpers.assert_eq(Ready.report("boot complete", { getenv = function(name) return env[name] end }), false)
			helpers.assert_nil(read(dir .. "/ready"))
		end)
	end)
end)
