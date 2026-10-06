--- tests/unit/modules/shortcuts/test_chatgpt_binding.lua

--- Drives canonical recommendations through real keyboard, action and URL owners.
local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")
local Manifest = require("infra.manifest_reader")
local CHORD = { key = "g", mods = { ctrl = true } }
local SOURCE = '[shortcuts]\nenabled = true\nchatgpt_url = "https://initial.example/chat"\nunknown = "keep"\n[other]\nvalue = 42\n'

--- Uses actual state owners and one recording process-launch boundary.
--- @param body function Test body.
--- @param options table|nil Explicit uninitialized-pair negative fixture.
local function with_binding(body, options)
	local loaded, backups = {}, {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(SOURCE, function(path)
			local seen = { commands = {}, other = 0, queue = {} }
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = { get = function(_, default) return default end,
				set = function() error("canonical bindings must not write legacy storage") end }
			package.loaded["adapters.shell_runner"] = {
				has_command = function(binary) return binary == "xdg-open" end,
				quote = function(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end,
				run = function(command) seen.commands[#seen.commands + 1] = command; return true end,
			}
			package.loaded["adapters.evdev_reader"] = {
				open = function() error("shortcut ownership must not acquire evdev") end,
				close = function() error("shortcut ownership must not close evdev") end,
			}
			package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end }
			local function reload()
				for _, name in ipairs({ "modules.shortcuts.manager", "modules.shortcuts.keyboard_shortcuts", "modules.shortcuts.tap_keys",
					"modules.shortcuts.chatgpt", "modules.shortcuts.script_chords", "modules.shortcuts.key_combinations", "modules.gestures.manager", "infra.shortcuts_scope" }) do package.loaded[name] = nil end
				local gestures = require("modules.gestures.manager")
				gestures.init({ persist = true, config_path = path, enabled = false,
					action_handlers = { script_reload = function() seen.other = seen.other + 1 end } })
				local manager = require("modules.shortcuts.manager")
				manager.init({ persist = true, config_path = path })
				local keyboard = require("modules.shortcuts.keyboard_shortcuts")
				keyboard.get_assignments()
				local taps = require("modules.shortcuts.tap_keys")
				taps.init({ is_active = function() return manager.is_enabled() end,
					defer = function(callback) seen.queue[#seen.queue + 1] = callback; return true end })
				-- A reload must rebuild every scope participant from the current
				-- canonical bytes, including the daemon's ordered-pair owner.
				local chords = require("modules.shortcuts.script_chords")
				chords.init({ is_paused = function() return false end,
					defer = function(callback) seen.queue[#seen.queue + 1] = callback; return true end })
				local combinations = require("modules.shortcuts.key_combinations")
				if not options or options.initialize_pairs ~= false then
					local Loader = require("platform.remap.tap_hold_loader")
					local defaults = require("infra.paths").shared("tap_hold/defaults.toml")
					local catalogue = Loader.load_document(defaults,
						{ tap_hold = { enabled = false, inherit_defaults = true } }, nil, path .. ".tap_hold.toml")
					helpers.assert_true(combinations.install({ keys = catalogue.catalog, hold_picker = catalogue.hold_picker,
						files = require("adapters.file_system"), route = function() return path end,
						is_paused = function() return false end,
						actions = { is_assignable = function(action)
							return action ~= "one_shot_shift" and action ~= "caps_word" and gestures.is_assignable(action) == true
						end }, changed = function() return true end }))
					local source = combinations.capture_edit_source()
					helpers.assert_type(source, "table")
					helpers.assert_eq(source.path, path)
					helpers.assert_eq(source.content, Sandbox.read_bytes(path))
					helpers.assert_true(gestures.parameter_configuration_matches(nil,
						Codec.decode(source.content), function() return true end))
				end
				return { keyboard = keyboard, manager = manager, url = require("modules.shortcuts.chatgpt"),
					combinations = combinations, gestures = gestures,
					apply = function(mode)
						local backup = path .. ".ctrl-g-" .. (#backups + 1)
						backups[#backups + 1] = backup
						return require("infra.shortcuts_scope").new({ path = path, backup_path = backup,
							is_paused = function() return false end }).apply(mode)
					end }
			end
			local owners = reload()
			body(owners, seen, path, reload)
		end)
	end)
	for _, path in ipairs(backups) do os.remove(path); os.remove(path .. ".tmp") end
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

helpers.describe("Canonical Linux ChatGPT binding", function()
	helpers.it("keeps Ctrl+G native with the master ON and no assignment", function()
		with_binding(function(owners, seen)
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_eq(owners.keyboard.dispatch(CHORD), false)
			helpers.assert_eq(#seen.commands, 0)
		end)
	end)

	helpers.it("keeps an edited URL inert until an action is explicitly bound", function()
		with_binding(function(owners, seen)
			helpers.assert_true(owners.url.set_url("https://edited.example/chat"))
			helpers.assert_eq(owners.keyboard.dispatch(CHORD), false)
			helpers.assert_eq(#seen.commands, 0)
		end)
	end)

	helpers.it("restores the canonical action and dispatches the current URL through the real registry", function()
		with_binding(function(owners, seen, path, reload)
			helpers.assert_eq(Manifest.default_for("shortcuts.keyboard.ctrl_g"), "none")
			helpers.assert_eq(Manifest.recommended_for("shortcuts.keyboard.ctrl_g"), "open_chatgpt")
			helpers.assert_true(owners.apply("recommended"))
			helpers.assert_eq(owners.keyboard.get_action("ctrl_g"), "open_chatgpt")
			helpers.assert_true(owners.url.set_url("https://edited.example/chat"))
			helpers.assert_true(owners.keyboard.dispatch(CHORD))
			helpers.assert_eq(seen.commands[1], "xdg-open 'https://edited.example/chat' >/dev/null 2>&1 &")
			local config = Codec.decode(Sandbox.read_bytes(path))
			helpers.assert_eq(config.shortcuts.keyboard.ctrl_g, "open_chatgpt")
			helpers.assert_eq(config.shortcuts.unknown, "keep")
			helpers.assert_eq(config.other.value, 42)
			owners = reload()
			helpers.assert_true(owners.keyboard.dispatch(CHORD))
			helpers.assert_eq(seen.commands[2], seen.commands[1])
		end)
	end)

	helpers.it("keeps an explicit none assignment neutral after sparse save and restart", function()
		with_binding(function(owners, seen, _, reload)
			helpers.assert_true(owners.apply("recommended"))
			helpers.assert_true(owners.keyboard.set_action("ctrl_g", "none"))
			helpers.assert_eq(owners.keyboard.dispatch(CHORD), false)
			owners = reload()
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_eq(owners.keyboard.dispatch(CHORD), false)
			helpers.assert_eq(#seen.commands, 0)
		end)
	end)

	helpers.it("runs a replacement action without also opening the ChatGPT URL", function()
		with_binding(function(owners, seen, _, reload)
			helpers.assert_true(owners.apply("recommended"))
			helpers.assert_true(owners.keyboard.set_action("ctrl_g", "script_reload"))
			helpers.assert_true(owners.keyboard.dispatch(CHORD))
			helpers.assert_eq(seen.other, 1)
			owners = reload()
			helpers.assert_true(owners.keyboard.dispatch(CHORD))
			helpers.assert_eq(seen.other, 2)
			helpers.assert_eq(#seen.commands, 0)
		end)
	end)

	helpers.it("keeps Clear neutral through master re-enable and restart", function()
		with_binding(function(owners, seen, _, reload)
			helpers.assert_true(owners.apply("recommended"))
			helpers.assert_true(owners.apply("clear"))
			helpers.assert_eq(owners.manager.is_enabled(), false)
			helpers.assert_true(owners.manager.set_enabled(true))
			helpers.assert_eq(owners.keyboard.dispatch(CHORD), false)
			owners = reload()
			helpers.assert_true(owners.manager.is_enabled())
			helpers.assert_eq(owners.keyboard.dispatch(CHORD), false)
			helpers.assert_eq(#seen.commands, 0)
		end)
	end)

	helpers.it("queues only an explicit recommendation and reads its current URL at execution", function()
		with_binding(function(owners, seen)
			helpers.assert_true(owners.apply("recommended"))
			helpers.assert_true(owners.keyboard.consume(CHORD, { defer = function(callback)
				seen.queue[#seen.queue + 1] = callback; return true end }))
			helpers.assert_eq(#seen.commands, 0)
			helpers.assert_true(owners.url.set_url("https://latest.example"))
			seen.queue[1]()
			helpers.assert_eq(seen.commands[1], "xdg-open 'https://latest.example' >/dev/null 2>&1 &")
		end)
	end)

	helpers.it("does not revive a canceled ChatGPT action after Clear and re-enable", function()
		with_binding(function(owners, seen)
			helpers.assert_true(owners.apply("recommended"))
			helpers.assert_true(owners.keyboard.consume(CHORD, { defer = function(callback)
				seen.queue[#seen.queue + 1] = callback; return true end }))
			helpers.assert_true(owners.apply("clear"))
			helpers.assert_true(owners.manager.set_enabled(true))
			seen.queue[1]()
			helpers.assert_eq(#seen.commands, 0)
		end)
	end)
end)

helpers.describe("Canonical Linux ChatGPT scope participants", function()
	helpers.it("refuses an uninitialized pair owner without publishing a recommendation or running xdg-open", function()
		with_binding(function(owners, seen, path)
			local before = Sandbox.read_bytes(path)
			local committed, detail = owners.apply("recommended")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(detail, "shortcut configuration acquisition refused")
			helpers.assert_eq(Sandbox.read_bytes(path), before)
			local backup = io.open(path .. ".ctrl-g-1", "rb")
			if backup then backup:close() end
			helpers.assert_eq(backup, nil, "uninitialized ownership cannot create a backup")
			helpers.assert_eq(owners.combinations.configuration_pending(), nil)
			helpers.assert_true(owners.manager.configuration_admitted())
			helpers.assert_eq(owners.keyboard.dispatch(CHORD), false)
			helpers.assert_eq(#seen.commands, 0)
			helpers.assert_eq(seen.other, 0)
		end, { initialize_pairs = false })
	end)

	helpers.it("reloads the actual pair and parameter owners from newly persisted canonical bytes", function()
		with_binding(function(owners, seen, path, reload)
			local current = Sandbox.read_bytes(path)
				.. '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "open_url"\n'
				.. '[gesture_parameters]\ncombination__caps_lock_then_tab__open_url = "https://pair.example"\n'
			Sandbox.write_bytes(path, current)
			owners = reload()
			helpers.assert_eq(owners.combinations.get_action("caps_lock_then_tab"), "open_url")
			helpers.assert_eq(owners.gestures.get_action_parameter("combination__caps_lock_then_tab", "open_url"), "https://pair.example")
			helpers.assert_true(owners.apply("recommended"))
			helpers.assert_eq(owners.combinations.get_action("caps_lock_then_tab"), "none")
			helpers.assert_eq(owners.gestures.get_action_parameter("combination__caps_lock_then_tab", "open_url"), "")
			helpers.assert_true(owners.url.set_url("https://after-reload.example/chat"))
			helpers.assert_true(owners.keyboard.dispatch(CHORD))
			helpers.assert_eq(seen.commands[1], "xdg-open 'https://after-reload.example/chat' >/dev/null 2>&1 &")
		end)
	end)
end)
