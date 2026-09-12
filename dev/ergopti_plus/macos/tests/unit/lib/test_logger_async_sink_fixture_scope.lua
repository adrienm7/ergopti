--- tests/unit/lib/test_logger_async_sink_fixture_scope.lua

--- ==============================================================================
--- MODULE: Logger Asynchronous Fixture Scope Tests
--- DESCRIPTION:
--- Preserves predecessor native identities and shared-core hooks across fixture work.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.logger_async_sink_fixture")
local OWNERS = {
	"infra.logger", "adapters.log_transport", "tests.stubs.hs", "hs", "logger",
	"infra.launcher_environment", "_generated.logger_sub_files", "socket",
}

helpers.describe("Logger asynchronous fixture scope", function()
	helpers.it("(async-fixture-scope) isolates policy loading even when its callback throws", function()
		helpers.with_stub_scope(OWNERS, function()
			local Core = require("logger")
			local records = {}
			Core.set_sink(function(line) records[#records + 1] = line end)
			local predecessor_hs = rawget(_G, "hs")
			local saved = {}
			for _, name in ipairs(OWNERS) do saved[name] = package.loaded[name] end
			local reached = false
			local ok, detail = pcall(Fixture.with_policy_logger, function(Logger)
				helpers.assert_eq(Logger.classify_async_sink_boot_environment(function() return nil end), "standalone")
				reached = true
				error("policy callback marker")
			end)
			helpers.assert_eq(ok, false)
			helpers.assert_eq(reached, true)
			helpers.assert_contains(detail, "policy callback marker")
			for _, name in ipairs(OWNERS) do
				helpers.assert_eq(package.loaded[name], saved[name], "policy cache predecessor: " .. name)
			end
			helpers.assert_eq(rawget(_G, "hs"), predecessor_hs)
			Core.info("predecessor", "after policy callback failure")
			helpers.assert_eq(#records, 1)
			helpers.assert_contains(records[1], "after policy callback failure")
		end)
	end)

	for _, predecessor_kind in ipairs({ "absent", "false", "table" }) do
		for _, outcome in ipairs({ "success", "callback failure", "construction failure" }) do
			helpers.it("(async-fixture-scope) restores " .. predecessor_kind .. " owners after " .. outcome, function()
				helpers.with_stub_scope(OWNERS, function()
					local predecessor = nil
					if predecessor_kind == "false" then predecessor = false end
					if predecessor_kind == "table" then predecessor = {} end
					for _, name in ipairs({ "infra.logger", "adapters.log_transport", "tests.stubs.hs", "hs" }) do
						package.loaded[name] = predecessor
					end
					_G.hs = predecessor
					local Core = require("logger")
					local sink_records = {}
					Core.set_sink(function(line) sink_records[#sink_records + 1] = line end)
					local saved = {}
					for _, name in ipairs(OWNERS) do saved[name] = package.loaded[name] end
					local original_require = require
					local construction_reached = false
					if outcome == "construction failure" then
						_G.require = function(name)
							local loaded = table.pack(original_require(name))
							if name == "infra.logger" then
								construction_reached = true
								error("fixture construction marker")
							end
							return table.unpack(loaded, 1, loaded.n)
						end
					end
					local callback_reached = false
					local ok, detail = pcall(Fixture.with_fixture, function(fixture)
						fixture.Logger.info("fixture_scope", "owned record")
						local record = fixture.deliver_next()
						helpers.assert_contains(record.line, "owned record")
						callback_reached = true
						if outcome == "callback failure" then error("fixture callback marker") end
					end)
					_G.require = original_require
					helpers.assert_eq(ok, outcome == "success")
					if outcome == "construction failure" then
						helpers.assert_eq(construction_reached, true)
						helpers.assert_eq(callback_reached, false)
						helpers.assert_contains(detail, "fixture construction marker")
					else
						helpers.assert_eq(callback_reached, true)
						if outcome == "callback failure" then helpers.assert_contains(detail, "fixture callback marker") end
					end
					for _, name in ipairs(OWNERS) do
						helpers.assert_eq(package.loaded[name], saved[name], "cache predecessor: " .. name)
					end
					helpers.assert_eq(rawget(_G, "hs"), predecessor)
					helpers.assert_eq(#sink_records, 0, "fixture logs must not enter the predecessor sink")
					Core.info("predecessor", "still owns its sink")
					helpers.assert_eq(#sink_records, 1)
					helpers.assert_contains(sink_records[1], "still owns its sink")
				end)
			end)
		end
	end

	helpers.it("(async-fixture-scope) preserves the retained predecessor core's actual sink", function()
		helpers.with_stub_scope(OWNERS, function()
			local Core = require("logger")
			local records = {}
			Core.set_sink(function(line) records[#records + 1] = line end)
			Core.info("predecessor", "before fixture")
			helpers.assert_eq(#records, 1)
			local retained_fixture
			Fixture.with_fixture(function(fixture)
				retained_fixture = fixture
				fixture.Logger.info("fixture_scope", "private record")
				fixture.deliver_next()
			end)
			Core.info("predecessor", "after fixture")
			helpers.assert_eq(#records, 2, "a retained core reference must still dispatch to its predecessor sink")
			helpers.assert_contains(records[2], "after fixture")
			helpers.assert_eq(retained_fixture.Logger.async_sink_status().queued, 0,
				"the predecessor emission must not enter the retired fixture transport")
		end)
	end)
end)
