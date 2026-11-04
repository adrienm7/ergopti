--- tests/unit/infra/lifecycle/test_dev_source.lua

--- ==============================================================================
--- MODULE: Developer Source Mode Tests
--- DESCRIPTION:
--- Since 0c954ed49a and a7bdb88a44 only the launcher's embedded runtime with
--- the managed log environment may run the driver, so a stock Hammerspoon
--- pointed at a clone stops at the native logger refusal. A developer
--- ErgoptiPlus.app (ERGOPTI_DEV_SOURCE=1) runs the clone in that runtime
--- instead. These tests prove the runtime recognises it exactly, treats it as a
--- source run (no update path can replace the app), still finds its launcher
--- helper and payload-only LuaSocket, and refuses a root that names another
--- tree.
--- ==============================================================================

local helpers = require("tests.helpers")
local DevSource = require("infra.dev_source")
local Admission = require("infra.instance_admission")

local CLONE = "/Users/maintainer/ergopti"
local DRIVER = CLONE .. "/static/ergopti_plus/macos"
local APP = "/Users/maintainer/ergopti/build/macos/ErgoptiPlus.app"
local RUNTIME = APP .. "/Contents/Frameworks/Hammerspoon.app"

--- An environment reader that answers only the developer root.
local function env(value)
	return function(name)
		if name == DevSource.ENVIRONMENT then return value end
		return nil
	end
end

--- Reads the one production file holding a unique marker, for wiring checks.
local function source(marker)
	return assert(helpers.read_driver_unit(marker))
end

helpers.describe("developer source mode: the runtime recognises its clone exactly", function()
	helpers.it("is inactive without the launcher's developer root", function()
		helpers.assert_eq(DevSource.resolve(env(nil), DRIVER), nil)
		helpers.assert_eq(DevSource.resolve(env(""), DRIVER), nil)
	end)

	helpers.it("admits the root that names this very driver", function()
		helpers.assert_eq(DevSource.resolve(env(CLONE), DRIVER), CLONE)
	end)

	helpers.it("raises for a root naming another tree or an unusable path", function()
		for _, value in ipairs({ "/Users/other/ergopti", "relative/ergopti", CLONE .. "/" }) do
			local ok, err = pcall(DevSource.resolve, env(value), DRIVER)
			helpers.assert_eq(ok, false, "developer root " .. value .. " must be refused")
			helpers.assert_contains(tostring(err), DevSource.ENVIRONMENT)
		end
		local ok = pcall(DevSource.resolve, env(CLONE), "/Applications/ErgoptiPlus.app/Contents/Resources"
			.. DevSource.DRIVER_SUBPATH)
		helpers.assert_eq(ok, false, "a packaged driver handed a clone root is an invalid state")
	end)

	helpers.it("is not active in an ordinary test or packaged process", function()
		helpers.assert_eq(DevSource.is_active(), false)
	end)
end)

