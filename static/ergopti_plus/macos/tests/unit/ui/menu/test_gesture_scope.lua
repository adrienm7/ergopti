--- tests/unit/ui/menu/test_gesture_scope.lua

local helpers = require("tests.helpers")
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")
local FileSystem = require("adapters.file_system")

local function fixture(source)
	package.loaded["adapters.file_system"] = FileSystem
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["modules.gestures.conflicts"] = nil
	helpers.load_with_stubs("modules.gestures.actions")
	local gestures = helpers.load_with_stubs("modules.gestures")
	local controls, state, files = {}, { gestures = true }, {}
	local original = source or '[gestures]\nenabled = true\ntap_4 = "open_url"\nmodes = { swipe_3_horiz = "incremental", future = "keep" }\nsensitivities = { swipe_3_horiz = 9, future = 17 }\naction_parameters = { tap_4__open_url = "https://apple.com", keyboard__cmd_k__open_url = "https://example.com", future = { preserve = 7 } }\n[future]\nkeep = 42\n'
	files.config = original
	if source == false then files.config = nil end
	local enabled, writes = true, 0
	gestures.is_enabled = function() return enabled end
	gestures.enable_all = function()
		if controls.refuse_enable then return false end
		enabled = true
		return true
	end
	gestures.disable_all = function()
		if controls.refuse_disable then return false end
		enabled = false
		return true
	end
	gestures.set_action("tap_4", "open_url")
	gestures.set_mode("swipe_3_horiz", "incremental")
	gestures.set_sensitivity("swipe_3_horiz", 9)
	gestures.set_action_parameter("tap_4", "open_url", "https://apple.com")
	gestures.set_action_parameter("keyboard__cmd_k", "open_url", "https://example.com")
	local files_port = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("unguarded write") end,
		write_if_unchanged = function(path, value, expected)
			if controls.refuse_write and path == "config" then return false end
			if expected.status == "ok" and files[path] ~= expected.content then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			if path == "config" and controls.during_write then controls.during_write() end
			files[path] = value
			writes = writes + 1
			return true
		end,
	}
	package.loaded["adapters.file_system"] = files_port
	local prefs = helpers.load_with_stubs("infra.preferences")
	prefs.load("config")
	local PT = require("ui.menu.preferences_transaction")
	local modules = { gestures = gestures }
	local demotions = require("ui.menu.session_demotions").new()
	controls.demotions = demotions
	local save, checkpoint = PT.bind(prefs, {
		path = "config", state = state, hotfiles = {}, core_modules = modules,
		initial_state = state, initial_preferences = prefs.snapshot(state, {}, modules),
		snapshot_view = demotions.persisted_view,
		restore_runtime = function(snapshot)
			gestures.set_action("tap_4", snapshot.gesture_actions.tap_4)
			return true
		end,
	})
	local owner = require("ui.menu.gesture_scope").new({
		path = "config", files = files_port, state = state, gestures = gestures,
		preferences = prefs, checkpoint = checkpoint,
		demotions = demotions,
		capture_preferences = function() return prefs.snapshot(state, {}, modules) end,
		backup_path = function() return "backup" end,
		paused = function() return controls.paused == true end,
		admission = function(_, callback) return callback() end,
	})
	return owner, gestures, files, state, controls, prefs, save, function() return writes end, original
end

local function menu_commands(owner, gestures, state)
	local original_renderer = package.loaded["infra.manifest_menu"]
	local original_menu = package.loaded["ui.menu.menu_gestures"]
	local commands
	package.loaded["infra.manifest_menu"] = { build = function(_, _, _, _, context)
		commands = context.commands
		return {}
	end }
	package.loaded["ui.menu.menu_gestures"] = nil
	local ok, detail = pcall(function()
		require("ui.menu.menu_gestures").build({ gestures = gestures, state = state, paused = false,
			apply_gesture_scope = owner.apply, save_prefs = function() error("scope must not use ordinary save") end,
			updateMenu = function() end })
	end)
	package.loaded["infra.manifest_menu"] = original_renderer
	package.loaded["ui.menu.menu_gestures"] = original_menu
	if not ok then error(detail) end
	return commands
end

