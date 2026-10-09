--- tests/support/program_parameter_fixture.lua

--- Real writer, preference checkpoint and global writer fence for picker fixtures.
local helpers = require("tests.helpers")
local Writer = require("toml_codec.writer")
local Manifest = require("infra.manifest_reader")
local Assignment = require("shortcuts.assignment")

return function(gestures, state, kind, read_action, save_attempt, controls)
	local noop = function() return true end
	controls = controls or {}
	-- Exact focused discovery must not depend on another test priming Paths.
	package.loaded["infra.paths"] = { shared = helpers.shared, shared_root = function() return helpers.shared() end }
	local content = '[gestures]\ntap_3 = "none"\naction_parameters = { retained = "unrelated" }\n[shortcuts.keyboard]\ncmd_1 = "none"\n[shortcuts.tap_keys]\nnumber_row_left = "none"\n[shortcuts.script_control]\nscript_altgr_enter = "none"\n'
	if controls and controls.absent then content = nil end
	local files = { config = content }
	local files_port = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write_if_unchanged = function(path, value, expected)
			if expected.status == "ok" and files[path] ~= expected.content then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			files[path] = value
			return true
		end,
		remove_exact = function(path) files[path] = nil; return true end,
		remove_if_unchanged = function(path, expected)
			if expected.status ~= "ok" or files[path] ~= expected.content then return false end
			files[path] = nil
			if controls.after_remove then controls.after_remove(files) end
			local settled = controls.remove_release_failure ~= true
			local receipt = { path = path, expected = expected, removed = true,
				is_settled = function() return settled end,
				matches_source = function() return files[path] == nil end,
				retry = function()
					if files[path] ~= nil or controls.remove_release_failure then return false end
					if not controls.false_remove_settlement then settled = true end
					return true
				end,
			}
			return settled, nil, receipt
		end,
	}
	-- Script saves carry a final pure native-publication fence, not merely CAS.
	function files_port.write_if_unchanged_admitted(path, value, expected, _, admission)
		if type(expected) ~= "table" or getmetatable(expected) ~= nil or type(admission) ~= "function" then return false end
		local status, content = rawget(expected, "status"), rawget(expected, "content")
		if not (status == "ok" and type(content) == "string" or status == "absent" and content == nil) then return false end
		local called, admitted = pcall(admission)
		if not called or admitted ~= true then return false end
		if status ~= (files[path] and "ok" or "absent") or status == "ok" and files[path] ~= content then return false end
		return files_port.write_if_unchanged(path, value, { status = status, content = content })
	end
	package.loaded["adapters.file_system"] = files_port
	package.loaded["infra.preferences"] = nil
	local preferences = require("infra.preferences")
	preferences.load("config")
	local previous_get_actions = gestures.get_all_actions
	gestures.get_all_actions = function()
		if kind == "gesture" then return { tap_3 = read_action() } end
		return previous_get_actions and previous_get_actions() or {}
	end
	local save, checkpoint = require("ui.menu.preferences_transaction").bind(preferences, {
		path = "config", state = state, hotfiles = {}, core_modules = { gestures = gestures },
		initial_state = state, initial_preferences = preferences.snapshot(state, {}, { gestures = gestures }),
		restore_runtime = noop,
		builder = { invalidate_cache = function() if controls.cache_throw then error("private cache failure") end end },
		on_commit = function()
			if controls.commit_throw then error("private commit failure") end
			if controls.after_commit then controls.after_commit() end
		end,
		snapshot_view = controls.snapshot_view,
	})
	local global = require("ui.menu.global_actions_transaction").create({
		state = state, capture_preferences = function() return {} end, sync_runtime = noop,
		restore_state = noop,
		settings = { get = function() end, set = noop, get_keys = function() return {} end },
		file_mover = { capture = function() return {} end, move = noop, restore = noop },
		reset_journal = { prepare = noop, mark_commit = noop, mark_prepared = noop, clear = noop },
		gestures = { get_action = read_action, set_action = noop, enable_all = noop, disable_all = noop },
		shortcuts = { set_shortcut_action = noop, get_keyboard_action = read_action,
			set_keyboard_action = noop, get_keyboard_assignments = function() return {} end },
		karabiner = { snapshot_settings = function() return {} end, reset_to_defaults = noop, restore_settings = noop },
		request_reload = noop, terminal_pending = function() return false end,
	})
	assert(global, "real global writer fixture unavailable")
	package.loaded["ui.menu.program_parameter_transaction"] = nil
	local owner = require("ui.menu.program_parameter_transaction").new({
		path = "config", files = files_port, gestures = gestures, preferences = preferences, checkpoint = checkpoint,
		paused = function() return false end, admission = global.run_exclusive,
		current_path = function() return controls.current_path or "config" end,
		capture_checkpoint_candidate = function()
			return { state = require("ui.menu.preferences_transaction").clone(state),
				preferences = preferences.snapshot(state, {}, { gestures = gestures }) }
		end,
		save_prefs = function(on_error)
			if save_attempt() ~= true then return false end
			return save(on_error) == true
		end,
	})
	local function publish_assignment(value, on_error)
		local section = kind == "keyboard" and "shortcuts.keyboard" or "shortcuts.tap_keys"
		local key = kind == "keyboard" and "cmd_1" or "number_row_left"
		local row
		if kind == "keyboard" then row = Assignment.operation(key, value, function() return true end, gestures.is_assignable)
		else row = Manifest.sparse_operation(section .. "." .. key, value) end
		local source = preferences.source_snapshot("config")
		local rows = preferences.prepare_shortcut_updates(source, { row }, { kind == "keyboard" and "keyboard" or "tap_keys" })
		return preferences.publish_owned("config", rows, source, on_error)
	end
	return owner, publish_assignment, files, global, preferences, checkpoint, files_port, content
end
