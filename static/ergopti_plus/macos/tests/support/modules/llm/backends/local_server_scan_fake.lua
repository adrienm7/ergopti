--- tests/support/modules/llm/backends/local_server_scan_fake.lua

--- ==============================================================================
--- MODULE: Synchronous Local Server Port Scan Fake
--- DESCRIPTION:
--- Replaces api_remote's asynchronous process scan with an immediate answer,
--- so a detection dispatches its probes before detect_local_servers returns.
--- By default every catalogue server runs at its catalogue address; a test
--- passes per-server overrides to model a stopped server or another port.
--- ==============================================================================

local M = {}

--- Installs the fake on a freshly loaded api_remote.
--- @param api table modules.llm.api_remote.
--- @param overrides table|nil Server id -> fields merged into its result.
--- @return table scans The entries of every scan, for assertions.
function M.install(api, overrides)
	assert(type(api) == "table" and type(api._scan_ports) == "function", "api_remote has no port scan seam")
	local scans = {}
	api._scan_ports = function(entries, on_done)
		scans[#scans + 1] = entries
		local results = {}
		for _, entry in ipairs(entries) do
			local result = { id = entry.id, running = true, pids = { 1 }, base_url = entry.base_url,
				port = tonumber(entry.base_url:match(":(%d+)")), source = "default", detail = "test fake" }
			for key, value in pairs(overrides and overrides[entry.id] or {}) do result[key] = value end
			results[entry.id] = result
		end
		on_done(results)
		return true
	end
	return scans
end

return M
