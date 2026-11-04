--- tests/unit/modules/llm/remote/test_local_server_fingerprint.lua

--- ==============================================================================
--- MODULE: Local Server Fingerprint Contract
--- DESCRIPTION:
--- Replays the shared fingerprint vectors against the actual catalogue: vLLM
--- answering on oMLX's port 8000 and TabbyAPI on text-generation-webui's port
--- 5000 are kept as one row named after the server that answered, and the
--- Linux catalogue port hands those fingerprints to the discovery owner
--- (test_local_server_discovery drives that owner's views and menu rows).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")

--- Reads one shared JSON file.
--- @param relative string
--- @return table
local function read(relative)
	local file = assert(io.open(Paths.shared(relative), "rb"))
	local root = assert(Json.decode(file:read("*a")))
	file:close()
	return root
end

helpers.describe("Local server fingerprint (local-server-fingerprint)", function()
	require("test.local_server_fingerprint_contract").run(read("tests/corpus/llm/local_server_fingerprint.json"),
		read("modules/llm/local_servers.json"), helpers)
end)

helpers.describe("Linux local server catalogue fingerprints (local-server-fingerprint)", function()
	helpers.it("the catalogue port hands the shared controller every shared address's fingerprint", function()
		local restore = helpers.keep_loaded({ "modules.llm.local_server_catalogue" })
		local ok, err = pcall(function()
			local Catalogue = helpers.load_module("modules.llm.local_server_catalogue")
			local order, _, published, _, _, _, identities = Catalogue.load({})
			helpers.assert_true(published, "the production catalogue is admitted")
			helpers.assert_eq(#order, #read("modules/llm/local_servers.json").server_order)
			helpers.assert_eq(identities.vllm.group, { "omlx", "vllm" })
			helpers.assert_eq(identities.tabbyapi.group, { "textgen_webui", "tabbyapi" })
			helpers.assert_eq(identities.vllm.rule, { model_field = "owned_by", equals = "vllm" })
			helpers.assert_eq(identities.tabbyapi.rule, { model_field = "owned_by", equals = "tabbyAPI" })
			helpers.assert_eq(identities.llamacpp, nil, "an unshared address is never fingerprinted")
		end)
		restore()
		assert(ok, err)
	end)
end)
