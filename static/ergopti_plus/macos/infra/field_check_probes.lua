--- infra/field_check_probes.lua

--- ==============================================================================
--- MODULE: Field Run Probes
--- DESCRIPTION:
--- The checks only the developer field run asks for (data/field_run.json), as
--- step lists over the ports of infra/field_check.lua. Each one names, in a
--- single run on the maintainer's Mac, the piece that is broken:
--- 1. permissions: the privacy grants this process holds and the identity
---    (bundle identifier, code signature) macOS files them under.
--- 2. event_taps: every keymap event tap is enabled and watched, the run loop
---    answers a timer on time, and how many holds and late keys the session saw.
--- 3. input_sources: the selected and enabled input sources, and whether every
---    installed Ergopti layout file and bundle property list parses.
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





-- ======================================
-- ======================================
-- ======= 2/ Event taps and loop =======
-- ======================================
-- ======================================

-- Timer probes the run-loop step takes, how long each asks, and the lateness
-- above which key events arrive late at the taps (infra/logger.lua's hold count).
M.RUNLOOP_PROBES = 5
M.RUNLOOP_PROBE_SECONDS = 0.1
M.RUNLOOP_LATE_MS = 250

--- Takes the run-loop probes one after the other.
--- @param ports table Check ports (timer_probe).
--- @param callback function fn(max_late_ms).
local function runloop_lateness(ports, callback)
	local worst, taken = 0, 0
	local function probe()
		ports.timer_probe(M.RUNLOOP_PROBE_SECONDS, function(late_ms)
			taken = taken + 1
			worst = math.max(worst, tonumber(late_ms) or 0)
			if taken >= M.RUNLOOP_PROBES then return callback(worst) end
			probe()
		end)
	end
	probe()
end

--- The keymap's event taps and the run loop that feeds them. Each tap the
--- keymap owns is its own step, so a report names the one macOS disabled; the
--- watchdog that revives a disabled tap must be running. The run loop answers
--- a short timer within the lateness that makes keys late; the session's holds
--- and late keys are information.
function M.event_taps(ports, report, finish)
	local states = ports.tap_states()
	if type(states) ~= "table" then
		report.step("keymap_started", STATE.fail, "not_loaded")
	else
		report.step("keymap_started", states.started and STATE.pass or STATE.fail, states.started and "yes" or "no")
		for _, entry in ipairs(states.taps or {}) do
			report.step("tap_" .. entry.name, entry.state == "enabled" and STATE.pass or STATE.fail, entry.state)
		end
		report.step("tap_watchdog", states.watchdog and STATE.pass or STATE.fail, states.watchdog and "running" or "stopped")
	end
	local counts = ports.health_counts()
	report.step("key_late", STATE.info, (counts.late_downs or 0) + (counts.late_ups or 0))
	report.step("key_late_passed", STATE.info, counts.stale_passed or 0)
	local holds = ports.hold_counts()
	report.step("holds_over_250ms", STATE.info, holds.over_250ms or 0)
	report.step("holds_over_1000ms", STATE.info, holds.over_1000ms or 0)
	report.step("lua_heap_mb", STATE.info, math.floor((tonumber(ports.lua_heap_kb()) or 0) / 1024))
	runloop_lateness(ports, function(worst)
		report.step("runloop_late_ms", worst <= M.RUNLOOP_LATE_MS and STATE.pass or STATE.fail,
			math.max(0, math.floor(worst)))
		finish()
	end)
end





-- ================================
-- ================================
-- ======= 3/ Input sources =======
-- ================================
-- ================================

local XMLLINT = "/usr/bin/xmllint"
local PLUTIL = "/usr/bin/plutil"

--- True when an input source identifier or name is an Ergopti layout.
--- @param value any Identifier or name.
--- @return boolean
local function is_ergopti(value)
	return type(value) == "string" and value:lower():find("ergopti", 1, true) ~= nil
end

--- Runs one bounded checker over each file and counts the refusals.
--- @param ports table Check ports (exec).
--- @param executable string Absolute path of the checker.
--- @param prefix table Arguments before the file.
--- @param files table Absolute paths (never reported).
--- @param callback function fn(bad, timed_out).
local function count_refusals(ports, executable, prefix, files, callback)
	local bad, timed_out = 0, 0
	local function check(index)
		if index > #files then return callback(bad, timed_out) end
		local args = {}
		for _, argument in ipairs(prefix) do args[#args + 1] = argument end
		args[#args + 1] = files[index]
		ports.exec(executable, args, COMMAND_TIMEOUT, function(code)
			if code == nil then timed_out = timed_out + 1 elseif code ~= 0 then bad = bad + 1 end
			check(index + 1)
		end)
	end
	check(1)
end

--- Reports one family of files checked by a parser.
--- @param report table Report.
--- @param id string Step id.
--- @param files table Paths checked.
--- @param bad integer Files the parser refused.
--- @param timed_out integer Files whose check timed out.
local function report_parsed(report, id, files, bad, timed_out)
	if #files == 0 then return report.step(id, STATE.skip, "none_installed") end
	if bad == 0 and timed_out == 0 then return report.step(id, STATE.pass, #files .. "_parsed") end
	report.step(id, STATE.fail, bad > 0 and ("refused_" .. bad .. "_of_" .. #files) or ("timeout_" .. timed_out))
end

--- The input sources macOS has turned on and the Ergopti layouts on disk. The
--- selected source and the enabled list are what the text-input system holds
--- now (not the preference, which it reads at login); every Ergopti .keylayout
--- must parse as XML and every Ergopti bundle's Info.plist as a property list,
--- since macOS drops a layout it cannot read without a word.
function M.input_sources(ports, report, finish)
	local facts = ports.input_source_facts()
	if facts.current == nil then
		report.step("current_source", STATE.fail, "unreadable")
	else
		report.step("current_source", STATE.info, facts.current)
	end
	report.step("current_is_ergopti", STATE.info, is_ergopti(facts.current) and "yes" or "no")
	if type(facts.enabled_ids) ~= "table" then
		report.step("enabled_sources", STATE.fail, "unreadable")
		report.step("ergopti_enabled", STATE.skip, "unreadable")
	else
		local ergopti = 0
		for _, id in ipairs(facts.enabled_ids) do
			if is_ergopti(id) then ergopti = ergopti + 1 end
		end
		report.step("enabled_sources", #facts.enabled_ids > 0 and STATE.pass or STATE.fail, #facts.enabled_ids)
		report.step("ergopti_enabled", STATE.info, ergopti)
	end
	local files = ports.layout_files()
	report.step("layout_bundles", STATE.info, #files.plists)
	count_refusals(ports, XMLLINT, { "--noout", "--nonet" }, files.keylayouts, function(bad, timed_out)
		report_parsed(report, "keylayout_xml", files.keylayouts, bad, timed_out)
		count_refusals(ports, PLUTIL, { "-lint", "-s" }, files.plists, function(plist_bad, plist_timed_out)
			report_parsed(report, "bundle_plist", files.plists, plist_bad, plist_timed_out)
			finish()
		end)
	end)
end

return M
