--- tests/unit/ui/test_llm_backend_rows.lua

--- ==============================================================================
--- MODULE: Choosing The AI Backend From The Tray
--- DESCRIPTION:
--- The Linux AI menu listed Ollama's models and nothing else: there was no way
--- to enter an API key. It now offers the backend choice and, for the API
--- backend, the entries, one "add" row per provider, a test and a removal.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the rows module over scripted collaborators.
--- @param backend string
--- @return table Rows, table state, function restore
local function setup(backend)
	local names = { "modules.llm.api_remote", "modules.llm.api_entries" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local state = { backend = backend, entries = {}, active = nil, prompts = {}, infos = {}, errors = {}, tests = {} }
	local cerebras = { id = "cerebras", label = "Cerebras", base_url = "https://api.cerebras.ai/v1", default_model = "qwen" }
	-- A provider that is no chat model: the agent's System 1 only
	local jev = { id = "typesafe", label = "TypeSafe (Jev)", base_url = "https://api.typesafe.ai/v1/systemone",
		default_model = "jev-latest" }
	local by_id = { cerebras = cerebras, typesafe = jev }
	package.loaded["modules.llm.api_remote"] = {
		providers = function() return { cerebras, jev } end,
		provider = function(id) return by_id[id] end,
		serves = function(id, use) return use ~= "chat" or id ~= "typesafe" end,
		normalize_base_url = function(url) return url end,
		test = function(entry, on_done)
			state.tests[#state.tests + 1] = entry
			state.finish_test = on_done
			return true
		end,
	}
	package.loaded["modules.llm.api_entries"] = {
		list = function() return state.entries end,
		active = function() return state.active end,
		set_active = function(id) for _, e in ipairs(state.entries) do if e.id == id then state.active = e end end return true end,
		add = function(fields)
			local entry = { id = "e" .. (#state.entries + 1), provider = fields.provider, label = fields.label,
				token = fields.token, model = fields.model, base_url = fields.base_url }
			state.entries[#state.entries + 1] = entry
			state.active = entry
			return entry
		end,
		remove = function(id)
			for index, e in ipairs(state.entries) do if e.id == id then table.remove(state.entries, index) end end
			state.active = nil
			return true
		end,
	}
	local llm = {
		get_backend = function() return state.backend end,
		get_current_model = function() return state.model end,
		set_backend = function(kind)
			state.backend = kind
			state.backend_sets = (state.backend_sets or 0) + 1
			return true
		end,
	}
	state.answers = {}
	local dialogs = {
		prompt = function(title, text, initial, hidden)
			state.prompts[#state.prompts + 1] = { title = title, text = text, initial = initial, hidden = hidden }
			return table.remove(state.answers, 1)
		end,
		error = function(text) state.errors[#state.errors + 1] = text end,
		info = function(title, text) state.infos[#state.infos + 1] = title .. " | " .. text end,
		confirm = function() return state.confirm end,
	}
	local Rows = helpers.load_module("ui.menu.llm_backend_rows")
	local function build()
		return Rows.rows(llm, dialogs, function() state.changed = (state.changed or 0) + 1 end,
			function() return { { label = "llama3" } } end)
	end
	return build, state, function()
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		package.loaded["ui.menu.llm_backend_rows"] = nil
	end
end

--- The first row whose label contains a fragment.
local function find(rows, fragment)
	for _, row in ipairs(rows) do
		if type(row.label) == "string" and row.label:find(fragment, 1, true) then return row end
		if type(row.items) == "table" then
			local nested = find(row.items, fragment)
			if nested then return nested end
		end
	end
	return nil
end

--- The row whose label is exactly `label`, at any depth.
local function exact(rows, label)
	for _, row in ipairs(rows) do
		if row.label == label then return row end
		if type(row.items) == "table" then
			local nested = exact(row.items, label)
			if nested then return nested end
		end
	end
	return nil
end

helpers.describe("AI menu: the backend choice", function()

	helpers.it("shows Ollama's models under the Ollama backend", function()
		local build, _, restore = setup("ollama")
		local rows = build()
		restore()
		helpers.assert_true(find(rows, "Ollama").checked)
		helpers.assert_true(find(rows, "llama3") ~= nil)
	end)

	helpers.it("switches to the API backend", function()
		local build, state, restore = setup("ollama")
		find(build(), "API 🌐").action()
		restore()
		helpers.assert_eq(state.backend, "api")
	end)

end)

helpers.describe("AI menu: the selected-model row (menu.llm.model_label)", function()

	local i18n = require("infra.i18n")

	--- The label every driver gives the selected model.
	--- @param model string
	--- @return string
	local function expected(model)
		local template = i18n.get("menu.llm.model_label")
		helpers.assert_true(template ~= "menu.llm.model_label" and template:find("%s", 1, true) ~= nil,
			"the shared key must resolve to a template with one %s, got: " .. tostring(template))
		return string.format(template, model)
	end

	helpers.it("heads the list with the selected Ollama model, not clickable", function()
		local build, state, restore = setup("ollama")
		state.model = "qwen3.5:0.8b"
		local rows = build()
		restore()
		helpers.assert_eq(rows[1].label, expected("qwen3.5:0.8b"))
		helpers.assert_eq(rows[1].disabled, true, "an information row, never an action")
		helpers.assert_eq(rows[1].action, nil)
	end)

	helpers.it("names the active API entry under the API backend", function()
		local build, state, restore = setup("api")
		state.answers = { "k", "qwen" }
		find(build(), "➕ Cerebras").action()
		-- A label an earlier build stored is never read (api-entry-auto-name)
		state.active.label = "Ma clé"
		local rows = build()
		restore()
		helpers.assert_eq(rows[1].label, expected("cerebras/qwen"))
	end)

	helpers.it("says so when no model is selected", function()
		local build, _, restore = setup("ollama")
		local rows = build()
		restore()
		helpers.assert_eq(rows[1].label, expected(i18n.get("menu.llm.no_model_none")))
	end)

end)

helpers.describe("AI menu: adding and testing a Cerebras key", function()

	helpers.it("asks for a hidden key and the model, stores, selects and tests the entry", function()
		local build, state, restore = setup("api")
		state.answers = { "  csk-123  ", "qwen" }
		find(build(), "➕ Cerebras").action()
		helpers.assert_true(state.prompts[1].hidden, "the key is typed into a masked field")
		helpers.assert_eq(state.prompts[2].initial, "qwen", "the model defaults to the provider's")
		helpers.assert_eq(state.entries[1].token, "csk-123", "surrounding blanks from a paste are dropped")
		helpers.assert_eq(state.entries[1].model, "", "the provider default is stored as no override")
		helpers.assert_eq(state.backend, "api")
		helpers.assert_eq(#state.tests, 1, "the new entry is tested at once")
		state.finish_test(true, "OK", 180)
		restore()
		helpers.assert_eq(#state.infos, 1)
		helpers.assert_true(state.infos[1]:find("180", 1, true) ~= nil, state.infos[1])
	end)

	helpers.it("reports a refused key with the provider's reason", function()
		local build, state, restore = setup("api")
		state.answers = { "bad", "qwen" }
		find(build(), "➕ Cerebras").action()
		state.finish_test(false, "HTTP 401: Wrong API Key", 90)
		restore()
		helpers.assert_true(state.errors[1]:find("Wrong API Key", 1, true) ~= nil)
	end)

	helpers.it("adds nothing when the key prompt is cancelled", function()
		local build, state, restore = setup("api")
		state.answers = {}
		find(build(), "➕ Cerebras").action()
		restore()
		helpers.assert_eq(#state.entries, 0)
	end)

	helpers.it("removes the selected entry only after confirmation", function()
		local build, state, restore = setup("api")
		state.answers = { "k", "qwen" }
		find(build(), "➕ Cerebras").action()
		state.confirm = false
		find(build(), "🗑️").action()
		local kept = #state.entries
		state.confirm = true
		find(build(), "🗑️").action()
		restore()
		helpers.assert_eq(kept, 1)
		helpers.assert_eq(#state.entries, 0)
	end)

end)

helpers.describe("AI menu: every API entry is named after its provider and model (api-entry-auto-name)", function()

	helpers.it("asks the key and the model, no name, and stores the automatic one", function()
		local build, state, restore = setup("api")
		state.answers = { "k", "llama" }
		find(build(), "➕ Cerebras").action()
		restore()
		helpers.assert_eq(#state.prompts, 2, "the key and the model: no name is asked")
		helpers.assert_eq(state.entries[1].label, "cerebras/llama",
			"the stored label is the automatic name, for the builds that still read it")
	end)

	helpers.it("lists provider/model, never a label an earlier build stored", function()
		local build, state, restore = setup("api")
		state.entries = {
			{ id = "a", provider = "cerebras", label = "Ma clé perso", token = "k", model = "", base_url = "" },
			{ id = "b", provider = "cerebras", label = "Autre", token = "k", model = "llama", base_url = "" },
		}
		state.active = state.entries[1]
		local rows = build()
		restore()
		helpers.assert_true(find(rows, "Ma clé") == nil, "the stored label is not shown")
		helpers.assert_true(exact(rows, "cerebras/qwen") ~= nil, "an entry without a model uses the provider's")
		helpers.assert_true(exact(rows, "cerebras/llama") ~= nil)
		helpers.assert_true(exact(rows, "cerebras/qwen").checked, "the active entry is ticked")
	end)

	helpers.it("tells two entries of one provider and model apart", function()
		local build, state, restore = setup("api")
		state.entries = {
			{ id = "a", provider = "cerebras", label = "Un", token = "k1", model = "", base_url = "" },
			{ id = "b", provider = "cerebras", label = "Deux", token = "k2", model = "", base_url = "" },
			{ id = "c", provider = "cerebras", label = "Trois", token = "k3", model = "",
				base_url = "http://localhost:8080/v1" },
		}
		local rows = build()
		restore()
		local labels = {}
		for _, row in ipairs(rows) do
			if type(row.label) == "string" and row.label:find("cerebras/", 1, true) == 1 then
				labels[#labels + 1] = row.label
			end
		end
		helpers.assert_eq(labels, {
			"cerebras/qwen (api.cerebras.ai)",
			"cerebras/qwen (api.cerebras.ai, 2)",
			"cerebras/qwen (localhost:8080)",
		})
	end)

end)

helpers.describe("AI menu: a key for the agent's System 1 only (Jev)", function()

	helpers.it("is stored and tested, but predictions keep their backend and entry", function()
		local build, state, restore = setup("api")
		state.answers = { "k", "qwen", "tsk-1", "jev-latest" }
		find(build(), "➕ Cerebras").action()
		local cerebras = state.active
		local sets = state.backend_sets
		find(build(), "➕ TypeSafe (Jev)").action()
		restore()
		helpers.assert_eq(#state.entries, 2, "the key is stored")
		helpers.assert_eq(state.entries[2].provider, "typesafe")
		helpers.assert_eq(state.active, cerebras, "the predictions' entry is still the active one")
		helpers.assert_eq(state.backend_sets, sets, "the predictions' backend is not touched")
		helpers.assert_eq(state.tests[2], state.entries[2], "the new key is tested at once")
	end)

	helpers.it("is listed with its own test and removal, never as the predictions' entry", function()
		local build, state, restore = setup("api")
		state.answers = { "tsk-1", "jev-latest" }
		find(build(), "➕ TypeSafe (Jev)").action()
		local rows = build()
		local row = exact(rows, "typesafe/jev-latest")
		helpers.assert_true(row ~= nil and row.items ~= nil, "a submenu, not a radio row")
		helpers.assert_eq(row.checked, nil, "never checked")
		helpers.assert_eq(row.action, nil, "never selected")
		row.items[1].action()
		helpers.assert_eq(#state.tests, 2, "its own test")
		state.confirm = true
		row.items[2].action()
		restore()
		helpers.assert_eq(#state.entries, 0, "its own removal")
	end)

end)
