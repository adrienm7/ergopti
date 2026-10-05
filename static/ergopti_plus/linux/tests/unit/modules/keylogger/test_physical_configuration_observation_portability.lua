--- tests/unit/modules/keylogger/test_physical_configuration_observation_portability.lua
--- Proves shared numeric validation on the real LuaJIT runtime, without native capture.
local helpers = require("tests.helpers")
local Observation = require("keylogger.physical_configuration_observation")

local function configuration()
	return { private_filter_enabled = true, secure_field_filter_enabled = true,
		system_auth_filter_enabled = true, disabled_apps = {{ bundleID = "excluded.app" }} }
end

helpers.describe("shared physical configuration numeric portability", function()
	helpers.it("(physical-configuration-portability) copies actual selectors without requiring a Lua54 numeric subtype primitive", function()
		local original = configuration()
		local copied = Observation.copy(original)
		original.disabled_apps[1].bundleID = "caller.mutated"
		helpers.assert_eq(copied.disabled_apps[1].bundleID, "excluded.app")
	end)

	helpers.it("(physical-configuration-portability) publishes finite integral numbers and preserves exact clock ordering under LuaJIT", function()
		local receipts, failures, now = {}, 0, 100.0
		local channel = Observation.new(2.0, function() now = now + 1; return now end,
			function(record) receipts[#receipts + 1] = record; return true end,
			function() failures = failures + 1 end)
		helpers.assert_true(channel.publish(configuration()))
		helpers.assert_true(channel.publish(configuration()))
		helpers.assert_eq(#receipts, 2)
		helpers.assert_eq(receipts[1].at, 101); helpers.assert_eq(receipts[2].at, 102)
		helpers.assert_eq(receipts[1].revision, 1); helpers.assert_eq(receipts[2].revision, 2)
		helpers.assert_eq(channel.publish(configuration()), false)
		helpers.assert_eq(failures, 1); helpers.assert_eq(now, 102)
	end)

	helpers.it("(physical-configuration-portability) refuses nonfinite fractional and nonnumeric budgets before any port executes", function()
		for _, row in ipairs({ { value = 0 }, { value = -1 }, { value = 1.5 }, { value = math.huge },
			{ value = -math.huge }, { value = 0 / 0 }, { value = "2" }, { value = false }, { value = {} }, {} }) do
			local calls = 0
			local ok, reason = pcall(Observation.new, row.value, function() calls = calls + 1; return 100 end,
				function() calls = calls + 1; return true end, function() calls = calls + 1 end)
			helpers.assert_eq(ok, false); helpers.assert_eq(calls, 0)
			helpers.assert_true(tostring(reason):find("Invalid physical observation budget", 1, true) ~= nil)
		end
	end)

	helpers.it("(physical-configuration-portability) retires an invalid portable clock representation before publishing or repeated reads", function()
		for _, row in ipairs({ { value = -1 }, { value = 1.5 }, { value = math.huge },
			{ value = -math.huge }, { value = 0 / 0 }, { value = "100" }, { value = false }, { value = {} }, {} }) do
			local reads, calls, refused = 0, 0, 0
			local channel = Observation.new(2, function() reads = reads + 1; return row.value end,
				function() calls = calls + 1; return true end, function() refused = refused + 1 end)
			helpers.assert_eq(channel.publish(configuration()), false)
			helpers.assert_eq(channel.publish(configuration()), false)
			helpers.assert_eq(reads, 1); helpers.assert_eq(calls, 0); helpers.assert_eq(refused, 1)
		end
	end)

	helpers.it("(physical-configuration-portability) refuses nonintegral array keys and sparse selectors through actual shared copy", function()
		for _, apps in ipairs({ { [0.5] = {} }, { [-1] = {} }, { [2] = {} }, { label = {} }, { [math.huge] = {} } }) do
			local original = configuration(); original.disabled_apps = apps
			local ok, reason = pcall(Observation.copy, original)
			helpers.assert_eq(ok, false)
			local expected_reason = apps[2] and "Invalid physical application selector"
				or "Invalid physical application array"
			helpers.assert_true(tostring(reason):find(expected_reason, 1, true) ~= nil,
				"Invalid selectors must fail their semantic validator, not an unrelated runtime error")
		end
		local original = configuration()
		local copied = Observation.copy(original)
		helpers.assert_eq(copied, { private_filter_enabled = true, secure_field_filter_enabled = true,
			system_auth_filter_enabled = true, disabled_apps = {{ bundleID = "excluded.app" }} })
		original.disabled_apps[1].bundleID = "caller.mutated"
		helpers.assert_eq(copied.disabled_apps[1].bundleID, "excluded.app", "Healthy selectors stay detached")
	end)
end)
