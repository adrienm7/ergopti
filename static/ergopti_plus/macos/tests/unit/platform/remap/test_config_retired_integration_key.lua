--- tests/unit/platform/remap/test_config_retired_integration_key.lua

--- ==============================================================================
--- MODULE: Retired Karabiner Preference Preservation
--- DESCRIPTION:
--- Real-file source models pin retirement without integration consent or an
--- implicit ordinary-save cleanup. Explicit whole-file resets keep their owner.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Exercises actual reads, codec and native conditional publication on a private file.
--- @param source string Independent TOML source.
--- @param body function Assertions receiving the owner and native boundary controls.
local function with_file(source, body)
	helpers.with_stub_scope({ "platform.remap.config", "adapters.file_system", "infra.logger", "logger.shim", "toml_codec", "infra.toml.codec" }, function()
		local warnings, errors = {}, {}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		require("config_outdated").reset_for_tests()
		local config = helpers.load_with_stubs("platform.remap.config")
		local path = os.tmpname()
		local function write(text)
			local file = assert(io.open(path, "wb")); assert(file:write(text)); assert(file:close())
		end
		local function read()
			local file = assert(io.open(path, "rb")); local text = assert(file:read("*a")); assert(file:close()); return text
		end
		write(source)
		local files = require("adapters.file_system")
		local native_write, native_conditional, native_read = files.write, files.write_if_unchanged, files.read_with_status
		local controls = { writes = 0 }
		files.write_if_unchanged = function(destination, content, expected)
			controls.writes = controls.writes + 1
			helpers.assert_eq(destination, path)
			helpers.assert_eq(expected, { status = "ok", content = controls.expected or source })
			if controls.before_publish then controls.before_publish() end
			return native_conditional(destination, content, expected)
		end
		files.write = function(destination, content)
			controls.writes = controls.writes + 1
			helpers.assert_eq(destination, path)
			return native_write(destination, content)
		end
		local function load()
			return config.load_user_config({ { id = "tab" } }, {}, path)
		end
		local ok, err = pcall(body, { config = config, path = path, files = files, warnings = warnings,
			errors = errors, controls = controls, load = load, read = read, write = write,
			decode = require("infra.toml.codec").decode })
		files.write, files.write_if_unchanged, files.read_with_status = native_write, native_conditional, native_read
		os.remove(path); os.remove(path .. ".tmp")
		if not ok then error(err, 0) end
	end)
end

local VALUES = {
	{ name = "false", literal = "false", value = false },
	{ name = "true", literal = "true", value = true },
	{ name = "integer", literal = "7", value = 7 },
	{ name = "float", literal = "1.5", value = 1.5 },
	{ name = "string", literal = '"obsolete"', value = "obsolete" },
	{ name = "array", literal = '[false, "future", 7]', value = { false, "future", 7 } },
	{ name = "inline table", literal = '{ future = { note = "keep", enabled = false } }',
		value = { future = { note = "keep", enabled = false } } },
}

--- Writes a complete independent source with native consent and unknown neighbors.
--- @param literal string Retired value's exact source spelling.
--- @param consent boolean|nil Actual integration consent, absent by default.
--- @return string source Handwritten TOML fixture.
local function fixture(literal, consent)
	return "[karabiner]\nenabled = " .. literal .. "\n"
		.. (consent ~= nil and "integration_enabled = " .. tostring(consent) .. "\n" or "")
		.. '[karabiner.future]\naliases = ["future", "preserve"]\n'
		.. '[future]\nkeep = "independent"\n[future.nested]\nvalue = 7\n'
end

--- Specifies every surviving source field independently of runtime construction.
--- @param retired any Retained value from the handwritten vector.
--- @param consent boolean|nil Current integration decision, if any.
--- @return table expected Complete expected model after adding the unrelated tab action.
local function expected_model(retired, consent)
	return {
		karabiner = { enabled = retired, integration_enabled = consent, future = { aliases = { "future", "preserve" } } },
		future = { keep = "independent", nested = { value = 7 } },
		tap_holds = { config = { tab = { tap = "copy" } } },
	}
end

