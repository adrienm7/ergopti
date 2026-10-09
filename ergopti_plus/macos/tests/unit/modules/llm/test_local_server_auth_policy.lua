--- tests/unit/modules/llm/test_local_server_auth_policy.lua

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


helpers.describe("Actual local catalogue publication acknowledgement", function()
	for _, vector in ipairs({
		{ name = "valid empty list", source = '{"server_order":[],"servers":{}}', published = true },
		{ name = "wrong empty order object", source = '{"server_order":{},"servers":{}}', published = false },
		{ name = "wrong empty descriptor array", source = '{"server_order":[],"servers":[]}', published = false },
		{ name = "native-erased null order slot", source = '{"server_order":[null],"servers":{}}', published = false },
		{ name = "malformed source", source = "{ malformed", published = false },
		{ name = "unsupported optional authentication", source = '{"server_order":["independent"],"servers":{"independent":{"label":"Independent","base_url":"http://localhost:4321/v1","auth":"required"}}}', published = false },
	}) do
		helpers.it("(local-provider-publication) " .. vector.name, function()
			helpers.with_stub_scope({ "modules.llm.local_servers", "infra.paths" }, function()
				helpers.load_with_stubs("modules.llm.local_servers")
				local owner_paths = require("infra.paths")
				local original = owner_paths.shared_llm_path
				local path = os.tmpname()
				local file = assert(io.open(path, "wb")); assert(file:write(vector.source)); assert(file:close())
				owner_paths.shared_llm_path = function(name)
					if name == "local_servers.json" then return path end
					return original(name)
				end
				local ok, err = xpcall(function()
					package.loaded["modules.llm.local_servers"] = nil
					local owner = require("modules.llm.local_servers")
					helpers.assert_eq(owner.config_catalogue_published(), vector.published)
					local source = assert(io.open(path, "rb")); local contents = source:read("*a"); assert(source:close())
					helpers.assert_eq(contents, vector.source)
				end, debug.traceback)
				owner_paths.shared_llm_path = original; os.remove(path)
				if not ok then error(err, 0) end
			end)
		end)
	end
end)
