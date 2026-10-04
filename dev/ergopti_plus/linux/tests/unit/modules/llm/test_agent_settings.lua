--- tests/unit/modules/llm/test_agent_settings.lua

--- ==============================================================================
--- MODULE: AI Agent Settings And Menu (Linux)
--- DESCRIPTION:
--- llm.agent_system1 / llm.agent_system2 name a backend like the llm_vision
--- parameter; llm.agent_mode and llm.agent_disabled_apps complete them. They go
--- through infra/llm_preferences like every llm.* setting, and the tray's
--- « AI agent » submenu shows and changes them.
---
--- ROOT CAUSE ENCODED:
--- A setting the manifest declares for Linux with no reader, writer or menu
--- row is a promise the driver does not keep.
--- ==============================================================================

local helpers = require("tests.helpers")
local Scenario = require("tests.support.agent_scenario")
local i18n = require("infra.i18n")

--- Finds the first rendered row with this title.
local function find(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local nested = find(row.menu, title)
		if nested then return nested end
	end
end

--- The titles of a rendered submenu, separators as "-".
local function titles(rows)
	local list = {}
	for index, row in ipairs(rows) do list[index] = row.title or "-" end
	return table.concat(list, "|")
end

--- Builds the tray menu with a scripted text prompt.
--- @param world table
--- @param answers table Queue of prompt answers (false for Cancel).
--- @return table rows, table prompts
local function build_menu(world, answers)
	local prompts = {}
	local previous = package.loaded["ui.text_prompt"]
	package.loaded["ui.text_prompt"] = {
		ask = function(title, prompt, initial, hidden, choices)
			prompts[#prompts + 1] = { title = title, prompt = prompt, initial = initial, choices = choices }
			local answer = table.remove(answers, 1)
			if answer == false then return nil end
			return answer
		end,
	}
	local ok, rows = pcall(function()
		-- Both bind the scenario's freshly loaded agent settings.
		package.loaded["ui.menu.agent_rows"] = nil
		local menu_builder = helpers.load_module("ui.menu.menu_builder")
		return menu_builder.build({ llm = world.engine, on_menu_changed = function() world.redraws =
			(world.redraws or 0) + 1 end })
	end)
	world.restore_prompt = function() package.loaded["ui.text_prompt"] = previous end
	if not ok then
		world.restore_prompt()
		error(rows, 0)
	end
	return rows, prompts
end





-- ======================================
-- ======================================
-- ======= 1/ The settings ==============
-- ======================================
-- ======================================

helpers.describe("AI agent settings: stored like every llm.* setting", function()

	helpers.it("round-trips both systems, the mode and the excluded apps through the preferences", function()
		Scenario.run({ stored = { ["llm.agent_system2"] = "" } }, function(world)
			local Settings = require("modules.llm.agent_settings")
			helpers.assert_eq(Settings.get_spec("system1"), "", "off by default")
			helpers.assert_eq(Settings.set_spec("system1", "local|qwen3:14b"), true)
			helpers.assert_eq(Settings.set_spec("system2", "cerebras"), true)
			helpers.assert_eq(world.preferences.get("llm.agent_system1"), "local|qwen3:14b", "persisted")
			helpers.assert_eq(world.preferences.get("llm.agent_system2"), "cerebras")
			helpers.assert_eq(Settings.set_spec("system1", "cerebras|"), false, "an empty model is refused")
			helpers.assert_eq(Settings.set_spec("system1", "Not A Backend"), false)
			helpers.assert_eq(world.preferences.get("llm.agent_system1"), "local|qwen3:14b", "unchanged")
			helpers.assert_eq(Settings.set_mode("auto"), true)
			helpers.assert_eq(Settings.set_mode("sometimes"), false)
			helpers.assert_eq(world.preferences.get("llm.agent_mode"), "auto")
			helpers.assert_eq(Settings.set_disabled_apps({ "keepassxc", "keepassxc", "gnome-terminal" }), true)
			helpers.assert_eq(table.concat(world.preferences.get("llm.agent_disabled_apps"), "|"),
				"keepassxc|gnome-terminal", "without duplicates")
			helpers.assert_eq(Settings.is_app_disabled("keepassxc"), true)
			helpers.assert_eq(Settings.is_app_disabled("thunderbird"), false)
			helpers.assert_eq(Settings.set_spec("system1", ""), true)
			helpers.assert_eq(world.preferences.get("llm.agent_system1"), nil, "back to the default, not stored")

			-- A fresh reader resolves the same values from the stored file.
			Settings._reset_for_test()
			helpers.assert_eq(Settings.get_spec("system2"), "cerebras")
			helpers.assert_eq(Settings.get_mode(), "auto")
			helpers.assert_eq(#Settings.get_disabled_apps(), 2)
		end)
	end)

	helpers.it("resolves the model: the named one, the local default, the provider's default", function()
		Scenario.run({}, function(world)
			local Settings = require("modules.llm.agent_settings")
			Settings.set_spec("system1", "local")
			helpers.assert_eq(Settings.resolve("system1").model, world.config.default_models["local"])
			Settings.set_spec("system1", "cerebras|llama-3.3-70b")
			helpers.assert_eq(Settings.resolve("system1").model, "llama-3.3-70b")
			helpers.assert_eq(Settings.resolve("system2").model, "qwen-3.8-27b", "api_providers.json's default")
			Settings.set_spec("system1", "openai_compat")
			local resolved, reason = Settings.resolve("system1")
			helpers.assert_nil(resolved, "no default: not configured")
			helpers.assert_eq(reason, "no_model")
			local chat = Settings.chat_target("system2")
			helpers.assert_eq(chat.kind, "api")
			helpers.assert_eq(chat.target.token, "k", "the stored key")
			helpers.assert_eq(chat.target.model, "qwen-3.8-27b", "with the system's model")
			Settings.set_spec("system1", "local")
			helpers.assert_eq(Settings.chat_target("system1").target, "http://127.0.0.1:11434")
		end)
	end)

	helpers.it("an invalid stored value reads as off", function()
		Scenario.run({ stored = { ["llm.agent_system1"] = "Bad Value", ["llm.agent_mode"] = "never" } }, function()
			local Settings = require("modules.llm.agent_settings")
			helpers.assert_eq(Settings.get_spec("system1"), "")
			helpers.assert_eq(Settings.get_mode(), "off")
		end)
	end)

	helpers.it("warns once about a retired mode or spec and offers it for cleanup (config-outdated-llm-agent)", function()
		local marked = {}
		require("config_outdated").reset_for_tests()
		local reported = require("config_outdated").collect_reports(function()
			Scenario.run({ stored = { ["llm.agent_system1"] = "Bad Value", ["llm.agent_mode"] = "suggest" } }, function()
				local Settings = require("modules.llm.agent_settings")
				helpers.assert_eq(Settings.get_mode(), "off")
				helpers.assert_eq(Settings.get_spec("system1"), "")
			end)
			require("modules.llm.agent_settings").mark_config_reads({ llm = {
				agent_system1 = "Bad Value", agent_system2 = "cerebras", agent_mode = "suggest",
			} }, function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
		end)
		helpers.assert_eq(marked, { "llm.agent_system2" }, "only the value the reader uses is kept")
		helpers.assert_eq(reported, { ["llm.agent_mode"] = true, ["llm.agent_system1"] = true })
	end)

	helpers.it("marks its four keys as read for the config cleanup", function()
		local marked = {}
		require("modules.llm.agent_settings").mark_config_reads({ llm = {
			agent_system1 = "local", agent_system2 = "cerebras", agent_mode = "auto", agent_disabled_apps = { "x" },
		} }, function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
		table.sort(marked)
		helpers.assert_eq(table.concat(marked, "|"),
			"llm.agent_disabled_apps|llm.agent_mode|llm.agent_system1|llm.agent_system2")
	end)
end)





-- ======================================
-- ======================================
-- ======= 2/ The tray submenu ==========
-- ======================================
-- ======================================

--- Reads independent mode expectations rather than generated menu data.
local function mode_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/agent_mode_rows.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	local corpus = assert(require("json").decode(raw))
	helpers.assert_eq(#corpus.modes, 3)
	helpers.assert_eq(#corpus.states, 3)
	return corpus
end

helpers.describe("AI agent menu: a top-level submenu", function()

	for _, vector in ipairs(mode_corpus().states) do
		helpers.it("replays the independent mode menu matrix for " .. vector.selected, function()
			Scenario.run({ stored = { ["llm.agent_mode"] = vector.selected, ["llm.agent_system1"] = "cerebras" } }, function(world)
				local rows = build_menu(world, {})
				world.restore_prompt()
				local agent = find(rows, i18n.get("menu.agent.title"))
				local row = agent.menu[1]
				local corpus = mode_corpus()
				helpers.assert_eq(row.disabled == true, false, "the actual live mode command remains available")
				helpers.assert_eq(#row.menu, 3)
				for index, expected in ipairs(corpus.modes) do
					local actual = row.menu[index]
					helpers.assert_eq(actual.title, i18n.get(expected.label_key))
					helpers.assert_eq(actual.checked == true, vector.checked[index])
					if expected.value == vector.selected then
						helpers.assert_eq(row.title, Scenario.text("menu.agent.mode_title", { actual.title }))
					end
				end
			end)
		end)
	end

	helpers.it("uses reordered shared choices and preserves persistence refusal without redraw", function()
		Scenario.run({}, function(world)
			local renderer = require("infra.manifest_menu")
			local mode = renderer.get_root().agent_menu[1]
			local previous = mode.choices
			local corpus, keys = mode_corpus(), {}
			for _, expected in ipairs(corpus.modes) do keys[expected.value] = expected.label_key end
			mode.choices = {}
			for _, value in ipairs(corpus.reordered_values) do
				mode.choices[#mode.choices + 1] = { value = value, i18n = keys[value] }
			end
			local ok, err = pcall(function()
				local rows = build_menu(world, {})
				world.restore_prompt()
				local row = find(rows, i18n.get("menu.agent.title")).menu[1]
				for index, value in ipairs(corpus.reordered_values) do
					helpers.assert_eq(row.menu[index].title, i18n.get(keys[value]), "the declaration owns every choice")
				end
				require("infra.llm_preferences").set = function() return false end
				helpers.assert_eq(row.menu[2].fn(), false, "the native durable owner refuses")
				helpers.assert_eq(world.preferences.get("llm.agent_mode"), "action", "persisted value is unchanged")
				helpers.assert_eq(world.redraws or 0, 0, "a refused choice never redraws as success")
			end)
			mode.choices = previous
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("lists Off then every backend for each system, checks the current one, and stores a choice", function()
		Scenario.run({ stored = { ["llm.agent_system1"] = "local|qwen3:14b" } }, function(world)
			local rows = build_menu(world, {})
			world.restore_prompt()
			local agent = find(rows, i18n.get("menu.agent.title"))
			helpers.assert_not_nil(agent, "the top-level row exists")
			local Remote = require("modules.llm.api_remote")
			for _, system in ipairs({ "system1", "system2" }) do
				local current = system == "system1" and i18n.get("llm.vision.local_backend") or "Cerebras"
				local sub = find(agent.menu, Scenario.text("menu.agent." .. system, { current }))
				helpers.assert_not_nil(sub, system .. " shows its backend")
				local expected = { i18n.get("menu.agent.off"), i18n.get("llm.vision.local_backend") }
				-- System 1 also offers Jev (no chat model); System 2 only chat models.
				for _, provider in ipairs(Remote.providers()) do
					if system == "system1" or provider.format ~= "decisions" then
						expected[#expected + 1] = provider.label
					end
				end
				expected[#expected + 1] = "-"
				local model = system == "system1" and "qwen3:14b" or "qwen-3.8-27b"
				expected[#expected + 1] = Scenario.text("menu.agent.model", { model })
				helpers.assert_eq(titles(sub.menu), table.concat(expected, "|"), system .. " rows")
				local checked = {}
				for _, row in ipairs(sub.menu) do if row.checked then checked[#checked + 1] = row.title end end
				helpers.assert_eq(table.concat(checked, "|"), current, "only the current backend is checked")
			end
			local sub = find(agent.menu, Scenario.text("menu.agent.system2", { "Cerebras" }))
			find(sub.menu, "OpenAI").fn()
			helpers.assert_eq(world.preferences.get("llm.agent_system2"), "openai")
			find(sub.menu, i18n.get("menu.agent.off")).fn()
			helpers.assert_eq(world.preferences.get("llm.agent_system2"), nil, "Off stores the default")
			helpers.assert_true((world.redraws or 0) >= 2, "the menu redraws")
		end)
	end)

	helpers.it("the model row asks for a model, and an empty answer goes back to the default", function()
		Scenario.run({}, function(world)
			local rows, prompts = build_menu(world, { "llama-3.3-70b", "", false })
			local agent = find(rows, i18n.get("menu.agent.title"))
			local sub = find(agent.menu, Scenario.text("menu.agent.system2", { "Cerebras" }))
			local model_row = find(sub.menu, Scenario.text("menu.agent.model", { "qwen-3.8-27b" }))
			model_row.fn()
			helpers.assert_eq(prompts[1].prompt, Scenario.text("dialog.agent.model_prompt", { "Cerebras" }))
			helpers.assert_eq(world.preferences.get("llm.agent_system2"), "cerebras|llama-3.3-70b")
			model_row.fn()
			helpers.assert_eq(world.preferences.get("llm.agent_system2"), "cerebras", "empty: the default")
			model_row.fn()
			helpers.assert_eq(world.preferences.get("llm.agent_system2"), "cerebras", "Cancel changes nothing")
			world.restore_prompt()
		end)
	end)

	helpers.it("the mode is a radio list, and the automatic mode needs System 1", function()
		Scenario.run({}, function(world)
			local rows = build_menu(world, {})
			world.restore_prompt()
			local agent = find(rows, i18n.get("menu.agent.title"))
			local mode = find(agent.menu, Scenario.text("menu.agent.mode_title", { i18n.get("menu.agent.mode_action") }))
			helpers.assert_not_nil(mode, "the mode row names the current mode")
			helpers.assert_eq(titles(mode.menu), table.concat({ i18n.get("menu.agent.mode_off"),
				i18n.get("menu.agent.mode_action"), i18n.get("menu.agent.mode_auto") }, "|"))
			find(mode.menu, i18n.get("menu.agent.mode_auto")).fn()
			helpers.assert_eq(world.preferences.get("llm.agent_mode"), "action", "refused without System 1")
			helpers.assert_eq(world.notices[1], Scenario.text("llm.agent.no_system1"))
			helpers.assert_eq(world.redraws or 0, 0, "refused automatic mode never redraws as success")
			find(mode.menu, i18n.get("menu.agent.mode_off")).fn()
			helpers.assert_eq(world.preferences.get("llm.agent_mode"), nil, "off is the default")
		end)
	end)

	helpers.it("the excluded apps: the one typed in last, any other, and a click removes one", function()
		Scenario.run({ stored = { ["llm.agent_disabled_apps"] = { "keepassxc" } } }, function(world)
			world.type("a", "gnome-terminal")
			local rows, prompts = build_menu(world, { "  code  " })
			local agent = find(rows, i18n.get("menu.agent.title"))
			local sub = find(agent.menu, Scenario.text("menu.agent.disabled_apps", { 1 }))
			helpers.assert_not_nil(sub, "the row counts the excluded apps")
			local current = i18n.get("app_picker.exclude_current"):gsub("{app}", "gnome-terminal")
			find(sub.menu, current).fn()
			helpers.assert_eq(table.concat(world.preferences.get("llm.agent_disabled_apps"), "|"),
				"keepassxc|gnome-terminal")
			find(sub.menu, i18n.get("app_picker.add_another_app")).fn()
			helpers.assert_eq(#prompts, 1)
			find(sub.menu, "keepassxc  ✗").fn()
			helpers.assert_eq(table.concat(world.preferences.get("llm.agent_disabled_apps"), "|"),
				"gnome-terminal|code", "each click reads the current list: nothing is lost")
			world.restore_prompt()
		end)
	end)
end)


--- Replays the independent fixed-system row contract through the actual menu.
local function system_off_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/agent_system_off.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

helpers.describe("AI agent shared system Off row (agent-system-off)", function()
	for _, vector in ipairs(system_off_corpus().states) do
		helpers.it("uses the independent system checks for " .. vector.spec .. " (agent-system-off)", function()
			Scenario.run({ stored = { ["llm.agent_system1"] = vector.spec, ["llm.agent_system2"] = vector.spec } }, function(world)
				local corpus = system_off_corpus()
				local rows = build_menu(world, {})
				world.restore_prompt()
				local agent = find(rows, i18n.get("menu.agent.title"))
				for index in ipairs(corpus.systems) do
					local off = agent.menu[index + 2].menu[1]
					helpers.assert_eq(off.title, i18n.get(corpus.label_key))
					helpers.assert_eq(off.checked == true, vector.checked)
					helpers.assert_eq(type(off.fn), "function")
				end
			end)
		end)
	end

	helpers.it("uses the declaration label and exact owner ACK on a retained Off callback (agent-system-off)", function()
		Scenario.run({ stored = { ["llm.agent_system1"] = "cerebras" } }, function(world)
			local renderer = require("infra.manifest_menu")
			local declaration = renderer.get_root().agent_system_controls[1]
			local old_label = declaration.i18n
			declaration.i18n = system_off_corpus().mutated_label_key
			local settings = require("modules.llm.agent_settings")
			local original = settings.set_spec
			local ok, err = pcall(function()
				local rows = build_menu(world, {})
				world.restore_prompt()
				local off = find(rows, i18n.get("menu.agent.title")).menu[3].menu[1]
				helpers.assert_eq(off.title, i18n.get("menu.agent.title"), "the actual shared label controls this child")
				local observations = {}
				for _, receipt in ipairs({ false, 2, "ack", {} }) do
					settings.set_spec = function(system, value)
						observations[#observations + 1] = { system = system, value = value }
						return receipt
					end
					helpers.assert_eq(off.fn(), false, "truthy values cannot acknowledge a durable system change")
					helpers.assert_eq(world.redraws or 0, 0)
				end
				settings.set_spec = original
				helpers.assert_eq(#observations, 4)
				for _, observed in ipairs(observations) do
					helpers.assert_eq(observed.system, "system1")
					helpers.assert_eq(observed.value, "")
				end
				helpers.assert_eq(world.preferences.get("llm.agent_system1"), "cerebras")
				helpers.assert_eq(off.fn(), true, "retry uses the actual current owner")
				helpers.assert_nil(world.preferences.get("llm.agent_system1"), "Off restores the sparse default")
				helpers.assert_eq(world.redraws, 1)
				settings.set_spec = nil
				helpers.assert_eq(off.fn(), false, "a retained callback cannot bypass a missing native owner")
				helpers.assert_eq(world.redraws, 1)
				settings.set_spec = original
			end)
			settings.set_spec = original
			declaration.i18n = old_label
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("preserves foreign physical source and refuses an actual scoped writer before Off ACK (agent-system-off)", function()
		local sandbox = require("test.config_unused_keys_contract").sandbox
		sandbox.with_config('[llm]\nagent_system1 = "cerebras"\n[future]\nkeep = "initial"\n', function(path)
			local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.agent_settings", "ui.menu.agent_rows" }
			local previous = {}
			for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
			local ok, err = pcall(function()
				package.loaded["infra.config_paths"] = { config = function() return path end }
				local preferences = require("infra.llm_preferences")
				local changes = 0
				local menu = require("ui.menu.agent_rows").build({ on_menu_changed = function() changes = changes + 1 end }, {})
				local off = menu.submenu[3].menu[1]
				local owner = { pending = function() return false end }
				helpers.assert_eq(preferences.acquire(owner), true)
				local initial = sandbox.read_bytes(path)
				helpers.assert_eq(off.fn(), false)
				helpers.assert_eq(sandbox.read_bytes(path), initial)
				helpers.assert_eq(changes, 0)
				helpers.assert_eq(preferences.release(owner), true)
				local writer = require("toml_codec.writer")
				local original_batch = writer.batch_write
				local foreign = '[llm]\nagent_system1 = "cerebras"\n[future]\nkeep = "external"\n'
				local observed = {}
				writer.batch_write = function(target, operations, drop, source)
					observed.path_matches = target == path
					observed.source_matches = source.content == initial
					local file = assert(io.open(path, "wb")); file:write(foreign); file:close()
					return original_batch(target, operations, drop, source)
				end
				local called, acknowledged = pcall(off.fn)
				writer.batch_write = original_batch
				helpers.assert_eq(called, true, tostring(acknowledged))
				helpers.assert_eq(acknowledged, false)
				helpers.assert_eq(observed.path_matches, true)
				helpers.assert_eq(observed.source_matches, true)
				helpers.assert_eq(sandbox.read_bytes(path), foreign, "the real canonical writer refuses the changed source")
				helpers.assert_eq(changes, 0)
				helpers.assert_eq(require("modules.llm.agent_settings").get_spec("system1"), "cerebras")
				helpers.assert_eq(off.fn(), true)
				local document = require("toml_codec").decode(sandbox.read_bytes(path))
				helpers.assert_nil(document.llm.agent_system1)
				helpers.assert_eq(document.future.keep, "external")
				helpers.assert_eq(changes, 1)
			end)
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			if not ok then error(err, 0) end
		end)
	end)
end)
