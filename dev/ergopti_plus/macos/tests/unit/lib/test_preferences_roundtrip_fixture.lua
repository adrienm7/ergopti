--- tests/unit/lib/test_preferences_roundtrip_fixture.lua

--- ==============================================================================
--- MODULE: Preferences Fixture Ownership Regressions
--- DESCRIPTION:
--- Observes real output cleanup and module restoration after semantic assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.preferences_roundtrip_fixture")

--- Verifies disk and module ownership without rescue cleanup hiding a failure.
--- @param fail boolean Injects a failed semantic assertion after real persistence.
local function check_ownership(fail)
	local previous_hs = _G.hs
	local previous_preferences = package.loaded["infra.preferences"]
	local previous_logger = package.loaded["infra.logger"]
	local output_path, sidecar_path
	local observed_output, observed_lock
	local outcome = table.pack(pcall(fixture.with_roundtrip, { delays = { rolls = 0.25 } },
		function(saved, preferences, path, lock_path)
			output_path, sidecar_path = path, lock_path
			helpers.assert_eq(saved.delays.rolls, 0.25, "real persisted data must reach assertions")
			helpers.assert_type(preferences.merge_saved_data, "function")
			local output = assert(io.open(path, "rb"))
			observed_output = output:read("*a")
			assert(output:close())
			local lock = assert(io.open(lock_path, "rb"))
			observed_lock = true
			assert(lock:close())
			if fail then error("injected preference assertion failure") end
			return "first", nil, "third"
		end))
	local remaining = {}
	for _, path in ipairs({ output_path, sidecar_path }) do
		local handle, reason, code = io.open(path, "rb")
		remaining[path] = handle ~= nil
		if handle then
			assert(handle:close())
			assert(os.remove(path))
		else
			assert(code == 2, "unexpected inspection failure: " .. tostring(reason))
		end
	end
	helpers.assert_type(output_path, "string", "the real callback must run")
	helpers.assert_true(observed_output:find("0.25", 1, true) ~= nil)
	helpers.assert_eq(observed_lock, true, "the real writer must create its stable sidecar")
	helpers.assert_eq(remaining[output_path], false, "output must be absent before rescue cleanup")
	helpers.assert_eq(remaining[sidecar_path], false, "sidecar must be absent before rescue cleanup")
	helpers.assert_true(rawequal(_G.hs, previous_hs), "restore native stub identity")
	helpers.assert_true(rawequal(package.loaded["infra.preferences"], previous_preferences), "restore preference module")
	helpers.assert_true(rawequal(package.loaded["infra.logger"], previous_logger), "restore logger module")
	helpers.assert_eq(outcome[1], not fail, tostring(outcome[2]))
	if fail then
		helpers.assert_true(tostring(outcome[2]):find("injected preference assertion failure", 1, true) ~= nil)
	else
		helpers.assert_eq(outcome.n, 4, "preserve nil callback return slots")
		helpers.assert_eq(outcome[2], "first")
		helpers.assert_nil(outcome[3])
		helpers.assert_eq(outcome[4], "third")
	end
end

helpers.describe("preferences roundtrip fixture ownership", function()
	for _, fail in ipairs({ false, true }) do
		helpers.it("(preferences-fixture-ownership) cleans after assertion failure=" .. tostring(fail), function()
			check_ownership(fail)
		end)
	end
end)
