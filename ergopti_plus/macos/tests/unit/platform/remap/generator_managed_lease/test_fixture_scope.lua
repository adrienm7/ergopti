--- tests/unit/platform/remap/generator_managed_lease/test_fixture_scope.lua

--- ==============================================================================
--- MODULE: Managed Lease Generator Fixture Isolation
--- DESCRIPTION:
--- Proves exact dependency restoration and independent file publication state.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.generator_managed_lease_fixture").with_fixture
local OWNERS = {
	"platform.remap.generator", "infra.logger", "adapters.file_system",
	"infra.config_paths", "infra.keycodes", "hs", "tests.stubs.hs",
}

local function with_observer(callback)
	helpers.with_stub_scope(OWNERS, function()
		local preload = package.preload["platform.remap.generator"]
		local describe = helpers.describe
		local outcome = table.pack(xpcall(callback, debug.traceback))
		package.preload["platform.remap.generator"] = preload
		helpers.describe = describe
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("Managed lease generator fixture isolation", function()
	for _, mode in ipairs({ "success", "callback failure", "construction failure" }) do
		helpers.it("(generator-fixture-scope) restores exact predecessors after " .. mode, function()
			with_observer(function()
				local expected = {}
				for _, name in ipairs(OWNERS) do
					expected[name] = {}
					package.loaded[name] = expected[name]
				end
				local native = rawget(_G, "hs")
				local marker = "generator fixture injected failure"
				if mode == "construction failure" then
					package.preload["platform.remap.generator"] = function() error(marker, 0) end
				end
				local entered = false
				local ok, result = pcall(with_fixture, function(fixture)
					entered = true
					helpers.assert_type(fixture.Generator.merge_and_deploy_config, "function")
					if mode == "callback failure" then error(marker, 0) end
					return "completed"
				end)
				helpers.assert_eq(entered, mode ~= "construction failure")
				helpers.assert_eq(ok, mode == "success", tostring(result))
				if mode == "success" then
					helpers.assert_eq(result, "completed")
				else
					helpers.assert_true(tostring(result):find(marker, 1, true) ~= nil)
				end
				helpers.assert_true(rawequal(rawget(_G, "hs"), native), "native host must be restored")
				for _, name in ipairs(OWNERS) do
					helpers.assert_true(package.loaded[name] == expected[name], name .. " must be restored")
				end
			end)
		end)
	end

	helpers.it("(generator-fixture-scope) discards previous file maps, refusal state and hooks", function()
		with_observer(function()
			local previous_generator
			with_fixture(function(fixture)
				previous_generator = fixture.Generator
				for _, key in ipairs({ "file_data", "unreadable_paths", "file_writes", "file_reads",
					"missing_parent_paths", "parent_prepare_failures", "parent_prepare_calls" }) do
					fixture[key].retired = true
				end
				fixture.write_succeeds = false
				fixture.before_read = function() error("retired read hook", 0) end
				fixture.before_publication = function() error("retired publication hook", 0) end
			end)
			with_fixture(function(fixture)
				helpers.assert_true(fixture.Generator ~= previous_generator)
				for _, key in ipairs({ "file_data", "unreadable_paths", "file_writes", "file_reads",
					"missing_parent_paths", "parent_prepare_failures", "parent_prepare_calls" }) do
					helpers.assert_nil(next(fixture[key]), key .. " must start empty")
				end
				helpers.assert_eq(fixture.write_succeeds, true)
				helpers.assert_nil(fixture.before_read)
				helpers.assert_nil(fixture.before_publication)
				local generated, err = fixture.build("0123456789abcdef0123456789abcdef")
				helpers.assert_not_nil(generated, err)
				local ok, detail = fixture.Generator.merge_and_deploy_config(generated, "/fresh/karabiner.json")
				helpers.assert_eq(ok, true, tostring(detail))
				helpers.assert_eq(#fixture.file_writes, 1)
				helpers.assert_eq(fixture.file_writes[1].method, "write_if_unchanged")
				helpers.assert_type(fixture.file_data["/fresh/karabiner.json"], "string")
			end)
			for _, name in ipairs(OWNERS) do helpers.assert_nil(package.loaded[name], name) end
		end)
	end)

	helpers.it("(generator-fixture-scope) registers all suites without replacing native dependencies", function()
		with_observer(function()
			local expected = {}
			for _, name in ipairs(OWNERS) do
				expected[name] = {}
				package.loaded[name] = expected[name]
			end
			local native = rawget(_G, "hs")
			local modules = {
				"tests.support.generator_managed_lease_fixture",
				"tests.unit.platform.remap.test_generator_managed_lease",
				"tests.unit.platform.remap.generator_managed_lease.test_historical_ownership",
				"tests.unit.platform.remap.generator_managed_lease.test_managed_merge",
				"tests.unit.platform.remap.generator_managed_lease.test_merge_ambiguity",
				"tests.unit.platform.remap.generator_managed_lease.test_publication",
			}
			local registrations = 0
			helpers.describe = function() registrations = registrations + 1 end
			helpers.with_fresh_modules(modules, function()
				for _, name in ipairs(modules) do require(name) end
			end)
			helpers.assert_eq(registrations, 5)
			helpers.assert_true(rawequal(rawget(_G, "hs"), native))
			for _, name in ipairs(OWNERS) do
				helpers.assert_true(package.loaded[name] == expected[name], name .. " must remain unchanged")
			end
		end)
	end)
end)
