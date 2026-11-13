--- tests/unit/keyboard/engine/runtime_install/test_runtime_install.lua

--- ==============================================================================
--- MODULE: Owned Runtime First Install
--- DESCRIPTION:
--- Pins keyboard/adapters/runtime/install.lua with fake ports: the confirmed
--- install runs the signed launcher's install role once, reads its one answer
--- line, and only after the helper's full success asks pqrs' manager to
--- activate the driver.
---
--- ROOT CAUSE ENCODED: nothing could install the owned runtime, so a Mac
--- without a hand-installed runtime stayed at `runtime_not_installed` with its
--- tap-holds off (ADR 011, WP8). A half-finished helper reported as installed,
--- a cancelled prompt reported as a failure, or an activation before the
--- install would each mislead the user.
--- ==============================================================================

local helpers = require("tests.helpers")

local LAUNCHER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"

--- Builds an installer over a fake Mac.
--- @param answer function fn() -> code, stdout of the launcher role.
--- @param overrides table|nil { launcher, manager_present, manager_code }.
--- @return table installer
--- @return table world { commands }
--- @return table Install The module.
local function fake(answer, overrides)
	overrides = overrides or {}
	package.loaded["keyboard.adapters.runtime.install"] = nil
	local Install = require("keyboard.adapters.runtime.install")
	local world = { commands = {} }
	local installer = Install.new({
		launcher = overrides.launcher or function() return LAUNCHER, nil, { ERGOPTI_LAUNCHER_EXECUTABLE = LAUNCHER } end,
		exists = function(path)
			if path == Install.DAEMON then return overrides.daemon_present ~= false end
			return overrides.manager_present ~= false
		end,
		fetch_driver = function(callback)
			world.fetches = (world.fetches or 0) + 1
			callback(overrides.fetch_ok ~= false, overrides.fetch_ok == false and "vhid_update_download_failed" or nil, "offline")
		end,
		exec = function(executable, args, timeout, callback, environment)
			world.commands[#world.commands + 1] = { executable = executable, args = args, timeout = timeout,
				environment = environment }
			if executable == LAUNCHER then return callback(answer()) end
			callback(overrides.manager_code or 0, "", "")
		end,
	})
	return installer, world, Install
end

--- Runs one install and returns its settlement.
local function install(installer)
	local result
	installer.install(function(ok, reason, detail) result = { ok = ok, reason = reason, detail = detail } end)
	return assert(result, "the install must settle")
end

