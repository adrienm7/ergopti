--- tests/unit/adapters/network/test_http_client_public_discovery_settlement.lua
--- ==============================================================================
--- MODULE: Public Local Discovery Native HTTP Settlement Regression Tests
--- DESCRIPTION:
--- Composes actual api_remote/local_servers/shared discovery with the real HTTP
--- and timer adapters. Unrelated inference owners are scoped inert dependencies.
--- All HTTP completions and timer objects are local ports; no network is used.
--- ==============================================================================
local helpers = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local OWNED_MODULES = {
	"modules.llm.api_remote", "modules.llm.local_servers", "adapters.http_client",
	"adapters.timer_scheduler", "infra.logger", "error_description", "number_policy",
	"adapters.json_codec", "llm.local_server_auth", "llm.local_server_discovery",
	"llm.provider_config_policy", "json", "modules.llm.provider_uses",
	"infra.timings", "infra.text_utils", "modules.llm.profiles", "modules.llm.parser",
	"modules.llm.api_common", "llm.prompt_builder", "modules.llm.api_token_crypto",
	"modules.llm.progressive_reveal", "modules.llm.remote_response_classifier",
	"llm.remote_formats", "modules.keystats", "adapters.file_system",
}

--- Reads an existing declared backend seam, without production test hooks.
local function upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if name == target then return value end
		if name == nil then break end
	end
	error("Missing production seam: " .. target)
end

local function isolated(scenario)
	helpers.with_stub_scope(OWNED_MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local state = { requests = {}, timers = {}, clients = {} }
		local function dispatch(url, callback)
			state.requests[#state.requests + 1] = { url = url, callback = callback }
			return nil
		end
		local timer = { secondsSinceEpoch = function() return 0 end }
		function timer.new(_, callback)
			local native = { active = false, callback = callback }
			function native:start() self.active = true; return self end
			function native:stop() self.active = false; return self end
			function native:running() return self.active end
			state.timers[#state.timers + 1] = native
			return native
		end
		local HttpClient = helpers.load_with_stubs("adapters.http_client", {
			timer = timer,
			http = {
				asyncGet = function(url, _, callback) return dispatch(url, callback) end,
				asyncPost = function(url, _, _, callback) return dispatch(url, callback) end,
				doAsyncRequest = function(url, _, _, _, callback) return dispatch(url, callback) end,
			},
		})
		local new_client = HttpClient.new
		HttpClient.new = function(options)
			local client = new_client(options)
			state.clients[#state.clients + 1] = client
			return client
		end
		-- These owners are outside detection; their module state is explicitly
		-- scoped and none substitutes the detector, shared sweep or HTTP adapter.
		for _, name in ipairs({ "infra.text_utils", "modules.llm.profiles", "modules.llm.parser",
			"llm.prompt_builder", "modules.llm.api_token_crypto", "modules.llm.progressive_reveal",
			"modules.llm.remote_response_classifier", "llm.remote_formats", "modules.keystats" }) do
			package.loaded[name] = {}
		end
		package.loaded["infra.timings"] = { ms = function() return 1000 end, sec = function() return 1 end }
		package.loaded["modules.llm.api_common"] = { get_retry_policy = function() return 1, 0, 0 end }
		package.loaded["adapters.file_system"] = {
			read_with_status = function(path) return SourceFile.read(path), "ok" end,
		}
		local api = require("modules.llm.api_remote")
		local servers = require("modules.llm.local_servers")
		local clients = upvalue(api.detect_local_servers, "_local_probe_clients")
		local scheduler = package.loaded["adapters.timer_scheduler"]
		local ok, err = xpcall(function() scenario(api, servers, clients, state) end, debug.traceback)
		-- A terminal can release a waiting successor. Drain appended requests too.
		for _, request in ipairs(state.requests) do request.callback(200, '{"data":[]}', {}) end
		for _, client in ipairs(state.clients) do
			client.cancel()
			helpers.assert_true(client.isSettled(), "fixture retains no exact HTTP receipt")
		end
		helpers.assert_eq(scheduler.activeCount(), 0, "fixture retains no scheduler handle")
		for _, native in ipairs(state.timers) do helpers.assert_eq(native:running(), false) end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("Public local discovery owns taskless HTTP exchanges", function()
	helpers.it("public discovery waits for taskless predecessors before replacement (http-native-public-settlement)", function()
		isolated(function(api, servers, _, state)
			helpers.assert_true(api.detect_local_servers())
			local count = #servers.ORDER
			helpers.assert_true(count > 0, "real source catalogue is nonempty")
			helpers.assert_eq(#state.requests, count)
			helpers.assert_true(api.detect_local_servers())
			helpers.assert_eq(#state.requests, count, "accepted logical cancel cannot acquire replacement native requests")
			for index = 1, count do state.requests[index].callback(200, '{"data":[]}', {}) end
			helpers.assert_eq(#state.requests, count * 2, "each exact terminal admits one current successor")
			for index = count + 1, count * 2 do state.requests[index].callback(200, '{"data":[]}', {}) end
			helpers.assert_eq(servers.is_sweeping(), false)
		end)
	end)

	helpers.it("public configured removal retains taskless HTTP owner until terminal (http-native-public-settlement)", function()
		isolated(function(api, _, clients, state)
			api.set_entries({ { id = "native-owned", provider = "openai_compat", token = "",
				model = "owned", base_url = "http://127.0.0.1:19423/owned/v1" } })
			api.detect_local_servers()
			local id = "configured:native-owned"
			local client = clients[id]
			helpers.assert_true(client ~= nil, "configured public view acquired its real HTTP owner")
			local owned
			for _, request in ipairs(state.requests) do
				if request.url == "http://127.0.0.1:19423/owned/v1/models" then owned = request end
			end
			helpers.assert_true(owned ~= nil)
			api.set_entries({})
			api.refresh_local_server_views()
			helpers.assert_eq(clients[id], client, "removed view cannot release a retained native callback")
			helpers.assert_eq(client.isSettled(), false)
			owned.callback(200, '{"data":[]}', {})
			helpers.assert_eq(clients[id], nil, "exact terminal releases the removed owner")
		end)
	end)
end)
