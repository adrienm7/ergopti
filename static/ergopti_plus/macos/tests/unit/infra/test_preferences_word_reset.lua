--- tests/unit/infra/test_preferences_word_reset.lua

--- ==============================================================================
--- MODULE: Word-Reset Preferences
--- DESCRIPTION:
--- hotstrings.idle_reset_seconds and hotstrings.click_resets_word reach the
--- menu state from config.toml, survive a save and a restart, and an invalid
--- stored value is an outdated entry: a WARNING, read as absent so the manifest
--- default applies, never a refused file.
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

helpers.describe("word-reset preferences", function()
	helpers.it("reads, saves and reloads both settings", function()
		with_source("[hotstrings]\nidle_reset_seconds = 4.5\nclick_resets_word = false\n", function(preferences, path)
			local state, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.idle_reset_seconds, 4.5)
			helpers.assert_eq(state.click_resets_word, false)
			helpers.assert_eq(preferences.save(path, { idle_reset_seconds = 0, click_resets_word = true }, {}, {}), true)
			package.loaded["infra.preferences"] = nil
			local restarted = helpers.load_with_stubs("infra.preferences").load(path)
			helpers.assert_eq(restarted.idle_reset_seconds, 0)
			helpers.assert_eq(restarted.click_resets_word, true)
		end)
	end)

	for _, vector in ipairs({
		{ name = "a negative idle delay", source = "[hotstrings]\nidle_reset_seconds = -2\n", key = "idle_reset_seconds" },
		{ name = "a text idle delay", source = '[hotstrings]\nidle_reset_seconds = "3"\n', key = "idle_reset_seconds" },
		{ name = "a text click flag", source = '[hotstrings]\nclick_resets_word = "yes"\n', key = "click_resets_word" },
	}) do
		helpers.it("reports " .. vector.name .. " as outdated and reads it as absent", function()
			with_source(vector.source, function(preferences, path, warnings)
				local state, status = preferences.load(path)
				helpers.assert_eq(status, "ok", "an outdated entry never refuses the file")
				helpers.assert_nil(state[vector.key])
				local named = false
				for _, line in ipairs(warnings) do
					if line:find(vector.key, 1, true) then named = true end
				end
				helpers.assert_true(named, "one WARNING names the entry: " .. table.concat(warnings, " | "))
			end)
		end)
	end
end)

return true
