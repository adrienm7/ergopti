--- tests/unit/ui/menu/llm/test_llm_backend_rows_shared_inert_empty.lua

--- ==============================================================================
--- MODULE: API Entry Publication From The Model Selector Page
--- DESCRIPTION:
--- Adding and removing an API entry from the model selector page (2026-10-27)
--- publishes through the one private writer: a non-chat key never selects
--- itself, an oMLX entry keeps every field, and a refused retirement removes
--- nothing (ui/menu/llm_backend_rows.lua api_page).
--- ==============================================================================

package.loaded["tests.support.ui.menu.llm.llm_backend_rows_fixture"] = nil
local Fixture = require("tests.support.ui.menu.llm.llm_backend_rows_fixture")
local helpers, setup, find, with_real_api_add = Fixture.helpers, Fixture.setup, Fixture.find, Fixture.with_real_api_add




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
				local rows = require("tests.support.ui.menu.llm.api_page_rows").rows(helpers.load_module("ui.menu.llm_backend_rows"),
					{ get_backend = function() return "api" end, set_backend = function() error("non-chat addition must preserve the backend") end },
					{ prompt = function() return table.remove(answers, 1) end, error = function() end },
					function() changes = changes + 1 end)
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
				helpers.assert_eq(state.backends, 0, "adding under API must not rewrite the backend preference")
				helpers.assert_eq(state.admissions, 1, "the runtime must admit the private publication before mutation")
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
					local message = require("infra.i18n").get("dialog.bulk_toggle.save_failed")
					helpers.assert_type(message, "string")
					helpers.assert_true(message ~= "" and message ~= "dialog.bulk_toggle.save_failed")
					helpers.assert_eq(state.errors[1], message)
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

