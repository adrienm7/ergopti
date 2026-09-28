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
local function with_binding(body)
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
					"modules.shortcuts.chatgpt", "modules.gestures.manager", "infra.shortcuts_scope" }) do package.loaded[name] = nil end
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
				return { keyboard = keyboard, manager = manager, url = require("modules.shortcuts.chatgpt"),
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
