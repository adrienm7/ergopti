--- tests/unit/modules/llm/test_agent_settings.lua

--- ==============================================================================
--- MODULE: AI Agent Settings And Menu (Linux)
--- DESCRIPTION:
--- llm.agent_system1 / llm.agent_system2 name a backend like the llm_vision
--- parameter; llm.agent_mode and llm.agent_disabled_apps complete them. They go
--- through infra/llm_preferences like every llm.* setting, and the tray's
--- « AI agent » component submenu shows and changes them under the exact
--- independently published available declaration. Current disabled public policy
--- is checked separately through the original scenario runner.
---
--- ROOT CAUSE ENCODED:
--- A setting the manifest declares for Linux with no reader, writer or menu
--- row is a promise the driver does not keep.
--- ==============================================================================

local helpers = require("tests.helpers")
local ActualScenario = require("tests.support.agent_scenario")
local i18n = require("infra.i18n")

--- Decorates a cache-restoration case with an absent genuine native owner.
--- The inner component journal must retire its actual inserted module entry;
--- this outer finally restores the pre-test identity, including false/absence.
--- @param body function Original complete restoration test body.
--- @return function Protected registered test body.
local function with_uncached_ai_parent(body)
	return function()
		local previous = rawget(package.loaded, "ui.menu.ai_parent")
		local ok, result = xpcall(function()
			package.loaded["ui.menu.ai_parent"] = nil
			body()
			helpers.assert_nil(rawget(package.loaded, "ui.menu.ai_parent"),
				"the inner component journal removes the genuine newly inserted owner")
		end, debug.traceback)
		package.loaded["ui.menu.ai_parent"] = previous
		if not ok then error(result, 0) end
		helpers.assert_true(rawequal(rawget(package.loaded, "ui.menu.ai_parent"), previous),
			"the outer finally restores the exact original native owner cache state")
	end
end

--- Observes the actual inserted owner at its registered Agent construction seam.
--- The original fresh builder must consume this table; a disconnected cached
--- upvalue gives zero calls. Every observation forwards the genuine owner.
--- @param body function Builds with the existing real native builder fixture.
--- @return table rows
local function with_actual_ai_parent_probe(body)
	local owner = require("ui.menu.ai_parent")
	local begin, agent_calls = owner.begin, 0
	owner.begin = function(renderer, kind, ...)
		if kind == "agent" then agent_calls = agent_calls + 1 end
		return begin(renderer, kind, ...)
	end
	local ok, rows = xpcall(body, debug.traceback)
	owner.begin = begin
	if not ok then error(rows, 0) end
	helpers.assert_eq(agent_calls, 1, "the fresh actual builder consumes the inserted native Agent owner exactly once")
	helpers.assert_true(rawequal(rawget(package.loaded, "ui.menu.ai_parent"), owner),
		"the native construction uses the actual newly inserted cache entry")
	return rows
end

--- Runs a component scenario under the independently published Agent declaration.
--- Public-policy scenarios keep the actual current declaration unchanged.
--- Every setup step and the body are protected; cache/global/source identities
--- are restored even if setup, fixture decoding or a completed scenario throws.
--- @param component boolean Use the recorded available declaration for coverage.
--- @param body function Scenario accepting the actual renderer and declaration.
--- @return any result
local function with_agent_declaration(component, body)
	local previous = {}; for name, value in pairs(package.loaded) do previous[name] = value end
	local original_getenv, original_i18n_safe = os.getenv, rawget(_G, "i18n_safe")
	local renderer, build, group_row, root, top, agent_index, public_agent, file
	local ok, result = xpcall(function()
		-- Retain the actual current locale/manifest owner cohort of this scenario.
		renderer = require("infra.manifest_menu")
		build, group_row = renderer.build, renderer.group_row
		root = renderer.get_root(); top = root and root.top_level
		helpers.assert_type(top, "table", "the actual top-level declaration must exist")
		for index, row in ipairs(top) do
			if row.id == "agent" then
				helpers.assert_nil(agent_index, "the actual Agent declaration must be unique")
				agent_index, public_agent = index, row
			end
		end
		helpers.assert_type(public_agent, "table", "the actual Agent declaration must exist")
		if component then
			-- Existing shared source fixture, published at 1028f6bd: not output
			-- expectations, current availability or a synthetic owner/engine.
			file = assert(io.open(helpers.driver_root()
				.. "/tests/support/fixtures/agent_available_top_level_published_1028.json", "rb"))
			local contents = assert(file:read("*a")); assert(file:close()); file = nil
			local available = require("json").decode(contents)
			helpers.assert_type(available, "table", "the published declaration must decode")
			helpers.assert_eq(available.id, "agent", "the historical source owns only Agent")
			helpers.assert_eq(available.greyed_when_paused, true, "the published pause policy is retained")
			local fields = 0
			for key in pairs(available) do
				helpers.assert_true(key == "id" or key == "greyed_when_paused",
					"the fixture cannot introduce readiness or owner fields")
				fields = fields + 1
			end
			helpers.assert_eq(fields, 2, "the independently published declaration has exactly two fields")
			top[agent_index] = available
		end
		return body(renderer, top[agent_index], public_agent)
	end, debug.traceback)
	local closed, close_error = true, nil
	if file then closed, close_error = pcall(function() assert(file:close()) end) end
	if root and top then root.top_level = top end
	if top and agent_index and public_agent then top[agent_index] = public_agent end
	if renderer then renderer.build, renderer.group_row = build, group_row end
	os.getenv = original_getenv; rawset(_G, "i18n_safe", original_i18n_safe)
	for name in pairs(package.loaded) do if previous[name] == nil then rawset(package.loaded, name, nil) end end
	for name, value in pairs(previous) do rawset(package.loaded, name, value) end
	if not ok then error(result, 0) end
	if not closed then error(close_error, 0) end
	return result
