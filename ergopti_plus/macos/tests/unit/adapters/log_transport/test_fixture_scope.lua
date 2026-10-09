--- tests/unit/adapters/log_transport/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: Log Transport Fixture Isolation Tests
--- DESCRIPTION:
--- Verifies exact native and module restoration around construction and assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")

local OWNERS = {
	"adapters.log_transport", "tests.stubs.hs", "hs",
	"adapters.timer_scheduler", "infra.logger",
}

helpers.describe("Log transport fixture isolation", function()
	for _, mode in ipairs({ "success", "construction", "callback", "real_scheduler" }) do
		helpers.it("(transport-fixture-scope) restores exact owners after " .. mode, function()
			helpers.with_stub_scope(OWNERS, function()
				helpers.load_with_stubs("hs")
				local prior_hs = _G.hs
				local prior_transport, prior_scheduler = {}, {}
				local prior_stub = package.loaded["tests.stubs.hs"]
				package.loaded["adapters.log_transport"] = prior_transport
				package.loaded["adapters.timer_scheduler"] = prior_scheduler
				package.loaded["infra.logger"] = false
				package.loaded["hs"] = nil
				local reached, sent = 0, 0
				local ok, result, trailing = pcall(Fixture.with_fixture, function()
					local options
					if mode == "construction" then
						options = setmetatable({}, { __index = function(_, key)
							if key == "no_bootstrap_timeout" then
								helpers.assert_true(_G.hs ~= prior_hs)
								helpers.assert_true(package.loaded["adapters.log_transport"] ~= prior_transport)
								error("transport construction marker")
							end
						end })
					end
					local context = Fixture.new_context(options)
					reached = reached + 1
					Fixture.configure(context)
					sent = #context.state.sends
					if mode == "callback" then error("transport callback marker") end
					if mode == "real_scheduler" then
						package.loaded["infra.logger"] = helpers.make_logger_stub()
						local scheduler = helpers.load_with_stubs("adapters.timer_scheduler", {
							timer = { absoluteTime = function() return 123456789 end },
						})
						helpers.assert_eq(scheduler.now_ns(), 123456789)
					else
						local successor = Fixture.new_context()
						Fixture.configure(successor)
						helpers.assert_true(successor.transport ~= context.transport)
						helpers.assert_true(successor.hs ~= context.hs)
						helpers.assert_eq(#context.state.sends, 1)
						helpers.assert_eq(#successor.state.sends, 1)
					end
					return nil, "transport fixture result"
				end)
				if mode == "construction" or mode == "callback" then
					helpers.assert_eq(ok, false)
					helpers.assert_contains(tostring(result), "transport " .. mode .. " marker")
				else
					helpers.assert_eq(ok, true, tostring(result))
					helpers.assert_nil(result)
					helpers.assert_eq(trailing, "transport fixture result")
				end
				helpers.assert_eq(reached, mode == "construction" and 0 or 1)
				helpers.assert_eq(sent, mode == "construction" and 0 or 1)
				helpers.assert_true(_G.hs == prior_hs, "restore the predecessor native host")
				helpers.assert_true(package.loaded["adapters.log_transport"] == prior_transport)
				helpers.assert_true(package.loaded["adapters.timer_scheduler"] == prior_scheduler)
				helpers.assert_true(package.loaded["tests.stubs.hs"] == prior_stub)
				helpers.assert_nil(package.loaded["hs"])
				helpers.assert_eq(package.loaded["infra.logger"], false)
			end)
		end)
	end
end)
