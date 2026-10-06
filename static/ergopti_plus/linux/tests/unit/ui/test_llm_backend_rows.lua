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
			local changed, result, after, count, active, foreign, stage_calls = 0, nil, nil, nil, nil, nil, 0
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
					{ get_backend = function() return "api" end },
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