end

-- Only this test-local runner changes policy; all other native scenario members
-- retain their exact identities through forwarding, including ENTRY/NOW/text.
local component_depth = 0
local Scenario = setmetatable({}, { __index = ActualScenario })
function Scenario.run(options, body)
	return with_agent_declaration(true, function()
		local previous_depth = component_depth
		component_depth = previous_depth + 1
		local ok, result = xpcall(function() return ActualScenario.run(options, body) end, debug.traceback)
		component_depth = previous_depth
		if not ok then error(result, 0) end
		return result
	end)
end


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

helpers.describe("AI agent component menu: the published available top-level submenu", function()

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


--- Independently authored model-control rows, loaded from physical shared data.
local function system_model_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/agent_system_model.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw))
end

--- Holds genuine locale/backend/renderer identities and restores them on every exit.
--- @param code string Runtime-only fixture locale.
--- @param scenario function Receives the authentic production i18n owner.
local function with_system_model_locale(code, scenario)
	local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
	local native, owner, receipt, acquired
	local ok, err = pcall(function()
		native = require("infra.i18n")
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner)
		helpers.assert_eq(acquired, true)
		receipt = native.scope_capture(owner)
		helpers.assert_not_nil(receipt)
		helpers.assert_eq(native.scope_apply(owner, receipt, code), true)
		helpers.assert_eq(native.get_locale(), code)
		helpers.assert_eq(require("infra.locale").current_locale(), code)
		if component_depth > 0 then
			with_agent_declaration(true, function() scenario(native) end)
		else
			scenario(native)
		end
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	for _, name in ipairs(names) do helpers.assert_eq(rawequal(package.loaded[name], previous[name]), true, name) end
	helpers.assert_eq(restored, true, "the authentic runtime inverse restores its prior locale")
	helpers.assert_eq(released, true, "the temporary native claim is released even after a raised scenario")
	helpers.assert_eq(forgotten, true, "the finalized temporary receipt is forgotten")
	if not ok then error(err, 0) end
end

