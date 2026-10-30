--- tests/hardware/run_managed_ollama_route_plan.lua

--- ==============================================================================
--- MODULE: Installed Managed Ollama Route Plan Control
--- DESCRIPTION:
--- Runs the shipped managed Ollama proxy stage from an installed layout, on the
--- module path the launcher wrapper exports, with the real shared proxy policy,
--- the real route_origins.json inventory and the real GIO lookup child. The
--- parent supplies the desktop proxy (a PAC on a private bus); this control
--- prints the daemon environment the stage selected and the retirement state.
--- ==============================================================================

local uv = require("luv")
local Json = require("json")

-- The parent passes the launcher's LUA_PATH; a module resolved elsewhere would
-- prove another tree than the installed one.
local installed = assert(os.getenv("ERGOPTI_INSTALLED_ROOT"), "installed root required")
for _, name in ipairs({ "network.route_plan", "infra.route_origins", "modules.llm.managed_ollama_proxy" }) do
	local found = package.searchpath(name, package.path)
	assert(found and found:sub(1, #installed + 1) == installed .. "/", "module outside the installed root: " .. name)
end

local policy = assert(require("infra.proxy_policy").load())
local origins = assert(require("infra.route_origins").client("ollama"))
local Proxy = require("modules.llm.managed_ollama_proxy")
local SystemProxy = require("adapters.system_proxy")

-- Count the native lookups without changing their arguments or answers.
local lookups, lookup_hosts = 0, {}
local lookup = function(url, options, callback)
	lookups = lookups + 1
	lookup_hosts[#lookup_hosts + 1] = url:match("^https://([^/]+)")
	return SystemProxy.lookup_owned(url, options, callback)
end

local environment_rows = {}
for key, value in pairs(uv.os_environ()) do environment_rows[#environment_rows + 1] = key .. "=" .. value end
table.sort(environment_rows)

local port = Proxy.new({
	policy = policy, lookup = lookup, owner = "ollama-runtime-proxy",
	timeout_ms = 5000, origins = origins,
	environment = function() return environment_rows end,
})
local deadline = uv.now() + 8000
local budget = { remaining_ms = function() uv.update_time(); return deadline - uv.now() end }
local result
local operation = port(budget, function() return true end, function(value) result = value end)

local timer = uv.new_timer()
uv.timer_start(timer, 20, 20, function()
	if (result and operation:is_settled()) or uv.now() > deadline then
		uv.timer_stop(timer)
		uv.close(timer)
	end
end)
uv.run()

local selected = {}
for _, row in ipairs(result and result.environment or {}) do
	local name, value = row:match("^([^=]+)=(.*)$")
	selected[name] = value
end
io.stdout:write("ERGOPTI_ROUTE_PLAN_RESULT:", Json.encode({
	finished = result ~= nil, settled = operation:is_settled(), ok = result and result.ok or false,
	error = result and result.error or nil, direct_fallback = result and result.direct_fallback or nil,
	environment = selected, rows = result and result.environment and #result.environment or 0,
	lookups = lookups, lookup_hosts = lookup_hosts, origins = origins,
}), "\n")