helpers.describe("macOS complete gesture scope", function()
	helpers.it("clears every owned setting and parameter while preserving nested neighbors", function()
		local owner, gestures, files, state, _, prefs, save, writes, original = fixture()
		local committed, detail = menu_commands(owner, gestures, state).scope_clear()
		helpers.assert_eq(committed, true, detail)
		local decoded = Codec.decode(files.config)
		helpers.assert_eq(decoded.gestures.enabled, nil)
		helpers.assert_eq(decoded.gestures.tap_4, nil)
		helpers.assert_eq(decoded.gestures.modes.swipe_3_horiz, nil)
		helpers.assert_eq(decoded.gestures.modes.future, "keep")
		helpers.assert_eq(decoded.gestures.sensitivities.swipe_3_horiz, nil)
		helpers.assert_eq(decoded.gestures.sensitivities.future, 17)
		helpers.assert_eq(decoded.gestures.action_parameters.tap_4__open_url, nil)
		helpers.assert_eq(decoded.gestures.action_parameters.future.preserve, 7)
		helpers.assert_eq(decoded.gestures.action_parameters.keyboard__cmd_k__open_url, "https://example.com")
		helpers.assert_eq(files.backup, original)
		helpers.assert_eq(writes(), 2)
		helpers.assert_eq(state.gestures, false)
		helpers.assert_eq(gestures.is_enabled(), false)
		for slot in pairs(gestures.DEFAULT_GESTURES) do helpers.assert_eq(gestures.get_action(slot), "none") end
		helpers.assert_eq(gestures.get_mode("swipe_3_horiz"), Manifest.default_for("gestures.modes.swipe_3_horiz"))
		helpers.assert_eq(gestures.get_sensitivity("swipe_3_horiz"), Manifest.default_for("gestures.sensitivities.swipe_3_horiz"))
		helpers.assert_eq(prefs.source_snapshot("config").content, files.config)
		helpers.assert_eq(save(), true, "the next real save must use the new baseline")
	end)
	helpers.it("restores recommendations and seeds the rollback snapshot used by a later failed save", function()
		local owner, gestures, files, state, controls, _, save = fixture()
		helpers.assert_eq(menu_commands(owner, gestures, state).scope_restore(), true)
		for slot, value in pairs(gestures.RECOMMENDED_GESTURES) do helpers.assert_eq(gestures.get_action(slot), value) end
		helpers.assert_eq(state.gestures, Manifest.recommended_for("gestures.enabled"))
		local committed = files.config
		controls.refuse_write = true
		gestures.set_action("tap_4", "open_url")
		helpers.assert_eq(save(), false)
		helpers.assert_eq(gestures.get_action("tap_4"), gestures.RECOMMENDED_GESTURES.tap_4)
		helpers.assert_eq(files.config, committed)
	end)
	helpers.it("a pause leaves every store untouched", function()
		for _, mode in ipairs({ "clear", "recommended" }) do
			local owner, gestures, files, _, controls, _, _, writes, original = fixture()
			controls.paused = true
			helpers.assert_eq(owner.apply(mode), false)
			helpers.assert_eq(writes(), 0)
			helpers.assert_eq(files.config, original)
			helpers.assert_eq(gestures.get_action("tap_4"), "open_url")
		end
	end)
	helpers.it("refused publication restores native state and both preference baselines", function()
		local owner, gestures, files, state, controls, prefs, save, _, original = fixture()
		controls.refuse_write = true
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(state.gestures, true)
		helpers.assert_eq(gestures.is_enabled(), true)
		helpers.assert_eq(gestures.get_action("tap_4"), "open_url")
		helpers.assert_eq(gestures.get_action_parameter("tap_4", "open_url"), "https://apple.com")
		helpers.assert_eq(prefs.source_snapshot("config").content, original)
		helpers.assert_eq(owner.pending(), false)
		controls.refuse_write = false
		helpers.assert_eq(save(), true)
	end)
	helpers.it("refuses stale source before backup and retains failed native compensation", function()
		local owner, gestures, files, _, controls, _, _, writes = fixture()
		files.config = '[future]\nexternal = true\n'
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(writes(), 0)
		helpers.assert_eq(gestures.get_action("tap_4"), "open_url")
		owner, gestures, files, _, controls = fixture()
		controls.refuse_write, controls.refuse_enable = true, true
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(owner.pending(), true)
		controls.refuse_enable = false
		helpers.assert_eq(owner.retry_restore(), true)
		helpers.assert_eq(owner.pending(), false)
		helpers.assert_eq(gestures.is_enabled(), true)
	end)
	helpers.it("the next save preserves unknown parameter neighbors when the owned registry is empty", function()
		local owner, gestures, files, _, _, _, save = fixture(
			'[gestures]\naction_parameters = { tap_4__open_url = "https://apple.com", future = { preserve = 7 } }\n')
		gestures.replace_action_parameters({ tap_4__open_url = "https://apple.com" })
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(next(gestures.get_all_action_parameters()), nil)
		helpers.assert_eq(save(), true)
		helpers.assert_eq(Codec.decode(files.config).gestures.action_parameters.future.preserve, 7)
	end)
	helpers.it("clear explicitly ends only gesture demotions, with an inverse when publication fails", function()
		for _, refuse in ipairs({ false, true }) do
			local owner, gestures, files, state, controls, _, save = fixture()
			controls.demotions.record({ feature = "gestures", key = "gestures", persisted = true, demoted = false })
			controls.demotions.record({ feature = "llm", key = "llm_enabled", persisted = true, demoted = false })
			state.gestures = false
			gestures.disable_all()
			controls.refuse_write = refuse
			helpers.assert_eq(owner.apply("clear"), not refuse)
			helpers.assert_eq(#controls.demotions.list(), refuse and 2 or 1)
			if not refuse then
				helpers.assert_eq(controls.demotions.list()[1].feature, "llm")
				helpers.assert_eq(save(), true)
				helpers.assert_eq(Codec.decode(files.config).gestures.enabled, nil)
			end
		end
	end)
	helpers.it("supports an absent source and refuses nonterminal native setters", function()
		local owner, _, files, _, _, prefs = fixture(false)
		helpers.assert_eq(owner.apply("clear"), true)
		helpers.assert_eq(files.backup, nil)
		helpers.assert_eq(prefs.source_snapshot("config").content, files.config)
		local gestures, controls, original
		owner, gestures, files, _, controls, prefs, _, _, original = fixture()
		local setter = gestures.set_action
		gestures.set_action = function(slot, value) setter(slot, value); return "accepted" end
		helpers.assert_eq(owner.apply("clear"), false)
		helpers.assert_eq(files.config, original)
		helpers.assert_eq(prefs.source_snapshot("config").content, original)
		helpers.assert_eq(owner.pending(), true)
		gestures.set_action = setter
		helpers.assert_eq(owner.retry_restore(), true)
	end)
end)

package.loaded["adapters.file_system"] = FileSystem
package.loaded["infra.preferences"] = nil