helpers.describe("Retired Karabiner integration preference", function()
	for _, vector in ipairs(VALUES) do
		helpers.it("ordinary save retains the complete retired " .. vector.name .. " model", function()
			local source = fixture(vector.literal)
			with_file(source, function(f)
				local state, status = f.load()
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(state.enabled, true, "the retired value never chooses integration consent")
				helpers.assert_eq(f.read(), source, "reading is not implicit cleanup")
				state.enabled = nil
				state.tap_hold_config.tab = { tap = "copy", hold = "none" }
				helpers.assert_true(f.config.save_user_config(state, f.path))
				helpers.assert_eq(f.decode(f.read()), expected_model(vector.value), "every independent source field survives")
				helpers.assert_eq(#f.warnings, 1)
				helpers.assert_contains(f.warnings[1], "'karabiner.enabled' in '" .. f.path .. "'")
				local fresh, fresh_status = f.load()
				helpers.assert_eq(fresh_status, "ok")
				helpers.assert_eq(fresh.enabled, true)
				helpers.assert_eq(fresh.tap_hold_config.tab, { tap = "copy", hold = "none" })
				helpers.assert_eq(#f.warnings, 1, "load/save/reload share one exact file/path/reason warning")
				helpers.assert_eq(f.errors, {})
				helpers.assert_eq(f.controls.writes, 1)
			end)
		end)
		for _, consent in ipairs({ false, true }) do
			helpers.it("integration consent " .. tostring(consent) .. " retains retired " .. vector.name, function()
				with_file(fixture(vector.literal, not consent), function(f)
					local state, status = f.load()
					helpers.assert_eq(status, "ok")
					helpers.assert_eq(state.enabled, not consent)
					state.enabled = consent
					state.tap_hold_config.tab = { tap = "copy", hold = "none" }
					helpers.assert_true(f.config.save_user_config(state, f.path))
					helpers.assert_eq(f.decode(f.read()), expected_model(vector.value, consent))
					local fresh, fresh_status = f.load()
					helpers.assert_eq(fresh_status, "ok")
					helpers.assert_eq(fresh.enabled, consent, "only integration_enabled controls the native decision")
					helpers.assert_eq(#f.warnings, 1)
					helpers.assert_eq(f.errors, {})
				end)
			end)
		end
	end

	helpers.it("a newer retired value is retained instead of resurrecting the carried source", function()
		with_file(fixture("false"), function(f)
			local state = f.load()
			local external = fixture('"newer"')
			f.write(external)
			f.controls.expected = external
			state.enabled = nil
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			helpers.assert_true(f.config.save_user_config(state, f.path))
			helpers.assert_eq(f.decode(f.read()), expected_model("newer"))
			helpers.assert_eq(#f.warnings, 1)
			helpers.assert_eq(f.errors, {})
		end)
	end)

	helpers.it("the actual conditional writer preserves an external source replacement", function()
		with_file(fixture("false"), function(f)
			local state = f.load()
			state.enabled = nil
			state.tap_hold_config.tab = { tap = "copy", hold = "none" }
			local external = fixture('"external"')
			f.controls.before_publish = function() f.write(external) end
			helpers.assert_eq(f.config.save_user_config(state, f.path), false)
			helpers.assert_eq(f.read(), external, "the exact newer source bytes remain owned by their writer")
			helpers.assert_eq(f.controls.writes, 1)
			helpers.assert_eq(#f.warnings, 1)
		end)
	end)

	helpers.it("a backed-up scope source cannot silently adopt another retired model", function()
		local source = fixture("false")
		with_file(source, function(f)
			local state = f.load()
			local external = fixture('"external"')
			f.write(external)
			helpers.assert_eq(f.config.save_user_config(state, f.path, nil, { status = "ok", content = source }), false)
			helpers.assert_eq(f.controls.writes, 0)
			helpers.assert_eq(f.read(), external)
		end)
	end)

	helpers.it("an explicit whole-file reset may remove retired and unknown source fields", function()
		with_file(fixture("false"), function(f)
			local state = { enabled = false, tap_holds_enabled = true, tap_hold_timeout_ms = 123,
				sticky_timeout_ms = 456, tap_hold_config = { tab = { tap = "copy", hold = "ctrl" } },
				mod_combos_enabled = false, combo_symmetric = true, simultaneous_threshold_ms = 78, mod_combos_config = {} }
			helpers.assert_true(f.config.save_user_config(state, f.path, true))
			helpers.assert_eq(f.decode(f.read()), {
				karabiner = { integration_enabled = false },
				tap_holds = { enabled = true, timeout_ms = 123, sticky_timeout_ms = 456,
					config = { tab = { tap = "copy", hold = "ctrl" } } },
				mod_combos = { enabled = false, symmetric = true, simultaneous_threshold_ms = 78 },
			}, "only explicit reset replaces the complete file model")
			helpers.assert_eq(f.warnings, {})
			helpers.assert_eq(f.errors, {})
		end)
	end)

	for _, literal in ipairs({ '"ambiguous"', "1", "[true]", "{ future = true }" }) do
		helpers.it("retired data cannot authorize ambiguous integration consent " .. literal, function()
			local source = '[karabiner]\nenabled = false\nintegration_enabled = ' .. literal .. '\n'
			with_file(source, function(f)
				local state, status = f.load()
				helpers.assert_nil(state)
				helpers.assert_eq(status, "error")
				helpers.assert_eq(f.read(), source)
				helpers.assert_eq(f.controls.writes, 0)
				helpers.assert_eq(#f.errors, 1)
			end)
		end)
	end

	helpers.it("the integration candidate still requires a Boolean before publication", function()
		local source = fixture("false")
		with_file(source, function(f)
			local state = f.load()
			state.enabled = "ambiguous"
			helpers.assert_eq(f.config.save_user_config(state, f.path), false)
			helpers.assert_eq(f.controls.writes, 0)
			helpers.assert_eq(f.read(), source)
			helpers.assert_eq(#f.warnings, 1)
		end)
	end)

	helpers.it("malformed syntax remains a file failure and never becomes retirement consent", function()
		local source = '[karabiner\nenabled = false\n'
		with_file(source, function(f)
			local state, status = f.load()
			helpers.assert_nil(state)
			helpers.assert_eq(status, "error")
			local candidate = f.config.build_default_state({ { id = "tab" } }, {})
			helpers.assert_eq(f.config.save_user_config(candidate, f.path), false)
			helpers.assert_eq(f.controls.writes, 0)
			helpers.assert_eq(f.read(), source)
			helpers.assert_eq(f.warnings, {})
		end)
	end)

	helpers.it("unavailable source remains a file failure before any native writer", function()
		local source = fixture("false")
		with_file(source, function(f)
			f.files.read_with_status = function() return nil, "error", "controlled unavailable source" end
			local state, status = f.load()
			helpers.assert_nil(state)
			helpers.assert_eq(status, "error")
			helpers.assert_eq(f.config.save_user_config(f.config.build_default_state({}, {}), f.path), false)
			helpers.assert_eq(f.controls.writes, 0)
			helpers.assert_eq(f.read(), source)
			helpers.assert_eq(f.warnings, {})
		end)
	end)
end)
