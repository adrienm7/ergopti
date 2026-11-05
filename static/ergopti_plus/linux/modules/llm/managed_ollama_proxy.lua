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
--- 3. Ollama has no failover of its own, so the PAC list is walked here, the
---    way a browser does: a relay followed by another entry ("PROXY a; DIRECT")
---    is kept only when a TCP connect to it completes within the shared probe
---    deadline (timings llm.managed_proxy_probe_timeout_ms); otherwise the next
---    entry is tried. The last entry is kept unprobed: nothing follows it.
---    DIRECT, or a machine without a desktop proxy source, is a direct route.
--- 4. An unusable desktop configuration (GIO could not resolve the origin, or
---    ran out of time: a PAC it could not fetch or evaluate) sends that origin
---    direct, at the closed stages of proxy_policy.json "pac_unavailable_fallback",
---    with one WARNING naming the stage, as macOS does. A relay the user exported
---    never reaches the lookup, and a relay the PAC names is kept as named.
---    Any other failure or a refused plan refuses the start with a classified
---    reason instead of launching a daemon that would fail its first pull.
--- 5. Logs name the outcome only: never an origin URL or the proxy.
--- 6. A plain http relay the plan selected is probed once for the registry
---    (docs/design/proxy-auth-relay.md): a proxy that demands an NTLM or
---    Negotiate sign-in the daemon cannot give is answered by Ergopti's local
---    relay, proven by the probe's own sign-in; the stage then names that relay
---    so the daemon starts under it. A refused sign-in starts the daemon without
---    the proxy, as Windows does: the models on disk keep working, and the result
---    carries the relay's closed reason, which refuses only the pull.
--- 7. The user's proxy override (network/proxy_override.lua, which the policy
---    binding applies) wins over everything above: "direct" bypasses every relay
---    the daemon would inherit, the sign-in relay included; a relay URL becomes
---    the daemon's HTTPS_PROXY as given, and is probed like a planned relay, so
---    an override that demands NTLM or Negotiate still gets the sign-in relay.
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

--- The closed lookup stage each GIO lookup failure stands for. GIO names no
--- finer step: a PAC it cannot download or evaluate fails the lookup itself.
--- Failures of Ergopti's own helper process are not listed and keep refusing.
M.LOOKUP_STAGES = {
	["proxy-lookup-failed"] = "native_proxy_lookup",
	["proxy-lookup-timeout"] = "native_proxy_budget",
}

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

