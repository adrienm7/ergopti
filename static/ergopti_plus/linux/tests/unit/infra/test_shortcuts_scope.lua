--- tests/unit/infra/test_shortcuts_scope.lua

--- Exercises the actual shortcut readers, dispatchers and parameter owner.
local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")

local SOURCE = '[shortcuts]\nenabled = true\nwrap_text_if_selected = true\nchatgpt_url = "https://old.example"\nunknown = "keep"\n'
	.. '[shortcuts.keyboard]\nctrl_j = "open_url"\nctrl_k = "enter"\nctrl_p = "script_reload"\nforeign_slot = "keep"\n'
	.. '[shortcuts.tap_keys]\nnumber_row_left = "send_text"\nunknown = "keep"\n'
	.. '[gesture_parameters]\nkeyboard__ctrl_j__open_url = "https://old.example"\ntap_key__number_row_left__send_text = "typed"\n'
	.. 'tap_3__open_url = "https://gesture.example"\ntap_hold__caps_lock__open_url = "https://hold.example"\nunknown = "keep"\n'
	.. '[linux.action_parameters]\nkeyboard__ctrl_k__open_url = "https://legacy.example"\nunknown = "keep"\n'
	.. '[gestures]\nenabled = false\ntap_3 = "enter"\n[metrics]\nenabled = true\n[llm]\nenabled = true\n[other]\nvalue = 42\n'