helpers.describe("developer source mode: bundle-only resources come from the app payload", function()
	helpers.it("derives the launcher and payload from the embedded runtime bundle", function()
		helpers.assert_eq(DevSource.launcher_executable(RUNTIME), APP .. "/Contents/MacOS/ErgoptiPlus")
		helpers.assert_eq(DevSource.payload_driver_dir(RUNTIME), APP .. "/Contents/Resources" .. DevSource.DRIVER_SUBPATH)
		for _, foreign in ipairs({ nil, "/Applications/Hammerspoon.app", APP }) do
			helpers.assert_eq(DevSource.launcher_executable(foreign), nil)
			helpers.assert_eq(DevSource.payload_driver_dir(foreign), nil)
		end
	end)

	helpers.it("loads only LuaSocket from the payload, naming the file it read", function()
		local payload = DevSource.payload_driver_dir(RUNTIME)
		local files, libs = {}, {}
		local searcher = DevSource.payload_searcher(payload,
			function(path) files[#files + 1] = path; return function() return "socket" end end,
			function(path, entry) libs[#libs + 1] = path .. "#" .. entry; return function() return "core" end end)
		helpers.assert_eq(searcher("infra.logger"), nil, "a clone module must never come from the payload")
		helpers.assert_eq(searcher("socket.http"), nil)
		local loader, origin = searcher("socket")
		helpers.assert_eq(type(loader), "function")
		helpers.assert_eq(origin, payload .. "/socket.lua")
		searcher("socket.core")
		helpers.assert_eq(files[1], payload .. "/socket.lua")
		helpers.assert_eq(libs[1], payload .. "/socket/core.so#luaopen_socket_core")
	end)

	helpers.it("explains a missing payload module instead of loading anything else", function()
		local searcher = DevSource.payload_searcher("/missing", function() return nil, "no such file" end,
			function() return nil, "no such library" end)
		helpers.assert_contains(searcher("socket.core"), "/missing/socket/core.so: no such library")
		helpers.assert_contains(DevSource.payload_searcher(nil, loadfile, package.loadlib)("socket"),
			"runtime bundle not recognised")
	end)
end)

helpers.describe("developer source mode: a source run that no update can replace", function()
	helpers.it("makes the updater answer local source, which the admission admits", function()
		local saved = package.loaded["infra.dev_source"]
		package.loaded["infra.dev_source"] = { is_active = function() return true end }
		local ok, failure = xpcall(function()
			package.loaded["modules.updater"] = nil
			local updater = helpers.load_with_stubs("modules.updater", {
				processInfo = { bundleID = "com.ergoptiplus.app.hammerspoon", version = "1.1.1" },
			})
			helpers.assert_true(updater.is_local_source(),
				"the embedded bundle id alone must not make a clone look packaged")
			helpers.assert_eq(updater.current_version(), "local")
			helpers.assert_eq(Admission.decide("managed", not updater.is_local_source()), Admission.ADMIT)
		end, debug.traceback)
		package.loaded["infra.dev_source"] = saved
		package.loaded["modules.updater"] = nil
		if not ok then error(failure, 0) end
	end)

	helpers.it("keeps refusing a stray runtime, which never receives the developer root", function()
		helpers.assert_eq(Admission.decide("standalone", true), Admission.STRAY_RUNTIME)
	end)

	helpers.it("raises from the updater when the root names another tree", function()
		local saved = package.loaded["infra.dev_source"]
		package.loaded["infra.dev_source"] = { is_active = function() error("root mismatch", 0) end }
		local ok, failure = xpcall(function()
			package.loaded["modules.updater"] = nil
			local updater = helpers.load_with_stubs("modules.updater", {
				processInfo = { bundleID = "com.ergoptiplus.app.hammerspoon", version = "1.1.1" },
			})
			local answered = pcall(updater.is_local_source)
			helpers.assert_eq(answered, false, "an unanswerable identity is treated as foreign by init.lua")
		end, debug.traceback)
		package.loaded["infra.dev_source"] = saved
		package.loaded["modules.updater"] = nil
		if not ok then error(failure, 0) end
	end)
end)

helpers.describe("developer source mode: the launcher helper is found from the runtime bundle", function()
	helpers.it("derives the exact helper from hs.processInfo, then proves its identity", function()
		local saved = package.loaded["infra.dev_source"]
		package.loaded["infra.dev_source"] = {
			root = function() return CLONE end,
			launcher_executable = DevSource.launcher_executable,
		}
		local helper_path = APP .. "/Contents/MacOS/ErgoptiPlus"
		local identity = { mode = "file", permissions = "rwxr-xr-x", dev = 7, ino = 9 }
		local original_getenv = os.getenv
		local ok, failure = xpcall(function()
			package.loaded["platform.remap.lease_helper"] = nil
			local helper = helpers.load_with_stubs("platform.remap.lease_helper", {
				processInfo = { bundlePath = RUNTIME },
				fs = {
					symlinkAttributes = function(path) return path == helper_path and identity or nil end,
					attributes = function(path) return path == helper_path and identity or nil end,
					pathToAbsolute = function(path) return path end,
				},
			})
			os.getenv = function(name)
				if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return helper_path end
				if name == "ERGOPTI_LAUNCHER_DEVICE" then return "7" end
				if name == "ERGOPTI_LAUNCHER_INODE" then return "9" end
				return original_getenv(name)
			end
			local resolved, reason = helper.resolve()
			helpers.assert_eq(resolved, helper_path, tostring(reason))
			os.getenv = function(name)
				if name == "ERGOPTI_LAUNCHER_EXECUTABLE" then return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus" end
				return original_getenv(name)
			end
			local foreign, foreign_reason = helper.resolve()
			helpers.assert_eq(foreign, nil, "another app's launcher must not cross the spawn boundary")
			helpers.assert_contains(foreign_reason, "differs from the bundle-owned helper")
		end, debug.traceback)
		os.getenv = original_getenv
		package.loaded["infra.dev_source"] = saved
		package.loaded["platform.remap.lease_helper"] = nil
		if not ok then error(failure, 0) end
	end)
end)

helpers.describe("developer source mode: boot wiring", function()
	helpers.it("installs the payload searcher only for a developer root, before the admission", function()
		local init = source("DevSource.payload_searcher(payload, loadfile, package.loadlib)")
		local searcher = init:find("DevSource.payload_searcher(payload, loadfile, package.loadlib)", 1, true)
		local guard = init:find("if dev_ok and dev_root and searchers then", 1, true)
		local admission = init:find("local InstanceAdmission = require(\"infra.instance_admission\")", 1, true)
		helpers.assert_true(guard and searcher and admission and guard < searcher and searcher < admission,
			"LuaSocket must be reachable before the logger transport, and only in a developer app")
	end)

	helpers.it("watches the clone's shared Lua only in a developer app", function()
		local init = source("DevSource.payload_searcher(payload, loadfile, package.loadlib)")
		helpers.assert_contains(init,
			'shared_source_dir       = require("infra.dev_source").is_active() and (logger_shared_root .. "/lua") or nil')
		helpers.assert_contains(source("ctx.shared_source_dir ~= nil"),
			'acquire_watcher(ctx.shared_source_dir, project_changed, "Shared source watcher", false)')
	end)
end)
