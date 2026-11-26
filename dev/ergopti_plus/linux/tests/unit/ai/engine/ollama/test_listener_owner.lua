--- tests/unit/ai/engine/ollama/test_listener_owner.lua

--- ==============================================================================
--- MODULE: Owned Ollama Listener Regression Cases
--- DESCRIPTION:
--- Replays the kernel's socket and process tables through fake /proc readers:
--- the readiness of the managed Ollama is admitted only from a socket its own
--- process group holds.
---
--- ROOT CAUSE ENCODED:
--- OLL-13: any server answering GET /api/version on the owned port was taken
--- for the managed daemon, so a foreign server on 11435 could answer the first
--- probe before the owned daemon failed to bind.
--- ==============================================================================

local helpers = require("tests.helpers")
local Listener = helpers.load_module("ai.engine.ollama.listener_owner")

local HEADER = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

--- One /proc/net/tcp row.
local function row(address, state, inode)
	return string.format("   0: %s 00000000:0000 %s 00000000:00000000 00:00000000 00000000  1000        0 %s 1 0000000000000000 100 0 0 10 0\n",
		address, state, inode)
end

--- A fake /proc: tables, process groups and descriptor links.
local function proc(spec)
	local files = {
		["/proc/net/tcp"] = spec.tcp and (HEADER .. table.concat(spec.tcp)) or nil,
		["/proc/net/tcp6"] = spec.tcp6 and (HEADER .. table.concat(spec.tcp6)) or nil,
	}
	local pids = {}
	for pid, process in pairs(spec.processes or {}) do
		pids[#pids + 1] = pid
		files["/proc/" .. pid .. "/stat"] = pid .. " (" .. (process.name or "ollama") .. ") S 1 " .. process.pgrp .. " 1 0 -1"
	end
	table.sort(pids)
	return {
		read = function(path)
			if files[path] then return files[path] end
			return nil, 2
		end,
		pids = function() return pids end,
		links = function(pid) return spec.processes[pid].links or {} end,
	}
end

helpers.describe("Owned Ollama listener (oll-13)", function()
	helpers.it("(oll-13) finds the sockets listening on the port, on IPv4 and IPv6", function()
		local ports = proc({ tcp = { row("0100007F:2CAB", "0A", "111"), row("0100007F:2CAB", "01", "112"),
			row("0100007F:2CAA", "0A", "113") }, tcp6 = { row("00000000000000000000000001000000:2CAB", "0A", "114") } })
		local inodes = Listener.listening(11435, ports)
		helpers.assert_true(inodes["111"] and inodes["114"], "both listening sockets of the port")
		helpers.assert_nil(inodes["112"], "an established connection is no listener")
		helpers.assert_nil(inodes["113"], "another port is not read")
	end)

	helpers.it("(oll-13) a kernel without IPv6 still reads its IPv4 table; an unreadable table is refused", function()
		local inodes = Listener.listening(11435, proc({ tcp = { row("0100007F:2CAB", "0A", "7") } }))
		helpers.assert_true(inodes["7"])
		local none, reason = Listener.listening(11435, proc({}))
		helpers.assert_nil(none)
		helpers.assert_eq(reason, "listener_table_unreadable")
	end)

	helpers.it("(oll-13) the socket held by the service's process group is owned", function()
		local ports = proc({ tcp = { row("0100007F:2CAB", "0A", "500") }, processes = {
			["4242"] = { pgrp = 4242, links = { "pipe:[1]" } },
			["4250"] = { pgrp = 4242, name = "ollama runner (x)", links = { "socket:[500]" } },
		} })
		helpers.assert_eq(Listener.owned(11435, 4242, ports), true)
	end)

	helpers.it("(oll-13) a socket held outside the service's group is foreign", function()
		local ports = proc({ tcp = { row("0100007F:2CAB", "0A", "500") }, processes = {
			["4242"] = { pgrp = 4242, links = {} },
			["900"] = { pgrp = 900, links = { "socket:[500]" } },
		} })
		local owned, reason = Listener.owned(11435, 4242, ports)
		helpers.assert_eq(owned, false)
		helpers.assert_eq(reason, "listener_foreign")
	end)

	helpers.it("(oll-13) one foreign socket beside the owned one is refused", function()
		local ports = proc({ tcp = { row("0100007F:2CAB", "0A", "500") }, tcp6 = { row("00000000000000000000000000000000:2CAB", "0A", "501") },
			processes = { ["4242"] = { pgrp = 4242, links = { "socket:[500]" } }, ["900"] = { pgrp = 900, links = { "socket:[501]" } } } })
		helpers.assert_eq(select(2, Listener.owned(11435, 4242, ports)), "listener_foreign")
	end)

	helpers.it("(oll-13) no listener, or no service pid, proves nothing", function()
		helpers.assert_eq(select(2, Listener.owned(11435, 4242, proc({ tcp = {}, processes = {} }))), "listener_absent")
		helpers.assert_eq(select(2, Listener.owned(11435, nil, proc({ tcp = {} }))), "listener_owner_unknown")
	end)
end)

return true
