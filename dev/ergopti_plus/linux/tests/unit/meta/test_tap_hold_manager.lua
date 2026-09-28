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
		action_names = function() return { "open_url" } end,
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

	helpers.it("warns at configuration load about a tap it cannot run", function()
		local Manager, warnings, _, close, user_path = catalogue_manager(
			'[tap_hold.keys.caps_lock]\ntap_action = "microsoft_bold"\n'
				.. '[tap_hold.keys.left_ctrl]\ntap_action = "select_all"\n')
		local ok, err = pcall(function()
			helpers.assert_eq(#warnings, 1, "one warning, for the one tap Linux cannot run")
			helpers.assert_contains(warnings[1], "caps_lock")
			helpers.assert_contains(warnings[1], "microsoft_bold")
			write(user_path, '[tap_hold.keys.caps_lock]\ntap_action = "lookup"\n')
			helpers.assert_true(Manager.reload())
			helpers.assert_eq(#warnings, 2, "a reload is a configuration load too")
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
