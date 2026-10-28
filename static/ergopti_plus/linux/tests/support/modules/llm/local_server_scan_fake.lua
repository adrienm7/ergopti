--- tests/support/modules/llm/local_server_scan_fake.lua

--- ==============================================================================
--- MODULE: Synchronous Local Server Port Scan Fake
--- DESCRIPTION:
--- Replaces modules/llm/local_server_ports.lua before local_servers loads, so
--- a rescan dispatches its probes before it returns. By default every
--- catalogue server runs at its catalogue address; a test passes per-server
--- overrides to model a stopped server or another port.
--- ==============================================================================

local M = {}

--- Installs the fake module into package.loaded.
--- @param overrides table|nil Server id -> fields merged into its result.
--- @return table scans The entries of every scan, for assertions.
function M.install(overrides)
	local scans = {}
	package.loaded["modules.llm.local_server_ports"] = { scan = function(entries, on_done)
		scans[#scans + 1] = entries
		local results = {}
		for _, entry in ipairs(entries) do
			local result = { id = entry.id, running = true, pids = { 1 }, base_url = entry.base_url,
				port = tonumber(entry.base_url:match(":(%d+)")), source = "default", detail = "test fake" }
			for key, value in pairs(overrides and overrides[entry.id] or {}) do result[key] = value end
			results[entry.id] = result
		end
		on_done(results)
	end }
	return scans
end

return M
