--- tests/unit/infra/test_gesture_scope.lua

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")

local SOURCE = '[gestures]\nenabled = true\ntap_3 = "enter"\n[gesture_parameters]\ntap_3__open_url = "https://old.example"\nkeyboard__ctrl_j__open_url = "https://keyboard.example"\nunknown = "keep"\n[linux.gestures]\ntap_4 = "vol_up"\nunknown = "keep"\n[linux.action_parameters]\ntap_4__open_url = "https://legacy.example"\nkeyboard__ctrl_k__open_url = "https://keep.example"\n[other]\nvalue = 42\n'

local function with_scope(body)
	Sandbox.with_config(SOURCE, function(path)
		local manager_name = "modules.gestures.manager"
		local original_manager = package.loaded[manager_name]
		local original_reader = package.loaded["adapters.evdev_reader"]
		package.loaded[manager_name] = nil
		package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end }
		local backup = path .. ".scope-backup"
		local controls = { backups = {} }
		local ok, err = pcall(function()
			local gestures = require(manager_name)
			gestures.init({ enabled = false, persist = true, config_path = path,
				is_paused = function() return controls.paused == true end })
			gestures.start_reading = function()
				if controls.refuse_reader then return false end
				gestures._test_begin_reading({})
				return true
			end
			helpers.assert_true(gestures.enable())
			local files = {
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional writes are forbidden") end,
				write_if_unchanged = function(target, content, expected)
					if controls.refuse == target then return false, "injected publication refusal" end
					if controls.external_edit and target == path then Sandbox.write_bytes(path, controls.external_edit) end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			local owner = require("infra.gesture_scope").new({
				path = path, backup_path = backup, gestures = gestures, files = files,
			})
			body(owner, gestures, controls, path, backup)
		end)
		package.loaded[manager_name] = original_manager
		package.loaded["adapters.evdev_reader"] = original_reader
		os.remove(backup)
		os.remove(backup .. ".tmp")
		for _, created in ipairs(controls.backups) do os.remove(created) os.remove(created .. ".tmp") end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Linux gesture scope transaction", function()
	helpers.it("gesture-master-close: refused native stop preserves file and retains its inverse", function()
		with_scope(function(_, gestures, _, path)
			gestures.stop_reading = function() return false end
			helpers.assert_eq(gestures.set_enabled(false), false)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(gestures.is_enabled())
			helpers.assert_true(gestures.is_reading())
		end)
	end)

	helpers.it("gesture-master-rollback: refused publication and reader restoration retain admission", function()
		with_scope(function(_, gestures, controls, path)
			local writer = require("toml_codec.writer")
			local publish = writer.batch_write
			local ok, err = pcall(function()
				writer.batch_write = function()
					controls.refuse_reader = true
					return false, "publication refused"
				end
				helpers.assert_eq(gestures.set_enabled(false), false)
				helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
				writer.batch_write = publish
				helpers.assert_eq(gestures.set_action("tap_3", "vol_up"), false)
			end)
			writer.batch_write = publish
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("gesture-scope-admission: retained compensation fences sibling mutations until exact restoration", function()
		with_scope(function(_, gestures, controls, path)
			local adapter = require("adapters.file_system")
			local publish = adapter.write_if_unchanged
			local phase = 1
			local ok, err = pcall(function()
				adapter.write_if_unchanged = function(target, content, expected)
					if target == path then
						controls.refuse_reader = true
						return false, "publication refused"
					end
					if phase == 2 then return false, "second backup refused" end
					return publish(target, content, expected)
				end
				local committed, detail, backup = gestures.apply_scope("clear")
				if backup then controls.backups[#controls.backups + 1] = backup end
				helpers.assert_eq(committed, false)
				helpers.assert_eq(detail, "runtime rollback remains pending")
				helpers.assert_eq(gestures.set_action("tap_3", "vol_up"), false)
				helpers.assert_eq(gestures.set_action_parameter("tap_3", "open_url", "https://new.example"), false)
				helpers.assert_eq(gestures.set_enabled(false), false)
				helpers.assert_eq(gestures.enable(), false)
				helpers.assert_eq(gestures.disable(), false)
				helpers.assert_eq(gestures.init({ persist = false }), false)
				helpers.assert_eq(gestures.reset_defaults(), false)
				helpers.assert_eq(gestures.disable_all_actions(), false)
				helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
				controls.refuse_reader, phase = false, 2
				committed, detail, backup = gestures.apply_scope("clear")
				if backup then controls.backups[#controls.backups + 1] = backup end
				helpers.assert_eq(committed, false)
				helpers.assert_true(detail:find("backup refused", 1, true) ~= nil, detail)
				helpers.assert_eq(gestures.get_action("tap_3"), "enter")
				helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
				helpers.assert_true(gestures.is_enabled() and gestures.is_reading())
			end)
			adapter.write_if_unchanged = publish
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("gesture-scope: the public manager uses the production file adapter", function()
		with_scope(function(_, gestures, controls, path)
			local committed, detail, backup = gestures.apply_scope("clear")
			if backup then controls.backups[#controls.backups + 1] = backup end
			helpers.assert_true(committed, tostring(detail))
			helpers.assert_eq(Sandbox.read_bytes(backup), SOURCE)
			helpers.assert_eq(gestures.is_enabled(), false)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).gestures.enabled, nil)
		end)
	end)

	helpers.it("gesture-scope: the real menu confirms with No default and publishes only after Yes", function()
		with_scope(function(_, gestures, controls, path)
			local menu_name, modal_name = "ui.menu.menu_builder", "ui.modal"
			local previous_menu, previous_modal = package.loaded[menu_name], package.loaded[modal_name]
			local previous_execute = os.execute
			local ok, err = pcall(function()
				package.loaded[menu_name] = nil
				package.loaded[modal_name] = { run = function(callback) return callback() end }
				local calls, refreshes, accept, questions = 0, 0, false, {}
				local pause_in_modal = false
				local apply = gestures.apply_scope
				gestures.apply_scope = function(mode)
					calls = calls + 1
					local committed, detail, backup = apply(mode)
					if backup then controls.backups[#controls.backups + 1] = backup end
					return committed, detail, backup
				end
				local rows = require(menu_name).build({
					_version = "scope-test", gestures = gestures,
					on_menu_changed = function() refreshes = refreshes + 1 end,
				})
				local clear
				local i18n = require("infra.i18n")
				for _, parent in ipairs(rows) do
					if parent.title == i18n.get("menu.gestures.title") then
						for _, row in ipairs(parent.menu or {}) do
							if row.title == i18n.get("common.clear_to_system") then clear = row end
						end
					end
				end
				helpers.assert_true(clear ~= nil and type(clear.fn) == "function", "the real gesture Clear row must exist")
				os.execute = function(command)
					if command == "command -v zenity >/dev/null 2>&1" then return 0 end
					helpers.assert_true(command:find("zenity --question", 1, true) ~= nil)
					questions[#questions + 1] = command
					if pause_in_modal then controls.paused = true end
					return accept and 0 or 1
				end
				clear.fn()
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
				accept = true
				pause_in_modal = true
				clear.fn()
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(refreshes, 0)
				helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
				pause_in_modal, controls.paused = false, false
				clear.fn()
				helpers.assert_eq(calls, 2)
				helpers.assert_true(refreshes > 0)
				helpers.assert_eq(gestures.is_enabled(), false)
				helpers.assert_eq(#questions, 3)
				for _, question in ipairs(questions) do
					helpers.assert_true(question:find("--default-cancel", 1, true) ~= nil)
					helpers.assert_true(question:find(i18n.get("menu.gestures.title"), 1, true) ~= nil,
						"confirmation uses the translated gesture title")
				end
			end)
			os.execute = previous_execute
			package.loaded[menu_name], package.loaded[modal_name] = previous_menu, previous_modal
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("gesture-scope: clear removes canonical and legacy ownership without erasing neighbors", function()
		with_scope(function(owner, gestures, _, path, backup)
			local committed, detail = owner.apply("clear")
			helpers.assert_true(committed, tostring(detail))
			helpers.assert_eq(Sandbox.read_bytes(backup), SOURCE)
			local saved = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(saved.gestures and saved.gestures.enabled, nil)
			helpers.assert_eq(saved.linux.gestures.tap_4, nil)
			helpers.assert_eq(saved.linux.gestures.unknown, "keep")
			helpers.assert_eq(saved.linux.action_parameters.tap_4__open_url, nil)
			helpers.assert_eq(saved.linux.action_parameters.keyboard__ctrl_k__open_url, "https://keep.example")
			helpers.assert_eq(saved.gesture_parameters.tap_3__open_url, nil)
			helpers.assert_eq(saved.gesture_parameters.keyboard__ctrl_j__open_url, "https://keyboard.example")
			helpers.assert_eq(saved.gesture_parameters.unknown, "keep")
			helpers.assert_eq(saved.other.value, 42)
			helpers.assert_eq(gestures.is_enabled(), false)
			helpers.assert_eq(gestures.is_reading(), false)
			helpers.assert_eq(gestures.get_all_action_parameters().tap_3__open_url, nil)
			helpers.assert_eq(gestures.get_all_action_parameters().tap_4__open_url, nil)
			package.loaded["modules.gestures.manager"] = nil
			local restarted = require("modules.gestures.manager")
			restarted.init({ persist = true, config_path = path })
			helpers.assert_eq(restarted.get_action("tap_4"), "none", "legacy configuration cannot resurrect the assignment")
			helpers.assert_eq(restarted.is_enabled(), false)
			helpers.assert_eq(restarted.get_all_action_parameters().tap_4__open_url, nil)
		end)
	end)

	helpers.it("gesture-scope: recommendations reach the live reader and all manifest slots", function()
		with_scope(function(owner, gestures)
			local committed, detail = owner.apply("recommended")
			helpers.assert_true(committed, tostring(detail))
			helpers.assert_eq(gestures.is_enabled(), true)
			helpers.assert_eq(gestures.is_reading(), true)
			for slot in pairs(gestures.DEFAULT_GESTURES) do
				helpers.assert_eq(gestures.get_action(slot), require("infra.manifest_reader").recommended_for("gestures." .. slot))
			end
		end)
	end)

	helpers.it("gesture-scope: late publication refusal restores exact runtime and source", function()
		with_scope(function(owner, gestures, controls, path)
			local before = gestures.capture_scope_state()
			controls.refuse = path
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(gestures.capture_scope_state(), before)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(owner.pending(), false)
		end)
	end)

	helpers.it("gesture-scope: occupied backup refuses before runtime mutation", function()
		with_scope(function(owner, gestures, _, path, backup)
			local before = gestures.capture_scope_state()
			Sandbox.write_bytes(backup, "existing backup")
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(gestures.capture_scope_state(), before)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(Sandbox.read_bytes(backup), "existing backup")
		end)
	end)

	helpers.it("gesture-scope: external edits win while refused reader restoration retains debt", function()
		with_scope(function(owner, gestures, controls, path)
			controls.external_edit = SOURCE .. "# another writer\n"
			controls.refuse_reader = true
			helpers.assert_eq(owner.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), controls.external_edit)
			helpers.assert_eq(owner.pending(), true)
			helpers.assert_eq(owner.apply("recommended"), false)
			controls.refuse_reader = false
			helpers.assert_true(owner.retry_restore())
			helpers.assert_eq(owner.pending(), false)
			helpers.assert_eq(gestures.is_enabled(), true)
		end)
	end)
end)

helpers.describe("Linux gesture scope revert", function()
	helpers.it("reverts a committed clear to the exact file, actions and reader", function()
		with_scope(function(owner, gestures, _, path)
			local actions = gestures.get_all_actions()
			helpers.assert_eq(owner.apply("clear"), true)
			helpers.assert_eq(gestures.is_enabled(), false)
			local reverted, detail = owner.revert()
			helpers.assert_eq(reverted, true, detail)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(gestures.is_enabled(), true)
			helpers.assert_eq(gestures.get_all_actions(), actions)
			helpers.assert_eq(owner.pending(), false)
			owner.release()
			helpers.assert_eq(owner.revert(), false, "one commit reverts once")
		end)
	end)
end)
