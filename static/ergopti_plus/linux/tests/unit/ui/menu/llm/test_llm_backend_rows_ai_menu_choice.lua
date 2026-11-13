--- tests/unit/ui/menu/llm/test_llm_backend_rows_ai_menu_choice.lua

--- ==============================================================================
--- MODULE: The API Entries Of The Model Selector Page
--- DESCRIPTION:
--- The Linux AI menu listed Ollama's models and nothing else: there was no way
--- to enter an API key. The API entries, one "add" per provider, a test and a
--- removal moved to the model selector page on 2026-10-27; these cases drive
--- the page's own transactions (ui/menu/llm_backend_rows.lua api_page).
--- ==============================================================================

package.loaded["tests.support.ui.menu.llm.llm_backend_rows_fixture"] = nil
local Fixture = require("tests.support.ui.menu.llm.llm_backend_rows_fixture")
local helpers, setup, find, exact = Fixture.helpers, Fixture.setup, Fixture.find, Fixture.exact




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




helpers.describe("model selector test ownership", function()
	helpers.it("reports a refused System 1 entry removal", function()
		local build, state, restore = setup("api")
		local entry = { id = "system", provider = "typesafe", model = "jev-latest", token = "test", base_url = "" }
		state.entries, state.confirm, state.refuse_removal = { entry }, true, true
		local result = find(build(), "🗑️").action()
		local kept, errors = state.entries[1], #state.errors
		restore()
		helpers.assert_eq(result, false)
		helpers.assert_eq(kept, entry)
		helpers.assert_eq(errors, 1)
	end)

	for _, fault in ipairs({ "backend", "storage" }) do
		helpers.it("reports a refused API entry removal: " .. fault, function()
			local build, state, restore = setup("api")
			local entry = { id = "chosen", provider = "cerebras", model = "qwen", token = "test", base_url = "" }
			state.entries, state.active, state.confirm = { entry }, entry, true
			state.refuse_backend, state.refuse_removal = fault == "backend", fault == "storage"
			local result = find(build(), "🗑️").action()
			local kept, errors = state.entries[1], #state.errors
			restore()
			helpers.assert_eq(result, false)
			helpers.assert_eq(kept, entry)
			helpers.assert_eq(errors, 1)
		end)
	end

	helpers.it("retains a refused selection retirement after its page closes", function()
		local build, state, restore = setup("api")
		local live = true
		state.page_current = function() return live end
		state.on_begin = function() live = false end
		state.refuse_finish = true
		state.answers = { "test-key", "qwen" }
		find(build(), "➕ Cerebras").action()
		live, state.on_begin = true, nil
		state.answers = { "next-key", "qwen" }
		local again = find(build(), "➕ Cerebras").action()
		local admissions, entries = state.admissions, #state.entries
		restore()
		helpers.assert_eq(again, false)
		helpers.assert_eq(admissions, 1)
		helpers.assert_eq(entries, 0)
	end)

	helpers.it("retires the selection receipt if its page closes during acquisition", function()
		local build, state, restore = setup("api")
		local live = true
		state.page_current = function() return live end
		state.on_begin = function() live = false end
		state.answers = { "test-key", "qwen" }
		local result = find(build(), "➕ Cerebras").action()
		local admissions, finished, entries = state.admissions, state.finished, #state.entries
		restore()
		helpers.assert_eq(result, false)
		helpers.assert_eq(admissions, 1)
		helpers.assert_eq(finished, 1)
		helpers.assert_eq(entries, 0)
	end)

	for _, kind in ipairs({ "chat", "system" }) do
		helpers.it("does not save a " .. kind .. " API entry after its page closes during input", function()
			local build, state, restore = setup("api")
			local live = true
			state.page_current = function() return live end
			state.on_prompt = function() live = false end
			state.answers = { "test-key", kind == "chat" and "qwen" or "jev-latest" }
			find(build(), kind == "chat" and "➕ Cerebras" or "➕ TypeSafe").action()
			local count, tests = #state.entries, #state.tests
			restore()
			helpers.assert_eq(count, 0)
			helpers.assert_eq(tests, 0)
		end)
	end

	for _, kind in ipairs({ "chat", "system" }) do
		helpers.it("does not remove " .. kind .. " after the owning page closes during confirmation", function()
			local build, state, restore = setup("api")
			local entry = { id = "chosen", provider = kind == "chat" and "cerebras" or "typesafe",
				model = "qwen", token = "test", base_url = "" }
			state.entries, state.active = { entry }, kind == "chat" and entry or nil
			local live = true
			state.page_current = function() return live end
			local remove = find(build(), "🗑️").action
			state.confirm = function() live = false; return true end
			local result = remove()
			local kept, count = state.entries[1], state.removal_sets or 0
			restore()
			helpers.assert_eq(result, false)
			helpers.assert_eq(kept, entry)
			helpers.assert_eq(count, 0)
		end)
	end

	helpers.it("does not remove an active API entry replaced during confirmation", function()
		local build, state, restore = setup("api")
		local old = { id = "chosen", provider = "cerebras", model = "qwen", token = "old", base_url = "" }
		local replacement = { id = "chosen", provider = "cerebras", model = "new", token = "new", base_url = "" }
		state.entries, state.active = { old }, old
		local remove = find(build(), "🗑️").action
		state.confirm = function() state.entries, state.active = { replacement }, replacement; return true end
		local result = remove()
		local kept, count = state.entries[1], state.removal_sets or 0
		restore()
		helpers.assert_eq(result, false)
		helpers.assert_eq(kept, replacement)
		helpers.assert_eq(count, 0)
	end)

	helpers.it("does not remove a System 1 entry replaced during confirmation", function()
		local build, state, restore = setup("api")
		local old = { id = "system", provider = "typesafe", model = "jev-latest", token = "old", base_url = "" }
		local replacement = { id = "system", provider = "typesafe", model = "new", token = "new", base_url = "" }
		state.entries = { old }
		local remove = find(build(), "🗑️").action
		state.confirm = function() state.entries = { replacement }; return true end
		local result = remove()
		local kept, count = state.entries[1], state.removal_sets or 0
		restore()
		helpers.assert_eq(result, false)
		helpers.assert_eq(kept, replacement)
		helpers.assert_eq(count, 0)
	end)

	helpers.it("suppresses a System 1 test when its entry is removed", function()
		local build, state, restore = setup("api")
		local entry = { id = "system", provider = "typesafe", model = "jev-latest", token = "test", base_url = "" }
		state.entries = { entry }
		find(build(), require("infra.i18n").get("menu.llm.api_test_entry")).action()
		helpers.assert_eq(#state.tests, 1)
		state.entries = {}
		state.finish_test(true, "OK", 10)
		local notices = #state.infos + #state.errors
		restore()
		helpers.assert_eq(notices, 0)
	end)

	helpers.it("suppresses a manual test when the active entry is replaced", function()
		local build, state, restore = setup("api")
		local entry = { id = "chosen", provider = "cerebras", model = "qwen", token = "test" }
		state.entries, state.active = { entry }, entry
		find(build(), require("infra.i18n").get("menu.llm.api_test_entry")).action()
		helpers.assert_eq(#state.tests, 1)
		state.active = { id = "chosen", provider = "cerebras", model = "other", token = "test" }
		state.finish_test(true, "OK", 10)
		local notices = #state.infos + #state.errors
		restore()
		helpers.assert_eq(notices, 0)
	end)

	for _, kind in ipairs({ "new chat", "new system", "manual" }) do
		helpers.it("suppresses " .. kind .. " test results after page closure", function()
			local build, state, restore = setup("api")
			local live = true
			state.page_current = function() return live end
			if kind == "manual" then
				local entry = { id = "chosen", provider = "cerebras", model = "qwen", token = "test" }
				state.entries, state.active = { entry }, entry
				find(build(), require("infra.i18n").get("menu.llm.api_test_entry")).action()
			else
				state.answers = { "test-key", kind == "new chat" and "qwen" or "jev-latest" }
				find(build(), kind == "new chat" and "➕ Cerebras" or "➕ TypeSafe").action()
			end
			helpers.assert_eq(#state.tests, 1)
			live = false
			state.finish_test(true, "OK", 10)
			local notices = #state.infos + #state.errors
			restore()
			helpers.assert_eq(notices, 0)
		end)
	end
end)

helpers.describe("AI menu: adding and testing a Cerebras key", function()
	helpers.it("acknowledges a saved entry if the menu refresh raises", function()
		local build, state, restore = setup("api")
		state.answers = { "test-key", "qwen" }
		state.on_changed = function() error("synthetic refresh failure") end
		local ok, result = pcall(find(build(), "➕ Cerebras").action)
		local count = #state.entries
		restore()
		helpers.assert_eq(count, 1)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(result, true)
	end)

	helpers.it("acknowledges a saved entry if its optional test raises", function()
		local build, state, restore = setup("api")
		state.answers = { "test-key", "qwen" }
		package.loaded["modules.llm.api_remote"].test = function() error("synthetic test failure") end
		local ok, result = pcall(find(build(), "➕ Cerebras").action)
		local count = #state.entries
		restore()
		helpers.assert_eq(count, 1)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(result, true)
	end)

	for _, kind in ipairs({ "chat", "system" }) do
		helpers.it("acknowledges a saved " .. kind .. " entry when its test request is refused", function()
			local build, state, restore = setup("api")
			state.answers = { "test-key", kind == "chat" and "qwen" or "jev-latest" }
			package.loaded["modules.llm.api_remote"].test = function() return false end
			local result = find(build(), kind == "chat" and "➕ Cerebras" or "➕ TypeSafe").action()
			local count, changed = #state.entries, state.changed
			restore()
			helpers.assert_eq(count, 1)
			helpers.assert_eq(changed, 1)
			helpers.assert_eq(result, true)
		end)
	end

	helpers.it("does not overwrite a backend changed while entering an API key", function()
		local build, state, restore = setup("ollama")
		state.answers = { "key", "qwen" }
		state.on_prompt = function() state.backend = "other" end
		find(build(), "➕ Cerebras").action()
		local backend, switches, count = state.backend, state.backend_sets or 0, #state.entries
		restore()
		helpers.assert_eq(backend, "other")
		helpers.assert_eq(switches, 0)
		helpers.assert_eq(count, 0)
	end)

	helpers.it("does not change the backend when the API key form is cancelled", function()
		local build, state, restore = setup("ollama")
		state.answers = {}
		find(build(), "➕ Cerebras").action()
		local backend, switches = state.backend, state.backend_sets or 0
		restore()
		helpers.assert_eq(backend, "ollama")
		helpers.assert_eq(switches, 0)
	end)


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
		helpers.assert_eq(state.error_titles[1], require("infra.i18n").get("menu.llm.api_key_refused_title"),
			"a 401 proves the server answered, so the title names the refused key")
	end)

	helpers.it("titles a transport failure as unreachable", function()
		local build, state, restore = setup("api")
		state.answers = { "bad", "qwen" }
		find(build(), "➕ Cerebras").action()
		state.finish_test(false, "connection refused", 90)
		restore()
		helpers.assert_eq(state.error_titles[1], require("infra.i18n").get("menu.llm.api_unreachable_title"))
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
		remote.token_allowed = function(id, token) return require("ai.engine.local_servers.auth").token_allowed(id, token, servers) end
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
			local changed, result, after, count, active, foreign, stage_calls, backend_calls, errors = 0, nil, nil, nil, nil, nil, 0, 0, 0
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
				local rows = require("tests.support.ui.menu.llm.api_page_rows").rows(helpers.load_module("ui.menu.llm_backend_rows"),
					{ get_backend = function() return "api" end, set_backend = function(kind)
						backend_calls = backend_calls + 1
						return kind == "api"
					end },
					{ confirm = function() return true end, error = function() errors = errors + 1 end },
					function() changed = changed + 1 end)
				result = find(rows, "🗑️").action()
				local read = assert(io.open(path, "rb")); after = read:read("*a"); assert(read:close())
				count, active = #owner.list(), owner.active()
				foreign = require("core.text.engine.json").decode(after).future.kept
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
			helpers.assert_eq(errors, refused and 1 or 0, "a refused deletion reaches the user")
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
			local backend_calls, errors = 0, 0
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
				local rows = require("tests.support.ui.menu.llm.api_page_rows").rows(helpers.load_module("ui.menu.llm_backend_rows"),
					{ get_backend = function() return "api" end,
						set_backend = function(kind) backend_calls = backend_calls + 1; return kind == "api" end },
					{ error = function() errors = errors + 1 end },
					function() changes = changes + 1 end)
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
			helpers.assert_eq(errors, refused and 1 or 0, "only a refused private selection reports an error")
			helpers.assert_nil(staging, "the real writer retires its staging file")
			local retained = require("core.text.engine.json").decode(after)
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




helpers.describe("AI active API commands: live selection", function()
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




