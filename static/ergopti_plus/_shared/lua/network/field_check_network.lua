--- _shared/lua/network/field_check_network.lua

--- ==============================================================================
--- MODULE: Shared Network Field Check
--- DESCRIPTION:
--- The steps of the Debug menu's « Test network (PAC, proxy, download) » check,
--- in the order every driver reports them: the system proxy settings, the PAC
--- download and verdict, then the managed download chain (route lookup, TLS,
--- transfer, digest). The check follows the managed transport's own path, so a
--- company proxy that breaks a download names the step that failed (issue #101)
--- instead of a generic network error.
---
--- FEATURES & RATIONALE:
--- 1. One definition for macOS and Linux. The Windows driver runs the same
---    steps in AutoHotkey (windows/ui/field_check/network_check.ahk) and a
---    corpus test pins that both spell the same step identities in the same
---    order.
--- 2. Ports, not platform calls. The driver supplies how it reads its proxy
---    settings, how it downloads a PAC and how it runs one request through its
---    managed transport; this module only sequences them and judges the answers.
--- 3. Privacy by construction. A PAC address is handed to the port that fetches
---    it and goes nowhere else; step values are closed tokens (kinds of proxy,
---    HTTP status classes, native failure stages), never a URL, a host, a user
---    name or PAC content.
--- 4. Settle once. finish() is called exactly once, after the last step.
--- ==============================================================================

local M = {}

local PacCheck = require("network.pac_check")
local RoutePlan = require("network.route_plan")

--- Step identities in report order; the locale key of each is
--- field_check.step.<id>.
M.STEP_IDS = { "proxy_settings", "pac_download", "pac_script", "route_lookup", "tls", "transfer", "digest" }

--- Steps macOS and Linux report after the chain: the route each origin of the managed
--- Ollama daemon takes (the Windows check does not report it yet, so the identities the
--- Windows list must equal stay M.STEP_IDS).
M.PLAN_STEPS = { "route_plan" }

--- The closed names of the managed Ollama daemon's origins, in the order of
--- route_origins.json "ollama" (the registry, then its blob host). A host name never
--- reaches a report; a new origin in the inventory needs a new name here.
M.OLLAMA_ORIGIN_TOKENS = { "registry", "blob" }

--- Steps the managed download chain reports, in display order.
M.CHAIN_STEPS = { "route_lookup", "tls", "transfer", "digest" }

--- States a chain step may carry.
M.CHAIN_STATES = { pass = true, fail = true, info = true, skip = true }

local STATE = { pass = "pass", fail = "fail", info = "info", skip = "skip" }

--- Reads the `step <id> <state> <value>` lines of a helper that ran the chain.
--- Unknown ids, states and repeated ids are ignored: a helper cannot add a step.
--- @param output any Helper stdout.
--- @return table steps id → { state, value }
function M.parse_chain_lines(output)
	local wanted, steps = {}, {}
	for _, id in ipairs(M.CHAIN_STEPS) do wanted[id] = true end
	for id, state, value in tostring(output or ""):gmatch("step (%S+) (%S+) (%S+)") do
		if wanted[id] and M.CHAIN_STATES[state] and not steps[id] then
			steps[id] = { state = state, value = value }
		end
	end
	return steps
end

--- Records the chain's four steps. A missing step is a failure of the transfer
--- (the one that matters) and a skip of the others.
--- @param report table The run's report.
--- @param helper_code number|nil Exit code of the chain runner, nil when it could not start.
--- @param steps table id → { state, value }
local function record_chain(report, helper_code, steps)
	for _, id in ipairs(M.CHAIN_STEPS) do
		local step = steps[id]
		if step then
			report.step(id, step.state, step.value)
		elseif id == "transfer" then
			report.step(id, STATE.fail, helper_code == nil and "helper_unavailable" or "no_answer")
		else
			report.step(id, STATE.skip, helper_code == nil and "helper_unavailable" or "no_answer")
		end
	end
end

--- Records the route each Ollama origin takes: direct or through a relay, never an
--- address. The daemon holds one relay, so the same refusal that stops its start
--- (a conflict between relays, an unplanned host) fails this step by its closed reason.
--- @param report table The run's report.
--- @param answer table { entries = { { origin, route }, ... } } or { failure = token }
local function record_route_plan(report, answer)
	if answer.failure then
		report.step("route_plan", STATE.fail, answer.failure)
		return
	end
	local entries = answer.entries
	assert(type(entries) == "table" and #entries == #M.OLLAMA_ORIGIN_TOKENS,
		"route plan entries must follow the Ollama origin inventory")
	local plan, reason = RoutePlan.plan(entries)
	if not plan then
		report.step("route_plan", STATE.fail, reason)
		return
	end
	local parts = {}
	for index, entry in ipairs(entries) do
		parts[index] = M.OLLAMA_ORIGIN_TOKENS[index] .. ":" .. (entry.route == "direct" and "direct" or "relay")
	end
	report.step("route_plan", STATE.info, table.concat(parts, "+"))
end

--- Runs the check.
--- ports:
---   proxy_settings(callback)  callback{ kinds = token, pac_url = string|nil } or
---                             callback{ failure = "timeout"|"unreadable" }
---   fetch_pac(url, callback)  callback(status|nil, body|nil)
---   chain(callback)           callback(helper_code|nil, steps) with steps as
---                             parse_chain_lines() returns them
---   route_plan(callback)      callback{ entries = { { origin, route }, ... } } with one
---                             entry per Ollama origin in inventory order and route
---                             "direct" or a relay, or callback{ failure = token }
--- @param ports table
--- @param report table Report from field_check_report.new_report().
--- @param finish function Called once, after the last step.
function M.run(ports, report, finish)
	assert(type(ports.route_plan) == "function", "the network check needs a route_plan port")
	local function native_chain()
		ports.chain(function(helper_code, steps)
			record_chain(report, helper_code, helper_code == 0 and steps or {})
			ports.route_plan(function(answer)
				record_route_plan(report, answer)
				finish()
			end)
		end)
	end
	ports.proxy_settings(function(settings)
		if settings.failure then
			report.step("proxy_settings", STATE.fail, settings.failure)
		else
			report.step("proxy_settings", STATE.info, settings.kinds)
		end
		local url = not settings.failure and settings.pac_url or nil
		if not url then
			report.step("pac_download", STATE.skip, "no_pac")
			report.step("pac_script", STATE.skip, "no_pac")
			native_chain()
			return
		end
		ports.fetch_pac(url, function(status, body)
			local number = tonumber(status) or 0
			report.step("pac_download", number == 200 and STATE.pass or STATE.fail,
				number > 0 and ("http_" .. number) or "failed")
			local verdict = PacCheck.judge(status, body)
			report.step("pac_script", verdict == "ok" and STATE.pass or STATE.fail,
				verdict == "ok" and "valid" or "invalid")
			native_chain()
		end)
	end)
end

return M
