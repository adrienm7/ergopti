--- tests/unit/modules/llm/backends/test_local_openai_backends_api_models.lua

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
package.loaded["tests.support.modules.llm.backends.local_openai_backends_fixture"] = nil
local Fixture = require("tests.support.modules.llm.backends.local_openai_backends_fixture")
local answer_sweep = Fixture.answer_sweep
local get_upvalue = Fixture.get_upvalue
local models_answer = Fixture.models_answer
local read_json = Fixture.read_json
local row_starting = Fixture.row_starting
local with_backend = Fixture.with_backend
local with_panel = Fixture.with_panel





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

helpers.describe("Configured generic local model mutation (local-configured-affinity)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("retains " .. provider .. " identity, foreign metadata and position through model ACK (local-configured-affinity)", function()
			with_panel(function(Panel, api, _, world, ctx)
				local before = { id = "before", provider = "openai", token = "fixture", model = "cloud-before" }
				local configured = { id = "generic", provider = provider, token = "fixture", model = "before",
					base_url = "http://127.0.0.1:8000/v1", label = "Personal label", foreign = { retained = true } }
				local after = { id = "after", provider = "openai", token = "fixture", model = "cloud-after" }
				api.set_entries({ before, configured, after }); api.set_active_entry_id(configured.id)
				ctx.state.llm_backend = "api"
				local selected
				helpers.assert_true(Panel.select_model(ctx, "omlx", "mlx-community/Qwen3-8B-4bit", function(value) selected = value end))
				local saved = api.get_entries()
				helpers.assert_eq(#saved, 3)
				helpers.assert_eq(saved[1], before); helpers.assert_eq(saved[3], after)
				helpers.assert_eq(saved[2].provider, provider); helpers.assert_eq(saved[2].id, configured.id)
				helpers.assert_eq(saved[2].label, configured.label); helpers.assert_eq(saved[2].foreign, configured.foreign)
				helpers.assert_eq(saved[2].base_url, configured.base_url)
				helpers.assert_eq(saved[2].token, configured.token)
				helpers.assert_eq(saved[2].model, "mlx-community/Qwen3-8B-4bit")
				helpers.assert_eq(world.persists, 1); helpers.assert_eq(selected, true)
				helpers.assert_eq(configured.model, "before", "the old row is not mutated before its publisher ACK")
			end)
		end)
	end
end)

