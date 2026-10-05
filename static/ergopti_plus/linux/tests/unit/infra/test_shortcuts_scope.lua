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
--- @param source string|nil config.toml content; SOURCE by default.
local function with_scope(body, source)
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(source or SOURCE, function(path)
			for _, name in ipairs({ "modules.shortcuts.manager", "modules.shortcuts.keyboard_shortcuts", "modules.shortcuts.tap_keys",
				"modules.shortcuts.chatgpt", "modules.shortcuts.script_chords", "modules.gestures.manager",
				"infra.shortcuts_scope", "ui.menu.menu_builder" }) do
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
			local chords = require("modules.shortcuts.script_chords")
			chords.init({ is_paused = function() return controls.paused end,
				defer = function(callback) controls.queued[#controls.queued + 1] = callback; return true end })
			local backup = path .. ".shortcuts-test-backup"
			local scope = require("infra.shortcuts_scope").new({ path = path, backup_path = backup,
				files = files, is_paused = function() return controls.paused end })
			controls.files = files
			local owners = { manager = manager, keyboard = keyboard, taps = taps, url = url, gestures = gestures,
				chords = chords }
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
	helpers.it("(magic-editor-scope) distinguishes durable personal None from scope removal and fences unproved sources", function()
		with_scope(function(scope, owners, _, path)
			local source = { generation = 1, status = "ready", candidates = {
				{ code = "KeyJ", native_code = 36, identity = "evdev:36", text = "★", native_text = "j", direct = true, dead = false },
			} }
			package.loaded["modules.hotstrings.magic_key_source"] = {
				editor_source = function() return source end, known_codes = function() return { KeyJ = true } end,
			}
			package.loaded["modules.hotstrings.magic_key"] = { get = function() return "★" end }
			local function decision()
				return owners.keyboard.magic_editor_decision({ master = owners.manager.is_enabled(), paused = false, inhibited = false })
			end
			helpers.assert_true(owners.manager.set_enabled(true))
			helpers.assert_true(owners.keyboard.set_action("super_j", "none"))
			owners.keyboard._reset()
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).shortcuts.keyboard.super_j, "none", "explicit None is durable personal ownership")
			helpers.assert_eq(decision().reason, "explicit_assignment", "restart cannot turn personal native behavior into the conditional default")
			helpers.assert_true(scope.apply("clear"))
			local cleared = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(cleared.shortcuts.keyboard.super_j, nil, "scope removal restores actual absence")
			helpers.assert_eq(cleared.shortcuts.keyboard.future_physical, "future_action", "unknown keyboard neighbors stay intact")
			helpers.assert_eq(cleared.unrelated.keep, 42)
			helpers.assert_eq(decision().active, false, "Clear keeps the shared logical slot and master disabled")
			helpers.assert_true(owners.keyboard.set_action("magic_editor", "open_hotstrings_editor"))
			helpers.assert_true(owners.manager.set_enabled(true))
			helpers.assert_true(decision().active, "owned reactivation uses an acknowledged current source after physical intent removal")
			source.status, source.candidates, source.generation = "unavailable", {}, 2
			helpers.assert_eq(decision().reason, "source_unavailable", "removing a claim never invents native source admission")
		end, '[shortcuts]\nenabled = true\n[shortcuts.keyboard]\nfuture_physical = "future_action"\n[unrelated]\nkeep = 42\n')
	end)

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

	helpers.it("refuses a reset whose own written action is unassignable (config-outdated-strict-candidate)", function()
		-- Tolerance is for the user's pre-write values. After the write every
		-- walked slot is the scope's own output, so an unassignable one there is
		-- a real failure: the reset must be refused and compensated, never
		-- committed with the slot silently unbound.
		with_scope(function(scope, owners, _, path)
			local refused = Manifest.recommended_for("shortcuts.keyboard.ctrl_g")
			helpers.assert_true(refused ~= "none", "the fixture needs a recommended keyboard action")
			local is_assignable = owners.gestures.is_assignable
			owners.gestures.is_assignable = function(action)
				if action == refused then return false end
				return is_assignable(action)
			end
			local ok, committed = pcall(scope.apply, "recommended")
			owners.gestures.is_assignable = is_assignable
			helpers.assert_true(ok, tostring(committed))
			helpers.assert_eq(committed, false)
			helpers.assert_eq(Sandbox.read_bytes(path), SOURCE, "the refused reset is compensated")
		end)
	end)

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

	-- The declared rows of the first group, not injected ones: the switch, the
	-- restore, the clear, a separator. Neither scope row asks (the maintainer
	-- retired the clear's question on 2026-09-30); a pause refuses the owner.
	for _, mode in ipairs({ "clear", "recommended", "paused" }) do
		helpers.it("routes the actual rendered " .. mode .. " request to the public terminal", function()
			with_scope(function(_, owners, controls, path)
				local renderer = require("infra.manifest_menu")
				local root = renderer.get_root()
				local top, execute = root.top_level, os.execute
				local selected = mode == "recommended" and "recommended" or "clear"
				local i18n = require("infra.i18n")
				local changed, questions = 0, 0
				local passed, err = pcall(function()
					root.top_level = {{ id = "shortcuts" }}
					os.execute = function(command)
						if command:find("zenity", 1, true) then
							questions = questions + 1
							return 0
						end
						return execute(command)
					end
					local menu = require("ui.menu.menu_builder").build({ shortcuts = owners.manager, paused = false,
						is_paused = function() return controls.paused end,
						on_menu_changed = function() changed = changed + 1 end })
					local submenu
					for _, item in ipairs(menu) do
						if item.title == i18n.get("menu.shortcuts.title") then submenu = item.menu end
					end
					helpers.assert_true(type(submenu) == "table", "the real Shortcuts submenu must exist")
					helpers.assert_eq(table.concat({ submenu[1].title, submenu[2].title, submenu[3].title,
						submenu[4].title }, " | "), table.concat({ i18n.get("menu.shortcuts.enable"),
						i18n.get("common.restore_recommended"), i18n.get("common.clear_to_system"), "-" }, " | "))
					local action = (selected == "clear" and submenu[3] or submenu[2]).fn
					helpers.assert_eq(type(action), "function")
					if mode == "paused" then controls.paused = true end
					action()
					local expected = mode ~= "paused"
					helpers.assert_eq(changed, expected and 1 or 0)
					helpers.assert_eq(questions, 0, "no scope row asks (restore-recommended-no-confirm)")
					helpers.assert_eq(owners.manager.is_enabled(), mode ~= "clear")
					if not expected then helpers.assert_eq(Sandbox.read_bytes(path), SOURCE) end
				end)
				root.top_level, os.execute = top, execute
				if not passed then error(err, 0) end
			end)
		end)
	end
end)

-- shortcuts-restore-row: the row is the manifest's own declaration now, not
-- one this suite injects. It runs the recommended scope without a question.
helpers.describe("Linux Shortcuts restore row", function()
	helpers.it("the declared Shortcuts restore row restores the recommended scope without a question", function()
		with_scope(function(_, owners, controls, path)
			local renderer = require("infra.manifest_menu")
			local root = renderer.get_root()
			local top, execute = root.top_level, os.execute
			local changed, questions = 0, 0
			local passed, err = pcall(function()
				root.top_level = {{ id = "shortcuts" }}
				os.execute = function(command)
					if command:find("command -v zenity", 1, true) then return 0 end
					if command:find("zenity --question", 1, true) then questions = questions + 1; return 1 end
					return execute(command)
				end
				local menu = require("ui.menu.menu_builder").build({ shortcuts = owners.manager, paused = false,
					is_paused = function() return controls.paused end,
					on_menu_changed = function() changed = changed + 1 end })
				local i18n = require("infra.i18n")
				local action
				for _, item in ipairs(menu) do
					if item.title == i18n.get("menu.shortcuts.title") then
						for _, row in ipairs(item.menu or {}) do
							if row.title == i18n.get("common.restore_recommended") then action = row.fn end
						end
					end
				end
				helpers.assert_eq(type(action), "function", "the Shortcuts submenu draws the declared restore row")
				owners.manager.set_enabled(false)
				action()
				helpers.assert_eq(questions, 0, "restoring the recommended values asks nothing")
				helpers.assert_eq(changed, 1)
				helpers.assert_eq(owners.manager.is_enabled(), Manifest.recommended_for("shortcuts.enabled"))
				helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).other.value, 42)
			end)
			root.top_level, os.execute = top, execute
			if not passed then error(err, 0) end
		end)
	end)
end)

