--- infra/field_check_probes.lua

--- ==============================================================================
--- MODULE: Field Run Probes
--- DESCRIPTION:
--- The checks only the developer field run asks for (data/field_run.json), as
--- step lists over the ports of infra/field_check.lua. Each one names, in a
--- single run on the maintainer's Mac, the piece that is broken:
--- 1. permissions: the privacy grants this process holds and the identity
---    (bundle identifier, code signature) macOS files them under.
---
--- FEATURES & RATIONALE:
--- 1. Read-only, like the Debug checks: nothing is granted, prompted, written
---    or reconfigured; a person's choice (a permission prompt) is never made.
--- 2. Closed values: states, counts, versions and tokens. A path given to a
---    port is never reported (infra/field_check.lua enforces the grammar).
--- 3. One failing step per broken piece, so the field run's fail_<step> code
---    names the check without reading the log.
--- 4. No platform call here: every system fact comes through a port
---    (adapters/field_probe_ports.lua), so the portable suite drives each step.
--- ==============================================================================

local Identifiers = require("identifiers")

local M = {}

local STATE = { pass = "pass", fail = "fail", info = "info", skip = "skip" }

-- Seconds an external command may run before its step is a timeout.
local COMMAND_TIMEOUT = 10

local CODESIGN = "/usr/bin/codesign"

--- Describes why a bounded command did not succeed, as a closed token.
--- @param code any Exit code, nil when it timed out.
--- @return string token "timeout" or "exit_<code>".
local function failure_token(code)
	return code == nil and "timeout" or "exit_" .. tostring(code)
end

--- Names the first known cause in a codesign diagnostic. The causes are the
--- Debug checks' table; that module registers this one, so it is required here
--- at call time rather than at load time.
--- @param text any The tool's stderr.
--- @return string|nil token
local function signature_cause(text)
	return require("infra.field_check_checks").signature_cause(text)
end

--- A permission answer as a closed value.
--- @param granted boolean|nil The native answer, nil when it could not be read.
--- @return string value "granted", "missing" or "unreadable".
local function grant_value(granted)
	if granted == true then return "granted" end
	if granted == false then return "missing" end
	return "unreadable"
end





-- ===============================================
-- ===============================================
-- ======= 1/ Permissions and app identity =======
-- ===============================================
-- ===============================================

--- Names which declared bundle identifier the process runs under.
--- @param bundle_id any The identifier macOS reports for this process.
--- @return string value "launcher", "hammerspoon", "other" or "none".
function M.classify_bundle_id(bundle_id)
	if type(bundle_id) ~= "string" or bundle_id == "" then return "none" end
	for role, declared in pairs(Identifiers.bundle_ids) do
		if bundle_id == declared then return role end
	end
	return "other"
end

--- Reads the signing identity from `codesign -dv --verbose=2` output.
--- @param text any The tool's stderr, where it writes the description.
--- @return string value "adhoc", "team:<id>", "unsigned" or "unknown".
function M.parse_signing_identity(text)
	text = tostring(text or "")
	if text:find("code object is not signed at all", 1, true) then return "unsigned" end
	if text:match("Signature=adhoc") then return "adhoc" end
	local team = text:match("TeamIdentifier=(%w+)")
	if team and team ~= "not" then return "team:" .. team end
	if text:match("TeamIdentifier=not set") then return "adhoc" end
	return "unknown"
end

--- The privacy grants of this process and the identity they are filed under.
--- Accessibility is required (no event can be rewritten without it); Input
--- Monitoring and Screen Recording are information, the first because the
--- grant the remap needs belongs to the Karabiner grabber. Automation has no
--- query that cannot prompt, so its step is skipped and says so. The running
--- bundle's strict signature and its signing identity show whether a rebuild
--- keeps the grants (an ad hoc signature changes with every build).
function M.permissions(ports, report, finish)
	local facts = ports.permission_facts()
	report.step("accessibility", facts.accessibility == true and STATE.pass or STATE.fail,
		grant_value(facts.accessibility))
	report.step("input_monitoring", STATE.info,
		facts.input_monitoring == nil and "not_queryable" or grant_value(facts.input_monitoring))
	report.step("screen_recording", STATE.info, grant_value(facts.screen_recording))
	report.step("automation", STATE.skip, "not_queryable")
	local secure = facts.secure_input
	report.step("secure_input", STATE.info, secure == nil and "unreadable" or (secure and "on" or "off"))
	local role = M.classify_bundle_id(facts.bundle_id)
	report.step("bundle_id", (role == "launcher" or role == "hammerspoon") and STATE.pass or STATE.fail, role)
	local bundle = ports.running_bundle_path()
	if type(bundle) ~= "string" or bundle == "" then
		report.step("app_signature", STATE.skip, "no_bundle")
		report.step("signing_identity", STATE.skip, "no_bundle")
		return finish()
	end
	ports.exec(CODESIGN, { "--verify", "--strict", "--verbose=2", bundle }, COMMAND_TIMEOUT,
		function(code, output, errors)
			if code == 0 then
				report.step("app_signature", STATE.pass, "valid")
			else
				local text = tostring(output or "") .. "\n" .. tostring(errors or "")
				report.step("app_signature", STATE.fail, code == nil and "timeout"
					or failure_token(code) .. ":" .. (signature_cause(text) or "unclassified"))
			end
			ports.exec(CODESIGN, { "-dv", "--verbose=2", bundle }, COMMAND_TIMEOUT,
				function(describe_code, describe_output, describe_errors)
					local text = tostring(describe_output or "") .. "\n" .. tostring(describe_errors or "")
					local identity = M.parse_signing_identity(text)
					if describe_code ~= 0 and identity ~= "unsigned" then identity = failure_token(describe_code) end
					report.step("signing_identity", STATE.info, identity)
					finish()
				end)
		end)
end

return M
