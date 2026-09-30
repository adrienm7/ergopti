--- tests/unit/platform/remap/test_config_sparse_load.lua

--- ==============================================================================
--- MODULE: Remap Configuration Sparse Loading
--- DESCRIPTION:
--- The remap writer persists only non-neutral leaves, so an absent table, key,
--- slot or timing is the neutral value and never a damaged save. Loading such a
--- file must yield the complete neutral runtime shape without a warning: the
--- daily errors file keeps every WARNING, and a sparse file is the normal case.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "platform.remap.config", "adapters.file_system", "infra.logger", "infra.toml.codec", "toml_codec" }

--- Loads one remap configuration source through the real codec.
--- @param source string Persisted bytes.
--- @return table state Loaded runtime state.
--- @return string status Load classification.
--- @return table warnings Every formatted WARNING line.
--- @return table config The loaded module.
local function load(source)
	local warnings, state, status, config = {}, nil, nil, nil
	helpers.with_stub_scope(MODULES, function()
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		package.loaded["infra.logger"] = logger
		config = helpers.load_with_stubs("platform.remap.config")
		local files = require("adapters.file_system")
		local old_read = files.read_with_status
		files.read_with_status = function() return source, "ok" end
		local ok, err = pcall(function()
			state, status = config.load_user_config({ { id = "escape" }, { id = "tab" } },
				{ { id = "esc_tab" } }, "sparse-remap-config.toml")
		end)
		files.read_with_status = old_read
		if not ok then error(err, 0) end
	end)
	return state, status, warnings, config
end

helpers.describe("Remap configuration sparse loading", function()
	helpers.it("reads an empty file as the complete neutral state without warnings", function()
		local state, status, warnings, config = load("")
		helpers.assert_eq(status, "ok")
		helpers.assert_eq(warnings, {})
		local neutral = config.build_default_state({ { id = "escape" }, { id = "tab" } }, { { id = "esc_tab" } })
		helpers.assert_eq(state.tap_holds_enabled, false)
		helpers.assert_eq(state.tap_hold_config, neutral.tap_hold_config)
		helpers.assert_eq(state.mod_combos_config, neutral.mod_combos_config)
		helpers.assert_eq(state.tap_hold_timeout_ms, neutral.tap_hold_timeout_ms)
		helpers.assert_eq(state.sticky_timeout_ms, neutral.sticky_timeout_ms)
		helpers.assert_eq(state.simultaneous_threshold_ms, neutral.simultaneous_threshold_ms)
		helpers.assert_eq(state.combo_symmetric, neutral.combo_symmetric)
	end)

	helpers.it("completes a partial binding with neutral slots and keeps unknown fields", function()
		local state, _, warnings = load('[tap_holds.config.escape]\ntap = "paste"\n'
			.. '[tap_holds.config.escape.custom]\nnote = "keep"\n'
			.. '[mod_combos.config.esc_tab]\nhold = "ctrl"\n')
		helpers.assert_eq(warnings, {})
		helpers.assert_eq(state.tap_hold_config.escape, { tap = "paste", hold = "none", custom = { note = "keep" } })
		helpers.assert_eq(state.tap_hold_config.tab, { tap = "none", hold = "none" })
		helpers.assert_eq(state.mod_combos_config.esc_tab, { tap = "none", hold = "ctrl", combo = "none" })
	end)

	helpers.it("still warns about a present value of the wrong type", function()
		local state, _, warnings = load('[tap_holds]\nconfig = "opaque"\ntimeout_ms = "slow"\n')
		helpers.assert_eq(#warnings, 2, table.concat(warnings, " | "))
		helpers.assert_eq(state.tap_hold_config.escape, { tap = "none", hold = "none" })
	end)

	helpers.it("names outdated bindings once and never refuses a save over them (config-outdated-karabiner)", function()
		-- A retired key's scalar value reached the save, whose encoding asserted
		-- a table: every remap save failed with an ERROR. Retired entries were
		-- kept and re-saved in silence.
		local source = '[tap_holds.config]\nretired_key = "legacy"\n'
			.. '[tap_holds.config.escape]\ntap = "copy"\n'
			.. '[mod_combos.config.retired_combo]\nhold = "ctrl"\n'
		helpers.with_stub_scope({ "platform.remap.config", "adapters.file_system", "infra.logger", "logger.shim",
			"infra.toml.codec", "toml_codec" }, function()
			local warnings, errors = {}, {}
			local logger = helpers.make_logger_stub()
			logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
			logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
			package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
			require("config_outdated").reset_for_tests()
			local config = helpers.load_with_stubs("platform.remap.config")
			local files = require("adapters.file_system")
			local old_read, old_write = files.read_with_status, files.write_if_unchanged
			local written
			files.read_with_status = function() return source, "ok" end
			files.write_if_unchanged = function(_, content) written = content; return true end
			local ok, err = pcall(function()
				local keys, combos = { { id = "escape" }, { id = "tab" } }, { { id = "esc_tab" } }
				local state, status = config.load_user_config(keys, combos, "karabiner.toml")
				helpers.assert_eq(status, "ok")
				helpers.assert_nil(state.tap_hold_config.retired_key)
				helpers.assert_nil(state.mod_combos_config.retired_combo)
				helpers.assert_eq(state.tap_hold_config.escape, { tap = "copy", hold = "none" })
				local text = table.concat(warnings, "\n")
				helpers.assert_eq(#warnings, 2, text)
				for _, entry in ipairs({ "tap_holds.config.retired_key", "mod_combos.config.retired_combo" }) do
					helpers.assert_true(text:find("'" .. entry .. "' in 'karabiner.toml'", 1, true) ~= nil, entry .. ": " .. text)
				end
				config.load_user_config(keys, combos, "karabiner.toml")
				helpers.assert_eq(#warnings, 2, "a reload does not name them again")
				state.tap_hold_config.tab = { tap = "paste", hold = "none" }
				helpers.assert_true(config.save_user_config(state, "karabiner.toml"), "the save is never refused")
				helpers.assert_eq(errors, {})
				local stored = require("infra.toml.codec").decode(written)
				helpers.assert_eq(stored.tap_holds.config.tab.tap, "paste")
				helpers.assert_eq(stored.tap_holds.config.retired_key, "legacy", "a retired entry stays for the user to fix")
				helpers.assert_eq(stored.mod_combos.config.retired_combo.hold, "ctrl")
				source = '[tap_holds.config]\ntab = "legacy"\n'
				local known = config.load_user_config(keys, combos, "karabiner.toml")
				helpers.assert_eq(known.tap_hold_config.tab, { tap = "none", hold = "none" }, "it runs as neutral")
				helpers.assert_true(table.concat(warnings, "\n"):find("'tap_holds.config.tab' in 'karabiner.toml'", 1, true)
					~= nil, "a known key's unusable binding is named too")
			end)
			files.read_with_status, files.write_if_unchanged = old_read, old_write
			if not ok then error(err, 0) end
		end)
	end)
end)

return true
