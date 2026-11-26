--- ai/engine/ollama/listener_owner.lua

--- ==============================================================================
--- MODULE: Owned Ollama Listener (Linux)
--- DESCRIPTION:
--- Tells which processes hold the TCP sockets listening on a port, from the
--- kernel's own tables (/proc/net/tcp, /proc/net/tcp6, /proc/<pid>/fd), so the
--- runtime repair admits readiness only from the daemon it started, as Windows
--- admits it only from its child's socket (ollama-runtime-launch.ps1).
---
--- FEATURES & RATIONALE:
--- 1. A listener is ours when every socket listening on the port is held by a
---    process of the service's process group: the daemon is spawned detached,
---    so it leads its own group, and under the sign-in relay the daemon is the
---    relay's child in that same group.
--- 2. A pid that vanishes during the walk, or whose descriptors /proc hides,
---    proves nothing: a socket without a proven holder in the group is foreign.
--- 3. Read once per readiness answer, never on the input path: the walk reads
---    one stat line per process and the descriptors of the group's members only.
--- ==============================================================================

local M = {}

local available, native = pcall(require, "luv")
if not available then native = nil end

-- The TCP state code of a listening socket in /proc/net/tcp (TCP_LISTEN).
local LISTEN_STATE = "0A"
-- The kernel's tables; tcp6 is absent only on a kernel built without IPv6.
local TABLES = { { path = "/proc/net/tcp", required = true }, { path = "/proc/net/tcp6", required = false } }
-- ENOENT, as io.open reports it.
local ENOENT = 2





-- =======================================
-- =======================================
-- ======= 1/ Native /proc Readers =======
-- =======================================
-- =======================================

--- Reads a whole /proc file.
--- @param path string
--- @return string|nil text
--- @return number|nil errno
local function read_file(path)
	local handle, _, code = io.open(path, "rb")
	if not handle then return nil, code end
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Lists the numeric entries of a /proc directory.
--- @param path string
--- @return table|nil names
local function list(path)
	if not native then return nil end
	local ok, iterator = pcall(native.fs_scandir, path)
	if not ok or not iterator then return nil end
	local names = {}
	while true do
		local name = native.fs_scandir_next(iterator)
		if name == nil then break end
		if name:match("^%d+$") then names[#names + 1] = name end
	end
	return names
end

local DEFAULT_PORTS = {
	read = read_file,
	pids = function() return list("/proc") end,
	links = function(pid)
		local descriptors = list("/proc/" .. pid .. "/fd")
		if not descriptors then return {} end
		local targets = {}
		for _, fd in ipairs(descriptors) do
			local ok, target = pcall(native.fs_readlink, "/proc/" .. pid .. "/fd/" .. fd)
			if ok and type(target) == "string" then targets[#targets + 1] = target end
		end
		return targets
	end,
}





-- ==================================
-- ==================================
-- ======= 2/ Listener Policy =======
-- ==================================
-- ==================================

--- The process group of a pid, from /proc/<pid>/stat (its fifth field, after
--- the command name, which may itself hold spaces and parentheses).
--- @param read function
--- @param pid string
--- @return number|nil group
local function group(read, pid)
	local stat = read("/proc/" .. pid .. "/stat")
	if type(stat) ~= "string" then return nil end
	local rest = stat:match("^.*%)%s+(.*)$")
	if not rest then return nil end
	local _, _, pgrp = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
	return tonumber(pgrp)
end

--- The inodes of the sockets listening on a TCP port, on any address.
--- @param port number
--- @param ports table|nil { read } (tests); the kernel's tables otherwise.
--- @return table|nil inodes Set of inode strings.
--- @return string|nil reason
function M.listening(port, ports)
	ports = ports or DEFAULT_PORTS
	if type(port) ~= "number" or port < 1 or port > 65535 or port % 1 ~= 0 then return nil, "listener_port_invalid" end
	local suffix = string.format(":%04X", port)
	local inodes = {}
	for _, table_spec in ipairs(TABLES) do
		local text, code = ports.read(table_spec.path)
		if type(text) ~= "string" then
			if table_spec.required or code ~= ENOENT then return nil, "listener_table_unreadable" end
		else
			for line in text:gmatch("[^\n]+") do
				local fields = {}
				for field in line:gmatch("%S+") do fields[#fields + 1] = field end
				local address, state, inode = fields[2], fields[4], fields[10]
				if address and state == LISTEN_STATE and address:sub(-#suffix):upper() == suffix
					and inode and inode:match("^%d+$") and inode ~= "0" then
					inodes[inode] = true
				end
			end
		end
	end
	return inodes
end

--- Whether every socket listening on the port belongs to the process group.
--- @param port number
--- @param pgid number The service's pid, the leader of its own group.
--- @param ports table|nil { read, pids, links } (tests).
--- @return boolean owned
--- @return string|nil reason listener_absent, listener_foreign or a read refusal.
function M.owned(port, pgid, ports)
	ports = ports or DEFAULT_PORTS
	if type(pgid) ~= "number" or pgid < 1 or pgid % 1 ~= 0 then return false, "listener_owner_unknown" end
	local inodes, reason = M.listening(port, ports)
	if not inodes then return false, reason end
	if next(inodes) == nil then return false, "listener_absent" end
	local pids = ports.pids()
	if type(pids) ~= "table" then return false, "listener_processes_unreadable" end
	local held = {}
	for _, pid in ipairs(pids) do
		if group(ports.read, pid) == pgid then
			for _, target in ipairs(ports.links(pid) or {}) do
				local inode = type(target) == "string" and target:match("^socket:%[(%d+)%]$")
				if inode and inodes[inode] then held[inode] = true end
			end
		end
	end
	for inode in pairs(inodes) do
		if not held[inode] then return false, "listener_foreign" end
	end
	return true
end

return M
