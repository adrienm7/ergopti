--- tests/unit/platform/remap/onboarding_install/test_onboarding_owned_health.lua

--- ==============================================================================
--- MODULE: Onboarding Health Check Per Runtime
--- DESCRIPTION:
--- The owned runtime (ADR 011) needs no Karabiner-Elements application, so its
--- health check must not ask for one; the shared check must stay exactly what it
--- was.
---
--- ROOT CAUSE ENCODED: a single check that required
--- /Applications/Karabiner-Elements.app would report a healthy owned runtime as
--- broken and send the wizard to install the official application over it.
--- ==============================================================================

local helpers = require("tests.helpers")

local LISTING = "*\t*\tG43BCU2T37\torg.pqrs.Karabiner-DriverKit-VirtualHIDDevice (8.5.0/8.5.0)\tx\t[activated enabled]\n"

--- Loads a fresh onboarding module over a modelled Mac.
--- @param world table { files = set of paths, jobs = boolean, listing = string }.
--- @return table Onboarding module.
local function load_onboarding(world)
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.i18n"] = { get = function(k) return k end }
	package.loaded["infra.notifications"] = { notify = function() end }
	package.loaded["infra.dialog_util"] = { block_alert = function() return "later" end }
	package.loaded["platform.remap.onboarding"] = nil
	return helpers.load_with_stubs("platform.remap.onboarding", {
		execute = function(command)
			if command:find("launchctl", 1, true) then return "", world.jobs end
			if command:find("systemextensionsctl", 1, true) then return world.listing, true end
			return "", true
		end,
	})
end

--- Runs a body with io.open answering from a set of existing paths.
--- @param files table Set of paths.
--- @param body function Code to run.
local function with_files(files, body)
	local original = io.open
	io.open = function(path, mode)
		if files[path] then return { close = function() end } end
		return original(path, mode)
	end
	local ok, err = pcall(body)
	io.open = original
	if not ok then error(err, 0) end
end

local function complete_files()
	local owned = require("platform.remap.ke_paths").OWNED
	return { [owned.CLI] = true, [owned.CORE_SERVICE] = true, [owned.CONSOLE] = true, [owned.CORE_JOB_FILE] = true }
end

helpers.describe("onboarding health check per runtime", function()
	helpers.it("calls a complete owned runtime healthy without the official application", function()
		local world = { jobs = true, listing = LISTING }
		local onboarding = load_onboarding(world)
		with_files(complete_files(), function()
			local report = onboarding.health_check("owned")
			helpers.assert_eq(report, { runtime_installed = true, jobs_loaded = true, sysext_activated = true, all_ok = true })
			helpers.assert_nil(report.ke_installed)
		end)
	end)

	helpers.it("names each missing part of the owned runtime", function()
		local owned = require("platform.remap.ke_paths").OWNED
		local files = complete_files()
		files[owned.CONSOLE] = nil
		local onboarding = load_onboarding({ jobs = false, listing = "0 extension(s)\n" })
		with_files(files, function()
			local report = onboarding.health_check("owned")
			helpers.assert_eq(report.runtime_installed, false)
			helpers.assert_eq(report.jobs_loaded, false)
			helpers.assert_eq(report.sysext_activated, false)
			helpers.assert_eq(report.all_ok, false)
		end)
	end)

	helpers.it("keeps the shared check as it was and requires the official application", function()
		local onboarding = load_onboarding({ jobs = true, listing = LISTING })
		with_files(complete_files(), function()
			local report = onboarding.health_check()
			helpers.assert_eq(report.ke_installed, false)
			helpers.assert_eq(report.all_ok, false)
			helpers.assert_nil(report.runtime_installed)
			helpers.assert_eq(onboarding.health_check("shared").ke_installed, false)
		end)
	end)

	helpers.it("refuses an unknown runtime name", function()
		local onboarding = load_onboarding({ jobs = true, listing = LISTING })
		helpers.assert_throws(function() onboarding.health_check("both") end)
	end)
end)
