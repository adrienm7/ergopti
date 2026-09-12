--- tests/unit/ui/test_healthcheck_error_persistence.lua

--- ==============================================================================
--- MODULE: Healthcheck Error Persistence Regression
--- DESCRIPTION:
--- Exercises real error publication and repeated snapshots, independently of
--- unrelated system probes. Taking a diagnostic must not erase its last error.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("healthcheck recorded error lifetime", function()
	helpers.it("retains the last recorded error across snapshots until explicitly replaced", function()
		local saved, prior_hs = {}, _G.hs
		for name, value in pairs(package.loaded) do saved[name] = value end
		local ok, err = xpcall(function()
			helpers.load_with_stubs("infra.logger")
			local logger = helpers.make_logger_stub()
			logger.ring_buffer_snapshot = function() return {} end
			package.loaded["infra.logger"] = logger
			package.loaded["ui.healthcheck.core"] = nil
			package.loaded["ui.healthcheck.helpers"] = nil
			-- Preserve the actual collector surface while isolating unrelated native
			-- probes; run() and record_error() remain the real production functions
			local collectors = require("ui.healthcheck.helpers")
			for name, value in pairs(collectors) do
				if type(value) == "function" then collectors[name] = function() return {} end end
			end
			local healthcheck = require("ui.healthcheck.core")
			helpers.assert_nil(healthcheck.run().last_error)
			healthcheck.record_error("first diagnostic failure")
			helpers.assert_eq(healthcheck.run().last_error, "first diagnostic failure")
			helpers.assert_eq(healthcheck.run().last_error, "first diagnostic failure",
				"a second snapshot must not consume the recorded error")
			healthcheck.record_error("replacement diagnostic failure")
			helpers.assert_eq(healthcheck.run().last_error, "replacement diagnostic failure")
		end, debug.traceback)
		for name in pairs(package.loaded) do
			if saved[name] == nil then package.loaded[name] = nil end
		end
		for name, value in pairs(saved) do package.loaded[name] = value end
		_G.hs = prior_hs
		if not ok then error(err, 0) end
	end)
end)