--- The daemon rows of a route without any proxy (a direct override, a refused
--- sign-in): a bypass of every relay the daemon would otherwise inherit.
--- @return table environment
local function bypass_environment()
	local environment = {}
	for _, name in ipairs(M.BYPASS_VARIABLES) do environment[#environment + 1] = name .. "=*" end
	return environment
end

--- Builds the proxy port of the runtime repair.
--- @param deps table { policy, lookup, environment, timeout_ms, owner, origins, relay,
---   probe, relay_address, probe_timeout_ms }
---   relay = { policy (network/proxy_auth_relay.lua), probe(upstream, authority,
---   options, callback) -> operation|nil, reason, timeout_ms }: the sign-in relay.
---   probe = fn(host, port, timeout_ms, callback) -> child (adapters/tcp_probe.lua),
---   relay_address = fn(relay) -> host, port: the PAC list walk.
--- @return function port Called as port(budget, authorized, done) -> operation.
function M.new(deps)
	assert(type(deps) == "table" and type(deps.policy) == "table" and type(deps.lookup) == "function"
		and type(deps.environment) == "function" and type(deps.owner) == "string"
		and type(deps.timeout_ms) == "number" and deps.timeout_ms > 0
		and type(deps.origins) == "table" and #deps.origins > 0
		and type(deps.probe) == "function" and type(deps.relay_address) == "function"
		and type(deps.probe_timeout_ms) == "number" and deps.probe_timeout_ms > 0,
		"managed proxy dependencies unavailable")
	local relay = deps.relay
	assert(type(relay) == "table" and type(relay.policy) == "table" and type(relay.probe) == "function"
		and type(relay.timeout_ms) == "number" and relay.timeout_ms > 0, "managed proxy relay dependencies unavailable")
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
		local entries = {}
		-- The first lookup stage that sent an origin direct, for the pull's error.
		local fallback = nil
		local dispatch, choose

		--- Settles a refused sign-in: the daemon starts without the proxy, and the
		--- closed reason travels with the result to refuse the pull alone.
		--- @param reason string The relay's closed refusal.
		local function refuse_sign_in(reason)
			Logger.error(LOG, "Managed Ollama proxy sign-in relay refused (%s): the daemon starts without the proxy.",
				tostring(reason))
			finish({ ok = true, environment = bypass_environment(), relay_refusal = reason, direct_fallback = fallback })
		end

		--- Asks the selected relay whether it demands a sign-in the daemon cannot
		--- give, then settles the stage with the relay the daemon starts under.
		--- @param plan table Settled route plan with a relay.
		--- @param upstream string The plain http relay the probe signs in to.
		local function probe_relay(plan, upstream)
			local remaining = budget.remaining_ms()
			if type(remaining) ~= "number" or remaining <= 0 then
				finish({ ok = false, error = "proxy_timeout" })
				return
			end
			local authority = relay.policy.authority(M.REGISTRY_URL)
			step = step + 1
			local mine = step
			local child, probe_error = relay.probe(upstream, authority, {
				owner = owner .. "-relay", timeout_ms = math.ceil(math.min(relay.timeout_ms, remaining)),
				authorized = authorized,
			}, function(answer, reason)
				if operation.finished then return end
				if not authorized() then
					Logger.info(LOG, "Managed Ollama proxy relay probe finished: start no longer authorized.")
					finish({ ok = false, error = "proxy_cancelled" })
					return
				end
				if not answer then refuse_sign_in(reason); return end
				local result = { ok = true, environment = environment_of(plan, rows), direct_fallback = fallback }
				if answer.status == "not_installed" then
					-- The relay is not packaged yet: the daemon keeps the proxy as
					-- named, as before the relay existed, and says so.
					Logger.warn(LOG, "Managed Ollama proxy sign-in relay not installed: a proxy that demands NTLM or Negotiate will refuse the pulls.")
				elseif answer.status == "required" then
					Logger.info(LOG, "Managed Ollama proxy demands a %s sign-in: the daemon starts under the local relay.",
						answer.scheme)
					result.relay = { upstream = upstream, scheme = answer.scheme }
				else
					Logger.info(LOG, "Managed Ollama proxy relay not needed: the proxy demands no Windows sign-in.")
				end
				finish(result)
			end)
			if not child then
				Logger.error(LOG, "Managed Ollama proxy relay probe not started: %s", tostring(probe_error))
				refuse_sign_in(require("network.proxy_auth_relay").UNAVAILABLE)
				return
			end
			if step == mine then inner = child end
		end

		-- Both short-cuts come after probe_relay: an override relay is probed
		-- like a planned one, so an NTLM or Negotiate proxy still gets the relay.
		if route.source == "override" then
			if route.mode == "direct" then
				Logger.info(LOG, "Managed Ollama proxy lookup skipped: the proxy override names a direct route.")
				finish({ ok = true, environment = bypass_environment() })
				return operation
			end
			Logger.info(LOG, "Managed Ollama proxy lookup skipped: the proxy override names a relay.")
			local plan = { proxy = route.proxy, no_proxy = function() return "" end }
			local upstream = relay.policy.upstream(route.proxy)
			if upstream then probe_relay(plan, upstream) else finish({ ok = true, environment = environment_of(plan, rows) }) end
			return operation
		end
		if route.mode ~= "system" then
			Logger.info(LOG, "Managed Ollama proxy lookup skipped: %s route.", route.mode)
			finish({ ok = true, environment = {} })
			return operation
		end

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
				-- Only a plain http relay without credentials can demand a sign-in
				-- the daemon cannot answer; userinfo is Basic, which it sends itself.
				local upstream = relay.policy.upstream(plan.proxy)
				if upstream then probe_relay(plan, upstream); return end
			end
			finish({ ok = true, environment = environment_of(plan, rows), direct_fallback = fallback })
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
				local stage = M.LOOKUP_STAGES[selection_error]
				if not policy.falls_back_direct(stage) then
					Logger.error(LOG, "Managed Ollama proxy lookup refused: %s", tostring(selection_error))
					finish({ ok = false, error = "proxy_lookup_failed" })
					return
				end
				Logger.warn(LOG, "Managed Ollama proxy lookup unusable at %s: origin %d of %d goes direct.",
					stage, index, #origins)
				fallback = fallback or stage
				choices = { { mode = "direct" } }
			end
			choose(index, choices, 1)
		end

		--- Keeps the first usable entry of one origin's PAC list, from `at` on.
		--- @param index number Origin index.
		--- @param choices table Ordered selections of the shared policy.
		--- @param at number Entry to try.
		local function probe_budget()
			if operation.finished then return nil end
			local remaining = budget.remaining_ms()
			-- Reading the master budget can synchronously revoke this operation.
			if operation.finished then return nil end
			if type(remaining) ~= "number" or remaining <= 0 then
				finish({ ok = false, error = "proxy_timeout" })
				return nil
			end
			if not authorized() then
				if not operation.finished then finish({ ok = false, error = "proxy_cancelled" }) end
				return nil
			end
			if operation.finished then return nil end
			return remaining
		end
		choose = function(index, choices, at)
			local remaining = probe_budget()
			if not remaining then return end
			local choice = choices[at]
			local function keep(route)
				entries[index] = { origin = origins[index], route = route }
				if index == #origins then conclude() else dispatch(index + 1) end
			end
			-- DIRECT, or the explicit "no native proxy source" acknowledgement.
			if choice.mode ~= "selected" then keep("direct"); return end
			if at == #choices then keep(choice.proxy); return end
			local host, port = deps.relay_address(choice.proxy)
			if not host then
				Logger.error(LOG, "Managed Ollama proxy entry %d of origin %d has no probe address.", at, index)
				finish({ ok = false, error = "proxy_route_invalid" })
				return
			end
			step = step + 1
			local mine = step
			local timeout = math.ceil(math.min(deps.probe_timeout_ms, remaining))
			local child, probe_error = deps.probe(host, port, timeout, function(reachable, reason)
				if not probe_budget() then return end
				if reachable then keep(choice.proxy); return end
				Logger.warn(LOG, "Managed Ollama proxy entry %d of origin %d unreachable (%s within %d ms): next PAC entry.",
					at, index, tostring(reason), timeout)
				choose(index, choices, at + 1)
			end)
			if not child then
				Logger.error(LOG, "Managed Ollama proxy probe not started: %s", tostring(probe_error))
				finish({ ok = false, error = "proxy_lookup_unavailable" })
				return
			end
			if step == mine then inner = child end
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
