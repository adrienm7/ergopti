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
end)

return true
