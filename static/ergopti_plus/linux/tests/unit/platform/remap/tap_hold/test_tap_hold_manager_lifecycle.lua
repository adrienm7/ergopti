--- tests/unit/platform/remap/tap_hold/test_tap_hold_manager_lifecycle.lua

--- ==============================================================================
--- MODULE: Tap-Hold Manager Lifecycle
--- DESCRIPTION:
--- The feature switch, the file's own switch and the pause decide together
--- whether the engine is in the keyboard hook, and a change from the tray is
--- applied live by reload(). A tap action reaches the catalogue executor.
--- ==============================================================================

package.loaded["tests.support.platform.remap.tap_hold.tap_hold_manager_fixture"] = nil
local Fixture = require("tests.support.platform.remap.tap_hold.tap_hold_manager_fixture")
local helpers, DEFAULTS, fake_hook, write, manager =
	Fixture.helpers, Fixture.DEFAULTS, Fixture.fake_hook, Fixture.write, Fixture.manager




helpers.describe("tap-hold manager", function()
	helpers.it("permits retry after the first engine installation is refused (init-apply-refusal)", function()
		helpers.load_module("platform.remap.nav_layer")
		local Manager = helpers.load_module("platform.remap.tap_hold_manager")
		local user_path = os.tmpname()
		write(user_path, "")
		local hook = fake_hook()
		local install = hook.set_remapper
		hook.set_remapper = function() return false end
		local opts = { keyboard_hook = hook, execute_action = function() end,
			action_names = require("modules.gestures.manager").get_executable_action_names,
			on_text_injected = function() end, defaults_path = DEFAULTS, user_path = user_path,
			config_path = require("tests.support.tap_hold_fixture").config_path(user_path) }
		local first = Manager.init(opts)
		hook.set_remapper = install
		local called, retried = pcall(Manager.init, opts)
		local installed = hook.engine ~= nil
		Manager._reset_for_test()
		os.remove(user_path)
		helpers.assert_eq(first, false)
		helpers.assert_true(called, "refused initialization must not make the manager permanently initialized")
		helpers.assert_true(retried)
		helpers.assert_true(installed)
	end)
	helpers.it("refuses a FIFO one-shot table without blocking a reload", function()
		local uv = require("luv")
		local Shell = require("core.process.adapters.shell_runner")
		local path = os.tmpname()
		os.remove(path)
		assert(Shell.run("mkfifo -- " .. Shell.quote(path)))
		local code = string.format([[package.path = %q
require("core.lifecycle.engine.compat.utf8").install()
local fixture = require("tests.support.platform.remap.tap_hold.tap_hold_manager_fixture")
local manager, hook, _, user_path = fixture.manager()
local original = hook.engine
local paths = require("core.fs.engine.paths")
local shared = paths.shared
paths.shared = function(name)
  if name == "tap_hold/data/one_shot_shift.json" then return %q end
  return shared(name)
end
assert(manager.reload() == false)
assert(hook.engine == original)
paths.shared = shared
manager._reset_for_test()
os.remove(user_path)
]], package.path, path)
		local exited, expired, status, signal = false, false, nil, nil
		local timer = assert(uv.new_timer())
		local child
		child = assert(uv.spawn(assert(arg[-1]), { args = { "-e", code } }, function(exit_code, sig)
			exited, status, signal = true, exit_code, sig
			uv.timer_stop(timer); uv.close(timer); uv.close(child)
		end))
		assert(require("core.timing.engine.native_timer").start(uv, timer, 2000, 0, function()
			expired = true; child:kill("sigkill")
		end))
		while not exited do uv.run("once") end
		uv.run("nowait")
		os.remove(path)
		helpers.assert_eq(expired, false, "a reload must not block on a FIFO")
		helpers.assert_eq(status, 0)
		helpers.assert_eq(signal, 0)
	end)

	helpers.it("installs the engine at init and runs its tap actions", function()
		local Manager, hook, actions, user_path = manager()
		helpers.assert_true(hook.engine ~= nil, "engine in the hook")
		helpers.assert_true(hook.engine:handles(42), "left Shift is configured by default")
		hook.on_tap("copy")
		helpers.assert_eq(actions[1], "copy@tap_hold")
		Manager._reset_for_test()
		os.remove(user_path)
	end)

	helpers.it("keeps a delayed copy retry out of a newly focused field", function()
		local names = { "adapters.clipboard", "core.events.timer_scheduler", "platform.system.notifier" }
		local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local callback, field = nil, "first"
		package.loaded["adapters.clipboard"] = { change_counter = function() return 100 end }
		package.loaded["core.events.timer_scheduler"] = {
			after = function(_, fn) callback = fn; return { armed = true } end,
			cancel = function() return true end,
		}
		package.loaded["platform.system.notifier"] = { send = function() return true end }
		local Manager, path
		local ok, err = xpcall(function()
			local hook, actions
			Manager, hook, actions, path = manager(nil, { capture_copy_owner = function()
				local selected = field
				return { current = function() return selected == field end }
			end })
			local code = require("platform.remap.tap_hold_engine").KEY_CODES.left_shift
			hook.engine:process(code, 1, 0)
			local _, action, binding = hook.engine:process(code, 0, 100)
			helpers.assert_eq(action, "copy")
			hook.on_tap(action, binding)
			helpers.assert_eq(#actions, 1, "the first copy is still sent after key-up")
			helpers.assert_true(type(callback) == "function")
			callback()
			helpers.assert_eq(#actions, 2, "the unchanged field and remap permit the retry")
			hook.on_tap("copy")
			helpers.assert_eq(#actions, 3)
			field = "second"
			callback()
			helpers.assert_eq(#actions, 3, "the retry cannot copy the second field")
			hook.on_tap("copy")
			helpers.assert_eq(#actions, 4)
			helpers.assert_true(Manager.set_enabled(false))
			callback()
			helpers.assert_eq(#actions, 4, "a retired remap cannot send its delayed retry")
		end, debug.traceback)
		if Manager then Manager._reset_for_test() end
		if path then os.remove(path) end
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end)

	helpers.it("reports an explicit refusal of the delayed copy retry", function()
		local names = { "adapters.clipboard", "core.events.timer_scheduler", "platform.system.notifier" }
		local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local callback, warnings, calls = nil, 0, 0
		package.loaded["adapters.clipboard"] = { change_counter = function() return 100 end }
		package.loaded["core.events.timer_scheduler"] = {
			after = function(_, fn) callback = fn; return { armed = true } end,
			cancel = function() return true end,
		}
		package.loaded["platform.system.notifier"] = { send = function() warnings = warnings + 1; return true end }
		local Manager, path
		local ok, err = xpcall(function()
			local hook, actions
			Manager, hook, actions, path = manager(nil, { capture_copy_owner = function()
				return { current = function() return true end }
			end, execute_action = function()
				calls = calls + 1
				if calls == 2 then return false end
			end })
			hook.on_tap("copy")
			helpers.assert_eq(calls, 1)
			callback()
			helpers.assert_eq(calls, 2)
			helpers.assert_eq(warnings, 1, "the refused retry is reported without waiting for another timer")
		end, debug.traceback)
		if Manager then Manager._reset_for_test() end
		if path then os.remove(path) end
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end)

	helpers.it("transports the actual monitor tap binding through release and queued rollover", function()
		local Manager, hook, actions, user_path = manager()
		local Engine = require("platform.remap.tap_hold_engine")
		local code = Engine.KEY_CODES.tab
		local saved_hook, native_hook = package.loaded["platform.input.keyboard_hook"], nil
		local ok, failure = pcall(function()
			hook.engine:process(code, 1, 0)
			local _, tap, binding = hook.engine:process(code, 0, 100)
			helpers.assert_eq(tap, "alt_tab_monitor")
			helpers.assert_eq(binding, "tap_hold__tab", "the shared key id survives to the native owner")
			hook.on_tap(tap, binding)
			helpers.assert_eq(actions[1], "alt_tab_monitor@tap_hold__tab")
			native_hook = helpers.load_module("platform.input.keyboard_hook")
			local received
			native_hook.set_remapper(hook.engine, function(action, origin)
				if action == "alt_tab_monitor" then received = origin end
			end)
			native_hook._test_drive({
				{ type = 1, code = code, value = 1, at_ms = 0 },
				{ type = 1, code = code, value = 0, at_ms = 100 },
			}, { onEmitRaw = function() return true end }, true)
			helpers.assert_eq(received, "tap_hold__tab", "the actual native hook forwards the source identity")
			-- A native action replayed under a typing roll belongs to the replayed
			-- key, not the roll key or the later event that settled that roll.
			local queued = Engine.new({ keys = {
				space = { tap_action = "", hold_modifier = "ctrl", time_activation_seconds = 0.2 },
				win = { tap_action = "alt_tab_monitor", time_activation_seconds = 0.2 },
			}, roll_keys = { "space" }, tap_min_ms = 50, lone_tap_max_ms = 0, one_shot_timeout_ms = 2000 })
			queued:process(Engine.KEY_CODES.space, 1, 0)
			queued:process(Engine.KEY_CODES.win, 1, 20)
			local due = queued:tick(201)
			local delivered
			for _, event in ipairs(due) do if event.tap then delivered = event end end
			helpers.assert_type(delivered, "table")
			helpers.assert_eq(delivered.tap, "alt_tab_monitor")
			helpers.assert_eq(delivered.binding, "tap_hold__win")
		end)
		if native_hook then native_hook.set_remapper(nil) end
		package.loaded["platform.input.keyboard_hook"] = saved_hook
		Manager._reset_for_test()
		os.remove(user_path)
		assert(ok, failure)
	end)

	helpers.it("admits a monitor tap only from its active canonical tap-hold source", function()
		local names = { "modules.gestures.manager", "platform.remap.tap_hold_manager", "adapters.window_switch",
			"platform.input.keyboard_hook", "core.fs.adapters.file_system", "settings.engine.paths", "core.fs.adapters.storage", "ui.gesture_conflicts" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local user_path, config_path = os.tmpname(), os.tmpname()
		write(user_path)
		local file = assert(io.open(config_path, "w")); file:write("[gesture_parameters]\nprivate = 'unchanged'\n"); file:close()
		local Manager, generation, capture, accepted, on_read = nil, 1, nil, 0, nil
		local ok, failure = pcall(function()
			package.loaded["platform.input.keyboard_hook"] = { physical_source_receipt = function()
				return { ready = true, generation = generation }
			end }
			package.loaded["core.fs.adapters.file_system"] = { read_with_status = function(path)
				if on_read and path == user_path then local callback = on_read; on_read = nil; callback() end
				local stream = io.open(path, "rb")
				if not stream then return nil, "absent" end
				local text = stream:read("*a"); stream:close(); return text, "ok"
			end }
			package.loaded["settings.engine.paths"] = { config = function() return config_path end }
			package.loaded["core.fs.adapters.storage"] = { get = function(_, default) return default end }
			package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end }
			package.loaded["adapters.window_switch"] = { new = function(owner_capture)
				capture = owner_capture
				return { run = function(binding)
					local guard = owner_capture(binding)
					if type(guard) ~= "function" or guard() ~= true then return false end
					accepted = accepted + 1; return true
				end }
			end }
			local Gestures = helpers.load_module("modules.gestures.manager")
			Gestures.init({ persist = true, config_path = config_path, enabled = false })
			Manager = helpers.load_module("platform.remap.tap_hold_manager")
			package.loaded["platform.remap.tap_hold_manager"] = Manager
			local hook = fake_hook()
			Manager.init({ keyboard_hook = hook, execute_action = Gestures.execute_action,
				action_names = Gestures.get_executable_action_names, on_text_injected = function() end,
				defaults_path = DEFAULTS, user_path = user_path,
				config_path = require("tests.support.tap_hold_fixture").config_path(user_path) })
			local code = require("platform.remap.tap_hold_engine").KEY_CODES.tab
			hook.engine:process(code, 1, 0)
			local _, tap, binding = hook.engine:process(code, 0, 100)
			hook.on_tap(tap, binding)
			helpers.assert_eq(accepted, 1, "real engine and dispatcher reach the scoped native capture")
			local guard, actual_path = capture("tap_hold__tab")
			helpers.assert_type(guard, "function")
			helpers.assert_eq(actual_path, user_path, "monitor admission owns tap_hold.toml, not config.toml")
			helpers.assert_eq(capture("tap_hold"), nil, "a generic callback cannot invent a physical binding")
			helpers.assert_eq(capture("tap_hold__unknown"), nil)
			generation = 2
			helpers.assert_eq(guard(), false, "physical reader replacement revokes a pending operation")
			generation = 1
			local source_guard = assert(capture("tap_hold__tab"))
			local stream = assert(io.open(user_path, "a")); stream:write("\n# foreign source change\n"); stream:close()
			helpers.assert_eq(source_guard(), false, "even an action-preserving source edit revokes captured admission")
			write(user_path, '[tap_hold.keys.tab]\ntap_action = "copy"\n')
			helpers.assert_eq(capture("tap_hold__tab"), nil, "unreloaded canonical source cannot authorize the old runtime tap")
			write(user_path)
			local paused_guard = assert(capture("tap_hold__tab"))
			Manager.set_paused(true); Manager.set_paused(false)
			helpers.assert_eq(paused_guard(), false, "pause and resume cannot revive an old source receipt")
			local reentrant_guard = assert(capture("tap_hold__tab"))
			on_read = function() Manager.set_paused(true); Manager.set_paused(false) end
			helpers.assert_eq(reentrant_guard(), false, "a source read cannot revive an epoch changed during admission")
			Manager.set_enabled(false)
			helpers.assert_eq(capture("tap_hold__tab"), nil, "disabled native engine owns no monitor tap")
			local stream = assert(io.open(config_path, "rb")); local content = stream:read("*a"); stream:close()
			helpers.assert_eq(content, "[gesture_parameters]\nprivate = 'unchanged'\n", "source admission never changes parameters")
		end)
		if Manager then Manager._reset_for_test() end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		os.remove(user_path); os.remove(config_path)
		assert(ok, failure)
	end)

	-- The live layout says which keys are modifiers (ctrl:nocaps makes CapsLock
	-- a Ctrl): the engine asks the hook, not its own list of the usual keys
	-- (engine-live-modifiers).
	helpers.it("tells the engine which modifiers the live layout holds (engine-live-modifiers)", function()
		local Manager, hook, _, user_path = manager()
		local TAB = require("platform.remap.tap_hold_engine").KEY_CODES.tab
		hook.mods = { ctrl = true }
		helpers.assert_nil(hook.engine:process(TAB, 1, 0), "Tab under a Ctrl only the layout knows is Ctrl+Tab")
		hook.engine:process(TAB, 0, 50)
		hook.mods = {}
		helpers.assert_true(hook.engine:process(TAB, 1, 100) ~= nil, "with no modifier held, Tab is its tap-hold")
		Manager._reset_for_test()
		os.remove(user_path)
	end)

	-- The engine gets the one-shot results of _shared/tap_hold/data/one_shot_shift.json
	-- and the magic key's, and what it cannot type goes to the injector
	-- (one-shot-results-shared).
	helpers.it("gives the one-shot Shift the shared results and the magic key's (one-shot-results-shared)", function()
		local Manager, hook, _, user_path, resets = manager()
		require("adapters.keyboard_layout")._set_table_for_test(nil)
		local magic = require("modules.hotstrings.magic_key").get()
		helpers.assert_true(magic ~= "", "the shipped magic key")
		hook.key_text = function(code) return ({ [41] = magic, [57] = " ", [52] = "." })[code] end
		local saved = package.loaded["modules.hotstrings.injector"]
		local injected = {}
		package.loaded["modules.hotstrings.injector"] = {
			inject = function(_, text) injected[#injected + 1] = text; return { ok = true } end,
		}
		local ok, err = pcall(function()
			for code, expected in pairs({ [41] = "J", [57] = "-", [52] = " :" }) do
				hook.engine:process(97, 1, 0)
				hook.engine:process(97, 0, 100)
				local _, tap = hook.engine:process(code, 1, 200)
				helpers.assert_eq(tap, { type_text = expected }, "no layout table: the injector types " .. expected)
				hook.engine:process(code, 0, 250)
				hook.on_tap(tap)
			end
		end)
		package.loaded["modules.hotstrings.injector"] = saved
		Manager._reset_for_test()
		os.remove(user_path)
		if not ok then error(err, 0) end
		table.sort(injected)
		helpers.assert_eq(injected, { " :", "-", "J" })
		-- Text typed by the injector never reaches the hotstring engine, whose
		-- buffer then describes another line: the daemon is told, to reset it
		-- as its other injections do (one-shot-injected-text).
		table.sort(resets)
		helpers.assert_eq(resets, { " :", "-", "J" }, "each injected result resets the typing buffer")
	end)

	-- The magic key is the user's choice, so it keeps its meaning even on a
	-- character the shared table has a result for; Windows checked it before
	-- the "," "'" and " " results too (one-shot-magic-first).
	helpers.it("gives the magic key its result before the character's own (one-shot-magic-first)", function()
		local Manager, hook, _, user_path = manager()
		hook.key_text = function(code) return code == 51 and "," or nil end
		local names = { "modules.hotstrings.magic_key", "modules.hotstrings.injector" }
		local saved = {}
		for _, name in ipairs(names) do
			saved[name] = package.loaded[name]
		end
		local injected = {}
		package.loaded["modules.hotstrings.magic_key"] = { get = function() return "," end }
		package.loaded["modules.hotstrings.injector"] = {
			inject = function(_, text) injected[#injected + 1] = text; return { ok = true } end,
		}
		require("adapters.keyboard_layout")._set_table_for_test(nil)
		local ok, err = pcall(function()
			hook.engine:process(97, 1, 0)
			hook.engine:process(97, 0, 100)
			local _, tap = hook.engine:process(51, 1, 200)
			helpers.assert_eq(tap, { type_text = "J" }, "a magic \",\" types the magic key's result, not \" ;\"")
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		Manager._reset_for_test()
		os.remove(user_path)
		if not ok then error(err, 0) end
	end)

	-- The hook names the level keys held now (a CapsLock the layout makes an
	-- AltGr included); the engine lifts them around a one-shot result
	-- (one-shot-lifts-levels).
	helpers.it("lets the engine lift the level keys the hook says are held (one-shot-lifts-levels)", function()
		local Manager, hook, _, user_path = manager()
		hook.key_text = function(code) return code == 52 and "." or nil end
		hook.text_mods = { 54 }
		local saved = package.loaded["adapters.keyboard_layout"]
		package.loaded["adapters.keyboard_layout"] = {
			plan = function() return { { keycode = 57, mods = {} }, { keycode = 39, mods = {} } } end,
		}
		local ok, err = pcall(function()
			hook.engine:process(97, 1, 0)
			hook.engine:process(97, 0, 100)
			local out = hook.engine:process(52, 1, 200)
			local parts = {}
			for _, ev in ipairs(out or {}) do parts[#parts + 1] = ev.code .. ":" .. ev.value end
			helpers.assert_eq(table.concat(parts, " "), "54:0 57:1 57:0 39:1 39:0 54:1",
				"the hand's right Shift is lifted around the result")
		end)
		package.loaded["adapters.keyboard_layout"] = saved
		Manager._reset_for_test()
		os.remove(user_path)
		if not ok then error(err, 0) end
	end)

	-- LAlt's Backspace logic types its keystrokes with only their own
	-- modifiers, lifting every one the hook says is down, as the live layout
	-- names them (lalt-backspace-logic).
	helpers.it("lets the engine lift the shortcut keys the hook says are held (lalt-backspace-logic)", function()
		local Manager, hook, _, user_path = manager()
		hook.text_mods = { 42 }
		hook.shortcut_mods = { 126 }
		local ok, err = pcall(function()
			hook.engine:process(42, 1, 0)
			hook.engine:process(56, 1, 10)
			local out = hook.engine:process(56, 0, 100)
			local parts = {}
			for _, ev in ipairs(out or {}) do parts[#parts + 1] = ev.code .. ":" .. ev.value end
			helpers.assert_eq(table.concat(parts, " "), "42:0 126:0 111:1 111:0 126:1 42:1",
				"LShift then LAlt is a Delete, with the Super the hook names lifted too")
		end)
		Manager._reset_for_test()
		os.remove(user_path)
		if not ok then error(err, 0) end
	end)

	helpers.it("takes the engine out on pause and off, and back after", function()
		local Manager, hook, _, user_path = manager()
		Manager.set_paused(true)
		helpers.assert_nil(hook.engine, "a paused script remaps nothing")
		Manager.set_enabled(false)
		Manager.set_paused(false)
		helpers.assert_nil(hook.engine, "still off after the pause")
		Manager.set_enabled(true)
		helpers.assert_true(hook.engine ~= nil)
		helpers.assert_true(Manager.is_active())
		Manager._reset_for_test()
		os.remove(user_path)
	end)

	for _, fault in ipairs({ "refusal", "exception" }) do
		helpers.it("keeps the enabled switch after a hook " .. fault .. " (enabled-apply-refusal)", function()
			local Manager, hook, _, user_path = manager()
			local original, install = hook.engine, hook.set_remapper
			hook.set_remapper = function()
				if fault == "exception" then error("controlled failure") end
				return false
			end
			local called, result = pcall(Manager.set_enabled, false)
			local enabled, installed = Manager.is_enabled(), hook.engine
			hook.set_remapper = install
			local retried = Manager.set_enabled(false)
			local after = Manager.is_enabled()
			Manager._reset_for_test()
			os.remove(user_path)
			helpers.assert_true(called)
			helpers.assert_eq(result, false)
			helpers.assert_true(enabled, "the refused switch must keep its previous value")
			helpers.assert_true(installed == original)
			helpers.assert_true(retried)
			helpers.assert_eq(after, false)
		end)
	end

	helpers.it("applies a changed file live on reload", function()
		local Manager, hook, _, user_path = manager()
		write(user_path, '[tap_hold.keys.caps_lock]\nenabled = false\n')
		helpers.assert_true(Manager.reload())
		helpers.assert_true(not hook.engine:handles(58), "CapsLock is itself again")
		write(user_path, '[tap_hold]\nenabled = false\n')
		Manager.reload()
		helpers.assert_nil(hook.engine, "config.toml's switch turns it off")
		helpers.assert_true(not Manager.file_enabled())
		Manager._reset_for_test()
		os.remove(user_path)
	end)

	helpers.it("preserves the effective configuration after a refused reload and retries it (reload-apply-refusal)", function()
		local Manager, hook, _, user_path = manager()
		local original, install = hook.engine, hook.set_remapper
		local original_active = Manager.is_active()
		hook.set_remapper = function() return false end
		write(user_path, '[tap_hold]\nenabled = false\n')
		local refused = Manager.reload()
		local effective_file_enabled, effective_active = Manager.file_enabled(), Manager.is_active()
		local still_installed = hook.engine == original
		hook.set_remapper = install
		local retried = Manager.reload()
		local after_retry, installed_after_retry = Manager.file_enabled(), hook.engine
		Manager._reset_for_test()
		os.remove(user_path)
		helpers.assert_eq(refused, false)
		helpers.assert_true(still_installed)
		helpers.assert_eq(effective_file_enabled, true, "a refused setting is not in force")
		helpers.assert_eq(effective_active, original_active, "the old engine still receives keys")
		helpers.assert_true(retried)
		helpers.assert_eq(after_retry, false)
		helpers.assert_nil(installed_after_retry)
	end)

	for _, fault in ipairs({ "refusal", "exception" }) do
		helpers.it("preserves effective state after candidate installation " .. fault .. " (candidate-apply-refusal)", function()
			local Manager, hook, _, user_path = manager()
			local original, install = hook.engine, hook.set_remapper
			hook.set_remapper = function()
				if fault == "exception" then error("controlled failure") end
				return false
			end
			local called, result = pcall(Manager.apply_configuration, { tap_hold = { inherit_defaults = true } }, nil,
				{ tap_holds = { enabled = false } })
			local file_enabled, installed = Manager.file_enabled(), hook.engine
			hook.set_remapper = install
			local retried = Manager.apply_configuration({ tap_hold = { inherit_defaults = true } }, nil, { tap_holds = { enabled = false } })
			Manager._reset_for_test()
			os.remove(user_path)
			helpers.assert_true(called, "installation errors are reported as refusal")
			helpers.assert_eq(result, false)
			helpers.assert_true(file_enabled, "the refused candidate is not effective")
			helpers.assert_true(installed == original)
			helpers.assert_true(retried)
		end)
	end

	helpers.it("keeps the current configuration when snapshot restoration is refused (snapshot-apply-refusal)", function()
		local Manager, hook, _, user_path = manager()
		local enabled = Manager.configuration_snapshot()
		helpers.assert_true(Manager.apply_configuration({ tap_hold = { inherit_defaults = true } }, nil, { tap_holds = { enabled = false } }))
		local disabled = Manager.configuration_snapshot()
		helpers.assert_true(Manager.restore_configuration(enabled))
		local original, install = hook.engine, hook.set_remapper
		hook.set_remapper = function() return false end
		local result = Manager.restore_configuration(disabled)
		local file_enabled, installed, active = Manager.file_enabled(), hook.engine, Manager.is_active()
		hook.set_remapper = install
		local retried = Manager.restore_configuration(disabled)
		Manager._reset_for_test()
		os.remove(user_path)
		helpers.assert_eq(result, false)
		helpers.assert_true(file_enabled)
		helpers.assert_true(installed == original)
		helpers.assert_true(active)
		helpers.assert_true(retried)
	end)

	helpers.it("keeps the running engine when a reload cannot read the defaults", function()
		local Manager, hook, _, user_path = manager()
		local running = hook.engine
		local Loader = require("platform.remap.tap_hold_loader")
		local real = Loader.load
		Loader.load = function() error("defaults unreadable", 0) end
		local ok = Manager.reload()
		Loader.load = real
		helpers.assert_true(not ok, "the failure is reported")
		helpers.assert_true(hook.engine == running, "and the keyboard keeps working as before")
		Manager._reset_for_test()
		os.remove(user_path)
	end)

	helpers.it("keeps the running engine when the user file becomes malformed", function()
		local Manager, hook, _, user_path = manager()
		local running = hook.engine
		local file = assert(io.open(user_path, "w"))
		file:write("[tap_hold\n"); file:close()
		helpers.assert_eq(Manager.reload(), false)
		helpers.assert_true(hook.engine == running, "a failed reload cannot publish a neutral replacement")
		Manager._reset_for_test()
		os.remove(user_path)
	end)

	helpers.it("offers every hold option and the catalogue as taps", function()
		local Manager, _, _, user_path = manager()
		helpers.assert_eq(Manager.canonical_hold("layer", "nav"), "nav")
		helpers.assert_eq(Manager.canonical_hold("modifier", "ctrl+shift"), "ctrl+shift")
		helpers.assert_eq(Manager.canonical_hold("modifier", "Shift + Ctrl"), "ctrl+shift",
			"a reordered spelling is the same option")
		helpers.assert_eq(Manager.canonical_hold("none", ""), "")
		helpers.assert_nil(Manager.canonical_hold("layer", "sym"))
		helpers.assert_nil(Manager.canonical_hold("modifier", ""), "a modifier hold needs a modifier")
		helpers.assert_nil(Manager.canonical_hold("modifier", "hyper"))
		for _, id in ipairs({ "copy", "paste", "enter", "one_shot_shift", "alt_tab_monitor", "open_url" }) do
			helpers.assert_true(Manager.is_tap_action(id), id)
		end
		helpers.assert_true(not Manager.is_tap_action("none"), "none is a sentinel, not an action")
		helpers.assert_true(not Manager.is_tap_action("rm -rf"))
		Manager._reset_for_test()
		os.remove(user_path)
	end)

	helpers.it("rejects a second init and a use before init", function()
		local Manager, _, _, user_path = manager()
		helpers.assert_true(not pcall(Manager.init, {}), "duplicate init")
		Manager._reset_for_test()
		helpers.assert_true(not pcall(Manager.reload), "use before init")
		os.remove(user_path)
	end)

	helpers.it("reports one threshold only when every key agrees", function()
		local Manager, _, _, user_path = manager()
		helpers.assert_eq(Manager.threshold_ms(), 200, "no key ships a delay: the shipped keys all follow the global one")
		Manager._reset_for_test()
		os.remove(user_path)
		local Mixed, _, _, mixed_path = manager('[tap_hold]\ninherit_defaults = true\n'
			.. '[tap_hold.keys.caps_lock]\ntime_activation_seconds = 0.5\n')
		helpers.assert_nil(Mixed.threshold_ms(), "a key with a delay of its own disagrees with the rest")
		Mixed._reset_for_test()
		os.remove(mixed_path)
		local Same, _, _, same_path = manager('[tap_hold]\ninherit_defaults = false\n'
			.. '[tap_hold.keys.caps_lock]\ntap_action = "enter"\nhold_modifier = "ctrl"\ntime_activation_seconds = 0.25\n')
		helpers.assert_eq(Same.threshold_ms(), 250)
		Same._reset_for_test()
		os.remove(same_path)
	end)

end)




-- A tap set to an action Linux could not run (select_all, undo, redo and find
-- were declared for Windows alone) held as configured, did nothing on a tap,
-- and left one DEBUG line per press as the only trace.
helpers.describe("tap-hold manager: taps this driver cannot run", function()

	--- A manager on the real action catalogue, as the daemon wires it, and the
	--- warnings its configuration load logged.
	local function catalogue_manager(user_text)
		local Gestures = helpers.load_module("modules.gestures.manager")
		local Logger = require("core.logger.engine.shim")
		local real_warn, warnings = Logger.warn, {}
		Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		local Manager = helpers.load_module("platform.remap.tap_hold_manager")
		local user_path = os.tmpname()
		if user_text then write(user_path, user_text) else os.remove(user_path) end
		local ok, err = pcall(Manager.init, {
			keyboard_hook = fake_hook(),
			execute_action = Gestures.execute_action,
			action_names = Gestures.get_executable_action_names,
			on_text_injected = function() end,
			defaults_path = DEFAULTS,
			user_path = user_path,
			config_path = require("tests.support.tap_hold_fixture").config_path(user_path),
		})
		local function close()
			Logger.warn = real_warn
			Manager._reset_for_test()
			os.remove(user_path)
		end
		if not ok then close(); error(err, 0) end
		return Manager, warnings, Gestures, close, user_path
	end

	helpers.it("offers every action the shared catalogue declares for Linux as a tap", function()
		local Manager, warnings, Gestures, close = catalogue_manager()
		local ok, err = pcall(function()
			helpers.assert_eq(warnings, {}, "the shipped defaults only tap what Linux runs")
			helpers.assert_true(#Gestures.LINUX_DECLARED_ACTIONS > 70, "the catalogue must be read")
			for _, id in ipairs(Gestures.LINUX_DECLARED_ACTIONS) do
				helpers.assert_true(Manager.is_tap_action(id), id .. " is declared for Linux")
			end
			for _, id in ipairs({ "select_all", "undo", "redo", "find" }) do
				helpers.assert_true(Manager.is_tap_action(id), id .. " taps on Linux too")
			end
		end)
		close()
		if not ok then error(err, 0) end
	end)

	helpers.it("warns once at configuration load about a tap it cannot run (config-outdated-tap-hold)", function()
		local Manager, warnings, _, close, user_path = catalogue_manager(
			'[tap_hold.keys.caps_lock]\ntap_action = "microsoft_bold"\n'
				.. '[tap_hold.keys.left_ctrl]\ntap_action = "select_all"\n')
		local ok, err = pcall(function()
			helpers.assert_eq(#warnings, 1, "one warning, for the one tap Linux cannot run")
			helpers.assert_contains(warnings[1], "tap_hold.keys.caps_lock.tap_action")
			helpers.assert_contains(warnings[1], "microsoft_bold")
			helpers.assert_contains(warnings[1], user_path)
			helpers.assert_true(Manager.reload())
			helpers.assert_eq(#warnings, 1, "the same stale tap is not named again at every reload")
			write(user_path, '[tap_hold.keys.caps_lock]\ntap_action = "lookup"\n')
			helpers.assert_true(Manager.reload())
			helpers.assert_eq(#warnings, 2, "another stale tap is another entry to name")
			helpers.assert_contains(warnings[2], "lookup")
		end)
		close()
		if not ok then error(err, 0) end
	end)

end)




-- The daemon wires the executor to the gestures module, which also owns the
-- touchpad reader. The reader's failure path used to drop the daemon's handle
-- to that module, and the tap-hold executor read the same handle: one touchpad
-- error disabled every catalogue tap action until a restart.
helpers.describe("tap-hold manager: the daemon's action executor", function()

	local function daemon_source()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local src = fh:read("*a")
		fh:close()
		return src
	end

	helpers.it("never drops the action catalogue when the touchpad reader fails", function()
		local src = daemon_source()
		helpers.assert_true(src:find('local gestures = RuntimeGuard.optional_require("modules.gestures.manager")', 1, true)
			~= nil, "the scan must find the handle's declaration, or it proves nothing")
		local offenders = {}
		for line in src:gmatch("[^\n]+") do
			-- A statement, not a table field (`gestures = gestures,`).
			if line:match("^%s*gestures%s*=[^=]") and not line:match(",%s*$") then
				offenders[#offenders + 1] = line
			end
		end
		helpers.assert_eq(offenders, {},
			"the reader stops on its own failure; the module handle is the action catalogue "
				.. "every tap, shortcut and tray row runs through")
	end)

	-- The injector types a one-shot result the layout has no key for, and the
	-- hotstring engine never sees it: the daemon resets its buffer, as after
	-- its other injections (one-shot-injected-text).
	helpers.it("resets the typing buffer after a one-shot result the injector typed (one-shot-injected-text)", function()
		local src = daemon_source()
		local start = src:find("TapHold.init({", 1, true)
		helpers.assert_true(start ~= nil, "the daemon must initialise the tap-hold manager")
		local block = src:sub(start, (src:find("\n\t})", start, true) or #src))
		local reset = block:match("on_text_injected%s*=%s*function%b()(.-)\n\t\tend,")
		helpers.assert_true(reset ~= nil, "the daemon must hand the manager on_text_injected")
		helpers.assert_true(reset:find("engine:reset(false)", 1, true) ~= nil and reset:find("_undoable = nil", 1, true) ~= nil,
			"it must drop the hotstring buffer and the undoable expansion")
	end)


	helpers.it("preserves unknown start authority through the actual one-shot callback (one-shot-injected-text)", function()
		local src = daemon_source()
		local start = assert(src:find("TapHold.init({", 1, true))
		local block = src:sub(start, assert(src:find("\n\t})", start, true)))
		local body = assert(block:match("on_text_injected%s*=%s*function%b()(.-)\n\t\tend,"))
		local compile = loadstring or load
		local factory = assert(compile("local engine = ...; local _undoable = {}; return function() " .. body
			.. " end, function() return _undoable end", "=owned-one-shot-callback"))
		local engine = require("hotstrings.engine.matcher").new({})
		engine:on_char("x")
		local callback, undoable = factory(engine)
		helpers.assert_true(undoable() ~= nil, "the original undoable record is present")
		callback()
		helpers.assert_eq(engine:current_buffer(), "", "the real callback clears stale text")
		helpers.assert_eq(engine:buffer_starts_at_word_boundary(), false, "injected output cannot invent word-start authority")
		helpers.assert_nil(undoable(), "the real callback clears the original undoable record")
	end)

	helpers.it("binds the tap-hold executor to the catalogue once, at init", function()
		local src = daemon_source()
		local start = src:find("TapHold.init({", 1, true)
		helpers.assert_true(start ~= nil, "the daemon must initialise the tap-hold manager")
		local block = src:sub(start, (src:find("\n\t})", start, true) or #src))
		local executor = block:match("execute_action%s*=%s*function%b()(.-)\n\t\tend,")
		helpers.assert_true(executor ~= nil and executor ~= "", "the executor's body must be found")
		helpers.assert_nil(executor:find("[^%w_]gestures%."),
			"the executor must not call through the reader's mutable module handle")
		helpers.assert_nil(executor:find("not gestures[%s)]"),
			"nor test that handle for presence")
	end)

end)




helpers.describe("native OneShot Manager route", function()
	local Fixture = require("tests.support.input_owner_fixture")
	local PREFIX = "29:1,29:0,29:1,29:0"
	local function rows(s)
		local result = {}; for _, row in ipairs(s.rows) do result[#result + 1] = row[1] .. ":" .. row[2] end
		return table.concat(result, ",")
	end
	local function consume(s)
		s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200); s.edge("a", 30, 2, 210); s.edge("a", 30, 0, 220)
	end
	helpers.it("permits a copy retry after a configured pair key is released", function()
		local names = { "adapters.clipboard", "core.events.timer_scheduler", "platform.system.notifier" }
		local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local timer
		package.loaded["adapters.clipboard"] = { change_counter = function() return 100 end }
		package.loaded["core.events.timer_scheduler"] = {
			after = function(_, callback) timer = callback; return { armed = true } end,
			cancel = function() return true end,
		}
		package.loaded["platform.system.notifier"] = { send = function() return true end }
		local ok, err = xpcall(function()
			Fixture.with_manager_session({ before_manager = function(s)
				s.bytes = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n'
			end, capture_copy_owner = function() return { current = function() return true end } end }, function(s)
				s.pair()
				helpers.assert_eq(#s.actions, 1)
				helpers.assert_eq(s.actions[1][1], "copy")
				helpers.assert_true(type(timer) == "function")
				timer()
				helpers.assert_eq(#s.actions, 2, "the unchanged pair still owns the retry after release")
			end)
			timer = nil
			Fixture.with_manager_session({ before_manager = function(s)
				s.bytes = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n'
			end, capture_copy_owner = function() return { current = function() return true end } end }, function(s)
				s.pair()
				helpers.assert_eq(#s.actions, 1)
				s.bytes = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "none"\n'
				timer()
				helpers.assert_eq(#s.actions, 1, "changed pair configuration cannot own the retry")
			end)
		end, debug.traceback)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end)

	for _, pair_mode in ipairs({ "configured", "none" }) do
		helpers.it("delivers both instant actions replayed by a rolled typing key: " .. pair_mode, function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
				.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
				.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
			local trace = {}
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
				clipboard = { change_counter = function() return nil, "unsupported" end },
				after_sync = function(_, code, value) trace[#trace + 1] = tostring(code) .. ":" .. tostring(value) end,
				on_generic_action = function(_, action) trace[#trace + 1] = action end,
				before_manager = function(s)
					if pair_mode == "none" then s.bytes = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "none"\n' end
				end }, function(s)
				if pair_mode == "none" then helpers.assert_eq(s.owner.has_bindings(), false) end
				s.edge("a", 57, 1, 1000)
				s.edge("a", 1, 1, 1010)
				s.edge("a", 111, 1, 1020)
				s.edge("a", 1, 0, 1030)
				s.edge("a", 111, 0, 1040)
				s.edge("a", 57, 0, 1050)
				helpers.assert_eq(#s.actions, 2)
				helpers.assert_eq(s.actions[1][1], "copy")
				helpers.assert_eq(s.actions[2][1], "paste")
				helpers.assert_eq(table.concat(trace, ","), "57:1,57:0,copy,paste", "rows and actions preserve event order")
				helpers.assert_eq(next(s.writer.output_view(s.output).down), nil, "no virtual key remains held")
			end)
		end)
	end

	for _, first in ipairs({ "a", "b" }) do
		helpers.it("keeps the surviving same-code roll hold when " .. first .. " releases first", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" } }, function(s)
				local last = first == "a" and "b" or "a"
				s.edge("a", 57, 1, 1000); s.edge("b", 57, 1, 1010)
				s.edge(first, 57, 0, 1020)
				s.edge(last, 30, 1, 1030); s.edge(last, 30, 0, 1040)
				s.edge(last, 57, 0, 1050)
				helpers.assert_eq(s.rows, { { 42, 1 }, { 30, 1 }, { 30, 0 }, { 42, 0 } },
					"the surviving physical Space must keep Shift and neither press may type a lone Space")
			end)
		end)
	end

	helpers.it("keeps the navigation layer active for the surviving same-code roll owner", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("b", 57, 1, 1010); s.edge("a", 57, 0, 1020)
			s.edge("b", 36, 1, 1030); s.edge("b", 36, 0, 1040); s.edge("b", 57, 0, 1050)
			local before = #s.rows
			helpers.assert_true(before > 0, "the layer action must be delivered")
			for _, row in ipairs(s.rows) do helpers.assert_true(row[1] ~= 57 and row[1] ~= 36) end
			s.edge("b", 36, 1, 1060); s.edge("b", 36, 0, 1070)
			helpers.assert_eq(s.rows[before + 1], { 36, 1 })
			helpers.assert_eq(s.rows[before + 2], { 36, 0 })
		end)
	end)

	helpers.it("retires both same-code roll owners if configuration changes after the first output", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
		local changed = false
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" },
			after_sync = function(s, code, value)
				if not changed and code == 42 and value == 1 then
					changed = true
					local file = assert(io.open(s.tap_path, "ab")); file:write("\n# changed after first output\n"); file:close()
				end
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("b", 57, 1, 1010)
			helpers.assert_true(changed)
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil, "the old output cannot retain Shift")
			for _, row in ipairs(s.rows) do helpers.assert_true(row[1] ~= 57, "no stale Space may be emitted") end
		end)
	end)

	helpers.it("retires the old roll journal when its second keyboard disappears after first output", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
		local removed = false
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" },
			after_sync = function(s, code, value)
				if not removed and code == 42 and value == 1 then
					removed = true
					s.reader.close("keyboard:" .. s.paths.b)
				end
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("b", 57, 1, 1010)
			helpers.assert_true(removed)
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil, "removed source cannot retain Shift")
			for _, row in ipairs(s.rows) do helpers.assert_true(row[1] ~= 57, "no stale Space may be emitted") end
		end)
	end)

	for _, lost in ipairs({ "a", "b" }) do
		helpers.it("retires both roll holds safely after source " .. lost .. " is lost", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			local options = { tap_hold_text = text, action_names = { "one_shot_shift" } }
			Fixture.with_manager_session(options, function(s)
				local survivor = lost == "a" and "b" or "a"
				s.edge("a", 57, 1, 1000); s.edge("b", 57, 1, 1010)
				options.eof_path = s.paths[lost]; s.hook.pump()
				helpers.assert_true(s.hook.isRunning())
				s.edge(survivor, 30, 1, 1030); s.edge(survivor, 30, 0, 1040)
				s.edge(survivor, 57, 0, 1050)
				helpers.assert_eq(s.rows, { { 42, 1 }, { 42, 0 }, { 30, 1 }, { 30, 0 } },
					"source loss retires the old remapper cohort without a stale Space")
			end)
		end)
	end

	helpers.it("does not deliver later roll effects after the first output acknowledgement fails", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
		local refused = false
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" },
			fail_sync = function(_, code, value)
				if not refused and code == 42 and value == 1 then refused = true; return true end
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("b", 57, 1, 1010)
			helpers.assert_true(refused)
			helpers.assert_eq(s.hook.isRunning(), false, "an unknown write cannot admit later effects")
			for _, row in ipairs(s.rows) do helpers.assert_true(row[1] ~= 57, "no stale Space may be emitted") end
		end)
	end)

	helpers.it("preserves a buffered key before joining a second same-code roll owner", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" } }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 30, 1, 1005); s.edge("b", 57, 1, 1010)
			s.edge("a", 57, 0, 1020); s.edge("a", 30, 0, 1030); s.edge("b", 57, 0, 1040)
			helpers.assert_eq(s.rows, { { 42, 1 }, { 30, 1 }, { 30, 0 }, { 42, 0 } })
		end)
	end)

	helpers.it("orders a buffered instant action before the second same-code roll receipt", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "paste"\n'
		local trace = {}
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "paste", "one_shot_shift" },
			after_sync = function(_, code, value) trace[#trace + 1] = code .. ":" .. value end,
			on_generic_action = function(_, action) trace[#trace + 1] = action end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1005); s.edge("b", 57, 1, 1010)
			s.edge("a", 57, 0, 1020); s.edge("a", 1, 0, 1030); s.edge("b", 57, 0, 1040)
			helpers.assert_eq(table.concat(trace, ","), "42:1,paste,42:0")
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
		end)
	end)

	for _, first in ipairs({ "a", "b" }) do
		helpers.it("keeps a shared navigation key down when " .. first .. " releases first", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true }, function(s)
				local last = first == "a" and "b" or "a"
				s.edge("a", 57, 1, 1000); s.pump_at(2000)
				s.edge("a", 36, 1, 2010); s.edge("b", 36, 1, 2020)
				s.edge(first, 36, 0, 2030); s.edge(last, 36, 2, 2040)
				s.edge("a", 57, 0, 2045); s.edge(last, 36, 0, 2050)
				helpers.assert_eq(s.rows, { { 29, 1 }, { 105, 1 }, { 105, 2 }, { 105, 0 }, { 29, 0 } },
					"the first release cannot lift the surviving source's navigation chord")
			end)
		end)
	end

	helpers.it("does not let another keyboard release a navigation chord it never acquired", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true }, function(s)
			s.edge("a", 57, 1, 1000); s.pump_at(2000); s.edge("a", 36, 1, 2010)
			s.edge("b", 36, 0, 2020); s.edge("a", 36, 2, 2030); s.edge("a", 36, 0, 2040)
			s.edge("a", 57, 0, 2050)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 105, 1 }, { 105, 2 }, { 105, 0 }, { 29, 0 } })
		end)
	end)

	for _, lost in ipairs({ "a", "b" }) do
		helpers.it("retires shared navigation output after loss of keyboard " .. lost, function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			local options = { tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true }
			Fixture.with_manager_session(options, function(s)
				s.edge("a", 57, 1, 1000); s.pump_at(2000)
				s.edge("a", 36, 1, 2010); s.edge("b", 36, 1, 2020)
				options.eof_path = s.paths[lost]; s.hook.pump()
				helpers.assert_true(s.hook.isRunning())
				helpers.assert_eq(s.rows, { { 29, 1 }, { 105, 1 }, { 105, 0 }, { 29, 0 } },
					"source loss retires the whole original remapper cohort")
				helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
			end)
		end)
	end

	helpers.it("stops the shared navigation chord when its repeated output is not acknowledged", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
		local refused = false
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true,
			fail_sync = function(_, code, value)
				if not refused and code == 105 and value == 2 then refused = true; return true end
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.pump_at(2000)
			s.edge("a", 36, 1, 2010); s.edge("b", 36, 1, 2020); s.edge("a", 36, 0, 2030)
			s.edge("b", 36, 2, 2040)
			helpers.assert_true(refused)
			helpers.assert_eq(s.hook.isRunning(), false, "uncertain repeat cannot retain a live capture")
			for _, row in ipairs(s.rows) do helpers.assert_true(row[1] ~= 36, "no source key is replayed") end
		end)
	end)

	helpers.it("counts an intermediate shared navigation release as activity for another tap-hold", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			.. '[tap_hold.keys.caps_lock]\ntap_action = "enter"\nhold_modifier = "ctrl"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true }, function(s)
			s.edge("a", 57, 1, 1000); s.pump_at(2000)
			s.edge("a", 36, 1, 2010); s.edge("b", 36, 1, 2020); s.edge("a", 57, 0, 2030)
			s.edge("a", 58, 1, 2040); s.edge("a", 36, 0, 2050); s.edge("a", 58, 0, 2060)
			s.edge("b", 36, 0, 2070)
			for _, row in ipairs(s.rows) do helpers.assert_true(row[1] ~= 28, "the other key's release cancels the Caps tap") end
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
		end)
	end)

	for _, first in ipairs({ "a", "b" }) do
		helpers.it("keeps each instant action source when " .. first .. " releases first", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.escape]\ntap_action = "paste"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "paste", "one_shot_shift" } }, function(s)
				local last = first == "a" and "b" or "a"
				s.edge("a", 1, 1, 1000); s.edge("b", 1, 1, 1010)
				s.edge(first, 1, 0, 1020); s.edge(last, 1, 2, 1030); s.edge(last, 1, 0, 1040)
				helpers.assert_eq(#s.actions, 3, "both physical presses and the surviving repeat must run")
			end)
		end)
	end

	for _, first in ipairs({ "a", "b" }) do
		helpers.it("keeps simultaneous instant pair-candidate actions when " .. first .. " releases first", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.caps_lock]\ntap_action = "paste"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "paste", "one_shot_shift" } }, function(s)
				local last = first == "a" and "b" or "a"
				s.edge("a", 58, 1, 1000); s.edge("b", 58, 1, 1010)
				s.edge(first, 58, 0, 1020); s.edge(last, 58, 2, 1030); s.edge(last, 58, 0, 1040)
				helpers.assert_eq(#s.actions, 3, "a combination candidate must keep each source's action and repeat")
			end)
		end)
	end

	helpers.it("keeps an instant key and another source's later navigation mapping independent", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			.. '[tap_hold.keys.caps_lock]\ntap_action = "paste"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "paste", "one_shot_shift" }, nav_fixture = true }, function(s)
			s.edge("a", 58, 1, 1000)
			s.edge("a", 57, 1, 1010); s.pump_at(2000)
			helpers.assert_true(s.engine.layer_depth > 0, "the layer must be active")
			s.edge("b", 58, 1, 2010); s.edge("a", 58, 0, 2020)
			s.edge("b", 58, 2, 2030); s.edge("b", 58, 0, 2040); s.edge("a", 57, 0, 2050)
			helpers.assert_eq(#s.actions, 1)
			helpers.assert_eq(s.rows, { { 14, 1 }, { 14, 2 }, { 14, 0 } },
				"releasing the instant source cannot lift the other source's layer chord")
		end)
	end)

	for _, lost in ipairs({ "a", "b" }) do
		helpers.it("does not revive an instant press after keyboard " .. lost .. " is lost", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.escape]\ntap_action = "paste"\n'
			local options = { tap_hold_text = text, action_names = { "paste", "one_shot_shift" } }
			Fixture.with_manager_session(options, function(s)
				local survivor = lost == "a" and "b" or "a"
				s.edge("a", 1, 1, 1000); s.edge("b", 1, 1, 1010)
				helpers.assert_eq(#s.actions, 2)
				options.eof_path = s.paths[lost]; s.hook.pump()
				s.edge(survivor, 1, 2, 1030); s.edge(survivor, 1, 0, 1040)
				helpers.assert_eq(#s.actions, 2, "old holds do not survive source retirement")
			end)
		end)
	end

	helpers.it("keeps both roll owners when the key is also a combination candidate", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.tab]\nhold_modifier = "shift"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" } }, function(s)
			helpers.assert_true(s.owner.has_bindings(), "the combination owner must be active")
			s.edge("a", 15, 1, 1000); s.edge("b", 15, 1, 1010)
			s.edge("a", 15, 0, 1020); s.edge("b", 30, 1, 1030); s.edge("b", 30, 0, 1040); s.edge("b", 15, 0, 1050)
			helpers.assert_eq(s.rows, { { 42, 1 }, { 30, 1 }, { 30, 0 }, { 42, 0 } })
		end)
	end)

	helpers.it("retires delegated pair-candidate roll after its second source disappears", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.tab]\nhold_modifier = "shift"\n'
		local removed = false
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" },
			after_sync = function(s, code, value)
				if not removed and code == 42 and value == 1 then
					removed = true; s.reader.close("keyboard:" .. s.paths.b)
				end
			end }, function(s)
			s.edge("a", 15, 1, 1000); s.edge("b", 15, 1, 1010)
			helpers.assert_true(removed)
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
			for _, row in ipairs(s.rows) do helpers.assert_true(row[1] ~= 15, "retired Tab cannot replay") end
		end)
	end)

	helpers.it("keeps an instant key independent of another source's native pass-through under a layer", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "paste"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "paste", "one_shot_shift" }, nav_fixture = true }, function(s)
			s.edge("a", 1, 1, 1000); s.edge("a", 57, 1, 1010); s.pump_at(2000)
			s.edge("b", 1, 1, 2010); s.edge("a", 1, 0, 2020)
			s.edge("b", 1, 2, 2030); s.edge("b", 1, 0, 2040); s.edge("a", 57, 0, 2050)
			helpers.assert_eq(#s.actions, 1)
			helpers.assert_eq(s.rows, { { 1, 1 }, { 1, 2 }, { 1, 0 } })
		end)
	end)

	for _, first in ipairs({ "a", "b" }) do
		helpers.it("keeps native layer-key repeats when " .. first .. " releases first", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
				.. '[tap_hold.keys.escape]\ntap_action = "paste"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "paste", "one_shot_shift" }, nav_fixture = true }, function(s)
				local last = first == "a" and "b" or "a"
				s.edge("a", 57, 1, 1000); s.pump_at(2000)
				s.edge("b", 1, 1, 2010); s.edge("a", 1, 1, 2020)
				s.edge(first, 1, 0, 2030); s.edge("a", 57, 0, 2035)
				s.edge(last, 1, 2, 2040); s.edge(last, 1, 0, 2050)
				helpers.assert_eq(s.rows, { { 1, 1 }, { 1, 2 }, { 1, 0 } })
				helpers.assert_eq(#s.actions, 0)
			end)
		end)
	end

	for _, lost in ipairs({ "a", "b" }) do
		helpers.it("keeps the surviving native key balanced after source " .. lost .. " disappears", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
				.. '[tap_hold.keys.escape]\ntap_action = "paste"\n'
			local options = { tap_hold_text = text, action_names = { "paste", "one_shot_shift" }, nav_fixture = true }
			Fixture.with_manager_session(options, function(s)
				local survivor = lost == "a" and "b" or "a"
				s.edge("a", 57, 1, 1000); s.pump_at(2000)
				s.edge("a", 1, 1, 2010); s.edge("b", 1, 1, 2020)
				options.eof_path = s.paths[lost]; s.hook.pump()
				helpers.assert_true(s.hook.isRunning())
				s.edge(survivor, 1, 0, 2040)
				helpers.assert_eq(s.rows, { { 1, 1 }, { 1, 0 } })
				helpers.assert_eq(#s.actions, 0)
			end)
		end)
	end

	helpers.it("keeps both native Tab sources while the combination owner is active", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			.. '[tap_hold.keys.tab]\ntap_action = "paste"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "paste", "one_shot_shift" }, nav_fixture = true }, function(s)
			helpers.assert_true(s.owner.has_bindings())
			s.edge("a", 57, 1, 1000); s.pump_at(2000)
			s.edge("a", 15, 1, 2010); s.edge("b", 15, 1, 2020)
			s.edge("a", 15, 0, 2030); s.edge("b", 15, 2, 2040); s.edge("b", 15, 0, 2050); s.edge("a", 57, 0, 2060)
			helpers.assert_eq(s.rows, { { 15, 1 }, { 15, 2 }, { 15, 0 } })
			helpers.assert_eq(#s.actions, 0)
		end)
	end)

	for _, first in ipairs({ "a", "b" }) do
		helpers.it("uses native input for a new source after the layer ends (" .. first .. " releases first)", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true }, function(s)
				local last = first == "a" and "b" or "a"
				s.edge("a", 57, 1, 1000); s.pump_at(2000)
				s.edge("a", 36, 1, 2010); s.edge("a", 57, 0, 2020); s.edge("b", 36, 1, 2030)
				s.edge(first, 36, 0, 2040)
				if last == "b" then s.edge("b", 36, 2, 2045) end
				s.edge(last, 36, 0, 2050)
				if first == "a" then
					helpers.assert_eq(s.rows, { { 29, 1 }, { 105, 1 }, { 36, 1 }, { 105, 0 }, { 29, 0 }, { 36, 2 }, { 36, 0 } })
				else
					helpers.assert_eq(s.rows, { { 29, 1 }, { 105, 1 }, { 36, 1 }, { 36, 0 }, { 105, 0 }, { 29, 0 } })
				end
			end)
		end)
	end

	for _, first in ipairs({ "a", "b" }) do
		helpers.it("uses each source's original action when the layer ends before the second DOWN (" .. first .. " first)", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
				.. '[tap_hold.keys.caps_lock]\ntap_action = "paste"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "paste", "one_shot_shift" }, nav_fixture = true }, function(s)
				local last = first == "a" and "b" or "a"
				s.edge("a", 57, 1, 1000); s.pump_at(2000); s.edge("a", 58, 1, 2010)
				s.edge("a", 57, 0, 2020); s.edge("b", 58, 1, 2030)
				s.edge(first, 58, 0, 2040); s.edge(last, 58, 0, 2050)
				helpers.assert_eq(s.rows, { { 14, 1 }, { 14, 0 } })
				helpers.assert_eq(#s.actions, 1, "B uses its instant action instead of A's old layer")
			end)
		end)
	end

	helpers.it("keeps a late tap-hold separate from the first source's old layer chord", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			.. '[tap_hold.keys.caps_lock]\ntap_action = "enter"\nhold_modifier = "ctrl"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true }, function(s)
			s.edge("a", 57, 1, 1000); s.pump_at(2000); s.edge("a", 58, 1, 2010)
			s.edge("a", 57, 0, 2020); s.edge("b", 58, 1, 2030)
			s.edge("a", 58, 0, 2040); s.edge("b", 58, 0, 2050)
			helpers.assert_eq(s.rows, { { 14, 1 }, { 29, 1 }, { 14, 0 }, { 29, 0 } })
		end)
	end)

	helpers.it("retires the old layer owner when a late native source has an unknown output receipt", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
		local refused = false
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" }, nav_fixture = true,
			fail_sync = function(_, code, value)
				if not refused and code == 36 and value == 1 then refused = true; return true end
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.pump_at(2000); s.edge("a", 36, 1, 2010)
			s.edge("a", 57, 0, 2020); s.edge("b", 36, 1, 2030)
			helpers.assert_true(refused)
			helpers.assert_eq(s.hook.isRunning(), false, "unknown output must stop the original capture")
			helpers.assert_eq(#s.actions, 0)
		end)
	end)

	helpers.it("retains two late native sources independently of an old layer chord", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
		Fixture.with_manager_session({ source_ids = { "a", "b", "c" }, tap_hold_text = text,
			action_names = { "one_shot_shift" }, nav_fixture = true }, function(s)
			s.edge("a", 57, 1, 1000); s.pump_at(2000); s.edge("a", 36, 1, 2010); s.edge("a", 57, 0, 2020)
			s.edge("b", 36, 1, 2030); s.edge("c", 36, 1, 2040); s.edge("b", 36, 0, 2050)
			s.edge("c", 36, 2, 2060); s.edge("c", 36, 0, 2070); s.edge("a", 36, 0, 2080)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 105, 1 }, { 36, 1 }, { 36, 2 }, { 36, 0 }, { 105, 0 }, { 29, 0 } })
		end)
	end)

	for _, first in ipairs({ "a", "b" }) do
		helpers.it("balances a late native source sharing its code with the old layer output (" .. first .. " first)", function()
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" },
				before_manager = function(s)
					local dir = assert(s.tap_path:match("^(.*)/[^/]+$"))
					local file = assert(io.open(dir .. "/layers.toml", "wb"))
					file:write('[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyJ" = "keystroke:KeyJ"\n'); file:close()
				end }, function(s)
				local last = first == "a" and "b" or "a"
				s.edge("a", 57, 1, 1000); s.pump_at(2000); s.edge("a", 36, 1, 2010); s.edge("a", 57, 0, 2020)
				helpers.assert_true(s.engine.layer_keys[36] ~= nil, "the first J must own a layer chord")
			s.edge("b", 36, 1, 2030); s.edge("b", 36, 2, 2035); s.edge(first, 36, 0, 2040); s.edge(last, 36, 0, 2050)
				helpers.assert_eq(s.rows, { { 36, 1 }, { 36, 2 }, { 36, 0 } }, "shared wire key must stay balanced")
				helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
			end)
		end)
	end

	helpers.it("keeps queued same-code roll replays bound to their own late native sources", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
		Fixture.with_manager_session({ source_ids = { "a", "b", "c" }, tap_hold_text = text,
			action_names = { "one_shot_shift" }, before_manager = function(s)
				local dir = assert(s.tap_path:match("^(.*)/[^/]+$"))
				local file = assert(io.open(dir .. "/layers.toml", "wb"))
				file:write('[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyJ" = "keystroke:KeyJ"\n'); file:close()
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.pump_at(2000); s.edge("a", 36, 1, 2010); s.edge("a", 57, 0, 2020)
			helpers.assert_true(s.engine.layer_keys[36] ~= nil)
			s.edge("b", 57, 1, 2030); helpers.assert_eq(s.engine.undecided, 57)
			s.edge("c", 36, 1, 2040); s.edge("b", 36, 1, 2050)
			s.edge("b", 57, 0, 2060); s.edge("c", 36, 0, 2070); s.edge("b", 36, 2, 2080); s.edge("b", 36, 0, 2090); s.edge("a", 36, 0, 2100)
			helpers.assert_eq(s.rows, { { 36, 1 }, { 57, 1 }, { 57, 0 }, { 36, 2 }, { 36, 0 } })
		end)
	end)

	helpers.it("delivers rolled actions from their separate physical keyboards", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end } }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("b", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			s.edge("b", 1, 0, 1030); s.edge("a", 111, 0, 1040); s.edge("a", 57, 0, 1050)
			helpers.assert_eq(#s.actions, 2)
			helpers.assert_eq(s.actions[1][2], "tap_hold__escape")
			helpers.assert_eq(s.actions[2][2], "tap_hold__delete")
		end)
	end)

	helpers.it("does not deliver a later roll action after the first retires its hook", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
				clipboard = { change_counter = function() return nil, "unsupported" end },
			on_generic_action = function(s) s.hook.stop() end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			helpers.assert_eq(#s.actions, 1)
			helpers.assert_eq(s.actions[1][1], "copy")
		end)
	end)

	for _, first in ipairs({ "copy", "paste" }) do
		helpers.it("stops a rolled sequence when its first " .. first .. " action explicitly refuses", function()
			local second = first == "copy" and "paste" or "copy"
			local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
				.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
				.. '[tap_hold.keys.escape]\ntap_action = "' .. first .. '"\n'
				.. '[tap_hold.keys.delete]\ntap_action = "' .. second .. '"\n'
			Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
				clipboard = { change_counter = function() return nil, "unsupported" end },
				on_generic_action = function() return false end }, function(s)
				s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
				helpers.assert_eq(#s.actions, 1, "the explicitly refused first action cannot authorize the second")
				helpers.assert_eq(s.actions[1][1], first)
				helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
			end)
		end)
	end

	helpers.it("continues a rolled sequence when the executor reports no result", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end },
			on_generic_action = function() return nil end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			helpers.assert_eq(#s.actions, 2, "nil acknowledges only that the action was attempted")
		end)
	end)

	helpers.it("stops a real rolled sequence when its first action explicitly refuses", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end },
			on_generic_action = function() return false end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			helpers.assert_eq(#s.actions, 1, "the refused first action cannot authorize the second")
			helpers.assert_eq(s.actions[1][1], "copy")
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil, "no virtual key remains held")
		end)
	end)

	helpers.it("stops a real rolled sequence when a non-copy first action refuses", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "paste"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "copy"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end },
			on_generic_action = function() return false end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			helpers.assert_eq(#s.actions, 1, "the refused first action cannot authorize the second")
			helpers.assert_eq(s.actions[1][1], "paste")
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil, "no virtual key remains held")
		end)
	end)


	helpers.it("refuses a reentrant reload without delivering a later roll action", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
		local reload_ok
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end },
			on_generic_action = function(s) reload_ok = s.manager.reload() end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			helpers.assert_eq(reload_ok, false, "reload during owned delivery must be refused")
			helpers.assert_eq(#s.actions, 1, "an interrupted journal cannot deliver its remaining action")
		end)
	end)

	helpers.it("does not run rolled actions after a key-output acknowledgement fails", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end },
			fail_sync = function(_, code, value) return code == 57 and value == 0 end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			helpers.assert_eq(#s.actions, 0, "no action follows an unacknowledged output")
		end)
	end)

	helpers.it("retires rolled output when its source changes between key emissions", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
		local changed = false
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end },
			after_sync = function(s, code, value)
				if not changed and code == 57 and value == 1 then
					changed = true; s.bytes = s.bytes .. "\n# source changed\n"
				end
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			helpers.assert_eq(changed, true)
			helpers.assert_eq(#s.actions, 0, "no action may follow source withdrawal")
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil, "the original virtual hold is retired")
		end)
	end)

	helpers.it("does not release a synthetic hold that its journal never published", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.left_ctrl]\ntap_action = "paste"\nhold_modifier = "ctrl"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end },
			on_generic_action = function(s)
				helpers.assert_eq(s.engine.key_refs[29], 1, "the future Ctrl hold was prepared by the engine")
				s.bytes = s.bytes .. "\n# source changed after copy\n"
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 29, 1, 1020)
			helpers.assert_eq(#s.actions, 1)
			for _, row in ipairs(s.rows) do
				helpers.assert_true(row[1] ~= 29, "an unpublished Ctrl must not be pressed or released")
			end
			helpers.assert_true(s.hook.isRunning(), "clean retirement keeps capture running")
		end)
	end)

	helpers.it("retires rolled output when the tap-hold file changes between emissions", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
			.. '[tap_hold.keys.delete]\ntap_action = "paste"\n'
		local changed = false
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "copy", "paste", "one_shot_shift" },
			clipboard = { change_counter = function() return nil, "unsupported" end },
			after_sync = function(s, code, value)
				if not changed and code == 57 and value == 1 then
					changed = true
					local file = assert(io.open(s.tap_path, "ab")); file:write("\n# tap source changed\n"); file:close()
				end
			end }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 1, 1, 1010); s.edge("a", 111, 1, 1020)
			helpers.assert_eq(changed, true)
			helpers.assert_eq(#s.actions, 0)
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
		end)
	end)

	helpers.it("preserves physical Shift custody through a roll timeout", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" } }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 42, 1, 1010)
			s.pump_at(1400)
			helpers.assert_true(s.hook.isRunning(), "the resolved roll must not stop capture")
			s.edge("a", 57, 0, 1410)
			helpers.assert_eq(s.writer.output_view(s.output).down, { 42 }, "physical Shift stays held after the roll key releases")
			s.edge("a", 42, 0, 1420)
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil, "Shift must be released")
		end)
	end)

	helpers.it("does not retain an invisible roll layer after source withdrawal", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_layer = "nav"\n'
		Fixture.with_manager_session({ tap_hold_text = text, nav_fixture = true, action_names = { "one_shot_shift" } }, function(s)
			s.edge("a", 57, 1, 1000)
			s.bytes = s.bytes .. "\n# source changed before timeout\n"
			s.pump_at(1400)
			local before = #s.rows
			s.edge("a", 36, 1, 1410); s.edge("a", 36, 0, 1420)
			helpers.assert_eq(s.rows[before + 1], { 36, 1 }, "the withdrawn layer cannot redirect J")
			helpers.assert_eq(s.rows[before + 2], { 36, 0 })
		end)
	end)

	helpers.it("does not reuse a cached roll proof after its source changes", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
		Fixture.with_manager_session({ tap_hold_text = text, action_names = { "one_shot_shift" } }, function(s)
			s.edge("a", 57, 1, 1000); s.edge("a", 30, 1, 1020)
			s.edge("a", 57, 0, 1040); s.edge("a", 30, 0, 1060)
			local before = #s.rows
			s.bytes = s.bytes .. "\n# source changed between rolls\n"
			s.edge("a", 57, 1, 2000)
			helpers.assert_eq(#s.rows, before + 1, "an unadmitted roll must pass through immediately")
			helpers.assert_eq(s.rows[#s.rows], { 57, 1 })
			s.edge("a", 57, 0, 2020)
		end)
	end)

	helpers.it("keeps a delayed roll action tied to its original keyboard", function()
		local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n'
			.. '[tap_hold.keys.space]\nhold_modifier = "shift"\n'
			.. '[tap_hold.keys.escape]\ntap_action = "copy"\n'
		local options = { tap_hold_text = text, action_names = { "copy", "one_shot_shift" },
			position_bits = true, on_capture_reacquired = function() return true end,
			clipboard = { change_counter = function() return nil, "unsupported" end } }
		Fixture.with_manager_session(options, function(s)
			s.edge("a", 57, 1, 1000); s.edge("b", 1, 1, 1010)
			s.pump_at(1400)
			helpers.assert_eq(#s.actions, 1, "the original held source may deliver after timeout")
			s.edge("b", 1, 0, 1410); s.edge("a", 57, 0, 1420)
		end)
		Fixture.with_manager_session(options, function(s)
			s.edge("a", 57, 1, 1000); s.edge("b", 1, 1, 1010)
			local original = assert(s.reader.capture_source_owner("keyboard:" .. s.paths.b))
			options.eof_path = s.paths.b; s.hook.pump(); options.eof_path = nil
			helpers.assert_eq(s.reader.source_owner_current(original), false)
			s.held[s.paths.b] = {}
			package.loaded["modules.hotstrings.device_finder"].find_devices = function() return { s.paths.a, s.paths.b }, {} end
			for _ = 1, s.hook.DEVICE_CHECK_TICKS do s.hook.check_device() end
			s.pump_at(1400)
			helpers.assert_eq(#s.actions, 0, "a reconnected source cannot revive the old DOWN")
		end)
	end)

	helpers.it("loads the saved action and arms through the actual Manager callback", function()
		Fixture.with_manager_session({}, function(s)
			helpers.assert_eq(s.owner.get_action("caps_lock_then_tab"), "one_shot_shift")
			s.pair(); helpers.assert_eq(s.arm_deadline(), 10 + require("core.timing.engine.timings").ms("tap_hold", "one_shot_shift_timeout_ms"))
			helpers.assert_eq(#s.actions, 0, "logical intent is never a generic action ACK")
			consume(s); helpers.assert_eq(rows(s), PREFIX .. ",42:1,30:1,30:2,30:0,42:0")
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
		end)
	end)
	helpers.it("refuses all-positive public ports replaced before Manager construction", function()
		local calls = 0
		Fixture.with_manager_session({ before_manager = function(s)
			for _, name in ipairs({ "capture_input_owner", "input_owner_current", "arm_one_shot" }) do
				s.hook[name] = function() calls = calls + 1; return name == "capture_input_owner" and {} or true end
			end
		end }, function(s)
			s.pair(); helpers.assert_nil(s.arm_deadline()); helpers.assert_eq(calls, 0)
			consume(s); helpers.assert_eq(rows(s), PREFIX .. ",30:1,30:2,30:0")
			helpers.assert_eq(#s.actions, 0)
		end)
	end)
	helpers.it("refuses public ports rebound after Manager construction without calling them", function()
		Fixture.with_manager_session({}, function(s)
			local calls = 0
			for _, name in ipairs({ "capture_input_owner", "input_owner_current", "arm_one_shot" }) do
				s.hook[name] = function() calls = calls + 1; return name == "capture_input_owner" and {} or true end
			end
			s.pair(); helpers.assert_nil(s.arm_deadline()); helpers.assert_eq(calls, 0)
			consume(s); helpers.assert_eq(rows(s), PREFIX .. ",30:1,30:2,30:0")
		end)
	end)
	helpers.it("refuses missing required public arm authority at the final frame join", function()
		local options = {}
		options.on_guard = function(s) if s.remove_arm then s.hook.arm_one_shot = nil; s.remove_arm = false end end
		Fixture.with_manager_session(options, function(s)
			s.remove_arm = true; s.pair(); helpers.assert_nil(s.arm_deadline()); helpers.assert_eq(#s.actions, 0)
			consume(s); helpers.assert_eq(rows(s), PREFIX .. ",30:1,30:2,30:0")
		end)
	end)
	helpers.it("does not arm when the original source changes during command admission", function()
		local options = {}
		options.on_guard = function(s)
			if s.change_command then s.bytes = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n'; s.change_command = false end
		end
		Fixture.with_manager_session(options, function(s)
			s.edge("a", 58, 1, 0); s.edge("a", 15, 1, 10); s.change_command = true; s.edge("a", 15, 0, 100)
			helpers.assert_nil(s.arm_deadline()); helpers.assert_eq(#s.actions, 0)
		end)
	end)
	helpers.it("withdraws an unspent arm before a foreign keyboard is forwarded", function()
		Fixture.with_manager_session({}, function(s)
			s.pair(); helpers.assert_true(type(s.arm_deadline()) == "number")
			s.edge("a", 58, 0, 150); s.edge("b", 30, 1, 200); s.edge("b", 30, 0, 210)
			helpers.assert_nil(s.arm_deadline()); helpers.assert_eq(rows(s), PREFIX .. ",30:1,30:0")
			helpers.assert_true(s.hook.isRunning()); helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
		end)
	end)
	helpers.it("retains the ordinary generic action route", function()
		Fixture.with_manager_session({}, function(s)
			s.bytes = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "copy"\n'
			helpers.assert_true(s.manager.reload()); s.engine = s.manager.configuration_snapshot().engine
			s.pair(); helpers.assert_eq(s.actions, { { "copy", "combination__caps_lock_then_tab" } })
			helpers.assert_nil(s.arm_deadline())
		end)
	end)
	helpers.it("keeps an action outside the catalogue unavailable", function()
		Fixture.with_manager_session({}, function(s)
			local valid = pcall(s.owner.configuration_candidate,
				{ shortcuts = { key_combination_taps = { caps_lock_then_tab = "not_a_catalogue_action" } } }, true)
			helpers.assert_eq(valid, false)
		end)
	end)
	-- The pair once handed CapsWord back to the hook as intent for the engine's
	-- own per-letter mode, which no setting could reach: the Windows trigger
	-- (LAlt then CapsLock) did nothing on Linux. It now toggles the shortcuts
	-- manager's session through the executor, like the tray row.
	helpers.it("(linux-caps-word-trigger) runs a CapsWord pair through the catalogue executor", function()
		Fixture.with_manager_session({ action_names = { "copy", "caps_word" } }, function(s)
			s.bytes = '[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "caps_word"\n'
			helpers.assert_true(s.manager.reload()); s.engine = s.manager.configuration_snapshot().engine
			s.pair()
			helpers.assert_eq(s.actions, { { "caps_word", "combination__caps_lock_then_tab" } })
			helpers.assert_nil(s.engine:input_arm_state(), "no per-letter engine mode is armed beside the session")
			helpers.assert_nil(s.arm_deadline())
		end)
	end)
	helpers.it("does not grant a lease outside the exact Manager action frame", function()
		Fixture.with_manager_session({}, function(s)
			helpers.assert_nil(s.hook.capture_input_owner()); helpers.assert_eq(s.hook.arm_one_shot({}), false)
			s.pair(); helpers.assert_nil(s.hook.capture_input_owner()); helpers.assert_eq(s.hook.arm_one_shot({}), false)
		end)
	end)
	helpers.it("settles original inverse ACK after consumed source descriptor replacement", function()
		local options = { recycle_descriptor = true }
		options.after_sync = function(s, code, value)
			if code == 42 and value == 1 and not s.reopened then
				s.reopened = true; local slot = "keyboard:" .. s.paths.a
				s.old_fd = s.descriptor("a"); s.reader.close(slot)
				helpers.assert_true(s.reader.open(s.paths.a, slot)); helpers.assert_true(s.reader.grab(slot))
				s.successor_source = s.reader.capture_source_owner(slot)
			end
		end
		Fixture.with_manager_session(options, function(s)
			s.pair(); s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200)
			helpers.assert_true(s.reopened); helpers.assert_eq(s.descriptor("a"), s.old_fd)
			helpers.assert_eq(s.hook.isRunning(), false); helpers.assert_eq(rows(s), PREFIX .. ",42:1,42:0")
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
			helpers.assert_true(s.hook.set_remapper(nil)); helpers.assert_true(s.reader.source_owner_current(s.successor_source))
		end)
	end)
	helpers.it("settles exact retired original output without borrowing its reopened successor", function()
		Fixture.with_manager_session({}, function(s)
			s.pair(); s.edge("a", 58, 0, 150)
			helpers.assert_true(s.writer.close_owned(s.output)); helpers.assert_true(s.writer.open()); s.successor = s.writer.capture_output()
			s.edge("a", 30, 1, 200)
			helpers.assert_eq(s.hook.isRunning(), false); helpers.assert_eq(rows(s), PREFIX)
			helpers.assert_true(s.hook.set_remapper(nil)); helpers.assert_true(s.writer.output_current(s.successor))
			helpers.assert_eq(next(s.writer.output_view(s.successor).down), nil)
		end)
	end)
	helpers.it("retires uncertain original inverse output instead of claiming healthy settlement", function()
		local options = { fail_sync = function(_, code, value) return code == 42 and value == 0 end }
		options.after_sync = function(s, code, value)
			if code == 42 and value == 1 and not s.reopened then
				s.reopened = true; local slot = "keyboard:" .. s.paths.a
				s.reader.close(slot); assert(s.reader.open(s.paths.a, slot)); assert(s.reader.grab(slot))
			end
		end
		Fixture.with_manager_session(options, function(s)
			s.pair(); s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200)
			helpers.assert_eq(s.hook.isRunning(), false); helpers.assert_nil(s.writer.output_view(s.output))
			helpers.assert_eq(s.output_destroys, 1); helpers.assert_eq(s.output_closes, 1)
			helpers.assert_true(s.hook.set_remapper(nil))
		end)
	end)
end)




helpers.describe("OneShot daemon Manager bootstrap", function()
	helpers.it("selects Hook at setup when keystats already constructed Manager before it", function()
		local file = assert(io.open("ergopti_hotstrings.lua", "r")); local daemon = file:read("*a"); file:close()
		local keystats_at = assert(daemon:find('require("modules.keystats.keystats")', 1, true))
		local hook_at = assert(daemon:find('require("platform.input.keyboard_hook")', 1, true))
		helpers.assert_true(keystats_at < hook_at, "actual daemon loads keystats before its Hook import")
		-- modules/keystats/keystats, selected by a declaration unique to it.
		local source = assert(helpers.read_driver_unit("local function new_live_tracker("))
		helpers.assert_true(source:find('require("platform.remap.tap_hold_manager")', 1, true) ~= nil,
			"actual keystats constructs Manager before daemon Hook setup")
		local options = {}
		options.before_manager = function(s)
			local hook = package.loaded["platform.input.keyboard_hook"]
			package.loaded["platform.input.keyboard_hook"] = nil
			local ok, manager = pcall(helpers.load_module, "platform.remap.tap_hold_manager")
			package.loaded["platform.input.keyboard_hook"] = hook
			if not ok then error(manager, 0) end
			options.cached_manager = manager
		end
		require("tests.support.input_owner_fixture").with_manager_session(options, function(s)
			helpers.assert_eq(s.manager, options.cached_manager, "setup must use the genuinely preloaded module")
			helpers.assert_eq(s.owner.get_action("caps_lock_then_tab"), "one_shot_shift")
			s.pair(); helpers.assert_true(type(s.arm_deadline()) == "number")
			s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200); s.edge("a", 30, 0, 210)
			local rows = {}; for _, row in ipairs(s.rows) do rows[#rows + 1] = row[1] .. ":" .. row[2] end
			helpers.assert_eq(table.concat(rows, ","), "29:1,29:0,29:1,29:0,42:1,30:1,30:0,42:0")
			helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
		end)
	end)
end)




helpers.describe("OneShot construction-original text source", function()
	for _, timing in ipairs({ "before_manager", "after_manager" }) do
		helpers.it("refuses a rebound text getter " .. timing .. " without changing raw input", function()
			local calls = 0
			local function replace(s) s.hook.key_text = function() calls = calls + 1; return "b" end end
			local options = {}
			if timing == "before_manager" then options.before_manager = replace end
			require("tests.support.input_owner_fixture").with_manager_session(options, function(s)
				require("adapters.keyboard_layout")._set_table_for_test({
					a = { keycode = 30, level = 1, mods = {} }, A = { keycode = 30, level = 2, mods = { "shift" } },
					b = { keycode = 48, level = 1, mods = {} }, B = { keycode = 48, level = 2, mods = { "shift" } },
				})
				if timing == "after_manager" then replace(s) end
				s.pair(); helpers.assert_nil(s.arm_deadline())
				s.edge("a", 58, 0, 150); s.edge("a", 30, 1, 200); s.edge("a", 30, 0, 220)
				local rows = {}; for _, row in ipairs(s.rows) do rows[#rows + 1] = row[1] .. ":" .. row[2] end
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(table.concat(rows, ","), "29:1,29:0,29:1,29:0,30:1,30:0")
				helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
				helpers.assert_true(s.hook.isRunning())
			end)
		end)
	end
end)


-- Cross-source choices use the layer and configuration at each physical DOWN.
do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('independent multi-source review', function()
  for _, first in ipairs({'a','b'}) do
    helpers.it('uses current instant config after native under layer: '..first, function()
      local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n' .. '[tap_hold.keys.space]\nhold_layer = "nav"\n' .. '[tap_hold.keys.escape]\ntap_action = "paste"\n'
      Fixture.with_manager_session({tap_hold_text=text, action_names={'paste','one_shot_shift'},nav_fixture=true},function(s)
        local last=first=='a' and 'b' or 'a'
        s.edge('a',57,1,1000); s.pump_at(2000)
        s.edge('a',1,1,2010); s.edge('a',57,0,2020)
        s.edge('b',1,1,2030)
        helpers.assert_eq(#s.actions,1,'B presses after layer ended and must execute paste')
        s.edge(first,1,0,2040); s.edge(last,1,0,2050)
        helpers.assert_eq(s.rows,{{1,1},{1,0}})
      end)
    end)
  end
end)
helpers.describe('independent reverse order review', function()
  for _, first in ipairs({'a', 'b'}) do
  helpers.it('selects layer for new source while another holds configured Ctrl: '..first,function()
    local text='[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.left_alt]\nhold_layer = "nav"\n[tap_hold.keys.caps_lock]\ntap_action = "enter"\nhold_modifier = "ctrl"\n'
    Fixture.with_manager_session({tap_hold_text=text,action_names={'one_shot_shift'},nav_fixture=true},function(s)
      s.edge('a',58,1,1000); s.pump_at(2000)
      s.edge('b',56,1,2010); s.pump_at(3000); helpers.assert_true(s.engine.layer_depth > 0, 'B LAlt has active navigation')
      s.edge('b',58,1,3010)
      if first == 'a' then s.edge('a',58,0,3020); s.edge('b',58,0,3030)
      else s.edge('b',58,0,3020); s.edge('a',58,0,3030) end
      s.edge('b',56,0,3040)
      local expected = first == 'a' and {{29,1},{14,1},{29,0},{14,0}} or {{29,1},{14,1},{14,0},{29,0}}
      helpers.assert_eq(s.rows, expected, 'each release follows its own source')
    end)
  end)
  end
end)

end

do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('native choice while another source holds a tap-hold', function()
  for _, first in ipairs({'a', 'b'}) do
  helpers.it('passes the unmapped key through the active layer: '..first, function()
    local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.left_alt]\nhold_layer = "nav"\n[tap_hold.keys.escape]\ntap_action = "paste"\nhold_modifier = "ctrl"\n'
    Fixture.with_manager_session({tap_hold_text=text, action_names={'paste','one_shot_shift'}, nav_fixture=true}, function(s)
      s.edge('a',1,1,1000); s.pump_at(2000)
      s.edge('b',56,1,2010); s.pump_at(3000)
      s.edge('b',1,1,3010)
      if first == 'a' then s.edge('a',1,0,3020); s.edge('b',1,0,3030)
      else s.edge('b',1,0,3020); s.edge('a',1,0,3030) end
      s.edge('b',56,0,3040)
      local expected = first == 'a' and {{29,1},{1,1},{29,0},{1,0}} or {{29,1},{1,1},{1,0},{29,0}}
      helpers.assert_eq(s.rows, expected)
    end)
  end)
  end
end)
end

do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('source-specific swallowed navigation key', function()
  helpers.it('does not repeat or tap a second left alt under the active layer', function()
    local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.left_alt]\ntap_action = "backspace"\nhold_layer = "nav"\n'
    Fixture.with_manager_session({tap_hold_text=text, action_names={'one_shot_shift'}, nav_fixture=true}, function(s)
      s.edge('a',56,1,1000); s.pump_at(2000)
      s.edge('b',56,1,2010); s.edge('b',56,2,2020); s.edge('b',56,0,2030)
      s.edge('a',56,0,2040)
      helpers.assert_eq(s.rows, {})
      helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
    end)
  end)
end)
end

do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('source-specific native to hold', function()
  for _, first in ipairs({'a', 'b'}) do
    helpers.it('preserves the later hold and earlier native key: '..first, function()
      local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.space]\nhold_layer = "nav"\n[tap_hold.keys.escape]\ntap_action = "paste"\nhold_modifier = "ctrl"\n'
      Fixture.with_manager_session({tap_hold_text=text,action_names={'paste','one_shot_shift'},nav_fixture=true},function(s)
        s.edge('a',57,1,1000); s.pump_at(2000)
        s.edge('a',1,1,2010); s.edge('a',57,0,2020)
        s.edge('b',1,1,2030)
        if first == 'a' then s.edge('a',1,0,2040); s.edge('b',1,0,2050)
        else s.edge('b',1,0,2040); s.edge('a',1,0,2050) end
        local expected = first == 'a' and {{1,1},{29,1},{1,0},{29,0}} or {{1,1},{29,1},{29,0},{1,0}}
        helpers.assert_eq(s.rows, expected)
        helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
      end)
    end)
  end
end)
end

do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('source choice output refusal', function()
  helpers.it('retires capture when the later native DOWN cannot be acknowledged', function()
    local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.left_alt]\nhold_layer = "nav"\n[tap_hold.keys.escape]\ntap_action = "paste"\nhold_modifier = "ctrl"\n'
    local refused = false
    Fixture.with_manager_session({tap_hold_text=text,action_names={'paste','one_shot_shift'},nav_fixture=true,
      fail_sync=function(_,code,value) if code == 1 and value == 1 and not refused then refused=true; return true end end}, function(s)
      s.edge('a',1,1,1000); s.pump_at(2000); s.edge('b',56,1,2010); s.pump_at(3000)
      s.edge('b',1,1,3010)
      helpers.assert_true(refused)
      helpers.assert_eq(s.hook.isRunning(), false)
      helpers.assert_eq(#s.actions, 0)
    end)
  end)
end)
end

do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('source choice on source loss', function()
  helpers.it('keeps the surviving hold until its own release after native source loss', function()
    local text = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.space]\nhold_layer = "nav"\n[tap_hold.keys.escape]\ntap_action = "paste"\nhold_modifier = "ctrl"\n'
    local options = {tap_hold_text=text,action_names={'paste','one_shot_shift'},nav_fixture=true}
    Fixture.with_manager_session(options, function(s)
      s.edge('a',57,1,1000); s.pump_at(2000); s.edge('a',1,1,2010); s.edge('a',57,0,2020)
      s.edge('b',1,1,2030)
      options.eof_path=s.paths.a; s.hook.pump(); options.eof_path=nil
      helpers.assert_eq(s.writer.output_view(s.output).down, {29})
      s.edge('b',1,0,2040)
      helpers.assert_eq(s.writer.output_view(s.output).down, {})
      helpers.assert_eq(#s.actions, 0)
    end)
  end)
end)
end

do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('plain combination candidate ownership', function()
  for _, code in ipairs({58,15}) do
  for _, first in ipairs({'a','b'}) do
    helpers.it('keeps the surviving native candidate and its repeat: '..code..' / '..first, function()
      Fixture.with_manager_session({tap_hold_text='[tap_hold]\nenabled = true\ninherit_defaults = false\n',action_names={'copy','one_shot_shift'}}, function(s)
        helpers.assert_true(s.owner.has_bindings())
        helpers.assert_eq(s.engine.by_code[code], nil)
        s.edge('a',code,1,1000); s.pump_at(2000)
        helpers.assert_eq(s.rows, {{code,1}})
        s.edge('b',code,1,2010); s.edge(first,code,0,2020)
        helpers.assert_eq(s.rows, {{code,1}})
        local last = first == 'a' and 'b' or 'a'
        s.edge(last,code,2,2030); s.edge(last,code,0,2040)
        helpers.assert_eq(s.rows, {{code,1},{code,2},{code,0}})
        helpers.assert_eq(#s.actions,0)
        helpers.assert_eq(next(s.writer.output_view(s.output).down),nil)
      end)
    end)
  end
  end
end)
end

do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('plain candidate repress with a peer still held', function()
  helpers.it('keeps each native reference and does not borrow the other keyboard', function()
    Fixture.with_manager_session({tap_hold_text='[tap_hold]\nenabled = true\ninherit_defaults = false\n',action_names={'copy','one_shot_shift'}}, function(s)
      s.edge('a',58,1,1000); s.pump_at(2000)
      s.edge('b',58,1,2010); s.edge('a',58,0,2020)
      s.edge('a',58,1,2030); helpers.assert_true(s.hook.isRunning(), 'after re-press')
      s.edge('a',15,1,2040); helpers.assert_true(s.hook.isRunning(), 'after Tab down')
      s.edge('a',15,0,2050); s.edge('a',58,0,2060); s.edge('b',58,0,2070)
      helpers.assert_eq(s.arm_deadline(), nil)
      helpers.assert_eq(s.rows, {{58,1},{15,1},{15,0},{58,0}})
      helpers.assert_eq(next(s.writer.output_view(s.output).down), nil)
    end)
  end)
end)
end

do
local helpers = require('tests.helpers')
local Fixture = require('tests.support.input_owner_fixture')
helpers.describe('repressed chord with a surviving peer', function()
  helpers.it('does not trigger a chord until the native peer releases', function()
    Fixture.with_manager_session({public_chords=true,tap_hold_text='[tap_hold]\nenabled = true\ninherit_defaults = false\n',action_names={'copy','one_shot_shift'},before_manager=function(s)
      s.bytes='[shortcuts.key_combination_taps]\ncaps_lock_then_tab = "none"\n[mod_combos]\nenabled = true\nsimultaneous_threshold_ms = 50\nsymmetric = true\n[mod_combos.config.tab_then_caps_lock]\ncombo = "copy"\n'
    end}, function(s)
      s.edge('a',58,1,1000); s.pump_at(2000); s.edge('b',58,1,2010); s.edge('a',58,0,2020)
      s.edge('a',58,1,2030); s.edge('a',15,1,2040); s.edge('a',15,0,2050); s.edge('a',58,0,2060)
      s.edge('b',58,2,2070); s.edge('b',58,0,2080)
      helpers.assert_eq(#s.actions,0)
      helpers.assert_eq(next(s.writer.output_view(s.output).down),nil)
    end)
  end)
end)
end
