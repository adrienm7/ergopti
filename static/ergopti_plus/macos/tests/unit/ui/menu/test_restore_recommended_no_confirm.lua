--- tests/unit/ui/menu/test_restore_recommended_no_confirm.lua

--- ==============================================================================
--- MODULE: Restore And Clear Ask Nothing (macOS)
--- DESCRIPTION:
--- Regression restore-recommended-no-confirm. Every « Restaurer les valeurs
--- conseillées » row used to open a default-No question before it applied,
--- and the maintainer retired that step: a restore is recoverable through the
--- backup its owner writes first. On 2026-09-30 he retired the « Tout effacer »
--- question too, per menu and global alike (« action directe partout, la
--- sauvegarde suffit »). Each case drives the real path with every question
--- answered No, so a question that came back would also stop the row, and
--- checks that the values were applied after the backup.
--- ==============================================================================

local helpers = require("tests.helpers")
local tap_helpers, runtime_inputs = require("tests.support.remap_menu_runtime_inputs").bind(helpers)
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")
local FileSystem = require("adapters.file_system")

local GESTURE_SOURCE = '[gestures]\nenabled = true\ntap_4 = "open_url"\n'
	.. 'action_parameters = { tap_4__open_url = "https://apple.com" }\n[future]\nkeep = 42\n'

--- Builds the real gesture scope over an in-memory config.toml; a dialog
--- double records each question and answers No.
--- @return table fixture owner, gestures, files, state, asked, writes().
local function gesture_fixture()
	package.loaded["adapters.file_system"] = FileSystem
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["modules.gestures.conflicts"] = nil
	helpers.load_with_stubs("modules.gestures.actions")
	local gestures = helpers.load_with_stubs("modules.gestures")
	local files, state, asked, writes = { config = GESTURE_SOURCE }, { gestures = true }, {}, 0
	local enabled = true
	gestures.is_enabled = function() return enabled end
	gestures.enable_all = function() enabled = true; return true end
	gestures.disable_all = function() enabled = false; return true end
	gestures.set_action("tap_4", "open_url")
	gestures.set_action_parameter("tap_4", "open_url", "https://apple.com")
	local files_port = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("unguarded write") end,
		write_if_unchanged = function(path, value, expected)
			if expected.status == "ok" and files[path] ~= expected.content then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			files[path] = value
			writes = writes + 1
			return true
		end,
	}
	package.loaded["adapters.file_system"] = files_port
	local prefs = helpers.load_with_stubs("infra.preferences")
	prefs.load("config")
	local modules = { gestures = gestures }
	local demotions = require("ui.menu.session_demotions").new()
	local _, checkpoint = require("ui.menu.preferences_transaction").bind(prefs, {
		path = "config", state = state, hotfiles = {}, core_modules = modules,
		initial_state = state, initial_preferences = prefs.snapshot(state, {}, modules),
		snapshot_view = demotions.persisted_view,
		restore_runtime = function() return true end,
	})
	local owner = require("ui.menu.gesture_scope").new({
		path = "config", files = files_port, state = state, gestures = gestures,
		preferences = prefs, checkpoint = checkpoint, demotions = demotions,
		capture_preferences = function() return prefs.snapshot(state, {}, modules) end,
		backup_path = function() return "backup" end,
		paused = function() return false end,
		admission = function(_, callback) return callback() end,
	})
	return { owner = owner, gestures = gestures, files = files, state = state, asked = asked,
		writes = function() return writes end }
end

