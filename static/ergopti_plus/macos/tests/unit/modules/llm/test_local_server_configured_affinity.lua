--- tests/unit/modules/llm/test_local_server_configured_affinity.lua

--- ==============================================================================
--- MODULE: Configured Local Endpoint Discovery
--- DESCRIPTION:
--- Exercises the actual remote catalogue projection and discovery publication.
--- Generic API entries retain their identities; credentials never cross endpoints.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Resolves a declared native seam without substituting the production detector.
--- @param fn function
--- @param target string
--- @return any
local function upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if name == target then return value end
		if not name then break end
	end
	error("Missing production seam: " .. target)
end

--- Owns fresh backend modules and the exact asynchronous probe callbacks.
--- @param scenario function
local function isolated(scenario)
	helpers.with_fresh_modules({ "modules.llm.local_servers", "modules.llm.api_remote" }, function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local servers = require("modules.llm.local_servers")
		local probes = {}
		local clients = upvalue(api.detect_local_servers, "_local_probe_clients")
		for _, id in ipairs(servers.ORDER) do
			clients[id] = { cancel = function() return true end, isSettled = function() return true end,
				onSettled = function(callback) callback(); return true end, get = function(url, headers, callback)
				probes[id] = { url = url, headers = headers, callback = callback }
				return true
			end }
		end
		local crypto = upvalue(api.detect_local_servers, "TokenCrypto")
		local original_decrypt = crypto.decrypt_async
		local http = upvalue(api.detect_local_servers, "_http_adapter")
		local original_new = http.new
		local ok, err = xpcall(function() scenario(api, servers, probes, crypto, clients, http) end, debug.traceback)
		crypto.decrypt_async = original_decrypt
		http.new = original_new
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Configured local endpoint discovery (local-configured-affinity)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("uses the configured " .. provider .. " endpoint without replacing provider identity (local-configured-affinity)", function()
			isolated(function(api, servers, probes)
				local entry = { id = "configured-generic", provider = provider, token = "",
					model = "before", base_url = "http://127.0.0.1:8000/v1/", label = "My local engine" }
				api.set_entries({ entry })
				api.set_active_entry_id(entry.id)
				helpers.assert_eq(api.local_server_entry("omlx"), entry, "the originating generic entry is retained")
				helpers.assert_true(api.detect_local_servers())
				helpers.assert_eq(probes.omlx.url, "http://127.0.0.1:8000/v1/models")
				helpers.assert_eq(probes.omlx.headers.Authorization, nil)
				probes.omlx.callback({ ok = true, status = 200,
					body = '{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"omlx"},{"id":"gemma-3-4b-it-4bit","object":"model","owned_by":"omlx"}]}' })
				for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do
					probes[id].callback({ ok = false, status = 0, body = "" })
				end
				helpers.assert_eq(servers.result("omlx").models, { "mlx-community/Qwen3-8B-4bit", "gemma-3-4b-it-4bit" })
				helpers.assert_eq(api.get_entries(), { entry }, "discovery never edits the private configuration")
				helpers.assert_eq(api.get_active_entry_id(), entry.id)
			end)
		end)
	end
end)

