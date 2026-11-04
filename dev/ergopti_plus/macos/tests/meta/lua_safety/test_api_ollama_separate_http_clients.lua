--- tests/meta/lua_safety/test_api_ollama_separate_http_clients.lua

--- ==============================================================================
--- MODULE: Api_ollama.lua separates inference and check clients (meta)
--- DESCRIPTION:
--- api_ollama.lua must keep an inference client and a check client.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

helpers.describe("api_ollama.lua separates inference and check clients", function()

	-- ====================================================================
	-- ===== 5) HTTP client singleton — split into infer + check clients
	-- ====================================================================

	helpers.it("api_ollama.lua must use separate _infer_client and _check_client", function()
		local src = read_source("local function read_ollama_port_override") -- modules/llm/api_ollama.lua
		assert(src, "modules/llm/api_ollama.lua must be readable")
		-- The bug: a single HttpClient is reused for both inference POST /api/chat
		-- and health-check GET /api/tags. A background ping would cancel any
		-- in-flight completion request, leaving the UI frozen.
		-- The fix: two independent clients.
		assert(
			not src:find("local HttpClient%s*=", 1, false),
			"api_ollama.lua: must not use a single shared HttpClient — " ..
			"split into _infer_client and _check_client"
		)
		assert(
			src:find("_infer_client", 1, true),
			"api_ollama.lua: must declare _infer_client for inference POST calls"
		)
		assert(
			src:find("_check_client", 1, true),
			"api_ollama.lua: must declare _check_client for health-check GET calls"
		)
		assert(
			src:find("_check_client%.get", 1, false),
			"api_ollama.lua: check_availability() must use _check_client.get, not the shared client"
		)
		assert(
			src:find("_infer_client%.post", 1, false),
			"api_ollama.lua: inference calls must use _infer_client.post, not the shared client"
		)
	end)

end)
