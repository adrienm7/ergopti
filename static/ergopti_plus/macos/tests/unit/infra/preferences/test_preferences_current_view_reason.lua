--- tests/unit/infra/preferences/test_preferences_current_view_reason.lua

--- ==============================================================================
--- MODULE: Current View Refusal Reasons
--- DESCRIPTION:
--- The canonical current view refused config.toml for six different causes and
--- returned a bare nil, so the 2026-10-27 field session only logged "config.toml
--- cannot be read, so the virtual keyboard choice is unknown" with no cause. A
--- refused view now names a closed reason; an absent file is still the
--- defaults, never a refusal.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")

--- Runs a body against the real preferences owner and a private config path.
--- @param source string|nil config.toml bytes, nil for an absent file.
--- @param body function Receives (preferences, path).
local function with_source(source, body)
	helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim",
		"config_outdated" }, function()
		local logger = helpers.make_logger_stub()
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		package.loaded["adapters.file_system"] = nil
		local config_outdated = require("config_outdated")
		if type(config_outdated.reset_for_tests) == "function" then config_outdated.reset_for_tests() end
		local preferences = helpers.load_with_stubs("infra.preferences")
		OutputFixture.with_output(function(path)
			if source ~= nil then
				local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			else
				os.remove(path)
			end
			body(preferences, path)
		end)
	end)
end

helpers.describe("current view refusal reasons", function()
	helpers.it("reads an absent file as the defaults with no refusal", function()
		with_source(nil, function(preferences, path)
			local view, _, reason = preferences.current_view(path, true)
			helpers.assert_type(view, "table", "an absent config.toml is the defaults")
			helpers.assert_nil(reason)
		end)
	end)

	helpers.it("names an outdated entry in the strict view", function()
		with_source("[shortcuts.keys]\nlayer_scroll = true\n", function(preferences, path)
			local view, _, reason = preferences.current_view(path)
			helpers.assert_nil(view)
			helpers.assert_eq(reason, "outdated_keys")
		end)
	end)

	helpers.it("names a section stored as a scalar", function()
		with_source("layout = 3\n", function(preferences, path)
			local view, _, reason = preferences.current_view(path, true)
			helpers.assert_nil(view)
			helpers.assert_eq(reason, "section_shape")
		end)
	end)

	helpers.it("names a value of the wrong type", function()
		with_source("[layout]\npause_switch_enabled = \"yes\"\n", function(preferences, path)
			local view, _, reason, key_path = preferences.current_view(path, true)
			helpers.assert_nil(view)
			helpers.assert_true(reason == "value_type" or reason == "value_out_of_range",
				"a wrong value type must be named, got " .. tostring(reason))
			-- Field run 2026-10-27 19:47: value_type on every regeneration, no key named.
			helpers.assert_eq(key_path, "layout.pause_switch_enabled")
		end)
	end)

	helpers.it("names an invalid path", function()
		with_source(nil, function(preferences)
			local view, _, reason = preferences.current_view("")
			helpers.assert_nil(view)
			helpers.assert_eq(reason, "invalid_path")
		end)
	end)
end)
