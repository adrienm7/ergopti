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
	function hook.set_remapper(engine, on_tap)
		hook.calls = hook.calls + 1
		hook.engine, hook.on_tap = engine, on_tap
	end
	return hook
end

local function write(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

--- A fresh manager on the shared defaults and a temporary user file.
local function manager(user_text)
	local Manager = helpers.load_module("platform.remap.tap_hold_manager")
	local user_path = os.tmpname()
	if user_text then write(user_path, user_text) else os.remove(user_path) end
	local hook, actions = fake_hook(), {}
	Manager.init({
		keyboard_hook = hook,
		execute_action = function(action, binding) actions[#actions + 1] = action .. "@" .. binding end,
		action_names = function() return { "open_url" } end,
		defaults_path = DEFAULTS,
		user_path = user_path,
	})
	return Manager, hook, actions, user_path
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
		helpers.assert_true(Manager.is_hold_option("layer", "nav"))
		helpers.assert_true(Manager.is_hold_option("modifier", "ctrl+shift"))
		helpers.assert_true(Manager.is_hold_option("none", ""))
		helpers.assert_true(not Manager.is_hold_option("layer", "sym"))
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