helpers.describe("AI agent shared system model control (agent-system-model)", function()
	helpers.it("uses both actual model rows, shared caption and exact owner ACK (agent-system-model)", function()
		local corpus = system_model_corpus()
		Scenario.run({ stored = { ["llm.agent_system1"] = corpus.spec, ["llm.agent_system2"] = corpus.spec } }, function(world)
			with_system_model_locale("en", function(i18n)
				local root = require("infra.manifest_menu").get_root()
				local declaration = root[corpus.section][2]
				local label = declaration.i18n
				local settings = require("modules.llm.agent_settings")
				local original_set = settings.set_spec
				local ok, err = pcall(function()
					local function systems(answers)
						local rows = build_menu(world, answers)
						world.restore_prompt()
						return find(rows, i18n.get("menu.agent.title")).menu
					end
					local rows = systems({})
					for index in ipairs(corpus.systems) do
						local children = rows[index + 2].menu
						helpers.assert_eq(children[#children - 1].title, "-")
						helpers.assert_eq(children[#children].title, corpus.caption)
					end
					declaration.i18n = corpus.mutated_label_key
					local retained = systems({ "changed-model", "changed-model" })[3].menu
					retained = retained[#retained]
					helpers.assert_eq(retained.title, corpus.mutated_caption)
					-- Keep the prompt installed while the retained model callback runs.
					local menu_rows = build_menu(world, { "changed-model", "changed-model" })
					retained = find(menu_rows, corpus.mutated_caption)
					settings.set_spec = function() return false end
					retained.fn()
					helpers.assert_eq(world.preferences.get("llm.agent_system1"), corpus.spec)
					helpers.assert_eq(world.preferences.get("llm.agent_system2"), corpus.spec)
					helpers.assert_eq(world.redraws or 0, 0)
					settings.set_spec = original_set
					retained.fn()
					helpers.assert_eq(world.preferences.get("llm.agent_system1"), "cerebras|changed-model")
					helpers.assert_eq(world.preferences.get("llm.agent_system2"), corpus.spec)
					helpers.assert_eq(world.redraws, 1)
					world.restore_prompt()
				end)
				world.restore_prompt()
				settings.set_spec = original_set
				declaration.i18n = label
				if not ok then error(err, 0) end
			end)
		end)
	end)

	helpers.it("takes exact shared order and refuses an unowned command (agent-system-model)", function()
		local corpus = system_model_corpus()
		Scenario.run({ stored = { ["llm.agent_system1"] = corpus.spec } }, function(world)
			with_system_model_locale("en", function(i18n)
				local root = require("infra.manifest_menu").get_root()
				local original = root[corpus.section]
				local ok, err = pcall(function()
					root[corpus.section] = { original[2], original[1], {
						type = "label", id = "model_tail_marker", i18n = "menu.agent.off",
					} }
					local rows = build_menu(world, {})
					world.restore_prompt()
					local children = find(rows, i18n.get("menu.agent.title")).menu[3].menu
					helpers.assert_eq(children[#children - 2].title, corpus.caption)
					helpers.assert_eq(children[#children - 1].title, "-")
					helpers.assert_eq(children[#children].title, "Off")
					root[corpus.section] = { { type = "---" }, {
						type = "command", id = "unowned_agent_model", i18n = corpus.label_key,
					} }
					rows = build_menu(world, {})
					world.restore_prompt()
					helpers.assert_nil(find(rows, corpus.caption))
					helpers.assert_eq(world.preferences.get("llm.agent_system1"), corpus.spec)
				end)
				world.restore_prompt()
				root[corpus.section] = original
				if not ok then error(err, 0) end
			end)
		end)
	end)
end)

helpers.describe("Agent model physical-source ownership (agent-system-model)", function()
	helpers.it("preserves physical bytes on scope/CAS refusal and retries the real model writer (agent-system-model)", function()
		local sandbox = require("test.config_unused_keys_contract").sandbox
		local initial = '[llm]\nagent_system1 = "cerebras|hand/50%"\n[future]\nkeep = "initial"\n'
		local foreign = '[llm]\nagent_system1 = "cerebras|hand/50%"\n[future]\nkeep = "external"\n'
		local expected = '[llm]\nagent_system1 = "cerebras|changed-model"\n[future]\nkeep = "external"\n'
		sandbox.with_config(initial, function(path)
			local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.agent_settings", "ui.menu.agent_rows" }
			local previous = {}
			for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
			local writer = require("toml_codec.writer")
			local original_batch = writer.batch_write
			local ok, err = pcall(function()
				package.loaded["infra.config_paths"] = { config = function() return path end }
				local preferences = require("infra.llm_preferences")
				local changes = 0
				local menu = require("ui.menu.agent_rows").build({
					on_menu_changed = function() changes = changes + 1 end,
				}, { prompt = function() return "changed-model" end })
				local children = menu.submenu[3].menu
				local retained = children[#children]
				local owner = { pending = function() return false end }
				helpers.assert_eq(preferences.acquire(owner), true)
				retained.fn()
				helpers.assert_eq(sandbox.read_bytes(path), initial)
				helpers.assert_eq(changes, 0)
				helpers.assert_eq(preferences.release(owner), true)
				local observed = {}
				writer.batch_write = function(target, operations, drop, source)
					observed.path_matches = target == path
					observed.source_matches = source.content == initial
					local file = assert(io.open(path, "wb")); file:write(foreign); file:close()
					return original_batch(target, operations, drop, source)
				end
				local called, result = pcall(retained.fn)
				writer.batch_write = original_batch
				helpers.assert_eq(called, true, tostring(result))
				helpers.assert_eq(observed.path_matches, true)
				helpers.assert_eq(observed.source_matches, true)
				helpers.assert_eq(sandbox.read_bytes(path), foreign)
				helpers.assert_eq(changes, 0)
				helpers.assert_eq(require("modules.llm.agent_settings").get_spec("system1"), "cerebras|hand/50%")
				retained.fn()
				helpers.assert_eq(sandbox.read_bytes(path), expected, "the hand image retains the external future field")
				helpers.assert_eq(changes, 1)
				helpers.assert_eq(require("modules.llm.agent_settings").get_spec("system1"), "cerebras|changed-model")
				package.loaded["infra.llm_preferences"] = nil
				helpers.assert_eq(require("infra.llm_preferences").get("llm.agent_system1"), "cerebras|changed-model")
			end)
			writer.batch_write = original_batch
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			if not ok then error(err, 0) end
		end)
	end)
end)

--- Reproduces the genuine warm i18n owner surviving a later locale-core reload.
--- @param scenario function Receives the French owner and newer backend.
local function with_system_model_french_seed(scenario)
	with_system_model_locale("fr", function(native)
		local backend, core = package.loaded["infra.locale"], package.loaded["locale.core"]
		local ok, err = pcall(function()
			require("infra.manifest_menu").get_root()
			local newer = helpers.load_module("infra.locale")
			newer.set_locale("en")
			helpers.assert_eq(newer.get("menu.agent.model"), "Model… ({1})")
			helpers.assert_eq(native.get("menu.agent.model"), "Modèle… ({1})",
				"the old fixture changes a different genuine backend than the native producer")
			scenario(native, newer)
		end)
		package.loaded["infra.locale"], package.loaded["locale.core"] = backend, core
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Agent model locale cohort isolation (agent-system-model)", function()
	helpers.it("uses actual English producers and restores the split French cohort exactly (agent-system-model)", function()
		with_system_model_french_seed(function(native, newer)
			local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
			local before = {}
			for _, name in ipairs(names) do before[name] = package.loaded[name] end
			local strings = native.get("menu.agent.model")
			local backend_locale = newer.current_locale()
			with_system_model_locale("en", function(scoped)
				local corpus = system_model_corpus()
				Scenario.run({ stored = { ["llm.agent_system1"] = corpus.spec } }, function(world)
					local rows = build_menu(world, {})
					world.restore_prompt()
					local children = find(rows, scoped.get("menu.agent.title")).menu[3].menu
					helpers.assert_eq(children[#children].title, corpus.caption)
					helpers.assert_eq(scoped.get_locale(), "en")
				end)
			end)
			for _, name in ipairs(names) do helpers.assert_eq(rawequal(package.loaded[name], before[name]), true, name) end
			helpers.assert_eq(native.get_locale(), "fr")
			helpers.assert_eq(native.get("menu.agent.model"), strings)
			helpers.assert_eq(newer.current_locale(), backend_locale)
		end)
	end)

	helpers.it("restores prior owners on a raised English scenario and permits a genuine retry (agent-system-model)", function()
		with_system_model_french_seed(function(native, newer)
			local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
			local before = {}
			for _, name in ipairs(names) do before[name] = package.loaded[name] end
			local strings = native.get("menu.agent.model")
			local backend_locale = newer.current_locale()
			local called, err = pcall(function()
				with_system_model_locale("en", function(scoped)
					helpers.assert_eq(scoped.get("menu.agent.model"), "Model… ({1})")
					error("intentional-system-model-locale-failure")
				end)
			end)
			helpers.assert_eq(called, false)
			helpers.assert_true(tostring(err):find("intentional-system-model-locale-failure", 1, true) ~= nil)
			for _, name in ipairs(names) do helpers.assert_eq(rawequal(package.loaded[name], before[name]), true, name) end
			helpers.assert_eq(native.get_locale(), "fr")
			helpers.assert_eq(native.get("menu.agent.model"), strings)
			helpers.assert_eq(newer.current_locale(), backend_locale)
			with_system_model_locale("en", function(scoped)
				helpers.assert_eq(scoped.get_locale(), "en")
				helpers.assert_eq(scoped.get("menu.agent.model"), "Model… ({1})")
			end)
		end)
	end)
end)


--- Loads captions frozen from prior physical locale bytes, never from new menu output.
local function disabled_apps_frame_corpus()
	local path = require("infra.paths").shared("tests/corpus/menus/agent_linux_disabled_apps.json")
	local file = assert(io.open(path, "rb"))
	local content = assert(file:read("*a")); assert(file:close())
	return assert(require("json").decode(content))
end

--- Runs through the actual producer, modal boundary and shared final parent renderer.
local function with_disabled_apps_frame(apps, last, answers, scenario)
	Scenario.run({ stored = { ["llm.agent_disabled_apps"] = apps } }, function(world)
		if last then world.type("a", last) end
		local ok, err = pcall(function()
			local rows, prompts = build_menu(world, answers or {})
			local agent = assert(find(rows, require("infra.i18n").get("menu.agent.title")))
			local count = #require("modules.llm.agent_settings").get_disabled_apps()
			local parent = find(agent.menu, Scenario.text("menu.agent.disabled_apps", { count }))
			scenario(world, parent, prompts, agent)
		end)
		if world.restore_prompt then world.restore_prompt() end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Linux Agent complete excluded-applications frame (agent-disabled-apps-frame)", function()
	for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
		"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		local language = code
		helpers.it("retains prior literal captions and parent through real " .. language .. " owners (agent-disabled-apps-frame)", function()
			with_system_model_locale(language, function()
				local corpus = disabled_apps_frame_corpus()
				with_disabled_apps_frame({ corpus.application }, corpus.current_application, {}, function(_, parent)
					local expected = corpus.locales[language]
					helpers.assert_not_nil(parent)
					helpers.assert_eq(parent.title, expected.parent)
					helpers.assert_eq(parent.menu[1].title, corpus.removed_caption)
					helpers.assert_eq(parent.menu[2].title, "-")
					helpers.assert_eq(parent.menu[3].title, expected.current)
					helpers.assert_eq(parent.menu[4].title, expected.add)
					helpers.assert_nil(parent.fn, "a real parent owns no leaf command")
					helpers.assert_eq(type(parent.menu[1].fn), "function")
					helpers.assert_nil(parent.menu[2].fn)
					helpers.assert_eq(type(parent.menu[3].fn), "function")
					helpers.assert_eq(type(parent.menu[4].fn), "function")
				end)
			end)
		end)
	end

	for _, vector in ipairs({
		{ apps = {}, last = false, count = 1, boundary = false, current = false },
		{ apps = {}, last = "editor", count = 2, boundary = false, current = true },
		{ apps = { "editor" }, last = false, count = 3, boundary = true, current = false },
		{ apps = { "editor" }, last = "editor", count = 3, boundary = true, current = false },
		{ apps = { "editor" }, last = "terminal", count = 4, boundary = true, current = true },
		{ apps = { "z", "a" }, last = false, count = 4, boundary = true, current = false },
	}) do
		local case = vector
		helpers.it("preserves actual native membership and shared boundary for " .. #case.apps .. "/" .. tostring(case.last)
			.. " (agent-disabled-apps-frame)", function()
			with_system_model_locale("en", function()
				with_disabled_apps_frame(case.apps, case.last, {}, function(_, parent)
					helpers.assert_not_nil(parent)
					helpers.assert_eq(#parent.menu, case.count)
					for index, app in ipairs(case.apps) do helpers.assert_eq(parent.menu[index].title, app .. "  ✗") end
					if case.boundary then helpers.assert_eq(parent.menu[#case.apps + 1].title, "-") end
					if case.current then
						helpers.assert_eq(parent.menu[case.count - 1].title, "Exclude " .. case.last .. " (current)")
					end
					helpers.assert_eq(parent.menu[case.count].title, "+ Add another application…")
				end)
			end)
		end)
	end

	helpers.it("takes parent, leaf caption and exact order from the physical declaration (agent-disabled-apps-frame)", function()
		with_system_model_locale("en", function()
			local menu = require("infra.manifest_menu")
			local root = menu.get_root()
			local sections = disabled_apps_frame_corpus().sections
			local children, parent, remove = root[sections.children], root[sections.parent][1], root[sections.remove][1]
			local label, marker = parent.i18n, remove.i18n
			local ok, err = pcall(function()
				parent.i18n = "menu.agent.model"
				remove.i18n = "menu.agent.off"
				root[sections.children] = { children[4], children[3], children[2], children[1] }
				with_disabled_apps_frame({ "editor" }, "terminal", {}, function(_, _, _, agent)
					local actual = assert(find(agent.menu, "Model… (1)"))
					helpers.assert_eq(titles(actual.menu), "+ Add another application…|Exclude terminal (current)|-|editor  Off")
				end)
			end)
			root[sections.children], parent.i18n, remove.i18n = children, label, marker
			if not ok then error(err, 0) end
		end)
	end)

	for _, name in ipairs({ "removed command", "current command", "add command", "missing boundary", "cyclic children",
		"current getter", "parent getter", "literal suffix layout" }) do
		local case = name
		helpers.it("refuses " .. case .. " without settings effects and restores the real frame (agent-disabled-apps-frame)", function()
			with_system_model_locale("en", function()
				local root = require("infra.manifest_menu").get_root()
				local sections = disabled_apps_frame_corpus().sections
				local parent, remove, current, add = root[sections.parent][1], root[sections.remove][1],
					root[sections.current][1], root[sections.add][1]
				local ids = { remove.id, current.id, add.id }
				local boundary, children = root[sections.boundary], root[sections.children]
				local current_getter, parent_getter, layout = current.caption_getter, parent.caption_getter, remove.caption_layout
				local ok, err = pcall(function()
					if case == "removed command" then remove.id = "foreign_remove"
					elseif case == "current command" then current.id = "foreign_current"
					elseif case == "add command" then add.id = "foreign_add"
					elseif case == "missing boundary" then root[sections.boundary] = nil
					elseif case == "cyclic children" then root[sections.children] = { { type = "include", section = sections.children } }
					elseif case == "current getter" then current.caption_getter = "foreign_caption"
					elseif case == "parent getter" then parent.caption_getter = "foreign_count"
					else remove.caption_layout = "infix" end
					with_disabled_apps_frame({ "editor" }, "terminal", {}, function(world, actual)
						helpers.assert_nil(actual, "the incomplete family cannot publish an empty or fallback parent")
						helpers.assert_eq(world.preferences.get("llm.agent_disabled_apps"), { "editor" })
						helpers.assert_eq(world.redraws or 0, 0)
					end)
				end)
				remove.id, current.id, add.id = ids[1], ids[2], ids[3]
				root[sections.boundary], root[sections.children] = boundary, children
				current.caption_getter, parent.caption_getter, remove.caption_layout = current_getter, parent_getter, layout
				if not ok then error(err, 0) end
				with_disabled_apps_frame({ "editor" }, "terminal", {}, function(_, actual)
					helpers.assert_not_nil(actual, "exact original declaration restoration recovers the native frame")
				end)
			end)
		end)
	end

	helpers.it("keeps retained removals and current-app callbacks on the actual live settings list (agent-disabled-apps-frame)", function()
		with_system_model_locale("en", function()
			with_disabled_apps_frame({ "z", "a" }, "terminal", {}, function(world, parent)
				local settings = require("modules.llm.agent_settings")
				helpers.assert_eq(settings.set_disabled_apps({ "z", "a", "later" }), true)
				parent.menu[1].fn()
				helpers.assert_eq(world.preferences.get("llm.agent_disabled_apps"), { "a", "later" })
				parent.menu[4].fn()
				helpers.assert_eq(world.preferences.get("llm.agent_disabled_apps"), { "a", "later", "terminal" })
				parent.menu[4].fn()
				helpers.assert_eq(world.preferences.get("llm.agent_disabled_apps"), { "a", "later", "terminal" })
				helpers.assert_eq(world.redraws, 2, "duplicate current-app additions keep the original no-op behavior")
			end)
		end)
	end)

	helpers.it("keeps native dialog arguments, choices, cancellation, trimming and redraw (agent-disabled-apps-frame)", function()
		with_system_model_locale("en", function()
			local name = "adapters.window_info"
			local previous = package.loaded[name]
			package.loaded[name] = { getAll = function() return {
				{ appId = "z" }, { appId = "editor" }, { appId = "a" }, { appId = "z" }, {},
			} end }
			local ok, err = pcall(function()
				with_disabled_apps_frame({ "editor" }, false, { false, "   ", "  a  " }, function(world, parent, prompts)
					local callback = parent.menu[#parent.menu].fn
					callback(); callback()
					helpers.assert_eq(world.preferences.get("llm.agent_disabled_apps"), { "editor" })
					helpers.assert_eq(world.redraws or 0, 0)
					callback()
					helpers.assert_eq(prompts[1].title, require("infra.i18n").get("menu.agent.title"))
					helpers.assert_eq(prompts[1].prompt, require("infra.i18n").get("app_picker.search_placeholder"))
					helpers.assert_eq(prompts[1].initial, "")
					helpers.assert_eq(prompts[1].choices, { "a", "z" })
					helpers.assert_eq(world.preferences.get("llm.agent_disabled_apps"), { "editor", "a" })
					helpers.assert_eq(world.redraws, 1)
				end)
			end)
			package.loaded[name] = previous
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("publishes the actual completed parent and native child identities (agent-disabled-apps-frame)", function()
		with_system_model_locale("en", function()
			local renderer = require("infra.manifest_menu")
			local render = renderer.render_rows
			local captured, count = nil, 0
			renderer.render_rows = function(rows, id, ...)
				local native = render(rows, id, ...)
				if id == "agent_disabled_apps" then captured, count = native[1], count + 1 end
				return native
			end
			local ok, err = pcall(function()
				with_disabled_apps_frame({ "editor" }, "terminal", {}, function(_, parent)
					helpers.assert_eq(count, 1, "one genuine completed frame is published")
					helpers.assert_eq(rawequal(parent, captured), true, "the actual final producer retains its rendered parent")
					helpers.assert_eq(rawequal(parent.menu, captured.menu), true)
					helpers.assert_eq(parent.menu[1].fn, captured.menu[1].fn)
					helpers.assert_eq(parent.menu[3].fn, captured.menu[3].fn)
					helpers.assert_eq(parent.menu[4].fn, captured.menu[4].fn)
				end)
			end)
			renderer.render_rows = render
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("preserves each native write refusal and callback result (agent-disabled-apps-frame)", function()
		with_system_model_locale("en", function()
			with_disabled_apps_frame({ "editor" }, "terminal", { "another" }, function(world, parent)
				local settings = require("modules.llm.agent_settings")
				local previous = settings.set_disabled_apps
				local observed = {}
				settings.set_disabled_apps = function(value) observed[#observed + 1] = value; return false end
				local ok, err = pcall(function()
					helpers.assert_nil(parent.menu[1].fn())
					helpers.assert_nil(parent.menu[3].fn())
					helpers.assert_nil(parent.menu[4].fn())
					helpers.assert_eq(observed, { {}, { "editor", "terminal" }, { "editor", "another" } })
					helpers.assert_eq(world.preferences.get("llm.agent_disabled_apps"), { "editor" })
					helpers.assert_eq(world.redraws or 0, 0)
				end)
				settings.set_disabled_apps = previous
				if not ok then error(err, 0) end
			end)
		end)
	end)
end)

--- Frozen old captions; no output of the candidate renderer defines expectations.
local function agent_system_frames_corpus()
	local path = require("infra.paths").shared("tests/corpus/menus/agent_linux_system_frames.json")
	local file = assert(io.open(path, "rb"))
	local raw = assert(file:read("*a")); assert(file:close())
	return assert(require("json").decode(raw))
end

--- Uses the registered native scenario, settings and menu producer unchanged.
local function with_agent_system_frames(spec, answers, scenario)
	Scenario.run({ stored = { ["llm.agent_system1"] = spec, ["llm.agent_system2"] = spec } }, function(world)
		local ok, err = pcall(function()
			local rows, prompts = build_menu(world, answers or {})
			local agent = assert(find(rows, require("infra.i18n").get("menu.agent.title")))
			scenario(world, agent, prompts)
		end)
		if world.restore_prompt then world.restore_prompt() end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Linux Agent complete System1/System2 frames (agent-linux-system-frame)", function()
	for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
		"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		local language = code
		helpers.it("preserves both native system parents and literal model in " .. language .. " (agent-linux-system-frame)", function()
			with_system_model_locale(language, function()
				local corpus = agent_system_frames_corpus()
				with_agent_system_frames(corpus.spec, {}, function(world, agent)
					for index, system in ipairs({ "system1", "system2" }) do
						local parent = agent.menu[index + 2]
						helpers.assert_eq(parent.title, corpus.locales[language].systems[system].remote)
						helpers.assert_nil(parent.fn)
						helpers.assert_eq(parent.menu[1].title, corpus.locales[language].off)
						helpers.assert_eq(parent.menu[1].checked, false)
						helpers.assert_eq(parent.menu[2].title, corpus.locales[language]["local"])
						helpers.assert_eq(parent.menu[#parent.menu - 1].title, "-")
						helpers.assert_eq(parent.menu[#parent.menu].title, corpus.locales[language].model)
						helpers.assert_eq(type(parent.menu[#parent.menu].fn), "function")
						helpers.assert_true(find(parent.menu, "Cerebras").checked)
					end
					helpers.assert_eq(world.redraws or 0, 0)
				end)
			end)
		end)
	end

	for _, spec in ipairs({ "", "local", "cerebras" }) do
		local value = spec
		helpers.it("keeps actual off/local/default resolutions for " .. value .. " (agent-linux-system-frame)", function()
			with_system_model_locale("en", function()
				local corpus = agent_system_frames_corpus()
				with_agent_system_frames(value, {}, function(_, agent)
					for index, system in ipairs({ "system1", "system2" }) do
						local parent = agent.menu[index + 2]
						local key = value == "" and "off" or value == "local" and "local" or "remote"
						helpers.assert_eq(parent.title, corpus.locales.en.systems[system][key])
						helpers.assert_eq(parent.menu[1].checked, value == "")
						if value == "" then helpers.assert_eq(parent.menu[#parent.menu].title, corpus.locales.en.model_empty) end
					end
				end)
			end)
		end)
	end

	helpers.it("retains actual native provider literals and callback results (agent-linux-system-frame)", function()
		with_system_model_locale("en", function()
			local corpus = agent_system_frames_corpus()
			Scenario.run({ stored = { ["llm.agent_system1"] = corpus.spec, ["llm.agent_system2"] = corpus.spec } }, function(world)
				local descriptor = assert(require("modules.llm.api_remote").provider("cerebras"))
				local label = descriptor.label
				local settings = require("modules.llm.agent_settings")
				local setter = settings.set_spec
				local ok, err = pcall(function()
					descriptor.label = corpus.provider_literal
					local rows = build_menu(world, {})
					local agent = assert(find(rows, require("infra.i18n").get("menu.agent.title")))
					for index, system in ipairs({ "system1", "system2" }) do
						local parent = agent.menu[index + 2]
						helpers.assert_eq(parent.title, corpus.locales.en.systems[system].native_literal)
						helpers.assert_true(find(parent.menu, corpus.provider_literal).checked)
					end
					local retained = assert(find(agent.menu[3].menu, "OpenAI"))
					settings.set_spec = function() return false end
					helpers.assert_nil(retained.fn(), "the existing backend callback returns nil even when its write refuses")
					helpers.assert_eq(world.preferences.get("llm.agent_system1"), corpus.spec)
					helpers.assert_eq(world.redraws or 0, 0)
					settings.set_spec = setter
					helpers.assert_nil(retained.fn())
					helpers.assert_eq(world.preferences.get("llm.agent_system1"), "openai")
					helpers.assert_eq(world.preferences.get("llm.agent_system2"), corpus.spec)
					helpers.assert_eq(world.redraws, 1)
				end)
				if world.restore_prompt then world.restore_prompt() end
				descriptor.label, settings.set_spec = label, setter
				if not ok then error(err, 0) end
			end)
		end)
	end)

	helpers.it("takes finished parents, backend policy and whole child order from shared declarations (agent-linux-system-frame)", function()
		with_system_model_locale("en", function()
			local corpus = agent_system_frames_corpus()
			local menu = require("infra.manifest_menu")
			local root, sections = menu.get_root(), corpus.sections
			local parents = { root[sections.system1][1], root[sections.system2][1] }
			local labels = { parents[1].i18n, parents[2].i18n }
			local children = root[sections.children]
			local backend = root[sections.backend][1]
			local checked = backend.checked_when
			local render, observed = menu.render_rows, {}
			menu.render_rows = function(rows, id, ...)
				local record
				if id == "agent_system1" or id == "agent_system2" then
					record = { parent = rows[1], data = rows[1].items }
					observed[id] = observed[id] or {}
					observed[id][#observed[id] + 1] = record
				end
				local native = render(rows, id, ...)
				if record then record.native = native[1] end
				return native
			end
			local ok, err = pcall(function()
				parents[1].i18n, parents[2].i18n = "menu.agent.model", "menu.agent.model"
				root[sections.children] = { children[3], children[2], children[1] }
				backend.checked_when = nil
				with_agent_system_frames(corpus.spec, {}, function(_, agent)
					for _, index in ipairs({ 3, 4 }) do
						local parent = agent.menu[index]
						helpers.assert_eq(parent.title, "Model… (Cerebras)")
						local id = index == 3 and "agent_system1" or "agent_system2"
						helpers.assert_eq(#observed[id], 1, "the actual parent crosses its native boundary once")
						local record = observed[id][1]
						helpers.assert_true(rawequal(parent, record.native))
						local data = record.data
						helpers.assert_type(data, "table")
						-- The original '-' belongs to actual DATA; only final native rendering prunes it.
						helpers.assert_eq(data[1].separator, true)
						helpers.assert_nil(data[1].label)
						helpers.assert_nil(data[1].action)
						helpers.assert_eq(data[2].label, corpus.locales.en.model)
						helpers.assert_eq(data[#data].label, corpus.locales.en.off)
						local actual_backend
						for _, row in ipairs(data) do
							if row.label == "Cerebras" then actual_backend = row end
						end
						helpers.assert_type(actual_backend, "table")
						helpers.assert_eq(actual_backend.checked == true, false)
						helpers.assert_eq(#parent.menu, #data - 1, "only the leading native separator is pruned")
						helpers.assert_eq(parent.menu[1].title, corpus.locales.en.model)
						for native_index, native in ipairs(parent.menu) do
							local row = data[native_index + 1]
							helpers.assert_true(native.title ~= "-", "this reversed frame has no remaining internal boundary")
							helpers.assert_nil(row.separator)
							helpers.assert_eq(native.title, row.label, "the complete declared DATA order survives native pruning")
							helpers.assert_eq(native.checked, row.checked)
							helpers.assert_type(row.action, "function")
							helpers.assert_true(rawequal(native.fn, row.action), "the original DATA callback is retained by identity")
						end
						helpers.assert_eq(parent.menu[#parent.menu].title, corpus.locales.en.off)
						helpers.assert_eq(find(parent.menu, "Cerebras").checked == true, false)
					end
				end)
			end)
			menu.render_rows = render
			parents[1].i18n, parents[2].i18n = labels[1], labels[2]
			root[sections.children], backend.checked_when = children, checked
			if not ok then error(err, 0) end
		end)
	end)

	for _, name in ipairs({ "backend command", "backend getter", "parent getter", "model getter", "missing children", "foreign child list" }) do
		local case = name
		helpers.it("refuses " .. case .. " and repairs the genuine complete family (agent-linux-system-frame)", function()
			with_system_model_locale("en", function()
				local corpus = agent_system_frames_corpus()
				local root, sections = require("infra.manifest_menu").get_root(), corpus.sections
				local backend, parent, model = root[sections.backend][1], root[sections.system1][1], root.agent_system_model_controls[2]
				local id, getter, parent_getter, model_getter, children = backend.id, backend.caption_getter,
					parent.caption_getter, model.caption_getter, root[sections.children]
				local list_id = children[2].id
				local ok, err = pcall(function()
					if case == "backend command" then backend.id = "foreign_backend"
					elseif case == "backend getter" then backend.caption_getter = "foreign_caption"
					elseif case == "parent getter" then parent.caption_getter = "foreign_parent"
					elseif case == "model getter" then model.caption_getter = "foreign_model"
					elseif case == "missing children" then root[sections.children] = nil
					else children[2].id = "foreign_list" end
					with_agent_system_frames(corpus.spec, {}, function(world, agent)
						helpers.assert_nil(find(agent.menu, corpus.locales.en.systems.system1.remote))
						helpers.assert_eq(world.preferences.get("llm.agent_system1"), corpus.spec)
						helpers.assert_eq(world.redraws or 0, 0)
					end)
				end)
				backend.id, backend.caption_getter, parent.caption_getter, model.caption_getter = id, getter, parent_getter, model_getter
				root[sections.children], children[2].id = children, list_id
				if not ok then error(err, 0) end
				with_agent_system_frames(corpus.spec, {}, function(_, agent)
					helpers.assert_eq(agent.menu[3].title, corpus.locales.en.systems.system1.remote)
				end)
			end)
		end)
	end

	helpers.it("hands off the actual completed rendered parent exactly once (agent-linux-system-frame)", function()
		with_system_model_locale("en", function()
			local menu = require("infra.manifest_menu")
			local render, observed = menu.render_rows, {}
			menu.render_rows = function(rows, id, ...)
				local native = render(rows, id, ...)
				if id == "agent_system1" or id == "agent_system2" then
					observed[id] = observed[id] or {}
					observed[id][#observed[id] + 1] = native[1]
				end
				return native
			end
			local ok, err = pcall(function()
				with_agent_system_frames(agent_system_frames_corpus().spec, {}, function(_, agent)
					for index, id in ipairs({ "agent_system1", "agent_system2" }) do
						helpers.assert_eq(#observed[id], 1)
						helpers.assert_true(rawequal(agent.menu[index + 2], observed[id][1]))
					end
				end)
			end)
			menu.render_rows = render
			if not ok then error(err, 0) end
		end)
	end)
end)

-- Public policy uses the actual unwrapped scenario and unchanged declaration.
helpers.describe("AI agent settings: current disabled public policy", function()
	for _, state in ipairs({ "present", "paused", "absent" }) do
		helpers.it("refuses public Agent availability with " .. state .. " engine state", function()
			with_agent_declaration(false, function(renderer, declaration)
				helpers.assert_eq(declaration.disabled, true)
				helpers.assert_eq(declaration.i18n, "menu.agent.title")
				helpers.assert_eq(declaration.reason_key, "menu.agent.not_ready")
				ActualScenario.run({ paused = state == "paused" }, function(world)
					package.loaded["ui.menu.agent_rows"], package.loaded["ui.menu.ai_parent"] = nil, nil
					local native_build, native_group = renderer.build, renderer.group_row
					local child_calls, available_groups = 0, 0
					renderer.build = function(key, ...)
						if key == "agent_menu" then child_calls = child_calls + 1 end
						return native_build(key, ...)
					end
					renderer.group_row = function(frame, id, ...)
						if id == "agent_parent_linux" then available_groups = available_groups + 1 end
						return native_group(frame, id, ...)
					end
					local context = { llm = world.engine, is_paused = function() return world.paused end,
						on_menu_changed = function() world.redraws = (world.redraws or 0) + 1 end }
					if state == "absent" then context.llm = nil end
					local native_i18n = require("infra.i18n")
					local caption, found = native_i18n.get("menu.agent.title"), nil
					for _, row in ipairs(helpers.load_module("ui.menu.menu_builder").build(context)) do
						if type(row.title) == "string" and row.title:sub(1, #caption) == caption then
							helpers.assert_nil(found, "the current public row must be unique")
							found = row
						end
					end
					helpers.assert_type(found, "table", "the disabled Agent row must remain visible")
					helpers.assert_eq(found.title, caption .. " — " .. native_i18n.get("menu.agent.not_ready"))
					helpers.assert_eq(found.disabled, true)
					helpers.assert_nil(found.menu, "public policy exposes no component submenu")
					helpers.assert_nil(found.fn, "public policy exposes no command")
					helpers.assert_eq(child_calls, 0, "public policy never builds the available Agent child")
					helpers.assert_eq(available_groups, 0, "public policy never projects an available Agent group")
					local retained
					for _, row in ipairs(renderer.get_root().top_level) do if row.id == "agent" then retained = row end end
					helpers.assert_true(rawequal(retained, declaration), "the original runner retains current public policy")
				end)
			end)
		end)
	end

	helpers.it("forwards native scenario members and restores the source after a retained-callback refusal", with_uncached_ai_parent(function()
		helpers.assert_true(rawequal(Scenario.ENTRY, ActualScenario.ENTRY))
		helpers.assert_eq(Scenario.NOW, ActualScenario.NOW)
		helpers.assert_true(rawequal(Scenario.text, ActualScenario.text))
		local renderer = require("infra.manifest_menu")
		local root, top = renderer.get_root(), renderer.get_root().top_level
		local public_agent; for _, row in ipairs(top) do if row.id == "agent" then public_agent = row end end
		local previous = {}; for name, value in pairs(package.loaded) do previous[name] = value end
		local native_build, native_group = renderer.build, renderer.group_row
		local original_getenv, original_i18n_safe = os.getenv, rawget(_G, "i18n_safe")
		local callback_executed = false
		local ok, err = pcall(function()
			Scenario.run({}, function(world)
				local rows = with_actual_ai_parent_probe(function() return build_menu(world, {}) end)
				world.restore_prompt()
				local retained = assert(find(rows, require("infra.i18n").get("menu.agent.title"))).menu[1].menu[1].fn
				helpers.assert_type(retained, "function", "the genuine mode callback is retained")
				local component_agent
				for _, row in ipairs(renderer.get_root().top_level) do if row.id == "agent" then component_agent = row end end
				helpers.assert_true(not rawequal(component_agent, public_agent), "the recorded declaration remains active through callbacks")
				helpers.assert_nil(component_agent.disabled, "the callback executes in recorded available component policy")
				helpers.assert_eq(retained(), true, "the original current owner acknowledges the retained mode command")
				callback_executed = true
				package.loaded["infra.manifest_menu"] = {}
				renderer.build = function() error("temporary component renderer") end
				os.getenv = function() return nil end; rawset(_G, "i18n_safe", function() return "temporary" end)
				error("deliberate Agent settings component refusal")
			end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("deliberate Agent settings component refusal", 1, true) ~= nil)
		helpers.assert_true(callback_executed, "the refusal follows an actual retained callback acknowledgement")
		helpers.assert_eq(component_depth, 0, "the local component scope is retired")
		helpers.assert_true(rawequal(root.top_level, top))
		local restored; for _, row in ipairs(top) do if row.id == "agent" then restored = row end end
		helpers.assert_true(rawequal(restored, public_agent))
		helpers.assert_true(rawequal(renderer.build, native_build))
		helpers.assert_true(rawequal(renderer.group_row, native_group))
		helpers.assert_true(rawequal(os.getenv, original_getenv))
		helpers.assert_true(rawequal(rawget(_G, "i18n_safe"), original_i18n_safe))
		for name, value in pairs(previous) do helpers.assert_true(rawequal(rawget(package.loaded, name), value), name) end
		for name in pairs(package.loaded) do helpers.assert_true(previous[name] ~= nil, name) end
	end))
end)
