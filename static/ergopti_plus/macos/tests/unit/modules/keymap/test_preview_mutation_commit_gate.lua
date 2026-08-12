--- tests/unit/modules/keymap/test_preview_mutation_commit_gate.lua

--- Drives a real registry row through the real preview bridge and public keymap
--- setter. A native canvas hide failure must abort semantic mutation while
--- retaining the exact old action lease; every registry writer must cross the
--- same already-behaviorally-proven fence.

local helpers = require("tests.helpers")

local function fresh_runtime(effects)
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^adapters%.")
			or name == "modules.keylogger"
			or name == "modules.llm"
			or name == "modules.llm.prediction_engine"
			or name == "ui.tooltip"
		) then
			package.loaded[name] = nil
		end
	end

	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() return false end,
	}
	package.loaded["modules.llm.prediction_engine"] = {
		init = function() end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function()
			effects.reset_calls = effects.reset_calls + 1
			return true
		end,
	}
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		notify_synthetic = function() end,
		set_buffer = function() end,
		log_hotstring = function() end,
	}

	local function hide_surface()
		effects.hide_calls = effects.hide_calls + 1
		if not effects.allow_hide then return false end
		effects.visible = false
		return true
	end
	package.loaded["ui.tooltip"] = {
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		set_colorization_enabled = function() end,
		set_accent_color = function() end,
		tint = function() return {} end,
		show_stacked = function(rows)
			effects.rows = rows
			effects.visible = true
			return true
		end,
		hide = hide_surface,
		hide_forced = hide_surface,
		hide_forced_silent = hide_surface,
		is_visible = function() return effects.visible end,
		is_hotstring_visible = function() return effects.visible end,
		has_visible_hotstring_lease = function(token)
			return effects.visible
				and type(effects.rows) == "table"
				and effects.rows[1]
				and effects.rows[1].lease_token == token
		end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = { resolve = function() return nil end }
	package.loaded["adapters.tooltip_renderer"] = { hide = function() return true end }

	return helpers.load_with_stubs("modules.keymap")
end

helpers.describe("keymap semantic mutations wait for native preview revocation", function()
	helpers.it("keeps the old engine state and lease when canvas hide fails", function()
		local effects = { allow_hide = true, hide_calls = 0, reset_calls = 0, visible = false }
		local Keymap = fresh_runtime(effects)
		local Registry = assert(package.loaded["modules.keymap.registry"])
		local Bridge = assert(package.loaded["modules.keymap.llm_bridge"])

		helpers.assert_eq(type(Keymap.invalidate_hotstring_preview), "function")
		helpers.assert_true(Keymap.set_trigger_char("a"))
		helpers.assert_true(Keymap.set_base_delay(0))
		helpers.assert_true(Keymap.add("olda", "promised", {
			auto_expand = true,
			is_case_sensitive = true,
			is_case_sensitive_strict = true,
		}) ~= false)
		helpers.assert_true(Keymap.sort_mappings() ~= false)
		local mapping = Registry.mappings_for_literal_magic_tail("d")[1]
		helpers.assert_not_nil(mapping)

		Bridge.update_preview("old")
		_G.hs.timer.__fire_all()
		helpers.assert_true(effects.visible)
		helpers.assert_true(Keymap.owns_visible_magic_action(mapping, "old"),
			"the control must establish a physically committed exact action lease")
		local resets_before_mutation = effects.reset_calls

		effects.allow_hide = false
		helpers.assert_eq(Keymap.set_base_delay(1), false,
			"a failed hide must reject timing semantics too")
		helpers.assert_eq(Keymap.get_base_delay(), 0,
			"the visible promise must retain the delay under which it was offered")
		helpers.assert_eq(Keymap.add("newz", "uncommitted", { auto_expand = true }), false,
			"the registry wrapper must reject a write behind still-visible pixels")
		helpers.assert_nil(Registry.mappings_for_tail("z"),
			"a rejected registry write must not leak into the engine")
		helpers.assert_eq(Keymap.set_trigger_char("b"), false,
			"a failed native hide must reject the semantic mutation")
		helpers.assert_eq(Keymap.get_trigger_char(), "a",
			"the registry must still describe the promise left on screen")
		helpers.assert_true(Keymap.owns_visible_magic_action(mapping, "old"),
			"failed revocation must retain ownership of still-visible pixels")
		helpers.assert_eq(effects.reset_calls, resets_before_mutation,
			"logical reset must not run before native revocation commits")

		effects.allow_hide = true
		helpers.assert_true(Keymap.set_trigger_char("b"))
		helpers.assert_eq(Keymap.get_trigger_char(), "b")
		helpers.assert_eq(Keymap.owns_visible_magic_action(mapping, "old"), false)
		helpers.assert_eq(effects.reset_calls, resets_before_mutation + 1)
	end)

	helpers.it("routes the complete public registry-writer class through that fence", function()
		local source = helpers.read_driver_source("local ACTION_EPOCH_LISTENER_ID")
		helpers.assert_not_nil(source, "modules/keymap/init.lua must be locatable")
		local writers = {
			"add", "load_file", "load_toml", "disable_section", "enable_section",
			"set_sections_enabled", "disable_group", "register_lua_group", "enable_group",
			"sort_mappings", "set_repeat_feature_enabled", "set_terminator_enabled",
			"add_custom_terminator", "remove_custom_terminator",
		}
		for _, name in ipairs(writers) do
			local escaped = name:gsub("_", "_")
			local pattern = "M%." .. escaped .. "%s*=%s*preview_fenced_registry_mutation%(Registry%."
				.. escaped .. "%)"
			helpers.assert_true(source:match(pattern) ~= nil,
				("public registry writer '%s' must use the proven preview fence"):format(name))
		end
	end)
end)

return true
