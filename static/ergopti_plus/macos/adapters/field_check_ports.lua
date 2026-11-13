--- adapters/field_check_ports.lua

--- ==============================================================================
--- MODULE: Field Check Ports (Hammerspoon)
--- DESCRIPTION:
--- The real Mac side of infra/field_check.lua: file existence, bounded external
--- commands, the driver facts the checks read (remap, keystats, key event
--- health) and a short passive key counter.
---
--- FEATURES & RATIONALE:
--- 1. Bounded commands: every command settles exactly once, with its exit code,
---    or with nil when it timed out or could not start. A timed-out child is
---    terminated.
--- 2. Counting tap: the key counter is a passive hs.eventtap that returns false
---    for every event and keeps one integer. It never reads a key code, a
---    character or a flag, and it does not count autorepeat.
--- 3. Read-only facts: remap, keystats and health data are read through their
---    public getters; nothing here changes driver state.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local ShellRunner = require("adapters.shell_runner")
local Timer = require("core.events.timer_scheduler")
local FileSystem = require("core.fs.adapters.file_system")
local NativePath = require("core.fs.engine.native_path")

local LOG = "adapters.field_check_ports"





-- ===========================
-- ===========================
-- ======= 1/ Commands =======
-- ===========================
-- ===========================

--- Runs one executable and settles once.
--- @param executable string Absolute path.
--- @param args table Argument array.
--- @param timeout_s number Seconds before the child is terminated.
--- @param callback function fn(exit_code|nil, stdout, stderr).
--- @param environment table|nil Explicit child environment (the launcher's identity).
local function exec(executable, args, timeout_s, callback, environment)
	local settled, timer, handle = false, nil, nil
	local retiring = false
	local function settle(code, stdout, stderr)
		if settled then return end
		settled = true
		if timer then Timer.cancel(timer) end
		callback(code, stdout, stderr or "")
	end
	handle = ShellRunner.spawn(executable, args, function(code, stdout, stderr)
		if not retiring then settle(code, stdout, stderr) end
	end, nil, environment)
	local function retire(reason)
		if retiring or settled then return end
		retiring = true
		local observer_ok, observed = pcall(handle.onSettled, function() settle(nil, "", reason) end)
		if not observer_ok or observed ~= true then
			Logger.error(LOG, "Could not observe the child after %s.", reason)
		end
		if settled then return end
		local terminated, accepted = pcall(handle.terminate)
		if not terminated or accepted ~= true then Logger.error(LOG, "Could not terminate the child after %s.", reason) end
	end
	if handle.isSettled() then
		Logger.warn(LOG, "Could not start %s.", NativePath.basename(executable) or "a command")
		settle(nil, "")
		return
	end
	if not handle.start() then
		Logger.warn(LOG, "Could not start %s.", NativePath.basename(executable) or "a command")
		if handle.isSettled() then settle(nil, "") else retire("start refused") end
		return
	end
	if settled then return end
	local timer_committed
	timer, timer_committed = Timer.after(timeout_s, function()
		timer = nil
		retire("deadline expired")
	end)
	if settled then
		if timer then Timer.cancel(timer); timer = nil end
		return
	end
	if timer_committed ~= true then
		-- The task was already started. A refused deadline is not permission to
		-- abandon it or report completion before the exact process is retired.
		retire("deadline unavailable")
	end
end





-- ============================
-- ============================
-- ======= 2/ Key count =======
-- ============================
-- ============================

--- Counts key-down events for a while, without reading what they are.
--- @param seconds number Watch duration.
--- @param callback function fn({ tap_running = boolean, presses = integer }).
local function count_keys(seconds, callback)
	local presses = 0
	local property = hs.eventtap.event.properties.keyboardEventAutorepeat
	local tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
		local ok, repeated = pcall(event.getProperty, event, property)
		if not (ok and repeated ~= nil and repeated ~= 0) then presses = presses + 1 end
		return false
	end)
	local started = tap:start()
	local running = started ~= nil and tap:isEnabled() == true
	Timer.after(seconds, function()
		tap:stop()
		callback({ tap_running = running, presses = presses })
	end)
