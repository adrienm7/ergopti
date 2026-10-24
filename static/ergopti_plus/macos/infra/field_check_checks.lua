--- infra/field_check_checks.lua

--- ==============================================================================
--- MODULE: Field Check Definitions
--- DESCRIPTION:
--- The four one-click Mac checks of the Debug menu, as step lists over the
--- ports of infra/field_check.lua:
--- 1. lease: is the Karabiner lease healthy right now (command line tool,
---    integration switch, lease phase, guardian, losses this session)?
--- 2. owned_runtime: is the Ergopti-owned Karabiner runtime (ADR 011, HS-274)
---    still dormant, and what of it is installed on this Mac?
--- 3. key_accounting: for a few seconds, how many key presses does the Quartz
---    event tap see and how many credits does the Karabiner ledger append, and
---    which source is allowed to credit?
--- 4. toolchain: do the timer service, the Apple Shortcuts tool, Homebrew and the
---    installed Karabiner-Elements package behave as the driver assumes?
--- 5. login_items: what starts Ergopti or Hammerspoon at login (login item state,
---    background items, launch agents), and does each entry belong to the
---    running copy or to another one?
---
--- FEATURES & RATIONALE:
--- 1. Read-only: no step starts, stops or reconfigures Karabiner, writes a file
---    or changes a setting. A check can be run at any time without effect.
--- 2. Counts, states and versions only: no key, character, path, URL or user
---    name is read into a step value (infra/field_check.lua enforces the
---    grammar again).
--- 3. Every external command is bounded by a timeout and settles the check
---    once, so a hung launchctl never leaves a window waiting.
--- ==============================================================================

local KePaths = require("platform.remap.ke_paths")

local M = {}

local STATE = { pass = "pass", fail = "fail", info = "info", skip = "skip" }

local OWNED_RUNTIME_DIR = "/Library/Application Support/ErgoptiPlus/Runtime"
local OWNED_JOB_FILE = "/Library/LaunchDaemons/com.ergoptiplus.runtime.core.plist"
local OWNED_JOB = "system/com.ergoptiplus.runtime.core"
local STOCK_APP = "/Applications/Karabiner-Elements.app"
local VHID_EXTENSION = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"

--- Seconds the key accounting check watches the keyboard.
M.KEY_ACCOUNTING_SECONDS = 30

-- Seconds an external command may run before its step is a timeout.
local COMMAND_TIMEOUT = 5

local function yes_no(flag) return flag and "yes" or "no" end

--- Counts the non-empty lines of a command output.
--- @param text any Command output.
--- @return integer
local function count_lines(text)
	local count = 0
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		if line:match("%S") then count = count + 1 end
	end
	return count
end

--- Extracts the activation state of the virtual keyboard driver from the
--- output of `systemextensionsctl list`, as a token such as activated_enabled.
--- @param output any Command output.
--- @return string state "absent" when the extension is not listed.
function M.parse_driver_state(output)
	for line in tostring(output or ""):gmatch("[^\r\n]+") do
		if line:find(VHID_EXTENSION, 1, true) then
			local state = line:match("%[([%a%s]+)%]")
			if not state then return "unknown" end
			return (state:gsub("%s+", "_"))
		end
	end
	return "absent"
end

--- Extracts a dotted version number from a command line tool's output.
--- @param output any Command output.
--- @return string|nil version
function M.parse_version(output)
	return tostring(output or ""):match("(%d+%.%d+[%.%d]*)")
end

--- Phases in which the lease is not usable.
local BAD_PHASES = { failed = true, fencing = true, recovering = true, uninitialized = true }

