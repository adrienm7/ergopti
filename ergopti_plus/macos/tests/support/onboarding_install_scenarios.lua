--- tests/support/onboarding_install_scenarios.lua

--- ==============================================================================
--- MODULE: Onboarding Installer Scenario Progression
--- DESCRIPTION:
--- Advances the real installer through the shared fixture and locates exact tasks.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local TEST_SHA = Fixture.TEST_SHA

--- Returns every constructed task for one stable stage.
--- @param calls table Fixture observations.
--- @param stage string Stable lifecycle stage.
--- @return table[] tasks
local function tasks_for_stage(calls, stage)
	local matches = {}
	for _, task in ipairs(calls.tasks) do
		if task.stage == stage then matches[#matches + 1] = task end
	end
	return matches
end

--- Advances a cache-miss install until the requested task is active.
--- @param onboarding table Onboarding module.
--- @param calls table Fixture observations.
--- @param target_stage string download | checksum | mount | install.
--- @param callback function|nil Public installer terminal observer.
--- @return table task Exact active task.
local function advance_to_stage(onboarding, calls, target_stage, callback)
	helpers.assert_true(onboarding.install_karabiner_elements(callback or function() end) ~= false)
	local downloads = tasks_for_stage(calls, "download")
	local download = downloads[#downloads]
	helpers.assert_not_nil(download, "the real pipeline must construct its download task")
	if target_stage == "download" then return download end

	download:complete(0, "", "")
	local checksums = tasks_for_stage(calls, "checksum")
	local checksum = checksums[#checksums]
	helpers.assert_not_nil(checksum, "download success must construct its checksum successor")
	if target_stage == "checksum" then return checksum end

	checksum:complete(0, TEST_SHA .. "  partial.dmg\n", "")
	local mounts = tasks_for_stage(calls, "mount")
	local mount = mounts[#mounts]
	helpers.assert_not_nil(mount, "verified bytes must construct their mount successor")
	if target_stage == "mount" then return mount end

	mount:complete(0, "/dev/disk9\tApple_HFS\t/Volumes/Karabiner Test\n", "")
	local installs = tasks_for_stage(calls, "install")
	local install = installs[#installs]
	helpers.assert_not_nil(install, "mounted package discovery must construct the installer successor")
	return install
end

return {
	tasks_for_stage = tasks_for_stage,
	advance_to_stage = advance_to_stage,
	CLEANUP_DEADLINE_PROBE_LIMIT = 10,
}
