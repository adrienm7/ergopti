--- tests/unit/infra/preferences/test_preferences_pause_layouts.lua

--- ==============================================================================
--- MODULE: Pause Layout Preferences
--- DESCRIPTION:
--- layout.on_pause and layout.on_resume hold layout ids. Declared as booleans,
--- a chosen layout made the canonical current view refuse the whole file, so
--- every caller reading it (the LLM settings transactions, program actions)
--- saw no configuration at all. A legacy `false` is an outdated entry: a
--- WARNING, read as absent so the manifest default applies.
--- ==============================================================================

local helpers = require("tests.helpers")
local OutputFixture = require("tests.support.toml_output_fixture")

--- Loads a private config.toml through the real preferences owner.
--- @param source string config.toml bytes.
--- @param body function Receives (preferences, path, warnings).
local function with_source(source, body)
	helpers.with_stub_scope({ "infra.preferences", "adapters.file_system", "infra.logger", "logger.shim",
		"config_outdated" }, function()
		local warnings = {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...)
			warnings[#warnings + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
		end
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		package.loaded["adapters.file_system"] = nil
		local config_outdated = require("config_outdated")
		if type(config_outdated.reset_for_tests) == "function" then config_outdated.reset_for_tests() end
		local preferences = helpers.load_with_stubs("infra.preferences")
		OutputFixture.with_output(function(path)
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
			body(preferences, path, warnings)
		end)
	end)
end

helpers.describe("pause layout preferences", function()
	helpers.it("keeps a chosen layout id in the load and in the current view", function()
		local source = '[layout]\npause_switch_enabled = true\non_pause = "French"\non_resume = "Ergopti_v2_2_2_plus"\n'
		with_source(source, function(preferences, path)
			local state, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.layout_pause_switch_enabled, true)
			helpers.assert_eq(state.layout_on_pause, "French")
			helpers.assert_eq(state.layout_on_resume, "Ergopti_v2_2_2_plus")
			local view = preferences.current_view(path)
			helpers.assert_type(view, "table", "a chosen layout no longer refuses the current view")
			helpers.assert_eq(view.layout_on_pause, "French")
			helpers.assert_eq(view.layout_on_resume, "Ergopti_v2_2_2_plus")
		end)
	end)

	for _, key in ipairs({ "on_pause", "on_resume" }) do
		helpers.it("reports a legacy boolean " .. key .. " as outdated and reads it as absent", function()
			with_source("[layout]\n" .. key .. " = false\n", function(preferences, path, warnings)
				local state, status = preferences.load(path)
				helpers.assert_eq(status, "ok", "an outdated entry never refuses the file")
				helpers.assert_nil(state["layout_" .. key])
				local named = false
				for _, line in ipairs(warnings) do
					if line:find(key, 1, true) then named = true end
				end
				helpers.assert_true(named, "one WARNING names the entry: " .. table.concat(warnings, " | "))
			end)
		end)
	end
end)

return true
