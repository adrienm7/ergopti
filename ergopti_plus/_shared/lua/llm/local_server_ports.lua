--- _shared/lua/llm/local_server_ports.lua

--- ==============================================================================
--- MODULE: Local Server Port Discovery Policy
--- DESCRIPTION:
--- Decides where a catalogue local server listens, from what the driver read
--- of the machine: the process list, the server's own settings file and the
--- process's listening TCP ports. Pure: the driver runs the commands
--- asynchronously and injects their text and a file reader.
---
--- FEATURES & RATIONALE:
--- 1. No process, no probe: a catalogue server whose process the process list
---    does not show is not probed, so a user-configurable port is never
---    guessed blindly.
--- 2. The port comes from the first source that gives one, in this order:
---    the process's command-line flag (what the server was started with), the
---    server's settings file (what it reads at start), the listening TCP ports
---    of its process, and only then the catalogue default, reported as such.
---    oMLX lets the user change its port (8000 by default) in its app, which
---    stores it in settings.json; a sweep that probed 8000 only found nothing.
--- 3. Every result names its source and detail, so the log says which port
---    was tried and why.
--- 4. The process lookup asks only for the catalogue's processes (pgrep with
---    M.process_pattern), never for every argument of every process: a full
---    listing of a managed Mac outgrew the pipe hs.task drains only at exit,
---    so ps blocked until its deadline and the sweep read nothing.
--- 5. The settings files and the listening ports do not depend on the process
---    list: when it is unreadable, a server is still probed at its settings
---    port, else at a port a process of its name listens on, and only then at
---    its catalogue default.
--- ==============================================================================

local TableUtil = require("table_util")
local TextUtils = require("text_utils")

local M = {}

M.SOURCE_CLI       = "cli"
M.SOURCE_CONFIG    = "config"
M.SOURCE_LISTENING = "listening"
M.SOURCE_DEFAULT   = "default"

-- The operating-system names a settings-file descriptor may restrict itself to
local OS_NAMES = { macos = true, linux = true, windows = true }

-- The detail every result of a sweep without a process list carries
local UNLISTED = "process list unreadable"

local resolve_config





-- =====================================
-- =====================================
-- ======= 1/ Descriptor ===============
-- =====================================
-- =====================================

--- Tells whether a value is a dense array of non-empty strings.
--- @param value any
--- @return boolean
local function string_list(value)
	if type(value) ~= "table" then return false end
	for index = 1, TableUtil.count(value) do
		if type(value[index]) ~= "string" or value[index] == "" then return false end
	end
	return true
end