helpers.describe("Configured endpoint refusal and ownership (local-configured-affinity)", function()
	helpers.it("explicit catalogue entry wins over active generic affinity (local-configured-affinity)", function()
		isolated(function(api)
			local generic = { id = "generic", provider = "openai_compat", token = "", model = "generic",
				base_url = "http://127.0.0.1:8000/v1" }
			local explicit = { id = "explicit", provider = "omlx", token = "", model = "explicit",
				base_url = "http://127.0.0.1:19423/v1" }
			api.set_entries({ generic, explicit }); api.set_active_entry_id(generic.id)
			helpers.assert_eq(api.local_server_entry("omlx"), explicit)
			helpers.assert_eq(api.local_server_target("omlx").base_url, explicit.base_url)
		end)
	end)
	helpers.it("configured credentials remain confined to their originating loopback path (local-configured-affinity)", function()
		isolated(function(api, _, probes, crypto, clients)
			local held = {}
			crypto.decrypt_async = function(stored, callback) held[#held + 1] = { stored = stored, callback = callback }; return {} end
			clients["configured:foreign-path"] = { cancel = function() return true end, isSettled = function() return true end,
				onSettled = function(callback) callback(); return true end, get = function(url, headers)
				probes.configured = { url = url, headers = headers }; return true
			end }
			api.set_entries({ { id = "foreign-path", provider = "openai", token = "owned-reference", model = "before",
				base_url = "http://localhost:8000/foreign/v1" } })
			api.detect_local_servers()
			helpers.assert_eq(#held, 1, "only the explicitly configured entry reads its own credential")
			helpers.assert_eq(held[1].stored, "owned-reference")
			held[1].callback(true, "inert-owned-key")
			helpers.assert_eq(probes.configured.url, "http://localhost:8000/foreign/v1/models")
			helpers.assert_eq(probes.configured.headers.Authorization, "Bearer inert-owned-key")
			helpers.assert_eq(probes.omlx.url, "http://localhost:8000/v1/models")
			helpers.assert_eq(probes.omlx.headers.Authorization, nil, "the catalogue endpoint never receives another path's credential")
		end)
		isolated(function(api, _, probes, crypto)
			local decrypts = 0
			crypto.decrypt_async = function() decrypts = decrypts + 1; error("Foreign secret must not be read") end
			api.set_entries({ { id = "foreign", provider = "openai", token = "foreign-reference", model = "before",
				base_url = "https://remote.example/v1" } })
			api.detect_local_servers()
			helpers.assert_eq(decrypts, 0)
			helpers.assert_eq(probes.omlx.headers.Authorization, nil)
		end)
	end)
	helpers.it("held generic credentials admit only the current captured entry (local-configured-affinity)", function()
		isolated(function(api, servers, probes, crypto)
			local held = {}
			crypto.decrypt_async = function(stored, callback)
				held[#held + 1] = { stored = stored, callback = callback }
				return { cancel = function() return true end }
			end
			local first = { id = "first", provider = "openai_compat", token = "opaque-reference", model = "before",
				base_url = "http://127.0.0.1:8000/v1" }
			api.set_entries({ first }); api.set_active_entry_id(first.id); api.detect_local_servers()
			local second = { id = "second", provider = "openai", token = first.token, model = first.model, base_url = first.base_url }
			api.set_entries({ second }); api.set_active_entry_id(second.id); api.detect_local_servers()
			held[1].callback(true, "inert-stale-key")
			helpers.assert_eq(probes.omlx, nil, "same URL and stored key do not grant a replaced entry authority")
			held[2].callback(true, "inert-current-key")
			helpers.assert_eq(probes.omlx.headers.Authorization, "Bearer inert-current-key")
			helpers.assert_eq(probes.omlx.url, first.base_url .. "/models")
			probes.omlx.callback({ ok = false, status = 401, body = '{"error":{"type":"authentication_error"}}' })
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do probes[id].callback({ ok = false, status = 0, body = "" }) end
			helpers.assert_eq(servers.result("omlx").status, servers.STATUS_NEEDS_KEY)
			helpers.assert_eq(servers.result("omlx").models, {})
		end)
	end)
	helpers.it("replaced generic entry refuses an acquired models answer even with identical URL and key (local-configured-affinity)", function()
		isolated(function(api, servers, probes)
			api.set_entries({ { id = "first", provider = "openai", token = "", model = "before", base_url = "http://localhost:8000/v1" } })
			api.detect_local_servers()
			api.set_entries({ { id = "second", provider = "openai", token = "", model = "before", base_url = "http://localhost:8000/v1" } })
			probes.omlx.callback({ ok = true, status = 200, body = '{"data":[{"id":"stale-model"}]}' })
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do probes[id].callback({ ok = false, status = 0, body = "" }) end
			helpers.assert_eq(servers.result("omlx").status, servers.STATUS_DOWN)
			helpers.assert_eq(servers.result("omlx").models, {})
		end)
	end)
end)

helpers.describe("Configured nondefault discovery views (local-configured-views)", function()
	for _, provider in ipairs({ "openai", "openai_compat" }) do
		helpers.it("discovers the configured " .. provider .. " port without registering a local product (local-configured-views)", function()
			isolated(function(api, servers, probes, _, clients)
				local id = "configured:personal"
				clients[id] = { cancel = function() return true end, isSettled = function() return true end,
				onSettled = function(callback) callback(); return true end, get = function(url, headers, callback) probes[id] = { url = url, headers = headers, callback = callback }; return true end }
				local entry = { id = "personal", provider = provider, token = "", model = "before", base_url = "http://127.0.0.1:19423/owned/v1" }
				api.set_entries({ entry }); api.set_active_entry_id(entry.id)
				helpers.assert_true(api.detect_local_servers())
				helpers.assert_eq(probes[id] and probes[id].url, entry.base_url .. "/models", "the configured port must be probed")
				helpers.assert_eq(probes[id].headers.Authorization, nil)
				helpers.assert_eq(table.concat(servers.ORDER, ","), "omlx,lmstudio,llamacpp,jan")
				helpers.assert_eq(api.PROVIDERS[id], nil, "a view never becomes a registered API provider")
				helpers.assert_eq(servers.view_servers()[id].label, api.PROVIDERS[provider].label)
				probes[id].callback({ ok = true, status = 200, body = '{"object":"list","data":[{"id":"mlx-community/Qwen3-8B-4bit","object":"model","owned_by":"omlx"}]}' })
				for _, known in ipairs(servers.ORDER) do probes[known].callback({ ok = false, status = 0, body = "" }) end
				helpers.assert_eq(servers.detected(), { id })
				helpers.assert_eq(servers.result(id).models, { "mlx-community/Qwen3-8B-4bit" })
				helpers.assert_eq(api.local_server_entry(id), entry)
				helpers.assert_eq(api.get_entries(), { entry }, "discovery does not mutate configured rows")
			end)
		end)
	end
end)

helpers.describe("Local discovery native ownership and availability (local-configured-native-owner)", function()
	helpers.it("waits for exact predecessor settlement before dispatching another native request (local-configured-native-owner)", function()
		isolated(function(api, servers, probes, _, clients)
			local settled, observer, starts, cancels = false, nil, 0, 0
			clients.omlx.isSettled = function() return settled end
			clients.omlx.cancel = function() cancels = cancels + 1; return false end
			clients.omlx.onSettled = function(callback) observer = callback; return true end
			local get = clients.omlx.get
			clients.omlx.get = function(...) starts = starts + 1; return get(...) end
			local publications = 0
			api.detect_local_servers(function() publications = publications + 1 end)
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do probes[id].callback({ ok = false, status = 0, body = "" }) end
			helpers.assert_eq(starts, 0); helpers.assert_eq(cancels, 1)
			helpers.assert_eq(publications, 0); helpers.assert_true(servers.is_sweeping())
			settled = true; observer()
			helpers.assert_eq(starts, 1)
			probes.omlx.callback({ ok = true, status = 200, body = '{"data":[{"id":"current-model"}]}' })
			helpers.assert_eq(publications, 1); helpers.assert_eq(servers.result("omlx").models, { "current-model" })
		end)
	end)
	helpers.it("refused observer registration cannot acquire after a synchronous callback (local-configured-native-owner)", function()
		isolated(function(api, servers, probes, _, clients)
			local starts, settled = 0, false
			clients.omlx.isSettled = function() return settled end
			clients.omlx.cancel = function() return false end
			clients.omlx.onSettled = function(callback) settled = true; callback(); return false end
			clients.omlx.get = function() starts = starts + 1; return true end
			api.detect_local_servers()
			for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do probes[id].callback({ ok = false, status = 0, body = "" }) end
			helpers.assert_eq(starts, 0, "the observer ACK precedes native request acquisition")
			helpers.assert_eq(servers.result("omlx").status, servers.STATUS_UNAVAILABLE)
		end)
	end)
	helpers.it("removed configured view retains its exact native HTTP owner until settlement (local-configured-native-owner)", function()
		isolated(function(api, servers, probes, _, clients)
			local id, settled, observer, cancels = "configured:removed", true, nil, 0
			local client = { isSettled = function() return settled end,
				cancel = function() cancels = cancels + 1; return false end,
				onSettled = function(callback) observer = callback; return true end,
				get = function(url, headers, callback) settled = false; probes[id] = { callback = callback }; return true end }
			clients[id] = client
			api.set_entries({ { id = "removed", provider = "openai_compat", token = "", model = "before", base_url = "http://localhost:19423/v1" } })
			api.detect_local_servers()
			local old = probes[id].callback
			api.set_entries({}); api.detect_local_servers()
			helpers.assert_eq(cancels, 1); helpers.assert_eq(clients[id], client)
			old({ ok = true, status = 200, body = '{"data":[{"id":"stale-model"}]}' })
			helpers.assert_eq(servers.result(id), nil)
			settled = true; observer()
			helpers.assert_eq(clients[id], nil, "only this settled native owner is released")
		end)
	end)
	for _, kind in ipairs({ "construction", "dispatch", "sync_false_after_positive" }) do
		helpers.it("reports actual native " .. kind .. " refusal separately from absent servers (local-configured-native-owner)", function()
			isolated(function(api, servers, probes, _, clients, http)
				if kind == "construction" then clients.omlx = nil; http.new = function() error("native fixture construction refusal") end
				elseif kind == "dispatch" then clients.omlx.get = function() return false end
				else clients.omlx.get = function(_, _, callback)
					callback({ ok = true, status = 200, body = '{"data":[{"id":"must-not-publish"}]}' }); return false
				end end
				api.detect_local_servers()
				for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do probes[id].callback({ ok = false, status = 0, body = "" }) end
				helpers.assert_eq(servers.result("omlx").status, servers.STATUS_UNAVAILABLE)
				helpers.assert_eq(servers.result("omlx").models, {}); helpers.assert_eq(servers.detected(), {})
				local rows = require("llm.local_server_menu").rows({ order = servers.view_order(), servers = servers.view_servers(),
					detected = servers.detected(), result = servers.result, backend = "api", paused = false,
					tr = function(key) return key end, format = function(key) return key end,
					actions = { select = function() end, address = function() end, key = function() end, rescan = function() end } })
				helpers.assert_eq(rows[3].label, "healthcheck.status.failed")
				for _, row in ipairs(rows) do helpers.assert_eq(row.label == "menu.llm.local_servers.none", false) end
			end)
		end)
	end
	for _, vector in ipairs({
		{ name = "valid empty models", status = 200, body = '{"object":"list","data":[]}', expected = "up" },
		{ name = "models object", status = 200, body = '{"object":"list","data":{}}', expected = "down" },
		{ name = "models root array", status = 200, body = '[{"id":"foreign"}]', expected = "down" },
		{ name = "models missing endpoint", status = 404, body = '{"error":"not found"}', expected = "down" },
		{ name = "ordinary connection refusal", status = 0, body = '', expected = "down" },
	}) do
		helpers.it("keeps " .. vector.name .. " distinct from infrastructure failure (local-configured-native-owner)", function()
			isolated(function(api, servers, probes)
				api.detect_local_servers()
				probes.omlx.callback({ ok = vector.status == 200, status = vector.status, body = vector.body })
				for _, id in ipairs({ "lmstudio", "llamacpp", "jan" }) do probes[id].callback({ ok = false, status = 0, body = "" }) end
				helpers.assert_eq(servers.result("omlx").status, vector.expected)
				helpers.assert_eq(servers.result("omlx").models, {})
				if vector.expected == "up" then
					local rows = require("llm.local_server_menu").rows({ order = servers.view_order(), servers = servers.view_servers(),
						detected = servers.detected(), result = servers.result, backend = "api", paused = false,
						tr = function(key) return key end, format = function(key) return key end,
						actions = { select = function() error("empty list must not select") end, address = function() end, key = function() end, rescan = function() end } })
					helpers.assert_eq(rows[3].items[1].label, "menu.llm.local_servers.no_models")
					helpers.assert_eq(rows[3].items[1].disabled, true); helpers.assert_eq(rows[3].items[1].action, nil)
				end
			end)
		end)
	end
end)

helpers.describe("Actual AI menu local discovery context (local-configured-native-owner)", function()
	helpers.it("passes the exact live native pause port to local discovery rows (local-configured-native-owner)", function()
		local paused, captured = false, nil
		local native_pause = function() return paused end
		require("tests.support.llm_count_menu_fixture")(function(menu)
			local panel = require("ui.menu.menu_llm.local_server_panel")
			panel.rows = function(ctx) captured = ctx; return {} end
			local backend = require("ui.menu.menu_llm.backend_panel")
			backend.build = function(ctx)
				ctx.local_server_rows(function() return true end)
				return "backend", {}
			end
			menu.build_item()
			helpers.assert_eq(captured and captured.is_paused, native_pause)
			helpers.assert_eq(captured.is_paused(), false)
			paused = true
			helpers.assert_eq(captured.is_paused(), true, "the retained factory context reads the live native owner")
		end, { script_control = { is_paused = native_pause } })
	end)
end)
