--- tests/support/platform/remap/generator/generator_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_generator
--- DESCRIPTION:
--- Prelude shared by the test_generator_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- Stub adapters.file_system so load_json_file never hits the real disk.
-- Tests that need a classified read to return data override _fs_data below.
local _fs_data = {}
package.loaded["adapters.file_system"] = {
	read = function(path) return _fs_data[path] end,
	read_with_status = function(path)
		local content = _fs_data[path]
		if content == nil then return nil, "absent" end
		return content, "ok"
	end,
	write = function(_path, _content) return true end,
}

-- Stub ui.menu.menu_paths (required at module load time to compute the
-- KE_PHYSICAL_KC_LOG constant — it must not hit the filesystem).
package.loaded["infra.config_paths"] = {
	get_config_dir = function() return "/tmp/ergopti_test" end,
}

-- Stub lib.keycodes with the minimal surface used by generator.lua.
package.loaded["infra.keycodes"] = {
	to_name              = function(code) return "key_" .. tostring(code) end,
	F13_KARABINER_RETURN   = 105,
	F14_KARABINER_BACKSPACE = 107,
	F15_KARABINER_ESCAPE   = 113,
	F20_LAYER_NAV_ENTERED  = 90,
	F19_LAYER_NAV_EXITED   = 80,
}

local Generator = helpers.load_with_stubs("platform.remap.generator")
local TEST_LEASE_TOKEN = "0123456789abcdef0123456789abcdef"
local raw_build_karabiner_json = Generator.build_karabiner_json
local raw_build_paused_script_control_rules = Generator.build_paused_script_control_rules

-- Existing snapshot cases focus on their own rule shapes. The dedicated
-- managed-lease suite tests the strict token boundary itself
Generator.build_karabiner_json = function(state, actions, keys, combos, non_canonical, shared_dir)
	return raw_build_karabiner_json(
		state,
		actions,
		keys,
		combos,
		non_canonical,
		shared_dir,
		TEST_LEASE_TOKEN
	)
end
Generator.build_paused_script_control_rules = function()
	return raw_build_paused_script_control_rules(TEST_LEASE_TOKEN)
end


-- ---------------------------------------------------------------------------
-- Minimal fixtures reused across tests.
-- ---------------------------------------------------------------------------

-- A none_action as generator.lua expects it internally; the generator falls
-- back to this when an action id is "none".
local NONE_ACTION = {
	id            = "none",
	label         = "Rien",
	karabiner_to  = {},
}

-- A simple cmd action used to exercise the tap/hold rule builder.
local CMD_ACTION = {
	id            = "cmd",
	label         = "⌘ Cmd",
	karabiner_to  = { { key_code = "left_command" } },
}

-- Minimal key definition (mirrors the shape in tap_hold_keys.json).
local RCMD_KEY_DEF = {
	id    = "right_command",
	label = "Right Command",
	from  = { key_code = "right_command" },
}

-- State table with every field build_karabiner_json reads.
local function make_state(overrides)
	local base = {
		tap_hold_config          = {},
		mod_combos_config        = {},
		tap_hold_timeout_ms      = 200,
		simultaneous_threshold_ms = 100,
		combo_symmetric          = false,
	}
	if overrides then
		for k, v in pairs(overrides) do base[k] = v end
	end
	return base
end

return {
	CMD_ACTION = CMD_ACTION,
	Generator = Generator,
	NONE_ACTION = NONE_ACTION,
	RCMD_KEY_DEF = RCMD_KEY_DEF,
	TEST_LEASE_TOKEN = TEST_LEASE_TOKEN,
	_fs_data = _fs_data,
	make_state = make_state,
	raw_build_karabiner_json = raw_build_karabiner_json,
	raw_build_paused_script_control_rules = raw_build_paused_script_control_rules,
}
