--- tests/unit/platform/remap/onboarding_install/test_cache_publication.lua

--- ==============================================================================
--- MODULE: Onboarding Installer cache publication
--- DESCRIPTION:
--- Exercises cache publication through the shared isolated native fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.onboarding_install_fixture")
local Scenario = require("tests.support.onboarding_install_scenarios")
local with_fixture = Fixture.with_fixture
local argument_after = Fixture.argument_after
local TEST_SHA = Fixture.TEST_SHA
local CACHE_PATH = Fixture.CACHE_PATH
local tasks_for_stage = Scenario.tasks_for_stage
local advance_to_stage = Scenario.advance_to_stage
local OTHER_PARTIAL = "/cache/unrelated-download.part"

--- Counts exact path occurrences in an array.
--- @param values string[] Recorded paths.
--- @param expected string Exact path.
--- @return number count
local function count_path(values, expected)
	local count = 0
	for _, value in ipairs(values) do
		if value == expected then count = count + 1 end
	end
	return count
end

helpers.describe("HS-011 onboarding cache publication", function()
	helpers.it("HS-011 consecutive attempts allocate distinct partial paths", function()
		with_fixture({ terminate_results = { download = { true, true } } },
			function(onboarding, calls)
				local first = advance_to_stage(onboarding, calls, "download")
				local first_partial = argument_after(first.args, "--output")
				helpers.assert_true(onboarding.stop() == false)
				first:complete(1, "", "cancelled")
				helpers.assert_nil(onboarding._install_owner)

				local second = advance_to_stage(onboarding, calls, "download")
				local second_partial = argument_after(second.args, "--output")
				helpers.assert_not_nil(first_partial)
				helpers.assert_not_nil(second_partial)
				helpers.assert_true(first_partial ~= second_partial,
					"each installer attempt must own a collision-free staging path")
			end)
	end)

	helpers.it("HS-011 stop removes only the owner unique partial", function()
		with_fixture({ files = { [OTHER_PARTIAL] = true } }, function(onboarding, calls, files)
			local task = advance_to_stage(onboarding, calls, "download")
			local output = argument_after(task.args, "--output")
			helpers.assert_not_nil(output)
			helpers.assert_true(output ~= CACHE_PATH)
			helpers.assert_true(output:match("%.part$") ~= nil,
				"download destination must be an attempt-unique .part path")
			helpers.assert_true(files[output] == true)

			helpers.assert_true(onboarding.stop() == false)
			task:complete(1, "", "cancelled")
			helpers.assert_true(files[output] ~= true,
				"the revoked owner must delete its own temporary bytes")
			helpers.assert_true(files[OTHER_PARTIAL] == true,
				"cleanup must never sweep a sibling attempt partial")
			helpers.assert_eq(count_path(calls.removes, OTHER_PARTIAL), 0)
		end)
	end)

	helpers.it("HS-011 checksum precedes atomic cache replacement without deleting the old cache", function()
		with_fixture({ files = { [CACHE_PATH] = true } }, function(onboarding, calls, files)
			helpers.assert_true(onboarding.install_karabiner_elements(function() end) ~= false)
			local cache_checksum = tasks_for_stage(calls, "checksum")[1]
			helpers.assert_not_nil(cache_checksum)
			cache_checksum:complete(0, string.rep("b", 64) .. "  cached.dmg\n", "")

			local download = tasks_for_stage(calls, "download")[1]
			helpers.assert_not_nil(download)
			local partial = argument_after(download.args, "--output")
			helpers.assert_true(partial ~= CACHE_PATH and partial:match("%.part$") ~= nil)
			helpers.assert_eq(count_path(calls.removes, CACHE_PATH), 0,
				"redownload must not unlink the previously published cache")
			helpers.assert_true(files[CACHE_PATH] == true)

			download:complete(0, "", "")
			local checksums = tasks_for_stage(calls, "checksum")
			helpers.assert_eq(#checksums, 2)
			checksums[2]:complete(0, TEST_SHA .. "  fresh.part\n", "")
			helpers.assert_eq(#calls.renames, 1)
			helpers.assert_eq(calls.renames[1].source, partial)
			helpers.assert_eq(calls.renames[1].destination, CACHE_PATH)
			helpers.assert_true(files[CACHE_PATH] == true)
			helpers.assert_true(files[partial] ~= true)
			helpers.assert_eq(#tasks_for_stage(calls, "mount"), 1,
				"mount may start only after checksum and atomic promotion commit")
		end)
	end)

	helpers.it("HS-011 rename refusal preserves the old cache and starts zero mounts", function()
		with_fixture({ files = { [CACHE_PATH] = true }, rename_refuses = true },
			function(onboarding, calls, files)
				local outcomes = {}
				helpers.assert_true(onboarding.install_karabiner_elements(function(ok, detail)
					outcomes[#outcomes + 1] = { ok = ok, detail = detail }
				end))
				local checksums = tasks_for_stage(calls, "checksum")
				checksums[1]:complete(0, string.rep("b", 64) .. "  old-cache.dmg\n", "")
				local download = tasks_for_stage(calls, "download")[1]
				local partial = argument_after(download.args, "--output")
				download:complete(0, "", "")
				checksums = tasks_for_stage(calls, "checksum")
				checksums[2]:complete(0, TEST_SHA .. "  verified.part\n", "")

				helpers.assert_eq(#outcomes, 1)
				helpers.assert_true(outcomes[1].ok == false)
				helpers.assert_true(files[CACHE_PATH] == true,
					"failed atomic promotion must preserve the prior published cache")
				helpers.assert_true(files[partial] ~= true,
					"a refused promotion must clean only the failed attempt partial")
				helpers.assert_eq(#tasks_for_stage(calls, "mount"), 0,
					"mount must remain fenced below successful atomic promotion")
				helpers.assert_eq(#calls.detaches, 0)
			end)
	end)

	helpers.it("HS-011 successful install settles one terminal callback and one detach", function()
		with_fixture({}, function(onboarding, calls)
			local outcomes = {}
			helpers.assert_true(onboarding.install_karabiner_elements(function(ok, err)
				outcomes[#outcomes + 1] = { ok = ok, err = err }
			end) ~= false)
			tasks_for_stage(calls, "download")[1]:complete(0, "", "")
			tasks_for_stage(calls, "checksum")[1]:complete(0, TEST_SHA .. "  fresh.part\n", "")
			tasks_for_stage(calls, "mount")[1]:complete(
				0, "/dev/disk9\tApple_HFS\t/Volumes/Karabiner Test\n", "")
			tasks_for_stage(calls, "install")[1]:complete(0, "", "")

			helpers.assert_eq(#outcomes, 1)
			helpers.assert_true(outcomes[1].ok == true)
			helpers.assert_nil(outcomes[1].err)
			helpers.assert_eq(#calls.detaches, 1)
			helpers.assert_nil(onboarding._install_owner)
			helpers.assert_true(onboarding.stop() == true)
		end)
	end)
end)
