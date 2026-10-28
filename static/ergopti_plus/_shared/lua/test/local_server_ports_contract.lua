--- _shared/lua/test/local_server_ports_contract.lua

--- ==============================================================================
--- MODULE: Local Server Port Discovery Replay
--- DESCRIPTION:
--- Both Lua drivers replay authored machine readings (process list, settings
--- files, listening sockets) against the actual catalogue descriptors and
--- compare the address each server must be probed at with authored values.
--- ==============================================================================

local M = {}
local Ports = require("llm.local_server_ports")

--- Replays every case through the driver's registered helpers.
--- @param corpus table Authored JSON expectations (local_server_ports.json).
--- @param catalogue table The decoded production local_servers.json.
--- @param decode_json function The driver's JSON decoder.
--- @param helpers table Driver assertion and registration owner.
function M.run(corpus, catalogue, decode_json, helpers)
	assert(corpus.version == 1 and #corpus.cases == 15, "independent port discovery inventory")
	for _, id in ipairs(catalogue.server_order) do
		helpers.it("catalogue discovery descriptor is valid: " .. id, function()
			local descriptor, reason = Ports.descriptor(id, catalogue.servers[id].discovery)
			helpers.assert_true(descriptor ~= nil, reason)
		end)
	end
	for _, case in ipairs(corpus.cases) do
		helpers.it("local server port: " .. case.name, function()
			local server = assert(catalogue.servers[case.server], "case names a catalogue server")
			local descriptor = assert(Ports.descriptor(case.server, server.discovery))
			local context = {
				os = case.os, home = "/Users/u", decode_json = decode_json,
				read_file = function(path) return case.files[path] end,
			}
			local result = Ports.resolve(case.server, descriptor, server.base_url, Ports.parse_processes(case.ps), context)
			if result.needs_listeners then
				local listeners = nil
				if case.lsof then listeners = Ports.parse_lsof(case.lsof) end
				if case.ss then listeners = Ports.parse_ss(case.ss) end
				Ports.apply_listeners(result, listeners)
			end
			local expected = case.expected
			helpers.assert_eq(result.running, expected.running)
			if expected.pids then
				helpers.assert_eq(table.concat(result.pids, ","), table.concat(expected.pids, ","))
			end
			if expected.running then
				helpers.assert_eq(result.source, expected.source)
				helpers.assert_eq(result.port, expected.port)
				helpers.assert_eq(result.base_url, expected.base_url)
				helpers.assert_eq(result.needs_listeners, nil)
			end
		end)
	end
end

return M
