--- tools/test/managed_ollama_restart_envelope_test.lua
--- The exact canonical restart function receives controlled dependency ports.
local root = assert(arg[1])
local production = assert(arg[2])
package.path = production .. "/static/ergopti_plus/macos/?.lua;" .. production .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. production .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local path = root .. "/static/ergopti_plus/macos/ui/menu/menu_llm/models_manager_ollama.lua"
local file = assert(io.open(path, "rb")); local source = assert(file:read("*a")); assert(file:close())
local body = assert(source:match("\tlocal function build_ollama_restart_command%(%)\n(.-)\n\tend"))
local text_utils = require("infra.text_utils")
local managed, binary, launch, refusal = true, "/private/owned/ollama", "exec /native/python -I /source/serve.py", nil
local source_kind = "native_managed"
local calls, errors = {}, {}
local environment = {
	require_ollama_path = function(operation) assert(operation == "restart the daemon"); return binary, source_kind end,
	Logger = { today_log_path = function() return "/private/logs/today.log" end,
		error = function(_, _, reason) errors[#errors + 1] = reason end },
	OllamaEndpoint = { get_port = function() return 45678 end },
	OllamaServerCommand = { build = function(executable, log, port)
		calls[#calls + 1] = { executable, log, port }; return launch, refusal
	end },
	OllamaBinary = { SOURCE_NATIVE_MANAGED = "native_managed" },
	ManagedPullReceipt = { handles = function(executable) assert(executable == binary); return managed end },
	text_utils = text_utils, tostring = tostring, type = type,
}
local restart = assert(load("return function()\n" .. body .. "\nend", path .. "#restart", "t", environment))()
local assertions, cases = 0, 0
local function check(actual, expected) assert(actual == expected, "restart envelope receiving assertion failed"); assertions = assertions + 1 end
local function case(run) cases = cases + 1; run() end
case(function()
	local command = restart()
	check(command, "nohup /usr/bin/env -u BASH_ENV -u ENV /bin/sh -c " .. text_utils.shell_quote(launch)
		.. " </dev/null >/dev/null 2>&1 &")
	check(calls[1][1], binary); check(calls[1][2], "/private/logs/today.log"); check(calls[1][3], 45678)
	check(command:find("OLLAMA_MODELS", 1, true), nil); check(command:find("HTTP_PROXY", 1, true), nil)
end)
case(function()
	managed = false
	check(restart(), "nohup /bin/bash -c " .. text_utils.shell_quote(launch) .. " </dev/null >/dev/null 2>&1 &")
	managed = true
end)
case(function()
	binary = nil; local count = #calls; check(restart(), nil); check(#calls, count); binary = "/private/owned/ollama"
end)
case(function()
	launch, refusal = nil, "guarded-unavailable"; check(restart(), nil); check(errors[1], refusal)
end)
case(function()
	launch, refusal = "stock serve pipeline", nil
	source_kind = "path"
	check(restart(), "nohup /bin/bash -c " .. text_utils.shell_quote(launch) .. " </dev/null >/dev/null 2>&1 &")
	source_kind = "native_managed"
end)
print(string.format("PASS %d cases / %d assertions", cases, assertions))
