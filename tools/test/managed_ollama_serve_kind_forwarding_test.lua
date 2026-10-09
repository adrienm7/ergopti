--- tools/test/managed_ollama_serve_kind_forwarding_test.lua
--- Exact actual API startup and restart snippets preserve resolver classifications.
local root, production = assert(arg[1]), assert(arg[2])
package.path = production .. "/static/ergopti_plus/macos/?.lua;" .. production .. "/static/ergopti_plus/macos/?/init.lua;" .. production .. "/static/ergopti_plus/_shared/lua/?.lua;" .. production .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local function read(name)
	local file = assert(io.open(root .. "/static/ergopti_plus/macos/" .. name, "rb"))
	local source = assert(file:read("*a")); assert(file:close()); return source
end
local api = read("modules/llm/api_ollama.lua")
local body = assert(api:match("(local ollama_bin, binary_err.-)\n%s*local serve_handle"))
local binary, source_kind, authorized = "/canonical/ollama", "native_managed", true
local built, failure = {}, nil
local environment = {
	OllamaBinary = { resolve = function() return binary, "controlled-refusal", source_kind end },
	my_generation = 1, _ollama_start_generation = 1, _ollama_starting = true,
	ollama_start_authorized = function() return authorized end,
	fail_start = function(reason) failure = reason end,
	Logger = { today_log_path = function() return "/logs/today.log" end },
	resolve_ollama_port = function() return 11434 end,
	OllamaServerCommand = { build = function(...)
		built[#built + 1] = table.pack(...); return "actual composed command", nil
	end },
}
local activate = assert(load("return function()\n" .. body .. "\nreturn launch_cmd\nend", "@actual-api-startup", "t", environment))()
local cases, assertions = 0, 0
local function check(a, b) assert(a == b, "source-kind forwarding assertion failed"); assertions = assertions + 1 end
local function case(run) cases = cases + 1; run() end
case(function()
	check(activate(), "actual composed command"); check(built[#built][4], "native_managed"); check(built[#built].n, 4)
end)
case(function()
	source_kind = "path"; check(activate(), "actual composed command"); check(built[#built][4], "path")
end)
case(function()
	source_kind = nil; check(activate(), "actual composed command"); check(built[#built][4], nil); check(built[#built].n, 4)
end)
case(function()
	binary = nil; local before = #built; check(activate(), nil); check(#built, before); check(failure, "server executable resolution"); binary = "/canonical/ollama"
end)
case(function()
	authorized = false; local before = #built; check(activate(), nil); check(#built, before); authorized = true
end)
case(function()
	local manager = read("ui/menu/menu_llm/models_manager_ollama.lua")
	local restart = assert(manager:match("local function build_ollama_restart_command%(%)\n(.-)\n\tend"))
	local fn = assert(load("return function()\n" .. restart .. "\nend", "@actual-restart", "t", {
		require_ollama_path = function() return binary, "native_managed" end,
		Logger = environment.Logger, OllamaEndpoint = { get_port = environment.resolve_ollama_port },
		OllamaServerCommand = environment.OllamaServerCommand,
		OllamaBinary = { SOURCE_NATIVE_MANAGED = "native_managed" },
		ManagedPullReceipt = { handles = function() return true end },
		text_utils = require("infra.text_utils"), type = type,
	}))()
	check(fn():find("/usr/bin/env -u BASH_ENV -u ENV", 1, true) ~= nil, true)
	check(built[#built][4], "native_managed")
end)
print(string.format("PASS %d cases / %d assertions", cases, assertions))
