--- modules/llm/ollama_server_command.lua

--- ==============================================================================
--- MODULE: Ollama Server Command Builder
--- DESCRIPTION:
--- Builds the long-lived Ollama server command shared by the API and
--- model-manager launch paths. The stock pipeline captures only the stable log
--- directory and resolves the dated ErgoptiPlus filename for every output line,
--- so a daemon that survives midnight follows the logger's daily rollover.
--- The optional managed daemon uses its foreground source owner and original
--- inherited network settings. Stock serving starts with the system network
--- settings (modules/llm/network_env.lua), since Ollama reads only its own
--- relay variables and a managed network lets nothing else out.
--- ==============================================================================

local M = {}

local text_utils = require("infra.text_utils")
local AppDirs    = require("app_dirs")
local NetworkEnv = require("modules.llm.network_env")

-- The daemon appends to the same dated file the logger names, so the prefix
-- and extension come from the one registry that names it.
local DAILY_LOG_PREFIX = AppDirs.files.unified_prefix
local DAILY_LOG_SUFFIX = AppDirs.files.extension
local STAMP_FORMAT = "+%Y-%m-%d %H:%M:%S"
local OLLAMA_HOST = "127.0.0.1"
local OLLAMA_PORT_MIN, OLLAMA_PORT_MAX = 1024, 65535

--- Resolves a POSIX parent directory from the Logger's current unified path.
--- Only the directory is retained by the daemon; the dated filename is rebuilt
--- at write time inside the shell loop.
--- @param unified_log_file string Logger.today_log_path() at launch.
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

--- Builds the source-admitted optional server command without rewriting relays.
--- @param executable string Exact native managed candidate.
--- @param port integer Canonical local port.
--- @return string|nil command Managed source owner invocation.
--- @return string|nil reason Fixed internal preparation failure.
local function managed_service(executable, port)
	local Binary = require("modules.llm.ollama_binary")
	local candidate, budgets = Binary.native_candidate()
	if executable ~= candidate then return nil, "managed runtime selection is unavailable" end
	local Python = require("modules.llm.managed_native_python")
	local FileSystem = require("adapters.file_system")
	local python = Python.resolve()
	local source = debug.getinfo(1, "S").source:sub(2)
	local driver = source:match("^(.*)/modules/llm/ollama_server_command%.lua$")
	if not python or not driver then return nil, "managed native daemon admission is unavailable" end
	local script = driver .. "/modules/llm/managed_ollama_serve.py"
	if not FileSystem.exists(script) then return nil, "managed native daemon owner is unavailable" end
	local admission, idle, retirement = budgets and budgets.admission, budgets and budgets.idle, budgets and budgets.retirement
	if not admission or not idle or not retirement then return nil, "managed native budgets are unavailable" end
	return text_utils.shell_quote(python) .. " -IB " .. text_utils.shell_quote(script)
		.. " --port " .. string.format("%.0f", port)
		.. " --timeout " .. string.format("%.0f", admission)
		.. " --idle-timeout " .. string.format("%.0f", idle)
		.. " --retirement-timeout " .. string.format("%.0f", retirement), nil
end

--- Builds the foreground `ollama serve` pipeline.
--- @param ollama_bin string Absolute Ollama executable path.
--- @param unified_log_file string Logger.today_log_path() at launch.
--- @param port integer Canonical configured Ollama port.
--- @param source_kind string|nil Explicit provisional resolver classification.
--- @param caller_nonce string|nil Opt-in exact-task lifecycle binding; never grants source authority.
--- @return string|nil command
--- @return string|nil error_message
function M.build(ollama_bin, unified_log_file, port, source_kind, caller_nonce)
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
	local Binary = require("modules.llm.ollama_binary")
	if caller_nonce ~= nil then
		if type(caller_nonce) ~= "string" or #caller_nonce ~= 32
			or not caller_nonce:match("^[0-9a-f]+$") then
			return nil, "managed daemon caller nonce is invalid"
		end
		if type(Binary.SOURCE_NATIVE_MANAGED) ~= "string" or source_kind ~= Binary.SOURCE_NATIVE_MANAGED then
			return nil, "managed daemon caller requires its native source owner"
		end
	end
	if type(Binary.SOURCE_NATIVE_MANAGED) == "string" and source_kind == Binary.SOURCE_NATIVE_MANAGED then
		local service, service_err = managed_service(ollama_bin, port)
		if not service then return nil, service_err end
		if caller_nonce ~= nil then
			service = service .. " --caller-nonce " .. text_utils.shell_quote(caller_nonce) .. " --acquire-readiness --owned-stdin"
		end
		-- The source owner must remain the foreground process. A log pipeline's
		-- last successful write cannot turn a guarded refusal into exit zero.
		return "exec " .. service, nil
	end
	local network, network_err = NetworkEnv.prelude("OLLAMA-SERVER")
	if not network then return nil, network_err end

	return table.concat({
		network,
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
