--- tests/unit/ui/menu/test_llm_scope.lua

--- Runs the real planner, preference owner, runtime reconciler and transaction.
local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")
local FS = require("adapters.file_system")
local function clone(value)
	if type(value) ~= "table" then return value end
	local out = {}; for key, child in pairs(value) do out[key] = clone(child) end; return out
end

local function fixture(demoted)
	local original = '[llm]\nenabled = true\napi_key = "keep-private"\ntrigger = { debounce_ms = 425, future = 19 }\n[llm.profiles]\nshortcuts = { basic = { mods = ["ctrl"], key = "B", future = 29 }, foreign = { key = "K", future = 39 } }\n[metrics]\nenabled = true\n'
	local files, control, writes = { config = original }, {}, 0
	local adapter = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("conditional publication required") end,
		write_if_unchanged = function(path, content, expected)
			if path == "config" and control.publication then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			if expected.status == "ok" and files[path] ~= expected.content then return false end
			files[path], writes = content, writes + 1; return true
		end,
	}
	package.loaded["adapters.file_system"] = adapter
	local Preferences = helpers.load_with_stubs("infra.preferences")
	for _, name in ipairs({ "ui.menu.llm_scope", "ui.menu.menu_llm.scope_runtime", "ui.menu.scoped_preferences" }) do package.loaded[name] = nil end
	Preferences.load("config")
	local state, values = {}, {}
	for _, row in ipairs(Manifest.scope_operations("llm", "clear")) do
		local path = row.section .. "." .. row.key
		local key = assert(Preferences.flat_key_for(path))
		state[key] = clone(Preferences.state_value_for(path, Manifest.default_for(path)))
		values[key] = clone(state[key])
	end
	state.llm_enabled, state.llm_debounce = not demoted, 0.425
	values.llm_debounce = 0.425
	state.llm_profile_shortcuts = { basic = { mods = { "ctrl" }, key = "B", future = 29 }, foreign = { key = "K", future = 39 } }
	state.llm_model, state.llm_model_power = "prior-engine-model", 2
	values.llm_model, values.llm_display_model_name, values.llm_backend_name = "prior-engine-model", "Prior", "Prior backend"
	local enabled, starts = not demoted, 0
	local core_state = { backend = "ollama", llm_model_ollama = "prior-ollama", llm_model_mlx = "prior-mlx",
		active_profile_id = "basic", user_profiles = {}, user_override_backend = false }
	local core = {
		configuration_snapshot = function() return clone(core_state) end,
		apply_configuration = function(candidate) core_state = clone(candidate); return true end,
	}
	local keymap = {
		get_llm_enabled = function() return enabled end,
		set_llm_enabled = function(value)
			enabled = value; if value then starts = starts + 1 end
			if control.gate then return "accepted" end
			return true
		end,
		get_llm_runtime_setting = function(key) return true, clone(values[key]) end,
	}
	for key in pairs(values) do
		if key ~= "llm_enabled" then keymap["set_" .. key] = function(value)
			if control.noop == key then return nil end
			values[key] = clone(value)
			if control.setting == key then return false end
		end end
	end
	keymap.set_llm_configuration_model = keymap.set_llm_model
	local hotkeys = { llm_profile_shortcuts = { basic = { mods = { "ctrl" }, key = "B", enabled = false } } }
	local runtime = require("ui.menu.menu_llm.scope_runtime").new({
		state = state, core = core, keymap = keymap, idle = function() return control.busy ~= true end,
		shortcuts = { configuration_snapshot = function() return clone(hotkeys) end,
			apply_configuration = function(value) hotkeys = clone(value); return control.shortcut or true end },
		reset_health = function() return true end, model_power = function() return 1 end,
		display_model = function(model) return model end, backend_label = function(backend) return backend end,
	})
	local demotions = require("ui.menu.session_demotions").new()
	if demoted then demotions.record({ feature = "ai", key = "llm_enabled", persisted = true, demoted = false }) end
	local save, checkpoint = require("ui.menu.preferences_transaction").bind(Preferences, {
		path = "config", state = state, hotfiles = {}, core_modules = {}, initial_state = state,
		initial_preferences = Preferences.snapshot(state, {}, {}), restore_runtime = function() return true end,
		snapshot_view = demotions.persisted_view,
	})
	local owner = require("ui.menu.llm_scope").new({
		path = "config", files = adapter, state = state, preferences = Preferences, checkpoint = checkpoint,
		demotions = demotions, runtime = runtime, profiles = function() if control.registry_unavailable then return nil end; return { { id = "basic" } } end,
		capture_preferences = function() return Preferences.snapshot(state, {}, {}) end,
		admission = function(_, callback) return callback() end, paused = function() return false end,
		backup_path = function() return "backup" end,
	})
	return owner, state, files, control, save, demotions, function() return enabled, starts, hotkeys, core_state end,
		function() return writes end, original, values
