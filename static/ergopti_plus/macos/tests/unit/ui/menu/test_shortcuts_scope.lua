--- tests/unit/ui/menu/test_shortcuts_scope.lua

--- Exercises complete native shortcut scopes against real persistence and rollback owners.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcuts_scope_fixture")
local Codec = require("toml_codec")

helpers.describe("terminal macOS shortcut scopes", function()
	helpers.it("keeps raw physical claims through an unrelated script scope without synthesizing defaults", function()
		local source = '[shortcuts]\nenabled = true\nkeyboard = { hs_ctrl_c = "none", cmd_a = "future_action" }\n'
		Fixture.run(function(f)
			local before_actions, before_claims = f.keyboard.get_configuration_intent()
			helpers.assert_eq(before_actions, { hs_ctrl_c = "none" })
			helpers.assert_eq(before_claims, { hs_ctrl_c = true, cmd_a = true })
			local committed, detail = f.owner.apply("recommended", require("ui.menu.shortcuts_scope").script_chord_rows)
			helpers.assert_eq(committed, true, detail)
			local actions, claims = f.keyboard.get_configuration_intent()
			helpers.assert_eq(actions, before_actions, "unrelated scope preserves valid personal intent")
			helpers.assert_eq(claims, before_claims, "invalid stored choices still reserve their owned physical identity")
			local decoded = Codec.decode(f.files.config)
			helpers.assert_eq(decoded.shortcuts.keyboard, { hs_ctrl_c = "none", cmd_a = "future_action" })
		end, source)
	end)

	helpers.it("clears raw presence while retaining resolved manifest choices", function()
		Fixture.run(function(f)
			local committed, detail = f.owner.apply("clear")
			helpers.assert_eq(committed, true, detail)
			local actions, claims = f.keyboard.get_configuration_intent()
			helpers.assert_eq(actions, { magic_editor = "none" })
			helpers.assert_eq(claims, { magic_editor = true })
			helpers.assert_eq(f.keyboard.get_action("hs_ctrl_space"), "none")
			helpers.assert_eq(f.keyboard.get_action("magic_editor"), "none")
		end)
	end)

	helpers.it("clears exact native choices and parameters while preserving inline neighbors", function()
		Fixture.run(function(f)
			local before = f.files.config
			helpers.assert_eq(f.gestures.get_action_parameter("keyboard__cmd_a", "send_text"), "keyboard")
			local committed, detail = f.owner.apply("clear")
			helpers.assert_eq(committed, true, detail)
			local decoded = Codec.decode(f.files.config)
			helpers.assert_nil(decoded.shortcuts.enabled)
			helpers.assert_nil(decoded.shortcuts.keyboard.cmd_a)
			helpers.assert_eq(decoded.shortcuts.keyboard.foreign, 17)
			helpers.assert_eq(decoded.shortcuts.tap_keys.foreign, 21)
			helpers.assert_eq(decoded.shortcuts.script_control.future, 42)
			helpers.assert_eq(decoded.shortcuts.keys.future, true)
			helpers.assert_eq(decoded.future.keep, 7)
			helpers.assert_nil(decoded.gestures.action_parameters.keyboard__cmd_a__send_text)
			helpers.assert_nil(decoded.gestures.action_parameters.tap_key__number_row_left__send_text)
			helpers.assert_nil(decoded.gestures.action_parameters.script__script_altgr_enter__open_url)
			helpers.assert_eq(decoded.gestures.action_parameters.tap_4__open_url, "https://apple.com")
			helpers.assert_eq(decoded.gestures.action_parameters.future.keep, 9)
			helpers.assert_eq(f.gestures.get_action_parameter("keyboard__cmd_a", "send_text"), "")
			helpers.assert_eq(f.gestures.get_action_parameter("tap_4", "open_url"), "https://apple.com")
			helpers.assert_eq(f.files.backup, before)
			helpers.assert_eq(f.bindings.is_started(), false)
			helpers.assert_eq(f.keyboard.is_started(), false)
			helpers.assert_eq(f.keyboard.get_action("cmd_a"), "none")
			helpers.assert_eq(f.taps.get_action("number_row_left"), "none")
			helpers.assert_eq(f.state.shortcuts, false)
			-- script-chords-three-os-2026-09-30: an absent chord starts with its
			-- preset, so the clear writes each slot off and the chords stay native.
			for _, slot in ipairs({ "script_altgr_enter", "script_altgr_backspace", "script_altgr_delete",
				"script_altgr_escape" }) do
				helpers.assert_eq(decoded.shortcuts.script_control[slot], "none", slot)
				helpers.assert_eq(f.script.get_shortcut_actions()[slot], "none", slot)
				helpers.assert_eq(f.script.slot_runs(slot), false, slot)
			end
			helpers.assert_eq(f.script.is_started(), true)
			helpers.assert_eq(f.prefs.source_snapshot("config").content, f.files.config)
			helpers.assert_eq(f.save(), true)
		end)
	end)

	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("retains obsolete keyboard and tap parents and refuses " .. mode .. " collisions (config-outdated-shortcuts-reset)",
			function()
				-- Ordinary reset is not explicit cleanup. Clear's personal None
				-- for the magic editor also differs from neutral absence.
				local source = '[shortcuts]\nenabled = true\nkeyboard = "legacy"\ntap_keys = ["legacy"]\n[future]\nkeep = 7\n'
				Fixture.run(function(f)
					local checkpoint, native = f.checkpoint.capture(), #f.controls.native
					local actions, claims = f.keyboard.get_configuration_intent()
					local scripts, started = f.script.get_shortcut_actions(), f.script.is_started()
					local committed = f.owner.apply(mode)
					helpers.assert_eq(committed, false)
					helpers.assert_eq(f.files.config, source, "the entire obsolete source stays intact until cleanup")
					helpers.assert_eq(f.controls.writes, 0)
					helpers.assert_nil(f.files.backup)
					helpers.assert_eq(#f.controls.native, native, "collision refusal precedes native reacquisition")
					helpers.assert_eq(f.bindings.is_started(), true)
					helpers.assert_eq(f.keyboard.is_started(), true)
					helpers.assert_eq(f.script.is_started(), started)
					helpers.assert_eq(f.script.get_shortcut_actions(), scripts)
					local after_actions, after_claims = f.keyboard.get_configuration_intent()
					helpers.assert_eq(after_actions, actions)
					helpers.assert_eq(after_claims, claims)
					helpers.assert_eq(f.taps.get_action("number_row_left"), "none")
					helpers.assert_eq(f.keyboard.get_action("magic_editor"), "open_hotstrings_editor")
					helpers.assert_eq(f.prefs.source_snapshot("config").content, source)
					helpers.assert_eq(f.checkpoint.capture(), checkpoint)
					helpers.assert_eq(f.owner.pending(), false)
				end, source)
			end)
	end

	helpers.it("compensates refused publication with exact native choices and save baselines", function()
		Fixture.run(function(f)
			local before, checkpoint = f.files.config, f.checkpoint.capture()
			f.controls.refuse_write = true
			helpers.assert_eq(f.owner.apply("clear"), false)
			helpers.assert_eq(f.owner.pending(), false)
			helpers.assert_eq(f.files.config, before)
			helpers.assert_eq(f.bindings.is_started(), true)
			helpers.assert_eq(f.keyboard.is_started(), true)
			helpers.assert_eq(f.keyboard.get_action("cmd_a"), "send_text")
			helpers.assert_eq(f.taps.get_action("number_row_left"), "send_text")
			helpers.assert_eq(f.script.get_shortcut_actions().script_altgr_enter, "open_url")
			helpers.assert_eq(f.gestures.get_action_parameter("keyboard__cmd_a", "send_text"), "keyboard")
			helpers.assert_eq(f.prefs.source_snapshot("config").content, before)
			local restored = f.checkpoint.capture()
			helpers.assert_eq(restored.state, checkpoint.state)
			helpers.assert_eq(restored.preferences, checkpoint.preferences)
			helpers.assert_eq(restored.revision, checkpoint.revision + 2)
			f.controls.refuse_write = false
			helpers.assert_eq(f.save(), true)
		end)
	end)

	helpers.it("activates both real registries from OFF with the recommended candidate", function()
		Fixture.run(function(f)
			helpers.assert_eq(f.bindings.stop(), true)
			helpers.assert_eq(f.keyboard.stop(), true)
			helpers.assert_eq(f.shortcuts.pause_bindings("feature_toggle"), true)
			f.state.shortcuts = false
			helpers.assert_eq(f.bindings.is_started(), false)
			helpers.assert_eq(f.keyboard.is_started(), false)
			local committed, detail = f.owner.apply("recommended")
			helpers.assert_eq(committed, true, tostring(detail) .. ": " .. table.concat(f.controls.errors, "; "))
			helpers.assert_eq(f.bindings.is_started(), true)
			helpers.assert_eq(f.keyboard.is_started(), true)
			helpers.assert_eq(f.keyboard.get_action("cmd_a"), "none")
			helpers.assert_eq(f.taps.get_action("number_row_left"),
				require("infra.manifest_reader").recommended_for("shortcuts.tap_keys.number_row_left"))
			helpers.assert_eq(f.gestures.get_action_parameter("keyboard__cmd_a", "send_text"), "")
			local decoded = Codec.decode(f.files.config)
			helpers.assert_eq(decoded.shortcuts.enabled, true)
			helpers.assert_nil(decoded.shortcuts.keyboard.cmd_a)
			helpers.assert_eq(decoded.shortcuts.keyboard.foreign, 17)
			helpers.assert_eq(f.save(), true)
			helpers.assert_nil(Codec.decode(f.files.config).shortcuts.keyboard.cmd_a)
		end)
	end)

	for _, field in ipairs({ "paused", "idle", "stale_source", "native_mismatch" }) do
		helpers.it("refuses " .. field .. " before backup or native publication", function()
			Fixture.run(function(f)
				if field == "idle" then f.controls[field] = false
				elseif field == "stale_source" then f.files.config = f.files.config .. "# external editor\n"
				elseif field == "native_mismatch" then helpers.assert_eq(f.keyboard.stop(), true)
				else f.controls[field] = true end
				local before = f.files.config
				helpers.assert_eq(f.owner.apply("clear"), false)
				helpers.assert_eq(f.controls.writes, 0)
				helpers.assert_nil(f.files.backup)
				helpers.assert_eq(f.files.config, before)
				helpers.assert_eq(f.bindings.is_started(), true)
			end)
		end)
	end

	for _, failure in ipairs({ "keyboard", "binding", "script" }) do
		helpers.it("retains and retries a refused " .. failure .. " native inverse", function()
			Fixture.run(function(f)
				local before = f.files.config
				f.controls.refuse_write = true
				if failure == "script" then f.controls.refuse_script_start = true
				else f.controls.refuse_start = failure end
				helpers.assert_eq(f.owner.apply("clear"), false)
				helpers.assert_eq(f.files.config, before)
				helpers.assert_eq(f.owner.pending(), true)
				helpers.assert_eq(f.owner.retry_restore(), false)
				f.controls.refuse_start, f.controls.refuse_script_start = nil, false
				helpers.assert_eq(f.owner.retry_restore(), true)
				helpers.assert_eq(f.owner.pending(), false)
				helpers.assert_eq(f.bindings.is_started(), true)
				helpers.assert_eq(f.keyboard.is_started(), true)
				helpers.assert_eq(f.script.is_started(), true)
				helpers.assert_eq(f.keyboard.get_action("cmd_a"), "send_text")
				helpers.assert_eq(f.prefs.source_snapshot("config").content, before)
			end)
		end)
	end

	helpers.it("rejects a ScriptControl stop that returns its still-enabled handle", function()
		Fixture.run(function(f)
			local before = f.files.config
			f.controls.refuse_script_stop = true
			helpers.assert_eq(f.owner.apply("clear"), false)
			helpers.assert_eq(f.files.config, before)
			helpers.assert_eq(f.owner.pending(), true)
			f.controls.refuse_script_stop = false
			helpers.assert_eq(f.owner.retry_restore(), true)
			helpers.assert_eq(f.script.is_started(), true)
		end)
	end)

	helpers.it("fences a reentrant scope during conditional publication", function()
		Fixture.run(function(f)
			local attempts = 0
			f.controls.during_write = function(path)
				if path ~= "config" then return end
				attempts = attempts + 1
				helpers.assert_eq(f.owner.apply("recommended"), false)
			end
			helpers.assert_eq(f.owner.apply("clear"), true)
			helpers.assert_eq(attempts, 1)
			helpers.assert_eq(f.bindings.is_started(), false)
		end)
	end)

	for _, refused in ipairs({ false, true }) do
		helpers.it("settles only shortcut demotions, publication refused=" .. tostring(refused), function()
			Fixture.run(function(f)
				f.demotions.record({ feature = "shortcuts", key = "shortcuts", persisted = true, demoted = false })
				f.demotions.record({ feature = "metrics", key = "keylogger_enabled", persisted = true, demoted = false })
				f.controls.refuse_write = refused
				helpers.assert_eq(f.owner.apply("clear"), not refused)
				local remaining = f.demotions.list()
				helpers.assert_eq(#remaining, refused and 2 or 1)
				helpers.assert_eq(remaining[1].feature, "metrics")
			end)
		end)
	end

	helpers.it("preserves a stopped boot-owned ScriptControl eventtap", function()
		Fixture.run(function(f)
			helpers.assert_eq(f.script.stop(), true)
			helpers.assert_eq(f.owner.apply("clear"), true)
			helpers.assert_eq(f.script.is_started(), false)
		end)
	end)

	helpers.it("does not grant input ownership when clearing an absent configuration", function()
		Fixture.run(function(f)
			helpers.assert_eq(f.owner.apply("clear"), true)
			helpers.assert_eq(f.bindings.is_started(), false)
			helpers.assert_eq(f.keyboard.is_started(), false)
			helpers.assert_eq(f.taps.get_action("number_row_left"), "none")
			helpers.assert_eq(f.save(), true)
		end, false)
	end)

	helpers.it("refuses a success-shaped keyboard candidate that did not change its choices", function()
		Fixture.run(function(f)
			local apply, before = f.keyboard.apply_configuration, f.files.config
			f.keyboard.apply_configuration = function() return true end
			helpers.assert_eq(f.owner.apply("clear"), false)
			helpers.assert_eq(f.files.config, before)
			f.keyboard.apply_configuration = apply
			helpers.assert_eq(f.owner.retry_restore(), true)
			helpers.assert_eq(f.keyboard.get_action("cmd_a"), "send_text")
		end)
	end)

	helpers.it("keeps a real keyboard teardown refusal pending until exact handles release", function()
		Fixture.run(function(f)
			local before = f.files.config
			f.controls.refuse_stop = "keyboard"
			helpers.assert_eq(f.owner.apply("clear"), false)
			helpers.assert_eq(f.owner.pending(), true)
			helpers.assert_eq(f.files.config, before)
			f.controls.refuse_stop = nil
			helpers.assert_eq(f.owner.retry_restore(), true)
			helpers.assert_eq(f.keyboard.is_started(), true)
		end)
	end)

	helpers.it("uses the new scope checkpoint when a subsequent ordinary URL save refuses", function()
		Fixture.run(function(f)
			helpers.assert_eq(f.owner.apply("clear"), true)
			local before, url = f.files.config, f.bindings.get_chatgpt_url()
			helpers.assert_true(url ~= "https://example.test")
			f.state.chatgpt_url = "https://refused.test"
			helpers.assert_eq(f.bindings.set_chatgpt_url(f.state.chatgpt_url), true)
			f.controls.refuse_write = true
			helpers.assert_eq(f.save(), false)
			helpers.assert_eq(f.state.chatgpt_url, url)
			helpers.assert_eq(f.bindings.get_chatgpt_url(), url)
			helpers.assert_eq(f.files.config, before)
			helpers.assert_eq(f.state.shortcuts, false)
			helpers.assert_eq(f.bindings.is_started(), false)
		end)
	end)
end)

-- script-chords-three-os-2026-09-30: the four chords are one set on every
-- driver, their preset is their default, and the submenu's restore and clear
-- apply at once to the chords alone.
local PRESETS = {
	script_altgr_enter = "script_pause_toggle",
	script_altgr_backspace = "script_reload",
	script_altgr_delete = "open_personal_shortcuts",
	script_altgr_escape = "script_quit",
}

helpers.describe("macOS script chords in the Shortcuts scope", function()
	helpers.it("script-chord: the restore brings the four presets back", function()
		Fixture.run(function(f)
			local committed, detail = f.owner.apply("recommended")
			helpers.assert_eq(committed, true, detail)
			local chords = Codec.decode(f.files.config).shortcuts.script_control
			for slot, preset in pairs(PRESETS) do
				helpers.assert_nil(chords[slot], slot .. " back on its preset is a deletion")
				helpers.assert_eq(f.script.get_shortcut_actions()[slot], preset, slot)
				helpers.assert_eq(f.state.script_control_shortcuts[slot], preset, slot)
				helpers.assert_eq(f.script.slot_runs(slot), true, slot)
			end
			helpers.assert_eq(f.script.chords_enabled(), true)
		end)
	end)

	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("script-chord: the submenu's " .. mode .. " touches the chords only and asks nothing", function()
			Fixture.run(function(f)
				local asked = 0
				f.controls.on_confirm = function() asked = asked + 1 end
				local committed, detail = f.owner.apply(mode, require("ui.menu.shortcuts_scope").script_chord_rows)
				helpers.assert_eq(committed, true, detail)
				helpers.assert_eq(asked, 0, "the submenu's rows apply without a question")
				local decoded = Codec.decode(f.files.config)
				for slot, preset in pairs(PRESETS) do
					helpers.assert_eq(decoded.shortcuts.script_control[slot], mode == "clear" and "none" or nil, slot)
					helpers.assert_eq(f.script.get_shortcut_actions()[slot], mode == "clear" and "none" or preset, slot)
				end
				helpers.assert_nil(decoded.gestures.action_parameters.script__script_altgr_enter__open_url)
				helpers.assert_eq(decoded.gestures.action_parameters.keyboard__cmd_a__send_text, "keyboard")
				helpers.assert_eq(decoded.shortcuts.keyboard.cmd_a, "send_text")
				helpers.assert_eq(decoded.shortcuts.tap_keys.number_row_left, "send_text")
				helpers.assert_eq(decoded.shortcuts.enabled, true)
				helpers.assert_eq(f.keyboard.get_action("cmd_a"), "send_text")
				helpers.assert_eq(f.taps.get_action("number_row_left"), "send_text")
				helpers.assert_eq(f.bindings.is_started(), true)
				helpers.assert_eq(f.script.is_started(), true)
			end)
		end)
	end
end)

helpers.describe("macOS ordinary obsolete shortcut parent policy", function()
	for _, literal in ipairs({ '"legacy"', '["legacy"]', "[]" }) do
		helpers.it("clears neutral tap intent while retaining exact obsolete source " .. literal, function()
			local source = '[shortcuts]\nenabled = true\nkeyboard = { magic_editor = "none", future = "keep" } # keyboard retained\n'
				.. 'tap_keys = ' .. literal .. ' # taps retained\n[future]\nkeep = 7\n'
			local expected = '[shortcuts]\nkeyboard = { magic_editor = "none", future = "keep" } # keyboard retained\n'
				.. 'tap_keys = ' .. literal .. ' # taps retained\n[future]\nkeep = 7\n\n[shortcuts.script_control]\n'
				.. 'script_altgr_backspace = "none"\nscript_altgr_delete = "none"\nscript_altgr_enter = "none"\nscript_altgr_escape = "none"\n'
			Fixture.run(function(f)
				local committed, detail = f.owner.apply("clear")
				helpers.assert_eq(committed, true, detail)
				helpers.assert_eq(f.files.config, expected, "hand-authored complete image keeps the obsolete token and comments")
				helpers.assert_eq(f.files.backup, source)
				helpers.assert_eq(f.controls.writes, 2, "one backup and one acknowledged source publication")
				helpers.assert_eq(f.bindings.is_started(), false)
				helpers.assert_eq(f.keyboard.is_started(), false)
				helpers.assert_eq(f.script.chords_enabled(), true, "neutral absence retains the actual chord gate default")
				helpers.assert_eq(f.prefs.source_snapshot("config").content, expected)
				for _, id in ipairs({ "number_row_left", "number_row_right_1", "number_row_right_2" }) do
					helpers.assert_eq(f.taps.get_action(id), "none")
				end
				helpers.assert_eq(f.taps.decide(50), nil)
				package.loaded["modules.shortcuts.tap_keys"] = nil
				local fresh = require("modules.shortcuts.tap_keys")
				fresh.ensure_loaded(f.gestures.is_assignable)
				helpers.assert_eq(fresh.get_action("number_row_left"), "none", "fresh actual reader agrees with native ACK")
				helpers.assert_eq(fresh.decide(50), nil)
				helpers.assert_eq(fresh.decide(10), nil)
				helpers.assert_eq(f.owner.pending(), false)
			end, source)
		end)
	end

	for _, owner in ipairs({ "keyboard", "tap" }) do
		helpers.it("refuses ordinary " .. owner .. " assignment without replacing an obsolete parent", function()
			local source = '[shortcuts]\nenabled = true\nkeyboard = "legacy"\ntap_keys = ["legacy"]\n[future]\nkeep = 7\n'
			Fixture.run(function(f)
				local checkpoint, count = f.checkpoint.capture(), #f.controls.native
				local accepted
				if owner == "keyboard" then accepted = f.keyboard.set_action("cmd_a", "send_text")
				else accepted = f.taps.set_action("number_row_left", "send_text", f.gestures.is_assignable) end
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(f.files.config, source)
				helpers.assert_eq(f.controls.writes, 0)
				helpers.assert_eq(#f.controls.native, count)
				helpers.assert_eq(f.checkpoint.capture(), checkpoint)
				helpers.assert_eq(f.keyboard.get_action("cmd_a"), "none")
				helpers.assert_eq(f.taps.get_action("number_row_left"), "none")
				helpers.assert_eq(f.bindings.is_started(), true)
				helpers.assert_eq(f.prefs.source_snapshot("config").content, source)
			end, source)
		end)
	end

	helpers.it("compensates a refused neutral clear publication without erasing the obsolete parent", function()
		local source = '[shortcuts]\nenabled = true\nkeyboard = { magic_editor = "none", future = "keep" }\ntap_keys = ["legacy"]\n[future]\nkeep = 7\n'
		Fixture.run(function(f)
			local checkpoint = f.checkpoint.capture()
			f.controls.refuse_write = true
			helpers.assert_eq(f.owner.apply("clear"), false)
			helpers.assert_eq(f.files.config, source)
			helpers.assert_eq(f.files.backup, source)
			helpers.assert_eq(f.controls.writes, 1, "only the independently acknowledged backup was published")
			helpers.assert_eq(f.bindings.is_started(), true)
			helpers.assert_eq(f.keyboard.is_started(), true)
			helpers.assert_eq(f.taps.get_action("number_row_left"), "none")
			helpers.assert_eq(f.prefs.source_snapshot("config").content, source)
			helpers.assert_eq(f.owner.pending(), false)
			helpers.assert_eq(f.checkpoint.capture().state, checkpoint.state)
			helpers.assert_eq(f.checkpoint.capture().preferences, checkpoint.preferences)
			helpers.assert_eq(f.owner.retry_restore(), true, "the actual compensation journal is settled")
			helpers.assert_eq(f.files.config, source)
			package.loaded["modules.shortcuts.tap_keys"] = nil
			local fresh = require("modules.shortcuts.tap_keys")
			fresh.ensure_loaded(f.gestures.is_assignable)
			helpers.assert_eq(fresh.get_action("number_row_left"), "none")
		end, source)
	end)
end)

require("test.config_obsolete_parents_contract").register(helpers)
