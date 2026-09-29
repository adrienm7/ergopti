--- tests/unit/modules/llm/test_agent_settings.lua

--- ==============================================================================
--- MODULE: AI Agent Settings (macOS)
--- DESCRIPTION:
--- Follows the four settings of the agent (llm.agent_system1,
--- llm.agent_system2, llm.agent_mode, llm.agent_disabled_apps) through every
--- owner: config.toml load and save by the real preference owner, the boot
--- sync into the keymap bridge, and the bridge's runtime setters and getter
--- that the AI menu's transaction and scope reset use.
---
--- ROOT CAUSE ENCODED:
--- A manifest setting without a preference owner broke the whole AI menu (its
--- scope runtime asserts one for every [llm] path), and a setting that is
--- saved but never pushed to the runtime is a menu choice that does nothing.
--- ==============================================================================

local helpers = require("tests.helpers")
local codec = require("toml_codec")

local SOURCE = table.concat({
	"[llm]",
	'agent_system1 = "cerebras|llama-3.3-70b"',
	'agent_system2 = "local"',
	'agent_mode = "auto"',
	'agent_disabled_apps = [{ name = "Slack", bundleID = "com.tinyspeck.slackmacgap" }]',
	"",
}, "\n")

helpers.describe("AI agent settings (macOS)", function()
	helpers.it("loads each setting at its owner and saves it back unchanged", function()
		helpers.with_fresh_modules({ "infra.preferences", "adapters.file_system" }, function()
			local source = SOURCE
			package.loaded["adapters.file_system"] = {
				read_with_status = function() return source, "ok" end,
				write = function() error("unguarded publication") end,
				write_if_unchanged = function(_, content)
					source = content
					return true
				end,
			}
			local prefs = helpers.load_with_stubs("infra.preferences")
			for path, key in pairs({
				["llm.agent_system1"] = "llm_agent_system1", ["llm.agent_system2"] = "llm_agent_system2",
				["llm.agent_mode"] = "llm_agent_mode", ["llm.agent_disabled_apps"] = "llm_agent_disabled_apps",
			}) do
				helpers.assert_eq(prefs.flat_key_for(path), key, path .. " has an owner")
			end
			local state, status = prefs.load("/agent/config.toml")
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(state.llm_agent_system1, "cerebras|llama-3.3-70b")
			helpers.assert_eq(state.llm_agent_system2, "local")
			helpers.assert_eq(state.llm_agent_mode, "auto")
			helpers.assert_eq(state.llm_agent_disabled_apps[1].name, "Slack")

			state.llm_agent_mode = "action"
			helpers.assert_eq(prefs.save("/agent/config.toml", state, {}, {}), true)
			local saved = codec.decode(source)
			helpers.assert_eq(saved.llm.agent_system1, "cerebras|llama-3.3-70b")
			helpers.assert_eq(saved.llm.agent_system2, "local")
			helpers.assert_eq(saved.llm.agent_mode, "action", "a change is saved")
			helpers.assert_eq(saved.llm.agent_disabled_apps[1].bundleID, "com.tinyspeck.slackmacgap")
		end)
	end)

	helpers.it("pushes the loaded settings into the keymap bridge at boot", function()
		local menu_state = helpers.load_with_stubs("ui.menu.menu_state")
		local pushed = {}
		local keymap = setmetatable({
			set_llm_model = function() return true end,
			set_llm_enabled = function() return true end,
		}, { __index = function(_, name)
			if type(name) == "string" and name:find("^set_llm_agent_") then
				return function(value) pushed[name] = value; return true end
			end
			return nil
		end })
		local state = {
			hotstrings = {}, gesture_modes = {}, gesture_actions = {},
			llm_enabled = false, llm_model = "m",
			llm_agent_system1 = "cerebras", llm_agent_system2 = "local|qwen3:14b", llm_agent_mode = "auto",
			llm_agent_disabled_apps = { { name = "Slack" } },
		}
		local stub_editor = { set_trigger_char = function() end, set_default_section = function() end,
			set_close_on_add = function() end }
		menu_state.sync_state_to_modules(state, {}, false, { keymap = keymap, core_mods = {}, hotstring_editor = stub_editor })
		helpers.assert_eq(pushed.set_llm_agent_system1, "cerebras")
		helpers.assert_eq(pushed.set_llm_agent_system2, "local|qwen3:14b")
		helpers.assert_eq(pushed.set_llm_agent_mode, "auto")
		helpers.assert_eq(pushed.set_llm_agent_disabled_apps[1].name, "Slack")
	end)

	helpers.it("sets and reads each setting through the real keymap bridge, refusing invalid values", function()
		local keymap = helpers.load_with_stubs("modules.keymap")
		require("modules.llm.agent_runner").reset()
		local found, value = keymap.get_llm_runtime_setting("llm_agent_mode")
		helpers.assert_eq(found, true)
		helpers.assert_eq(value, "off", "the manifest default until set")
		helpers.assert_eq(keymap.set_llm_agent_mode("auto"), true)
		helpers.assert_eq(select(2, keymap.get_llm_runtime_setting("llm_agent_mode")), "auto")
		helpers.assert_eq(keymap.set_llm_agent_mode("sometimes"), false, "an unknown mode is refused")
		helpers.assert_eq(select(2, keymap.get_llm_runtime_setting("llm_agent_mode")), "auto")

		helpers.assert_eq(keymap.set_llm_agent_system1("cerebras|llama-3.3-70b"), true)
		helpers.assert_eq(select(2, keymap.get_llm_runtime_setting("llm_agent_system1")), "cerebras|llama-3.3-70b")
		helpers.assert_eq(keymap.set_llm_agent_system1("Not a backend"), false)
		helpers.assert_eq(keymap.set_llm_agent_system2(""), true, "empty is off")
		helpers.assert_eq(select(2, keymap.get_llm_runtime_setting("llm_agent_system2")), "")

		local apps = { { name = "Slack" } }
		helpers.assert_eq(keymap.set_llm_agent_disabled_apps(apps), true)
		apps[1].name = "changed"
		helpers.assert_eq(select(2, keymap.get_llm_runtime_setting("llm_agent_disabled_apps"))[1].name, "Slack",
			"the runtime keeps its own copy")
		helpers.assert_eq(keymap.set_llm_agent_disabled_apps("Slack"), false)
		helpers.assert_eq(select(1, keymap.get_llm_runtime_setting("llm_agent_unknown")), false)
		require("modules.llm.agent_runner").reset()
	end)
end)