--- Uses real state owners and only controlled native/file publication ports.
--- @param body function Test body.
local function with_scope(body)
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(SOURCE, function(path)
			for _, name in ipairs({ "modules.shortcuts.manager", "modules.shortcuts.keyboard_shortcuts", "modules.shortcuts.tap_keys",
				"modules.shortcuts.chatgpt", "modules.gestures.manager", "infra.shortcuts_scope", "ui.menu.menu_builder" }) do
				package.loaded[name] = nil
			end
			local controls = { backups = {}, queued = {}, executed = {}, paused = false, device_calls = 0, runtime_calls = 0 }
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = {
				get = function(_, default) return default end,
				set = function() error("shortcut scope must not write legacy storage") end,
			}
			package.loaded["adapters.evdev_reader"] = {
				TOUCHPAD = "touchpad", close = function() controls.device_calls = controls.device_calls + 1; return false end,
				open = function() controls.device_calls = controls.device_calls + 1; return false end,
			}
			package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end }
			package.loaded["adapters.shell_runner"] = {
				has_command = function() return true end,
				quote = function(value) return "'" .. value .. "'" end,
				run = function(command) controls.executed[#controls.executed + 1] = command; return true end,
			}
			local gestures = require("modules.gestures.manager")
			gestures.init({ persist = true, config_path = path, enabled = false })
			gestures.execute_action = function(action, binding)
				controls.executed[#controls.executed + 1] = action .. "@" .. binding
			end
			local manager = require("modules.shortcuts.manager")
			manager.init({ persist = true, config_path = path })
			local keyboard, taps = require("modules.shortcuts.keyboard_shortcuts"), require("modules.shortcuts.tap_keys")
			keyboard.get_assignments()
			taps.init({ is_active = function() return manager.is_enabled() and not controls.paused end,
				defer = function(callback) controls.queued[#controls.queued + 1] = callback; return true end })
			taps.get_action("number_row_left")
			local url = require("modules.shortcuts.chatgpt")
			local files = {
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional configuration publication") end,
				write_if_unchanged = function(target, content, expected)
					if target ~= path then controls.backups[#controls.backups + 1] = target end
					if controls.before_publish then controls.before_publish(target) end
					if controls.refuse == target then return false, "injected publication refusal" end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			package.loaded["adapters.file_system"] = files
			local apply_keyboard = keyboard.apply_configuration
			keyboard.apply_configuration = function(token, state)
				controls.runtime_calls = controls.runtime_calls + 1
				local accepted = apply_keyboard(token, state)
				if controls.refuse_runtime then controls.refuse_runtime = false; return false end
				return accepted
			end
			local apply_parameters = gestures.apply_parameter_configuration
			gestures.apply_parameter_configuration = function(token, state)
				if controls.refuse_restore and state.keyboard__ctrl_j__open_url then return false end
				return apply_parameters(token, state)
			end
			local backup = path .. ".shortcuts-test-backup"
			local scope = require("infra.shortcuts_scope").new({ path = path, backup_path = backup,
				files = files, is_paused = function() return controls.paused end })
			local owners = { manager = manager, keyboard = keyboard, taps = taps, url = url, gestures = gestures }
			local passed, failure = pcall(body, scope, owners, controls, path, backup)
			for _, created in ipairs(controls.backups) do os.remove(created); os.remove(created .. ".tmp") end
			os.remove(backup)
			if not passed then error(failure, 0) end
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

helpers.describe("Linux terminal shortcut scope", function()
	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("applies " .. mode .. " through the real owners and preserves other domains", function()
			with_scope(function(scope, owners, controls, path, backup)
				helpers.assert_true(scope.apply(mode))
				helpers.assert_eq(Sandbox.read_bytes(backup), SOURCE)
				local config = Codec.decode(Sandbox.read_bytes(path))
				helpers.assert_eq(owners.manager.is_enabled(), mode == "recommended")
				helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "none")
				helpers.assert_eq(owners.taps.get_action("number_row_left"), mode == "clear" and "none"
					or Manifest.recommended_for("shortcuts.tap_keys.number_row_left"))
				helpers.assert_eq(owners.url.get_url(), Manifest.default_for("shortcuts.chatgpt_url"))
				helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__ctrl_j", "open_url"), "")
				helpers.assert_eq(owners.gestures.get_action_parameter("tap_key__number_row_left", "send_text"), "")
				helpers.assert_eq(config.gesture_parameters.keyboard__ctrl_j__open_url, nil)
				helpers.assert_eq(config.linux.action_parameters.keyboard__ctrl_k__open_url, nil)
				helpers.assert_eq(config.gesture_parameters.tap_3__open_url, "https://gesture.example")
				helpers.assert_eq(config.gesture_parameters.tap_hold__caps_lock__open_url, "https://hold.example")
				helpers.assert_eq(config.gesture_parameters.unknown, "keep")
				helpers.assert_eq(config.linux.action_parameters.unknown, "keep")
				helpers.assert_eq(config.shortcuts.keyboard.foreign_slot, "keep")
				helpers.assert_eq(config.shortcuts.tap_keys.unknown, "keep")
				helpers.assert_eq(config.shortcuts.unknown, "keep")
				helpers.assert_eq(config.metrics.enabled, true)
				helpers.assert_eq(config.llm.enabled, true)
				helpers.assert_eq(config.other.value, 42)
				helpers.assert_eq(owners.gestures.get_action("tap_3"), "enter")
				helpers.assert_eq(controls.device_calls, 0, "shortcut parameters must never operate evdev")
				owners.manager.init({ persist = true, config_path = path })
				owners.keyboard._reset()
				owners.taps._reset()
				helpers.assert_eq(owners.manager.is_enabled(), mode == "recommended")
				helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "none")
				helpers.assert_eq(owners.taps.get_action("number_row_left"), mode == "clear" and "none" or Manifest.recommended_for("shortcuts.tap_keys.number_row_left"))
			end)
		end)
	end

	helpers.it("cancels queued script work and keeps Ctrl+G native after Clear", function()
		with_scope(function(scope, owners, controls)
			local options = { defer = function(callback) controls.queued[#controls.queued + 1] = callback; return true end }
			helpers.assert_true(owners.keyboard.consume({ key = "p", mods = { ctrl = true } }, options))
			helpers.assert_true(scope.apply("clear"))
			controls.queued[1]()
			helpers.assert_eq(#controls.executed, 0)
			helpers.assert_eq(owners.keyboard.dispatch({ key = "g", mods = { ctrl = true } },
				{ only_script = not owners.manager.is_enabled() }), false)
			helpers.assert_eq(#controls.executed, 0)
		end)
	end)

	helpers.it("clears an outdated owned value instead of refusing (config-outdated-shortcuts)", function()
		-- An old-shape or retired slot value is outdated configuration: the
		-- reset that would remove it must never be refused because of it.
		with_scope(function(scope, owners, controls, path)
			local malformed = SOURCE:gsub('ctrl_j = "open_url"', 'ctrl_j = false')
			Sandbox.write_bytes(path, malformed)
			helpers.assert_eq(scope.apply("clear"), true)
			helpers.assert_true(not Sandbox.read_bytes(path):find("ctrl_j = false", 1, true),
				"the clear removes the outdated value")
			helpers.assert_eq(#controls.backups, 1)
			helpers.assert_true(owners.manager.configuration_admitted())
		end)
	end)

	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("resets over a plain keyboard or tap_keys value instead of refusing: " .. mode
			.. " (config-outdated-shortcut-shape)", function()
			-- The candidate readers asserted a table, so a value an older build
			-- left as `keyboard = "…"` refused Restore recommended and Clear.
			with_scope(function(scope, owners, _, path)
				local stale = '[shortcuts]\nenabled = true\nkeyboard = "x"\ntap_keys = "y"\n'
				Sandbox.write_bytes(path, stale)
				local ok, committed = pcall(owners.keyboard.configuration_candidate, Codec.decode(stale))
				helpers.assert_true(ok, tostring(committed))
				helpers.assert_eq(scope.apply(mode), true)
				helpers.assert_true(owners.manager.configuration_admitted())
			end)
		end)
	end

	helpers.it("refuses a reserved backup before changing runtime", function()
		with_scope(function(scope, owners, _, path, backup)
			Sandbox.write_bytes(backup, "reserved")
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(Sandbox.read_bytes(backup), "reserved")
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_true(owners.manager.configuration_admitted())
		end)
	end)

	helpers.it("compensates an owner refusal after that owner has already changed", function()
		with_scope(function(scope, owners, controls, path)
			controls.refuse_runtime = true
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "open_url")
			helpers.assert_eq(owners.taps.get_action("number_row_left"), "send_text")
			helpers.assert_eq(scope.pending(), false)
			helpers.assert_eq(controls.runtime_calls, 2, "candidate and compensation must both reach the real owner")
			helpers.assert_eq(#controls.backups, 1)
		end)
	end)

	helpers.it("compensates conditional publication refusal and preserves exact source", function()
		with_scope(function(scope, owners, controls, path)
			controls.refuse = path
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__ctrl_j", "open_url"), "https://old.example")
			helpers.assert_eq(owners.keyboard.get_action("ctrl_k"), "enter")
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_eq(scope.pending(), false)
			helpers.assert_eq(controls.runtime_calls, 2)
			helpers.assert_eq(#controls.backups, 1)
		end)
	end)

	helpers.it("preserves an external edit while restoring the old runtime", function()
		with_scope(function(scope, owners, controls, path)
			local external = SOURCE .. "external = 9\n"
			controls.before_publish = function(target) if target == path then Sandbox.write_bytes(path, external) end end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), external)
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "open_url")
		end)
	end)

	helpers.it("retains refused compensation and fences every participating setter until retry", function()
		with_scope(function(scope, owners, controls, path)
			controls.refuse = path
			controls.before_publish = function(target) if target == path then controls.refuse_restore = true end end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_true(scope.pending())
			helpers.assert_eq(owners.manager.set_enabled(true), false)
			helpers.assert_eq(owners.manager.set_wrap_on_type_enabled(false), false)
			helpers.assert_eq(owners.keyboard.set_action("ctrl_j", "enter"), false)
			helpers.assert_eq(owners.taps.set_action("number_row_left", "enter"), false)
			helpers.assert_eq(owners.url.set_url("https://new.example"), false)
			helpers.assert_eq(owners.url.open(), false)
			helpers.assert_eq(owners.gestures.set_action_parameter("keyboard__ctrl_j", "open_url", "https://new.example"), false)
			helpers.assert_eq(owners.gestures.apply_scope("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			controls.refuse_restore, controls.before_publish, controls.refuse = false, nil, nil
			helpers.assert_true(scope.retry_restore())
			helpers.assert_eq(scope.pending(), false)
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__ctrl_j", "open_url"), "https://old.example")
			helpers.assert_true(owners.keyboard.set_action("ctrl_j", "enter"))
		end)
	end)


	helpers.it("refuses a pause raised after backup and releases all owners", function()
		with_scope(function(scope, owners, controls, path)
			controls.before_publish = function(target) if target ~= path then controls.paused = true end end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(#controls.backups, 1)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_true(owners.manager.configuration_admitted())
		end)
	end)

	helpers.it("fences real dispatch and competing mutations during the publication window", function()
		with_scope(function(scope, owners, controls, path)
			local observed = false
			controls.before_publish = function(target)
				if target == path then return end
				observed = true
				helpers.assert_eq(owners.keyboard.dispatch({ key = "p", mods = { ctrl = true } }), false)
				helpers.assert_eq(owners.taps.on_key("number_row_left"), false)
				helpers.assert_eq(owners.manager.select_word(), false)
				helpers.assert_eq(owners.manager.toggle_caps_word(), false)
				helpers.assert_eq(owners.manager.set_enabled(false), false)
				helpers.assert_eq(owners.gestures.set_action("tap_3", "none"), false)
				helpers.assert_eq(owners.url.open(), false)
			end
			helpers.assert_true(scope.apply("clear"))
			helpers.assert_true(observed)
			helpers.assert_eq(#controls.executed, 0)
		end)
	end)

	helpers.it("releases earlier acquisitions when the parameter owner is already held", function()
		with_scope(function(scope, owners, controls, path)
			local other = {}
			helpers.assert_true(owners.gestures.acquire_parameter_configuration(other))
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_true(owners.manager.configuration_admitted())
			helpers.assert_eq(#controls.backups, 0)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(owners.gestures.release_parameter_configuration(other))
		end)
	end)

	helpers.it("uses live transaction admission in the daemon's actual wrap getter", function()
		local file = assert(io.open("ergopti_hotstrings.lua", "r"))
		local source = file:read("*a")
		file:close()
		local block = assert(source:match('local wrap_on_type = require%("modules.shortcuts.wrap_on_type"%).new%({(.-)get_pair%s*='))
		local getter = assert(block:match("is_active%s*=%s*(function%(%).-end),"))
		local admitted = true
		local factory = assert((loadstring or load)("return function(shortcuts, script_actions, secure_focus_guard) return " .. getter .. " end"))()
		local active = factory({ is_enabled = function() return true end, is_wrap_on_type_enabled = function() return true end,
			configuration_admitted = function() return admitted end }, { is_paused = function() return false end },
			{ blocks_text = function() return false end })
		helpers.assert_true(active())
		admitted = false
		helpers.assert_eq(active(), false)
		admitted = true
		helpers.assert_true(active())
	end)

	for _, mode in ipairs({ "clear", "recommended", "cancel", "paused confirmation" }) do
		helpers.it("routes the actual rendered " .. mode .. " request to the public terminal", function()
			with_scope(function(_, owners, controls, path)
				local renderer = require("infra.manifest_menu")
				local root = renderer.get_root()
				local rows, top, execute = root.shortcuts_menu, root.top_level, os.execute
				local selected = mode == "recommended" and "recommended" or "clear"
				local key = selected == "clear" and "common.clear_to_system" or "common.restore_recommended"
				local id = selected == "clear" and "scope_clear" or "scope_restore"
				local changed = 0
				local passed, err = pcall(function()
					root.shortcuts_menu = {{ type = "command", id = id, i18n = key }}
					root.top_level = {{ id = "shortcuts" }}
					os.execute = function(command)
						if command:find("command -v zenity", 1, true) then return 0 end
						if command:find("zenity --question", 1, true) then
							if mode == "paused confirmation" then controls.paused = true end
							return mode == "cancel" and 1 or 0
						end
						return execute(command)
					end
					local menu = require("ui.menu.menu_builder").build({ shortcuts = owners.manager, paused = false,
						is_paused = function() return controls.paused end,
						on_menu_changed = function() changed = changed + 1 end })
					local action
					local function find(items)
						for _, row in ipairs(items) do
							if row.title == require("infra.i18n").get(key) then action = row.fn end
							if row.menu then find(row.menu) end
						end
					end
					find(menu)
					helpers.assert_eq(type(action), "function")
					action()
					local expected = mode == "clear" or mode == "recommended"
					helpers.assert_eq(changed, expected and 1 or 0)
					helpers.assert_eq(owners.manager.is_enabled(), mode ~= "clear")
					if not expected then helpers.assert_eq(Sandbox.read_bytes(path), SOURCE) end
				end)
				root.shortcuts_menu, root.top_level, os.execute = rows, top, execute
				if not passed then error(err, 0) end
			end)
		end)
	end
end)

helpers.describe("Linux terminal shortcut scope revert", function()
	helpers.it("reverts a committed clear under the same dispatch ownership", function()
		with_scope(function(scope, owners, _, path, backup)
			local before = Sandbox.read_bytes(path)
			helpers.assert_true(scope.apply("clear"))
			helpers.assert_eq(owners.manager.is_enabled(), false)
			local reverted, detail = scope.revert()
			helpers.assert_eq(reverted, true, detail)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			helpers.assert_eq(owners.manager.is_enabled(), true)
			helpers.assert_eq(scope.pending(), false)
			os.remove(backup)
			helpers.assert_true(scope.apply("clear"), "every dispatch port is released after a revert")
		end)
	end)
end)
