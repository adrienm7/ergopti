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
--- 5. The verdict follows what the driver's downloads do. Where the driver's
---    PAC fallback (pac_fallback port) sends a download direct when the PAC
---    cannot be fetched or evaluated, that PAC failure is information
---    (unreachable_direct, http_<status>_direct, invalid_direct) and the chain
---    steps prove whether the direct path works. A driver without that port
---    refuses such downloads, so the failure stays a failure.
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

--- The pac_unavailable_fallback stages (proxy_policy.json) a PAC download and
--- a PAC verdict stand for.
M.PAC_DOWNLOAD_STAGE = "native_pac_download"
M.PAC_EVALUATION_STAGE = "native_pac_evaluation"

--- Records the PAC download and verdict steps.
--- @param report table The run's report.
--- @param status any HTTP status, nil or 0 when the download failed.
--- @param body any The downloaded script.
--- @param pac_fallback function|nil fn(stage) -> boolean, the driver's fallback policy.
local function record_pac(report, status, body, pac_fallback)
	local number = tonumber(status) or 0
	local function falls_back(stage) return pac_fallback ~= nil and pac_fallback(stage) == true end
	if number ~= 200 then
		local token = number > 0 and ("http_" .. number) or "failed"
		if falls_back(M.PAC_DOWNLOAD_STAGE) then
			report.step("pac_download", STATE.info, number > 0 and (token .. "_direct") or "unreachable_direct")
			report.step("pac_script", STATE.skip, "not_fetched")
		else
			report.step("pac_download", STATE.fail, token)
			report.step("pac_script", STATE.fail, "invalid")
		end
		return
	end
	report.step("pac_download", STATE.pass, "http_200")
	if PacCheck.judge(status, body) == "ok" then
		report.step("pac_script", STATE.pass, "valid")
	elseif falls_back(M.PAC_EVALUATION_STAGE) then
		report.step("pac_script", STATE.info, "invalid_direct")
	else
		report.step("pac_script", STATE.fail, "invalid")
	end
end

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
--- A lookup that failed at a stage the driver's PAC fallback covers is not a
--- failure of the download: it goes direct, so the step says so (info).
--- @param answer table { entries = { { origin, route }, ... } } or { failure = token }
--- @param pac_fallback function|nil fn(stage) -> boolean, the driver's fallback policy.
local function record_route_plan(report, answer, pac_fallback)
	if answer.failure then
		if pac_fallback and pac_fallback(answer.failure) == true then
			report.step("route_plan", STATE.info, "direct_fallback:" .. answer.failure)
		else
			report.step("route_plan", STATE.fail, answer.failure)
		end
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
---   pac_fallback(stage)       optional: true when a failed lookup stage sends the
---                             download direct (the driver's PAC fallback policy)
--- @param ports table
--- @param report table Report from field_check_report.new_report().
--- @param finish function Called once, after the last step.
function M.run(ports, report, finish)
	assert(type(ports.route_plan) == "function", "the network check needs a route_plan port")
	local function native_chain()
		ports.chain(function(helper_code, steps)
			record_chain(report, helper_code, helper_code == 0 and steps or {})
			ports.route_plan(function(answer)
				record_route_plan(report, answer, ports.pac_fallback)
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
			record_pac(report, status, body, ports.pac_fallback)
			native_chain()
		end)
	end)
end

return M