end

helpers.describe("macOS complete LLM scope", function()
	helpers.it("refuses unavailable profile ownership before backup", function()
		local owner, _, files, control, _, _, _, writes, original = fixture()
		control.registry_unavailable = true
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(writes(), 0)
		helpers.assert_eq(files.config, original)
	end)

	helpers.it("clears consent and known leaves while preserving inline neighbors and credentials", function()
		local owner, state, files, _, save, _, native, _, original = fixture()
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(native(), false)
		local _, _, live_shortcuts = native()
		helpers.assert_nil(live_shortcuts.llm_profile_shortcuts.foreign, "unknown stored neighbors cannot acquire hotkeys")
		helpers.assert_eq(state.llm_enabled, false)
		helpers.assert_eq(state.llm_debounce, 0.2)
		helpers.assert_eq(save(), true)
		local value = Codec.decode(files.config)
		helpers.assert_nil(value.llm.enabled)
		helpers.assert_nil(value.llm.trigger.debounce_ms)
		helpers.assert_eq(value.llm.trigger.future, 19)
		helpers.assert_nil(value.llm.profiles.shortcuts.basic.key)
		helpers.assert_eq(value.llm.profiles.shortcuts.basic.future, 29)
		helpers.assert_eq(value.llm.profiles.shortcuts.foreign.key, "K")
		helpers.assert_eq(value.llm.api_key, "keep-private")
		helpers.assert_eq(value.metrics.enabled, true)
		helpers.assert_eq(files.backup, original)
	end)

	helpers.it("restores recommendations without granting a demoted AI consent", function()
		local owner, state, files, _, save, demotions, native = fixture(true)
		helpers.assert_eq(owner.apply("recommended"), true)
		local enabled, starts = native()
		helpers.assert_eq(enabled, false)
		helpers.assert_eq(starts, 0)
		helpers.assert_eq(state.llm_enabled, false)
		helpers.assert_eq(#demotions.list(), 1)
		helpers.assert_eq(save(), true)
		helpers.assert_eq(Codec.decode(files.config).llm.enabled, true)
	end)

	helpers.it("refuses busy native owners before writing a backup", function()
		for _, field in ipairs({ "busy" }) do
			local owner, _, files, control, _, _, _, writes, original = fixture()
			control[field] = true
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(writes(), 0)
			helpers.assert_eq(files.config, original)
		end
	end)

	helpers.it("compensates source publication and preserves the prior dormant shortcut posture", function()
		local owner, state, files, control, save, _, native, _, original, values = fixture()
		control.publication = true
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(owner.pending(), false)
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(state.llm_debounce, 0.425)
		helpers.assert_eq(values.llm_debounce, 0.425)
		local enabled, _, hotkeys, core = native()
		helpers.assert_eq(enabled, true)
		helpers.assert_eq(hotkeys.llm_profile_shortcuts.basic.enabled, false)
		helpers.assert_eq(core.backend, "ollama")
		control.publication = false
		helpers.assert_eq(save(), true)
	end)

	helpers.it("refuses an ignored scalar setter by checking the actual native value", function()
		local owner, state, files, control, _, _, _, _, original, values = fixture()
		control.noop = "llm_debounce"
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(owner.pending(), false)
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(values.llm_debounce, 0.425)
		helpers.assert_eq(state.llm_debounce, 0.425)
	end)

	helpers.it("Clear consumes only the selected consent demotion", function()
		local owner, _, files, _, save, demotions = fixture(true)
		demotions.record({ feature = "metrics", key = "keylogger_enabled", persisted = true, demoted = false })
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(#demotions.list(), 1)
		helpers.assert_eq(demotions.list()[1].feature, "metrics")
		helpers.assert_eq(save(), true)
		helpers.assert_nil(Codec.decode(files.config).llm.enabled)
	end)

	helpers.it("retains nonterminal native acknowledgements until the inverse really settles", function()
		for _, field in ipairs({ "gate", "shortcut" }) do
			local owner, _, files, control, _, _, _, _, original = fixture()
			control[field] = "accepted"
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(files.config, original)
			control[field] = nil
			helpers.assert_eq(owner.retry_restore(), true)
			helpers.assert_eq(owner.pending(), false)
		end
	end)
end)

package.loaded["adapters.file_system"] = FS
package.loaded["infra.preferences"] = nil
