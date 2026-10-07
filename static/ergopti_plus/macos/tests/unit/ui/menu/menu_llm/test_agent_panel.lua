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
--- 4. A local model nobody pulled must be visible and downloadable from the
---    menu, and choosing the local backend offers its download at once
---    (ai-agent-local-model).
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

helpers.describe("AI agent menu (macOS)", function()
	for _, vector in ipairs(mode_corpus().states) do
		helpers.it("replays the independent mode menu matrix for " .. vector.selected, function()
			local state = base_state()
			state.llm_agent_mode = vector.selected
			state.llm_agent_system1 = "cerebras"
			with_panel(state, function(build, world)
				local row = build().submenu[1]
				local corpus = mode_corpus()
				helpers.assert_eq(row.disabled == true, false, "a live durable owner keeps the actual mode row available")
				helpers.assert_eq(#row.menu, 3)
				for index, expected in ipairs(corpus.modes) do
					local actual = row.menu[index]
					helpers.assert_eq(actual.title, world.i18n.get(expected.label_key))
					helpers.assert_eq(actual.checked == true, vector.checked[index])
					if expected.value == vector.selected then
						helpers.assert_eq(row.title, world.i18n.format("menu.agent.mode_title", actual.title))
					end
				end
			end)
		end)
	end

	helpers.it("uses reordered shared choices and preserves the durable owner's refusal", function()
		with_panel(base_state(), function(build, world)
			local manifest = require("infra.manifest_menu").get_root()
			local mode = manifest.agent_menu[1]
			local previous = mode.choices
			local corpus = mode_corpus()
			local keys = {}
			for _, expected in ipairs(corpus.modes) do keys[expected.value] = expected.label_key end
			mode.choices = {}
			for _, value in ipairs(corpus.reordered_values) do
				mode.choices[#mode.choices + 1] = { value = value, i18n = keys[value] }
			end
			local ok, err = pcall(function()
				local row = build().submenu[1]
				for index, value in ipairs(corpus.reordered_values) do
					helpers.assert_eq(row.menu[index].title, world.i18n.get(keys[value]), "the declaration owns every choice")
				end
				world.refuse_write = true
				helpers.assert_eq(row.menu[2].fn(), false, "the actual setting transaction refuses")
				helpers.assert_eq(#world.applied, 0, "nothing is published")
				helpers.assert_eq(build().submenu[1].title, "Mode: On action (gesture or shortcut)")
				helpers.assert_eq(world.menu_updates, 0, "no successful redraw is claimed")
			end)
			mode.choices = previous
			if not ok then error(err, 0) end
		end)
	end)

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

	helpers.it("lists off, the local server and every chat provider in order, the current one checked", function()
		with_panel(base_state(), function(build, world)
			local Remote = require("modules.llm.api_remote")
			local system2 = row_starting(build().submenu, "🧠")
			local expected = { "Off", "Local (Ollama)" }
			for _, id in ipairs(Remote.PROVIDER_ORDER) do
				-- A decisions provider (Jev) is not a chat model: System 1 only
				if Remote.PROVIDERS[id].format ~= "decisions" then
					expected[#expected + 1] = Remote.PROVIDERS[id].label
				end
			end
			helpers.assert_true(#expected < #Remote.PROVIDER_ORDER + 2, "the catalogue holds a decisions provider")
			expected[#expected + 1] = "-"
			expected[#expected + 1] = "Model… (qwen-3.8-27b)"
			helpers.assert_eq(table.concat(titles(system2.menu), " | "), table.concat(expected, " | "))
			for _, label in ipairs({ "Groq", "OpenRouter", "Together AI", "Fireworks AI", "Backboard" }) do
				helpers.assert_true(row_starting(system2.menu, label) ~= nil, label .. " is a System 2 choice")
			end

			-- System 1 lists every provider, the decisions ones included
			local system1 = row_starting(build().submenu, "⚡")
			local expected1 = { "Off", "Local (Ollama)" }
			for _, id in ipairs(Remote.PROVIDER_ORDER) do expected1[#expected1 + 1] = Remote.PROVIDERS[id].label end
			expected1[#expected1 + 1] = "-"
			expected1[#expected1 + 1] = "Model… (Off)"
			helpers.assert_eq(table.concat(titles(system1.menu), " | "), table.concat(expected1, " | "))
			helpers.assert_true(row_starting(system1.menu, "TypeSafe (Jev)") ~= nil, "Jev is a System 1 choice")
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

	helpers.it("lists an answering local server with its models, stored as server|model (local-openai-backends)",
		function()
			local state = base_state()
			state.llm_agent_system2 = "lmstudio|gone-model"
			with_panel(state, function(build, world)
				local LocalServers = require("modules.llm.local_servers")
				local system2 = row_starting(build().submenu, "🧠")
				helpers.assert_eq(system2.title, "🧠 System 2 (thorough): LM Studio 🖥️",
					"a chosen server that does not answer keeps its name")
				local row = row_starting(system2.menu, "LM Studio")
				helpers.assert_eq(row.checked, true, "and stays checked")
				helpers.assert_eq(row.menu[1].title, "gone-model")

				LocalServers.sweep({ { id = "lmstudio", base_url = "http://localhost:1234/v1" } }, function(_, settle)
					settle({ ok = true, status = 200, body = '{"data":[{"id":"qwen2.5-7b-instruct"}]}' })
					return true
				end)
				system2 = row_starting(build().submenu, "🧠")
				row = row_starting(system2.menu, "LM Studio")
				helpers.assert_eq(titles(system2.menu)[3], "LM Studio 🖥️", "after the local server, before the providers")
				helpers.assert_eq(table.concat(titles(row.menu), " | "), "qwen2.5-7b-instruct | gone-model")
				row.menu[1].fn()
				helpers.assert_eq(world.applied[1].key, "llm_agent_system2")
				helpers.assert_eq(world.applied[1].value, "lmstudio|qwen2.5-7b-instruct")
				local system1 = row_starting(build().submenu, "⚡")
				helpers.assert_true(row_starting(system1.menu, "LM Studio") ~= nil, "System 1 offers it too")
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
	helpers.it("(ai-agent-local-model) shows whether the local model is installed and downloads a missing one", function()
		local state = base_state()
		state.llm_agent_system2 = "local"
		with_panel(state, function(build, world)
			local function system2_rows() return row_starting(build().submenu, "🧠").menu end
			-- Unknown until the local server listed its models: the menu asks for a listing
			helpers.assert_eq(row_starting(system2_rows(), "Model…").title, "Model… (qwen2.5:7b)")
			helpers.assert_true(world.refreshes >= 1, "the menu asks the local server for its models")
			-- The listing redraws the (cached) menu only when it changes a row:
			-- a redraw per listing would rebuild in a loop
			world.listed = { ["qwen2.5:7b"] = true }
			world.listing_done(true)
			helpers.assert_eq(world.menu_updates, 1, "the new install state is drawn")
			local rows = system2_rows()
			world.listing_done(true)
			helpers.assert_eq(world.menu_updates, 1, "an unchanged listing redraws nothing")
			helpers.assert_eq(row_starting(rows, "Model…").title, "Model… (qwen2.5:7b, installed)")
			helpers.assert_eq(row_starting(rows, "⬇️"), nil, "nothing to download")

			world.listed = { ["llama3.2:3b"] = true }
			rows = system2_rows()
			helpers.assert_eq(row_starting(rows, "Model…").title, "Model… (qwen2.5:7b, not installed)")
			local download = row_starting(rows, "⬇️")
			helpers.assert_eq(download.title, "⬇️ Download qwen2.5:7b")
			download.fn()
			helpers.assert_eq(world.installs[1], "qwen2.5:7b", "the row hands the model to the download owner")

			-- Choosing the local backend asks the server at once, and offers a missing model
			row_starting(row_starting(build().submenu, "⚡").menu, "Local").fn()
			helpers.assert_eq(state.llm_agent_system1, "local")
			local verification = world.verifications[#world.verifications]
			helpers.assert_eq(verification.model, "qwen2.5:7b")
			world.alert_answer = "first"
			verification.on_result(false)
			helpers.assert_eq(#world.alerts, 1)
			helpers.assert_eq(world.alerts[1].title, "AI model not installed")
			helpers.assert_eq(world.alerts[1].message, "The model “qwen2.5:7b” is not installed on this computer, "
				.. "so the local server (Ollama) cannot answer with it. Download it now?")
			helpers.assert_eq(world.alerts[1].buttons[1], "Download")
			helpers.assert_eq(world.installs[2], "qwen2.5:7b", "its Download button pulls it")
			verification.on_result(true)
			helpers.assert_eq(#world.alerts, 1, "an installed model asks nothing")

			-- Naming another local model verifies that one
			world.dialog_answer = { "OK", "qwen3:14b" }
			row_starting(system2_rows(), "Model…").fn()
			helpers.assert_eq(world.verifications[#world.verifications].model, "qwen3:14b")

			-- A remote System shows no install state and verifies nothing
			local count = #world.verifications
			row_starting(system2_rows(), "Cerebras").fn()
			helpers.assert_eq(#world.verifications, count)
			helpers.assert_eq(row_starting(system2_rows(), "Model…").title, "Model… (qwen-3.8-27b)")
		end)
	end)
end)


--- Loads the independently authored system Off menu states.
local function system_off_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/agent_system_off.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("adapters.json_codec").decode(raw))
end

helpers.describe("AI agent shared system Off row (agent-system-off)", function()
	for _, vector in ipairs(system_off_corpus().states) do
		helpers.it("uses the independent system checks for " .. vector.spec .. " (agent-system-off)", function()
			local state = base_state()
			state.llm_agent_system1, state.llm_agent_system2 = vector.spec, vector.spec
			with_panel(state, function(build, world)
				local rows = build().submenu
				for index in ipairs(system_off_corpus().systems) do
					local off = rows[index + 2].menu[1]
					helpers.assert_eq(off.title, world.i18n.get(system_off_corpus().label_key))
					helpers.assert_eq(off.checked == true, vector.checked)
					helpers.assert_eq(type(off.fn), "function")
				end
			end)
		end)
	end

	helpers.it("uses the shared label and refuses the actual owner before mutating either system (agent-system-off)", function()
		local state = base_state()
		state.llm_agent_system1 = "cerebras"
		with_panel(state, function(build, world)
			local declaration = require("infra.manifest_menu").get_root().agent_system_controls[1]
			local label = declaration.i18n
			declaration.i18n = system_off_corpus().mutated_label_key
			local ok, err = pcall(function()
				local rows = build().submenu
				world.refuse_write = true
				for index, key in ipairs({ "llm_agent_system1", "llm_agent_system2" }) do
					local off = rows[index + 2].menu[1]
					helpers.assert_eq(off.title, world.i18n.get("menu.agent.title"))
					helpers.assert_eq(off.fn(), false)
					helpers.assert_eq(state[key], "cerebras")
				end
				helpers.assert_eq(#world.applied, 0)
				helpers.assert_eq(world.menu_updates, 0)
				world.refuse_write = false
				helpers.assert_eq(rows[3].menu[1].fn(), true)
				helpers.assert_eq(state.llm_agent_system1, "")
				helpers.assert_eq(state.llm_agent_system2, "cerebras")
				helpers.assert_eq(#world.applied, 1)
				helpers.assert_eq(world.applied[1].runtime_fn, "set_llm_agent_system1")
			end)
			declaration.i18n = label
			if not ok then error(err, 0) end
		end)
	end)
end)


--- Independent fixed model-control contract, separate from the generated declaration.
local function system_model_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/agent_system_model.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("adapters.json_codec").decode(raw))
end

helpers.describe("Agent shared system model control (agent-system-model)", function()
	helpers.it("uses both actual model rows, shared caption and transaction refusal (agent-system-model)", function()
		local corpus = system_model_corpus()
		local state = base_state()
		state.llm_agent_system1, state.llm_agent_system2 = corpus.spec, corpus.spec
		with_panel(state, function(build, world)
			local root = require("infra.manifest_menu").get_root()
			local declaration = root[corpus.section][2]
			local label = declaration.i18n
			local ok, err = pcall(function()
				for _, prefix in ipairs({ "⚡", "🧠" }) do
					local rows = row_starting(build().submenu, prefix).menu
					helpers.assert_eq(rows[#rows - 1].title, "-")
					helpers.assert_eq(rows[#rows].title, corpus.caption)
				end
				declaration.i18n = corpus.mutated_label_key
				local retained = row_starting(build().submenu, "⚡").menu
				retained = retained[#retained]
				helpers.assert_eq(retained.title, corpus.mutated_caption)
				world.dialog_answer = { "OK", "changed-model" }
				world.refuse_write = true
				helpers.assert_eq(retained.fn(), false)
				helpers.assert_eq(state.llm_agent_system1, corpus.spec)
				helpers.assert_eq(state.llm_agent_system2, corpus.spec)
				helpers.assert_eq(#world.applied, 0)
				world.refuse_write = false
				helpers.assert_eq(retained.fn(), true)
				helpers.assert_eq(state.llm_agent_system1, "cerebras|changed-model")
				helpers.assert_eq(state.llm_agent_system2, corpus.spec)
				helpers.assert_eq(#world.applied, 1)
			end)
			declaration.i18n = label
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("takes exact shared order and refuses a malformed command owner (agent-system-model)", function()
		local corpus = system_model_corpus()
		local state = base_state()
		state.llm_agent_system1 = corpus.spec
		with_panel(state, function(build)
			local root = require("infra.manifest_menu").get_root()
			local original = root[corpus.section]
			local ok, err = pcall(function()
				root[corpus.section] = { original[2], original[1], {
					type = "label", id = "model_tail_marker", i18n = "menu.agent.off",
				} }
				local rows = row_starting(build().submenu, "⚡").menu
				helpers.assert_eq(rows[#rows - 2].title, corpus.caption)
				helpers.assert_eq(rows[#rows - 1].title, "-")
				helpers.assert_eq(rows[#rows].title, "Off")
				root[corpus.section] = { { type = "---" }, {
					type = "command", id = "unowned_agent_model", i18n = corpus.label_key,
				} }
				helpers.assert_nil(row_starting(build().submenu, "⚡"))
				helpers.assert_eq(state.llm_agent_system1, corpus.spec)
			end)
			root[corpus.section] = original
			if not ok then error(err, 0) end
		end)
	end)
end)

helpers.describe("Agent model observed-state frames (agent-system-model)", function()
	for _, variant in ipairs(system_model_corpus().variants) do
		helpers.it("uses the real declared " .. variant.section .. " caption (agent-system-model)", function()
			local state = base_state()
			state.llm_agent_system2 = "local"
			with_panel(state, function(build, world)
				world.listed = { ["qwen2.5:7b"] = variant.installed }
				local rows = row_starting(build().submenu, "🧠").menu
				helpers.assert_eq(row_starting(rows, "Model…").title, variant.caption)
				local declaration = require("infra.manifest_menu").get_root()[variant.section][2]
				local label = declaration.i18n
				declaration.i18n = system_model_corpus().label_key
				local ok, err = pcall(function()
					rows = row_starting(build().submenu, "🧠").menu
					helpers.assert_eq(row_starting(rows, "Model…").title, "Model… (qwen2.5:7b)",
						"even observed installed/missing captions come from their actual shared frame")
					helpers.assert_eq(state.llm_agent_system2, "local")
					helpers.assert_eq(#world.applied, 0)
				end)
				declaration.i18n = label
				if not ok then error(err, 0) end
			end)
		end)
	end
end)


--- Reads the two independent inert status frames.
local function empty_status_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/llm_empty_status.json"), "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

--- Holds the real native data, renderer and locale owners over private bootstrap paths.
local function with_empty_server_owner(scenario)
	local previous, previous_hs, previous_getenv = {}, rawget(_G, "hs"), os.getenv
	for name, value in pairs(package.loaded) do previous[name] = value end
	local native, owner, receipt, acquired, scratch, fresh_bridge
	local ok, err = pcall(function()
		local driver = helpers.driver_root():gsub("/+$", "")
		local shared = assert(driver:match("^(.*)/[^/]+$")) .. "/_shared/lua"
		require("tests.support.module_isolation").purge(driver, shared)
		helpers.load_with_stubs("infra.logger")
		scratch = assert(os.tmpname())
		assert(os.remove(scratch))
		assert(hs.fs.mkdir(scratch))
		assert(hs.fs.mkdir(scratch .. "/metrics"))
		local ledger = assert(io.open(scratch .. "/metrics/karabiner_kc.log", "wb")); assert(ledger:close())
		local bootstrap = assert(io.open(scratch .. "/paths.toml", "wb"))
		assert(bootstrap:write('ConfigDirPath = "' .. scratch .. '/"\n'))
		assert(bootstrap:close())
		os.getenv = function(name)
			if name == "ERGOPTI_PATHS_FILE" then return scratch .. "/paths.toml" end
			return previous_getenv(name)
		end
		local paths = require("infra.config_paths")
		helpers.assert_eq(paths.init(scratch .. "/"), true)
		helpers.assert_eq(paths.get_config_dir(), scratch .. "/")
		package.loaded["infra.i18n"] = nil
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end)
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner)
		helpers.assert_eq(acquired, true)
		receipt = native.scope_capture(owner)
		helpers.assert_not_nil(receipt)
		helpers.assert_eq(native.scope_apply(owner, receipt, "en"), true)
		local corpus = empty_status_corpus()
		local servers = require("modules.llm.local_servers")
		servers.sweep({ { id = corpus.server_id, base_url = "http://localhost:1234/v1" } }, function(_, settle)
			settle({ ok = true, status = 200, body = corpus.empty_server_body }); return true
		end)
		helpers.assert_eq(servers.result(corpus.server_id).status, servers.STATUS_UP)
		helpers.assert_eq(servers.result(corpus.server_id).models, {})
		local applied, observations = {}, { refreshes = 0 }
		local state = { llm_agent_system1 = corpus.server_id, llm_agent_system2 = corpus.server_id,
			llm_agent_mode = "action", llm_agent_disabled_apps = {} }
		local ctx = { state = state, settings_mgr = { apply_setting_transaction = function(options)
			applied[#applied + 1] = options; state[options.key] = options.value; return true
		end }, update_menu = function() observations.refreshes = observations.refreshes + 1 end, observations = observations }
		local panel = require("ui.menu.menu_llm.agent_panel")
		fresh_bridge = package.loaded["modules.keylogger.kc_bridge"]
		scenario(function() return panel.build(ctx) end, ctx, require("infra.manifest_menu"), native, applied, corpus, servers)
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	local cleanup_ok, cleanup_error = pcall(function()
		fresh_bridge = fresh_bridge or package.loaded["modules.keylogger.kc_bridge"]
		if fresh_bridge and not rawequal(fresh_bridge, previous["modules.keylogger.kc_bridge"]) then fresh_bridge.stop() end
		local scheduler = package.loaded["adapters.timer_scheduler"]
		if scheduler and not rawequal(scheduler, previous["adapters.timer_scheduler"]) then
			helpers.assert_eq(scheduler.cancelAll(), true)
			helpers.assert_eq(scheduler.activeCount(), 0)
		end
		if scratch then
			os.remove(scratch .. "/metrics/karabiner_kc.log")
			os.remove(scratch .. "/paths.toml")
			if hs.fs.attributes(scratch .. "/hammerspoon") then assert(hs.fs.rmdir(scratch .. "/hammerspoon")) end
			if hs.fs.attributes(scratch .. "/metrics") then assert(hs.fs.rmdir(scratch .. "/metrics")) end
			assert(hs.fs.rmdir(scratch))
		end
	end)
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	_G.hs = previous_hs
	os.getenv = previous_getenv
	helpers.assert_eq(rawequal(os.getenv, previous_getenv), true)
	for name, value in pairs(previous) do helpers.assert_eq(rawequal(package.loaded[name], value), true, name) end
	helpers.assert_eq(cleanup_ok, true, tostring(cleanup_error))
	helpers.assert_eq(restored, true, "actual translator inverse restores before releasing ownership")
	helpers.assert_eq(released, true)
	helpers.assert_eq(forgotten, true)
	if not ok then error(err, 0) end
end

--- Finds the genuine retained or discovered LM Studio submenu under System 1.
local function empty_server_rows(build)
	local system = assert(row_starting(build().submenu, "⚡"))
	local server = assert(row_starting(system.menu, "LM Studio"))
	return server.menu or {}, server
end

helpers.describe("Shared inert empty server status (llm-empty-status)", function()
	helpers.it("uses the genuine empty discovery receipt and shared inert caption (llm-empty-status)", function()
		with_empty_server_owner(function(build, ctx, menu, native, applied, corpus, servers)
			local definition = menu.get_array(corpus.agent.section)
			local original = definition[1]
			local ok, err = pcall(function()
				local rows = empty_server_rows(build)
				helpers.assert_eq(#rows, 1)
				helpers.assert_eq(rows[1].title, corpus.agent.english)
				helpers.assert_eq(rows[1].disabled, true)
				helpers.assert_nil(rows[1].fn)
				definition[1] = { type = "label", id = corpus.agent.rows[1].id, i18n = corpus.marker_key,
					platforms = { "hs" }, unavailable = "hide" }
				rows = empty_server_rows(build)
				helpers.assert_eq(rows[1].title, corpus.marker_english)
				helpers.assert_eq(rows[1].disabled, true)
				helpers.assert_nil(rows[1].fn)
				ctx.state.llm_agent_system1 = corpus.server_id .. "|" .. corpus.selected_model
				rows = empty_server_rows(build)
				helpers.assert_eq(#rows, 1)
				helpers.assert_eq(rows[1].title, corpus.selected_model)
				helpers.assert_eq(rows[1].checked, true)
				helpers.assert_type(rows[1].fn, "function")
				helpers.assert_eq(#applied, 0)
				helpers.assert_eq(ctx.observations.refreshes, 0)
				servers.sweep({ { id = corpus.server_id, base_url = "http://localhost:1234/v1" } }, function(_, settle)
					settle({ ok = true, status = 200, body = corpus.served_server_body }); return true
				end)
				ctx.state.llm_agent_system1 = corpus.server_id
				rows = empty_server_rows(build)
				helpers.assert_eq(rows[1].title, corpus.served_model)
				helpers.assert_type(rows[1].fn, "function")
				helpers.assert_eq(rows[1].fn(), true)
				helpers.assert_eq(ctx.state.llm_agent_system1, corpus.server_id .. "|" .. corpus.served_model)
				helpers.assert_eq(ctx.state.llm_agent_system2, corpus.server_id)
				helpers.assert_eq(#applied, 1)
				helpers.assert_eq(ctx.observations.refreshes, 0, "the native setting route delegates publication without a second direct refresh")
				helpers.assert_eq(applied[1].publish_setting, false)
				helpers.assert_eq(applied[1].runtime_fn, "set_llm_agent_system1")
			end)
			definition[1] = original
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(native.get(corpus.agent.key), corpus.agent.english)
		end)
	end)
	helpers.it("refuses a missing or unbound leaf then repairs the original presentation (llm-empty-status)", function()
		with_empty_server_owner(function(build, ctx, menu, _, applied, corpus)
			local definition = menu.get_array(corpus.agent.section)
			local original = definition[1]
			local ok, err = pcall(function()
				definition[1] = nil
				local rows = empty_server_rows(build)
				helpers.assert_eq(rows, {})
				definition[1] = { type = "command", id = "unowned_server_empty", i18n = corpus.agent.key,
					platforms = { "hs" }, unavailable = "hide" }
				rows = empty_server_rows(build)
				helpers.assert_eq(rows, {})
				helpers.assert_eq(ctx.state.llm_agent_system1, corpus.server_id)
				helpers.assert_eq(ctx.state.llm_agent_system2, corpus.server_id)
				helpers.assert_eq(#applied, 0)
				helpers.assert_eq(ctx.observations.refreshes, 0)
			end)
			definition[1] = original
			helpers.assert_eq(ok, true, tostring(err))
			local repaired = empty_server_rows(build)
			helpers.assert_eq(repaired[1].title, corpus.agent.english)
			helpers.assert_eq(repaired[1].disabled, true)
			helpers.assert_nil(repaired[1].fn)
		end)
	end)
	helpers.it("restores exact native owners and private paths after a raised scenario (llm-empty-status)", function()
		local raised = {}
		local ok, err = pcall(function()
			with_empty_server_owner(function() error(raised, 0) end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(rawequal(err, raised), true)
	end)
end)


--- Independent complete fixed presentation, captured from the original native producer.
local function panel_frame_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/agent_panel_frames.json"), "rb"))
	local raw = assert(file:read("*a")); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

helpers.describe("Agent complete declared presentation frames", function()
	for _, language in ipairs({ "en", "fr" }) do
		helpers.it("preserves the complete original hierarchy and native effects in " .. language, function()
			local corpus = panel_frame_corpus()
			local state = { llm_agent_system1 = "", llm_agent_system2 = "local", llm_agent_mode = "action",
				llm_agent_disabled_apps = { "hand.alpha", "hand.beta" } }
			with_panel(state, function(build, world)
				world.listed = {}
				local item = assert(build())
				local expected = corpus[language]
				helpers.assert_eq(item.label, expected.outer)
				helpers.assert_eq(titles(item.submenu), { expected.mode, "-", expected.system1, expected.system2, "-", expected.excluded })
				local first, second, excluded = item.submenu[3], item.submenu[4], item.submenu[6]
				helpers.assert_true(first.menu[1].checked)
				helpers.assert_eq(second.menu[1].checked, false)
				helpers.assert_true(second.menu[2].checked, "the original actual local backend remains selected")
				helpers.assert_eq(second.menu[#second.menu - 2].title, "-")
				helpers.assert_eq(second.menu[#second.menu - 1].title, expected.model)
				helpers.assert_eq(second.menu[#second.menu].title, expected.download)
				helpers.assert_eq(excluded.menu[1].title, corpus.picker_label)
				helpers.assert_eq(world.pickers[1].apps, state.llm_agent_disabled_apps)
				helpers.assert_eq(world.pickers[1].placeholder, expected.excluded)
				helpers.assert_eq(#world.applied, 0, "construction never commits an Agent setting")
				helpers.assert_eq(#world.installs, 0, "construction never starts a download")
				second.menu[#second.menu].fn()
				helpers.assert_eq(world.installs, { corpus.model })
				world.refuse_write = true
				world.pickers[1].on_change({ "hand.refused" })
				helpers.assert_eq(state.llm_agent_disabled_apps, { "hand.alpha", "hand.beta" })
				helpers.assert_eq(#world.applied, 0)
				world.refuse_write = false
				world.pickers[1].on_change({ "hand.changed" })
				helpers.assert_eq(world.applied[1].key, "llm_agent_disabled_apps")
				helpers.assert_eq(world.applied[1].runtime_fn, "set_llm_agent_disabled_apps")
			end, language)
		end)
	end

	helpers.it("reads every genuine frame and refuses complete declaration withdrawal before native discovery", function()
		local corpus = panel_frame_corpus()
		local state = base_state(); state.llm_agent_system2 = "local"
		with_panel(state, function(build, world)
			world.listed = {}
			local manifest = require("infra.manifest_menu")
			local root = manifest.get_root()
			local saved = {}
			for section, rows in pairs(corpus.frames) do
				saved[section] = root[section]
				helpers.assert_eq(root[section], rows, "independent canonical declaration: " .. section)
			end
			local original_agent_menu = root.agent_menu
			local ok, err = pcall(function()
				for section, original in pairs(saved) do
					local before = world.tool_lists or 0
					root[section] = nil
					helpers.assert_nil(build(), section .. " withdrawal cannot recreate fixed Agent frames")
					helpers.assert_eq(world.tool_lists or 0, before, "no discovery after missing-frame refusal")
					helpers.assert_eq(#world.applied, 0)
					helpers.assert_eq(#world.installs, 0)
					root[section] = original
					helpers.assert_not_nil(build(), "fresh actual declaration restores the whole parent")
				end
				for section, original in pairs(saved) do
					root[section] = { { type = "group", id = "foreign_unbound_child", i18n = "menu.agent.title",
						platforms = { "hs" }, unavailable = "hide" } }
					helpers.assert_nil(build(), section .. " invalid child cannot publish the complete Agent parent")
					helpers.assert_eq(#world.applied, 0)
					helpers.assert_eq(#world.installs, 0)
					root[section] = original
					helpers.assert_not_nil(build(), "the actual repaired frame remains admitted")
				end
				for section, original in pairs(saved) do
					for _, invalid in ipairs({ { false }, { {} }, { { i18n = false } }, { { i18n = 123 } } }) do
						local before = world.tool_lists or 0
						root[section] = invalid
						helpers.assert_nil(build(), section .. " malformed row refuses before child construction")
						helpers.assert_eq(world.tool_lists or 0, before)
						helpers.assert_eq(#world.applied, 0)
						helpers.assert_eq(#world.installs, 0)
					end
					root[section] = original
				end
				for section, original in pairs(saved) do
					for _, kind in ipairs({ "label", "---" }) do
						root[section] = { { type = kind, id = original[1].id, i18n = original[1].i18n,
							platforms = { "hs" }, unavailable = "hide" } }
						helpers.assert_nil(build(), section .. " wrong semantic row kind cannot replace its real child/command")
						helpers.assert_eq(#world.applied, 0)
						helpers.assert_eq(#world.installs, 0)
					end
					root[section] = original
				end
				local runner = require("modules.llm.agent_runner")
				local refresh_tools = runner.refresh_tools
				local late_ok, late_err = pcall(function()
					runner.refresh_tools = function(...)
						local result = refresh_tools(...)
						root.agent_system1_frame = { false }
						return result
					end
					helpers.assert_nil(build(), "a late thrown child refusal cannot publish a surviving partial parent")
					helpers.assert_eq(#world.applied, 0)
					helpers.assert_eq(#world.installs, 0)
				end)
				runner.refresh_tools = refresh_tools
				root.agent_system1_frame = saved.agent_system1_frame
				if not late_ok then error(late_err, 0) end
				local original_menu = root.agent_menu
				root.agent_menu = nil
				helpers.assert_nil(build(), "the genuine absent Agent child definition cannot become an empty fallback")
				root.agent_menu = original_menu
				helpers.assert_not_nil(build(), "the actual child definition repairs the parent route")
				local original = root.agent_system1_frame
				root.agent_system1_frame = { { type = "group", id = "agent_system1", i18n = "menu.agent.off",
					platforms = { "hs" }, unavailable = "hide" } }
				helpers.assert_eq(build().submenu[3].title, "Off", "the genuine changed declaration owns the parent caption")
				root.agent_system1_frame = original
			end)
			for section, original in pairs(saved) do root[section] = original end
			root.agent_menu = original_agent_menu
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("retains the genuine download callback and rechecks declaration withdrawal before delivery", function()
		local state = base_state(); state.llm_agent_system2 = "local"
		with_panel(state, function(build, world)
			world.listed = {}
			local item = assert(build())
			local retained = item.submenu[4].menu[#item.submenu[4].menu].fn
			local root = require("infra.manifest_menu").get_root()
			local saved = root.agent_download_frame
			local ok, err = pcall(function()
				root.agent_download_frame = nil
				helpers.assert_eq(retained(), false, "withdrawn command never enters the download owner")
				helpers.assert_eq(#world.installs, 0)
				root.agent_download_frame = saved
				helpers.assert_eq(retained(), true, "fresh declaration admits the original native callback")
				helpers.assert_eq(world.installs, { "qwen2.5:7b" })
			end)
			root.agent_download_frame = saved
			if not ok then error(err, 0) end
		end)
	end)
end)