helpers.describe("Configured local menu leases and native pause (local-configured-views)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("selects configured " .. provider .. " view and acknowledges the exact generic entry (local-configured-views)", function()
			with_panel(function(Panel, api, LocalServers, world, ctx)
				local id = "configured:personal"
				local clients = get_upvalue(api.detect_local_servers, "_local_probe_clients")
				clients[id] = { cancel = function() return true end, isSettled = function() return true end,
					onSettled = function(callback) callback(); return true end,
					get = function(url, headers, callback)
						world.probes[#world.probes + 1] = { id = id, url = url, headers = headers, callback = callback }; return true
					end }
				local configured = { id = "personal", provider = provider, token = "", model = "before",
					base_url = "http://127.0.0.1:19423/v1", label = "Personal label", foreign = { retained = false } }
				api.set_entries({ configured }); api.set_active_entry_id(configured.id)
				ctx.state.llm_backend = "api"
				api.detect_local_servers()
				world.probe(id).callback(models_answer({ "mlx-community/Qwen3-8B-4bit" }))
				answer_sweep(world, {})
				local rows = Panel.rows(ctx)
				local server = row_starting(rows, api.PROVIDERS[provider].label .. " 🖥️")
				helpers.assert_true(server ~= nil)
				helpers.assert_eq(server.checked, true)
				helpers.assert_true(server.items[1].action())
				helpers.assert_eq(world.persists, 1)
				helpers.assert_eq(api.get_active_entry().provider, provider)
				helpers.assert_eq(api.get_active_entry().id, configured.id)
				helpers.assert_eq(api.get_active_entry().foreign, configured.foreign)
				helpers.assert_eq(api.get_active_entry().model, "mlx-community/Qwen3-8B-4bit")
			end)
		end)
	end
	helpers.it("retained configured model row refuses a replaced private identity (local-configured-views)", function()
		with_panel(function(Panel, api, _, world, ctx)
			local configured = { id = "personal", provider = "openai", token = "", model = "before", base_url = "http://localhost:8000/v1" }
			api.set_entries({ configured }); api.set_active_entry_id(configured.id)
			api.detect_local_servers(); answer_sweep(world, { omlx = models_answer({ "old-model" }) })
			local row = row_starting(Panel.rows(ctx), "oMLX 🖥️").items[1]
			local newer = { id = "personal", provider = "openai_compat", token = "", model = "newer", base_url = configured.base_url }
			api.set_entries({ newer })
			helpers.assert_eq(row.action(), false)
			helpers.assert_eq(world.persists, 0); helpers.assert_eq(api.get_entries(), { newer })
		end)
	end)
	for _, phase in ipairs({ "paused", "missing", "untyped", "throw" }) do
		helpers.it("retained local rows refuse live pause owner " .. phase .. " (local-configured-views)", function()
			with_panel(function(Panel, api, _, world, ctx)
				api.detect_local_servers(); answer_sweep(world, { omlx = models_answer({ "model" }) })
				local row = row_starting(Panel.rows(ctx), "oMLX 🖥️").items[1]
				if phase == "missing" then ctx.is_paused = nil
				elseif phase == "paused" then ctx.is_paused = function() return true end
				elseif phase == "untyped" then ctx.is_paused = function() return "false" end
				else ctx.is_paused = function() error("native pause read refused") end end
				helpers.assert_eq(row.action(), false)
				helpers.assert_eq(world.persists, 0); helpers.assert_eq(api.get_entries(), {})
				helpers.assert_eq(Panel.rescan(ctx), false)
			end)
		end)
	end
	helpers.it("address dialog refuses a source replacement while preserving the newer entry (local-configured-views)", function()
		with_panel(function(Panel, api, _, world, ctx)
			local original = { id = "personal", provider = "openai", token = "", model = "before", base_url = "http://localhost:8000/v1" }
			api.set_entries({ original })
			local newer = { id = "personal", provider = "openai_compat", token = "", model = "newer", base_url = original.base_url }
			local dialogs = require("infra.dialog_util")
			dialogs.text_prompt = function(_, _, _, ok_label)
				api.set_entries({ newer }); return ok_label, "http://127.0.0.1:8000/v1"
			end
			helpers.assert_eq(Panel.prompt_address(ctx, "omlx"), false)
			helpers.assert_eq(world.persists, 0); helpers.assert_eq(api.get_entries(), { newer })
		end)
	end)
	helpers.it("late refused publication never rolls back a newer configured source (local-configured-views)", function()
		with_panel(function(Panel, api, _, world, ctx)
			local configured = { id = "personal", provider = "openai", token = "", model = "before", base_url = "http://localhost:8000/v1" }
			api.set_entries({ configured }); api.set_active_entry_id(configured.id)
			local held
			require("modules.llm").persist_api_entries = function(callback) world.persists = world.persists + 1; held = callback end
			local selected
			helpers.assert_true(Panel.select_model(ctx, "omlx", "staged", function(value) selected = value end))
			local newer = { id = "newer", provider = "openai_compat", token = "", model = "newer", base_url = configured.base_url }
			api.set_entries({ newer }); api.set_active_entry_id(newer.id)
			held(false, "source changed", false)
			helpers.assert_eq(selected, false); helpers.assert_eq(api.get_entries(), { newer })
			helpers.assert_eq(api.get_active_entry_id(), newer.id)
			helpers.assert_eq(world.activations, 0)
		end)
	end)
end)

helpers.describe("Local models cache source identity (local-configured-cache)", function()
	helpers.it("same view membership clears cached models before a changed configured source is shown (local-configured-cache)", function()
		with_panel(function(Panel, api, LocalServers, world, ctx)
			local id = "configured:personal"
			local clients = get_upvalue(api.detect_local_servers, "_local_probe_clients")
			clients[id] = { cancel = function() return true end, isSettled = function() return true end,
				onSettled = function(callback) callback(); return true end,
				get = function(url, headers, callback)
					world.probes[#world.probes + 1] = { id = id, url = url, headers = headers, callback = callback }; return true
				end }
			api.set_entries({ { id = "personal", provider = "openai", token = "", model = "before", base_url = "http://localhost:19423/first/v1" } })
			api.detect_local_servers()
			world.probe(id).callback(models_answer({ "old-source-model" })); answer_sweep(world, {})
			helpers.assert_eq(LocalServers.result(id).models, { "old-source-model" })
			local changed = { id = "personal", provider = "openai_compat", token = "", model = "newer", base_url = "http://localhost:19423/second/v1" }
			api.set_entries({ changed })
			local before = #world.probes
			local rows = Panel.rows(ctx)
			helpers.assert_eq(LocalServers.result(id), nil, "same view id cannot retain another source's model receipt")
			helpers.assert_eq(#world.probes - before, 5, "actual rows start one fresh joint sweep before displaying models")
			helpers.assert_eq(world.probe(id).url, changed.base_url .. "/models")
			for _, row in ipairs(rows) do
				for _, item in ipairs(row.items or {}) do helpers.assert_eq(item.label == "old-source-model", false) end
			end
		end)
	end)
end)
