--- modules/llm/ollama_server_command.lua

--- ==============================================================================
--- MODULE: Ollama Server Command Builder
--- DESCRIPTION:
--- Builds the single long-lived Ollama server pipeline shared by the API and
--- model-manager launch paths. The pipeline captures only the stable log
--- directory and resolves the dated ErgoptiPlus filename for every output line,
--- so a daemon that survives midnight follows the logger's daily rollover.
--- ==============================================================================

local M = {}

local text_utils = require("infra.text_utils")

local DAILY_LOG_PREFIX = "ErgoptiPlus_"
local DAILY_LOG_SUFFIX = ".log"
local STAMP_FORMAT = "+%Y-%m-%d %H:%M:%S"
local OLLAMA_HOST = "127.0.0.1"
local OLLAMA_PORT_MIN, OLLAMA_PORT_MAX = 1024, 65535

--- Resolves a POSIX parent directory from the Logger's current unified path.
--- Only the directory is retained by the daemon; the dated filename is rebuilt
--- at write time inside the shell loop.
--- @param unified_log_file string Current Logger.UNIFIED_LOG_FILE value.
--- @return string|nil log_dir
--- @return string|nil error_message
local function resolve_log_dir(unified_log_file)
	if type(unified_log_file) ~= "string" or unified_log_file == "" then
		return nil, "unified log path is absent"
	end
	local log_dir = unified_log_file:match("^(.*)/[^/]+$")
	if type(log_dir) ~= "string" or log_dir == "" then
		return nil, "unified log path has no POSIX parent directory"
	end
	return log_dir, nil
end

--- Builds the foreground `ollama serve` pipeline.
--- @param ollama_bin string Absolute Ollama executable path.
--- @param unified_log_file string Current Logger.UNIFIED_LOG_FILE value.
--- @param port integer Canonical configured Ollama port.
--- @return string|nil command
--- @return string|nil error_message
function M.build(ollama_bin, unified_log_file, port)
	if type(ollama_bin) ~= "string" or ollama_bin == "" then
		return nil, "Ollama executable path is absent"
	end
	port = tonumber(port)
	if type(port) ~= "number" or port % 1 ~= 0
		or port < OLLAMA_PORT_MIN or port > OLLAMA_PORT_MAX then
		return nil, "Ollama port is outside the supported range"
	end
	local log_dir, dir_err = resolve_log_dir(unified_log_file)
	if not log_dir then return nil, dir_err end

	return table.concat({
		"LOG_DIR=", text_utils.shell_quote(log_dir), "; ",
		"OLLAMA_HOST=", text_utils.shell_quote(OLLAMA_HOST .. ":" .. tostring(port)), " ",
		text_utils.shell_quote(ollama_bin), " serve 2>&1 | ",
		"while IFS= read -r LINE || [ -n \"$LINE\" ]; do ",
		"STAMP=\"$(date '", STAMP_FORMAT, "')\"; ",
		"LOG_DATE=\"${STAMP%% *}\"; ",
		"LOG_TIME=\"${STAMP#* }\"; ",
		"if ! printf '%s [OLLAMA-SERVER] %s\\n' \"$LOG_TIME\" \"$LINE\" ",
		">> \"$LOG_DIR/", DAILY_LOG_PREFIX, "${LOG_DATE}", DAILY_LOG_SUFFIX, "\"; then ",
		"printf '%s\\n' 'Ollama log append failed.' >&2; exit 1; fi; ",
		"done",
	}), nil
end

return M
