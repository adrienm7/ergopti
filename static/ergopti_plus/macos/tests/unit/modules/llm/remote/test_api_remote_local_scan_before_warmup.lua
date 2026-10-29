--- tests/unit/modules/llm/remote/test_api_remote_local_scan_before_warmup.lua

--- ==============================================================================
--- MODULE: Regression — a local server is located before its first warmup ping
--- DESCRIPTION:
--- A local server entry stored without an address follows where the port scan
--- found its server. No scan ran at startup, so after every reload the warmup
--- pinged the catalogue default port, a server listening elsewhere looked "not
--- running", the AI health dot stayed red and predictions never started. The
--- warmup must locate any local server first, then ping the scanned address.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["modules.llm.api_remote"] = nil
local ApiRemote = helpers.load_with_stubs("modules.llm.api_remote")

local function get_upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

local PROVIDER = "fixture_local"
ApiRemote.PROVIDERS[PROVIDER] = {
	label = "Fixture local", base_url = "http://127.0.0.1:8000/v1",
	default_model = "fixture-model", format = "openai",
}

--- Runs one warmup with a stubbed scan state, scan entry point and HTTP owner.
--- @param entry table Remote entry to warm.
--- @param scan table|nil Port scan result the local server registry returns.
--- @param body function Receives the probe state table.
local function with_fixture(entry, scan, body)
	local LocalServers = get_upvalue(ApiRemote.detect_local_servers, "LocalServers")
	local warmup_client = get_upvalue(ApiRemote.warmup, "_warmup_client")
	helpers.assert_true(LocalServers ~= nil and warmup_client ~= nil, "fixture upvalues must resolve")
	local real = {
		is_local = LocalServers.is_local, port_scan = LocalServers.port_scan,
		detect = ApiRemote.detect_local_servers, get = warmup_client.get,
	}
	local state = { scan = scan, urls = {}, scans = 0 }
	LocalServers.is_local = function(id) return id == PROVIDER end
	LocalServers.port_scan = function(id) return id == PROVIDER and state.scan or nil end
	ApiRemote.detect_local_servers = function(on_done)
		state.scans = state.scans + 1
		state.on_scanned = on_done
		return true
	end
	warmup_client.get = function(url) state.urls[#state.urls + 1] = url end
	local ok, err = pcall(function()
		ApiRemote.set_entries({ entry })
		ApiRemote.set_active_entry_id(entry.id)
		ApiRemote.warmup()
		body(state)
	end)
	LocalServers.is_local, LocalServers.port_scan = real.is_local, real.port_scan
	ApiRemote.detect_local_servers, warmup_client.get = real.detect, real.get
	ApiRemote.set_active_entry_id("")
	if not ok then error(err) end
end

helpers.describe("api_remote locates a local server before its warmup ping", function()
	helpers.it("(local-scan-before-warmup) scans first, then pings the scanned port instead of the default", function()
		with_fixture({ id = "local-a", provider = PROVIDER, base_url = "", model = "m", token = "t" }, nil, function(state)
			helpers.assert_eq(state.scans, 1, "an unscanned local entry must trigger a port scan")
			helpers.assert_eq(#state.urls, 0, "no ping may go to the default port before the scan")
			state.scan = { running = true, base_url = "http://127.0.0.1:8181/v1" }
			state.on_scanned(true)
			helpers.assert_eq(#state.urls, 1, "the ping follows the scan")
			helpers.assert_true(state.urls[1]:find("127.0.0.1:8181", 1, true) ~= nil, state.urls[1])
		end)
	end)

	helpers.it("(local-scan-before-warmup) still pings the default when the scan finds nothing", function()
		with_fixture({ id = "local-b", provider = PROVIDER, base_url = "", model = "m", token = "t" }, nil, function(state)
			state.on_scanned(false)
			helpers.assert_eq(#state.urls, 1, "a scan that finds nothing must not stall the warmup")
			helpers.assert_true(state.urls[1]:find("127.0.0.1:8000", 1, true) ~= nil, state.urls[1])
		end)
	end)

	helpers.it("(local-scan-before-warmup) pings at once when the server is already located", function()
		local scan = { running = true, base_url = "http://127.0.0.1:1234/v1" }
		with_fixture({ id = "local-c", provider = PROVIDER, base_url = "", model = "m", token = "t" }, scan, function(state)
			helpers.assert_eq(state.scans, 0)
			helpers.assert_eq(#state.urls, 1)
			helpers.assert_true(state.urls[1]:find("127.0.0.1:1234", 1, true) ~= nil, state.urls[1])
		end)
	end)

	helpers.it("(local-scan-before-warmup) pings at once an address the user typed", function()
		local entry = { id = "local-d", provider = PROVIDER, base_url = "http://127.0.0.1:9999/v1", model = "m", token = "t" }
		with_fixture(entry, nil, function(state)
			helpers.assert_eq(state.scans, 0)
			helpers.assert_eq(#state.urls, 1)
			helpers.assert_true(state.urls[1]:find("127.0.0.1:9999", 1, true) ~= nil, state.urls[1])
		end)
	end)

	helpers.it("(local-scan-before-warmup) drops the deferred ping after the active entry changes", function()
		with_fixture({ id = "local-e", provider = PROVIDER, base_url = "", model = "m", token = "t" }, nil, function(state)
			ApiRemote.set_active_entry_id("")
			state.on_scanned(true)
			helpers.assert_eq(#state.urls, 0, "a scan started for an old entry cannot ping for it")
		end)
	end)
end)
