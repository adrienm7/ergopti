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
