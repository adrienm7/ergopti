--- tests/unit/modules/llm/test_local_openai_backends.lua

--- ==============================================================================
--- MODULE: Local OpenAI-Compatible Servers (macOS)
--- DESCRIPTION:
--- Drives the real catalogue (_shared/modules/llm/local_servers.json), the
--- detection (modules/llm/local_servers.lua), the remote backend that sends
--- their requests (modules/llm/api_remote.lua), the API entry persistence
--- (modules/llm/init.lua) and the AI menus (local_server_panel, agent_panel),
--- with the HTTP transport, the settings store and the dialogs faked:
--- - each server is a keyless provider of the openai format, outside the
---   remote catalogue's order, serving every use of provider_uses;
--- - a sweep lists only the servers whose models endpoint answers, with their
---   models, and a 401 as a server that wants a key;
--- - predictions and agent requests take the OpenAI chat shape with no key;
--- - a chosen model is stored as a keyless API entry that reads back;
--- - a failure is classified and reported once to the menu, which offers the fix.
---
--- ROOT CAUSE ENCODED:
--- The AI menu offered Ollama and MLX, which it installs, and remote
--- providers that need a key. A server the user already runs (oMLX, LM Studio,
--- llama.cpp, Jan) could not be chosen: none was detected, and every API entry
--- had to carry a key.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SERVERS = { "omlx", "lmstudio", "llamacpp", "jan" }

--- Reads a shared JSON file.
--- @param relative string Path under _shared/.
--- @return table decoded
local function read_json(relative)
	local fh = assert(io.open(helpers.shared(relative), "r"), "cannot open " .. relative)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw))
end

--- Returns one named closure upvalue.
--- @param fn function
--- @param target string
--- @return any value
local function get_upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

--- A models answer.
--- @param ids table Model ids.
--- @return table response
local function models_answer(ids)
	local data = {}
	for index, id in ipairs(ids) do data[index] = { id = id, object = "model" } end
	return { ok = true, status = 200, body = json.encode({ object = "list", data = data }), headers = {} }
end

--- A chat completion answer.
--- @param content string
--- @return table response
local function completion_answer(content)
	return { ok = true, status = 200, headers = {}, body = json.encode({
		choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
	}) }
end