--- Karabiner lease health.
function M.lease(ports, report, finish)
	local remap = ports.remap_facts()
	local enabled = remap.enabled == true
	local cli = ports.path_exists(KePaths.CLI)
	report.step("cli_present", (cli or not enabled) and STATE.pass or STATE.fail, yes_no(cli))
	report.step("integration_enabled", STATE.info, yes_no(enabled))
	if enabled then
		report.step("lease_phase", BAD_PHASES[remap.phase] and STATE.fail or STATE.pass, remap.phase)
		report.step("guardian_state", remap.guardian == "ready" and STATE.pass or STATE.fail, remap.guardian)
	else
		report.step("lease_phase", STATE.skip, remap.phase)
		report.step("guardian_state", STATE.skip, remap.guardian)
	end
	local home = ports.home()
	if home then
		report.step("config_present", STATE.info, yes_no(ports.path_exists(home .. "/.config/karabiner/karabiner.json")))
	else
		report.step("config_present", STATE.skip, "no_home")
	end
	local counts = ports.health_counts()
	local lease_total = 0
	for _, value in pairs(counts.lease or {}) do lease_total = lease_total + value end
	report.step("lease_failures", lease_total == 0 and STATE.pass or STATE.fail, lease_total)
	local losses = (counts.ups_without_down or 0) + (counts.downs_without_up or 0) + (counts.stuck or 0)
	report.step("key_losses", losses == 0 and STATE.pass or STATE.fail, losses)
	if not cli then
		report.step("cli_version", STATE.skip, "no_cli")
		finish()
		return
	end
	ports.exec(KePaths.CLI, { "--version" }, COMMAND_TIMEOUT, function(code, output)
		local version = code == 0 and M.parse_version(output) or nil
		report.step("cli_version", version and STATE.pass or STATE.fail, version or (code == nil and "timeout" or "exit_" .. tostring(code)))
		finish()
	end)
end

--- Dormancy of the owned runtime and what is installed.
function M.owned_runtime(ports, report, finish)
	local facts = ports.keystats_facts()
	report.step("dormant_source", facts.credit_source == "legacy" and STATE.pass or STATE.fail, facts.credit_source)
	report.step("capture_unloaded", facts.capture_loaded and STATE.fail or STATE.pass, yes_no(not facts.capture_loaded))
	report.step("runtime_installed", STATE.info, yes_no(ports.path_exists(OWNED_RUNTIME_DIR)))
	report.step("job_file", STATE.info, yes_no(ports.path_exists(OWNED_JOB_FILE)))
	report.step("stock_app", STATE.info, yes_no(ports.path_exists(STOCK_APP)))
	ports.exec("/bin/launchctl", { "print", OWNED_JOB }, COMMAND_TIMEOUT, function(code)
		report.step("job_loaded", STATE.info, code == 0 and "loaded" or (code == nil and "timeout" or "not_loaded"))
		ports.exec("/usr/sbin/systemextensionsctl", { "list" }, COMMAND_TIMEOUT, function(ext_code, ext_out)
			report.step("driver_state", STATE.info, ext_code == 0 and M.parse_driver_state(ext_out) or "unreadable")
			ports.exec("/usr/bin/pgrep", { "-f", "org.pqrs/Karabiner" }, COMMAND_TIMEOUT, function(stock_code, stock_out)
				report.step("stock_running", STATE.info, stock_code == nil and "timeout" or count_lines(stock_out))
				ports.exec("/usr/bin/pgrep", { "-f", "ErgoptiPlus/Runtime" }, COMMAND_TIMEOUT, function(own_code, own_out)
					report.step("owned_running", STATE.info, own_code == nil and "timeout" or count_lines(own_out))
					ports.owned_readiness(function(facts)
						local unpinned = facts.unpinned
						report.step("artifact_pin", STATE.info,
							unpinned == nil and "unreadable" or (unpinned == 0 and "pinned" or ("unpinned_" .. unpinned)))
						report.step("installed_source", STATE.info, facts.source and "reachable" or "unavailable")
						report.step("other_karabiner_helper", STATE.info, yes_no(facts.helper_present))
						report.step("other_karabiner_active", STATE.info, facts.active == nil and "unknown" or facts.active)
						finish()
					end)
				end)
			end)
		end)
	end)
end

--- Key presses seen by Quartz against credits appended by the ledger.
function M.key_accounting(ports, report, finish)
	local before = ports.keystats_facts()
	ports.count_keys(M.KEY_ACCOUNTING_SECONDS, function(observed)
		local after = ports.keystats_facts()
		local presses = observed.presses or 0
		local ledger = math.max(0, (after.ledger_drained or 0) - (before.ledger_drained or 0))
		report.step("tap_running", observed.tap_running and STATE.pass or STATE.fail, yes_no(observed.tap_running))
		report.step("presses_seen", presses > 0 and STATE.pass or STATE.fail, presses)
		report.step("ledger_credits", STATE.info, ledger)
		report.step("source", STATE.info, after.credit_source)
		local verdict = "none"
		if after.credit_source ~= "legacy" then
			verdict = "stream_only"
		elseif ledger > 0 then
			verdict = "suspected"
		end
		report.step("double_count", STATE.info, verdict)
		finish()
	end)
