--- tests/unit/ui/menu/menu_llm/test_agent_panel.lua

--- ==============================================================================
--- MODULE: AI Agent Menu (macOS)
--- DESCRIPTION:
--- Builds the real top-level AI agent menu through the shared manifest
--- renderer and drives its rows: the mode, the backend and model of System 1
--- and System 2, and the excluded applications. The setting transaction, the
--- model dialog, the tooltip and the application picker are faked; labels are
--- read from the real English catalogue.
---
--- ROOT CAUSES ENCODED:
--- 1. The manifest's agent_menu places the rows; every dynamic row must have
---    its handler here, or it silently vanishes.
--- 2. The backend lists are the vision backends' (local, then every provider
---    in order), the current one checked, and the model row shows the model in
---    force and stores "<backend>" or "<backend>|<model>".
--- 3. The automatic mode needs System 1: the menu refuses it without one.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"ui.menu.menu_llm.agent_panel", "modules.llm.agent_runner", "modules.llm.agent_connectors",
	"infra.dialog_util", "ui.tooltip", "infra.app_picker", "infra.manifest_menu", "modules.llm.api_remote",
	"infra.logger", "infra.locale",
}

--- Builds the panel over a state and faked owners.
--- @param state table The menu state.
--- @param scenario function Receives (build, world).
local function with_panel(state, scenario)
	helpers.with_fresh_modules(OWNED, function()
		local world = { applied = {}, dialogs = {}, notices = {}, dialog_answer = { "OK", "" }, pickers = {} }
		package.loaded["infra.dialog_util"] = {
			text_prompt = function(title, message, default, ok_label, cancel_label)
				world.dialogs[#world.dialogs + 1] = { title = title, message = message, default = default }
				return world.dialog_answer[1] == "OK" and ok_label or cancel_label, world.dialog_answer[2]
			end,
		}
		package.loaded["ui.tooltip"] = {
			show = function(text) world.notices[#world.notices + 1] = text; return true end,
		}
		package.loaded["infra.app_picker"] = {
			build_menu = function(apps, on_change, placeholder)
				world.pickers[#world.pickers + 1] = { apps = apps, on_change = on_change, placeholder = placeholder }
				return { { label = "picker-row", action = function() end } }
			end,
		}
		package.loaded["modules.llm.agent_connectors"] = {
			list_tools = function(_, on_done) world.tool_lists = (world.tool_lists or 0) + 1; on_done({}) end,
		}
		local Panel = helpers.load_with_stubs("ui.menu.menu_llm.agent_panel")
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local i18n = require("infra.i18n")
		local Locale = require("infra.locale")
		local previous_locale = Locale.all()["_meta.locale"]
		Locale.set_locale("en")
		i18n.get = function(key)
			local text = Locale.get(key)
			if text == nil or text == "" then return key end
			return text
		end
		i18n.format = function(key, ...)
			local text = i18n.get(key)
			local args = table.pack(...)
			for n = 1, args.n do text = text:gsub("{" .. n .. "}", (tostring(args[n]):gsub("%%", "%%%%"))) end
			return text
		end
		world.i18n = i18n
		local settings_mgr = {
			apply_setting_transaction = function(options)
				world.applied[#world.applied + 1] = options
				state[options.key] = options.value
				return true
			end,
		}
		local function build() return Panel.build({ state = state, settings_mgr = settings_mgr }) end
		local ok, err = pcall(scenario, build, world)
		Locale.set_locale(previous_locale)
		if not ok then error(err, 0) end
	end)
end

--- Finds a rendered row by its title prefix.
--- @param rows table Rendered rows.
--- @param prefix string
--- @return table|nil row
local function row_starting(rows, prefix)
	for _, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return row end
	end
	return nil
end

--- The titles of rendered rows, separators as "-".
local function titles(rows)
	local out = {}
	for index, row in ipairs(rows) do out[index] = tostring(row.title) end
	return out
end

local function base_state()
	return { llm_agent_system1 = "", llm_agent_system2 = "cerebras", llm_agent_mode = "action", llm_agent_disabled_apps = {} }
end

helpers.describe("AI agent menu (macOS)", function()
	helpers.it("draws the manifest's rows: mode, System 1, System 2, excluded applications", function()
		with_panel(base_state(), function(build)
			local item = build()
			helpers.assert_eq(item.label, "🤖 AI agent")
			helpers.assert_eq(table.concat(titles(item.submenu), " | "), table.concat({
				"Mode: On action (gesture or shortcut)", "-",
				"⚡ System 1 (fast): Off", "🧠 System 2 (thorough): Cerebras", "-",
				"Apps excluded from the automatic mode (0)",
			}, " | "))
		end)
	end)

	helpers.it("lists off, the local server and every provider in order, the current one checked", function()
		with_panel(base_state(), function(build, world)
			local Remote = require("modules.llm.api_remote")
			local system2 = row_starting(build().submenu, "🧠")
			local expected = { "Off", "Local (Ollama)" }
			for _, id in ipairs(Remote.PROVIDER_ORDER) do expected[#expected + 1] = Remote.PROVIDERS[id].label end
			expected[#expected + 1] = "-"
			expected[#expected + 1] = "Model… (qwen-3.8-27b)"
			helpers.assert_eq(table.concat(titles(system2.menu), " | "), table.concat(expected, " | "))
			for _, row in ipairs(system2.menu) do
				helpers.assert_eq(row.checked == true, row.title == "Cerebras", "only the current backend is checked: " .. row.title)
			end

			-- Choosing a backend stores its id alone
			row_starting(system2.menu, "Local").fn()
			helpers.assert_eq(world.applied[1].key, "llm_agent_system2")
			helpers.assert_eq(world.applied[1].value, "local")
			helpers.assert_eq(world.applied[1].runtime_fn, "set_llm_agent_system2")
			local model_row = row_starting(row_starting(build().submenu, "🧠").menu, "Model…")
			helpers.assert_eq(model_row.title, "Model… (qwen2.5:7b)", "the local default model")
		end)
	end)

	helpers.it("asks for System 1's model and stores backend|model, empty for the default", function()
		local state = base_state()
		state.llm_agent_system1 = "cerebras"
		with_panel(state, function(build, world)
			local system1 = row_starting(build().submenu, "⚡")
			helpers.assert_eq(system1.title, "⚡ System 1 (fast): Cerebras")
			world.dialog_answer = { "OK", " llama-3.3-70b " }
			row_starting(system1.menu, "Model…").fn()
			helpers.assert_eq(world.dialogs[1].message, "Model name for Cerebras (empty for the default model):")
			helpers.assert_eq(world.applied[1].key, "llm_agent_system1")
			helpers.assert_eq(world.applied[1].value, "cerebras|llama-3.3-70b")
			system1 = row_starting(build().submenu, "⚡")
			helpers.assert_eq(row_starting(system1.menu, "Model…").title, "Model… (llama-3.3-70b)")
			helpers.assert_eq(row_starting(system1.menu, "Cerebras").checked, true, "the backend stays checked with a model")

			world.dialog_answer = { "OK", "" }
			row_starting(system1.menu, "Model…").fn()
			helpers.assert_eq(world.dialogs[2].default, "llama-3.3-70b", "the dialog shows the chosen model")
			helpers.assert_eq(world.applied[2].value, "cerebras", "empty returns to the default model")

			world.dialog_answer = { "Cancel", "ignored" }
			row_starting(row_starting(build().submenu, "⚡").menu, "Model…").fn()
			helpers.assert_eq(#world.applied, 2, "a cancelled dialog changes nothing")

			row_starting(row_starting(build().submenu, "⚡").menu, "Off").fn()
			helpers.assert_eq(world.applied[3].value, "", "off is the empty setting")
			local off_model = row_starting(row_starting(build().submenu, "⚡").menu, "Model…")
			helpers.assert_eq(off_model.disabled, true, "no model to choose while off")
		end)
	end)

	helpers.it("switches the mode, refusing the automatic mode without System 1", function()
		with_panel(base_state(), function(build, world)
			local mode = build().submenu[1]
			helpers.assert_eq(table.concat(titles(mode.menu), " | "),
				"Off | On action (gesture or shortcut) | Automatic (while typing)")
			helpers.assert_eq(mode.menu[2].checked, true)
			mode.menu[3].fn()
			helpers.assert_eq(#world.applied, 0, "refused without System 1")
			helpers.assert_eq(world.notices[1], world.i18n.get("llm.agent.no_system1"))
			mode.menu[1].fn()
			helpers.assert_eq(world.applied[1].key, "llm_agent_mode")
			helpers.assert_eq(world.applied[1].value, "off")
			helpers.assert_eq(world.applied[1].runtime_fn, "set_llm_agent_mode")
		end)
	end)

	helpers.it("edits the excluded applications through the application picker", function()
		local state = base_state()
		state.llm_agent_disabled_apps = { { name = "Slack", bundleID = "com.tinyspeck.slackmacgap" } }
		with_panel(state, function(build, world)
			local row = build().submenu[#build().submenu]
			helpers.assert_eq(row.title, "Apps excluded from the automatic mode (1)")
			helpers.assert_eq(row.menu[1].title, "picker-row")
			local picker = world.pickers[#world.pickers]
			helpers.assert_eq(picker.apps[1].name, "Slack")
			picker.on_change({})
			helpers.assert_eq(world.applied[1].key, "llm_agent_disabled_apps")
			helpers.assert_eq(world.applied[1].runtime_fn, "set_llm_agent_disabled_apps")
			helpers.assert_eq(#world.applied[1].value, 0)
			helpers.assert_true((world.tool_lists or 0) >= 1, "opening the menu refreshes the Shortcuts list")
		end)
	end)
end)
