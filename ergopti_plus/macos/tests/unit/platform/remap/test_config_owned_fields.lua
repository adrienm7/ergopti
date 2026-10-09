--- tests/unit/platform/remap/test_config_owned_fields.lua

--- ==============================================================================
--- MODULE: Remap Configuration Field Ownership
--- DESCRIPTION:
--- Ordinary tap-hold edits preserve fields outside the native writer's ownership,
--- including nested fields inside known keys and combinations.
--- ==============================================================================

local helpers = require("tests.helpers")

local SOURCE = '[other]\nvalue = 17\n[tap_holds]\nfuture = "keep"\n'
	.. '[tap_holds.config.escape]\ntap = "copy"\nhold = "ctrl"\ntimeout_ms = 250\n'
	.. '[tap_holds.config.escape.custom]\nnote = "keep"\n'
	.. '[tap_holds.config.future_key]\ntap = "future"\n'
	.. '[mod_combos]\nfuture = "keep"\n'
	.. '[mod_combos.config.esc_tab]\ntap = "copy"\nhold = "ctrl"\ncombo = "paste"\n'
	.. '[mod_combos.config.esc_tab.custom]\nnote = "keep"\n'
	.. '[mod_combos.config.future_combo]\ncombo = "future"\n'

--- Runs the actual codec and writer over a captured conditional publication.
--- @param source string Configuration bytes.
--- @param body function Assertions receiving save, state and captured bytes.
local function with_source(source, body)
	helpers.with_stub_scope({ "platform.remap.config", "adapters.file_system", "infra.toml.codec", "toml_codec" }, function()
		local config = helpers.load_with_stubs("platform.remap.config")
		local files = require("adapters.file_system")
		local codec = require("infra.toml.codec")
		local old_read, old_write = files.read_with_status, files.write_if_unchanged
		local captured = { writes = 0 }
		files.read_with_status = function() return source, "ok" end
		files.write_if_unchanged = function(path, content, expected)
			helpers.assert_eq(path, "owned-remap-config.toml")
			helpers.assert_eq(expected, { status = "ok", content = source })
			captured.writes, captured.content = captured.writes + 1, content
			return true
		end
		local state = config.build_default_state({ { id = "escape" } }, { { id = "esc_tab" } })
		state.tap_hold_config.escape = { tap = "paste", hold = "shift" }
		state.mod_combos_config.esc_tab = { tap = "none", hold = "none", combo = "none" }
		local ok, err = pcall(body, function() return config.save_user_config(state, "owned-remap-config.toml") end,
			state, captured, codec, config)
		files.read_with_status, files.write_if_unchanged = old_read, old_write
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Remap configuration owned fields", function()
	helpers.it("preserves unknown nested settings while publishing known tap-hold edits", function()
		with_source(SOURCE, function(save, _, captured, codec)
			helpers.assert_true(save())
			local stored = codec.decode(captured.content)
			helpers.assert_eq(stored.other.value, 17)
			helpers.assert_eq(stored.tap_holds.future, "keep")
			helpers.assert_eq(stored.tap_holds.config.escape, { tap = "paste", hold = "shift", custom = { note = "keep" } })
			helpers.assert_eq(stored.tap_holds.config.future_key, { tap = "future" })
			helpers.assert_eq(stored.mod_combos.future, "keep")
			helpers.assert_eq(stored.mod_combos.config.esc_tab,
				{ custom = { note = "keep" } })
			helpers.assert_eq(stored.mod_combos.config.future_combo, { combo = "future" })
			helpers.assert_eq(captured.writes, 1)
		end)
	end)
	for _, source in ipairs({ 'tap_holds = "opaque"\n', '[tap_holds]\nconfig = "opaque"\n',
		'[tap_holds.config]\nescape = "opaque"\n', 'mod_combos = "opaque"\n' }) do
		helpers.it("refuses a conflicting typed remap table without discarding it: " .. source:gsub("\n", " "), function()
			with_source(source, function(save, _, captured)
				helpers.assert_eq(save(), false)
				helpers.assert_eq(captured.writes, 0)
			end)
		end)
	end
	helpers.it("removes neutral leaves while preserving unknown neighbors and reloads the same intent", function()
		with_source(SOURCE, function(save, state, captured, codec, config)
			state.tap_hold_config.escape = { tap = "none", hold = "none" }
			helpers.assert_true(save())
			local stored = codec.decode(captured.content)
			helpers.assert_nil(stored.tap_holds.enabled)
			helpers.assert_nil(stored.tap_holds.timeout_ms)
			helpers.assert_nil(stored.tap_holds.sticky_timeout_ms)
			helpers.assert_nil(stored.mod_combos.simultaneous_threshold_ms)
			helpers.assert_nil(stored.mod_combos.symmetric)
			helpers.assert_eq(stored.tap_holds.config.escape, { custom = { note = "keep" } })
			helpers.assert_eq(stored.mod_combos.config.esc_tab, { custom = { note = "keep" } })
			helpers.assert_eq(stored.tap_holds.config.future_key.tap, "future")
			require("adapters.file_system").read_with_status = function() return captured.content, "ok" end
			local reloaded, status = config.load_user_config({ { id = "escape" } }, { { id = "esc_tab" } }, "owned-remap-config.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(reloaded.tap_holds_enabled, false)
			helpers.assert_eq(reloaded.tap_hold_timeout_ms, state.tap_hold_timeout_ms)
			helpers.assert_eq(reloaded.sticky_timeout_ms, state.sticky_timeout_ms)
			helpers.assert_eq(reloaded.simultaneous_threshold_ms, state.simultaneous_threshold_ms)
			helpers.assert_eq(reloaded.combo_symmetric, state.combo_symmetric)
		end)
	end)
	helpers.it("keeps explicit non-neutral bindings, master and custom timing values", function()
		with_source("", function(save, state, captured, codec)
			state.tap_holds_enabled = true
			state.tap_hold_timeout_ms = state.tap_hold_timeout_ms + 13
			state.sticky_timeout_ms = state.sticky_timeout_ms + 17
			state.simultaneous_threshold_ms = state.simultaneous_threshold_ms + 19
			state.combo_symmetric = not state.combo_symmetric
			state.tap_hold_config.escape.timeout_ms = 337
			helpers.assert_true(save())
			local stored = codec.decode(captured.content)
			helpers.assert_eq(stored.tap_holds.enabled, true)
			helpers.assert_eq(stored.tap_holds.timeout_ms, state.tap_hold_timeout_ms)
			helpers.assert_eq(stored.tap_holds.sticky_timeout_ms, state.sticky_timeout_ms)
			helpers.assert_eq(stored.tap_holds.config.escape, { tap = "paste", hold = "shift", timeout_ms = 337 })
			helpers.assert_eq(stored.mod_combos.simultaneous_threshold_ms, state.simultaneous_threshold_ms)
			helpers.assert_eq(stored.mod_combos.symmetric, state.combo_symmetric)
			helpers.assert_nil(stored.mod_combos.config)
		end)
	end)
	helpers.it("does not seed any setting when saving neutral intent", function()
		with_source("", function(save, state, captured, codec)
			state.tap_hold_config.escape = { tap = "none", hold = "none" }
			-- A settings-only candidate carries no « Ergopti uses Karabiner »
			-- decision; the switch is the remap owner's explicit write.
			state.enabled = nil
			helpers.assert_true(save())
			helpers.assert_eq(codec.decode(captured.content), {})
		end)
	end)

	helpers.it("writes only the carried Karabiner switch beside neutral settings", function()
		with_source("", function(save, state, captured, codec)
			state.tap_hold_config.escape = { tap = "none", hold = "none" }
			state.enabled = true
			helpers.assert_true(save())
			helpers.assert_eq(codec.decode(captured.content), { karabiner = { integration_enabled = true } })
		end)
	end)

end)

return true
