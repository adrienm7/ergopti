--- tests/unit/modules/llm/remote/test_local_server_auth_policy.lua

--- ==============================================================================
--- MODULE: Local API Optional Authentication Contract
--- DESCRIPTION:
--- Both Lua drivers replay independent credentials and models receipts. The
--- actual catalogue grants capability; a user row or custom URL cannot grant it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Policy = require("llm.local_server_auth")
local Paths = require("infra.paths")

--- Reads the independent shared fixture without deriving its expected verdicts.
--- @param relative string
--- @return table
local function read(relative)
	local file = assert(io.open(Paths.shared(relative), "rb"))
	local root = assert(Json.decode_lossless(file:read("*a")))
	file:close()
	return root
end

helpers.describe("Local API optional authentication policy (local-api-optional-auth)", function()
	local _, servers = Policy.catalogue(read("modules/llm/local_servers.json"), { openai = true, openai_compat = true })
	local corpus = read("tests/corpus/llm/local_server_auth.json")
	for _, vector in ipairs(corpus.auth_cases) do
		helpers.it("auth material: " .. vector.name .. " (local-api-optional-auth)", function()
			helpers.assert_eq(Policy.token_allowed(vector.provider, vector.token, servers), vector.allowed)
		end)
	end
	for _, vector in ipairs(corpus.models_cases) do
		helpers.it("native models receipt: " .. vector.name .. " (local-api-optional-auth)", function()
			local ids = Policy.models_receipt(vector.response)
			helpers.assert_eq(ids ~= nil, vector.admitted)
			if ids then helpers.assert_eq(table.concat(ids, ","), table.concat(vector.models, ",")) end
		end)
	end

	helpers.it("cannot grant cloud, duplicate or malformed capabilities (local-api-optional-auth)", function()
		local order, accepted = Policy.catalogue({ server_order = { "openai", "known", "known", "foreign" }, servers = {
			openai = { label = "Cloud", base_url = "http://localhost:1/v1", auth = "optional" },
			known = { label = "Known", base_url = "http://localhost:2/v1", auth = "optional" },
			foreign = { label = "Foreign", base_url = "http://localhost:3/v1", auth = "required" },
		} }, { openai = true })
		helpers.assert_eq(table.concat(order, ","), "known")
		helpers.assert_eq(accepted.openai, nil)
		helpers.assert_eq(accepted.foreign, nil)
		helpers.assert_eq(Policy.token_allowed("openai", "", accepted), false)
	end)
end)

helpers.describe("Shared local discovery controller", function()
	require("test.local_server_discovery_contract").run(read("tests/corpus/llm/local_server_discovery.json"), helpers)
end)

helpers.describe("Configured endpoint affinity (local-configured-affinity)", function()
	local _, servers = Policy.catalogue(read("modules/llm/local_servers.json"), {})
	local corpus = read("tests/corpus/llm/local_server_affinity.json")
	for _, vector in ipairs(corpus.affinity_cases) do
		helpers.it(vector.name .. " (local-configured-affinity)", function()
			helpers.assert_eq(Policy.entry_matches(vector.provider, vector.base_url, vector.server, servers), vector.matches)
		end)
	end
	helpers.it("accepts literal oMLX model identifiers without using them as endpoint identity (local-configured-affinity)", function()
		helpers.assert_eq(Policy.models_receipt({ ok = true, status = 200, body = corpus.omlx_models_body }), corpus.omlx_model_ids)
	end)
end)

helpers.describe("Configured loopback optional credentials (local-configured-affinity)", function()
	local _, servers = Policy.catalogue(read("modules/llm/local_servers.json"), {})
	for _, vector in ipairs(read("tests/corpus/llm/local_server_affinity.json").entry_auth_cases) do
		helpers.it(vector.name .. " (local-configured-affinity)", function()
			helpers.assert_eq(Policy.entry_token_allowed(vector.provider, vector.token, vector.base_url, servers), vector.allowed)
		end)
	end
end)

helpers.describe("Configured generic endpoint view projection (local-configured-views)", function()
	local _, servers = Policy.catalogue(read("modules/llm/local_servers.json"), {})
	local providers = read("modules/llm/api_providers.json").providers
	for _, vector in ipairs(read("tests/corpus/llm/local_server_affinity.json").configured_view_cases) do
		helpers.it(vector.name .. " (local-configured-views)", function()
			local order, views = Policy.configured_views(vector.entries, servers, providers)
			helpers.assert_eq(order, vector.expected_order); helpers.assert_eq(views, vector.expected_views)
			for _, view in pairs(views) do helpers.assert_eq(view.token, nil); helpers.assert_eq(view.model, nil) end
		end)
	end
end)
