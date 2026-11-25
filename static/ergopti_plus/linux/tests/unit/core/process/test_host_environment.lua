--- tests/unit/core/process/test_host_environment.lua

--- ==============================================================================
--- MODULE: Host Environment Restoration Tests (Linux)
--- DESCRIPTION:
--- The private runtime's launch environment reached every host program the
--- daemon started: the GIO module directory of the v1.0.9 AppImage reached
--- every GTK application xdg-open opened. Host programs now get the session's
--- environment back from the launcher's record; owned programs keep the bundle's.
--- ==============================================================================

local h = require("tests.helpers")

local PREFIX = "/tmp/.mount_ErgoX/usr"
local DRIVER = "/tmp/.mount_ErgoX/usr/lib/ergopti"

--- An os.getenv over a fixed table.
--- @param values table
--- @return function
local function getenv_of(values)
	return function(name) return values[name] end
end

--- The record the launcher leaves for a session with LUA_PATH set and no LUA_CPATH.
local LAUNCHED = {
	ERGOPTI_HOST_ENV_NAMES = "LUA_PATH LUA_CPATH CURL_CA_BUNDLE",
	ERGOPTI_HOST_ENV_SET_LUA_PATH = "/home/u/lua/?.lua;;",
	ERGOPTI_HOST_ENV_SET_CURL_CA_BUNDLE = "/etc/ssl/it's.pem",
	ERGOPTI_RUNTIME_PREFIX = PREFIX,
	ERGOPTI_HOST_ENV_DRIVER_ROOT = DRIVER,
}

