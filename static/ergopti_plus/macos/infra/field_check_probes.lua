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
--- 4. storage: the keystats database passes SQLite's quick check (read-only),
---    every configuration file parses, the logs folder takes a write and the
---    auto-reload file watchers are owned.
--- 5. launcher_roles: the launcher this runtime resolves answers its headless
---    roles before any application startup, and its native HTTP worker carries
---    one request to a loopback server this check owns.
--- 6. network_hosts: every external host the drivers declare answers one HEAD
---    through the managed transport (route lookup, proxy, TLS), by its key.
---    ollama_blob_host: the host the Ollama registry sends a model's blob to
---    is one the route inventory plans, so the daemon's pull takes its route.
--- 7. app_health: the app's memory and CPU at idle, and the crash reports the
---    driver or macOS wrote for it during the last day.
--- 8. ai_local: the owned Ollama's signature, its server's listing, one token
---    predicted with a model already installed, and the MLX models on disk.
--- 9. menu_build: one timed rebuild of the menu tree and its slowest rows.
--- 10. typing_selftest: the automatic key accounting. The app types a fixed
---    sequence into a scratch field of its own, and only there; the tap must
---    see each key once and the field must hold exactly the sequence.
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
local Json = require("json")

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

--- Rewrites a .keylayout into the XML 1.0 xmllint reads. Apple keyboard
--- layouts are XML 1.1 and carry character references to C0 controls
--- (`&#x0008;` for backspace), which XML 1.0 forbids: libxml2 refused all
--- eight genuine Ergopti files on the 2026-10-30 20:51 run. The declaration is
--- read as 1.0 and each such reference as a space, so the parser judges
--- everything else; a UTF-16 file (byte order mark) is left as it is.
--- @param text string File bytes.
--- @return string text
function M.keylayout_as_xml10(text)
	local head = text:sub(1, 2)
	if head == "\254\255" or head == "\255\254" then return text end
	text = text:gsub('^(%s*<%?xml[^>]-version%s*=%s*["\'])1%.1(["\'])', "%11.0%2", 1)
	local function control(code)
		return code ~= nil and code >= 1 and code <= 31 and code ~= 9 and code ~= 10 and code ~= 13
	end
	text = text:gsub("&#[xX](%x+);", function(hex)
		if control(tonumber(hex, 16)) then return "&#x20;" end
	end)
	text = text:gsub("&#(%d+);", function(decimal)
		if control(tonumber(decimal)) then return "&#x20;" end
	end)
	return text
end

-- xmllint diagnostics, in the order a cause is looked for, with the closed
-- token a refused layout names.
local XML_CAUSES = {
	{ "xmlParseCharRef", "char_ref" },
	{ "Unsupported version", "xml_version" },
	{ "Opening and ending tag mismatch", "tag_mismatch" },
	{ "Premature end of data", "truncated" },
	{ "Document is empty", "empty_input" },
	{ "Start tag expected", "no_root" },
	{ "Extra content at the end", "trailing_content" },
	{ "Entity", "entity" },
	{ "encoding", "encoding" },
	{ "AttValue", "attribute" },
}

--- Names the construct xmllint refused.
--- @param text any The tool's stderr.
--- @return string token
function M.xml_refusal(text)
	text = tostring(text or "")
	for _, cause in ipairs(XML_CAUSES) do
		if text:find(cause[1], 1, true) then return cause[2] end
	end
	return "not_well_formed"
end

