--- tests/support/keylogger/cipher_shell_double.lua

--- ==============================================================================
--- MODULE: At-Rest Cipher Shell Double
--- DESCRIPTION:
--- Models what hs.execute does with the commands the macOS at-rest cipher
--- composes: popen(3) hands /bin/sh a C string, the shell delivers standard
--- input to the first pipeline stage, and openssl answers with stdout and an
--- exit status. A stand-in cipher ("C" then uppercase hex) keeps every byte
--- observable; like AES-CBC padding, it is never empty for an empty input.
---
--- FEATURES & RATIONALE:
--- 1. The command stops at its first NUL, as it does at the char * boundary.
--- 2. Both stdin framings are parsed as bash parses them: a quoted heredoc
---    filtered by `head -c N` (an unterminated heredoc ends at end of input),
---    and the printf %b pipeline decoded by tests.support.posix_printf_model.
--- 3. The return shape is hs.execute's: output, status, "exit", code. Faults
---    can make a stage print partial output and exit non-zero.
--- 4. A popen(3) double models ShellRunner.exec_private_stdin: the command and
---    the bytes written to its stdin are recorded apart, so a test can prove a
---    secret never reached a command line.
--- ==============================================================================

local PrintfModel = require("tests.support.posix_printf_model")

local M = {}

M.KEY = string.rep("ab", 32)
M.IV = string.rep("cd", 16)

--- @param s string
--- @return string
function M.to_hex(s)
	return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end))
end

--- @param h string
--- @return string|nil
function M.from_hex(h)
	if h:match("^%x*$") == nil or #h % 2 ~= 0 then return nil end
	return (h:gsub("%x%x", function(b) return string.char(tonumber(b, 16)) end))
end

--- Splits a C-string command into its first stage's stdin and the consumer.
--- @param command string
--- @return string|nil stdin, string consumer, boolean pipefail
local function split(command)
	local first = command:match("^([^\n]*)") or ""
	local limit, token, consumer = first:match("^head %-c (%d+) <<'([%w_]+)' | (.*)$")
	if limit then
		local rest = command:sub(#first + 2)
		local body = rest:match("^(.-\n)" .. token .. "\n") or rest
		return body:sub(1, tonumber(limit)), consumer, false
	end
	local stdin, printf_consumer = PrintfModel.parse_pipeline(command)
	if printf_consumer then return stdin, printf_consumer, true end
	return nil, command, false
end

--- Builds the hs.execute double and the popen(3) double of
--- ShellRunner.exec_private_stdin, which share one openssl model.
--- @param faults table|nil { encrypt|decrypt|derive = { stdout, code }, producer = code }.
--- @return function execute, table seen, table native
function M.new(faults)
	faults = faults or {}
	local seen = {}
	-- Openssl's answer to one consumer command fed with the given stdin.
	local function respond(consumer, stdin)
		local stdout, code
		if consumer:find("ioreg", 1, true) then
			stdout, code = "0123456789ABCDEF\n", 0
		elseif stdin == nil then
			stdout, code = "", 2
		elseif consumer:find("-pbkdf2", 1, true) then
			stdout, code = "salt=00\nkey=" .. M.KEY .. "\niv=" .. M.IV .. "\n", 0
			if faults.derive then stdout, code = faults.derive[1], faults.derive[2] end
		elseif consumer:find("enc %-d ") then
			local plain = stdin:sub(1, 1) == "C" and M.from_hex(stdin:sub(2)) or nil
			stdout, code = plain or "", plain and 0 or 1
			if faults.decrypt then stdout, code = faults.decrypt[1], faults.decrypt[2] end
		elseif consumer:find("^openssl enc ") then
			stdout, code = "C" .. M.to_hex(stdin), 0
			if faults.encrypt then stdout, code = faults.encrypt[1], faults.encrypt[2] end
		else
			stdout, code = "", 127
		end
		return stdout, code
	end
	local function execute(command)
		seen[#seen + 1] = command
		local c_string = command:match("^[^%z]*")
		local stdin, consumer, pipefail = split(c_string)
		-- A failed producer delivers only part of the payload before exiting.
		if faults.producer and stdin then stdin = stdin:sub(1, 1) end
		local stdout, code = respond(consumer, stdin)
		-- Without pipefail the shell reports only the last stage.
		if faults.producer and pipefail then code = faults.producer end
		return stdout, code == 0 and true or nil, "exit", code
	end

	-- In-memory files stand for mkstemp(3) outputs; host paths differ per OS.
	local files, next_file = {}, 0
	local native = {}
	function native.tmpname()
		next_file = next_file + 1
		local path = "/tmp/lua_cipher_double_" .. next_file
		files[path] = ""
		return path
	end
	function native.popen(command, mode)
		seen[#seen + 1] = command
		local c_string = command:match("^[^%z]*")
		local consumer, out_path = c_string:match("^(.-) > (/%S+)$")
		if mode ~= "w" or not consumer then return nil end
		local parts = {}
		local pipe = {}
		function pipe:write(data)
			-- A failed delivery hands the consumer only the first byte.
			if faults.producer then parts[#parts + 1] = data:sub(1, 1); return nil, "Broken pipe" end
			parts[#parts + 1] = data
			return self
		end
		function pipe:close()
			local stdout, code = respond(consumer, table.concat(parts))
			files[out_path] = stdout
			return code == 0 and true or nil, "exit", code
		end
		return pipe
	end
	function native.open(path, mode)
		if files[path] == nil or mode ~= "rb" then return nil end
		local data = files[path]
		return {
			read = function(_, format) return format == "a" and data or nil end,
			close = function() return true end,
		}
	end
	function native.remove(path)
		files[path] = nil
		return true
	end
	--- Lists the output files still present, which must be none after a call.
	function native.leftover_files()
		local left = {}
		for path in pairs(files) do left[#left + 1] = path end
		return left
	end
	return execute, seen, native
end

--- Models hs.hash.new("SHA256") deterministically over the exact bytes.
--- @return table
function M.native_hash()
	return {
		new = function()
			local parts = {}
			local context = {}
			function context:append(data) parts[#parts + 1] = data; return self end
			function context:finish() return self end
			function context:value()
				local h = 0
				local data = table.concat(parts)
				for i = 1, #data do h = (h * 33 + data:byte(i)) % 0xFFFFFFF end
				return (string.format("%07x", h):rep(10)):sub(1, 64)
			end
			return context
		end,
	}
end

return M
