--- tests/unit/infra/lifecycle/test_updater_boot_ready.lua

--- ==============================================================================
--- MODULE: Updater boot ready (linux-update-successor-ready)
--- DESCRIPTION:
--- The Linux update restart started the new daemon without knowing whether it
--- came up; Windows keeps a new build only once its boot signals ready. The
--- daemon must write its pid to the watcher's token once, atomically, only for
--- a token of the watcher's shape, treat a token whose watcher is gone as
--- harmless, and report once it is ready.
--- ==============================================================================

local helpers = require("tests.helpers")

local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end

local function read(path)
	local handle = io.open(path, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Runs body against a fresh reporter and a scratch token folder.
--- @param body function Receives the reporter, the folder and a deps builder.
local function with_reporter(body)
	package.loaded["infra.updater_boot_ready"] = nil
	local Ready = require("infra.updater_boot_ready")
	local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
	local dir = base .. "/ergopti-boot-ready." .. tostring(os.time()) .. tostring(math.random(1e6))
	assert(os.execute("mkdir -p " .. quote(dir)))
	local env = { ERGOPTI_UPDATER_BOOT_READY = dir .. "/ready" }
	local function deps(extra)
		local d = { getenv = function(name) return env[name] end, pid = 4242 }
		for k, v in pairs(extra or {}) do d[k] = v end
		return d
	end
	local ok, err = xpcall(body, debug.traceback, Ready, dir, deps, env)
	os.execute("rm -rf " .. quote(dir))
	package.loaded["infra.updater_boot_ready"] = nil
	if not ok then error(err, 0) end
end

helpers.describe("updater boot ready (linux-update-successor-ready)", function()
	helpers.it("(update-successor-watch) writes the daemon pid to the watcher's token once", function()
		with_reporter(function(Ready, dir, deps)
			helpers.assert_eq(Ready.report("daemon ready", deps()), true)
			helpers.assert_eq(read(dir .. "/ready"), "4242\n")
			helpers.assert_nil(read(dir .. "/ready.tmp"), "no temporary file is left behind")
			os.remove(dir .. "/ready")
			helpers.assert_eq(Ready.report("daemon ready", deps()), false, "one report per daemon")
			helpers.assert_nil(read(dir .. "/ready"))
		end)
	end)

	helpers.it("(update-successor-watch) publishes through a rename", function()
		with_reporter(function(Ready, dir, deps)
			local renames = 0
			helpers.assert_eq(Ready.report("daemon ready", deps({ rename = function(from, to)
				renames = renames + 1
				helpers.assert_eq(from, dir .. "/ready.tmp")
				helpers.assert_nil(read(to), "the token appears only by the rename")
				return os.rename(from, to)
			end })), true)
			helpers.assert_eq(renames, 1)
		end)
	end)

	helpers.it("(update-successor-watch) ignores a missing, foreign or stale token", function()
		with_reporter(function(Ready, dir, deps, env)
			env.ERGOPTI_UPDATER_BOOT_READY = nil
			helpers.assert_eq(Ready.report("daemon ready", deps()), false)
			for _, token in ipairs({ dir .. "/elsewhere", "/etc/x/ready", "relative/ready",
				dir .. "/../ergopti-boot-ready.y/ready" }) do
				Ready.reset_for_tests()
				env.ERGOPTI_UPDATER_BOOT_READY = token
				helpers.assert_eq(Ready.report("daemon ready", deps()), false, token)
			end
			Ready.reset_for_tests()
			env.ERGOPTI_UPDATER_BOOT_READY = dir .. "/ready"
			os.execute("rm -rf " .. quote(dir))
			helpers.assert_eq(Ready.report("daemon ready", deps()), false, "a watcher that decided removed its folder")
		end)
	end)

	helpers.it("(update-successor-watch) the daemon reports once ready and the update restart is watched", function()
		local source = assert(helpers.read_module_source("ergopti_hotstrings"))
		local complete_at = source:find("local boot_ms = BootProfiler.complete()", 1, true)
		helpers.assert_true(complete_at ~= nil)
		helpers.assert_true(source:find('require("infra.updater_boot_ready").report("daemon ready")', complete_at, true) ~= nil,
			"the daemon reports ready after its boot completes")
		helpers.assert_true(source:find("successor = root and { root = root } or nil", 1, true) ~= nil,
			"the restart on an installed release names the installation it watches")
	end)
end)