end





-- ========================
-- ========================
-- ======= 3/ Facts =======
-- ========================
-- ========================

--- Remap facts, read from memory.
local function remap_facts()
	local Remap = require("platform.remap")
	local phase = "unknown"
	local ok, current = pcall(function() return (require("platform.remap.lease_controller").status()) end)
	if ok and type(current) == "string" then phase = current end
	local KePaths = require("platform.remap.ke_paths")
	-- Nil for the shared runtime; for the owned one, whether its owner admitted it
	local owned_admitted = nil
	if KePaths.selected_runtime() == KePaths.RUNTIME_OWNED then
		local status = type(Remap.owned_runtime_status) == "function" and Remap.owned_runtime_status() or nil
		owned_admitted = type(status) == "table" and status.state == "ready"
	end
	return { enabled = Remap.get_enabled(), phase = phase, guardian = Remap.guardian_state(),
		owned_admitted = owned_admitted }
end

--- The deployed Karabiner configuration and the tap-hold delays the shared
--- model asks for, for infra/field_check_tap_hold_thresholds.lua.
--- @return table facts { enabled, config, reason, expected, tag }.
local function tap_hold_threshold_facts()
	local Remap = require("platform.remap")
	local KePaths = require("platform.remap.ke_paths")
	local facts = { enabled = Remap.get_enabled() == true, expected = {},
		tag = require("platform.remap.lease_contract").MANAGED_TAG_LABEL }
	local global = Remap.get_tap_hold_timeout()
	-- A modifier key pressed alone may tap for longer than its delay (the lone
	-- tap window): the generator says what it gave each key.
	local deployed = require("platform.remap.generator").last_tap_timeouts() or {}
	for _, key in ipairs(Remap.TAP_HOLD_KEYS or {}) do
		local key_code = type(key.from) == "table" and key.from.key_code
		if type(key_code) == "string" then
			local own = Remap.get_tap_timeout(key.id)
			facts.expected[key_code] = { id = key.id, ms = deployed[key.id] or ((own and own > 0) and own or global) }
		end
	end
	local runtime = KePaths.selected_runtime()
	-- The owned runtime deploys nothing before its owner admits it: its folder
	-- does not exist yet, and reading through it logged an error and failed the
	-- thresholds for a runtime the owned_* steps already report (field report 2026-11-06).
	if runtime == KePaths.RUNTIME_OWNED then
		local status = type(Remap.owned_runtime_status) == "function" and Remap.owned_runtime_status() or nil
		if type(status) ~= "table" or status.state ~= "ready" then
			facts.reason = "owned_runtime_not_ready"
			return facts
		end
	end
	local path = FileSystem.expand_path(KePaths.config_file_for(runtime))
	if FileSystem.exists(path) ~= true then
		facts.reason = "not_deployed"
		return facts
	end
	local text = FileSystem.read(path)
	if type(text) ~= "string" then
		facts.reason = "unreadable"
		return facts
	end
	local decoded = require("core.fs.adapters.json_codec").decode(text)
	if type(decoded) ~= "table" then
		facts.reason = "not_json"
		return facts
	end
	facts.config = decoded
	return facts
end

--- What the tap-hold copy check needs, for infra/field_check_tap_copy.lua: the
--- lone tap window, each key whose tap is copy with the tap timeout Karabiner
--- was given, the pasteboard counter now, and the copy watch statistics.
--- @return table facts
local function tap_copy_facts()
	local Remap = require("platform.remap")
	local deployed = require("platform.remap.generator").last_tap_timeouts() or {}
	local rollover = require("platform.remap.defaults").rollover_keys
	local facts = { window_ms = Remap.get_lone_modifier_tap_max_ms(), keys = {}, deployed = next(deployed) ~= nil,
		change_count = (require("adapters.clipboard")._change_count()),
		stats = require("modules.keymap").tap_copy_statistics() }
	for _, key in ipairs(Remap.TAP_HOLD_KEYS or {}) do
		if Remap.get_tap_action(key.id) == "copy" then
			facts.keys[#facts.keys + 1] = { id = key.id, deployed_ms = deployed[key.id],
				eligible = not rollover[key.id] and Remap.get_hold_action(key.id) ~= "none" }
		end
	end
	return facts
