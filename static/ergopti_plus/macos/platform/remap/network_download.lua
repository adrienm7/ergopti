--- platform/remap/network_download.lua

--- ==============================================================================
--- MODULE: Remap Engine Download Route
--- DESCRIPTION:
--- The Karabiner DMG, the owned runtime artifact and the VirtualHIDDevice
--- package are fetched by /usr/bin/curl. They used to start with the inherited
--- Hammerspoon environment, which holds no proxy, so a Mac that reaches the
--- internet only through its company proxy could not install the remap engine
--- and was told it was offline (NET-001). Each download now runs behind the
--- same system network prelude as the Ollama and MLX children
--- (modules/llm/network_env.lua), resolved for the `karabiner` client of
--- _shared/modules/network/route_origins.json, and a refused route is named
--- through the shared managed network failure classes.
--- ==============================================================================

local M = {}

local NetworkEnv = require("modules.llm.network_env")
local Admission = require("modules.llm.opaque_network_admission")

-- The route client every remap download resolves its proxy for.
M.ROUTE_CLIENT = "karabiner"

-- curl is exec'd by the prelude's shell, so its PID, exit status and output
-- remain the task's own.
local EXEC_CURL = 'exec /usr/bin/curl "$@"'

--- Describes a failed download, naming a refused route by its shared class.
--- @param code number|nil The shell's exit status.
--- @param stderr string|nil Its standard error.
--- @return string|nil description nil when the failure is curl's own.
function M.describe_failure(code, stderr)
	local phase = Admission.new()
	phase.push(type(stderr) == "string" and stderr or "")
	phase.push("\n")
	local receipt = phase.finish(code)
	if not receipt then return nil end
	local report = Admission.report(receipt, {})
	return "the proxy route could not be resolved (" .. tostring(report.cause) .. ")"
end

--- The command that runs one remap download behind the system network prelude.
--- @param tag string Log prefix of the child, e.g. "KARABINER-DMG".
--- @param curl_args table curl's arguments.
--- @return string|nil executable "/bin/sh", nil when the route cannot be built.
--- @return table|string args The shell argv, or why the route cannot be built.
--- @return function|nil describe M.describe_failure for this command.
function M.command(tag, curl_args)
	assert(type(curl_args) == "table", "a remap download needs its curl arguments")
	local prelude, err = NetworkEnv.opaque_prelude(tag, { pac_probe_client = M.ROUTE_CLIENT })
	if not prelude then return nil, tostring(err) end
	local args = { "-c", prelude .. EXEC_CURL, tag }
	for _, value in ipairs(curl_args) do args[#args + 1] = value end
	return "/bin/sh", args, M.describe_failure
end

return M
