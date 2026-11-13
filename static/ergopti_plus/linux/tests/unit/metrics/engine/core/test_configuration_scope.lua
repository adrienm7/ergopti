--- tests/unit/metrics/engine/core/test_configuration_scope.lua

--- ==============================================================================
--- MODULE: Collector Configuration Scope Contract
--- DESCRIPTION:
--- Configuration changes must affect future capture without rewriting history
--- or preferences. Native cipher refusal and active conversion cannot be hidden
--- by a successful table assignment.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.metrics.preferences_fixture")

local function with_collector(body)
	local names = { "metrics.engine.keystats", "metrics.engine.privacy.text_cipher",
		"metrics.engine.privacy.text_migration", "metrics.engine.preferences" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local state = { cipher = false, available = true, running = false, migrations = 0, writes = 0 }
	local ok, err = pcall(function()
		local preferences = Fixture.new()
		preferences.set = function() state.writes = state.writes + 1; return true end
		package.loaded["metrics.engine.preferences"] = preferences
		package.loaded["metrics.engine.privacy.text_cipher"] = {
			is_enabled = function() return state.cipher end,
			is_available = function() return state.available end,
			set_enabled = function(value)
				if state.refusal then return state.refusal(value) end
				state.cipher = value
				return true
			end,
		}
		package.loaded["metrics.engine.privacy.text_migration"] = {
			is_running = function() return state.running end,
			start = function() state.migrations = state.migrations + 1; return true end,
			resume = function() state.migrations = state.migrations + 1; return true end,
			cancel = function() state.migrations = state.migrations + 1 end,
		}
		package.loaded["metrics.engine.keystats"] = nil
		body(require("metrics.engine.keystats"), state)
	end)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("collector configuration scope", function()
	helpers.it("captures detached native posture and updates future capture without historical conversion", function()
		with_collector(function(collector, state)
			local snapshot = collector.configuration_snapshot()
			helpers.assert_eq(snapshot.enabled, false)
			snapshot.enabled, snapshot.encrypt, snapshot.cipher_enabled = true, true, true
			snapshot.private_filter_enabled = false
			helpers.assert_eq(collector.is_enabled(), false)
			helpers.assert_eq(collector.apply_configuration(snapshot), true)
			helpers.assert_eq(collector.is_enabled(), true)
			helpers.assert_eq(collector.get_privacy_state().private_filter_enabled, false)
			helpers.assert_eq(state.cipher, true)
			helpers.assert_eq(state.migrations, 0)
			helpers.assert_eq(state.writes, 0)
		end)
	end)

	helpers.it("refuses capture and mutation while a historical conversion is active", function()
		with_collector(function(collector, state)
			local snapshot = collector.configuration_snapshot()
			state.running = true
			helpers.assert_eq(collector.configuration_snapshot(), nil)
			snapshot.enabled = true
			helpers.assert_eq(collector.apply_configuration(snapshot), false)
			helpers.assert_eq(collector.is_enabled(), false)
			helpers.assert_eq(state.migrations, 0)
		end)
	end)

	helpers.it("rejects malformed or unavailable encryption before publishing capture flags", function()
		with_collector(function(collector, state)
			local snapshot = collector.configuration_snapshot()
			snapshot.enabled = "true"
			helpers.assert_eq(collector.apply_configuration(snapshot), false)
			snapshot.enabled, snapshot.encrypt, snapshot.cipher_enabled = true, true, true
			state.available = false
			helpers.assert_eq(collector.apply_configuration(snapshot), false)
			helpers.assert_eq(collector.is_enabled(), false)
			helpers.assert_eq(state.cipher, false)
			snapshot.cipher_enabled = false
			helpers.assert_eq(collector.apply_configuration(snapshot), true,
				"compensation must preserve a previously demoted desired encryption posture")
			helpers.assert_eq(collector.is_encrypt_enabled(), true)
			helpers.assert_eq(state.cipher, false)
		end)
	end)

	helpers.it("requires terminal cipher acknowledgment and permits exact compensation", function()
		for _, refusal in ipairs({
			function() return false end,
			function() return nil end,
			function() error("cipher failure") end,
		}) do
			with_collector(function(collector, state)
				local previous = collector.configuration_snapshot()
				local candidate = collector.configuration_snapshot()
				candidate.enabled, candidate.encrypt, candidate.cipher_enabled = true, true, true
				state.refusal = function(value) state.cipher = value; return refusal() end
				helpers.assert_eq(collector.apply_configuration(candidate), false)
				helpers.assert_eq(collector.is_enabled(), false)
				state.refusal = nil
				helpers.assert_eq(collector.apply_configuration(previous), true)
				helpers.assert_eq(state.cipher, false)
				helpers.assert_eq(state.writes, 0)
			end)
		end
	end)
end)