--- Parses each .keylayout with xmllint over stdin, after M.keylayout_as_xml10.
--- @param ports table Check ports (read_text, exec_input).
--- @param files table Absolute paths (never reported).
--- @param callback function fn(bad, timed_out, first_cause).
local function check_keylayouts(ports, files, callback)
	local bad, timed_out, cause = 0, 0, nil
	local function check(index)
		if index > #files then return callback(bad, timed_out, cause) end
		local text = ports.read_text(files[index])
		if type(text) ~= "string" then
			bad, cause = bad + 1, cause or "unreadable"
			return check(index + 1)
		end
		ports.exec_input(XMLLINT, { "--noout", "--nonet", "-" }, M.keylayout_as_xml10(text), COMMAND_TIMEOUT,
			function(code, _, errors)
				if code == nil then
					timed_out = timed_out + 1
				elseif code ~= 0 then
					bad, cause = bad + 1, cause or M.xml_refusal(errors)
				end
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
--- @param cause string|nil The construct the first refused file failed on.
local function report_parsed(report, id, files, bad, timed_out, cause)
	if #files == 0 then return report.step(id, STATE.skip, "none_installed") end
	if bad == 0 and timed_out == 0 then return report.step(id, STATE.pass, #files .. "_parsed") end
	report.step(id, STATE.fail, bad > 0 and ("refused_" .. bad .. "_of_" .. #files .. (cause and (":" .. cause) or ""))
		or ("timeout_" .. timed_out))
end

--- The input sources macOS has turned on and the Ergopti layouts on disk. The
--- selected source and the enabled list are what the text-input system holds
--- now (not the preference, which it reads at login); every Ergopti .keylayout
--- must parse as XML (its 1.1 control references aside) and every Ergopti
--- bundle's Info.plist as a property list,
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
	check_keylayouts(ports, files.keylayouts, function(bad, timed_out, cause)
		report_parsed(report, "keylayout_xml", files.keylayouts, bad, timed_out, cause)
		count_refusals(ports, PLUTIL, { "-lint", "-s" }, files.plists, function(plist_bad, plist_timed_out)
			report_parsed(report, "bundle_plist", files.plists, plist_bad, plist_timed_out)
			finish()
		end)
	end)
end





-- ==========================
-- ==========================
-- ======= 4/ Storage =======
-- ==========================
-- ==========================

local SQLITE = "/usr/bin/sqlite3"

-- A large database takes a while to scan; the step deadline covers both scans.
local SQLITE_TIMEOUT = 40

-- Seconds before the second scan that confirms a reported issue.
M.SQLITE_RECHECK_SECONDS = 2

--- Counts the non-empty lines of a command output.
--- @param text any Output.
--- @return integer
local function line_count(text)
	local count = 0
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		if line:match("%S") then count = count + 1 end
	end
	return count
end

--- The keystats database, the configuration files, the logs and the watchers.
--- The database is opened read-only and without a lock (immutable URI) and
--- checked with PRAGMA quick_check, whose only healthy answer is "ok"; each configuration file goes
--- through the driver's own TOML reader without being written; the logs folder
--- takes one probe file that is removed at once; the file watcher owner must be
--- published, since FSEvents refusing a stream leaves every edit unseen.
function M.storage(ports, report, finish)
	for _, file in ipairs(ports.config_files()) do
		local id = "config_" .. file.name
		if not file.present then
			report.step(id, STATE.skip, "absent")
		else
			local parsed = ports.parse_toml(file.path)
			report.step(id, parsed and STATE.pass or STATE.fail, parsed and "parsed" or "parse_error")
		end
	end
	local logs = ports.log_facts()
	report.step("log_today", logs.today_present and STATE.pass or STATE.fail, logs.today_present and "present" or "absent")
	report.step("log_writable", logs.writable and STATE.pass or STATE.fail, logs.writable and "yes" or "no")
	report.step("log_files", STATE.info, logs.files or 0)
	report.step("log_total_mb", STATE.info, math.floor((logs.bytes or 0) / 1048576))
	local owners = ports.watcher_owners()
	report.step("file_watchers", owners > 0 and STATE.pass or STATE.fail, owners > 0 and ("owners_" .. owners) or "none")
	local database = ports.keystats_database()
	if database.path == nil then
		report.step("keystats_db", STATE.skip, "not_initialized")
		return finish()
	end
	if not database.present then
		report.step("keystats_db", STATE.skip, "absent")
		return finish()
	end
	-- immutable=1 takes no lock: the ingest writes in rollback-journal mode, and
	-- a reader's shared lock made its COMMIT fail with "database is locked"
	-- (2026-10-30 20:52:44, during this step). Without a lock a write can land
	-- mid-scan, so a reported issue counts only when a second scan sees it too.
	local uri = M.immutable_uri(database.path)
	local function quick_check(callback)
		ports.exec(SQLITE, { "-readonly", uri, "PRAGMA quick_check;" }, SQLITE_TIMEOUT, function(code, output)
			callback(code, (tostring(output or ""):gsub("%s+$", "")))
		end)
	end
	quick_check(function(code, answer)
		if code == 0 and answer == "ok" then
			report.step("keystats_db", STATE.pass, "quick_check_ok")
			return finish()
		end
		if code ~= 0 then
			report.step("keystats_db", STATE.fail, failure_token(code))
			return finish()
		end
		ports.after(M.SQLITE_RECHECK_SECONDS, function()
			quick_check(function(again_code, again)
				if again_code == 0 and again == "ok" then
					report.step("keystats_db", STATE.info, "concurrent_write")
				elseif again_code == 0 then
					report.step("keystats_db", STATE.fail, "issues_" .. line_count(again))
				else
					report.step("keystats_db", STATE.fail, failure_token(again_code))
				end
				finish()
			end)
		end)
	end)
end

--- The URI SQLite opens without any lock, for a file another connection writes.
--- @param path string Absolute database path.
--- @return string uri
function M.immutable_uri(path)
	local escaped = path:gsub("[%%%?#%s]", function(char) return string.format("%%%02X", char:byte()) end)
	return "file:" .. escaped .. "?immutable=1"
end





-- =================================
-- =================================
-- ======= 5/ Launcher roles =======
-- =================================
-- =================================

M.HTTP_WORKER_FLAG = "--managed-http-worker"

-- The usage refusal every headless role answers to malformed arguments
-- (EX_USAGE), before it reads anything or starts the application.
M.USAGE_EXIT = 64

-- Seconds of the loopback request: its budget and its idle bound, which the
-- worker requires to match its two arguments.
M.LOOPBACK_SECONDS = 5

-- The path the loopback server answers; anything else is not this check's.
M.LOOPBACK_PATH = "/ergopti-field-probe"

--- The request the native HTTP worker reads on stdin, as native_http.py sends it.
--- @param port integer Loopback port.
--- @return string json
function M.loopback_request(port)
	return Json.encode({
		version = 1,
		url = "http://127.0.0.1:" .. tostring(port) .. M.LOOPBACK_PATH,
		method = "GET",
		headers = Json.array({}),
		timeout = M.LOOPBACK_SECONDS,
		idle_timeout = M.LOOPBACK_SECONDS,
		direct = true,
	})
end

--- Reads the worker's first frame: the HTTP head or the refusal it published.
--- The frames are length-prefixed binary; only their JSON bodies are searched,
--- so a stdout the task layer could not decode reads as nothing.
--- @param stdout any Worker stdout.
--- @return integer|nil status, string|nil refusal_stage
function M.parse_worker_head(stdout)
	local text = tostring(stdout or "")
	local stage = text:match('"native_refusal_stage"%s*:%s*"(native_[a-z_]+)"')
	local status = tonumber(text:match('"status"%s*:%s*(%d+)'))
	return status, stage
end

--- The launcher's headless roles. A role must refuse malformed arguments with
--- EX_USAGE at once: anything else means the role did not dispatch (a launcher
--- built before it, a kill by an endpoint agent, the GUI starting). Then the
--- native HTTP worker, which every managed download goes through, carries one
--- direct GET to a loopback server this check opens and closes: an exit code,
--- a refusal stage or a request that never arrived names where it broke. No
--- byte leaves the Mac.
function M.launcher_roles(ports, report, finish)
	local launcher, environment = ports.launcher()
	if type(launcher) ~= "string" then
		report.step("launcher_present", STATE.fail, "unresolved")
		report.step("http_worker_usage", STATE.skip, "no_launcher")
		report.step("http_worker_loopback", STATE.skip, "no_launcher")
		return finish()
	end
	report.step("launcher_present", STATE.pass, "yes")
	ports.exec(launcher, { M.HTTP_WORKER_FLAG }, COMMAND_TIMEOUT, function(usage_code)
		report.step("http_worker_usage", usage_code == M.USAGE_EXIT and STATE.pass or STATE.fail,
			usage_code == M.USAGE_EXIT and "usage_refused" or failure_token(usage_code))
		ports.loopback_server(M.LOOPBACK_PATH, function(server)
			if not server then
				report.step("http_worker_loopback", STATE.fail, "server_refused")
				return finish()
			end
			local seconds = tostring(M.LOOPBACK_SECONDS)
			local request = M.loopback_request(server.port)
			local args = { M.HTTP_WORKER_FLAG, seconds, seconds }
			-- What the worker received, for an EX_USAGE that names no guard
			report.step("http_worker_request", STATE.info, "args_" .. (#args + 1) .. ":bytes_" .. #request)
			ports.exec_input(launcher, args, request,
				COMMAND_TIMEOUT, function(code, stdout)
					local hits = server.hits()
					server.stop()
					local status, stage = M.parse_worker_head(stdout)
					if code == 0 and hits == 1 then
						report.step("http_worker_loopback", STATE.pass, "http_" .. tostring(status or "unread"))
					elseif stage then
						report.step("http_worker_loopback", STATE.fail, failure_token(code) .. ":" .. stage)
					elseif hits == 0 then
						report.step("http_worker_loopback", STATE.fail, failure_token(code) .. ":not_reached")
					else
						report.step("http_worker_loopback", STATE.fail, failure_token(code) .. ":hits_" .. hits)
					end
					finish()
				end, environment)
		end)
	end, environment)
end





-- ================================
-- ================================
-- ======= 6/ Network hosts =======
-- ================================
-- ================================

--- Reads the helper's `step host_<key> <state> <value>` lines.
--- @param output any Helper stdout.
--- @return table steps key → { state, value }
function M.parse_host_lines(output)
	local steps = {}
	for key, state, value in tostring(output or ""):gmatch("step host_([%w_]+) (%a+) (%S+)") do
		if (state == STATE.pass or state == STATE.fail) and not steps[key] then
			steps[key] = { state = state, value = value }
		end
	end
	return steps
end

--- The external hosts the drivers declare, each reached with one HEAD to its
--- root through the managed transport a download uses (route lookup, PAC or
--- proxy, TLS trust), by the native helper. Any HTTP answer below 500 proves
--- the route; a host the helper did not answer for fails by its key.
function M.network_hosts(ports, report, finish)
	local keys = {}
	for key in pairs(Identifiers.hosts) do keys[#keys + 1] = key end
	table.sort(keys)
	ports.host_heads(function(code, output)
		local steps = code == 0 and M.parse_host_lines(output) or {}
		for _, key in ipairs(keys) do
			local step = steps[key]
			if step then
				report.step("host_" .. key, step.state, step.value)
			else
				report.step("host_" .. key, STATE.fail, code == nil and "helper_unavailable" or "no_answer")
			end
		end
		finish()
	end)
end

--- Reads the helper's blob_manifest and blob_host lines.
--- @param output any Helper stdout.
--- @return table steps id → { state, value }
function M.parse_blob_lines(output)
	local steps = {}
	for id, state, value in tostring(output or ""):gmatch("step (blob_[%w_]+) (%a+) (%S+)") do
		if (id == "blob_manifest" or id == "blob_host") and not steps[id] then
			steps[id] = { state = state, value = value }
		end
	end
	return steps
end

--- The Ollama daemon pulls a model's blobs from the host the registry redirects
--- it to, on the route the inventory (route_origins.json) planned for that
--- host. The helper reads the smallest catalogue model's manifest and asks for
--- one blob without following the redirect: a blob host the inventory does not
--- plan fails, since behind a PAC the daemon would fetch it on the wrong route.
function M.ollama_blob_host(ports, report, finish)
	local model = ports.smallest_ollama_model()
	if not model then
		report.step("blob_manifest", STATE.skip, "no_catalogue_model")
		report.step("blob_host", STATE.skip, "no_catalogue_model")
		finish()
		return
	end
	ports.blob_host(model.runtime_name, function(code, output)
		local steps = code == 0 and M.parse_blob_lines(output) or {}
		for _, id in ipairs({ "blob_manifest", "blob_host" }) do
			local step = steps[id]
			if step then
				report.step(id, step.state, step.value)
			else
				report.step(id, STATE.fail, code == nil and "helper_unavailable" or "no_answer")
			end
		end
		finish()
	end)
end





-- =============================
-- =============================
-- ======= 7/ App health =======
-- =============================
-- =============================

local PS = "/bin/ps"

-- Newest app crash reports listed one by one with their kind.
M.CRASHES_LISTED = 3

--- Reads `ps -o rss=,%cpu=` output.
--- @param output any Command output.
--- @return number|nil rss_kb, number|nil cpu_percent
function M.parse_usage(output)
	local rss, cpu = tostring(output or ""):match("^%s*(%d+)%s+([%d.,]+)")
	if not rss then return nil, nil end
	return tonumber(rss), tonumber((cpu:gsub(",", ".")))
end

--- The app's resident memory and CPU share while the field run waits between
--- steps, and the crash reports of the last day: the driver's own (a Lua
--- fatal it caught) and the ones macOS wrote for this app's processes (the app
--- and its launcher roles, Hammerspoon, Ollama, Python, Karabiner), which fail
--- by process and are listed with their closed kind (hang or crash, exception,
--- signal, termination namespace); other apps' reports are counted only.
function M.app_health(ports, report, finish)
	local crashes = ports.crash_counts()
	report.step("driver_crash_reports_24h", (crashes.driver or 0) == 0 and STATE.pass or STATE.fail, crashes.driver or 0)
	-- One of this app's processes fails the step; every other app's report is information
	local owned = crashes.owned or {}
	local per_process, names = {}, {}
	for _, entry in ipairs(owned) do
		if not per_process[entry.process] then names[#names + 1] = entry.process end
		per_process[entry.process] = (per_process[entry.process] or 0) + 1
	end
	table.sort(names)
	local parts = {}
	for _, name in ipairs(names) do parts[#parts + 1] = name .. ":" .. per_process[name] end
	report.step("app_crash_reports_24h", #owned == 0 and STATE.pass or STATE.fail,
		#owned == 0 and 0 or table.concat(parts, "+"))
	for index = 1, math.min(#owned, M.CRASHES_LISTED) do
		report.step("app_crash_" .. index, STATE.info, owned[index].process .. ":" .. owned[index].kind)
	end
	report.step("other_crash_reports_24h", STATE.info, crashes.other or 0)
	ports.exec(PS, { "-o", "rss=,%cpu=", "-p", tostring(ports.pid()) }, COMMAND_TIMEOUT, function(code, output)
		local rss, cpu = M.parse_usage(code == 0 and output or "")
		if not rss then
			report.step("app_rss_mb", STATE.fail, failure_token(code))
			report.step("app_cpu_pct", STATE.skip, "unreadable")
		else
			report.step("app_rss_mb", STATE.info, math.floor(rss / 1024))
			report.step("app_cpu_pct", STATE.info, string.format("%.1f", cpu or 0))
		end
		finish()
	end)
end





-- ===========================
-- ===========================
-- ======= 8/ Local AI =======
-- ===========================
-- ===========================

-- The prediction the local AI step asks for: a few digits of the check's own,
-- never a person's text, answered with one token.
M.PREDICTION_TEXT = "1 2 3 4"

--- The local AI without downloading or starting anything: the owned Ollama
--- binary must pass a strict signature check (macOS kills an invalid one at
--- launch, field run 2026-10-27 22:32); a running server must list its
--- models; one token is predicted with the smallest catalogue model already
--- installed, through the driver's own request path; the MLX runtime and the
--- catalogue models in its cache are counted. A server that is not running
--- and a Mac with no model are skips, never a download.
function M.ai_local(ports, report, finish)
	local facts = ports.ai_facts()
	report.step("mlx_runtime", STATE.info, facts.mlx_runtime == nil and "unknown" or (facts.mlx_runtime and "installed" or "absent"))
	report.step("mlx_models_installed", STATE.info, facts.mlx_installed == nil and "unknown" or facts.mlx_installed)
	local function listing_stage()
		ports.ollama_refresh(function(listed)
			if not listed then
				report.step("ollama_listing", STATE.skip, "not_running")
				report.step("ollama_prediction", STATE.skip, "not_running")
				return finish()
			end
			report.step("ollama_listing", STATE.pass, "listed")
			local model = ports.ollama_installed_model()
			report.step("ollama_installed", STATE.info, model and "yes" or "none_of_the_catalogue")
			if not model then
				report.step("ollama_prediction", STATE.skip, "no_installed_model")
				return finish()
			end
			ports.ollama_predict(model, M.PREDICTION_TEXT, function(answered, token, elapsed_ms)
				report.step("ollama_prediction", answered and STATE.pass or STATE.fail,
					answered and (math.floor(elapsed_ms or 0) .. "ms") or (token or "failed"))
				finish()
			end)
		end)
	end
	if type(facts.ollama_path) ~= "string" then
		report.step("ollama_binary", STATE.skip, "not_installed")
		return listing_stage()
	end
	ports.exec(CODESIGN, { "--verify", "--strict", "--verbose=2", facts.ollama_path }, COMMAND_TIMEOUT,
		function(code, output, errors)
			if code == 0 then
				report.step("ollama_binary", STATE.pass, "signature_valid")
			else
				local text = tostring(output or "") .. "\n" .. tostring(errors or "")
				report.step("ollama_binary", STATE.fail, code == nil and "timeout"
					or failure_token(code) .. ":" .. (signature_cause(text) or "unclassified"))
			end
			listing_stage()
		end)
end





-- =============================
-- =============================
-- ======= 9/ Menu build =======
-- =============================
-- =============================

-- Slowest top-level rows the menu step names.
M.MENU_SLOWEST_LISTED = 3

--- One rebuild of the menu tree, timed, as a state change rebuilds it. The
--- rebuild must succeed (AppKit accepted the tree); its duration, the number
--- of top-level rows and the slowest ones are information for the analyser.
function M.menu_build(ports, report, finish)
	local outcome = ports.menu_rebuild()
	if type(outcome) ~= "table" then
		report.step("menu_rebuild", STATE.fail, "menu_absent")
		return finish()
	end
	report.step("menu_rebuild", outcome.ok and STATE.pass or STATE.fail, outcome.ok and "rebuilt" or "refused")
	report.step("menu_rebuild_ms", STATE.info, math.floor(outcome.ms or 0))
	report.step("menu_top_items", STATE.info, outcome.items or 0)
	for index = 1, M.MENU_SLOWEST_LISTED do
		local entry = (outcome.slowest or {})[index]
		if entry then
			report.step("menu_slowest_" .. index, STATE.info,
				tostring(entry.id) .. ":" .. string.format("%.1f", tonumber(entry.ms) or 0))
		end
	end
	finish()
end





-- ====================================
-- ====================================
-- ======= 10/ Typing self-test =======
-- ====================================
-- ====================================

-- The sequence typed into the scratch field: plain letters with no terminator,
-- so nothing reacts to it even if the tag were lost.
M.SELFTEST_KEYS = { "w", "k", "j", "x" }

-- Seconds the passive counter watches; the scratch typing ends well before.
M.SELFTEST_COUNT_SECONDS = 6

--- The automatic key accounting. The app opens a scratch text field of its
--- own, brings it to the front and types the fixed sequence there, checking
--- before each key that the field still has the focus: a key never reaches the
--- user's application, and a lost focus stops the sequence with its code. The
--- passive counter must see each posted key once and the field must hold the
--- sequence exactly; the previous application gets the focus back. The keys
--- go through the tagged injection owner, so the keymap and keystats treat
--- them as the driver's own output; they are posted after Karabiner, so the
--- virtual keyboard path and the ledger's double count are only provable with
--- physical keys, as their codes say.
function M.typing_selftest(ports, report, finish)
	local expected = table.concat(M.SELFTEST_KEYS)
	local before = ports.keystats_facts()
	local typed = nil
	ports.count_keys(M.SELFTEST_COUNT_SECONDS, function(observed)
		local after = ports.keystats_facts()
		if type(typed) ~= "table" then
			report.step("scratch_focus", STATE.fail, "typing_unsettled")
			return finish()
		end
		report.step("scratch_focus", typed.focused and STATE.pass or STATE.fail, typed.focused and "focused"
			or (typed.aborted or "not_focused"))
		local posted = typed.posted or 0
		report.step("keys_posted", posted == #M.SELFTEST_KEYS and STATE.pass or STATE.fail,
			posted == #M.SELFTEST_KEYS and posted or ("posted_" .. posted .. "_of_" .. #M.SELFTEST_KEYS
				.. (typed.aborted and (":" .. typed.aborted) or "")))
		report.step("tap_running", observed.tap_running and STATE.pass or STATE.fail, observed.tap_running and "yes" or "no")
		local presses = observed.presses or 0
		report.step("presses_seen", posted > 0 and presses == posted and STATE.pass or STATE.fail,
			"seen_" .. presses .. "_of_" .. posted)
		if typed.text == nil then
			report.step("field_text", posted > 0 and STATE.fail or STATE.skip, "unreadable")
		else
			report.step("field_text", typed.text == expected and STATE.pass or STATE.fail,
				typed.text == expected and "exact" or ("mismatch_" .. #typed.text .. "_chars"))
		end
		if typed.latency_ms then report.step("type_latency_ms", STATE.info, math.floor(typed.latency_ms)) end
		report.step("ledger_credits", STATE.info,
			math.max(0, (after.ledger_drained or 0) - (before.ledger_drained or 0)))
		report.step("source", STATE.info, after.credit_source)
		report.step("karabiner_path", STATE.skip, "physical_keys_only")
		report.step("double_count", STATE.skip, "physical_keys_only")
		report.step("front_restored", typed.restored and STATE.pass or STATE.fail, typed.restored and "yes" or "no")
		report.step("keystats_effect", STATE.info, "tagged_synthetic_input")
		finish()
	end)
	ports.scratch_typing(M.SELFTEST_KEYS, function(outcome) typed = outcome end)
end

return M
