--- tests/unit/ui/menu/test_metrics_scope.lua

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local FS = require("adapters.file_system")
local Manifest = require("infra.manifest_reader")

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function fixture(demoted)
	local original = '[metrics]\nenabled = true\nprivate_filter_enabled = false\nencrypt = true\nfloat_colors = false\nfuture = { keep = 9 }\nshortcut = { mods = ["cmd"], key = "m", future = 7 } # legacy typing\napps_shortcut = "unsupported" # legacy apps\n[llm]\nenabled = true\napi_key = "untouched"\n'
	local files, control, writes = { config = original, history = "private historical bytes" }, {}, 0
	local adapter = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("conditional publication required") end,
		write_if_unchanged = function(path, content, expected)
			if path == "config" and control.publication then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			if expected.status == "ok" and expected.content ~= files[path] then return false end
			files[path], writes = content, writes + 1
			return true
		end,
	}
	package.loaded["adapters.file_system"] = adapter
	local Preferences = helpers.load_with_stubs("infra.preferences")
	package.loaded["ui.menu.metrics_scope"] = nil
	Preferences.load("config")
	local state = {}
	for _, row in ipairs(Manifest.scope_operations("metrics", "clear")) do
		local path = row.section .. "." .. row.key
		state[Preferences.flat_key_for(path)] = clone(Manifest.default_for(path))
	end
	state.keylogger_enabled, state.keylogger_private_filter_enabled = not demoted, false
	state.keylogger_encrypt, state.keylogger_float_colors = true, false
	local demotions = require("ui.menu.session_demotions").new()
	if demoted then demotions.record({ feature = "metrics", key = "keylogger_enabled", persisted = true, demoted = false }) end
	local native = { enabled = not demoted, options = { encrypt = true }, cipher_enabled = true,
		disabled_apps = {}, private_filter_enabled = false, secure_field_filter_enabled = true,
		system_auth_filter_enabled = true }
	local core, starts = {}, 0
	core.configuration_snapshot = function()
		if control.conversion then return nil end
		return clone(native)
	end
	core.apply_configuration = function(value)
		local enabled = native.enabled
		native = clone(value); native.enabled = enabled
		return true
	end
	core.stop = function() native.enabled = false; return control.stop_result or true end
	core.start = function() starts = starts + 1; native.enabled = true; return control.restore_result or true end
	local bar = { running = not demoted, colors = false }
	local widget = { running = not demoted, colors = false, graph = false }
	local function display(value)
		return {
			configuration_snapshot = function() return clone(value) end,
			apply_configuration = function(config)
				for key, child in pairs(config) do value[key] = child end
				return true
			end,
		}
	end
	local save, checkpoint = require("ui.menu.preferences_transaction").bind(Preferences, {
		path = "config", state = state, hotfiles = {}, core_modules = {}, initial_state = state,
		initial_preferences = Preferences.snapshot(state, {}, {}), restore_runtime = function() return true end,
		snapshot_view = demotions.persisted_view,
	})
	local owner = require("ui.menu.metrics_scope").new({
		path = "config", files = adapter, state = state, preferences = Preferences, checkpoint = checkpoint,
		demotions = demotions, core = core, menubar = display(bar), widget = display(widget),
		capture_preferences = function() return Preferences.snapshot(state, {}, {}) end,
		admission = function(_, callback) return callback() end, paused = function() return false end,
		backup_path = function() return "backup" end,
		activation_pending = function() return control.pending == true end,
		capture_shortcuts = function() error("retired shortcut snapshot must not be used") end,
		apply_shortcut = function() error("retired shortcut owner must not be called") end,
	})
	return owner, state, files, control, function() return native, starts end, save, demotions,
		function() return writes end, original, bar, widget
end