--- Installs the restoration over recording io, os and luv stand-ins.
--- @return table seen { popen, execute, spawn }
local function install_recorded()
	local HostEnvironment = h.fresh_module("core.process.adapters.host_environment")
	local seen = { popen = {}, execute = {}, spawn = {} }
	local io_stub = { popen = function(command) seen.popen[#seen.popen + 1] = command; return "pipe" end }
	local os_stub = { execute = function(command) seen.execute[#seen.execute + 1] = command or "<probe>"; return 0 end }
	local luv_stub = {
		spawn = function(path, options) seen.spawn[#seen.spawn + 1] = { path = path, options = options } end,
		os_environ = function()
			return { HOME = "/home/u", LUA_PATH = PREFIX .. "/share/lua/5.1/?.lua;;", LUA_CPATH = PREFIX .. "/lib/?.so",
				CURL_CA_BUNDLE = "/etc/ssl/it's.pem", ERGOPTI_HOST_ENV_NAMES = LAUNCHED.ERGOPTI_HOST_ENV_NAMES,
				ERGOPTI_HOST_ENV_SET_LUA_PATH = LAUNCHED.ERGOPTI_HOST_ENV_SET_LUA_PATH }
		end,
	}
	h.assert_eq(true, HostEnvironment.install({ getenv = getenv_of(LAUNCHED), io = io_stub, os = os_stub,
		luv = luv_stub, logger = h.make_logger_stub() }))
	return seen, io_stub, os_stub, luv_stub, HostEnvironment
end

h.describe("host environment restoration", function()
	h.it("a source checkout has no launcher record and changes nothing", function()
		local HostEnvironment = h.fresh_module("core.process.adapters.host_environment")
		local io_stub = { popen = function() end }
		local popen = io_stub.popen
		h.assert_eq(false, HostEnvironment.install({ getenv = getenv_of({}), io = io_stub, os = {}, luv = {} }))
		h.assert_eq(popen, io_stub.popen)
	end)

	h.it("a host command gets the session's values back and loses the bundle's", function()
		local seen, io_stub, os_stub = install_recorded()
		io_stub.popen("setxkbmap -query", "r")
		os_stub.execute("xdg-open https://ergopti.fr")
		for _, command in ipairs({ seen.popen[1], seen.execute[1] }) do
			h.assert_eq(1, select(2, command:gsub("^unset ERGOPTI_HOST_ENV_NAMES ERGOPTI_HOST_ENV_SET_LUA_PATH "
				.. "ERGOPTI_HOST_ENV_SET_LUA_CPATH LUA_CPATH ERGOPTI_HOST_ENV_SET_CURL_CA_BUNDLE; ", "")))
			h.assert_true(command:find("export LUA_PATH='/home/u/lua/?.lua;;' "
				.. "CURL_CA_BUNDLE='/etc/ssl/it'\\''s.pem'; ", 1, true) ~= nil)
		end
		h.assert_true(seen.popen[1]:sub(-#"setxkbmap -query") == "setxkbmap -query")
	end)

	h.it("an owned program keeps the bundle environment", function()
		local seen, io_stub, os_stub = install_recorded()
		io_stub.popen("env LUA_PATH=x timeout -s KILL 2s '" .. PREFIX .. "/bin/luajit' -e 'x'", "r")
		os_stub.execute("bash '" .. DRIVER .. "/install/build_native_luv.sh'")
		os_stub.execute()
		h.assert_eq("env LUA_PATH=x timeout -s KILL 2s '" .. PREFIX .. "/bin/luajit' -e 'x'", seen.popen[1])
		h.assert_eq("bash '" .. DRIVER .. "/install/build_native_luv.sh'", seen.execute[1])
		h.assert_eq("<probe>", seen.execute[2])
	end)

	h.it("luv.spawn of a host program gets the restored environment, an owned one inherits", function()
		local seen, _, _, luv_stub = install_recorded()
		local options = { args = { "--user", "restart", "x" } }
		luv_stub.spawn("/usr/bin/systemctl", options)
		luv_stub.spawn(PREFIX .. "/bin/luajit", { args = { "worker.lua" } })
		luv_stub.spawn("/bin/sh", { args = { "-c", "'" .. PREFIX .. "/bin/curl' -V" } })
		luv_stub.spawn("/usr/bin/notify-send", { args = { "x" }, env = { "KEPT=1" } })
		h.assert_eq(nil, options.env, "the caller's options table is not modified")
		local env = seen.spawn[1].options.env
		h.assert_eq(table.concat({ "CURL_CA_BUNDLE=/etc/ssl/it's.pem", "HOME=/home/u", "LUA_PATH=/home/u/lua/?.lua;;" }, "|"),
			table.concat(env, "|"))
		h.assert_eq(nil, seen.spawn[2].options.env)
		h.assert_eq(nil, seen.spawn[3].options.env)
		h.assert_eq("KEPT=1", seen.spawn[4].options.env[1])
	end)

	h.it("a second install is refused", function()
		local _, _, _, _, HostEnvironment = install_recorded()
		local ok, err = pcall(HostEnvironment.install, { getenv = getenv_of(LAUNCHED), io = {}, os = {}, luv = {} })
		h.assert_eq(false, ok)
		h.assert_true(tostring(err):find("installed twice", 1, true) ~= nil)
	end)

	h.it("an invalid record is refused, never half-applied", function()
		local HostEnvironment = h.fresh_module("core.process.adapters.host_environment")
		local ok = pcall(HostEnvironment.read, getenv_of({ ERGOPTI_HOST_ENV_NAMES = "LUA_PATH; rm" }))
		h.assert_eq(false, ok)
	end)
end)

h.describe("tray library order", function()
	h.it("the recipient's libayatana is tried before the bundled fallback", function()
		local Indicator = h.fresh_module("tray.adapters.appindicator")
		local names = Indicator.indicator_candidates(PREFIX)
		h.assert_eq("ayatana-appindicator3.so.1", names[1])
		h.assert_eq(PREFIX .. "/lib/tray/libayatana-appindicator3.so.1", names[#names])
		h.assert_eq(#names - 1, #Indicator.indicator_candidates(nil))
	end)
end)
