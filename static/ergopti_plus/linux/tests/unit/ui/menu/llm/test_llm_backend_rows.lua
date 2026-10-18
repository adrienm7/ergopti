--- tests/unit/ui/menu/llm/test_llm_backend_rows.lua

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
		set_active = function(id)
			state.selection_sets = (state.selection_sets or 0) + 1
			if state.refuse_selection then return false end
			for _, e in ipairs(state.entries) do if e.id == id then state.active = e end end
			return true
		end,
		add = function(fields, select)
			local entry = { id = "e" .. (#state.entries + 1), provider = fields.provider, label = fields.label,
				token = fields.token, model = fields.model, base_url = fields.base_url }
			state.entries[#state.entries + 1] = entry
			if select ~= false then state.active = entry end
			return entry
		end,
		remove = function(id)
			state.removal_sets = (state.removal_sets or 0) + 1
			if state.refuse_removal then return false end
			for index, e in ipairs(state.entries) do if e.id == id then table.remove(state.entries, index) end end
			state.active = nil
			return true
		end,
	}
	local llm = {
		get_backend = function() return state.backend end,
		get_current_model = function() return state.model end,
		set_backend = function(kind)
			if state.refuse_backend then return false end
			state.backend = kind
			state.backend_sets = (state.backend_sets or 0) + 1
			if state.on_backend then state.on_backend() end
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
		confirm = function()
			if type(state.confirm) == "function" then return state.confirm() end
			return state.confirm
		end,
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

helpers.describe("AI menu publication acknowledgement (ai-menu-selection-ack)", function()
	helpers.it("preserves the active API entry when request retirement is refused (ai-pass2-entry)", function()
		local build, state, restore = setup("api")
		local previous = { id = "previous", provider = "cerebras", model = "previous", token = "inert" }
		local chosen = { id = "chosen", provider = "cerebras", model = "qwen", token = "inert" }
		state.entries, state.active, state.refuse_backend = { previous, chosen }, previous, true
		local result = exact(build(), "cerebras/qwen").action()
		restore()
		helpers.assert_eq(result, false)
		helpers.assert_eq(state.active, previous, "a refused runtime transition retains the previous selection")
		helpers.assert_eq(state.selection_sets or 0, 0, "the private writer is not entered")
		helpers.assert_eq(state.changed or 0, 0, "the menu announces no successful selection")
		helpers.assert_eq(#state.tests, 0, "selection cannot start a partial provider request")
	end)

	for _, backend in ipairs({ "api", "ollama" }) do
		for _, refused in ipairs({ false, true }) do
			helpers.it("(ai-menu-selection-ack) returns the backend writer acknowledgement for " .. backend .. " refusal=" .. tostring(refused), function()
				local previous = backend == "api" and "ollama" or "api"
				local build, state, restore = setup(previous)
				state.refuse_backend = refused
				local rows = build()
				local result = rows[backend == "ollama" and 2 or 3].action()
				restore()
				helpers.assert_eq(state.backend, refused and previous or backend)
				helpers.assert_eq(state.changed or 0, refused and 0 or 1)
				helpers.assert_eq(result, not refused)
			end)
		end
	end
	for _, refused in ipairs({ false, true }) do
		helpers.it("(ai-menu-selection-ack) returns the private entry writer acknowledgement refusal=" .. tostring(refused), function()
			local build, state, restore = setup("api")
			local entry = { id = "chosen", provider = "cerebras", model = "qwen", token = "inert" }
			state.entries, state.refuse_selection = { entry }, refused
			local result = exact(build(), "cerebras/qwen").action()
			restore()
			if refused then helpers.assert_nil(state.active) else helpers.assert_eq(state.active, entry) end
			helpers.assert_eq(state.selection_sets, 1)
			helpers.assert_eq(state.changed or 0, refused and 0 or 1)
			helpers.assert_eq(result, not refused)
		end)
	end
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
		helpers.assert_eq(state.entries[1].token, "  csk-123  ", "provided secret bytes remain authoritative")
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


helpers.describe("Non-chat API removal acknowledgement", function()
	for _, refused in ipairs({ false, true }) do
		helpers.it("(ai-menu-removal-ack) publishes only the non-chat private writer ACK refusal=" .. tostring(refused), function()
			local build, state, restore = setup("api")
			local entry = { id = "held", provider = "typesafe", model = "jev-latest", base_url = "", token = "inert" }
			state.entries, state.confirm, state.refuse_removal = { entry }, true, refused
			local result = exact(build(), "typesafe/jev-latest").items[2].action()
			restore()
			helpers.assert_eq(state.removal_sets, 1)
			helpers.assert_eq(#state.entries, refused and 1 or 0)
			helpers.assert_eq(state.changed or 0, refused and 0 or 1)
			helpers.assert_eq(result, not refused)
		end)
	end
	for _, answer in ipairs({ false, "yes" }) do
		helpers.it("(ai-menu-removal-ack) refuses non-Boolean confirmation " .. tostring(answer), function()
			local build, state, restore = setup("api")
			state.entries = { { id = "held", provider = "typesafe", model = "jev-latest", base_url = "", token = "inert" } }
			state.confirm = answer
			local result = exact(build(), "typesafe/jev-latest").items[2].action()
			restore()
			helpers.assert_eq(state.removal_sets or 0, 0)
			helpers.assert_eq(#state.entries, 1)
			helpers.assert_eq(state.changed or 0, 0)
			helpers.assert_eq(result, false)
		end)
	end
end)

helpers.describe("Local API optional-auth tray consumer", function()
	helpers.it("stores an explicitly empty local key and tests the selected model (local-api-optional-auth-ui)", function()
		local build, state, restore = setup("api")
		local remote = package.loaded["modules.llm.api_remote"]
		local provider = { id = "lmstudio", label = "LM Studio", base_url = "http://localhost:1234/v1", default_model = "" }
		local providers, lookup = remote.providers, remote.provider
		local _, servers = require("modules.llm.local_server_catalogue").load({})
		remote.providers = function() local list = providers(); list[#list + 1] = provider; return list end
		remote.provider = function(id) return id == provider.id and provider or lookup(id) end
		remote.token_allowed = function(id, token) return require("llm.local_server_auth").token_allowed(id, token, servers) end
		state.answers = { "", "fixture-model" }
		local action = find(build(), "➕ LM Studio")
		local ok, failure = xpcall(function() action.action() end, debug.traceback)
		restore()
		if not ok then error(failure) end
		helpers.assert_eq(#state.entries, 1)
		helpers.assert_eq(state.entries[1].token, "")
		helpers.assert_eq(state.entries[1].provider, "lmstudio")
		helpers.assert_eq(state.entries[1].model, "fixture-model")
		helpers.assert_eq(state.tests[1], state.entries[1])
		helpers.assert_eq(state.backend, "api")
		helpers.assert_eq(state.prompts[1].hidden, true)
	end)
end)

helpers.describe("AI active API commands: acknowledged private removal", function()
	for _, refused in ipairs({ true, false }) do
		helpers.it("publishes a removal only after the real private writer ACK " .. tostring(not refused), function()
			local names = { "modules.llm.api_entries", "modules.llm.api_remote", "ui.menu.llm_backend_rows" }
			local saved = {}
			for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local path = assert(os.tmpname())
			local rename = os.rename
			local original = [[{"version":1,"entries":[{"id":"chosen","provider":"cerebras","label":"old","token":"inert-key","model":"qwen","base_url":""}],"active_id":"chosen","future":{"kept":true}}]]
			local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
			local changed, result, after, count, active, foreign, stage_calls, backend_calls = 0, nil, nil, nil, nil, nil, 0, 0
			local ok, failure = pcall(function()
				local owner = helpers.load_module("modules.llm.api_entries")
				owner._set_path_for_test(path)
				package.loaded["modules.llm.api_remote"] = {
					-- The chosen provider is known; this removal does not publish a catalogue.
					provider_config_receipt = function() return { published = false, ids = { cerebras = true } } end,
					provider = function() return { default_model = "qwen", base_url = "https://example.invalid/v1" } end,
					providers = function() return {} end,
					serves = function() return true end,
					test = function() error("removal must not acquire an HTTP request") end,
				}
				os.rename = function(from, to)
					if to == path then
						stage_calls = stage_calls + 1
						if refused then return nil, "owned staged publication refused" end
					end
					return rename(from, to)
				end
				local rows = helpers.load_module("ui.menu.llm_backend_rows").rows(
					{ get_backend = function() return "api" end, set_backend = function(kind)
						backend_calls = backend_calls + 1
						return kind == "api"
					end },
					{ confirm = function() return true end },
					function() changed = changed + 1 end, function() return {} end)
				result = find(rows, "🗑️").action()
				local read = assert(io.open(path, "rb")); after = read:read("*a"); assert(read:close())
				count, active = #owner.list(), owner.active()
				foreign = require("json").decode(after).future.kept
			end)
			os.rename = rename
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			local removed = os.remove(path)
			helpers.assert_eq(ok, true, tostring(failure))
			helpers.assert_eq(removed, true)
			helpers.assert_eq(backend_calls, 1, "retire the request before entering the real private writer")
			helpers.assert_eq(stage_calls, 1, "use the actual private stage and native publication owner")
			helpers.assert_eq(changed, refused and 0 or 1, "writer refusal must not refresh as a committed mutation")
			helpers.assert_eq(result, not refused, "the menu returns only a durable ACK")
			helpers.assert_eq(count, refused and 1 or 0, "the real store rolls back RAM when publication refuses")
			helpers.assert_eq(active ~= nil, refused)
			helpers.assert_eq(foreign, true, "unknown root data survives successful removal")
			if refused then helpers.assert_eq(after, original, "refusal preserves exact source bytes") end
		end)
	end
end)

helpers.describe("AI menu selection through the private writer (ai-menu-selection-native-ack)", function()
	for _, refused in ipairs({ true, false }) do
		helpers.it("(ai-menu-selection-native-ack) preserves the actual store on refusal=" .. tostring(refused), function()
			local names = { "modules.llm.api_entries", "modules.llm.api_remote", "ui.menu.llm_backend_rows" }
			local saved = {}
			for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local path = assert(os.tmpname())
			local rename = os.rename
			local original = [[{"version":1,"entries":[{"id":"chosen","provider":"cerebras","label":"old","token":"inert-key","model":"qwen","base_url":"","future":{"retained":true}}],"active_id":"","future":{"kept":true}}]]
			local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
			local changes, stages, result, active, after, mode = 0, 0
			local backend_calls = 0
			local ok, failure = pcall(function()
				package.loaded["modules.llm.api_remote"] = {
					provider_config_receipt = function() return { published = false, ids = { cerebras = true } } end,
					provider = function() return { default_model = "qwen", base_url = "https://example.invalid/v1" } end,
					providers = function() return {} end,
					serves = function() return true end,
					test = function() error("selection must not dispatch a request") end,
				}
				local owner = helpers.load_module("modules.llm.api_entries")
				owner._set_path_for_test(path)
				os.rename = function(from, to)
					if to == path then
						stages = stages + 1
						if refused then return nil, "owned selection publication refused" end
					end
					return rename(from, to)
				end
				local rows = helpers.load_module("ui.menu.llm_backend_rows").rows(
					{ get_backend = function() return "api" end,
						set_backend = function(kind) backend_calls = backend_calls + 1; return kind == "api" end }, {},
					function() changes = changes + 1 end, function() return {} end)
				result = exact(rows, "cerebras/qwen").action()
				active = owner.active()
				local read = assert(io.open(path, "rb")); after = read:read("*a"); assert(read:close())
				local stat = assert(io.popen("stat -c %a '" .. path .. "'")); mode = stat:read("*l"); assert(stat:close())
			end)
			os.rename = rename
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			local staging = io.open(path .. ".tmp", "rb")
			if staging then staging:close() end
			assert(os.remove(path))
			helpers.assert_eq(ok, true, tostring(failure))
			helpers.assert_eq(backend_calls, 1, "request retirement is acknowledged before private publication")
			helpers.assert_eq(stages, 1)
			helpers.assert_eq(changes, refused and 0 or 1)
			helpers.assert_eq(result, not refused)
			helpers.assert_nil(staging, "the real writer retires its staging file")
			local retained = require("json").decode(after)
			helpers.assert_eq(retained.future.kept, true)
			helpers.assert_eq(retained.entries[1].future.retained, true)
			if refused then
				helpers.assert_nil(active)
				helpers.assert_eq(after, original)
			else
				helpers.assert_eq(active.id, "chosen")
				helpers.assert_eq(retained.active_id, "chosen")
				helpers.assert_eq(mode, "600")
			end
		end)
	end
end)

helpers.describe("AI active API commands: shared captions and live selection", function()
	for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it",
		"ja", "ko", "no", "nl", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("renders the actual shared command data in " .. code, function()
			local names = { "infra.i18n", "infra.manifest_menu" }
			local saved = {}
			for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local restore, observations
			local ok, failure = pcall(function()
				local path = require("infra.paths").shared("data/locales/" .. code .. ".json")
				local file = assert(io.open(path, "rb")); local raw = file:read("*a"); assert(file:close())
				local labels = require("json").decode(raw)
				package.loaded["infra.i18n"] = { get = function(key) return labels[key] or key end,
					section = function() return {} end }
				package.loaded["infra.manifest_menu"] = nil
				local renderer = require("infra.manifest_menu")
				local declaration = renderer.get_array("llm_api_active_commands")
				declaration[1].i18n = "button.cancel"
				local build, state, cleanup = setup("api"); restore = cleanup
				local entry = { id = "chosen", provider = "cerebras", model = "qwen", token = "inert" }
				state.entries, state.active = { entry }, entry
				local rows, positions = build(), {}
				for index, row in ipairs(rows) do
					if row.label == labels["button.cancel"] then positions[1] = index end
					if type(row.label) == "string" and row.label:find(labels["menu.llm.api_remove_entry"], 1, true) then positions[2] = index end
				end
				observations = { positions = positions, rows = rows }
			end)
			if restore then restore() end
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			helpers.assert_eq(ok, true, tostring(failure))
			helpers.assert_type(observations.positions[1], "number")
			helpers.assert_eq(observations.positions[2], observations.positions[1] + 1)
			helpers.assert_type(observations.rows[observations.positions[1]].action, "function")
		end)
	end
	helpers.it("a retained Test refuses a revoked active entry before native request creation", function()
		local build, state, restore = setup("api")
		local entry = { id = "chosen", provider = "cerebras", model = "qwen", token = "inert" }
		state.entries, state.active = { entry }, entry
		local held = exact(build(), require("infra.i18n").get("menu.llm.api_test_entry")).action
		state.active = nil
		local observed = held()
		restore()
		helpers.assert_eq(observed, false)
		helpers.assert_eq(#state.tests, 0)
		helpers.assert_eq(state.entries[1], entry)
	end)
	helpers.it("a selection change during confirmation refuses removal before the store owner", function()
		local build, state, restore = setup("api")
		local entry = { id = "chosen", provider = "cerebras", model = "qwen", token = "inert" }
		state.entries, state.active, state.confirm = { entry }, entry, true
		local rows = build()
		-- The actual confirmation port changes selection before returning its accepted receipt.
		state.confirm = function() state.active = nil; return true end
		local observed = find(rows, "🗑️").action()
		restore()
		helpers.assert_eq(observed, false)
		helpers.assert_eq(#state.entries, 1)
		helpers.assert_eq(state.changed, nil)
	end)
end)


--- Holds the genuine translator/backend/renderer cohort without persisting a locale.
local function with_api_add_locale(scenario)
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
		helpers.assert_eq(native.scope_apply(owner, receipt, "en"), true)
		helpers.assert_eq(native.get_locale(), "en")
		helpers.assert_eq(require("infra.locale").current_locale(), "en")
		scenario(native)
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	for _, name in ipairs(names) do helpers.assert_eq(rawequal(package.loaded[name], previous[name]), true, name) end
	helpers.assert_eq(restored, true, "the genuine runtime inverse restores its previous locale")
	helpers.assert_eq(released, true, "the temporary locale owner is released on every exit")
	helpers.assert_eq(forgotten, true, "the temporary locale receipt is forgotten on every exit")
	if not ok then error(err, 0) end
end

--- Exercises the real tray provider over the handwritten shared frame.
local function with_api_add_frame(scenario)
	local path = require("infra.paths").shared("tests/corpus/menus/api_add_controls.json")
	local file = assert(io.open(path, "rb")); local raw = file:read("*a"); assert(file:close())
	local corpus = assert(require("json").decode(raw))
	with_api_add_locale(function()
		local restore
		local ok, err = pcall(function()
			local menu = require("infra.manifest_menu")
			local build, state, cleanup = setup("api"); restore = cleanup
			scenario(corpus, menu, build, state)
		end)
		if restore then restore() end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Shared API Add frame (api-add-controls)", function()
	helpers.it("uses the shared Add caption and preserves the native cancelled prompt (api-add-controls)", function()
		with_api_add_frame(function(corpus, menu, build, state)
			local declaration = menu.get_array(corpus.group_section)[1]
			local original = declaration.i18n
			local observations
			local ok, err = pcall(function()
				helpers.assert_not_nil(exact(build(), corpus.label))
				declaration.i18n = corpus.mutated_key
				local row = exact(build(), corpus.mutated_label)
				helpers.assert_not_nil(row)
				row.items[1].action()
				observations = { entries = #state.entries, prompts = #state.prompts,
					changed = state.changed or 0, probes = #state.tests }
			end)
			declaration.i18n = original
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(observations, { entries = 0, prompts = 1, changed = 0, probes = 0 })
		end)
	end)
	helpers.it("uses the shared preceding separator and refuses an unowned Add group (api-add-controls)", function()
		with_api_add_frame(function(corpus, menu, build, state)
			local separator = menu.get_array(corpus.separator_section)
			local group = menu.get_array(corpus.group_section)[1]
			local original, identity = separator[1], group.id
			local observations
			local ok, err = pcall(function()
				separator[1] = { type = "label", id = "api_add_marker", i18n = corpus.mutated_key }
				local rows = build()
				local position
				for index, row in ipairs(rows) do if row.label == corpus.label then position = index end end
				helpers.assert_type(position, "number")
				observations = rows[position - 1]
				group.id = "unowned_api_add"
				helpers.assert_eq(#build(), 0, "shared missing child owner refuses before native effects")
				helpers.assert_eq(#state.entries, 0)
				helpers.assert_eq(#state.prompts, 0)
			end)
			separator[1], group.id = original, identity
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(observations.label, corpus.mutated_label)
			helpers.assert_eq(observations.disabled, true)
			helpers.assert_nil(observations.action)
		end)
	end)
end)

helpers.describe("API Add locale scope failure inverse (api-add-controls)", function()
	helpers.it("restores the actual prior locale cohort after a raised case (api-add-controls)", function()
		local names = { "infra.i18n", "infra.locale", "locale.core", "infra.manifest_menu" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local raised = {}
		local ok, err = pcall(function()
			with_api_add_locale(function(native)
				helpers.assert_eq(native.get("menu.llm.api_add_entry"), "+ Add an API")
				error(raised, 0)
			end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(rawequal(err, raised), true)
		for _, name in ipairs(names) do helpers.assert_eq(rawequal(package.loaded[name], previous[name]), true, name) end
	end)
end)


--- The backend boundary is a presentation row; macOS never allocates it.
local function backend_boundary_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/backend_choice_boundary.json"), "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("json").decode(raw))
end

helpers.describe("Shared backend-choice boundary (backend-choice-boundary)", function()
	helpers.it("uses the canonical boundary and retains the real backend callback (backend-choice-boundary)", function()
		with_api_add_locale(function()
			local corpus = backend_boundary_corpus()
			local menu = require("infra.manifest_menu")
			local frame = menu.get_array(corpus.section)
			local original = frame[1]
			local build, state, restore = setup("api")
			local observed
			local ok, err = pcall(function()
				local rows = build()
				helpers.assert_eq(rows[4], corpus.platform_rows.linux[1])
				frame[1] = { type = "label", id = "backend_boundary_marker", i18n = corpus.marker_key,
					platforms = { "ahk", "linux" }, unavailable = "hide" }
				rows = build()
				observed = rows[4]
				helpers.assert_eq(rows[2].label, "Ollama 🦙 — " .. corpus.linux_choice_english[1])
				helpers.assert_eq(rows[3].label, "API 🌐 — " .. corpus.linux_choice_english[2])
				helpers.assert_eq(rows[3].checked, true)
				helpers.assert_eq(state.backend, "api")
				helpers.assert_eq(state.changed, nil)
				rows[2].action()
				helpers.assert_eq(state.backend, "ollama")
				helpers.assert_eq(state.backend_sets, 1)
				helpers.assert_eq(state.changed, 1)
			end)
			frame[1] = original
			restore()
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(observed.label, corpus.marker_english)
			helpers.assert_eq(observed.disabled, true)
			helpers.assert_nil(observed.action)
		end)
	end)
	helpers.it("refuses an unowned boundary before any native control effects (backend-choice-boundary)", function()
		with_api_add_locale(function()
			local corpus = backend_boundary_corpus()
			local frame = require("infra.manifest_menu").get_array(corpus.section)
			local original = frame[1]
			local build, state, restore = setup("ollama")
			local observed
			local ok, err = pcall(function()
				frame[1] = { type = "command", id = "unowned_backend_boundary", i18n = corpus.marker_key,
					platforms = { "ahk", "linux" }, unavailable = "hide" }
				observed = build()
			end)
			frame[1] = original
			restore()
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(observed, {})
			helpers.assert_eq(state.backend, "ollama")
			helpers.assert_eq(state.backend_sets, nil)
			helpers.assert_eq(state.changed, nil)
			helpers.assert_eq(#state.prompts, 0)
			helpers.assert_eq(#state.tests, 0)
		end)
	end)
	helpers.it("projects the hand boundary on three platforms with genuine macOS absence (backend-choice-boundary)", function()
		with_api_add_locale(function(native)
			local corpus = backend_boundary_corpus()
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({
					platform = platform,
					manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
					json_decode = require("json").decode,
					i18n = native,
					logger = require("logger.shim"),
				}))
				helpers.assert_eq(renderer.template_rows(corpus.section, {}, {}, {}), corpus.platform_rows[platform])
			end
		end)
	end)
end)


--- Builds the native API rows over a genuine private empty entries source.
local function with_empty_api_owner(scenario)
	local previous = {}
	for name, value in pairs(package.loaded) do previous[name] = value end
	local path = assert(os.tmpname())
	local image = '{"version":1,"active_id":"","entries":[]}\n'
	local file = assert(io.open(path, "wb")); assert(file:write(image)); assert(file:close())
	local ok, err = pcall(function()
		for _, name in ipairs({ "modules.llm.api_remote", "modules.llm.api_entries", "ui.menu.llm_backend_rows" }) do
			package.loaded[name] = nil
		end
		with_api_add_locale(function(native)
			local entries = require("modules.llm.api_entries")
			entries._set_path_for_test(path)
			helpers.assert_eq(entries.list(), {})
			helpers.assert_nil(entries.active())
			local observations = { prompts = 0, changes = 0, sets = 0 }
			local llm = { get_backend = function() return "api" end, get_current_model = function() return nil end,
				set_backend = function() observations.sets = observations.sets + 1; return true end }
			local dialogs = { prompt = function() observations.prompts = observations.prompts + 1; return nil end,
				error = function() error("empty status must not open an error") end,
				info = function() error("empty status must not open a notice") end }
			local rows = require("ui.menu.llm_backend_rows")
			local function build()
				return rows.rows(llm, dialogs, function() observations.changes = observations.changes + 1 end,
					function() error("the API status must not query Ollama rows") end)
			end
			scenario(build, require("infra.manifest_menu"), native, observations)
		end)
	end)
	local check = assert(io.open(path, "rb")); local retained = check:read("*a"); assert(check:close())
	local quarantined = io.open(path .. ".corrupt", "rb")
	if quarantined then quarantined:close() end
	assert(os.remove(path))
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	for name, value in pairs(previous) do helpers.assert_eq(rawequal(package.loaded[name], value), true, name) end
	helpers.assert_eq(retained, image, "the genuine empty source stays byte-exact")
	helpers.assert_nil(quarantined, "the valid private source is never quarantined")
	if not ok then error(err, 0) end
end

--- The two empty states are independent inert labels, not selectable NoModel controls.
local function empty_status_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/llm_empty_status.json"), "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("json").decode(raw))
end

helpers.describe("Shared inert empty API status (llm-empty-status)", function()
	helpers.it("uses the actual private empty source and canonical inert label (llm-empty-status)", function()
		with_empty_api_owner(function(build, menu, native, observations)
			local corpus = empty_status_corpus()
			local definition = menu.get_array(corpus.api.section)
			local original = definition[1]
			local ok, err = pcall(function()
				local rows = build()
				helpers.assert_eq(rows[5], corpus.api.platform_rows.linux[1])
				helpers.assert_eq(rows[6].separator, true)
				helpers.assert_eq(rows[7].label, corpus.add_english)
				helpers.assert_type(rows[7].items[1].action, "function")
				definition[1] = { type = "label", id = corpus.api.rows[1].id, i18n = corpus.marker_key,
					platforms = { "ahk", "linux" }, unavailable = "hide" }
				local marker = build()[5]
				helpers.assert_eq(marker.label, corpus.marker_english)
				helpers.assert_eq(marker.disabled, true)
				helpers.assert_nil(marker.action)
				helpers.assert_nil(marker.items)
				rows[7].items[1].action()
				helpers.assert_eq(observations, { prompts = 1, changes = 0, sets = 0 })
			end)
			definition[1] = original
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(native.get(corpus.api.key), corpus.api.english)
		end)
	end)
	helpers.it("refuses missing or unbound status admission and repairs the original owner (llm-empty-status)", function()
		with_empty_api_owner(function(build, menu, _, observations)
			local corpus = empty_status_corpus()
			local definition = menu.get_array(corpus.api.section)
			local original = definition[1]
			local ok, err = pcall(function()
				definition[1] = nil
				helpers.assert_eq(build(), {})
				definition[1] = { type = "command", id = "unowned_api_empty", i18n = corpus.api.key,
					platforms = { "ahk", "linux" }, unavailable = "hide" }
				helpers.assert_eq(build(), {})
				helpers.assert_eq(observations, { prompts = 0, changes = 0, sets = 0 })
			end)
			definition[1] = original
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(build()[5], corpus.api.platform_rows.linux[1])
		end)
	end)
	helpers.it("replays both hand fragments with the genuine three-platform renderer (llm-empty-status)", function()
		with_api_add_locale(function(native)
			local corpus = empty_status_corpus()
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({ platform = platform,
					manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
					json_decode = require("json").decode, i18n = native, logger = require("logger.shim") }))
				for _, status in ipairs({ corpus.api, corpus.agent }) do
					helpers.assert_eq(renderer.template_rows(status.section, {}, {}, {}), status.platform_rows[platform])
				end
			end
		end)
	end)
	helpers.it("restores actual source and module owners after a raised scenario (llm-empty-status)", function()
		local raised = {}
		local ok, err = pcall(function()
			with_empty_api_owner(function() error(raised, 0) end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(rawequal(err, raised), true)
	end)
end)

helpers.describe("Atomic non-chat addition (ai-menu-nonchat-add)", function()
	for _, chosen in ipairs({ false, true }) do
		helpers.it("(ai-menu-nonchat-add) never restores selection with a second write chosen=" .. tostring(chosen), function()
			local build, state, restore = setup("api")
			local previous = { id = "chosen", provider = "cerebras", model = "qwen", token = "inert" }
			if chosen then state.entries, state.active = { previous }, previous end
			state.answers, state.refuse_selection = { "inert-key", "jev-latest" }, true
			find(build(), "➕ TypeSafe (Jev)").action()
			restore()
			helpers.assert_eq(state.selection_sets or 0, 0, "non-chat creation must publish without selecting")
			helpers.assert_eq(state.active, chosen and previous or nil)
			helpers.assert_eq(#state.tests, 1)
			helpers.assert_eq(state.changed, 1)
		end)
	end
	for _, refused in ipairs({ false, true }) do
		helpers.it("(ai-menu-nonchat-add) uses one actual private publication refusal=" .. tostring(refused), function()
			local names = { "modules.llm.api_entries", "modules.llm.api_remote", "ui.menu.llm_backend_rows" }
			local saved = {}
			for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			local path, rename = assert(os.tmpname()), os.rename
			local original = [[{"version":1,"entries":[{"id":"chosen","provider":"cerebras","label":"old","token":"inert","model":"qwen","base_url":"","future":{"retained":true}}],"active_id":"chosen","future":{"kept":true}}]]
			local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
			local stages, changes, probes, active, count, after = 0, 0, 0
			local ok, failure = pcall(function()
				local provider = { id = "typesafe", label = "TypeSafe (Jev)", base_url = "https://example.invalid/v1", default_model = "jev-latest" }
				package.loaded["modules.llm.api_remote"] = {
					provider_config_receipt = function() return { published = false, ids = { cerebras = true, typesafe = true } } end,
					provider = function() return provider end,
					providers = function() return { provider } end,
					serves = function(id) return id ~= "typesafe" end,
					test = function() probes = probes + 1; return true end,
				}
				local owner = helpers.load_module("modules.llm.api_entries"); owner._set_path_for_test(path)
				os.rename = function(from, to)
					if to == path then
						stages = stages + 1
						if refused or stages > 1 then return nil, "private publication refused" end
					end
					return rename(from, to)
				end
				local answers = { "inert-key", "jev-latest" }
				local rows = helpers.load_module("ui.menu.llm_backend_rows").rows(
					{ get_backend = function() return "api" end, set_backend = function() error("non-chat addition must preserve the backend") end },
					{ prompt = function() return table.remove(answers, 1) end, error = function() end },
					function() changes = changes + 1 end, function() return {} end)
				find(rows, "➕ TypeSafe (Jev)").action()
				active, count = owner.active(), #owner.list()
				local read = assert(io.open(path, "rb")); after = read:read("*a"); assert(read:close())
			end)
			os.rename = rename
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
			assert(os.remove(path))
			helpers.assert_eq(ok, true, tostring(failure))
			helpers.assert_eq(stages, 1)
			helpers.assert_eq(active.id, "chosen", "RAM selection survives both outcomes")
			helpers.assert_eq(count, refused and 1 or 2)
			helpers.assert_eq(changes, refused and 0 or 1)
			helpers.assert_eq(probes, refused and 0 or 1)
			if refused then helpers.assert_eq(after, original) end
			local image = require("json").decode(after)
			helpers.assert_eq(image.active_id, "chosen", "durable selection never changes")
			helpers.assert_eq(image.future.kept, true)
			helpers.assert_eq(image.entries[1].future.retained, true)
		end)
	end
end)

--- Runs actual menu/catalogue/private storage/request code over authored dialogs and HTTP.
--- @param provider_id string
--- @param scenario string
--- @param body function
local function with_real_api_add(provider_id, scenario, body)
	local names = { "modules.llm.api_entries", "modules.llm.api_remote", "ui.menu.llm_backend_rows", "adapters.http_client" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local path, rename = assert(os.tmpname()), os.rename
	local original = [[{"version":1,"entries":[{"id":"chosen","provider":"openai","label":"old","token":"inert-old","model":"old-model","base_url":"","future":{"kept":true}},{"id":"foreign","provider":"future-private-provider","label":"future","token":"inert-foreign","opaque":{"kept":17}}],"active_id":"chosen","foreign_personal":{"kept":"unchanged"}}]]
	if scenario == "unknown-source" then original = original:gsub('"version":1', '"version":2', 1) end
	local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
	local state = { prompts = {}, errors = {}, infos = {}, requests = {}, changes = 0, backends = 0, stages = 0 }
	local ok, failure = xpcall(function()
		package.loaded["adapters.http_client"] = {
			post = function(url, headers, payload, done)
				state.requests[#state.requests + 1] = { url = url, headers = headers, payload = payload }
				state.done = done
				return true
			end,
			cancel = function() return true end,
		}
		local remote = helpers.load_module("modules.llm.api_remote")
		local provider = assert(remote.provider(provider_id), "the actual shipped provider must exist")
		local entries = helpers.load_module("modules.llm.api_entries"); entries._set_path_for_test(path)
		os.rename = function(from, to)
			if to == path then
				state.stages = state.stages + 1
				if scenario == "refused" then return nil, "authored publication refusal" end
			end
			return rename(from, to)
		end
		local answers = { "http://127.0.0.1:8000/v1", "  inert-private-key  ", "omlx-fixture-model" }
		if scenario == "default-url" then answers[1] = provider.base_url end
		if scenario == "no-auth-local" or scenario == "http-refused" then
			answers[1], answers[2] = "http://127.0.0.1:8502/v1", ""
		elseif scenario == "remote-empty-key" then
			answers[1], answers[2] = "https://example.invalid/v1", ""
		end
		local cancel = { ["cancel-url"] = 1, ["cancel-key"] = 2, ["cancel-model"] = 3 }
		local dialogs = {
			prompt = function(title, text, initial, hidden)
				local index = #state.prompts + 1
				state.prompts[index] = { title = title, text = text, initial = initial, hidden = hidden }
				if cancel[scenario] == index then return nil end
				return answers[index]
			end,
			error = function(text) state.errors[#state.errors + 1] = text end,
			info = function(_, text) state.infos[#state.infos + 1] = text end,
		}
		local llm = { get_backend = function() return "api" end,
			set_backend = function(kind) state.backends = state.backends + 1; return kind == "api" end }
		local Rows = helpers.load_module("ui.menu.llm_backend_rows")
		local function changed() state.changes = state.changes + 1 end
		local rows = Rows.rows(llm, dialogs, changed, function() return {} end)
		assert(exact(rows, "➕ " .. provider.label), "the actual Add action must be present").action()
		state.entry, state.list = entries.active(), entries.list()
		local handle = assert(io.open(path, "rb")); state.bytes = handle:read("*a"); assert(handle:close())
		state.image = require("json").decode(state.bytes)
		if state.done then
			if scenario == "http-refused" then
				state.done({ ok = false, status = 401, error_body = '{"error":{"message":"inert key required"}}' })
			else state.done({ ok = true, body = '{"choices":[{"message":{"content":"fixture answer"}}]}' }) end
		end
		state.rows = Rows.rows(llm, dialogs, changed, function() return {} end)
		body(state, original, provider)
	end, debug.traceback)
	os.rename = rename
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	os.remove(path .. ".tmp"); os.remove(path)
	if not ok then error(failure, 0) end
end

helpers.describe("Real API Add publication (api-add-real-publication)", function()
	for _, provider_id in ipairs({ "openai", "openai_compat" }) do
		helpers.it("(api-add-real-publication) persists every supplied oMLX field and emits one actual request for " .. provider_id, function()
			with_real_api_add(provider_id, "accepted", function(state, _, provider)
				helpers.assert_eq(#state.prompts, 3)
				helpers.assert_eq(state.prompts[1].initial, provider.base_url)
				helpers.assert_eq(state.prompts[2].hidden, true)
				helpers.assert_eq(state.prompts[3].initial, provider.default_model)
				helpers.assert_eq(state.entry.provider, provider_id)
				helpers.assert_eq(state.entry.base_url, "http://127.0.0.1:8000/v1")
				helpers.assert_eq(state.entry.token, "  inert-private-key  ")
				helpers.assert_eq(state.entry.model, "omlx-fixture-model")
				helpers.assert_eq(state.image.active_id, state.entry.id)
				helpers.assert_eq(state.image.entries[3].id, state.entry.id)
				helpers.assert_eq(state.image.entries[1].future.kept, true)
				helpers.assert_eq(state.image.entries[2].opaque.kept, 17)
				helpers.assert_eq(state.image.foreign_personal.kept, "unchanged")
				helpers.assert_eq(state.stages, 1)
				helpers.assert_eq(state.changes, 1)
				helpers.assert_eq(state.backends, 1)
				helpers.assert_eq(#state.requests, 1)
				helpers.assert_eq(state.requests[1].url, "http://127.0.0.1:8000/v1/chat/completions")
				helpers.assert_eq(state.requests[1].headers.Authorization, "Bearer   inert-private-key  ")
				helpers.assert_eq(require("json").decode(state.requests[1].payload).model, "omlx-fixture-model")
				helpers.assert_eq(#state.errors, 0)
				helpers.assert_eq(#state.infos, 1)
				helpers.assert_contains(state.infos[1], "fixture answer")
				helpers.assert_not_nil(find(state.rows, provider_id .. "/omlx-fixture-model"))
			end)
		end)
		for _, scenario in ipairs({ "no-auth-local", "http-refused" }) do
			helpers.it("(api-add-real-publication) preserves explicit local blank auth and truthful response " .. provider_id .. " " .. scenario, function()
				with_real_api_add(provider_id, scenario, function(state)
					helpers.assert_eq(state.entry.token, "")
					helpers.assert_eq(state.image.entries[3].token, "")
					helpers.assert_eq(state.entry.base_url, "http://127.0.0.1:8502/v1")
					helpers.assert_eq(#state.requests, 1)
					helpers.assert_eq(state.requests[1].url, "http://127.0.0.1:8502/v1/chat/completions")
					helpers.assert_eq(state.requests[1].headers.Authorization, nil, "an optional blank key must not invent a secret")
					helpers.assert_eq(#state.errors, scenario == "http-refused" and 1 or 0)
					helpers.assert_eq(#state.infos, scenario == "http-refused" and 0 or 1)
					if scenario == "http-refused" then
						helpers.assert_contains(state.errors[1], "HTTP 401")
						helpers.assert_contains(state.errors[1], "inert key required")
					end
				end)
			end)
		end
		helpers.it("(api-add-real-publication) keeps nonlocal empty-key refusal " .. provider_id, function()
			with_real_api_add(provider_id, "remote-empty-key", function(state, original)
				helpers.assert_eq(state.bytes, original)
				helpers.assert_eq(state.stages, 0)
				helpers.assert_eq(#state.requests, 0)
				helpers.assert_eq(state.changes, 0)
			end)
		end)

		for _, scenario in ipairs({ "refused", "unknown-source" }) do
			helpers.it("(api-add-real-publication) reports actual persistence refusal " .. provider_id .. " " .. scenario, function()
				with_real_api_add(provider_id, scenario, function(state, original)
					helpers.assert_eq(state.bytes, original, "a refused publication cannot rewrite personal data")
					helpers.assert_eq(state.changes, 0)
					helpers.assert_eq(state.backends, 0)
					helpers.assert_eq(#state.requests, 0)
					helpers.assert_eq(#state.errors, 1, "the actual failed persistence is visible to the user")
					helpers.assert_contains(state.errors[1], "saved")
					helpers.assert_eq(state.image.active_id, "chosen")
				end)
			end)
		end
		for _, scenario in ipairs({ "cancel-url", "cancel-key", "cancel-model" }) do
			helpers.it("(api-add-real-publication) cancels without publication " .. provider_id .. " " .. scenario, function()
				with_real_api_add(provider_id, scenario, function(state, original)
					helpers.assert_eq(state.bytes, original)
					helpers.assert_eq(state.stages, 0)
					helpers.assert_eq(state.changes, 0)
					helpers.assert_eq(state.backends, 0)
					helpers.assert_eq(#state.requests, 0)
					helpers.assert_eq(#state.errors, 0)
				end)
			end)
		end
	end
	helpers.it("(api-add-real-publication) retains the official OpenAI URL when the prefilled field is accepted", function()
		with_real_api_add("openai", "default-url", function(state, _, provider)
			helpers.assert_eq(provider.base_url, "https://api.openai.com/v1")
			helpers.assert_eq(state.entry.base_url, provider.base_url)
			helpers.assert_eq(state.requests[1].url, "https://api.openai.com/v1/chat/completions")
		end)
	end)
end)

helpers.describe("active API removal retirement acknowledgement", function()
	for _, fault in ipairs({ "refused", "reentrant" }) do
		helpers.it("ai-pass2-remove preserves entries when retirement is " .. fault, function()
			local build, state, restore = setup("api")
			local original = { id = "original", provider = "cerebras", model = "qwen", token = "inert" }
			local replacement = { id = "replacement", provider = "cerebras", model = "replacement", token = "inert" }
			state.entries, state.active, state.confirm = { original }, original, true
			if fault == "refused" then state.refuse_backend = true
			else state.on_backend = function() state.active = replacement end end
			local result = find(build(), "🗑️").action()
			restore()
			helpers.assert_eq(result, false)
			helpers.assert_eq(state.removal_sets or 0, 0, "no private deletion before exact retirement ACK")
			helpers.assert_eq(state.changed or 0, 0, "no false deletion announcement")
			helpers.assert_eq(#state.entries, 1)
			helpers.assert_eq(#state.tests, 0, "retirement cannot start a provider probe")
			helpers.assert_eq(state.active, fault == "refused" and original or replacement)
		end)
	end
end)
