--- tools/test/managed_ollama_serve_kind_forwarding_test.lua
--- Preserve resolver input families while receiving the actual foreground contract.
--- Foreign or unclassified runtimes no longer grant an implicit shell launch.
local root, production = assert(arg[1]), assert(arg[2])
local Ports = assert(loadfile(root .. "/tools/test/fixtures/managed_ollama_foreground_ports.lua"))()
local function read(name)
	local file = assert(io.open(root .. "/static/ergopti_plus/macos/" .. name, "rb"))
	local source = assert(file:read("*a")); assert(file:close()); return source
end
local api = read("modules/llm/api_ollama.lua")
local body = assert(api:match("(local resolved_ok, ollama_bin, binary_err, source_kind.-)\n%s*local serve_handle"),
	"The canonical API must classify before foreground acquisition")
local Choice = assert(loadfile(root .. "/static/ergopti_plus/_shared/lua/core/llm/ollama_runtime_choice.lua"))()
local binary, source_kind, authorized = "/canonical/ollama", "native_managed", true
local built, failure, detail = {}, nil, nil
local environment = setmetatable({
	OllamaBinary = { resolve = function() return binary, "controlled-refusal", source_kind end },
	RuntimeChoice = Choice,
	hs = { host = { uuid = function() return "01234567-89ab-cdef-0123-456789abcdef" end } },
	my_generation = 1, _ollama_start_generation = 1, _ollama_starting = true,
	ollama_start_authorized = function() return authorized end,
	fail_start = function(reason, value) failure, detail = reason, value; return false end,
	Logger = { today_log_path = function() return "/logs/today.log" end },
	resolve_ollama_port = function() return 11434 end,
	OllamaServerCommand = { build = function(...)
		built[#built + 1] = table.pack(...); return "actual composed command", nil
	end },
}, { __index = _G })
local activate = assert(load("return function()\n" .. body .. "\nreturn launch_cmd\nend", "@actual-api-startup", "t", environment))()
local cases, assertions = 0, 0
local function check(a, b) assert(a == b, "source-kind forwarding assertion failed"); assertions = assertions + 1 end
local function case(run) cases = cases + 1; run() end
local function frame(role) return "ERGOPTI_MANAGED_DAEMON_V1 " .. Ports.NONCE .. " " .. role .. "\n" end
case(function()
	local command = activate()
	check(command, "actual composed command"); check(#built, 1)
	check(built[1][1], "/canonical/ollama"); check(built[1][2], "/logs/today.log"); check(built[1][3], 11434)
	check(built[1][4], "native_managed"); check(built[1][5], "0123456789abcdef0123456789abcdef"); check(built[1].n, 5)
	check(command:find("nohup", 1, true), nil); check(command:find("pkill", 1, true), nil)
end)
case(function()
	source_kind = "path"; local before = #built
	check(activate(), false); check(#built, before)
	check(failure, "external runtime requires manual service management"); check(detail, false)
end)
case(function()
	source_kind = nil; local before = #built
	check(activate(), false); check(#built, before)
	check(failure, "external runtime requires manual service management"); check(detail, false)
end)
case(function()
	binary = nil; local before = #built
	check(activate(), false); check(#built, before); check(failure, "server executable resolution"); check(detail, "controlled-refusal")
	binary, source_kind = "/canonical/ollama", "native_managed"
end)
case(function()
	authorized = false; local before = #built
	check(activate(), false); check(#built, before); check(failure, "runtime authority superseded"); check(detail, false)
	authorized = true
end)
case(function()
	-- Load the full canonical API behind the manager's actual callback block,
	-- rather than reintroducing the removed detached-command helper.
	local state = Ports.new(root, production, { pull_supported = true })
	check(state.restart(), true); check(#state.calls, 1)
	check(state.calls[1][4], "native_managed"); check(state.calls[1][5], Ports.NONCE)
	check(#state.tasks, 1); check(state.operation.command, state.observed); check(state.retries, 0)
	local task = state.tasks[1]
	check(task.attempted, true); check(task.private, true); check(task.owned, true); check(type(task.streaming), "function")
	check(task.arguments[2]:find("nohup", 1, true), nil); check(task.arguments[2]:find("pkill", 1, true), nil)
	task.emit(frame("ACTIVE") .. frame("READY"):sub(1, -2)); check(state.retries, 0)
	task.emit("\n"); check(state.retries, 1); check(state.operation.command, nil); check(state.api.migration_idle(), false)
	task.emit(frame("RETIRED 0")); check(state.api.migration_idle(), false)
	task.complete(); check(state.api.migration_idle(), true); check(#state.tasks, 1); check(task.terminate_calls, 0)
end)
print(string.format("PASS %d cases / %d assertions", cases, assertions))
