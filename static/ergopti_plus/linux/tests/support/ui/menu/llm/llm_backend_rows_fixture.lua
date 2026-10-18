--- tests/support/ui/menu/llm/llm_backend_rows_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_llm_backend_rows
--- DESCRIPTION:
--- Prelude shared by the test_llm_backend_rows_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Supplies the mandatory private runtime admission port for scripted menu tests.
--- Real gate/source/rollback ownership is exercised by test_api_add_admission.
--- @param llm table Scripted backend selection owner.
--- @param state table Observable fixture state.
local function add_admission_port(llm, state)
	local receipts, active, generation = setmetatable({}, { __mode = "k" }), nil, 0
	llm.begin_api_selection = function()
		if active or state.refuse_backend or llm.get_backend() ~= "api" then return nil end
		generation = generation + 1
		state.admissions = (state.admissions or 0) + 1
		local receipt = {}
		receipts[receipt] = { generation = generation }
		active = receipt
		return receipt
	end
	llm.api_selection_is_current = function(receipt, source_current)
		local held = receipts[receipt]
		if source_current ~= nil and source_current() ~= true then return false end
		return held ~= nil and held.generation == generation and llm.get_backend() == "api"
			and (active == receipt or held.published == true)
	end
	llm.finish_api_selection = function(receipt, committed, settled)
		local held = receipts[receipt]
		if not held or active ~= receipt or settled ~= true then return false end
		active = nil
		if committed then held.published = true else receipts[receipt] = nil end
		return true
	end
end

--- Loads the rows module over scripted collaborators.
--- @param backend string
--- @return table Rows, table state, function restore
local function setup(backend)
	local names = { "modules.llm.api_remote", "modules.llm.api_entries" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local state = { backend = backend, entries = {}, active = nil, prompts = {}, infos = {}, errors = {}, tests = {} }
	local sources, source_generation = setmetatable({}, { __mode = "k" }), 0
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
			source_generation = source_generation + 1
			return true
		end,
		add = function(fields, select, admit)
			if admit and admit() ~= true then return nil, "scripted admission refused", true end
			local entry = { id = "e" .. (#state.entries + 1), provider = fields.provider, label = fields.label,
				token = fields.token, model = fields.model, base_url = fields.base_url }
			state.entries[#state.entries + 1] = entry
			if select ~= false then state.active = entry end
			source_generation = source_generation + 1
			local receipt = {}; sources[receipt] = source_generation
			return entry, nil, true, receipt
		end,
		source_is_current = function(receipt) return sources[receipt] == source_generation end,
		remove = function(id)
			state.removal_sets = (state.removal_sets or 0) + 1
			if state.refuse_removal then return false end
			for index, e in ipairs(state.entries) do if e.id == id then table.remove(state.entries, index) end end
			state.active = nil
			source_generation = source_generation + 1
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
	add_admission_port(llm, state)
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

--- The backend boundary is a presentation row; macOS never allocates it.
local function backend_boundary_corpus()
	local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/backend_choice_boundary.json"), "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("json").decode(raw))
end

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
		add_admission_port(llm, state)
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

return {
	helpers = helpers,
	setup = setup,
	find = find,
	exact = exact,
	with_api_add_locale = with_api_add_locale,
	with_api_add_frame = with_api_add_frame,
	backend_boundary_corpus = backend_boundary_corpus,
	with_empty_api_owner = with_empty_api_owner,
	empty_status_corpus = empty_status_corpus,
	with_real_api_add = with_real_api_add,
}