-- The maintainer's request of 2026-09-30: « Taper un symbole encadre la
-- sélection » (no AltGr: the symbols need not be there) and « Symboles
-- encadrants » form one group, with no separator between them.
helpers.describe("Linux Shortcuts wrap group", function()
	helpers.it("draws the wrap toggle by its behaviour, followed by its symbols", function()
		with_scope(function(_, owners, controls)
			local renderer = require("infra.manifest_menu")
			local root = renderer.get_root()
			local top = root.top_level
			local passed, err = pcall(function()
				root.top_level = {{ id = "shortcuts" }}
				local menu = require("ui.menu.menu_builder").build({ shortcuts = owners.manager, paused = false,
					is_paused = function() return controls.paused end })
				local i18n = require("infra.i18n")
				local submenu
				for _, item in ipairs(menu) do
					if item.title == i18n.get("menu.shortcuts.title") then submenu = item.menu end
				end
				helpers.assert_true(type(submenu) == "table", "the real Shortcuts submenu must exist")
				local at
				for index, row in ipairs(submenu) do
					if row.title == i18n.get("shortcuts.label_wrap_text") then at = index end
				end
				helpers.assert_true(at ~= nil, "the wrap toggle is drawn with its label")
				helpers.assert_eq(submenu[at + 1].title, i18n.get("menu.shortcuts.wrap_symbols"),
					"the wrapping symbols follow the toggle with no separator between them")
				helpers.assert_true(not i18n.get("shortcuts.label_wrap_text"):find("AltGr", 1, true))
			end)
			root.top_level = top
			if not passed then error(err, 0) end
		end)
	end)
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

-- script-chords-three-os-2026-09-30: an absent chord starts with its preset, so
-- every clear writes "none" in each slot and « Restaurer » deletes them; the
-- submenu's own restore and clear touch the chords and nothing else.
local SLOTS = { "script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape" }
local CHORDS_SOURCE = SOURCE .. '[shortcuts.script_control]\nchords_enabled = false\nscript_altgr_enter = "open_url"\n'
	.. 'script_altgr_escape = "none"\n'
local CHORD_PARAMETER = "script__script_altgr_enter__open_url"

helpers.describe("Linux script chords in the Shortcuts scope", function()
	helpers.it("script-chord: the Shortcuts clear writes the four chords off and leaves them to the application", function()
		with_scope(function(scope, owners, _, path)
			helpers.assert_true(scope.apply("clear"))
			local saved = Codec.decode(Sandbox.read_bytes(path)).shortcuts.script_control
			for _, slot in ipairs(SLOTS) do
				helpers.assert_eq(saved[slot], "none", slot .. " is written off, since absence is the preset")
				helpers.assert_eq(owners.chords.get_action(slot), "none")
			end
			helpers.assert_eq(owners.chords.on_key({ code = 28, mods = { altgr = true } }), false,
				"AltGr + Enter reaches the application after a clear")
		end)
	end)

	helpers.it("script-chord: the Shortcuts restore brings the four presets and the switch back", function()
		with_scope(function(scope, owners, _, path)
			helpers.assert_eq(owners.chords.chords_enabled(), false)
			helpers.assert_true(scope.apply("recommended"))
			local saved = Codec.decode(Sandbox.read_bytes(path)).shortcuts.script_control or {}
			for _, slot in ipairs(SLOTS) do
				helpers.assert_eq(saved[slot], nil, slot .. " back on its preset is a deletion")
				helpers.assert_eq(owners.chords.get_action(slot), Manifest.recommended_for("shortcuts.script_control." .. slot))
			end
			helpers.assert_eq(saved.chords_enabled, nil)
			helpers.assert_eq(owners.chords.chords_enabled(), true)
		end, CHORDS_SOURCE)
	end)

	for _, mode in ipairs({ "clear", "recommended" }) do
		helpers.it("script-chord: the submenu's " .. mode .. " touches the chords and nothing else", function()
			with_scope(function(_, owners, controls, path, backup)
				Sandbox.write_bytes(path, Sandbox.read_bytes(path):gsub("%[gesture_parameters%]\n",
					"[gesture_parameters]\n" .. CHORD_PARAMETER .. ' = "https://script.example"\n', 1))
				owners.chords._reset()
				owners.chords.init({ is_paused = function() return controls.paused end,
					defer = function(callback) controls.queued[#controls.queued + 1] = callback; return true end })
				local narrowed = require("infra.shortcuts_scope").new({ path = path, backup_path = backup .. ".chords",
					files = controls.files, is_paused = function() return controls.paused end, only = "script_chords" })
				helpers.assert_true(narrowed.apply(mode))
				local config = Codec.decode(Sandbox.read_bytes(path))
				local chords = config.shortcuts.script_control or {}
				for _, slot in ipairs(SLOTS) do
					helpers.assert_eq(chords[slot], mode == "clear" and "none" or nil, slot)
				end
				helpers.assert_eq(owners.chords.chords_enabled(), true)
				helpers.assert_eq(config.gesture_parameters[CHORD_PARAMETER], nil, "the chords' parameters go with them")
				helpers.assert_eq(config.shortcuts.keyboard.ctrl_j, "open_url", "the keyboard slots are untouched")
				helpers.assert_eq(config.shortcuts.tap_keys.number_row_left, "send_text", "the tap keys are untouched")
				helpers.assert_eq(config.shortcuts.enabled, true)
				helpers.assert_eq(config.gesture_parameters.keyboard__ctrl_j__open_url, "https://old.example")
				helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__ctrl_j", "open_url"), "https://old.example")
				helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "open_url")
				os.remove(backup .. ".chords")
			end, CHORDS_SOURCE)
		end)
	end

	helpers.it("script-chord: the tray draws the shared submenu, ticks it from the switch and asks nothing", function()
		with_scope(function(_, owners, controls, path)
			local renderer = require("infra.manifest_menu")
			local root = renderer.get_root()
			local top, execute = root.top_level, os.execute
			local questions, changed = 0, 0
			local passed, err = pcall(function()
				root.top_level = {{ id = "shortcuts" }}
				os.execute = function(command)
					if command:find("command -v zenity", 1, true) then return 0 end
					if command:find("zenity --question", 1, true) then questions = questions + 1; return 1 end
					return execute(command)
				end
				local i18n = require("infra.i18n")
				local function group()
					local menu = require("ui.menu.menu_builder").build({ shortcuts = owners.manager, paused = false,
						is_paused = function() return controls.paused end,
						on_menu_changed = function() changed = changed + 1 end })
					for _, item in ipairs(menu) do
						if item.title == i18n.get("menu.shortcuts.title") then
							for _, row in ipairs(item.menu or {}) do
								if row.title == i18n.get("menu.shortcuts.script_shortcuts") then return row end
							end
						end
					end
				end
				local row = group()
				helpers.assert_eq(type(row), "table", "the Shortcuts submenu draws « Raccourcis de gestion du script »")
				helpers.assert_eq(row.checked, false, "the title mirrors the switch, off in this configuration")
				local titles = {}
				for _, sub in ipairs(row.menu) do titles[#titles + 1] = sub.title end
				helpers.assert_eq(titles[1], i18n.get("menu.shortcuts.script_shortcuts_enable"))
				helpers.assert_eq(titles[2], i18n.get("common.restore_recommended"))
				helpers.assert_eq(titles[3], i18n.get("common.clear_to_system"))
				helpers.assert_eq(titles[4], "-")
				helpers.assert_eq(#titles, 8, "the switch, restore, clear, a separator and the four slots")
				for index, slot in ipairs(SLOTS) do
					helpers.assert_true(titles[4 + index]:find(i18n.get("sg_labels." .. slot), 1, true) == 1, titles[4 + index])
				end
				row.menu[1].fn()
				helpers.assert_eq(owners.chords.chords_enabled(), true)
				helpers.assert_eq(group().checked, true, "the title follows the switch")
				row.menu[3].fn()
				helpers.assert_eq(questions, 0, "the submenu's clear asks nothing")
				local saved = Codec.decode(Sandbox.read_bytes(path)).shortcuts.script_control
				for _, slot in ipairs(SLOTS) do helpers.assert_eq(saved[slot], "none", slot) end
				group().menu[2].fn()
				helpers.assert_eq(questions, 0, "the submenu's restore asks nothing")
				helpers.assert_eq(owners.chords.get_action("script_altgr_escape"), "script_quit")
				helpers.assert_eq(changed, 3)
			end)
			root.top_level, os.execute = top, execute
			if not passed then error(err, 0) end
		end, CHORDS_SOURCE)
	end)
end)


helpers.describe("shortcut retained native release debt", function()
	local expected = {
		shortcuts = { enabled = true, wrap_text_if_selected = true, chatgpt_url = "https://old.example", unknown = "keep",
			keyboard = { ctrl_j = "open_url", ctrl_k = "enter", ctrl_p = "script_reload", foreign_slot = "keep" },
			tap_keys = { number_row_left = "send_text", unknown = "keep" } },
		gesture_parameters = { keyboard__ctrl_j__open_url = "https://old.example", tap_key__number_row_left__send_text = "typed",
			tap_3__open_url = "https://gesture.example", tap_hold__caps_lock__open_url = "https://hold.example", unknown = "keep" },
		linux = { action_parameters = { keyboard__ctrl_k__open_url = "https://legacy.example", unknown = "keep" } },
		gestures = { enabled = false, tap_3 = "enter" }, metrics = { enabled = true }, llm = { enabled = true }, other = { value = 42 },
	}
	local receipts = {
		{ name = "nil", reply = function() return nil end },
		{ name = "false", reply = function() return false end },
		{ name = "truthy string", reply = function() return "true" end },
		{ name = "wrong object", reply = function() return {} end },
		{ name = "exception", reply = function() error("native release refused") end },
	}
	--- Wraps real lease owners; an injected refusal never releases their token.
	local function controlled_scope(owners, controls, path, selected, refusal)
		local blocked, live, acknowledgements = true, {}, {}
		local faults = {}
		for _, entry in ipairs({ { "manager", "acquire_configuration", "release_configuration" },
			{ "gestures", "acquire_parameter_configuration", "release_parameter_configuration" },
			{ "url", "acquire_configuration", "release_configuration" },
			{ "keyboard", "acquire_configuration", "release_configuration" },
			{ "taps", "acquire_configuration", "release_configuration" },
			{ "chords", "acquire_configuration", "release_configuration" } }) do
			local name, native = entry[1], owners[entry[1]]
			local acquire, release = native[entry[2]], native[entry[3]]
			native[entry[2]] = function(token)
				if faults.reacquire == name and acknowledgements[name] then return false end
				local accepted = acquire(token)
				if accepted == true then
					helpers.assert_eq(live[name], nil, "a live acknowledged lease is never reacquired")
					live[name] = token
				end
				return accepted
			end
			native[entry[3]] = function(token)
				helpers.assert_eq(live[name], token, "a released lease is never released without a fresh acquisition")
				if name == selected and blocked then return refusal() end
				local accepted = release(token)
				if accepted == true then
					live[name] = nil
					acknowledgements[name] = (acknowledgements[name] or 0) + 1
				end
				return accepted
			end
		end
		local scope = require("infra.shortcuts_scope").new({ path = path, backup_path = path .. ".release-debt-backup",
			files = controls.files, is_paused = function() return controls.paused end })
		return scope, function(value) blocked = value == true end, live, acknowledgements, faults
	end

	for _, mode in ipairs({ "clear", "recommended" }) do
		for _, receipt in ipairs(receipts) do
			helpers.it("retains " .. mode .. " runtime/file compensation on " .. receipt.name .. " native release", function()
				with_scope(function(_, owners, controls, path)
					local scope, unblock, live = controlled_scope(owners, controls, path, "manager", receipt.reply)
					local called, committed = pcall(scope.apply, mode)
					helpers.assert_eq(called, true, "native refusal settles rather than escaping")
					helpers.assert_eq(committed, false)
					helpers.assert_eq(scope.pending(), true)
					helpers.assert_eq(scope.release(), false)
					helpers.assert_eq(scope.apply("clear"), false, "another request cannot replace release debt")
					unblock()
					helpers.assert_eq(scope.retry_restore(), true)
					helpers.assert_eq(scope.pending(), false)
					helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
					helpers.assert_eq(owners.manager.is_enabled(), true)
					helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "open_url")
					helpers.assert_eq(owners.taps.get_action("number_row_left"), "send_text")
					helpers.assert_eq(owners.gestures.get_action_parameter("keyboard__ctrl_j", "open_url"), "https://old.example")
					helpers.assert_eq(next(live), nil)
				end)
			end)
		end
	end

	helpers.it("stops global progression and retries the exact shortcut inverse before earlier categories", function()
		with_scope(function(_, owners, controls, path)
			local scope, unblock = controlled_scope(owners, controls, path, "keyboard", function() return false end)
			local trace = {}
			local before = { apply = function(_, done) trace[#trace + 1] = "before.apply"; done(true) end,
				revert = function(done) trace[#trace + 1] = "before.revert"; done(true) end,
				release = function() trace[#trace + 1] = "before.release" end,
				pending = function() return false end, retry_restore = function(done) done(true) end }
			local after = { apply = function(_, done) trace[#trace + 1] = "after.apply"; done(true) end,
				revert = function(done) done(true) end, release = function() end,
				pending = function() return false end, retry_restore = function(done) done(true) end }
			local actual = require("config_scope_participant").synchronous({ apply = scope.apply, owner = function() return scope end })
			local logger = {}; for _, level in ipairs({ "start", "success", "warn", "info", "error" }) do logger[level] = function() end end
			local global = require("config_scope_composition").new({ manifest = Manifest, scope = "global", logger = logger,
				participants = function() return { tap_holds = before, shortcuts = actual, llm = after } end })
			local verdict, report
			global.apply("recommended", function(ok, detail) verdict, report = ok, detail end)
			helpers.assert_eq(verdict, false)
			helpers.assert_eq(report.failed, "shortcuts")
			helpers.assert_eq(report.reverted, false)
			helpers.assert_eq(global.pending(), true)
			helpers.assert_eq(trace, { "before.apply" }, "later scopes and earlier inverses wait for exact owned debt")
			unblock()
			local restored
			global.retry_restore(function(ok) restored = ok end)
			helpers.assert_eq(restored, true)
			helpers.assert_eq(trace, { "before.apply", "before.revert" })
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
			helpers.assert_eq(global.pending(), false)
		end)
	end)

	helpers.it("preserves a source successor while the exact inverse and all native claims remain pending", function()
		with_scope(function(_, owners, controls, path)
			local scope, unblock, live = controlled_scope(owners, controls, path, "keyboard", function() return false end)
			local publish, writes, candidate = controls.files.write_if_unchanged, 0, nil
			local foreign = '[foreign]\nowner = "external"\nvalue = 999\n'
			controls.files.write_if_unchanged = function(target, content, expected_source)
				if target == path then
					writes = writes + 1
					if writes == 2 then Sandbox.write_bytes(path, foreign) end
				end
				local ok, detail = publish(target, content, expected_source)
				if target == path and writes == 1 and ok == true then candidate = Sandbox.read_bytes(path) end
				return ok, detail
			end
			helpers.assert_eq(scope.apply("clear"), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			helpers.assert_eq(scope.pending(), true)
			helpers.assert_eq(owners.keyboard.set_action("ctrl_j", "none"), false)
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			helpers.assert_true(next(live) ~= nil)
			local restored_runtime = controls.runtime_calls
			Sandbox.write_bytes(path, candidate) -- Explicit fixture repair under the retained source fence.
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.runtime_calls, restored_runtime, "the acknowledged runtime inverse is not repeated")
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
			helpers.assert_eq(next(live), nil)
		end)
	end)

	helpers.it("retains a committed candidate until released dispatch claims can be reacquired for its inverse", function()
		with_scope(function(_, owners, controls, path)
			local scope, unblock, live, _, faults = controlled_scope(owners, controls, path, "keyboard", function() return false end)
			faults.reacquire = "taps"
			helpers.assert_eq(scope.apply("clear"), false)
			local candidate = Sandbox.read_bytes(path)
			helpers.assert_true(candidate ~= SOURCE)
			helpers.assert_eq(scope.pending(), true)
			unblock()
			helpers.assert_eq(scope.retry_restore(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), candidate)
			helpers.assert_true(next(live) ~= nil)
			faults.reacquire = nil
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
			helpers.assert_eq(owners.keyboard.get_action("ctrl_j"), "open_url")
			helpers.assert_eq(next(live), nil)
		end)
	end)

	helpers.it("settles release-only debt after an acknowledged explicit inverse without replaying it", function()
		with_scope(function(_, _, controls, path)
			local owners = { manager = require("modules.shortcuts.manager"), keyboard = require("modules.shortcuts.keyboard_shortcuts"),
				taps = require("modules.shortcuts.tap_keys"), chords = require("modules.shortcuts.script_chords"),
				url = require("modules.shortcuts.chatgpt"), gestures = require("modules.gestures.manager") }
			local scope, block, live = controlled_scope(owners, controls, path, "keyboard", function() return false end)
			block(false)
			helpers.assert_eq(scope.apply("recommended"), true)
			block(true)
			helpers.assert_eq(scope.revert(), false)
			helpers.assert_eq(scope.pending(), true)
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)), expected)
			local runtime_calls = controls.runtime_calls
			block(false)
			helpers.assert_eq(scope.retry_restore(), true)
			helpers.assert_eq(controls.runtime_calls, runtime_calls)
			helpers.assert_eq(next(live), nil)
		end)
	end)
end)
