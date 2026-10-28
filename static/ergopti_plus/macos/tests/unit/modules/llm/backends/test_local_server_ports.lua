--- tests/unit/modules/llm/backends/test_local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Discovery Contract
--- DESCRIPTION:
--- Replays the shared machine readings (process list, settings files,
--- listening sockets) against the actual catalogue: a server on a non-default
--- port is found, the settings-file port is used, and a server whose process
--- does not run is not probed.
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

helpers.describe("Local server port discovery (local-server-ports)", function()
	require("test.local_server_ports_contract").run(read("tests/corpus/llm/local_server_ports.json"),
		read("modules/llm/local_servers.json"), Json.decode, helpers)
end)