end

local SCUTIL = "/usr/sbin/scutil"

--- Names the kinds of system proxy configured, from `scutil --proxy` text.
--- @param text any Command output.
--- @return string kinds Tokens joined by "+" (pac, discovery, fixed), or "none".
function M.parse_proxy_kinds(text)
	text = tostring(text or "")
	local kinds = {}
	if text:find("ProxyAutoConfigEnable%s*:%s*1") then kinds[#kinds + 1] = "pac" end
	if text:find("ProxyAutoDiscoveryEnable%s*:%s*1") then kinds[#kinds + 1] = "discovery" end
	if text:find("HTTPSEnable%s*:%s*1") or text:find("HTTPEnable%s*:%s*1") then kinds[#kinds + 1] = "fixed" end
	return #kinds > 0 and table.concat(kinds, "+") or "none"
end

--- Reads the `step <id> <state> <value>` lines of the native network helper.
--- The grammar is shared with the Linux and Windows checks.
--- @param output any Helper stdout.
--- @return table steps id → { state, value }
M.parse_network_helper = require("network.field_check_network").parse_chain_lines

--- The managed download chain end to end: system proxy settings, the PAC
--- download and verdict, then one HEAD request through the native transport.
--- The PAC address is only handed to the port that fetches it; no step carries it.
--- The steps are the shared ones (network.field_check_network); this function
--- binds them to scutil, the PAC fetch and the native helper.
function M.network(ports, report, finish)
	local PacCheck = require("network.pac_check")
	require("network.field_check_network").run({
		proxy_settings = function(callback)
			ports.exec(SCUTIL, { "--proxy" }, COMMAND_TIMEOUT, function(code, output)
				if code ~= 0 then
					callback({ failure = code == nil and "timeout" or "unreadable" })
				else
					callback({ kinds = M.parse_proxy_kinds(output), pac_url = PacCheck.url_from_scutil(output) })
				end
			end)
		end,
		fetch_pac = ports.fetch_pac,
		chain = function(callback)
			ports.network_chain(function(helper_code, helper_output)
				callback(helper_code, helper_code == 0 and M.parse_network_helper(helper_output) or {})
			end)
		end,
	}, report, finish)
end

local SHORTCUTS = "/usr/bin/shortcuts"
local CODESIGN = "/usr/bin/codesign"
local BREW_PATHS = { "/opt/homebrew/bin/brew", "/usr/local/bin/brew" }

-- A shortcut name no Mac can hold: running it must be refused at once, which
-- proves the real command line tool starts, answers and exits within its bound.
M.ABSENT_SHORTCUT = "ergopti-field-check-absent-shortcut"

-- Seconds a timer probe waits, and the lateness above which it is a failure.
M.TIMER_PROBE_SECONDS = 0.25
M.TIMER_LATE_MS = 250

-- Homebrew may need to update its index before answering.
local BREW_TIMEOUT = 20

--- Describes why a bounded command did not succeed, as a closed token.
--- @param code any Exit code, nil when it timed out.
--- @return string token "timeout" or "exit_<code>".
local function failure_token(code)
	return code == nil and "timeout" or "exit_" .. tostring(code)
end

--- The Apple Shortcuts command line tool, the Homebrew install of Karabiner and
--- the timer service, each isolated so that one failure names itself:
--- a timer that fires late, the Shortcuts tool listing, and refusing a missing
--- shortcut inside a bound (the same bound a cancelled invocation relies on),
--- then Homebrew itself, the Karabiner-Elements cask, and the code signature of
--- the installed app (package provenance). Read-only: nothing is installed,
--- run or changed.
function M.toolchain(ports, report, finish)
	local function brew_stage()
		local brew
		for _, candidate in ipairs(BREW_PATHS) do
			if ports.path_exists(candidate) then
				brew = candidate
				break
			end
		end
		report.step("brew_present", STATE.info, yes_no(brew ~= nil))
		local function signature_stage()
			if not ports.path_exists(STOCK_APP) then
				report.step("karabiner_signature", STATE.skip, "not_installed")
				finish()
				return
			end
			ports.exec(CODESIGN, { "--verify", "--deep", "--strict", STOCK_APP }, COMMAND_TIMEOUT, function(code)
				report.step("karabiner_signature", code == 0 and STATE.pass or STATE.fail,
					code == 0 and "valid" or failure_token(code))
				finish()
			end)
		end
		if not brew then
			report.step("brew_version", STATE.skip, "no_brew")
			report.step("karabiner_cask", STATE.skip, "no_brew")
			signature_stage()
			return
		end
		ports.exec(brew, { "--version" }, BREW_TIMEOUT, function(code, output)
			local version = code == 0 and M.parse_version(output) or nil
			report.step("brew_version", version and STATE.pass or STATE.fail, version or failure_token(code))
			ports.exec(brew, { "list", "--cask", "--versions", "karabiner-elements" }, BREW_TIMEOUT, function(list_code, list_output)
				local installed = list_code == 0 and count_lines(list_output) > 0
				-- A cask that is absent exits non-zero: that is an answer, not a fault
				local token = installed and "installed" or (list_code == nil and "timeout" or "absent")
				report.step("karabiner_cask", list_code == nil and STATE.fail or STATE.info, token)
				signature_stage()
			end)
		end)
	end

	local function shortcuts_stage()
		if not ports.path_exists(SHORTCUTS) then
			report.step("shortcuts_cli", STATE.fail, "no")
			report.step("shortcuts_list", STATE.skip, "no_cli")
			report.step("shortcuts_refusal", STATE.skip, "no_cli")
			brew_stage()
			return
		end
		report.step("shortcuts_cli", STATE.pass, "yes")
		ports.exec(SHORTCUTS, { "list" }, COMMAND_TIMEOUT, function(code, output)
			report.step("shortcuts_list", code == 0 and STATE.pass or STATE.fail,
				code == 0 and count_lines(output) or failure_token(code))
			ports.exec(SHORTCUTS, { "run", M.ABSENT_SHORTCUT }, COMMAND_TIMEOUT, function(run_code)
				local refused = run_code ~= nil and run_code ~= 0
				report.step("shortcuts_refusal", refused and STATE.pass or STATE.fail,
					refused and "refused" or (run_code == nil and "timeout" or "unexpected_success"))
				brew_stage()
			end)
		end)
	end

	ports.timer_probe(M.TIMER_PROBE_SECONDS, function(late_ms)
		report.step("timer_late_ms", late_ms <= M.TIMER_LATE_MS and STATE.pass or STATE.fail, math.max(0, math.floor(late_ms)))
		shortcuts_stage()
	end)
end





-- ===================================
-- ===================================
-- ======= 5/ Login items scan =======
-- ===================================
-- ===================================

local SFLTOOL = "/usr/bin/sfltool"
local GREP = "/usr/bin/grep"
local PLUTIL = "/usr/bin/plutil"
local ID_TOOL = "/usr/bin/id"

--- Entries a family lists one by one; the counts above them cover all.
M.LOGIN_ITEMS_LISTED = 3

-- The dump can be long on a Mac with many apps.
local BTM_TIMEOUT = 20

-- Longest identifier a listed entry carries, so that "<id>:other:off" fits the report grammar.
local LISTED_ID_LENGTH = 36

--- True when text names Ergopti or Hammerspoon.
--- @param text any Text.
--- @return boolean
local function mentions_ours(text)
	local lower = tostring(text or ""):lower()
	return lower:find("ergopti", 1, true) ~= nil or lower:find("hammerspoon", 1, true) ~= nil
end

--- Turns a `file://` address or a plain path into a path, undoing percent escapes.
--- @param value any Address or path.
--- @return string|nil path Absolute path, nil when there is none.
function M.decode_location(value)
	if type(value) ~= "string" then return nil end
	local path = value:gsub("^file://[^/]*", "")
	path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
	if path:sub(1, 1) ~= "/" then return nil end
	return path
end

--- Says whether a location belongs to the running application bundle.
--- @param location any Address or path of an entry.
--- @param app_path string|nil Path of the running application bundle.
--- @return string verdict "this", "other", or "unknown" when either side is not known.
function M.classify_copy(location, app_path)
	local path = M.decode_location(location)
	if not path or type(app_path) ~= "string" or app_path == "" then return "unknown" end
	local root = app_path:gsub("/+$", "")
	local trimmed = path:gsub("/+$", "")
	if trimmed == root or trimmed:sub(1, #root + 1) == root .. "/" then return "this" end
	return "other"
end

--- Reads the entries of `sfltool dumpbtm` that concern Ergopti or Hammerspoon.
---
--- Assumptions about the format (macOS 13 and later; written from knowledge of the
--- tool, not from a Mac in this session, and to be confirmed by the first real run):
--- * each user has a section headed `Records for UID <n>`;
--- * each entry starts with a line `#<n>:` and continues with `Key: value` lines;
--- * the keys used are `Name`, `Identifier` (often prefixed `<digit>.`), `URL`,
---   `Executable Path` and `Disposition`, a bracketed list that contains the word
---   `enabled` for an enabled entry.
--- An entry that does not match the assumptions is simply not listed; the check
--- then reports a count of zero rather than a guess.
--- @param output any Command output.
--- @param uid string|nil Current user id; other users' sections are ignored when given.
--- @return table entries { identifier, enabled (true, false or nil), location (string|nil) }.
function M.parse_btm(output, uid)
	local entries, current, section_ok = {}, nil, uid == nil
	local function close()
		if not current then return end
		local fields = current
		current = nil
		local text = (fields.name or "") .. " " .. (fields.identifier or "") .. " "
			.. (fields.url or "") .. " " .. (fields["executable path"] or "")
		if not mentions_ours(text) then return end
		local identifier = (fields.identifier or ""):gsub("^%d+%.", "")
		if identifier == "" then identifier = "unnamed" end
		local enabled
		if fields.disposition then
			enabled = fields.disposition:find("%f[%a]enabled%f[%A]") ~= nil
		end
		entries[#entries + 1] = {
			identifier = identifier,
			enabled = enabled,
			location = fields.url or fields["executable path"],
		}
	end
	for line in tostring(output or ""):gmatch("[^\r\n]+") do
		local section = line:match("Records for UID (%d+)")
		if section then
			close()
			section_ok = uid == nil or section == tostring(uid)
		elseif line:match("^%s*#%d+:%s*$") then
			close()
			if section_ok then current = {} end
		elseif current then
			local key, value = line:match("^%s*([%a ]+):%s*(.-)%s*$")
			if key then current[key:lower()] = value end
		end
	end
	close()
	return entries
end

--- Compacts one entry for a report value: `<identifier>:<this|other|unk>:<on|off|unk>`.
--- @param identifier string Bundle identifier or label.
--- @param verdict string Copy verdict.
--- @param enabled boolean|nil Whether the entry is enabled, nil when not known.
--- @return string value
local function listed_value(identifier, verdict, enabled)
	local state = enabled == nil and "unk" or (enabled and "on" or "off")
	local copy = verdict == "unknown" and "unk" or verdict
	return identifier:sub(1, LISTED_ID_LENGTH) .. ":" .. copy .. ":" .. state
end

--- Reports the counts of one family and lists its first entries.
--- @param report table Report.
--- @param prefix string Step prefix of the listed entries ("btm" or "agent").
--- @param counts string Step prefix of the counts ("btm" or "agents").
--- @param rows table Rows { identifier, verdict, enabled }.
local function report_family(report, prefix, counts, rows)
	local this_count, other_count = 0, 0
	for _, row in ipairs(rows) do
		if row.verdict == "this" then this_count = this_count + 1 end
		if row.verdict == "other" then other_count = other_count + 1 end
	end
	report.step(counts .. "_this_copy", STATE.info, this_count)
	report.step(counts .. "_other_copy", STATE.info, other_count)
	for index = 1, M.LOGIN_ITEMS_LISTED do
		local row = rows[index]
		if row then
			report.step(prefix .. "_item_" .. index, STATE.info, listed_value(row.identifier, row.verdict, row.enabled))
		end
	end
end

--- Applies `step` to each item in order, then `done`.
--- @param items table Array.
--- @param step function fn(item, next).
--- @param done function fn().
local function each_in_turn(items, step, done)
	local function run(index)
		if index > #items then return done() end
		step(items[index], function() run(index + 1) end)
	end
	run(1)
end

--- Trims a command output to one value.
--- @param text any Output.
--- @return string value
local function trimmed(text)
	return (tostring(text or ""):match("^%s*(.-)%s*$"))
end

--- Reads a launch agent's label and program with plutil.
--- @param ports table Ports.
--- @param file string Property list path (never reported).
--- @param callback function fn(label|nil, program|nil).
local function read_agent(ports, file, callback)
	ports.exec(PLUTIL, { "-extract", "Label", "raw", "-o", "-", "--", file }, COMMAND_TIMEOUT, function(code, label)
		local text = code == 0 and trimmed(label) or nil
		ports.exec(PLUTIL, { "-extract", "ProgramArguments.0", "raw", "-o", "-", "--", file }, COMMAND_TIMEOUT,
			function(args_code, program)
				if args_code == 0 then return callback(text, trimmed(program)) end
				ports.exec(PLUTIL, { "-extract", "Program", "raw", "-o", "-", "--", file }, COMMAND_TIMEOUT,
					function(program_code, plain)
						callback(text, program_code == 0 and trimmed(plain) or nil)
					end)
			end)
	end)
end

--- Finds the launch agent files that mention Ergopti or Hammerspoon.
--- @param ports table Ports.
--- @param callback function fn(files) with the paths found; never reported.
local function find_agent_files(ports, callback)
	local home = ports.home()
	local directories = { "/Library/LaunchAgents" }
	if home then table.insert(directories, 1, home .. "/Library/LaunchAgents") end
	local files = {}
	each_in_turn(directories, function(directory, next_directory)
		if not ports.path_exists(directory) then return next_directory() end
		ports.exec(GREP, { "-rlisaE", "--", "ergopti|hammerspoon", directory }, COMMAND_TIMEOUT, function(code, output)
			if code == 0 then
				for file in tostring(output):gmatch("[^\r\n]+") do files[#files + 1] = file end
			end
			next_directory()
		end)
	end, function() callback(files) end)
end

--- What starts Ergopti or Hammerspoon at login. Read-only: nothing is removed,
--- written or unregistered. It names states, bundle identifiers and labels, and
--- counts entries as belonging to the running copy or to another one.
function M.login_items(ports, report, finish)
	local app_path = ports.app_path()
	report.step("this_copy_known", STATE.info, yes_no(app_path ~= nil))

	local function agents_stage()
		find_agent_files(ports, function(files)
			local rows = {}
			each_in_turn(files, function(file, next_file)
				read_agent(ports, file, function(label, program)
					rows[#rows + 1] = {
						identifier = (label and label ~= "") and label or "unnamed",
						verdict = M.classify_copy(program, app_path),
					}
					next_file()
				end)
			end, function()
				report_family(report, "agent", "agents", rows)
				finish()
			end)
		end)
	end

	local function btm_stage()
		if not ports.path_exists(SFLTOOL) then
			report.step("btm_state", STATE.skip, "no_tool")
			return agents_stage()
		end
		ports.exec(ID_TOOL, { "-u" }, COMMAND_TIMEOUT, function(id_code, id_output)
			local uid = id_code == 0 and tostring(id_output):match("^%s*(%d+)%s*$") or nil
			ports.exec(SFLTOOL, { "dumpbtm" }, BTM_TIMEOUT, function(code, output)
				if code ~= 0 then
					report.step("btm_state", STATE.info, code == nil and "timeout" or "unreadable")
					return agents_stage()
				end
				local rows = {}
				for _, entry in ipairs(M.parse_btm(output, uid)) do
					rows[#rows + 1] = {
						identifier = entry.identifier,
						enabled = entry.enabled,
						verdict = M.classify_copy(entry.location, app_path),
					}
				end
				report.step("btm_state", STATE.info, uid and "readable" or "readable_all_users")
				report_family(report, "btm", "btm", rows)
				agents_stage()
			end)
		end)
	end

	ports.login_startup_status(function(state)
		report.step("main_app_login_item", STATE.info, state or "unreadable")
		btm_stage()
	end)
end

--- The composed layout: installs the shipped check composition through the
--- composer's real path, verifies it, asks the system whether it is enabled and
--- removes it again (a user's own composition is only read). The steps are the
--- shared ones (_shared/lua/layouts/composer_check.lua).
function M.composer(ports, report, finish)
	local env = ports.composer_env()
	if not env then
		report.step("composer_fixture", STATE.fail, "unusable")
		finish()
		return
	end
	require("layouts.composer_check").run(env, report, finish)
end

--- Check identity → definition(ports, report, finish), as run by infra.field_check.
M.checks = {
	network = M.network,
	lease = M.lease,
	owned_runtime = M.owned_runtime,
	key_accounting = M.key_accounting,
	toolchain = M.toolchain,
	login_items = M.login_items,
	composer = M.composer,
}

return M