helpers.describe("owned runtime first install", function()
	helpers.it("runs the launcher role, then asks pqrs' manager to activate the driver", function()
		local installer, world, Install = fake(function()
			return 0, "OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired\n"
		end)
		local result = install(installer)
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(#world.commands, 2)
		helpers.assert_eq(world.commands[1].executable, LAUNCHER)
		helpers.assert_eq(world.commands[1].args[1], "--request-owned-runtime-install")
		helpers.assert_eq(#world.commands[1].args, 1)
		helpers.assert_eq(world.commands[1].environment.ERGOPTI_LAUNCHER_EXECUTABLE, LAUNCHER)
		helpers.assert_eq(world.commands[1].timeout, Install.INSTALL_TIMEOUT_SEC)
		helpers.assert_eq(world.commands[2].executable, require("keyboard.adapters.runtime.vhid_update").MANAGER)
		helpers.assert_eq(world.commands[2].args[1], "activate")
	end)

	helpers.it("names each refusal and never activates after one", function()
		local cases = {
			{ 0, "OWNED_RUNTIME_INSTALL|1|files-published-service-cleanup-pending\n", "install_cleanup_pending" },
			{ 1, "OWNED_RUNTIME_INSTALL_REQUEST|1|cancelled\n", "install_cancelled" },
			{ 77, "OWNED_RUNTIME_INSTALL_REQUEST|1|refused|launcher_unsigned\n", "install_refused", "launcher_unsigned" },
			{ 77, "OWNED_RUNTIME_INSTALL_REQUEST|1|refused|artifact_download_absent\n", "install_refused" },
			{ 75, "OWNED_RUNTIME_INSTALL_REQUEST|1|failed|77\n", "install_refused" },
			{ 75, "OWNED_RUNTIME_INSTALL_REQUEST|1|failed|75\n", "install_cleanup_pending" },
			{ 75, "OWNED_RUNTIME_INSTALL_REQUEST|1|failed|1\n", "install_failed" },
			{ 75, "OWNED_RUNTIME_INSTALL_REQUEST|1|failed|1|stage_signature\n", "install_failed",
				"administrator shell status 1 at step stage_signature" },
			{ 75, "OWNED_RUNTIME_INSTALL_REQUEST|1|failed|1|Stage\n", "install_unanswered" },
			{ 0, "", "install_unanswered" },
			{ 0, "OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired\nextra\n", "install_unanswered" },
			{ 1, "OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired\n", "install_unanswered" },
			{ 0, "OWNED_RUNTIME_INSTALL|1|files-published-staging-retired\n", "install_unanswered" },
		}
		for _, case in ipairs(cases) do
			local installer, world = fake(function() return case[1], case[2] end)
			local result = install(installer)
			helpers.assert_eq(result.ok, false, case[2])
			helpers.assert_eq(result.reason, case[3], case[2])
			if case[4] then helpers.assert_eq(result.detail, case[4]) end
			helpers.assert_eq(#world.commands, 1, "no activation after " .. case[2])
		end
	end)

	helpers.it("refuses without a launcher and when the manager is absent or fails", function()
		local installer, world = fake(function() error("unreachable") end,
			{ launcher = function() return nil, "no bundle" end })
		local result = install(installer)
		helpers.assert_eq(result.reason, "install_launcher_unavailable")
		helpers.assert_eq(#world.commands, 0)
		local success = function() return 0, "OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired\n" end
		helpers.assert_eq(install((fake(success, { manager_present = false }))).reason, "install_activation_failed")
		helpers.assert_eq(install((fake(success, { manager_code = 1 }))).reason, "install_activation_failed")
	end)

	helpers.it("downloads pqrs' driver first when none is installed, and stops when it cannot", function()
		-- The live helper carries no driver payload: the role installs the verified download.
		local success = function() return 0, "OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired\n" end
		local installer, world = fake(success, { daemon_present = false })
		helpers.assert_eq(install(installer).ok, true)
		helpers.assert_eq(world.fetches, 1)
		helpers.assert_eq(world.commands[1].executable, LAUNCHER, "the role runs after the download")
		local refused, refused_world = fake(function() error("unreachable") end, { daemon_present = false, fetch_ok = false })
		local result = install(refused)
		helpers.assert_eq(result.reason, "install_driver_failed")
		helpers.assert_eq(#refused_world.commands, 0, "no administrator prompt without the verified package")
		local present, present_world = fake(success)
		install(present)
		helpers.assert_nil(present_world.fetches, "an installed driver is not downloaded again")
		local digest = install((fake(function() return 75, "OWNED_RUNTIME_INSTALL_REQUEST|1|failed|78\n" end)))
		helpers.assert_eq(digest.reason, "install_driver_failed")
	end)

	helpers.it("lets a second caller wait for the running install", function()
		local pending
		package.loaded["keyboard.adapters.runtime.install"] = nil
		local installer = require("keyboard.adapters.runtime.install").new({
			launcher = function() return LAUNCHER end,
			exists = function() return true end,
			fetch_driver = function() error("the driver is installed: nothing to fetch") end,
			exec = function(executable, _, _, callback)
				if executable == LAUNCHER then pending = callback else callback(0, "", "") end
			end,
		})
		local results = {}
		installer.install(function(ok) results[#results + 1] = ok end)
		installer.install(function(ok) results[#results + 1] = ok end)
		pending(0, "OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired\n")
		helpers.assert_eq(#results, 2)
		helpers.assert_eq(results[1], true)
		helpers.assert_eq(results[2], true)
	end)
end)
