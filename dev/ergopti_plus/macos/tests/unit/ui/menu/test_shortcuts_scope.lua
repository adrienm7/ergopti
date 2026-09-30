--- tests/unit/ui/menu/test_shortcuts_scope.lua

--- Exercises complete native shortcut scopes against real persistence and rollback owners.
local helpers = require("tests.helpers")
local Fixture = require("tests.support.shortcuts_scope_fixture")
local Codec = require("toml_codec")

helpers.describe("terminal macOS shortcut scopes", function()
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
			helpers.assert_nil(decoded.gestures.action_parameters.script__return_key__open_url)
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
			helpers.assert_eq(f.script.get_shortcut_actions().return_key, "none")
			helpers.assert_eq(f.script.is_started(), true)
			helpers.assert_eq(f.prefs.source_snapshot("config").content, f.files.config)
			helpers.assert_eq(f.save(), true)
		end)
	end)

	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("removes a plain keyboard or tap_keys value with its " .. mode .. " reset (config-outdated-shortcuts-reset)",
			function()
				-- The value an older build left where the scope keeps a table of
				-- assignments made every row below it unwritable, so the reset the
				-- user asked for was refused by the very value it replaces.
				local source = '[shortcuts]\nenabled = true\nkeyboard = "legacy"\ntap_keys = ["legacy"]\n[future]\nkeep = 7\n'
				Fixture.run(function(f)
					local committed, detail = f.owner.apply(mode)
					helpers.assert_eq(committed, true, detail)
					local decoded = Codec.decode(f.files.config)
					for _, key in ipairs({ "keyboard", "tap_keys" }) do
						local value = decoded.shortcuts and decoded.shortcuts[key]
						helpers.assert_true(value == nil or (type(value) == "table" and #value == 0),
							key .. " holds no outdated value after the reset: " .. f.files.config)
					end
					helpers.assert_eq(decoded.future.keep, 7, "the rest of the file is kept")
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
			helpers.assert_eq(f.script.get_shortcut_actions().return_key, "open_url")
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

	for _, field in ipairs({ "confirm", "paused", "idle", "modal_pause", "stale_source", "native_mismatch" }) do
		helpers.it("refuses " .. field .. " before backup or native publication", function()
			Fixture.run(function(f)
				if field == "confirm" or field == "idle" then f.controls[field] = false
				elseif field == "modal_pause" then f.controls.on_confirm = function() f.controls.paused = true end
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
