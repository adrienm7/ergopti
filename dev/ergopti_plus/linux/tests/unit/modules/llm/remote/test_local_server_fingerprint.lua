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
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")

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
	require("tests.lua.core.local_server_fingerprint_contract").run(read("tests/corpus/llm/local_server_fingerprint.json"),
		read("ai/data/local_servers.json"), helpers)
end)

helpers.describe("Linux local server catalogue fingerprints (local-server-fingerprint)", function()
	helpers.it("reports an unreadable cloud catalogue before refusing local discovery", function()
		local Reader, Logger = require("core.fs.engine.regular_file_reader"), require("core.logger.engine.shim")
		local open, report, errors = Reader.open_source, Logger.error, {}
		Reader.open_source = function(path, ...)
			if path:match("api_providers%.json$") then return nil end
			return open(path, ...)
		end
		Logger.error = function(_, message) errors[#errors + 1] = message end
		local ok, err = pcall(function()
			local catalogue = helpers.load_module("modules.llm.local_server_catalogue")
			local order, _, published = catalogue.load({})
			helpers.assert_eq(#order, 0)
			helpers.assert_eq(published, false)
			helpers.assert_true(#errors > 0, "refusal must be diagnosed")
		end)
		Reader.open_source, Logger.error = open, report
		if not ok then error(err, 0) end
	end)

	helpers.it("the catalogue port hands the shared controller every shared address's fingerprint", function()
		local restore = helpers.keep_loaded({ "modules.llm.local_server_catalogue" })
		local ok, err = pcall(function()
			local Catalogue = helpers.load_module("modules.llm.local_server_catalogue")
			local order, _, published, _, _, _, identities = Catalogue.load({})
			helpers.assert_true(published, "the production catalogue is admitted")
			helpers.assert_eq(#order, #read("ai/data/local_servers.json").server_order)
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
