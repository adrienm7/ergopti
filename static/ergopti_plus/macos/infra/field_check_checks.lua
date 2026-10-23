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
					finish()
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

-- Steps the native helper may report, in display order, and the states it may use.
local NETWORK_STEPS = { "route_lookup", "tls", "transfer", "digest" }
local NETWORK_STATES = { pass = true, fail = true, info = true, skip = true }

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
--- Unknown ids, states and repeated ids are ignored: the helper cannot add a step.
--- @param output any Helper stdout.
--- @return table steps id → { state, value }
function M.parse_network_helper(output)
	local wanted, steps = {}, {}
	for _, id in ipairs(NETWORK_STEPS) do wanted[id] = true end
	for id, state, value in tostring(output or ""):gmatch("step (%S+) (%S+) (%S+)") do
		if wanted[id] and NETWORK_STATES[state] and not steps[id] then
			steps[id] = { state = state, value = value }
		end
	end
	return steps
end

--- The managed download chain end to end: system proxy settings, the PAC
--- download and verdict, then one HEAD request through the native transport.
--- The PAC address is only handed to the port that fetches it; no step carries it.
function M.network(ports, report, finish)
	local PacCheck = require("network.pac_check")
	ports.exec(SCUTIL, { "--proxy" }, COMMAND_TIMEOUT, function(code, output)
		if code ~= 0 then
			report.step("proxy_settings", STATE.fail, code == nil and "timeout" or "unreadable")
		else
			report.step("proxy_settings", STATE.info, M.parse_proxy_kinds(output))
		end
		local function native_chain()
			ports.network_chain(function(helper_code, helper_output)
				local steps = helper_code == 0 and M.parse_network_helper(helper_output) or {}
				for _, id in ipairs(NETWORK_STEPS) do
					local step = steps[id]
					if step then
						report.step(id, step.state, step.value)
					elseif id == "transfer" then
						report.step(id, STATE.fail, helper_code == nil and "helper_unavailable" or "no_answer")
					else
						report.step(id, STATE.skip, helper_code == nil and "helper_unavailable" or "no_answer")
					end
				end
				finish()
			end)
		end
		local url = code == 0 and PacCheck.url_from_scutil(output) or nil
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

--- Check identity → definition(ports, report, finish), as run by infra.field_check.
M.checks = {
	network = M.network,
	lease = M.lease,
	owned_runtime = M.owned_runtime,
	key_accounting = M.key_accounting,
	toolchain = M.toolchain,
}

return M