--- Runs a scenario over a fresh remote backend and fresh detection, with the
--- probe, inference and agent HTTP clients faked.
--- @param scenario function Receives (api, LocalServers, world).
local function with_backend(scenario)
	helpers.with_fresh_modules({ "modules.llm.local_servers", "modules.llm.api_remote" }, function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local LocalServers = require("modules.llm.local_servers")
		local world = { probes = {}, posts = {} }
		local probe_clients = get_upvalue(api.detect_local_servers, "_local_probe_clients")
		assert(type(probe_clients) == "table", "the probe clients must be reachable")
		for _, id in ipairs(LocalServers.ORDER) do
			probe_clients[id] = {
				get = function(url, headers, callback)
					world.probes[#world.probes + 1] = { id = id, url = url, headers = headers, callback = callback }
					return true
				end,
			}
		end
		for _, name in ipairs({ "_infer_client", "_vision_client" }) do
			local client = get_upvalue(name == "_infer_client" and api.cancel_streaming or api.request_chat, name)
			assert(type(client) == "table", name .. " must be reachable")
			client.post = function(url, headers, body, callback)
				world.posts[#world.posts + 1] = {
					client = name, url = url, headers = headers, body = json.decode(body), callback = callback,
				}
				return true
			end
		end
		--- The last probe of one server.
		function world.probe(id)
			for index = #world.probes, 1, -1 do
				if world.probes[index].id == id then return world.probes[index] end
			end
			return nil
		end
		scenario(api, LocalServers, world)
	end)
end

--- Answers the probes of the last sweep: every server not named is down.
--- @param world table
--- @param answers table Server id -> response.
local function answer_sweep(world, answers)
	for _, id in ipairs(SERVERS) do
		world.probe(id).callback(answers[id] or { ok = false, status = 0, error = "connection refused" })
	end
end




-- =====================================
-- =====================================
-- ======= 1/ Catalogue ================
-- =====================================
-- =====================================

helpers.describe("Local OpenAI-compatible servers: catalogue (local-openai-backends)", function()
	helpers.it("lists oMLX, LM Studio, llama.cpp / LocalAI and Jan at their documented ports (local-openai-backends)",
		function()
			local catalogue = read_json("modules/llm/local_servers.json")
			helpers.assert_eq(table.concat(catalogue.server_order, ","), table.concat(SERVERS, ","))
			local expected = {
				omlx = "http://localhost:8000/v1", lmstudio = "http://localhost:1234/v1",
				llamacpp = "http://localhost:8080/v1", jan = "http://localhost:1337/v1",
			}
			local providers = read_json("modules/llm/api_providers.json").providers
			for id, base_url in pairs(expected) do
				helpers.assert_eq(catalogue.servers[id].base_url, base_url, id .. " default address")
				helpers.assert_true(type(catalogue.servers[id]._source) == "string", id .. " names its source")
				helpers.assert_eq(providers[id], nil, id .. " must not be a remote provider id")
			end
		end)

	helpers.it("registers each server as a keyless openai provider outside the remote order (local-openai-backends)",
		function()
			with_backend(function(api)
				local ProviderUses = require("modules.llm.provider_uses")
				for _, id in ipairs(SERVERS) do
					local provider = api.PROVIDERS[id]
					helpers.assert_true(provider ~= nil and provider.local_server == true, id .. " is registered")
					helpers.assert_eq(provider.format, "openai")
					helpers.assert_true(api.is_local_server(id))
					for _, listed in ipairs(api.PROVIDER_ORDER) do
						helpers.assert_true(listed ~= id, id .. " is listed only while it answers")
					end
					for _, use in ipairs({ ProviderUses.PREDICTION, ProviderUses.SYSTEM1, ProviderUses.SYSTEM2,
						ProviderUses.VISION }) do
						helpers.assert_true(api.provider_serves(id, use), id .. " serves " .. use)
					end
				end
				helpers.assert_true(not api.is_local_server("openai"), "a remote provider is not local")
			end)
		end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Detection ================
-- =====================================
-- =====================================

helpers.describe("Local OpenAI-compatible servers: detection (local-openai-backends)", function()
	helpers.it("lists only the servers whose models endpoint answers, with their models (local-openai-backends)",
		function()
			with_backend(function(api, LocalServers, world)
				local done = {}
				helpers.assert_eq(LocalServers.is_stale(), true, "nothing was swept yet")
				helpers.assert_eq(api.detect_local_servers(function(changed) done[#done + 1] = changed end), true)
				helpers.assert_eq(#world.probes, 4, "every server is probed at once")
				helpers.assert_eq(world.probe("omlx").url, "http://localhost:8000/v1/models")
				helpers.assert_eq(world.probe("lmstudio").url, "http://localhost:1234/v1/models")
				helpers.assert_eq(world.probe("llamacpp").url, "http://localhost:8080/v1/models")
				helpers.assert_eq(world.probe("jan").url, "http://localhost:1337/v1/models")
				helpers.assert_eq(world.probe("omlx").headers.Authorization, nil, "no key unless the user gives one")
				helpers.assert_true(LocalServers.is_sweeping())

				world.probe("omlx").callback(models_answer({ "Qwen3-8B-4bit", "gemma-3-4b-it" }))
				world.probe("lmstudio").callback({ ok = false, status = 0, error = "connection refused" })
				world.probe("llamacpp").callback({ ok = false, status = 401, body = "{}" })
				helpers.assert_eq(#done, 0, "the verdicts publish together")
				world.probe("jan").callback({ ok = true, status = 200, body = "<html>another service</html>" })

				helpers.assert_eq(#done, 1)
				helpers.assert_eq(done[1], true, "the verdicts changed")
				helpers.assert_eq(table.concat(LocalServers.detected(), ","), "omlx,llamacpp")
				helpers.assert_eq(LocalServers.result("omlx").status, LocalServers.STATUS_UP)
				helpers.assert_eq(table.concat(LocalServers.result("omlx").models, ","), "Qwen3-8B-4bit,gemma-3-4b-it")
				helpers.assert_eq(LocalServers.result("llamacpp").status, LocalServers.STATUS_NEEDS_KEY)
				helpers.assert_eq(LocalServers.result("jan").status, LocalServers.STATUS_DOWN,
					"a 200 that is not a models list is another service")
				helpers.assert_eq(LocalServers.is_stale(), false)

				-- The same verdicts again change nothing, and a late answer of an
				-- older sweep is dropped
				local first_omlx = world.probe("omlx")
				api.detect_local_servers(function(changed) done[#done + 1] = changed end)
				first_omlx.callback(models_answer({ "stale" }))
				answer_sweep(world, {
					omlx = models_answer({ "Qwen3-8B-4bit", "gemma-3-4b-it" }),
					llamacpp = { ok = false, status = 401 },
				})
				helpers.assert_eq(#done, 2)
				helpers.assert_eq(done[2], false, "nothing changed")
				helpers.assert_eq(table.concat(LocalServers.result("omlx").models, ","), "Qwen3-8B-4bit,gemma-3-4b-it")
			end)
		end)

	helpers.it("probes a server at its entry's address, with its key (local-openai-backends)", function()
		with_backend(function(api, LocalServers, world)
			api.set_entries({ {
				id = "local-lmstudio", provider = "lmstudio", base_url = "http://127.0.0.1:4321/v1",
				token = "lm-key", model = "qwen2.5-7b-instruct",
			} })
			LocalServers.set_pending("jan", { base_url = "http://127.0.0.1:1400/v1" })
			api.detect_local_servers()
			helpers.assert_eq(world.probe("lmstudio").url, "http://127.0.0.1:4321/v1/models")
			helpers.assert_eq(world.probe("lmstudio").headers.Authorization, "Bearer lm-key")
			helpers.assert_eq(world.probe("jan").url, "http://127.0.0.1:1400/v1/models",
				"an address typed before any model is chosen is probed")
		end)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Requests =================
-- =====================================
-- =====================================

helpers.describe("Local OpenAI-compatible servers: requests (local-openai-backends)", function()
	helpers.it("sends a prediction in the OpenAI chat shape, with no key (local-openai-backends)", function()
		with_backend(function(api, _, world)
			api.set_entries({ {
				id = "local-lmstudio", provider = "lmstudio", base_url = "", token = "", model = "qwen2.5-7b-instruct",
			} })
			api.set_active_entry_id("local-lmstudio")
			local answers, failures = {}, 0
			api.request_raw(nil, "Complete the text.", "Bonjour, je", "", 0.2, 32,
				function(text) answers[#answers + 1] = text end, function() failures = failures + 1 end)
			helpers.assert_eq(#world.posts, 1, "a keyless local entry is sent")
			local post = world.posts[1]
			helpers.assert_eq(post.client, "_infer_client")
			helpers.assert_eq(post.url, "http://localhost:1234/v1/chat/completions")
			helpers.assert_eq(post.headers.Authorization, nil)
			helpers.assert_eq(post.headers["Content-Type"], "application/json")
			helpers.assert_eq(post.body.model, "qwen2.5-7b-instruct")
			helpers.assert_eq(post.body.stream, false)
			helpers.assert_eq(post.body.max_tokens, 32)
			helpers.assert_eq(post.body.messages[1].role, "system")
			helpers.assert_eq(post.body.messages[1].content, "Complete the text.")
			helpers.assert_eq(post.body.messages[2].role, "user")
			helpers.assert_eq(post.body.messages[2].content, "Bonjour, je")
			post.callback(completion_answer("suis là"))
			helpers.assert_eq(answers[1], "suis là")
			helpers.assert_eq(failures, 0)
		end)
	end)

	helpers.it("sends an agent request to a server that has no entry (local-openai-backends)", function()
		with_backend(function(api, _, world)
			local ProviderUses = require("modules.llm.provider_uses")
			helpers.assert_eq(api.provider_status("omlx", ProviderUses.SYSTEM2), true)
			helpers.assert_eq(select(2, api.provider_status("openai", ProviderUses.SYSTEM2)), "no_entry",
				"a remote provider still needs its entry")
			local texts = {}
			local body = { model = "Qwen3-8B-4bit", stream = false,
				messages = { { role = "system", content = "S" }, { role = "user", content = "T" } } }
			helpers.assert_eq(api.request_chat("omlx", "Qwen3-8B-4bit", body,
				function(text) texts[#texts + 1] = text end, function() end), true)
			local post = world.posts[1]
			helpers.assert_eq(post.client, "_vision_client")
			helpers.assert_eq(post.url, "http://localhost:8000/v1/chat/completions")
			helpers.assert_eq(post.headers.Authorization, nil)
			helpers.assert_eq(post.body.model, "Qwen3-8B-4bit")
			post.callback(completion_answer("ACTIONS: []"))
			helpers.assert_eq(texts[1], "ACTIONS: []")
		end)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ Failures =================
-- =====================================
-- =====================================

helpers.describe("Local OpenAI-compatible servers: failures (local-openai-backends)", function()
	helpers.it("classifies what the user can fix (local-openai-backends)", function()
		with_backend(function(_, LocalServers)
			helpers.assert_eq(LocalServers.classify_failure(0), LocalServers.FAILURE_NOT_RUNNING)
			helpers.assert_eq(LocalServers.classify_failure(401), LocalServers.FAILURE_NEEDS_KEY)
			helpers.assert_eq(LocalServers.classify_failure(403), LocalServers.FAILURE_NEEDS_KEY)
			helpers.assert_eq(LocalServers.classify_failure(404, "Not Found"), LocalServers.FAILURE_MODEL_MISSING)
			helpers.assert_eq(LocalServers.classify_failure(400, "Model 'x' not found"),
				LocalServers.FAILURE_MODEL_MISSING)
			helpers.assert_eq(LocalServers.classify_failure(400, "Invalid temperature"), nil)
			helpers.assert_eq(LocalServers.classify_failure(500, "boom"), nil)
		end)
	end)

	helpers.it("reports a failed prediction once to the menu's handler (local-openai-backends)", function()
		with_backend(function(api, LocalServers, world)
			local reports = {}
			helpers.assert_eq(LocalServers.report_failure("lmstudio", 404, "", "gone-model"),
				LocalServers.FAILURE_MODEL_MISSING)
			LocalServers.set_failure_handler(function(id, kind, detail)
				reports[#reports + 1] = { id = id, kind = kind, detail = detail }
			end)
			api.set_entries({ { id = "local-lmstudio", provider = "lmstudio", token = "", model = "gone-model" } })
			api.set_active_entry_id("local-lmstudio")
			local function predict()
				api.request_raw(nil, "S", "text", "", 0.2, 16, function() end, function() end)
				return world.posts[#world.posts]
			end
			predict().callback({ ok = false, status = 404, headers = {},
				body = json.encode({ error = { message = "Model gone-model not found" } }) })
			helpers.assert_eq(#reports, 1, "a failure before the menu registered its handler is not swallowed")
			helpers.assert_eq(reports[1].id, "lmstudio")
			helpers.assert_eq(reports[1].kind, LocalServers.FAILURE_MODEL_MISSING)
			helpers.assert_eq(reports[1].detail.model, "gone-model")
			predict().callback({ ok = false, status = 404, headers = {}, body = "" })
			helpers.assert_eq(#reports, 1, "the same failure is reported once")
			predict().callback({ ok = false, status = 0, headers = {} })
			helpers.assert_eq(reports[2].kind, LocalServers.FAILURE_NOT_RUNNING)
			predict().callback(completion_answer("ok"))
			predict().callback({ ok = false, status = 0, headers = {} })
			helpers.assert_eq(#reports, 3, "an answer clears the report")
			LocalServers.set_failure_handler(nil)
		end)
	end)
end)




-- =====================================
-- =====================================
-- ======= 5/ Persistence ==============
-- =====================================
-- =====================================

--- Runs the real LLM core's API entry persistence over a faked settings store
--- and Keychain.
--- @param store table The settings store.
--- @param entries table Runtime entries.
--- @param active_id string Runtime active entry.
--- @param body function Receives (llm, fixture).
local function with_persistence(store, entries, active_id, body)
	local owned = {
		"modules.llm", "modules.llm.profiles", "modules.llm.api_ollama", "modules.llm.api_mlx",
		"modules.llm.api_remote", "modules.llm.api_token_crypto", "modules.llm.api_common",
		"infra.logger", "infra.paths", "adapters.timer_scheduler", "adapters.storage",
	}
	helpers.with_fresh_modules(owned, function()
		local fixture = { encrypt_jobs = {}, errors = {} }
		package.loaded["modules.llm.api_remote"] = {
			set_entries = function(value) entries = value end,
			get_entries = function() return entries end,
			set_active_entry_id = function(value) active_id = value end,
			get_active_entry_id = function() return active_id end,
			prewarm_active_entry_decrypt = function() end,
			is_local_server = function(id) return id == "lmstudio" end,
		}
		package.loaded["modules.llm.profiles"] = { BUILTIN_PROFILES = {} }
		package.loaded["modules.llm.api_ollama"] = {}
		package.loaded["modules.llm.api_mlx"] = {}
		package.loaded["modules.llm.api_common"] = {}
		package.loaded["modules.llm.api_token_crypto"] = {
			is_encrypted = function(value) return type(value) == "string" and value:sub(1, 9) == "keychain:" end,
			encrypt_async = function(id, _, callback)
				fixture.encrypt_jobs[#fixture.encrypt_jobs + 1] = id
				callback(true, "keychain:" .. id, nil)
				return { cancel = function() return true end }
			end,
			delete_async = function(_, callback) callback(true, nil); return { cancel = function() return true end } end,
		}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, fmt, ...) fixture.errors[#fixture.errors + 1] = string.format(tostring(fmt), ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.paths"] = { shared = function(relative) return "static/ergopti_plus/_shared/" .. relative end }
		package.loaded["adapters.timer_scheduler"] = {
			after = function() return { timer = true }, true end, cancel = function() return true end,
			now = function() return 0 end,
		}
		package.loaded["adapters.storage"] = {
			set = function(key, value) store[key] = value; return true end,
			read_exact = function(key) return true, store[key] end,
			delete_exact = function(key) store[key] = nil; return true end,
		}
		local settings = {
			get = function(key) return store[key] end,
			set = function(key, value) store[key] = value end,
			clear = function(key) store[key] = nil end,
		}
		local llm = helpers.load_with_stubs("modules.llm", { settings = settings })
		fixture.entries = function() return entries end
		fixture.active_id = function() return active_id end
		body(llm, fixture)
	end)
end

helpers.describe("Local OpenAI-compatible servers: persistence (local-openai-backends)", function()
	helpers.it("stores a chosen local model as a keyless API entry that reads back (local-openai-backends)", function()
		local store = {}
		local entry = {
			id = "local-lmstudio", provider = "lmstudio", base_url = "", token = "",
			model = "qwen2.5-7b-instruct", label = "LM Studio/qwen2.5-7b-instruct",
		}
		local outcome = nil
		with_persistence(store, { entry }, "local-lmstudio", function(llm, fixture)
			llm.persist_api_entries(function(ok, reason) outcome = { ok = ok, reason = reason } end)
			helpers.assert_eq(#fixture.encrypt_jobs, 0, "no key, nothing for the Keychain")
			helpers.assert_eq(#fixture.errors, 0, table.concat(fixture.errors, " | "))
		end)
		helpers.assert_eq(outcome and outcome.ok, true, "the keyless local entry persists")
		local state = store.llm_api_state_v1
		helpers.assert_eq(state.active_id, "local-lmstudio")
		helpers.assert_eq(state.entries[1].token, "")

		with_persistence(store, {}, "", function(llm, fixture)
			helpers.assert_eq(llm.load_api_entries(), true, "the stored state reads back")
			helpers.assert_eq(fixture.active_id(), "local-lmstudio")
			helpers.assert_eq(fixture.entries()[1].provider, "lmstudio")
			helpers.assert_eq(fixture.entries()[1].model, "qwen2.5-7b-instruct")
		end)
	end)

	helpers.it("still refuses a remote provider entry without a key (local-openai-backends)", function()
		local store = {}
		local outcome = nil
		with_persistence(store, { { id = "e", provider = "openai", token = "", model = "gpt" } }, "e", function(llm)
			llm.persist_api_entries(function(ok, reason) outcome = { ok = ok, reason = reason } end)
		end)
		helpers.assert_eq(outcome and outcome.ok, false)
		helpers.assert_eq(outcome.reason, "invalid_api_state")
		helpers.assert_eq(store.llm_api_state_v1, nil)
	end)
end)




-- =====================================
-- =====================================
-- ======= 6/ Menus ====================
-- =====================================
-- =====================================

--- Runs a scenario over the real local server panel and remote backend, with
--- the persistence, dialogs and notices faked.
--- @param scenario function Receives (Panel, api, LocalServers, world, ctx).
local function with_panel(scenario)
	local owned = {
		"ui.menu.menu_llm.local_server_panel", "ui.menu.menu_llm.api_panel", "modules.llm",
		"infra.dialog_util", "infra.notifications",
	}
	with_backend(function(api, LocalServers, world)
		helpers.with_fresh_modules(owned, function()
			world.notices, world.persists, world.menus, world.activations, world.warmups = {}, 0, 0, 0, 0
			world.dialog_answer = { "OK", "" }
			package.loaded["modules.llm"] = {
				api_remote = api,
				persist_api_entries = function(callback)
					world.persists = world.persists + 1
					callback(true, nil, true)
				end,
			}
			package.loaded["infra.dialog_util"] = {
				text_prompt = function(_, _, default, ok_label, cancel_label)
					world.last_default = default
					return world.dialog_answer[1] == "OK" and ok_label or cancel_label, world.dialog_answer[2]
				end,
			}
			package.loaded["infra.notifications"] = {
				notify = function(title, body, kind, on_click)
					world.notices[#world.notices + 1] = { title = title, body = body, kind = kind, on_click = on_click }
					return true
				end,
			}
			local Panel = require("ui.menu.menu_llm.local_server_panel")
			local ctx = {
				state = { llm_backend = "ollama", llm_model = "" },
				paused = false,
				keymap = { reset_predictions = function() return true end },
				update_menu = function() world.menus = world.menus + 1 end,
				WarmupCtrl = { warmup = function() world.warmups = world.warmups + 1 end },
				activate_api = function() world.activations = world.activations + 1 end,
			}
			scenario(Panel, api, LocalServers, world, ctx)
		end)
	end)
end

--- The row whose label starts with a prefix.
--- @param rows table
--- @param prefix string
--- @return table|nil row
local function row_starting(rows, prefix)
	for _, row in ipairs(rows) do
		if type(row.label) == "string" and row.label:sub(1, #prefix) == prefix then return row end
	end
	return nil
end

helpers.describe("Local OpenAI-compatible servers: AI menu (local-openai-backends)", function()
	helpers.it("lists the answering servers and makes a chosen model the backend (local-openai-backends)", function()
		with_panel(function(Panel, api, LocalServers, world, ctx)
			local rows = Panel.rows(ctx)
			helpers.assert_eq(#world.probes, 4, "a stale menu sweeps without waiting")
			helpers.assert_true(row_starting(rows, "oMLX") == nil, "nothing is listed before it answers")
			helpers.assert_true(row_starting(rows, "menu.llm.local_servers.searching") ~= nil)

			answer_sweep(world, { omlx = models_answer({ "Qwen3-8B-4bit", "gemma-3-4b-it" }) })
			helpers.assert_eq(world.menus, 1, "a changed verdict redraws the menu")
			rows = Panel.rows(ctx)
			helpers.assert_eq(#world.probes, 4, "fresh verdicts are not swept again")
			local omlx = row_starting(rows, "oMLX 🖥️ — localhost:8000")
			helpers.assert_true(omlx ~= nil, "the answering server is listed")
			helpers.assert_true(row_starting(rows, "LM Studio") == nil, "a silent server is not")
			helpers.assert_eq(omlx.items[1].label, "Qwen3-8B-4bit")
			helpers.assert_eq(omlx.items[2].label, "gemma-3-4b-it")

			omlx.items[2].action()
			local entry = api.get_active_entry()
			helpers.assert_true(entry ~= nil, "the chosen model's entry is active")
			helpers.assert_eq(entry.provider, "omlx")
			helpers.assert_eq(entry.model, "gemma-3-4b-it")
			helpers.assert_eq(entry.token, "", "no key was given")
			helpers.assert_eq(entry.base_url, "", "the default address is inherited")
			helpers.assert_eq(ctx.state.llm_model, "", "the Ollama model slot is the backend switch's to change")
			helpers.assert_eq(world.persists, 1)
			helpers.assert_eq(world.activations, 1, "the API backend is selected")

			-- Choosing another model reuses the one entry of the server
			ctx.state.llm_backend = "api"
			rows = Panel.rows(ctx)
			omlx = row_starting(rows, "oMLX")
			helpers.assert_eq(omlx.checked, true)
			helpers.assert_eq(omlx.items[2].checked, true)
			omlx.items[1].action()
			helpers.assert_eq(#api.get_entries(), 1)
			helpers.assert_eq(api.get_active_entry().model, "Qwen3-8B-4bit")
			helpers.assert_eq(ctx.state.llm_model, "Qwen3-8B-4bit")
			helpers.assert_eq(world.activations, 1, "the backend already was the API")
			helpers.assert_eq(world.warmups, 1, "the new model is warmed up")
		end)
	end)

	helpers.it("asks for the key a server wants and probes it with the key (local-openai-backends)", function()
		with_panel(function(Panel, api, LocalServers, world, ctx)
			Panel.rows(ctx)
			answer_sweep(world, { llamacpp = { ok = false, status = 401 } })
			local row = row_starting(Panel.rows(ctx), "menu.llm.local_servers.needs_key")
			helpers.assert_true(row ~= nil, "a server that wants a key is listed as such")
			world.dialog_answer = { "OK", "  secret-key  " }
			row.items[1].action()
			helpers.assert_eq(LocalServers.pending("llamacpp").token, "secret-key",
				"the key waits for the chosen model")
			helpers.assert_eq(world.probe("llamacpp").headers.Authorization, "Bearer secret-key")
			answer_sweep(world, { llamacpp = models_answer({ "llama-3.2-3b" }) })
			local server = row_starting(Panel.rows(ctx), "llama.cpp")
			server.items[1].action()
			helpers.assert_eq(api.get_active_entry().token, "secret-key", "the chosen model's entry carries the key")
			helpers.assert_eq(LocalServers.pending("llamacpp").token, nil)
		end)
	end)

	helpers.it("offers the fix of each failure in its notice (local-openai-backends)", function()
		with_panel(function(Panel, api, LocalServers, world, ctx)
			Panel.rows(ctx)
			answer_sweep(world, { omlx = models_answer({ "a", "b" }) })
			local probes = #world.probes
			LocalServers.report_failure("omlx", 0, nil, "a")
			local notice = world.notices[#world.notices]
			helpers.assert_eq(notice.title, "llm.local_servers.not_running_title")
			helpers.assert_true(type(notice.on_click) == "function", "the notice offers its fix")
			notice.on_click()
			helpers.assert_eq(#world.probes, probes + 4, "a click searches again")

			answer_sweep(world, { omlx = models_answer({ "b" }) })
			api.set_entries({ { id = "local-omlx", provider = "omlx", token = "", model = "a" } })
			api.set_active_entry_id("local-omlx")
			LocalServers.report_failure("omlx", 404, "model a not found", "a")
			notice = world.notices[#world.notices]
			helpers.assert_eq(notice.title, "llm.local_servers.model_missing_title")
			world.dialog_answer = { "OK", "b" }
			notice.on_click()
			answer_sweep(world, { omlx = models_answer({ "b" }) })
			helpers.assert_eq(world.last_default, "b", "the served model is proposed")
			helpers.assert_eq(api.get_active_entry().model, "b", "the missing model is replaced")
		end)
	end)

	helpers.it("offers the answering servers' models to the agent's Systems (local-openai-backends)", function()
		with_backend(function(api, LocalServers, world)
			helpers.with_fresh_modules({ "ui.menu.menu_llm.agent_panel", "ui.menu.menu_llm.local_server_panel" }, function()
				local Panel = require("ui.menu.menu_llm.agent_panel")
				local before = #Panel.backends("system2")
				api.detect_local_servers()
				answer_sweep(world, { lmstudio = models_answer({ "qwen2.5-7b-instruct" }) })
				local choices = Panel.backends("system2")
				helpers.assert_eq(#choices, before + 1)
				helpers.assert_eq(choices[2].id, "lmstudio", "after the local server, before the providers")
				helpers.assert_eq(choices[2].label, "LM Studio 🖥️")
			end)
		end)
	end)
end)


helpers.describe("Local API typed optional authentication (local-api-optional-auth)", function()
	helpers.it("refuses a non-string local token before the actual request", function()
		local observed = {}
		with_backend(function(api, _, world)
			api.set_entries({ { id = "typed-local", provider = "lmstudio", token = {},
				model = "fixture-model", base_url = "http://127.0.0.1:19273/v1" } })
			api.set_active_entry_id("typed-local")
			api.resolve_active_entry(function(ok, entry, reason)
				observed.ok, observed.entry, observed.reason = ok, entry, reason
			end)
			observed.posts = #world.posts
		end)
		helpers.assert_eq(observed.ok, false)
		helpers.assert_eq(observed.entry, nil)
		helpers.assert_eq(observed.posts, 0)
	end)

	helpers.it("keeps a configured keyless local address as a supported request", function()
		local observed = {}
		with_backend(function(api, _, world)
			api.set_entries({ { id = "custom-local", provider = "lmstudio", token = "",
				model = "fixture-model", base_url = "http://127.0.0.1:19273/v1" } })
			api.set_active_entry_id("custom-local")
			api.request_raw(nil, "Continue.", "hello", "", 0.2, 16,
				function(text) observed.text = text end, function(reason) observed.reason = reason end)
			observed.posts, observed.post = #world.posts, world.posts[1]
		end)
		helpers.assert_eq(observed.posts, 1)
		helpers.assert_eq(observed.post.url, "http://127.0.0.1:19273/v1/chat/completions")
		helpers.assert_eq(observed.post.headers.Authorization, nil)
	end)
end)


helpers.describe("Actual local API models receipt contract", function()
	helpers.it("replays strict typed/status receipts through the native catalogue consumer", function()
		local vectors = read_json("tests/corpus/llm/local_server_auth.json").models_cases
		local observed = {}
		with_backend(function(_, servers)
			for index, vector in ipairs(vectors) do
				local status, ids = servers.classify(vector.response)
				observed[index] = { status = status, ids = ids }
			end
		end)
		for index, vector in ipairs(vectors) do
			helpers.assert_eq(observed[index].status == "up", vector.admitted, vector.name)
			if vector.admitted then helpers.assert_eq(observed[index].ids, vector.models, vector.name) end
		end
	end)
end)

helpers.describe("Local discovery captured identities (local-discovery-controller)", function()
	helpers.it("captures each probe identity before the producer can mutate its input", function()
		local observed = {}
		with_backend(function(_, servers)
			local target = { id = "omlx", base_url = "http://127.0.0.1:17341/v1", token = "" }
			local complete
			servers.sweep({ target }, function(_, settle) complete = settle; return true end)
			target.id, target.base_url = "jan", "http://127.0.0.1:17342/v1"
			complete(models_answer({ "captured-model" }))
			observed.result = servers.result("omlx")
			observed.foreign = servers.result("jan")
		end)
		helpers.assert_true(observed.result ~= nil, "native delivery belongs to the captured provider")
		helpers.assert_eq(observed.result.base_url, "http://127.0.0.1:17341/v1")
		helpers.assert_eq(observed.result.models[1], "captured-model")
		helpers.assert_eq(observed.foreign, nil)
	end)

	helpers.it("stops dispatching an older sweep after a native producer reenters a newer sweep", function()
		local observed = { starts = {}, dones = {} }
		with_backend(function(_, servers)
			local old = {
				{ id = "omlx", base_url = "http://127.0.0.1:17341/v1" },
				{ id = "lmstudio", base_url = "http://127.0.0.1:17342/v1" },
			}
			local newest = { { id = "omlx", base_url = "http://127.0.0.1:17343/v1" } }
			local old_answer, new_answer
			servers.sweep(old, function(target, settle)
				observed.starts[#observed.starts + 1] = "old:" .. target.id
				if target.id == "omlx" then
					old_answer = settle
					servers.sweep(newest, function(current, answer)
						observed.starts[#observed.starts + 1] = "new:" .. current.id
						new_answer = answer
						return true
					end, function(changed) observed.dones[#observed.dones + 1] = changed end)
				end
				return true
			end, function(changed) observed.dones[#observed.dones + 1] = changed end)
			new_answer(models_answer({ "new-model" }))
			old_answer(models_answer({ "old-model" }))
			observed.result = servers.result("omlx")
		end)
		helpers.assert_eq(table.concat(observed.starts, ","), "old:omlx,new:omlx",
			"a superseded producer cannot cancel newer native requests by continuing its dispatch loop")
		helpers.assert_eq(#observed.dones, 2, "both waiting callers receive the newest joint publication")
		helpers.assert_eq(observed.result.models[1], "new-model")
		helpers.assert_eq(observed.result.base_url, "http://127.0.0.1:17343/v1")
	end)
end)


--- Holds the real native owner's asynchronous credential boundary, then restores
--- its exact function even when the test scenario raises. Observations are
--- asserted after cleanup, outside production's protected callbacks.
local function with_held_probe_credentials(scenario)
	with_backend(function(api, LocalServers, world)
		local crypto = require("modules.llm.api_token_crypto")
		local original = crypto.decrypt_async
		local callbacks = {}
		crypto.decrypt_async = function(stored, callback)
			callbacks[#callbacks + 1] = { stored = stored, callback = callback }
			return true
		end
		local ok, result = xpcall(function()
			return scenario(api, LocalServers, world, callbacks)
		end, debug.traceback)
		crypto.decrypt_async = original
		helpers.assert_eq(crypto.decrypt_async, original, "the exact credential callback owner is restored")
		if not ok then error(result) end
		for key, observation in pairs(result) do
			helpers.assert_eq(observation.actual, observation.expected, key)
		end
	end)
end

helpers.describe("Local discovery: native credential admission (local-openai-backends)", function()
	helpers.it("a superseded held credential cannot acquire an HTTP probe (local-openai-backends)", function()
		with_held_probe_credentials(function(api, LocalServers, world, credentials)
			LocalServers.set_pending("omlx", { base_url = "http://localhost:9801/v1", token = "owned-reference" })
			local done = {}
			api.detect_local_servers(function() done[#done + 1] = "old" end)
			api.detect_local_servers(function() done[#done + 1] = "new" end)
			local before_old = #world.probes
			credentials[1].callback(true, "old-cleartext")
			local after_old = #world.probes
			credentials[2].callback(true, "new-cleartext")
			local fresh = world.probe("omlx")
			answer_sweep(world, { omlx = models_answer({ "new-model" }) })
			return {
				held = { actual = #credentials, expected = 2 },
				old_native_acquisitions = { actual = after_old - before_old, expected = 0 },
				fresh_native_acquisitions = { actual = #world.probes - after_old, expected = 1 },
				fresh_url = { actual = fresh.url, expected = "http://localhost:9801/v1/models" },
				fresh_key = { actual = fresh.headers.Authorization, expected = "Bearer new-cleartext" },
				waiters = { actual = done, expected = { "old", "new" } },
				fresh_models = { actual = LocalServers.result("omlx").models, expected = { "new-model" } },
			}
		end)
	end)

	helpers.it("a changed current target refuses held credentials and unchanged retry still acquires (local-openai-backends)", function()
		with_held_probe_credentials(function(api, LocalServers, world, credentials)
			LocalServers.set_pending("omlx", { base_url = "http://localhost:9801/v1", token = "first-reference" })
			api.detect_local_servers()
			LocalServers.set_pending("omlx", { base_url = "http://localhost:9802/v1", token = "second-reference" })
			local before_stale = #world.probes
			credentials[1].callback(true, "stale-cleartext")
			local after_stale = #world.probes
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do
				world.probe(id).callback({ ok = false, status = 0, error = "connection refused" })
			end
			local stale = LocalServers.result("omlx")
			api.detect_local_servers()
			credentials[2].callback(true, "unchanged-cleartext")
			local fresh = world.probe("omlx")
			answer_sweep(world, { omlx = models_answer({ "current-model" }) })
			return {
				stale_native_acquisitions = { actual = after_stale - before_stale, expected = 0 },
				stale_status = { actual = stale and stale.status or "not-published", expected = LocalServers.STATUS_DOWN },
				current_url = { actual = fresh.url, expected = "http://localhost:9802/v1/models" },
				current_key = { actual = fresh.headers.Authorization, expected = "Bearer unchanged-cleartext" },
				current_models = { actual = LocalServers.result("omlx").models, expected = { "current-model" } },
			}
		end)
	end)
end)


helpers.describe("Local discovery: live response identity (local-openai-backends)", function()
	helpers.it("an address or stored key change independently refuses an already acquired answer (local-openai-backends)", function()
		for _, field in ipairs({ "base_url", "token" }) do
			with_backend(function(api, LocalServers, world)
				LocalServers.set_pending("omlx", { base_url = "http://localhost:9801/v1", token = "" })
				local completions = 0
				api.detect_local_servers(function() completions = completions + 1 end)
				local captured = world.probe("omlx")
				local changes = {}
				changes[field] = field == "token" and "new-owned-reference" or "http://localhost:9802/v1"
				LocalServers.set_pending("omlx", changes)
				captured.callback(models_answer({ "foreign-source-model" }))
				for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do
					world.probe(id).callback({ ok = false, status = 0, error = "connection refused" })
				end
				-- Observe after the protected native response callbacks have returned.
				helpers.assert_eq(completions, 1, field .. " settles the joint current search")
				helpers.assert_eq(#world.probes, 4, field .. " never acquires an implicit retry")
				helpers.assert_eq(LocalServers.result("omlx").status, LocalServers.STATUS_DOWN,
					field .. " prevents stale source publication")
				helpers.assert_eq(LocalServers.result("omlx").models, {}, field .. " admits no old models")
			end)
		end
	end)
end)
