--- modules/llm/managed_ollama_proxy.lua

--- ==============================================================================
--- MODULE: Managed Ollama Proxy Selection (Linux)
--- DESCRIPTION:
--- Resolves the desktop proxy configuration (GIO, including a company PAC) for
--- every origin the Ollama daemon downloads from and turns the answers into the
--- HTTPS_PROXY / NO_PROXY entries of the daemon Ergopti starts. The daemon
--- cannot evaluate a PAC itself, so without these entries a pull behind a
--- PAC-only network is refused. The environment/loopback/selection rules are
--- the shared proxy policy and the per-origin aggregation is the shared route
--- plan (network/route_plan.lua), the same ones macOS applies.
---
--- FEATURES & RATIONALE:
--- 1. A proxy the user exported (HTTPS_PROXY and friends) wins: the daemon
---    already inherits it, so no lookup runs and nothing is overridden.
--- 2. Each origin of route_origins.json "ollama" (the registry and its blob
---    redirect host) is looked up, one after the other under one owner. The
---    daemon holds one relay: the plan exports it with a NO_PROXY entry for
---    each origin the PAC sends direct, and refuses two different relays.
--- 3. Ollama has no failover: only the first selection of each origin is used.
---    DIRECT, or a machine without a desktop proxy source, is a direct route.
--- 4. Any lookup failure or refused plan refuses the start with a classified
---    reason instead of launching a daemon that would fail its first pull.
--- 5. Logs name the outcome only: never an origin URL or the proxy.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local RoutePlan = require("network.route_plan")
local LOG = "modules.llm.managed_ollama_proxy"

--- The registry the Ollama daemon pulls from (one source for every driver).
M.REGISTRY_URL = require("llm.ollama_registry").URL

--- The relay variable the daemon reads for its HTTPS registry and blob traffic.
M.VARIABLE = "HTTPS_PROXY"

--- The bypass names, in the order Go's net/http (the daemon) reads them. Both
--- are written with the same merged value so neither reader sees a stale copy.
M.BYPASS_VARIABLES = { "NO_PROXY", "no_proxy" }

--- Every variable the stage may set; the composition admits only these.
M.VARIABLES = { M.VARIABLE, M.BYPASS_VARIABLES[1], M.BYPASS_VARIABLES[2] }

--- Splits "NAME=value" rows into a name -> value map for the given names.
--- @param rows table Process environment rows.
--- @param names table Names to keep.
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

--- Turns the plan into the daemon rows, keeping the user's own bypass entries.
--- @param plan table Settled route plan.
--- @param rows table Process environment rows.
--- @return table environment
local function environment_of(plan, rows)
	if plan.proxy == "direct" then return {} end
	local environment = { M.VARIABLE .. "=" .. plan.proxy }
	local direct = plan.no_proxy()
	if direct == "" then return environment end
	local existing = snapshot_of(rows, M.BYPASS_VARIABLES)
	local current = ""
	for _, name in ipairs(M.BYPASS_VARIABLES) do
		if existing[name] and existing[name] ~= "" then current = existing[name]; break end
	end
	local merged = current == "" and direct or current .. "," .. direct
	for _, name in ipairs(M.BYPASS_VARIABLES) do environment[#environment + 1] = name .. "=" .. merged end
	return environment
end

--- Builds the proxy port of the runtime repair.
--- @param deps table { policy, lookup, environment, timeout_ms, owner, origins }
--- @return function port Called as port(budget, authorized, done) -> operation.
function M.new(deps)
	assert(type(deps) == "table" and type(deps.policy) == "table" and type(deps.lookup) == "function"
		and type(deps.environment) == "function" and type(deps.owner) == "string"
		and type(deps.timeout_ms) == "number" and deps.timeout_ms > 0
		and type(deps.origins) == "table" and #deps.origins > 0, "managed proxy dependencies unavailable")
	-- The registry decides whether an exported relay already covers the daemon.
	assert(deps.origins[1] == M.REGISTRY_URL, "managed proxy origin inventory does not start with the registry")
	local policy, lookup, owner, origins = deps.policy, deps.lookup, deps.owner, deps.origins
	return function(budget, authorized, done)
		-- `inner` is the current lookup child; the operation settles once the
		-- logical answer is out and that child is physically retired.
		local operation = { finished = false, listeners = {} }
		local inner, step = nil, 0
		function operation:is_settled()
			if inner then return inner.is_settled() == true end
			return self.finished
		end
		local function release()
			local listeners = operation.listeners
			operation.listeners = {}
			for _, listener in ipairs(listeners) do listener() end
		end
		function operation:on_settled(listener)
			if type(listener) ~= "function" then return false end
			if not self.finished then self.listeners[#self.listeners + 1] = listener; return true end
			-- Once the answer is out the current child is the last one.
			if inner and inner.is_settled() ~= true then return inner.on_settled(listener) end
			listener()
			return true
		end
		local function settle_later()
			if inner and inner.is_settled() ~= true then inner.on_settled(release) else release() end
		end
		function operation:cancel()
			self.finished = true
			local accepted = true
			if inner then accepted = inner.cancel() end
			settle_later()
			return accepted
		end
		local function finish(result)
			if operation.finished then return end
			operation.finished = true
			done(result)
			settle_later()
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
		local entries = {}
		local dispatch

		--- Settles the plan once every origin has a route.
		local function conclude()
			local plan, reason = RoutePlan.plan(entries)
			if not plan then
				Logger.error(LOG, "Managed Ollama proxy plan refused: %s", reason)
				finish({ ok = false, error = "proxy_route_plan_refused" })
				return
			end
			if plan.proxy == "direct" then
				Logger.info(LOG, "Managed Ollama proxy lookup finished: every origin direct.")
			else
				local direct = plan.no_proxy()
				Logger.info(LOG, "Managed Ollama proxy lookup finished: proxy selected, %d direct origin(s).",
					direct == "" and 0 or select(2, direct:gsub(",", "")) + 1)
			end
			finish({ ok = true, environment = environment_of(plan, rows) })
		end

		--- Records one origin's first selection, then looks up the next origin.
		--- @param index number
		--- @param receipt table
		local function receive(index, receipt)
			if operation.finished then return end
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
			-- DIRECT, or the explicit "no native proxy source" acknowledgement.
			entries[index] = { origin = origins[index], route = first.mode == "selected" and first.proxy or "direct" }
			if index == #origins then conclude() else dispatch(index + 1) end
		end

		--- Looks up one origin under the remaining budget.
		--- @param index number
		dispatch = function(index)
			local remaining = budget.remaining_ms()
			if type(remaining) ~= "number" or remaining <= 0 then
				finish({ ok = false, error = "proxy_timeout" })
				return
			end
			step = step + 1
			local mine = step
			local child, dispatch_error = lookup(origins[index], {
				owner = owner, timeout_ms = math.ceil(math.min(deps.timeout_ms, remaining)),
				environment_exclusions = route.environment_exclusions,
			}, function(receipt) receive(index, receipt) end)
			if not child then
				Logger.error(LOG, "Managed Ollama proxy lookup not started: %s", tostring(dispatch_error))
				finish({ ok = false, error = "proxy_lookup_unavailable" })
				return
			end
			-- A synchronous answer may already have dispatched the next origin.
			if step == mine then inner = child end
		end

		Logger.info(LOG, "Managed Ollama proxy lookup started for %d origin(s).", #origins)
		dispatch(1)
		return operation
	end
end

return M