end

--- The note and status of this lifecycle's guardian registration, read from memory.
--- @return string|nil note `developer_adhoc_*`, or nil when no reset ran.
--- @return string|nil status The registration's answer, nil before it settled.
local function guardian_registration_note()
	local ok, note, status = pcall(function()
		return require("platform.remap.lease_controller").guardian_registration_note()
	end)
	if not ok then return nil, nil end
	return note, status
end

--- Keystats facts, read from memory.
local function keystats_facts()
	local Accounting = require("modules.keystats.physical_accounting_mode")
	local stats = require("modules.keystats.kc_bridge").get_stats()
	return {
		credit_source = Accounting.credit_source(),
		capture_loaded = package.loaded["modules.keystats.physical_capture"] ~= nil,
		ledger_drained = stats.drained_total,
	}
end

--- Downloads the PAC the way the diagnostics probe does; the address is never logged.
--- @param url string PAC address from the system proxy settings.
--- The step tokens stay fixed, so a transport failure's reason is logged here:
--- it is the only clue a field report carries (issue #104).
--- @param callback function fn(status|nil, body|nil).
local function fetch_pac(url, callback)
	local client = require("adapters.http_client").new({ timeout_ms = 6000 })
	client.get(url, {}, function(result)
		if (tonumber(result.status) or 0) == 0 then
			-- The transport's error text ends with the request URL: the company PAC
			-- address reached the field report of 2026-10-27 19:47 through it.
			local reason = tostring(result.error):gsub("%s*%-?%s*%a[%w+.-]*://%S*", ""):gsub("[%s.]+$", "")
			Logger.warn(LOG, "PAC download failed: %s.", reason)
		end
		callback(result.status, result.body)
	end)
end

--- Runs the native network helper (one HEAD through the managed transport).
--- @param callback function fn(exit_code|nil, stdout); nil when it cannot start.
--- @param mode string|table|nil "--hosts" for one HEAD per declared host, or
---   the argument list of another mode ({ "--ollama-blob", model }).
--- @param timeout_s number|nil Seconds before the helper is terminated.
local function network_chain(callback, mode, timeout_s)
	local python = require("adapters.python_interpreter").resolve()
	local source = debug.getinfo(1, "S").source or ""
	local root = (source:sub(1, 1) == "@" and source:sub(2) or source):match("^(.*)/adapters/field_check_ports%.lua$")
	if not python or not root then
		Logger.warn(LOG, "Network helper unavailable: %s.", python and "no driver root" or "no native Python")
		callback(nil, "")
		return
	end
	local args = { "-B", root .. "/modules/llm/managed_network_check.py" }
	for _, argument in ipairs(type(mode) == "table" and mode or { mode }) do args[#args + 1] = argument end
	exec(python, args, timeout_s or 40, callback)
end


--- The route the system settings name for each origin of the managed Ollama daemon,
--- looked up one after the other through the launcher's route command, the lookup the
--- daemon's own start performs (network-retry.sh).
--- @param callback function fn({ entries = {{ origin, route }} } | { failure = token }).
local function route_plan(callback)
	local NetworkEnv = require("modules.llm.network_env")
	local origins = NetworkEnv.route_origins("ollama")
	local budget = NetworkEnv.route_lookup_budget_seconds()
	local launcher, _, environment = require("platform.remap.lease_helper").resolve()
	if not origins or not budget then return callback({ failure = "route-origins-unavailable" }) end
	if not launcher then return callback({ failure = "launcher_unavailable" }) end
	local entries = {}
	local function dispatch(index)
		exec(launcher, { "--managed-proxy-route", origins[index], tostring(budget) }, budget + 5, function(code, output, errors)
			local route = code == 0 and tostring(output):match("ROUTE ([^\r\n]+)") or nil
			if not route then
				-- The role writes its STAGE line on stderr (ManagedProxyRouteWorker):
				-- reading stdout lost every stage, so the PAC fallback never applied.
				local stage = tostring(errors):match("STAGE (native_[a-z_]+)")
				return callback({ failure = stage or "lookup_failed" })
			end
			entries[index] = { origin = origins[index], route = route }
			if index == #origins then callback({ entries = entries }) else dispatch(index + 1) end
		end, environment)
	end
	dispatch(1)
end

--- The installed relay beside the launcher in the application bundle; nil in a
--- source checkout, or a bundle built before the relay shipped.
--- @return string|nil path
local function relay_executable()
	local launcher = require("platform.remap.lease_helper").resolve()
	if not launcher then return nil end
	local path = NativePath.dirname(launcher) .. "/" .. require("core.network.engine.proxy_auth_relay_core").EXECUTABLE_NAME
	return FileSystem.exists(path) and path or nil
end

--- Probes the relay the route plan selected for the registry, as the daemon's
--- start would (docs/design/proxy-auth-relay.md). The answer is the shared
--- policy's: not needed, required with its scheme, or a closed refusal.
--- @param upstream string Plain http relay (policy.upstream()).
--- @param callback function fn(answer|nil, reason|nil).
local function relay_probe(upstream, callback)
	local NetworkEnv = require("modules.llm.network_env")
	local policy = NetworkEnv.proxy_auth_relay()
	local origins = NetworkEnv.route_origins("ollama")
	if not policy or not origins then return callback(nil, "relay_unavailable") end
	local executable = relay_executable()
	if not executable then return callback({ status = require("core.network.engine.proxy_auth_relay_core").NOT_INSTALLED }) end
	local Timings = require("infra.timings")
	local args = policy.probe_args(upstream, policy.authority(origins[1]), {
		dial_ms = Timings.ms("adapters", "proxy_relay_dial_timeout_ms"),
		handshake_ms = Timings.ms("adapters", "proxy_relay_handshake_timeout_ms"),
	})
	if not args then return callback(nil, "relay_unavailable") end
	exec(executable, args, Timings.sec("adapters", "proxy_relay_probe_timeout_ms"), function(code, output)
		callback(policy.read_probe(code, output))
	end)
end

--- Measures how late the timer service fires, and names the long phases that
--- ran while it waited: what held the run loop when the probe came late.
--- @param seconds number Delay asked of the timer.
--- @param callback function fn(late_ms, phases) with the lateness in
---   milliseconds and `name=12.3 ms, …` (longest first), or nil when none ran.
local function timer_probe(seconds, callback)
	local PhaseStats = require("infra.phase_stats")
	local started = hs.timer.secondsSinceEpoch()
	local started_ns = PhaseStats.now()
	Timer.after(seconds, function()
		callback((hs.timer.secondsSinceEpoch() - started - seconds) * 1000, PhaseStats.recent_since(started_ns))
	end)
end

--- Path of the running application bundle, or nil when the driver does not run
--- from a bundled application (a source checkout).
--- @return string|nil path
local function app_path()
	local launcher = require("platform.remap.lease_helper").resolve()
	if not launcher then return nil end
	return (launcher:gsub("/Contents/MacOS/ErgoptiPlus$", ""))
end

--- Reads the login item state of the application from its own launcher, which is
--- the only process that may query it (the same read-only role the menu uses).
--- @param callback function fn(state|nil) with enabled, disabled, approval or unavailable.
local function login_startup_status(callback)
	local launcher, _, environment = require("platform.remap.lease_helper").resolve()
	if not launcher then return callback(nil) end
	exec(launcher, { "--login-startup", "status" }, 5, function(code, output)
		local state = code == 0 and tostring(output):match("^(%a+)%s*$") or nil
		if state ~= "enabled" and state ~= "disabled" and state ~= "approval" and state ~= "unavailable" then
			state = nil
		end
		callback(state)
	end, environment)
end

--- Reads the Input Monitoring grant through the launcher's IOHIDCheckAccess
--- role, which never prompts (ledger L32).
--- @param callback function fn("granted"|"denied"|"unknown"|nil); nil when unreadable.
local function input_monitoring_access(callback)
	local launcher, _, environment = require("platform.remap.lease_helper").resolve()
	if not launcher then return callback(nil) end
	exec(launcher, { "--input-monitoring", "status" }, 5, function(code, output)
		local state = code == 0 and tostring(output):match("^(%a+)%s*$") or nil
		if state ~= "granted" and state ~= "denied" and state ~= "unknown" then state = nil end
		callback(state)
	end, environment)
end

--- Facts about the pieces of the owned runtime that are not installed yet:
--- whether the artifact manifest is pinned and which driver version it names,
--- whether the installed-source module can be reached (it is loaded, never
--- acquired), and what a close of the official Karabiner would meet. Nothing is started, closed or changed.
--- @param callback function fn({ unpinned = integer|nil, source = boolean, helper_present = boolean,
---   active = integer|nil, virtual_hid_version = string|nil }).
local function owned_readiness(callback)
	local source_available = require("adapters.installed_physical_source").new().available()
	require("adapters.karabiner_coexistence").new().describe(function(facts)
		local OwnerPorts = require("adapters.runtime_owner_ports")
		local readiness = {
			unpinned = OwnerPorts.unpinned_count(),
			virtual_hid_version = OwnerPorts.virtual_hid_extension_version(),
			artifact = OwnerPorts.artifact_receipt_state(),
			source = source_available == true,
			helper_present = facts.helper_present,
			active = facts.active_processes,
		}
		-- The install role refuses an ad hoc launcher (launcher_unsigned): the
		-- helper must carry this launcher's own certificate leaf.
		local launcher = require("platform.remap.lease_helper").resolve()
		local bundle = type(launcher) == "string" and launcher:match("^(.-%.app)/Contents/") or nil
		if not bundle then
			readiness.launcher_identity = "no_launcher"
			return callback(readiness)
		end
		exec("/usr/bin/codesign", { "-dv", "--verbose=2", bundle }, 5, function(code, output, errors)
			local identity = require("infra.field_check_probes").parse_signing_identity(
				tostring(output or "") .. "\n" .. tostring(errors or ""))
			readiness.launcher_identity = (code == 0 or identity == "unsigned") and identity
				or (code == nil and "timeout" or ("exit_" .. tostring(code)))
			callback(readiness)
		end)
	end)
end

--- The owned runtime's activation rule, driven by the field run
--- (infra/field_check_owned_activation.lua): the pause it takes, the owner's
--- state and the user Karabiner it may close and give back.
--- @return table port
local function owned_activation()
	-- Resolved per call: building the ports must not load the remap bridge.
	local function Remap() return require("platform.remap") end
	local function owner_status()
		local owner = Remap()._owned and Remap()._owned.owner
		if not owner then return { state = "unbound" } end
		return owner.status()
	end
	return {
		selected = function()
			return type(Remap().owned_runtime_selected) == "function" and Remap().owned_runtime_selected() == true
		end,
		paused = function() return require("modules.shortcuts.script_control").is_paused() == true end,
		-- The same transactional pause and resume as the pause key.
		pause = function() return require("modules.shortcuts.script_control").pause_all() end,
		resume = function() return require("modules.shortcuts.script_control").resume_all() end,
		owner_state = function() return owner_status().state end,
		owner_reason = function() return owner_status().reason end,
		fetch = function(callback) require("adapters.runtime_owner_ports").fetch_artifact(callback) end,
		other_active = function(callback) require("adapters.karabiner_coexistence").new().detect(callback) end,
		marker = function() return require("adapters.runtime_owner_ports").marker().get() end,
		-- The first install with no confirmation dialog: the field run is the request.
		install_reasons = function() return Remap().OWNED_INSTALL_REASONS end,
		install = function(callback)
			if Remap().install_owned_runtime(callback) ~= true then callback(false, "install_not_offered") end
		end,
		driver_active = function(callback)
			exec("/usr/bin/systemextensionsctl", { "list" }, 5, function(code, output)
				local version = require("adapters.runtime_owner_ports").virtual_hid_extension_version()
				if code ~= 0 or type(version) ~= "string" then return callback(nil) end
				local Vhid = require("platform.remap.runtime_vhid")
				callback(Vhid.assess(Vhid.parse(output), version).ok == true)
			end)
		end,
		open_driver_pane = function()
			return hs.urlevent.openURL(require("platform.remap.ke_paths").EXTENSIONS_SETTINGS_URL)
		end,
	}
end

--- The bounded command runner, shared with adapters/runtime_owner_ports.lua.
M.exec = exec

--- The ports of the real Mac.
--- @return table ports
--- The catalogue's smallest model for a backend, an installed one first; the
--- field run's AI steps and the blob host check pick the same model.
--- @param backend string "ollama" or "mlx".
--- @param installed function|nil fn(model) -> boolean.
--- @return table|nil model { name, runtime_name, download_gb }
function M.smallest_model(backend, installed)
	local path = require("core.fs.engine.paths").shared_llm_path("models.json")
	-- Resolved per call: the field run's ports and these share the caller's adapters.
	local text = path and require("core.fs.adapters.file_system").read(path) or nil
	if type(text) ~= "string" then return nil end
	return require("infra.field_run").smallest_model(require("core.text.engine.json").decode(text), backend, installed)
end

function M.new()
	local ports = {
		path_exists = FileSystem.exists,
		exec = exec,
		home = function() return os.getenv("HOME") end,
		remap_facts = remap_facts,
		tap_hold_threshold_facts = tap_hold_threshold_facts,
		tap_copy_facts = tap_copy_facts,
		guardian_registration_note = guardian_registration_note,
		keystats_facts = keystats_facts,
		health_counts = function() return require("core.logger.engine.key_event_health").counts() end,
		swallowed_keys = function() return require("core.logger.engine.keystroke_integrity").drop_count() end,
		deploy_facts = function() return require("platform.remap.generator").last_deploy() end,
		count_keys = count_keys,
		fetch_pac = fetch_pac,
		network_chain = function(callback) return network_chain(callback) end,
		-- Five hosts of at most 15 s each, one after the other
		host_heads = function(callback) return network_chain(callback, "--hosts", 100) end,
		-- A manifest GET and one blob HEAD of at most 15 s each
		blob_host = function(model, callback) return network_chain(callback, { "--ollama-blob", model }, 40) end,
		smallest_ollama_model = function() return M.smallest_model("ollama") end,
		route_plan = route_plan,
		relay_probe = relay_probe,
		relay_policy = function() return require("modules.llm.network_env").proxy_auth_relay() end,
		timer_probe = timer_probe,
		after = function(seconds, callback)
			local _, committed = Timer.after(seconds, callback)
			if committed ~= true then error("field check: the wait timer could not be armed", 0) end
		end,
		owned_readiness = owned_readiness,
		owned_activation = owned_activation(),
		-- Work that must wait until the field run has written its results.
		after_run = function(work) return require("infra.field_run").after_run(work) end,
		app_path = app_path,
		login_startup_status = login_startup_status,
		input_monitoring_access = input_monitoring_access,
		composer_env = function() return (require("modules.keymap.composer_check").env()) end,
	}
	-- The field run's own checks (infra/field_check_probes.lua) read more facts
	for name, port in pairs(require("adapters.field_probe_ports").new()) do
		if ports[name] ~= nil then error("field check ports: duplicate port " .. name, 2) end
		ports[name] = port
	end
	return ports
end

return M