helpers.describe("macOS complete Metrics scope", function()
	helpers.it("Clear revokes only Metrics consent and leaves history, credentials and unknown fields intact", function()
		local owner, state, files, _, runtime, save, _, _, original, bar, widget = fixture()
		helpers.assert_eq(owner.apply("clear"), true)
		local native, starts = runtime()
		helpers.assert_eq(native.enabled, false)
		helpers.assert_eq(starts, 0)
		helpers.assert_eq(state.keylogger_enabled, false)
		helpers.assert_eq(bar.running, false)
		helpers.assert_eq(widget.running, false)
		helpers.assert_eq(save(), true)
		local decoded = Codec.decode(files.config)
		helpers.assert_eq(decoded.metrics.enabled, nil)
		helpers.assert_eq(decoded.metrics.future.keep, 9)
		helpers.assert_eq(decoded.metrics.shortcut.future, 7)
		helpers.assert_eq(decoded.metrics.apps_shortcut, "unsupported")
		helpers.assert_true(files.config:find('shortcut = { mods = ["cmd"], key = "m", future = 7 } # legacy typing\n', 1, true) ~= nil)
		helpers.assert_true(files.config:find('apps_shortcut = "unsupported" # legacy apps\n', 1, true) ~= nil)
		helpers.assert_eq(decoded.llm.enabled, true)
		helpers.assert_eq(decoded.llm.api_key, "untouched")
		helpers.assert_eq(files.history, "private historical bytes")
		helpers.assert_eq(files.backup, original)
	end)
	helpers.it("Restore preserves consent and a boot demotion through the next ordinary save", function()
		for _, demoted in ipairs({ false, true }) do
			local owner, state, files, _, runtime, save, demotions = fixture(demoted)
			helpers.assert_eq(owner.apply("recommended"), true)
			local native, starts = runtime()
			helpers.assert_eq(native.enabled, not demoted)
			helpers.assert_eq(starts, 0, "Restore cannot grant or retry collection consent")
			helpers.assert_eq(state.keylogger_enabled, not demoted)
			helpers.assert_eq(#demotions.list(), demoted and 1 or 0)
			helpers.assert_eq(save(), true)
			helpers.assert_eq(Codec.decode(files.config).metrics.enabled, true)
		end
	end)
	helpers.it("Clear ends the selected consent demotion without resurrecting it on save", function()
		local owner, _, files, _, _, save, demotions = fixture(true)
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(#demotions.list(), 0)
		helpers.assert_eq(save(), true)
		helpers.assert_eq(Codec.decode(files.config).metrics.enabled, nil)
	end)
	helpers.it("pending native activation refuses before backup", function()
		for _, field in ipairs({ "pending", "conversion" }) do
			local owner, _, files, control, _, _, _, writes, original = fixture()
			control[field] = true
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(writes(), 0)
			helpers.assert_eq(files.config, original)
		end
	end)
	helpers.it("compensates publication refusal and nonterminal stop, retaining a refused inverse", function()
		for _, field in ipairs({ "publication", "stop_result", "restore_result" }) do
			local owner, state, files, control, runtime, save, _, _, original = fixture()
			control[field] = field == "publication" and true or "accepted"
			if field == "restore_result" then control.publication = true end
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(files.config, original)
			if field == "restore_result" then
				helpers.assert_eq(owner.pending(), true)
				control.restore_result = nil
				helpers.assert_eq(owner.retry_restore(), true)
			end
			helpers.assert_eq(state.keylogger_enabled, true)
			helpers.assert_eq(runtime().enabled, true)
			control.publication, control.stop_result = nil, nil
			helpers.assert_eq(save(), true)
		end
	end)
end)

package.loaded["adapters.file_system"] = FS
package.loaded["infra.preferences"] = nil

helpers.describe("Metrics scope provider", function()
	-- The restore alone since the maintainer retired the Metrics clear on
	-- 2026-09-30; the owner's clear above stays for the Configuration clear.
	helpers.it("routes the restore through the actual Metrics scope port, and registers no clear", function()
		local renderer = require("infra.manifest_menu")
		local old, captured = renderer.build
		renderer.build = function(_, _, _, _, ctx) captured = ctx; return {} end
		local ok, err = xpcall(function()
			local menu = helpers.load_with_stubs("ui.menu.menu_metrics")
			local selected, mode, paused
			menu.build({ state = { keylogger_enabled = false, keylogger_disabled_apps = {} },
				base_dir = helpers.driver_root(), updateMenu = function() end,
				script_control = { is_paused = function() return paused == true end },
				save_prefs = function() error("only the scope transaction publishes") end,
				apply_preference_scope = function(scope, value) selected, mode = scope, value; return true end })
			helpers.assert_nil(captured.commands.scope_clear, "the Metrics menu offers no clear")
			helpers.assert_eq(captured.commands.scope_restore(), true)
			helpers.assert_eq(selected, "metrics")
			helpers.assert_eq(mode, "recommended")
			paused, mode = true, nil
			helpers.assert_eq(captured.commands.scope_restore(), false)
			helpers.assert_nil(mode, "a paused session runs no scope")
		end, debug.traceback)
		renderer.build = old
		if not ok then error(err, 0) end
	end)
end)
