--- tests/support/keyboard/engine/tap_hold_manager_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_tap_hold_manager
--- DESCRIPTION:
--- Prelude shared by the test_tap_hold_manager_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEFAULTS = require("core.fs.engine.paths").shared("tap_hold/data/defaults.toml")

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

--- Writes a scenario's tap_hold.toml and the config.toml beside it (the switch
--- and the timings, tests/support/keyboard/tap_hold_fixture.lua).
local function write(path, text)
	require("tests.support.keyboard.tap_hold_fixture").write(path, text)
end

--- A fresh manager on the shared defaults and a temporary user file.
local function manager(user_text, opts)
	-- Earlier enrolled fixtures reload the shared Writer. A fresh Manager's
	-- original Nav issuer must capture that same current dependency graph.
	helpers.load_module("keyboard.engine.layers.nav_layer")
	local Manager = helpers.load_module("tap_hold.engine.manager")
	local user_path = os.tmpname()
	write(user_path, user_text)
	local hook, actions, resets = fake_hook(), {}, {}
	Manager.init({
		keyboard_hook = hook,
		capture_copy_owner = opts and opts.capture_copy_owner,
		execute_action = opts and opts.execute_action or function(action, binding) actions[#actions + 1] = action .. "@" .. binding end,
		action_names = require("gestures.engine.manager").get_executable_action_names,
		on_text_injected = function(text) resets[#resets + 1] = text end,
		defaults_path = DEFAULTS,
		user_path = user_path,
		config_path = require("tests.support.keyboard.tap_hold_fixture").config_path(user_path),
	})
	return Manager, hook, actions, user_path, resets
end

return {
	helpers = helpers,
	DEFAULTS = DEFAULTS,
	fake_hook = fake_hook,
	write = write,
	manager = manager,
}
