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

local M = {}
local next_id = 0

--- Executes one OpenSSL command and retains output only after a zero exit.
--- @param command string Composed native command without NUL.
--- @param input string|nil Textual stdin bytes without NUL; nil means no stdin.
--- @param options table|nil Set pipefail to require every pipeline stage to succeed.
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
	-- Stay on the command line preceding the heredoc body. A newline here would
	-- put the receipt printer inside stdin instead of after the native pipeline.
	local framed = command .. "; printf '\\n" .. prefix .. "%s\\n' \"$?\""
	local Shell = require("adapters.shell_runner")
	if options and options.pipefail then
		if not Shell.has_command("bash") then return nil, "missing OpenSSL pipeline supervisor" end
		-- Supervise every native stage. Quote only the composed command, leaving
		-- the exact-stdin payload outside this wrapper and its argument budget.
		framed = "bash -o pipefail -c " .. Shell.quote(framed)
	end
	local output
	if input ~= nil then output = Shell.exec_exact_stdin(framed, input)
	else output = Shell.exec(framed) end
	if type(output) ~= "string" then return nil, "missing OpenSSL exit receipt" end
	local contents, status = output:match("^(.*)\n" .. prefix .. "(%d+)\n$")
	local code = tonumber(status)
	if not code or code > 255 then return nil, "missing OpenSSL exit receipt" end
	if code ~= 0 then return nil, "OpenSSL exited with status " .. status end
	return contents
end

return M
