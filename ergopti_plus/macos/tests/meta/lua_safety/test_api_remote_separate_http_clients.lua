--- tests/meta/lua_safety/test_api_remote_separate_http_clients.lua

--- ==============================================================================
--- MODULE: Api_remote.lua separates inference and check clients (meta)
--- DESCRIPTION:
--- api_remote.lua must keep an inference client and a check client so a check never cancels an inference.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_src(selector)
	local s = helpers.read_driver_source(selector)
	return s
end

helpers.describe("api_remote.lua separates inference and check clients", function()

	-- =====================================================================
	-- ===== 7) api_remote.lua: split into _infer_client + _check_client
	-- =====================================================================

	helpers.it("api_remote.lua must use separate _infer_client and _check_client", function()
		local src = read_src("local function load_api_providers") -- modules/llm/api_remote.lua
		assert(src, "modules/llm/api_remote.lua must be readable")
		-- The bug: single HttpClient used for both POST inference and GET health-checks.
		-- http_client.lua cancels the in-flight request on every new call, so a
		-- background ping would silently abort a user's LLM completion.
		assert(
			not src:find("local HttpClient%s*=", 1, false),
			"api_remote.lua: must not use a single shared HttpClient — split into _infer_client and _check_client"
		)
		assert(src:find("_infer_client", 1, true), "api_remote.lua: must declare _infer_client for POST inference")
		assert(src:find("_check_client", 1, true), "api_remote.lua: must declare _check_client for GET health-checks")
		assert(src:find("_infer_client%.post", 1, false), "api_remote.lua: inference must use _infer_client.post")
		-- Health checks go through dispatch_probe, whose models GET (or Backboard
		-- assistant creation) runs on the client it is handed: _check_client
		assert(src:find("dispatch_probe%(_check_client", 1, false),
			"api_remote.lua: health-checks must dispatch on _check_client")
		assert(src:find("return client%.get%(build_models_url", 1, false),
			"api_remote.lua: the models probe must be a GET on the client it is handed")
	end)

end)
