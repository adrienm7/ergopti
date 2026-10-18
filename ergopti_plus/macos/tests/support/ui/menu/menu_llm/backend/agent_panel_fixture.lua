--- tests/support/ui/menu/menu_llm/backend/agent_panel_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_agent_panel
--- DESCRIPTION:
--- Prelude shared by the test_agent_panel_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"ui.menu.menu_llm.agent_panel", "modules.llm.agent_runner", "modules.llm.agent_connectors",
	"infra.dialog_util", "ui.tooltip", "infra.app_picker", "infra.manifest_menu", "modules.llm.api_remote",
	"infra.logger", "infra.locale", "modules.llm.api_ollama", "modules.llm.local_model_offer",
	"modules.llm.local_servers", "ui.menu.menu_llm.local_server_panel",
}

--- Builds the panel over a state and faked owners.
--- @param state table The menu state.
--- @param scenario function Receives (build, world).
local function with_panel(state, scenario, language)
	helpers.with_fresh_modules(OWNED, function()
		local world = { applied = {}, dialogs = {}, notices = {}, dialog_answer = { "OK", "" }, pickers = {},
			-- What the local server listed (nil: not yet), the listings and
			-- verifications asked for, the alerts and the downloads
			listed = nil, refreshes = 0, verifications = {}, alerts = {}, alert_answer = nil, installs = {},
			listing_done = nil, menu_updates = 0 }
		package.loaded["infra.dialog_util"] = {
			text_prompt = function(title, message, default, ok_label, cancel_label)
				world.dialogs[#world.dialogs + 1] = { title = title, message = message, default = default }
				return world.dialog_answer[1] == "OK" and ok_label or cancel_label, world.dialog_answer[2]
			end,
			block_alert = function(title, message, first, second)
				world.alerts[#world.alerts + 1] = { title = title, message = message, buttons = { first, second } }
				return world.alert_answer == "first" and first or second
			end,
		}
		package.loaded["modules.llm.api_ollama"] = {
			MODEL_MISSING = "model_missing",
			get_base_url = function() return "http://127.0.0.1:11470" end,
			capture_service_owner = function() return function() return true end end,
			local_model_installed = function(model)
				if world.listed == nil then return nil end
				return world.listed[model] == true
			end,
			refresh_local_models = function(on_done)
				world.refreshes = world.refreshes + 1
				world.listing_done = on_done
			end,
			verify_local_model = function(model, on_result)
				world.verifications[#world.verifications + 1] = { model = model, on_result = on_result }
			end,
			forget_local_models = function() end,
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
		Locale.set_locale(language or "en")
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
		require("modules.llm.local_model_offer").set_installer(function(model)
			world.installs[#world.installs + 1] = model
			return true
		end)
		local settings_mgr = {
			apply_setting_transaction = function(options)
				if world.refuse_write then return false end
				world.applied[#world.applied + 1] = options
				state[options.key] = options.value
				return true
			end,
		}
		local function build()
			return Panel.build({ state = state, settings_mgr = settings_mgr,
				update_menu = function() world.menu_updates = world.menu_updates + 1 end })
		end
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

--- Reads the independent three-mode menu matrix, never generated from the manifest.
local function mode_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/agent_mode_rows.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	local corpus, err = require("adapters.json_codec").decode(raw)
	helpers.assert_not_nil(corpus, tostring(err))
	helpers.assert_eq(#corpus.modes, 3)
	helpers.assert_eq(#corpus.states, 3)
	return corpus
end


local function system_model_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/agent_system_model.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("adapters.json_codec").decode(raw))
end

return {
	OWNED = OWNED,
	base_state = base_state,
	mode_corpus = mode_corpus,
	row_starting = row_starting,
	system_model_corpus = system_model_corpus,
	titles = titles,
	with_panel = with_panel,
}