--- Returns the commands the real Gestures submenu registers for its rows.
--- @param fixture table gesture_fixture() result.
--- @return table commands Row id -> click handler.
local function gesture_commands(fixture)
	local original_renderer = package.loaded["infra.manifest_menu"]
	local original_menu = package.loaded["ui.menu.menu_gestures"]
	local original_dialog = package.loaded["infra.dialog_util"]
	local commands
	package.loaded["infra.manifest_menu"] = { group_receiver = require("tests.support.declared_menu_parent_fixture").new().group_receiver, build = function(_, _, _, _, context)
		commands = context.commands
		return {}
	end }
	package.loaded["infra.dialog_util"] = { block_alert = function(_, message, no)
		fixture.asked[#fixture.asked + 1] = message
		return no
	end }
	package.loaded["ui.menu.menu_gestures"] = nil
	local ok, detail = pcall(function()
		require("ui.menu.menu_gestures").build({ gestures = fixture.gestures, state = fixture.state, paused = false,
			apply_gesture_scope = fixture.owner.apply,
			save_prefs = function() error("a scope row must not use the ordinary save") end,
			updateMenu = function() end })
	end)
	package.loaded["infra.manifest_menu"] = original_renderer
	package.loaded["ui.menu.menu_gestures"] = original_menu
	if not ok then
		package.loaded["infra.dialog_util"] = original_dialog
		error(detail, 0)
	end
	-- The dialog double stays for the click; the caller's run restores it.
	fixture.restore_dialog = function() package.loaded["infra.dialog_util"] = original_dialog end
	return commands
end

helpers.describe("restore-recommended-no-confirm: Gestures (macOS)", function()
	helpers.it("the restore row applies the recommended gestures without a question", function()
		local fixture = gesture_fixture()
		local commands = gesture_commands(fixture)
		local ok, result = pcall(commands.scope_restore)
		fixture.restore_dialog()
		helpers.assert_true(ok, tostring(result))
		helpers.assert_eq(result, true)
		helpers.assert_eq(#fixture.asked, 0, "restoring the recommended values asks nothing")
		for slot, value in pairs(fixture.gestures.RECOMMENDED_GESTURES) do
			helpers.assert_eq(fixture.gestures.get_action(slot), value, slot)
		end
		helpers.assert_eq(fixture.state.gestures, Manifest.recommended_for("gestures.enabled"))
		helpers.assert_eq(fixture.files.backup, GESTURE_SOURCE, "the backup is written before the restore")
		helpers.assert_eq(Codec.decode(fixture.files.config).future.keep, 42)
	end)

	helpers.it("the clear row applies at once after its backup, without a question", function()
		local fixture = gesture_fixture()
		local commands = gesture_commands(fixture)
		local ok, result = pcall(commands.scope_clear)
		fixture.restore_dialog()
		helpers.assert_true(ok, tostring(result))
		helpers.assert_eq(result, true)
		helpers.assert_eq(#fixture.asked, 0, "clearing asks nothing either")
		helpers.assert_eq(fixture.files.backup, GESTURE_SOURCE, "the backup is written before the clear")
		helpers.assert_eq(fixture.gestures.get_action("tap_4"), "none")
		helpers.assert_eq(fixture.state.gestures, true, "the clear keeps the switch (gestures-clear-keeps-switch)")
		helpers.assert_eq(Codec.decode(fixture.files.config).future.keep, 42)
	end)
end)

package.loaded["adapters.file_system"] = FileSystem
package.loaded["infra.preferences"] = nil

--- A remap facade double recording each scope request; its terminal is true.
--- @param requests table Receives every apply_scope request.
--- @return table remap
local function remap_double(requests)
	return {
		get_runtime = runtime_inputs.get_runtime,
		shared_runtime_selected = runtime_inputs.shared_runtime_selected,
		runtime_unavailable_reason = runtime_inputs.runtime_unavailable_reason,
		get_enabled = function() return true end,
		get_tap_holds_enabled = function() return true end,
		apply_scope = function(request, on_done)
			requests[#requests + 1] = request
			on_done(true, "ready", 1)
			return true
		end,
	}
end

--- Runs one Tap-Holds row of the real submenu with every question answered No.
--- @param id string Manifest row id.
--- @return boolean accepted
--- @return table requests Remap scope requests.
--- @return table asked Dialog messages shown.
--- @return number refreshes Menu refreshes.
local function run_tap_hold_row(id)
	local names = { "infra.dialog_util", "infra.config_paths", "infra.manifest_menu", "ui.menu.menu_tap_holds" }
	return helpers.with_fresh_modules(names, function()
		local asked, requests, refreshes, commands = {}, {}, 0, nil
		package.loaded["infra.dialog_util"] = { block_alert = function(_, message, no)
			asked[#asked + 1] = message
			return no
		end }
		package.loaded["infra.config_paths"] = { get = function() return "/remap/config_karabiner.toml" end }
		package.loaded["infra.manifest_menu"] = { group_receiver = require("tests.support.declared_menu_parent_fixture").new().group_receiver, build = function(menu_key, _, _, _, context)
			if menu_key == "tap_holds_menu" then commands = context.commands end
			return {}
		end }
		local menu = helpers.load_with_stubs("ui.menu.menu_tap_holds")
		menu.build({ karabiner = remap_double(requests), updateMenu = function() refreshes = refreshes + 1 end })
		helpers.assert_type(commands and commands[id], "function", "the Tap-Holds submenu registers " .. id)
		return commands[id](), requests, asked, refreshes
	end)
end

helpers.describe("restore-recommended-no-confirm: Tap-Holds (macOS)", function()
	tap_helpers.it("the restore row sends the recommended scope without a question", function()
		local accepted, requests, asked, refreshes = run_tap_hold_row("scope_restore")
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(#asked, 0, "restoring the recommended values asks nothing")
		helpers.assert_eq(#requests, 1)
		helpers.assert_eq(requests[1].scope, "tap_holds")
		helpers.assert_eq(requests[1].mode, "recommended")
		helpers.assert_true(requests[1].backup_path:find("^/remap/config_karabiner%.toml%.tap_holds%-") ~= nil,
			"the remap file is backed up first: " .. tostring(requests[1].backup_path))
		helpers.assert_eq(refreshes, 1, "the menu refreshes once the terminal commits")
	end)

	tap_helpers.it("the clear row sends the clear scope without a question", function()
		local accepted, requests, asked, refreshes = run_tap_hold_row("scope_clear")
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(#asked, 0, "clearing asks nothing either")
		helpers.assert_eq(#requests, 1)
		helpers.assert_eq(requests[1].scope, "tap_holds")
		helpers.assert_eq(requests[1].mode, "clear")
		helpers.assert_true(requests[1].backup_path:find("^/remap/config_karabiner%.toml%.tap_holds%-") ~= nil,
			"the remap file is backed up first: " .. tostring(requests[1].backup_path))
		helpers.assert_eq(refreshes, 1)
	end)
end)

--- Builds the real global scope over synchronous owner doubles.
--- @param trace table Receives each owner call.
--- @return table global
local function global_scope(trace)
	local owners = {}
	for _, name in ipairs({ "gestures", "shortcuts", "keyboard_layout", "hotstrings", "llm", "metrics" }) do
		local owner = {}
		function owner.apply(mode) trace[#trace + 1] = name .. ":" .. mode; return true end
		function owner.revert() return true end
		function owner.release() end
		function owner.pending() return false end
		function owner.retry_restore() return true end
		owners[name] = function() return owner end
	end
	return helpers.load_with_stubs("ui.menu.global_scope").new({
		owners = owners,
		backup_path = function(scope) return "/remap.toml.global-" .. scope end,
		defer = function(continuation) continuation(); return true end,
		paused = function() return false end,
		refresh = function() end,
	})
end

helpers.describe("restore-recommended-no-confirm: Configuration (macOS)", function()
	for _, mode in ipairs({ "recommended", "clear" }) do
		helpers.it("the global " .. mode .. " composes every category without a question", function()
			local trace = {}
			helpers.assert_eq(global_scope(trace).apply(mode), true)
			table.sort(trace)
			helpers.assert_eq(trace, { "gestures:" .. mode, "hotstrings:" .. mode, "keyboard_layout:" .. mode,
				"llm:" .. mode, "metrics:" .. mode, "shortcuts:" .. mode })
		end)
	end
end)

--- Captures the options ui.menu.init hands to one scope owner module; the
--- owner applies without asking and records the mode.
--- @param captured table Module name -> options.
--- @param applied table Receives module:mode entries.
--- @param name string Owner module name.
local function capture_owner(captured, applied, name)
	package.loaded[name] = { new = function(options)
		captured[name] = options
		return {
			apply = function(mode) applied[#applied + 1] = name .. ":" .. mode; return true end,
			unavailable = function() return nil end,
		}
	end }
end

helpers.describe("restore-recommended-no-confirm: the menu's scope wiring (macOS)", function()
	helpers.it("no restore or clear row asks, and no owner is handed a question port", function()
		local owners = { "ui.menu.gesture_scope", "ui.menu.shortcuts_scope", "ui.menu.llm_scope",
			"ui.menu.metrics_scope", "ui.menu.hotstrings_scope", "ui.menu.scoped_preferences",
			"ui.menu.global_scope" }
		local names = { "infra.dialog_util", "modules.hotstrings.hotstrings_config" }
		for _, name in ipairs(owners) do names[#names + 1] = name end
		helpers.with_fresh_modules(names, function()
			local asked, captured, applied = {}, {}, {}
			package.loaded["infra.dialog_util"] = { block_alert = function(title, message, no, yes)
				asked[#asked + 1] = { title, message, no, yes }
				return no
			end }
			package.loaded["modules.hotstrings.hotstrings_config"] = {
				get_override_path = function() return "/virtual/hotstrings_config.toml" end,
			}
			local fixture = require("tests.support.menu_boot_fixture").boot()
			local actions = fixture.global_actions()
			-- After the boot, whose stub loader sweeps every ui.menu module: the
			-- owners are required on the first click.
			for _, name in ipairs(owners) do capture_owner(captured, applied, name) end
			local ctx = fixture.ctx
			-- The Shortcuts and AI owners need runtimes this boot does not start.
			package.loaded["ui.menu.menu_shortcuts"].scope_idle = function() return true end
			ctx.llm_handler.scope_runtime = {}
			for _, mode in ipairs({ "recommended", "clear" }) do
				helpers.assert_eq(ctx.apply_gesture_scope(mode), true)
				for _, scope in ipairs({ "shortcuts", "keyboard_layout", "hotstrings", "llm", "metrics" }) do
					helpers.assert_eq(ctx.apply_preference_scope(scope, mode), true, scope)
				end
			end
			helpers.assert_eq(actions.reset_defaults(), true)
			helpers.assert_eq(actions.clear_to_system(), true, "the Configuration clear runs the global clear")
			helpers.assert_eq(#asked, 0, "no restore or clear asks")
			table.sort(applied)
			local expected = {}
			for _, name in ipairs(owners) do
				for _, mode in ipairs({ "clear", "recommended" }) do expected[#expected + 1] = name .. ":" .. mode end
			end
			table.sort(expected)
			helpers.assert_eq(applied, expected)
			for _, name in ipairs(owners) do
				helpers.assert_type(captured[name], "table", name)
				helpers.assert_nil(captured[name].confirm, name .. " is handed no question port")
			end
		end)
	end)
end)

return true
