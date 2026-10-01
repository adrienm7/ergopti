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
					if controls.external_edit and target == path then
						Sandbox.write_bytes(path, controls.external_edit)
						-- The reader refuses from the publication on: the apply
						-- that came before it started the reader.
						if controls.refuse_reader_after_edit then controls.refuse_reader = true end
					end
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
			-- The clear once switched the Gestures off with the assignments
			-- (gestures-clear-keeps-switch).
			helpers.assert_eq(gestures.is_enabled(), true, "the clear owns the assignments, not the switch")
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).gestures.enabled, true)
		end)
	end)

	-- The maintainer's first group (2026-09-30): the switch, « Restaurer les
	-- valeurs conseillées », « Tout effacer », then a separator; both scope rows
	-- act at once, with no question, because the owner's backup is the way back.
	helpers.it("gesture-scope: the real menu opens with switch, restore and clear, each applied at once", function()
		with_scope(function(_, gestures, controls, path)
			local menu_name = "ui.menu.menu_builder"
			local previous_menu = package.loaded[menu_name]
			local previous_execute = os.execute
			local ok, err = pcall(function()
				package.loaded[menu_name] = nil
				local calls, refreshes, questions = {}, 0, 0
				local apply = gestures.apply_scope
				gestures.apply_scope = function(mode)
					calls[#calls + 1] = mode
					local committed, detail, backup = apply(mode)
					if backup then controls.backups[#controls.backups + 1] = backup end
					return committed, detail, backup
				end
				local rows = require(menu_name).build({
					_version = "scope-test", gestures = gestures,
					on_menu_changed = function() refreshes = refreshes + 1 end,
				})
				local i18n = require("infra.i18n")
				local submenu
				for _, parent in ipairs(rows) do
					if parent.title == i18n.get("menu.gestures.title") then submenu = parent.menu end
				end
				helpers.assert_true(type(submenu) == "table", "the real Gestures submenu must exist")
				local first = {}
				for index = 1, 4 do first[index] = submenu[index] and submenu[index].title end
				helpers.assert_eq(table.concat(first, " | "), table.concat({ i18n.get("menu.gestures.enable"),
					i18n.get("common.restore_recommended"), i18n.get("common.clear_to_system"), "-" }, " | "))
				for index = 5, #submenu do
					helpers.assert_true(submenu[index].title ~= i18n.get("common.restore_recommended")
						and submenu[index].title ~= i18n.get("common.clear_to_system"),
						"no scope row may follow the first group")
				end
				local restore, clear = submenu[2], submenu[3]
				helpers.assert_true(type(restore.fn) == "function" and type(clear.fn) == "function")
				os.execute = function(command)
					if command:find("zenity", 1, true) then questions = questions + 1 end
					return 0
				end
				-- A pause refuses the owner's publication; the file stays whole.
				controls.paused = true
				clear.fn()
				helpers.assert_eq(table.concat(calls, ","), "clear")
				helpers.assert_eq(refreshes, 0)
				helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
				controls.paused = false
				clear.fn()
				helpers.assert_eq(table.concat(calls, ","), "clear,clear")
				helpers.assert_true(refreshes > 0)
				helpers.assert_eq(gestures.is_enabled(), true, "the menu clear keeps the switch (gestures-clear-keeps-switch)")
				local saved = Codec.decode(Sandbox.read_bytes(path))
				helpers.assert_eq(saved.gestures and saved.gestures.enabled, true)
				helpers.assert_eq(saved.other.value, 42)
				helpers.assert_eq(Sandbox.read_bytes(controls.backups[#controls.backups]), SOURCE,
					"the clear backs the file up before it rewrites it")
				restore.fn()
				helpers.assert_eq(table.concat(calls, ","), "clear,clear,recommended")
				local recommended = require("infra.manifest_reader").recommended_for("gestures.enabled")
				helpers.assert_eq(gestures.is_enabled(), recommended)
				helpers.assert_eq(questions, 0, "neither scope row asks a question")
			end)
			os.execute = previous_execute
			package.loaded[menu_name] = previous_menu
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("gesture-scope: clear removes canonical and legacy ownership without erasing neighbors", function()
		with_scope(function(owner, gestures, _, path, backup)
			local committed, detail = owner.apply("clear")
			helpers.assert_true(committed, tostring(detail))
			helpers.assert_eq(Sandbox.read_bytes(backup), SOURCE)
			local saved = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(saved.gestures and saved.gestures.enabled, true, "gestures-clear-keeps-switch")
			helpers.assert_eq(saved.linux.gestures.tap_4, nil)
			helpers.assert_eq(saved.linux.gestures.unknown, "keep")
			helpers.assert_eq(saved.linux.action_parameters.tap_4__open_url, nil)
			helpers.assert_eq(saved.linux.action_parameters.keyboard__ctrl_k__open_url, "https://keep.example")
			helpers.assert_eq(saved.gesture_parameters.tap_3__open_url, nil)
			helpers.assert_eq(saved.gesture_parameters.keyboard__ctrl_j__open_url, "https://keyboard.example")
			helpers.assert_eq(saved.gesture_parameters.unknown, "keep")
			helpers.assert_eq(saved.other.value, 42)
			helpers.assert_eq(gestures.is_enabled(), true, "the switch stays on")
			helpers.assert_eq(gestures.is_reading(), true)
			for slot in pairs(gestures.DEFAULT_GESTURES) do
				helpers.assert_eq(gestures.get_action(slot), "none", slot .. " is cleared")
			end
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
			-- A clear keeps the switch, so its apply restarts the reader like its
			-- inverse does: the reader refuses only once the publication lost.
			controls.external_edit = SOURCE .. "# another writer\n"
			controls.refuse_reader_after_edit = true
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
			helpers.assert_eq(gestures.is_enabled(), true, "the clear keeps the switch")
			helpers.assert_eq(gestures.get_action("tap_3"), "none", "and removes the assignment")
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
