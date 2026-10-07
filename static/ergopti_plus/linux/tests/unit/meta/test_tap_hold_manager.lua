--- tests/unit/meta/test_tap_hold_manager.lua

--- ==============================================================================
--- MODULE: Tap-Hold Manager Lifecycle
--- DESCRIPTION:
--- The feature switch, the file's own switch and the pause decide together
--- whether the engine is in the keyboard hook, and a change from the tray is
--- applied live by reload(). A tap action reaches the catalogue executor.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")

--- A keyboard hook double that records what is installed.
local function fake_hook()
	local hook = { engine = nil, on_tap = nil, calls = 0 }
	function hook.key_text() return nil end
	function hook.held_modifiers() return hook.mods or {} end
	function hook.held_text_modifier_codes() return hook.text_mods or {} end
	function hook.held_shortcut_modifier_codes() return hook.shortcut_mods or {} end
	function hook.set_remapper(engine, on_tap)
		hook.calls = hook.calls + 1
		hook.engine, hook.on_tap = engine, on_tap
	end
	return hook
end

local function write(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(require("tests.support.tap_hold_fixture").with_preset(text))
	fh:close()
end

--- A fresh manager on the shared defaults and a temporary user file.
local function manager(user_text)
	local Manager = helpers.load_module("platform.remap.tap_hold_manager")
	local user_path = os.tmpname()
	write(user_path, user_text)
	local hook, actions, resets = fake_hook(), {}, {}
	Manager.init({
		keyboard_hook = hook,
		execute_action = function(action, binding) actions[#actions + 1] = action .. "@" .. binding end,
		action_names = require("modules.gestures.manager").get_executable_action_names,
		on_text_injected = function(text) resets[#resets + 1] = text end,
		defaults_path = DEFAULTS,
		user_path = user_path,
	})
	return Manager, hook, actions, user_path, resets
end

helpers.describe("tap-hold manager", function()

	helpers.it("installs the engine at init and runs its tap actions", function()
		local Manager, hook, actions, user_path = manager()
		helpers.assert_true(hook.engine ~= nil, "engine in the hook")
		helpers.assert_true(hook.engine:handles(42), "left Shift is configured by default")
		hook.on_tap("copy")
		helpers.assert_eq(actions[1], "copy@tap_hold")
		Manager._reset_for_test()
		os.remove(user_path)
	end)

	helpers.it("transports the actual monitor tap binding through release and queued rollover", function()
		local Manager, hook, actions, user_path = manager()
		local Engine = require("platform.remap.tap_hold_engine")
		local code = Engine.KEY_CODES.tab
		local saved_hook, native_hook = package.loaded["adapters.keyboard_hook"], nil
		local ok, failure = pcall(function()
			hook.engine:process(code, 1, 0)
			local _, tap, binding = hook.engine:process(code, 0, 100)
			helpers.assert_eq(tap, "alt_tab_monitor")
			helpers.assert_eq(binding, "tap_hold__tab", "the shared key id survives to the native owner")
			hook.on_tap(tap, binding)
			helpers.assert_eq(actions[1], "alt_tab_monitor@tap_hold__tab")
			native_hook = helpers.load_module("adapters.keyboard_hook")
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
			}, roll_keys = { "space" }, tap_min_ms = 50, one_shot_timeout_ms = 2000 })
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
		package.loaded["adapters.keyboard_hook"] = saved_hook
		Manager._reset_for_test()
		os.remove(user_path)
		assert(ok, failure)
	end)

	helpers.it("admits a monitor tap only from its active canonical tap-hold source", function()
		local names = { "modules.gestures.manager", "platform.remap.tap_hold_manager", "adapters.window_switch",
			"adapters.keyboard_hook", "adapters.file_system", "infra.config_paths", "adapters.storage", "ui.gesture_conflicts" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local user_path, config_path = os.tmpname(), os.tmpname()
		write(user_path)
		local file = assert(io.open(config_path, "w")); file:write("[gesture_parameters]\nprivate = 'unchanged'\n"); file:close()
		local Manager, generation, capture, accepted, on_read = nil, 1, nil, 0, nil
		local ok, failure = pcall(function()
			package.loaded["adapters.keyboard_hook"] = { physical_source_receipt = function()
				return { ready = true, generation = generation }
			end }
			package.loaded["adapters.file_system"] = { read_with_status = function(path)
				if on_read and path == user_path then local callback = on_read; on_read = nil; callback() end
				local stream = io.open(path, "rb")
				if not stream then return nil, "absent" end
				local text = stream:read("*a"); stream:close(); return text, "ok"
			end }
			package.loaded["infra.config_paths"] = { config = function() return config_path end }
			package.loaded["adapters.storage"] = { get = function(_, default) return default end }
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
				defaults_path = DEFAULTS, user_path = user_path })
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

	-- The engine gets the one-shot results of _shared/tap_hold/one_shot_shift.json
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
		local saved = {}
		for _, name in ipairs({ "modules.hotstrings.magic_key", "modules.hotstrings.injector" }) do
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
		for name, module in pairs(saved) do package.loaded[name] = module end
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

	helpers.it("applies a changed file live on reload", function()
		local Manager, hook, _, user_path = manager()
		write(user_path, '[tap_hold.keys.caps_lock]\nenabled = false\n')
		helpers.assert_true(Manager.reload())
		helpers.assert_true(not hook.engine:handles(58), "CapsLock is itself again")
		write(user_path, '[tap_hold]\nenabled = false\n')
		Manager.reload()
		helpers.assert_nil(hook.engine, "the file's own switch turns it off")
		helpers.assert_true(not Manager.file_enabled())
		Manager._reset_for_test()
		os.remove(user_path)
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
		helpers.assert_nil(Manager.threshold_ms(), "the defaults mix 0.35 s and 0.2 s")
		Manager._reset_for_test()
		os.remove(user_path)
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
		local Logger = require("logger.shim")
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
		helpers.assert_true(reset:find("engine:reset()", 1, true) ~= nil and reset:find("_undoable = nil", 1, true) ~= nil,
			"it must drop the hotstring buffer and the undoable expansion")
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
	helpers.it("loads the saved action and arms through the actual Manager callback", function()
		Fixture.with_manager_session({}, function(s)
			helpers.assert_eq(s.owner.get_action("caps_lock_then_tab"), "one_shot_shift")
			s.pair(); helpers.assert_eq(s.arm_deadline(), 10 + require("infra.timings").ms("tap_hold", "one_shot_shift_timeout_ms"))
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
	helpers.it("keeps unknown actions and unwired CapsWord unavailable", function()
		Fixture.with_manager_session({}, function(s)
			for _, action in ipairs({ "caps_word", "not_a_catalogue_action" }) do
				local valid = pcall(s.owner.configuration_candidate, { shortcuts = { key_combination_taps = { caps_lock_then_tab = action } } }, true)
				helpers.assert_eq(valid, false)
			end
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
	helpers.it("selects Hook at setup when keylogger already constructed Manager before it", function()
		local file = assert(io.open("ergopti_hotstrings.lua", "r")); local daemon = file:read("*a"); file:close()
		local keylogger_at = assert(daemon:find('require("modules.keylogger.keylogger")', 1, true))
		local hook_at = assert(daemon:find('require("adapters.keyboard_hook")', 1, true))
		helpers.assert_true(keylogger_at < hook_at, "actual daemon loads keylogger before its Hook import")
		file = assert(io.open("modules/keylogger/keylogger.lua", "r")); local source = file:read("*a"); file:close()
		helpers.assert_true(source:find('require("platform.remap.tap_hold_manager")', 1, true) ~= nil,
			"actual keylogger constructs Manager before daemon Hook setup")
		local options = {}
		options.before_manager = function(s)
			local hook = package.loaded["adapters.keyboard_hook"]
			package.loaded["adapters.keyboard_hook"] = nil
			local ok, manager = pcall(helpers.load_module, "platform.remap.tap_hold_manager")
			package.loaded["adapters.keyboard_hook"] = hook
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
