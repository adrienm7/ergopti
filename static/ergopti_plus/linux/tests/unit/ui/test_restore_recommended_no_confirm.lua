--- tests/unit/ui/test_restore_recommended_no_confirm.lua

--- ==============================================================================
--- MODULE: Restore And Clear Ask Nothing (Linux)
--- DESCRIPTION:
--- Regression restore-recommended-no-confirm. Every « Restaurer les valeurs
--- conseillées » row of the tray used to open a default-No zenity question
--- before it applied, and the maintainer retired that step: a restore is
--- recoverable through the backup its owner writes first. On 2026-09-30 he
--- retired the « Tout effacer » question too, per menu and global alike, for
--- parity with Windows, which never asked. Each case clicks the real tray row
--- with zenity answering No, so a question that came back would also stop the
--- row, and checks that the values were applied after the backup.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")

local GESTURE_SOURCE = '[gestures]\nenabled = true\ntap_3 = "enter"\n[other]\nvalue = 42\n'
local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")

--- Runs `body` with zenity answering No to every question.
--- @param body function Clicks the rows under test.
--- @return table asked Every zenity question command.
local function with_zenity_answering_no(body)
	local execute, asked = os.execute, {}
	local previous_modal = package.loaded["ui.modal"]
	package.loaded["ui.modal"] = { run = function(callback) return callback() end }
	os.execute = function(command)
		if command:find("zenity", 1, true) then
			asked[#asked + 1] = command
			return 1
		end
		return execute(command)
	end
	local ok, err = pcall(body)
	os.execute = execute
	package.loaded["ui.modal"] = previous_modal
	if not ok then error(err, 0) end
	return asked
end

--- Builds the real tray and returns one row of one section.
--- @param ctx table Menu context.
--- @param section_key string i18n key of the section title.
--- @param row_key string i18n key of the row label.
--- @return table|nil row
local function tray_row(ctx, section_key, row_key)
	local i18n = require("infra.i18n")
	package.loaded["ui.menu.menu_builder"] = nil
	for _, section in ipairs(require("ui.menu.menu_builder").build(ctx)) do
		if type(section.title) == "string" and section.title:find(i18n.get(section_key), 1, true) == 1 then
			for _, row in ipairs(section.menu or {}) do
				if row.title == i18n.get(row_key) then return row end
			end
		end
	end
	return nil
end

--- Runs `body` with the real gesture manager over a sandboxed config.toml.
--- @param body function Receives the manager, the config path and the backups list.
local function with_gestures(body)
	Sandbox.with_config(GESTURE_SOURCE, function(path)
		local names = { "modules.gestures.manager", "adapters.evdev_reader", "ui.menu.menu_builder" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end }
		local backups = {}
		local ok, err = pcall(function()
			local gestures = require("modules.gestures.manager")
			gestures.init({ enabled = false, persist = true, config_path = path, is_paused = function() return false end })
			gestures.start_reading = function()
				gestures._test_begin_reading({})
				return true
			end
			helpers.assert_true(gestures.enable())
			local apply = gestures.apply_scope
			gestures.apply_scope = function(mode)
				local committed, detail, backup = apply(mode)
				if backup then backups[#backups + 1] = backup end
				return committed, detail, backup
			end
			body(gestures, path, backups)
		end)
		for _, backup in ipairs(backups) do os.remove(backup); os.remove(backup .. ".tmp") end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("restore-recommended-no-confirm: Gestures (Linux)", function()
	helpers.it("the restore row applies the recommended gestures without a question", function()
		with_gestures(function(gestures, path, backups)
			local ctx = { _version = "test", gestures = gestures, on_menu_changed = function() end }
			local row = tray_row(ctx, "menu.gestures.title", "common.restore_recommended")
			helpers.assert_true(row ~= nil and type(row.fn) == "function", "the real Gestures restore row")
			local asked = with_zenity_answering_no(function() row.fn() end)
			helpers.assert_eq(#asked, 0, "restoring the recommended values asks nothing")
			helpers.assert_eq(#backups, 1)
			helpers.assert_eq(Sandbox.read_bytes(backups[1]), GESTURE_SOURCE, "the backup is written before the restore")
			local Manifest = require("infra.manifest_reader")
			helpers.assert_eq(gestures.is_enabled(), Manifest.recommended_for("gestures.enabled"))
			for slot in pairs(gestures.DEFAULT_GESTURES) do
				helpers.assert_eq(gestures.get_action(slot), Manifest.recommended_for("gestures." .. slot), slot)
			end
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).other.value, 42)
		end)
	end)

	helpers.it("the clear row applies at once after its backup, without a question", function()
		with_gestures(function(gestures, path, backups)
			local ctx = { _version = "test", gestures = gestures, on_menu_changed = function() end }
			local row = tray_row(ctx, "menu.gestures.title", "common.clear_to_system")
			helpers.assert_true(row ~= nil and type(row.fn) == "function", "the real Gestures clear row")
			local asked = with_zenity_answering_no(function() row.fn() end)
			helpers.assert_eq(#asked, 0, "clearing asks nothing either")
			helpers.assert_eq(#backups, 1)
			helpers.assert_eq(Sandbox.read_bytes(backups[1]), GESTURE_SOURCE, "the backup is written before the clear")
			helpers.assert_true(Sandbox.read_bytes(path) ~= GESTURE_SOURCE, "the clear rewrote the file")
			helpers.assert_eq(gestures.is_enabled(), true, "the clear keeps the switch (gestures-clear-keeps-switch)")
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).other.value, 42)
		end)
	end)
end)

--- Runs `body` with the real tap-hold manager on the shared preset and the
--- scope transaction recorded.
--- @param body function Receives the menu context and the scope calls.
local function with_tap_holds(body)
	local names = { "platform.remap.tap_hold_manager", "infra.tap_hold_scope", "ui.menu.menu_builder" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local user_path = os.tmpname()
	local fh = assert(io.open(user_path, "w"))
	fh:write(require("tests.support.tap_hold_fixture").with_preset(nil))
	fh:close()
	local ok, err = pcall(function()
		local Manager = require("platform.remap.tap_hold_manager")
		Manager.init({
			keyboard_hook = { set_remapper = function() end, key_text = function() return nil end,
				held_modifiers = function() return {} end, held_text_modifier_codes = function() return {} end,
				held_shortcut_modifier_codes = function() return {} end },
			execute_action = function() end, on_text_injected = function() end,
			action_names = function() return {} end, defaults_path = DEFAULTS, user_path = user_path,
		})
		local calls = {}
		package.loaded["infra.tap_hold_scope"] = {
			apply = function(mode) calls[#calls + 1] = mode; return true end,
		}
		body({ _version = "test", on_quit = function() end, tap_holds = Manager }, calls)
		Manager._reset_for_test()
	end)
	os.remove(user_path)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("restore-recommended-no-confirm: Tap-Holds (Linux)", function()
	helpers.it("the restore row runs the recommended scope without a question", function()
		with_tap_holds(function(ctx, calls)
			local row = tray_row(ctx, "menu.tapholds.title", "common.restore_recommended")
			helpers.assert_true(row ~= nil and type(row.fn) == "function", "the real Tap-Holds restore row")
			local asked = with_zenity_answering_no(function() row.fn() end)
			helpers.assert_eq(#asked, 0, "restoring the recommended values asks nothing")
			helpers.assert_eq(calls, { "recommended" })
		end)
	end)

	helpers.it("the clear row runs the clear scope without a question", function()
		with_tap_holds(function(ctx, calls)
			local row = tray_row(ctx, "menu.tapholds.title", "common.clear_to_system")
			helpers.assert_true(row ~= nil and type(row.fn) == "function", "the real Tap-Holds clear row")
			local asked = with_zenity_answering_no(function() row.fn() end)
			helpers.assert_eq(#asked, 0, "clearing asks nothing either")
			helpers.assert_eq(calls, { "clear" })
		end)
	end)
end)

helpers.describe("restore-recommended-no-confirm: Configuration (Linux)", function()
	for _, case in ipairs({ { key = "common.restore_recommended", mode = "recommended" },
		{ key = "common.clear_to_system", mode = "clear" } }) do
		helpers.it("the global " .. case.mode .. " composes every category without a question", function()
			local names = { "infra.global_scope", "ui.menu.menu_builder" }
			local saved = {}
			for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local calls = {}
			local ok, err = pcall(function()
				package.loaded["infra.global_scope"] = {
					participants = function() calls[#calls + 1] = "participants"; return {} end,
					apply = function(mode) calls[#calls + 1] = mode; return true, { reverted = nil } end,
				}
				local ctx = { _version = "test", on_quit = function() end, is_paused = function() return false end }
				local row = tray_row(ctx, "menu.configuration.title", case.key)
				helpers.assert_true(row ~= nil and type(row.fn) == "function", "the real Configuration " .. case.mode .. " row")
				local asked = with_zenity_answering_no(function() row.fn() end)
				helpers.assert_eq(#asked, 0, "neither Configuration row asks")
			end)
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			if not ok then error(err, 0) end
			helpers.assert_eq(calls, { "participants", case.mode })
		end)
	end
end)
