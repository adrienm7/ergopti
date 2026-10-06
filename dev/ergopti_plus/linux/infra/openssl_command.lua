--- infra/openssl_command.lua
--- ==============================================================================
--- MODULE: Native OpenSSL Command Receipts (Linux)
--- DESCRIPTION:
--- Preserves a synchronous CLI's exit status without staging key/plaintext
--- output in a file or quoting its stdin command twice. LuaJIT pclose can hide
--- a failed child's status, so useful stdout alone is never success evidence.
--- A per-call terminal frame distinguishes receipt-looking caller bytes from
--- the shell's own receipt; only an actual zero exit admits the captured bytes.
--- Existing exact-stdin framing and its argv budget remain intact.
--- ==============================================================================

local Heredoc = require("shell.heredoc")

local M = {}
local next_id = 0

--- Executes one OpenSSL command and retains output only after a zero exit.
--- @param command string Composed native command without NUL.
--- @param input string|nil Textual stdin bytes without NUL; nil means no stdin.
--- @param options table|nil Require pipefail without stdin; exact stdin is always supervised.
--- @return string|nil output Byte-exact stdout after verified success.
--- @return string|nil error_message Missing or refused native receipt.
function M.exec(command, input, options)
	if type(command) ~= "string" or command == "" or command:find("\0", 1, true) then
		return nil, "invalid OpenSSL command"
	end
	if input ~= nil and (type(input) ~= "string" or input:find("\0", 1, true)) then
		return nil, "invalid OpenSSL textual stdin"
	end
	if options ~= nil and (type(options) ~= "table"
		or (options.pipefail ~= nil and type(options.pipefail) ~= "boolean")) then
		return nil, "invalid OpenSSL command options"
	end
	next_id = next_id + 1
	local prefix = "ERGOPTI_OPENSSL_EXIT_STATUS_" .. tostring({}):gsub("%W", "") .. "_" .. string.format("%.0f", next_id) .. "="
	local receipt = "printf '\\n" .. prefix .. "%s\\n' \"$?\""
	local Shell = require("adapters.shell_runner")
	local framed
	if input ~= nil then
		if not Shell.has_command("bash") then return nil, "missing OpenSSL input supervisor" end
		-- Let Bash own head and every consumer. Feed the small script through
		-- fd 3 and the original data through stdin; Bash never interprets data
		-- as script or creates its own large plaintext heredoc temporary file.
		local script = "head -c " .. #input .. " | " .. command .. "\n" .. receipt .. "\n"
		local program = Heredoc.with_stdin("bash -o pipefail /dev/fd/3", script)
		local header, program_body = program:match("^([^\n]*)\n(.*)$")
		-- Reuse the shared exact body and collision policy, relocating only its
		-- native fd redirection. No quoting or normalization touches caller bytes.
		local data = Heredoc.with_exact_stdin("", input)
		local data_header, data_body = data:match("^([^\n]*)\n(.*)$")
		local token = data_header:match("<<'([%w_]+)'")
		framed = header .. " 3<&0 4<<'" .. token .. "' 0<&4 4<&-\n" .. program_body .. data_body
	elseif options and options.pipefail then
		if not Shell.has_command("bash") then return nil, "missing OpenSSL pipeline supervisor" end
		framed = Heredoc.with_stdin("bash -o pipefail", command .. "; " .. receipt)
	else
		framed = command .. "; " .. receipt
	end
	local output = Shell.exec(framed)
	if type(output) ~= "string" then return nil, "missing OpenSSL exit receipt" end
	local contents, status = output:match("^(.*)\n" .. prefix .. "(%d+)\n$")
	local code = tonumber(status)
	if not code or code > 255 then return nil, "missing OpenSSL exit receipt" end
	if code ~= 0 then return nil, "OpenSSL exited with status " .. status end
	return contents
end

return M
