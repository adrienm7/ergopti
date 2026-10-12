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
			clients[id] = { get = function(url, headers, callback)
				probes[id] = { url = url, headers = headers, callback = callback }
				return true
			end }
		end
		local crypto = upvalue(api.detect_local_servers, "TokenCrypto")
		local original_decrypt = crypto.decrypt_async
		local ok, err = xpcall(function() scenario(api, servers, probes, crypto) end, debug.traceback)
		crypto.decrypt_async = original_decrypt
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
	helpers.it("foreign configured origin and path never acquire catalogue credentials (local-configured-affinity)", function()
		for _, base in ipairs({ "http://localhost:8000/foreign/v1", "https://remote.example/v1" }) do
			isolated(function(api, _, probes, crypto)
				local decrypts = 0
				crypto.decrypt_async = function() decrypts = decrypts + 1; error("Foreign secret must not be read") end
				api.set_entries({ { id = "foreign", provider = "openai", token = "foreign-reference", model = "before", base_url = base } })
				api.detect_local_servers()
				helpers.assert_eq(decrypts, 0)
				helpers.assert_eq(probes.omlx.url, "http://localhost:8000/v1/models")
				helpers.assert_eq(probes.omlx.headers.Authorization, nil)
			end)
		end
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