--- Validates the discovery descriptor of one catalogue server.
--- @param id string Server id.
--- @param raw any The server's "discovery" object of local_servers.json.
--- @return table|nil descriptor { process_names, command_lines, port_flags, address_flags, config_files }.
--- @return string|nil reason Why the descriptor is refused.
function M.descriptor(id, raw)
	if type(raw) ~= "table" then return nil, "server '" .. tostring(id) .. "' has no discovery object" end
	for _, key in ipairs({ "process_names", "command_lines", "port_flags", "address_flags" }) do
		if raw[key] ~= nil and not string_list(raw[key]) then
			return nil, "server '" .. id .. "' discovery." .. key .. " is not a list of strings"
		end
	end
	local names, lines = raw.process_names or {}, raw.command_lines or {}
	if #names + #lines == 0 then
		return nil, "server '" .. id .. "' declares no process name nor command line"
	end
	local configs = {}
	if raw.config_files ~= nil and type(raw.config_files) ~= "table" then
		return nil, "server '" .. id .. "' discovery.config_files is not a list"
	end
	for index, config in ipairs(raw.config_files or {}) do
		local valid = type(config) == "table" and string_list(config.os) and #config.os > 0
			and type(config.dir) == "string" and config.dir ~= ""
			and type(config.file) == "string" and config.file ~= ""
			and type(config.port_key) == "string" and config.port_key:match("^[%w_]+[%w_%.]*$") ~= nil
			and (config.dir_file == nil or (type(config.dir_file) == "string" and config.dir_file ~= ""))
			and (config.key_key == nil or (type(config.key_key) == "string" and config.key_key:match("^[%w_]+[%w_%.]*$") ~= nil))
		for _, os_name in ipairs(valid and config.os or {}) do valid = valid and OS_NAMES[os_name] == true end
		if not valid then
			return nil, "server '" .. id .. "' discovery.config_files[" .. index .. "] is malformed"
		end
		configs[#configs + 1] = config
	end
	return {
		process_names = names, command_lines = lines,
		port_flags = raw.port_flags or {}, address_flags = raw.address_flags or {},
		config_files = configs,
	}, nil
end





-- =====================================
-- =====================================
-- ======= 2/ Machine Readings =========
-- =====================================
-- =====================================

--- Parses "pid command line" rows (ps -o pid=,args=; the Windows driver
--- composes the same rows from its process list).
--- @param text string
--- @return table processes Array of { pid = number, command = string }.
function M.parse_processes(text)
	local processes = {}
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		local pid, command = line:match("^%s*(%d+)%s+(.-)%s*$")
		if pid and command ~= "" then processes[#processes + 1] = { pid = tonumber(pid), command = command } end
	end
	return processes
end

--- Splits a listening address into its host and port.
--- @param address string "127.0.0.1:8181", "*:8181", "[::1]:8181" or "0.0.0.0:8181".
--- @return string|nil host
--- @return number|nil port
local function split_address(address)
	local host, port = tostring(address):match("^(.*):(%d+)$")
	port = tonumber(port)
	if not host or not port or port < 1 or port > 65535 then return nil, nil end
	return host, port
end

--- Parses lsof -F pn (or -F pcn) output (macOS): a "p<pid>" line, its
--- optional "c<command name>" line, then its "n<address>" lines.
--- @param text string
--- @return table listeners Array of { pid, host, port, command|nil }.
function M.parse_lsof(text)
	local listeners, pid, command = {}, nil, nil
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		local tag, value = line:sub(1, 1), line:sub(2)
		if tag == "p" then pid, command = tonumber(value), nil
		elseif tag == "c" and pid then command = value ~= "" and value or nil
		elseif tag == "n" and pid then
			local host, port = split_address(value:match("^(%S+)"))
			if port then listeners[#listeners + 1] = { pid = pid, host = host, port = port, command = command } end
		end
	end
	return listeners
end

--- Parses ss -Hltnp output (Linux): local address in column 4, owners as
--- users:(("name",pid=N,fd=M),…).
--- @param text string
--- @return table listeners Array of { pid, host, port, command }.
function M.parse_ss(text)
	local listeners = {}
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		local columns = {}
		for column in line:gmatch("%S+") do columns[#columns + 1] = column end
		local host, port = split_address(columns[4] or "")
		if port then
			for name, pid in line:gmatch('"([^"]*)",pid=(%d+)') do
				listeners[#listeners + 1] = { pid = tonumber(pid), host = host, port = port, command = name }
			end
		end
	end
	return listeners
end

--- Escapes the extended regular expression operators of a literal.
--- @param text string
--- @return string
local function regex_literal(text)
	return (text:gsub("[%^%$%.%[%]|%(%)%*%+%?{}\\]", "\\%0"))
end

--- Builds the extended regular expression a process lookup (pgrep -f -i)
--- matches the command lines with: each process name as the executable's file
--- name, each command-line fragment as a substring. M.matches decides on the
--- rows it returns; the pattern only keeps the listing to those candidates.
--- @param entries table Array of { descriptor } (catalogue order).
--- @return string pattern
function M.process_pattern(entries)
	local alternatives = {}
	for _, entry in ipairs(entries) do
		for _, name in ipairs(entry.descriptor.process_names) do
			alternatives[#alternatives + 1] = "(^|/)" .. regex_literal(name) .. "(\\.exe)?( |$)"
		end
		for _, fragment in ipairs(entry.descriptor.command_lines) do
			alternatives[#alternatives + 1] = regex_literal(fragment)
		end
	end
	assert(#alternatives > 0, "local server process lookup has no process name")
	return table.concat(alternatives, "|")
end





-- =====================================
-- =====================================
-- ======= 3/ Resolution ===============
-- =====================================
-- =====================================

--- Tells whether a command line runs one of the descriptor's processes. A
--- process name is the executable's file name (".exe" optional) at the start
--- of the line or after a path separator; a command line fragment matches as
--- a plain substring. Both ignore case.
--- @param descriptor table From M.descriptor.
--- @param command string
--- @return boolean
function M.matches(descriptor, command)
	local line = command:lower()
	for _, name in ipairs(descriptor.process_names) do
		local wanted = name:lower()
		for _, form in ipairs({ wanted, wanted .. ".exe" }) do
			local from = 1
			while true do
				local first, last = line:find(form, from, true)
				if not first then break end
				local before = first == 1 and "" or line:sub(first - 1, first - 1)
				local after = line:sub(last + 1, last + 1)
				if (before == "" or before == "/" or before == "\\") and (after == "" or after == " ") then return true end
				from = first + 1
			end
		end
	end
	for _, fragment in ipairs(descriptor.command_lines) do
		if line:find(fragment:lower(), 1, true) then return true end
	end
	return false
end

--- Reads a valid TCP port.
--- @param value any
--- @return number|nil
local function valid_port(value)
	local port = tonumber(value)
	if not port or port ~= math.floor(port) or port < 1 or port > 65535 then return nil end
	return port
end

--- Reads the port a command line passes: "--port N", "--port=N", or an
--- address flag "--address [host]:N".
--- @param descriptor table
--- @param command string
--- @return number|nil port
--- @return string|nil flag
local function port_from_command(descriptor, command)
	local tokens = {}
	for token in command:gmatch("%S+") do tokens[#tokens + 1] = token end
	for index, token in ipairs(tokens) do
		for _, flag in ipairs(descriptor.port_flags) do
			local value = token == flag and tokens[index + 1] or (token:sub(1, #flag + 1) == flag .. "=" and token:sub(#flag + 2))
			local port = value and valid_port(value)
			if port then return port, flag end
		end
		for _, flag in ipairs(descriptor.address_flags) do
			local value = token == flag and tokens[index + 1] or (token:sub(1, #flag + 1) == flag .. "=" and token:sub(#flag + 2))
			local port = value and valid_port(value:match(":(%d+)$"))
			if port then return port, flag end
		end
	end
	return nil, nil
end

--- Expands a leading "~" against the home directory.
--- @param path string
--- @param home string
--- @return string
local function expand(path, home)
	if path == "~" then return home end
	if path:sub(1, 2) == "~/" then return home .. path:sub(2) end
	return path
end

--- Reads the decoded settings file of one config_files entry.
--- @param config table A config_files entry.
--- @param context table { home, read_file, decode_json }.
--- @return table|nil root The decoded file, nil when absent or malformed.
--- @return string path The file read.
--- @return string|nil problem Why a present file gave nothing.
local function read_config(config, context)
	local dir = expand(config.dir, context.home)
	if config.dir_file then
		-- A pointer file holding the data folder the user moved the server to
		local pointer = context.read_file(expand(config.dir_file, context.home))
		local moved = type(pointer) == "string" and TextUtils.trim(pointer) or ""
		if moved ~= "" then dir = expand(moved, context.home) end
	end
	local path = dir:gsub("/+$", "") .. "/" .. config.file
	local raw = context.read_file(path)
	if type(raw) ~= "string" then return nil, path, nil end
	local ok, root = pcall(context.decode_json, raw)
	if not ok or type(root) ~= "table" then return nil, path, "malformed JSON" end
	return root, path, nil
end

--- Follows a dotted key through a decoded settings file.
--- @param root table
--- @param dotted string "server.port".
--- @return any
local function dotted_value(root, dotted)
	local node = root
	for key in dotted:gmatch("[^%.]+") do
		node = type(node) == "table" and node[key] or nil
	end
	return node
end

--- Reads the port a settings file holds, with its dotted key.
--- @param config table A config_files entry.
--- @param context table { home, read_file, decode_json }.
--- @return number|nil port
--- @return string|nil path The file that gave it.
--- @return string|nil problem Why a present file gave none.
local function port_from_config(config, context)
	local root, path, problem = read_config(config, context)
	if not root then return nil, path, problem end
	local node = dotted_value(root, config.port_key)
	if node == nil then return nil, path, nil end
	local port = valid_port(node)
	if not port then return nil, path, config.port_key .. " is not a TCP port" end
	return port, path, nil
end

--- Replaces the port, and when asked the host, of a catalogue base URL.
--- @param base_url string "http://127.0.0.1:8000/v1".
--- @param port number
--- @param host string|nil Host literal, nil to keep the catalogue's.
--- @return string
function M.with_port(base_url, port, host)
	local scheme, old_host, rest = base_url:match("^(https?://)(%[[^%]]+%]):%d+(.*)$")
	if not scheme then scheme, old_host, rest = base_url:match("^(https?://)([^/:]+):%d+(.*)$") end
	if not scheme then
		scheme, old_host, rest = base_url:match("^(https?://)([^/:]+)(.*)$")
		assert(scheme, "catalogue base_url has no host: " .. tostring(base_url))
	end
	return scheme .. (host or old_host) .. ":" .. tostring(port) .. rest
end

--- Reads the catalogue default port of a base URL.
--- @param base_url string
--- @return number
function M.default_port(base_url)
	local port = valid_port(base_url:match("^https?://[^/]-:(%d+)"))
	assert(port, "catalogue base_url names no port: " .. tostring(base_url))
	return port
end

--- Reads the port of the first applicable settings file that gives one.
--- @param result table A result whose process runs or may run.
--- @param descriptor table From M.descriptor.
--- @param base_url string The catalogue base URL.
--- @param context table { os, home, read_file, decode_json }.
--- @return table result With source config, or needs_listeners and the problems met.
resolve_config = function(result, descriptor, base_url, context)
	local problems = {}
	for _, config in ipairs(descriptor.config_files) do
		local applies = false
		for _, os_name in ipairs(config.os) do applies = applies or os_name == context.os end
		if applies then
			local port, path, problem = port_from_config(config, context)
			if port then
				result.port, result.source, result.detail = port, M.SOURCE_CONFIG, path
				result.base_url = M.with_port(base_url, port)
				return result
			end
			problems[#problems + 1] = path .. (problem and (": " .. problem) or ": no port")
		end
	end
	result.needs_listeners = true
	result.detail = #problems > 0 and table.concat(problems, "; ") or nil
	return result
end

--- Reads the API key the server's own settings file requires (key_key): a
--- server started with authentication answers 401 to a keyless probe, and
--- the user never typed a key the server already holds (oMLX auth.api_key).
--- The key is only returned, never put in the result's detail nor logged.
--- @param descriptor table From M.descriptor.
--- @param context table { os, home, read_file, decode_json }.
--- @return string|nil key
local function key_from_configs(descriptor, context)
	for _, config in ipairs(descriptor.config_files) do
		local applies = false
		for _, os_name in ipairs(config.os) do applies = applies or os_name == context.os end
		if applies and config.key_key then
			local root = read_config(config, context)
			local key = root and dotted_value(root, config.key_key)
			if type(key) == "string" and key ~= "" and not key:find("[%c%s]") then return key end
		end
	end
	return nil
end

--- Reads the API key the server's own settings file requires (key_key): a
--- server started with authentication answers 401 to a keyless probe, and
--- the user never typed a key the server already holds (oMLX auth.api_key).
--- The key is only returned, never put in the result's detail nor logged.
--- @param descriptor table From M.descriptor.
--- @param context table { os, home, read_file, decode_json }.
--- @return string|nil key
local function key_from_configs(descriptor, context)
	for _, config in ipairs(descriptor.config_files) do
		local applies = false
		for _, os_name in ipairs(config.os) do applies = applies or os_name == context.os end
		if applies and config.key_key then
			local root = read_config(config, context)
			local key = root and dotted_value(root, config.key_key)
			if type(key) == "string" and key ~= "" and not key:find("[%c%s]") then return key end
		end
	end
	return nil
end

--- Resolves one server from the process list and its settings files.
--- @param id string Server id.
--- @param descriptor table From M.descriptor.
--- @param base_url string The catalogue base URL.
--- @param processes table From M.parse_processes.
--- @param context table { os, home, read_file(path) -> string|nil, decode_json }.
--- @return table result { id, running, pids, base_url, port, source, detail,
---        needs_listeners } where needs_listeners asks for M.apply_listeners.
function M.resolve(id, descriptor, base_url, processes, context)
	local result = { id = id, running = false, pids = {}, base_url = base_url, port = M.default_port(base_url) }
	local cli_port, cli_flag = nil, nil
	for _, process in ipairs(processes) do
		if M.matches(descriptor, process.command) then
			result.pids[#result.pids + 1] = process.pid
			if not cli_port then cli_port, cli_flag = port_from_command(descriptor, process.command) end
		end
	end
	if #result.pids == 0 then
		result.detail = "no running process"
		return result
	end
	result.running = true
	result.api_key = key_from_configs(descriptor, context)
	if cli_port then
		result.port, result.source, result.detail = cli_port, M.SOURCE_CLI, cli_flag
		result.base_url = M.with_port(base_url, cli_port)
		return result
	end
	return resolve_config(result, descriptor, base_url, context)
end

--- Resolves one server without a process list: its settings file, else it
--- asks for every listening port (M.apply_unlisted_listeners). The process
--- is not known to run, so the result is probed, its pids unknown.
--- @param id string Server id.
--- @param descriptor table From M.descriptor.
--- @param base_url string The catalogue base URL.
--- @param context table { os, home, read_file(path) -> string|nil, decode_json }.
--- @return table result As M.resolve, with needs_all_listeners instead of needs_listeners.
function M.resolve_unlisted(id, descriptor, base_url, context)
	local result = { id = id, running = true, pids = {}, base_url = base_url, port = M.default_port(base_url) }
	result.api_key = key_from_configs(descriptor, context)
	resolve_config(result, descriptor, base_url, context)
	if result.needs_listeners then
		result.needs_listeners, result.needs_all_listeners = nil, true
		result.detail = UNLISTED .. (result.detail and ("; " .. result.detail) or "")
	else
		result.detail = result.detail .. "; " .. UNLISTED
	end
	return result
end

--- Completes a result that needs listening ports, then falls back to the
--- catalogue default. With several ports the catalogue default wins when the
--- process listens on it, else the lowest port.
--- @param result table From M.resolve with needs_listeners.
--- @param listeners table|nil From M.parse_lsof / M.parse_ss; nil when unread.
--- @return table result
function M.apply_listeners(result, listeners)
	if not result.needs_listeners then return result end
	result.needs_listeners = nil
	local owned, ports, hosts = {}, {}, {}
	for _, pid in ipairs(result.pids) do owned[pid] = true end
	for _, listener in ipairs(listeners or {}) do
		if owned[listener.pid] then
			if not hosts[listener.port] then ports[#ports + 1] = listener.port; hosts[listener.port] = {} end
			hosts[listener.port][#hosts[listener.port] + 1] = listener.host
		end
	end
	local reason = result.detail
	if #ports == 0 then
		result.source = M.SOURCE_DEFAULT
		result.detail = (listeners == nil and "listening ports unread" or "no listening port")
			.. (reason and ("; " .. reason) or "")
		return result
	end
	table.sort(ports)
	local chosen = ports[1]
	for _, port in ipairs(ports) do if port == result.port then chosen = port end end
	-- A server bound to the IPv6 loopback only is unreachable at 127.0.0.1
	local host = nil
	local only_v6 = true
	for _, bound in ipairs(hosts[chosen]) do
		if bound ~= "[::1]" and bound ~= "::1" then only_v6 = false end
	end
	if only_v6 then host = "[::1]" end
	local listed = {}
	for index, port in ipairs(ports) do listed[index] = tostring(port) end
	result.port, result.source = chosen, M.SOURCE_LISTENING
	result.detail = "listening on " .. table.concat(listed, ",")
	result.base_url = M.with_port(result.base_url, chosen, host)
	return result
end





--- Completes a result of M.resolve_unlisted from every listening socket: the
--- sockets of a process whose command line (processes, read for the listening
--- pids) or command name (the listener's) is the server's, then falls back to
--- the catalogue default as M.apply_listeners does.
--- @param result table From M.resolve_unlisted with needs_all_listeners.
--- @param descriptor table From M.descriptor.
--- @param listeners table|nil Every listener { pid, host, port, command|nil }; nil when unread.
--- @param processes table|nil From M.parse_processes for the listening pids; nil when unread.
--- @return table result
function M.apply_unlisted_listeners(result, descriptor, listeners, processes)
	if not result.needs_all_listeners then return result end
	result.needs_all_listeners, result.needs_listeners = nil, true
	local commands, seen = {}, {}
	for _, process in ipairs(processes or {}) do commands[process.pid] = process.command end
	for _, listener in ipairs(listeners or {}) do
		local named = (commands[listener.pid] and M.matches(descriptor, commands[listener.pid]))
			or (listener.command and M.matches(descriptor, listener.command))
		if named and not seen[listener.pid] then
			seen[listener.pid] = true
			result.pids[#result.pids + 1] = listener.pid
		end
	end
	M.apply_listeners(result, listeners)
	if result.source == M.SOURCE_LISTENING then result.detail = result.detail .. "; " .. UNLISTED end
	return result
end





-- =====================================
-- =====================================
-- ======= 4/ Scan =====================
-- =====================================
-- =====================================

--- Describes one result for the log.
--- @param result table
--- @return string
function M.describe(result)
	if not result.running then return "not running (" .. tostring(result.detail) .. "): not probed" end
	local pids = {}
	for index, pid in ipairs(result.pids) do pids[index] = tostring(pid) end
	return string.format("pid %s, port %d from %s%s", #pids > 0 and table.concat(pids, ",") or "unknown",
		result.port, result.source, result.detail and (" (" .. result.detail .. ")") or "")
end

--- Scans every catalogue server through the driver's asynchronous readers.
--- @param entries table Array of { id, descriptor, base_url } in catalogue order.
--- @param ports table { os, home, decode_json, read_file(path) -> string|nil,
---        list_processes(pattern, on_text), list_listeners(pids, on_listeners),
---        list_all_listeners(on_listeners), describe_processes(pids, on_text),
---        logger, log }: list_processes calls on_text once with the "pid
---        command" rows of the processes M.process_pattern matches,
---        describe_processes with the rows of the given pids, list_listeners
---        and list_all_listeners call on_listeners once with parsed { pid,
---        host, port, command|nil } rows of those pids or of every process;
---        each passes nil (and a cause) when it could not read.
--- @param on_done function Receives results: id -> M.resolve result.
function M.scan(entries, ports, on_done)
	for _, name in ipairs({ "list_processes", "list_listeners", "list_all_listeners", "describe_processes" }) do
		if type(ports[name]) ~= "function" then error("local_server_ports.scan: ports." .. name .. " is required") end
	end
	local Logger, LOG = ports.logger, ports.log
	Logger.trace(LOG, "Scanning %d local server process(es)…", #entries)
	local context = { os = ports.os, home = ports.home or "", read_file = ports.read_file, decode_json = ports.decode_json }
	local function report(results, how)
		local summary = {}
		for _, entry in ipairs(entries) do
			local result = results[entry.id]
			Logger.debug(LOG, "Local server '%s': %s.", entry.id, M.describe(result))
			summary[#summary + 1] = entry.id .. "=" .. (result.running
				and (tostring(result.port) .. "/" .. result.source) or "off")
		end
		Logger.info(LOG, "Local server ports: %s.", #summary > 0 and table.concat(summary, ", ") or "no server")
		Logger.done(LOG, "Local server process scan settled%s.", how)
		on_done(results)
	end
	--- Resolves every server from its settings file, then every listening port.
	--- @param cause string Why the process list is missing.
	local function scan_unlisted(cause)
		-- A warning, not an error: the next readings still find a moved port
		Logger.warn(LOG, "The process list is unreadable (%s): local servers are probed at the port of their "
			.. "settings file, else of a listening process of their name, else of the catalogue.", cause)
		local results, pending = {}, {}
		for _, entry in ipairs(entries) do
			results[entry.id] = M.resolve_unlisted(entry.id, entry.descriptor, entry.base_url, context)
			if results[entry.id].needs_all_listeners then pending[#pending + 1] = entry end
		end
		if #pending == 0 then report(results, " without a process list"); return end
		ports.list_all_listeners(function(listeners)
			local function complete(processes)
				for _, entry in ipairs(pending) do
					M.apply_unlisted_listeners(results[entry.id], entry.descriptor, listeners, processes)
				end
				report(results, " without a process list")
			end
			local pids, seen = {}, {}
			for _, listener in ipairs(listeners or {}) do
				if not seen[listener.pid] then seen[listener.pid] = true; pids[#pids + 1] = listener.pid end
			end
			if #pids == 0 then complete(nil); return end
			ports.describe_processes(pids, function(text) complete(text and M.parse_processes(text) or nil) end)
		end)
	end
	ports.list_processes(M.process_pattern(entries), function(listing, cause)
		if listing == nil then scan_unlisted(cause or "no reading"); return end
		local results = {}
		local processes = M.parse_processes(listing)
		local wanted, seen = {}, {}
		for _, entry in ipairs(entries) do
			local result = M.resolve(entry.id, entry.descriptor, entry.base_url, processes, context)
			results[entry.id] = result
			if result.needs_listeners then
				for _, pid in ipairs(result.pids) do
					if not seen[pid] then seen[pid] = true; wanted[#wanted + 1] = pid end
				end
			end
		end
		local function complete(listeners)
			for _, entry in ipairs(entries) do M.apply_listeners(results[entry.id], listeners) end
			report(results, "")
		end
		if #wanted == 0 then complete({}); return end
		ports.list_listeners(wanted, complete)
	end)
end

return M
