--- modules/llm/managed_ollama_proxy.lua

--- ==============================================================================
--- MODULE: Managed Ollama Proxy Selection (Linux)
--- DESCRIPTION:
--- Resolves the desktop proxy configuration (GIO, including a company PAC) for
--- the Ollama model registry and turns the first selection into the HTTPS_PROXY
--- entry of the daemon Ergopti starts. The daemon cannot evaluate a PAC itself,
--- so without this entry a pull behind a PAC-only network is refused. The
--- environment/loopback/selection rules are the shared proxy policy, the same
--- one the managed HTTP client applies, so every driver reaches one verdict.
---
--- FEATURES & RATIONALE:
--- 1. A proxy the user exported (HTTPS_PROXY and friends) wins: the daemon
---    already inherits it, so no lookup runs and nothing is overridden.
--- 2. Ollama has no failover: only the first selection is used. DIRECT, or a
---    machine without a desktop proxy source, adds nothing.
--- 3. Any other lookup failure refuses the start with a classified reason
---    instead of launching a daemon that would fail its first pull.
--- 4. Logs name the outcome only: never the registry URL or the proxy.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "modules.llm.managed_ollama_proxy"

--- The registry the Ollama daemon pulls from (one source for every driver).
M.REGISTRY_URL = require("llm.ollama_registry").URL

--- The one variable the daemon reads for its HTTPS registry and blob traffic.
M.VARIABLE = "HTTPS_PROXY"

--- Splits "NAME=value" rows into a name -> value map for the policy.
--- @param rows table Process environment rows.
--- @param names table Names the policy reads.
--- @return table snapshot
local function snapshot_of(rows, names)
	local wanted = {}
	for _, name in ipairs(names) do wanted[name] = true end
	local snapshot = {}
	for _, row in ipairs(rows) do
		local name, value = row:match("^([^=]+)=(.*)$")
		if name and wanted[name] then snapshot[name] = value end
	end
	return snapshot
end

--- Builds the proxy port of the runtime repair.
--- @param deps table { policy, lookup, environment, timeout_ms, owner }
--- @return function port Called as port(budget, authorized, done) -> operation.
function M.new(deps)
	assert(type(deps) == "table" and type(deps.policy) == "table" and type(deps.lookup) == "function"
		and type(deps.environment) == "function" and type(deps.owner) == "string"
		and type(deps.timeout_ms) == "number" and deps.timeout_ms > 0, "managed proxy dependencies unavailable")
	local policy, lookup, owner = deps.policy, deps.lookup, deps.owner
	return function(budget, authorized, done)
		local operation = { settled = false, listeners = {} }
		local inner
		--- A lookup that never ran is settled at once; a running one settles with its child.
		function operation:is_settled()
			if inner then return inner.is_settled() == true end
			return self.settled
		end
		function operation:on_settled(listener)
			if type(listener) ~= "function" then return false end
			if inner then return inner.on_settled(listener) end
			listener()
			return true
		end
		function operation:cancel()
			if inner then return inner.cancel() end
			return true
		end
		local function finish(result)
			operation.settled = true
			done(result)
		end
		local rows = deps.environment()
		if type(rows) ~= "table" then finish({ ok = false, error = "proxy_environment_unavailable" }); return operation end
		local route, route_error = policy.route(M.REGISTRY_URL, snapshot_of(rows, policy.environment_names()))
		if not route then
			Logger.error(LOG, "Managed Ollama proxy route refused: %s", tostring(route_error))
			finish({ ok = false, error = "proxy_route_invalid" })
			return operation
		end
		if route.mode ~= "system" then
			Logger.info(LOG, "Managed Ollama proxy lookup skipped: %s route.", route.mode)
			finish({ ok = true, environment = {} })
			return operation
		end
		local remaining = budget.remaining_ms()
		if type(remaining) ~= "number" or remaining <= 0 then
			finish({ ok = false, error = "proxy_timeout" })
			return operation
		end
		Logger.info(LOG, "Managed Ollama proxy lookup started.")
		local child, dispatch_error = lookup(M.REGISTRY_URL, {
			owner = owner, timeout_ms = math.ceil(math.min(deps.timeout_ms, remaining)),
			environment_exclusions = route.environment_exclusions,
		}, function(receipt)
			if not authorized() then
				Logger.info(LOG, "Managed Ollama proxy lookup finished: start no longer authorized.")
				finish({ ok = false, error = "proxy_cancelled" })
				return
			end
			local choices, selection_error = policy.selection(receipt)
			if not choices then
				Logger.error(LOG, "Managed Ollama proxy lookup refused: %s", tostring(selection_error))
				finish({ ok = false, error = "proxy_lookup_failed" })
				return
			end
			local first = choices[1]
			if first.mode == "selected" then
				Logger.info(LOG, "Managed Ollama proxy lookup finished: proxy selected.")
				finish({ ok = true, environment = { M.VARIABLE .. "=" .. first.proxy } })
			else
				-- DIRECT, or the explicit "no native proxy source" acknowledgement.
				Logger.info(LOG, "Managed Ollama proxy lookup finished: %s.", first.mode)
				finish({ ok = true, environment = {} })
			end
		end)
		if not child then
			Logger.error(LOG, "Managed Ollama proxy lookup not started: %s", tostring(dispatch_error))
			finish({ ok = false, error = "proxy_lookup_unavailable" })
			return operation
		end
		inner = child
		return operation
	end
end

return M
