--- ui/healthcheck/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Diagnostics Window (Linux)
--- DESCRIPTION:
--- Serves the shared diagnostics page (_shared/ui/healthcheck/): the version 2
--- snapshot of _shared/modules/diagnostics/schema.json, the asynchronous
--- probes that complete it, and the actions the page asks for (copy, save,
--- report on GitHub, open a folder, refresh, close).
--- Bridge name: "healthcheck"
---
--- FEATURES & RATIONALE:
--- 1. One collector per section, each isolated: a report exists to be read
---    when things are broken, so one collector raising costs its own section,
---    never the window. Phase A reads /proc, /sys and daemon memory only.
--- 2. The probes (api.github.com, the AI backend, kanata and df) run as curl
---    and child processes owned by libuv; their answers are pushed into the
---    page only while the page they were started for is still open.
--- 3. Every page message is validated by healthcheck.actions before anything
---    happens: the host opens only the paths it collected, by field id.
--- 4. Values that cannot be read stay absent (the page shows "unknown"): a
---    fabricated zero is indistinguishable from a measured one.
--- ==============================================================================

local M = {}
M.bridge_name = "healthcheck"

local Logger = require("logger.shim")
local LOG = "bridge.healthcheck"

local Version = require("infra.version")
local Snapshot = require("healthcheck.snapshot")
local Actions = require("healthcheck.actions")
local LoggerSink = require("infra.logger_sink")

M.DRIVER = "linux"

-- When the daemon started, in seconds. Captured at load rather than read from
-- the process table: /proc/self/stat gives jiffies since boot, which needs the
-- clock tick and the boot time to become an age, and both can be wrong in a
-- container.
local _started_at = os.time()

-- The daemon parts the developer section checks. The required ones run in
-- every daemon. The optional ones are loaded by every daemon too, through
-- RuntimeGuard.optional_require, but the user can switch them off: switched
-- off is a neutral "disabled"; absent means the module failed to load (logged
-- by the guard), which is a failure.
local REQUIRED_PARTS = { "engine", "keylogger", "config" }
local OPTIONAL_PARTS = { "llm" }

-- The evdev bus numbers of /proc/bus/input/devices, as schema buses
local BUSES = { ["0003"] = "usb", ["0005"] = "bluetooth", ["0011"] = "internal", ["0018"] = "internal",
	["0019"] = "internal" }

-- The documents of the diagnostics window, loaded once
local _config = nil

-- The state of the window's current page: its epoch, whether details are
-- included, its last snapshot and its running probes
local _session = nil





-- ================================
-- ================================
-- ======= 1/ Configuration =======
-- ================================
-- ================================

--- The schema, the issue forms, the redaction rules and the repository,
--- loaded once: they are files of the shared tree, not settings.
--- @return table
function M.config()
	if not _config then
		_config = Snapshot.load_config(function(rel) return require("infra.paths").shared(rel) end)
	end
	return _config
end





-- =============================
-- =============================
-- ======= 2/ Collectors =======
-- =============================
-- =============================

--- Runs a collector, isolating a failure to its own section.
--- @param name string Section name, for the log line.
--- @param fn function
--- @return table
local function collect(name, fn)
	local ok, value = pcall(fn)
	if not ok then
		Logger.error(LOG, "Diagnostics collector '%s' raised: %s — section left empty.", name, tostring(value))
		return {}
	end
	return value
end

--- Reads a small file, nil when it cannot be read.
--- @param path string
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- The folder part of a path.
--- @param path string|nil
--- @return string|nil
local function dirname(path)
	if type(path) ~= "string" then return nil end
	return path:match("^(.*)/[^/]*$")
end

--- The folders and files the page lists and opens by id.
--- @param schema table
--- @return table
local function collect_paths(schema)
	local logs_dir = LoggerSink.log_dir()
	if logs_dir == "" then logs_dir = nil end
	return {
		config_dir      = require("infra.config_paths").get_config_dir(),
		logs_dir        = logs_dir,
		log_today       = LoggerSink.main_log_path(),
		errors_today    = LoggerSink.errors_log_path(),
		crash_dir       = require("modules.diagnostics.crash_reporter").get_crash_dir(),
		diagnostics_dir = logs_dir and (logs_dir .. "/" .. schema.report.subdir) or nil,
		app_dir         = require("infra.paths").driver_root(),
	}
end

--- The installed WebKitGTK version, when GTK is loaded in this process.
--- @return string|nil
local function webkit_version()
	local ok, lgi = pcall(require, "lgi")
	if not ok then return nil end
	local ok_version, version = pcall(function()
		local WebKit = lgi.WebKit2
		return string.format("WebKitGTK %d.%d.%d", WebKit.get_major_version(), WebKit.get_minor_version(),
			WebKit.get_micro_version())
	end)
	return ok_version and version or nil
end

--- The versions a bug report is triaged by.
--- @param facts table system_facts()
--- @return table
local function collect_versions(facts)
	local commit, source = require("infra.diagnostic_snapshot").resolve_commit()
	local ok_updater, Updater = pcall(require, "modules.updater.manager")
	return {
		ergopti_version = Version.VERSION,
		commit          = commit .. " (" .. source .. ")",
		channel         = ok_updater and Updater.get_channel() or nil,
		runtime         = facts.runtime,
		webview         = webkit_version(),
	}
end

--- The machine model, from the firmware tables (never a serial number).
--- @return string|nil
local function machine_model()
	local vendor = read_file("/sys/class/dmi/id/sys_vendor")
	local product = read_file("/sys/class/dmi/id/product_name")
	local text = ((vendor or "") .. " " .. (product or "")):gsub("%s+", " "):match("^%s*(.-)%s*$")
	return text ~= "" and text or nil
end

--- The displays GTK knows, when GTK is loaded in this process.
--- @return table|nil
local function displays()
	local ok, lgi = pcall(require, "lgi")
	if not ok then return nil end
	local ok_list, list = pcall(function()
		local Gdk = lgi.Gdk
		local display = Gdk.Display.get_default()
		if not display then return nil end
		local out = {}
		for index = 0, display:get_n_monitors() - 1 do
			local monitor = display:get_monitor(index)
			local geometry = monitor:get_geometry()
			local scale = monitor:get_scale_factor()
			local text = string.format("%d×%d @%dx", geometry.width * scale, geometry.height * scale, scale)
			if monitor:is_primary() then text = text .. " (main)" end
			out[#out + 1] = text
		end
		return out
	end)
	return ok_list and list or nil
end

--- The hardware section.
--- @param facts table system_facts()
--- @return table
local function collect_hardware(facts)
	return {
		model     = machine_model(),
		cpu       = facts.cpu_model,
		cpu_cores = facts.cpu_cores,
		arch      = facts.arch,
		ram_total = facts.ram_total,
		displays  = displays(),
	}
end

--- Whether the daemon runs with an effective uid of 0.
--- @param status string|nil Content of /proc/self/status.
--- @return boolean|nil
local function elevated(status)
	local _, effective = (status or ""):match("\nUid:%s+(%d+)%s+(%d+)")
	if not effective then return nil end
	return effective == "0"
end

--- The daemon's resident memory, in bytes.
--- @param status string|nil Content of /proc/self/status.
--- @return number|nil
local function process_memory(status)
	local kib = (status or ""):match("\nVmRSS:%s+(%d+) kB")
	return kib and tonumber(kib) * 1024 or nil
end

--- The system section and its load.
--- @param facts table system_facts()
--- @param state table Daemon state.
--- @return table
local function collect_system(facts, state)
	local layout = state.layout
	local status = read_file("/proc/self/status")
	return {
		os              = facts.os_name,
		kernel          = facts.kernel,
		display_server  = facts.display_server,
		desktop         = facts.desktop,
		locale          = facts.locale,
		keyboard_layout = type(layout) == "string" and layout or nil,
		ram_free        = facts.ram_free,
		process_memory  = process_memory(status),
		uptime          = os.time() - _started_at,
		elevated        = elevated(status),
	}
end

--- The keyboard state at this instant, and the remapping engine's.
--- @param state table Daemon state.
--- @return table
local function collect_input(state)
	local input = {}
	-- The pause belongs to the script actions, which the daemon hands over
	if type(state.is_paused) == "function" then input.paused = state.is_paused() == true end
	local Hook = require("adapters.keyboard_hook")
	local held = Hook.held_modifiers()
	for _, name in ipairs({ "shift", "ctrl", "alt", "altgr", "meta" }) do input[name] = held[name] == true end
	local caps_lock, caps_err = Hook.caps_lock_on()
	if caps_lock == nil then Logger.warn(LOG, "Diagnostics could not read the CapsLock state: %s.", tostring(caps_err)) end
	input.caps_lock = caps_lock
	local ok_manager, Manager = pcall(require, "platform.remap.manager")
	if ok_manager then input.kanata_running = Manager.owns_process() end
	input.keymap_resolved = require("adapters.keyboard_layout").is_ready() == true
	return input
end

--- Whether any hotstring group is on, as the macOS snapshot reads it; nil
--- when the configuration cannot say.
--- @param config table|nil The hotstrings configuration.
--- @return boolean|nil
local function hotstrings_enabled(config)
	if type(config) ~= "table" or type(config.get_groups) ~= "function"
		or type(config.is_group_enabled) ~= "function" then
		return nil
	end
	for _, name in ipairs(config.get_groups() or {}) do
		if config.is_group_enabled(name) == true then return true end
	end
	return false
end

--- The switch of a daemon module that exposes is_enabled(), nil without one.
--- @param part table|nil
--- @return boolean|nil
local function module_enabled(part)
	if type(part) ~= "table" or type(part.is_enabled) ~= "function" then return nil end
	return part.is_enabled() == true
end

--- The feature switches this driver can answer, as { id, enabled } items. A
--- module the daemon does not run has no row: a guessed "off" would read as
--- the user's choice.
--- @param state table Daemon state.
--- @return table
local function collect_features(state)
	local items = {}
	local function add(id, enabled)
		if type(enabled) == "boolean" then items[#items + 1] = { id = id, enabled = enabled } end
	end
	add("hotstrings", hotstrings_enabled(state.config))
	add("shortcuts", module_enabled(state.shortcuts))
	add("gestures", module_enabled(state.gestures))
	local ok_manager, Manager = pcall(require, "platform.remap.manager")
	if ok_manager then add("tapholds", Manager.tap_holds_enabled()) end
	add("llm", module_enabled(state.llm))
	add("metrics", module_enabled(state.keylogger))
	return { items = items }
end

--- The AI section.
--- @param state table Daemon state.
--- @return table
local function collect_ai(state)
	local llm = state.llm
	if not llm then return {} end
	return {
		ai_enabled = type(llm.is_enabled) == "function" and llm.is_enabled() == true or nil,
		-- Ollama is the only backend this driver has
		ai_backend = "ollama",
		ai_model   = type(llm.get_current_model) == "function" and llm.get_current_model() or nil,
	}
end

--- Whether the daemon may open a device, without keeping it open.
--- @param path string
--- @param mode string io.open mode.
--- @return string "granted", "missing" or "unknown"
local function device_access(path, mode)
	local fh, err, code = io.open(path, mode)
	if fh then
		fh:close()
		return "granted"
	end
	-- EACCES and EPERM: the file exists and this user may not open it
	if code == 13 or code == 1 then return "missing" end
	Logger.warn(LOG, "Diagnostics could not check %s: %s.", path, tostring(err))
	return "unknown"
end

--- The devices /proc/bus/input/devices lists, one table per block.
--- @return table
local function input_devices()
	local text = read_file("/proc/bus/input/devices") or ""
	local devices = {}
	for block in (text .. "\n\n"):gmatch("(.-)\n\n") do
		local bus, vendor, product = block:match("I: Bus=(%x+) Vendor=(%x+) Product=(%x+)")
		if bus then
			devices[#devices + 1] = {
				bus = bus, vendor = vendor, product = product,
				name = block:match('N: Name="([^"]*)"'),
				handlers = block:match("H: Handlers=([^\n]*)") or "",
			}
		end
	end
	return devices
end

--- The permissions the daemon needs, in the schema's order.
--- @param ids table The schema's permission ids for Linux, ordered.
--- @return table
local function collect_permissions(ids)
	local event = nil
	for _, device in ipairs(input_devices()) do
		local node = device.handlers:match("(event%d+)")
		if node and device.handlers:find("kbd", 1, true) then
			event = "/dev/input/" .. node
			break
		end
	end
	local readers = {
		input_devices = function() return event and device_access(event, "rb") or "unknown" end,
		uinput        = function() return device_access("/dev/uinput", "ab") end,
	}
	local items = {}
	for _, id in ipairs(ids) do
		local reader = readers[id]
		if not reader then error("no reader for the permission " .. tostring(id)) end
		items[#items + 1] = { id = id, state = reader() }
	end
	return { items = items }
end

--- The keyboards, mice and touchpads the kernel lists: bus, kind and ids, and
--- their names only when the user ticked "Include details". Virtual devices,
--- including the daemon's own output keyboard, are left out.
--- @param detailed boolean
--- @return table
local function collect_peripherals(detailed)
	local items = {}
	for _, device in ipairs(input_devices()) do
		local lower = (device.name or ""):lower()
		local kind = nil
		if lower:find("touchpad", 1, true) or lower:find("trackpad", 1, true) then kind = "touchpad"
		elseif device.handlers:find("mouse", 1, true) then kind = "mouse"
		elseif device.handlers:find("kbd", 1, true) then kind = "keyboard" end
		if kind and device.bus ~= "0006" then
			local item = {
				bus = BUSES[device.bus] or "other",
				kind = kind,
				vendor_id = device.vendor,
				product_id = device.product,
			}
			if detailed then item.name = device.name end
			items[#items + 1] = item
		end
	end
	return { items = items }
end

--- The warnings and errors: the session counters, the last error and the
--- newest entries of today's errors file (the ring before it exists).
--- @return table
local function collect_issues()
	local lines = require("logger").ring_buffer_snapshot() or {}
	local issues = require("logger").session_issues()
	local recent, source = {}, "unavailable"
	local ok, err = pcall(function()
		local limits = Snapshot.load_recent_issue_limits(
			require("infra.paths").shared("modules/diagnostics/recent_issues.json"))
		recent, source = Snapshot.collect_recent_issues(LoggerSink.errors_log_path(), lines, limits)
	end)
	if not ok then Logger.error(LOG, "Recent issues could not be collected: %s.", tostring(err)) end
	return {
		warn_count    = issues.warn_count,
		err_count     = issues.err_count,
		last_error    = issues.last_error,
		recent_source = source,
		recent        = recent,
	}
end

--- The daemon parts, the log level and the in-memory log.
--- @param state table Daemon state.
--- @return table
local function collect_developer(state)
	local ok_list, failed, disabled = {}, {}, {}
	-- Iterated over a list of NAMES: a constructor drops its nil values, so a
	-- table built from the state is empty exactly when every part is missing
	for _, name in ipairs(REQUIRED_PARTS) do
		if state[name] then ok_list[#ok_list + 1] = name else failed[#failed + 1] = name .. " (not wired)" end
	end
	for _, name in ipairs(OPTIONAL_PARTS) do
		local part = state[name]
		if not part then
			failed[#failed + 1] = name .. " (not loaded)"
		elseif type(part.is_enabled) == "function" and part.is_enabled() == false then
			disabled[#disabled + 1] = name
		else
			ok_list[#ok_list + 1] = name
		end
	end
	local logger = require("logger")
	local level = nil
	for name, value in pairs(logger.LEVELS) do
		if value == logger.get_level() then level = name end
	end
	return {
		modules_ok       = ok_list,
		modules_failed   = failed,
		modules_disabled = disabled,
		log_level        = level,
		ring_lines       = #(logger.ring_buffer_snapshot() or {}),
	}
end





-- ===============================
-- ===============================
-- ======= 3/ The Snapshot =======
-- ===============================
-- ===============================

--- Milliseconds, for the collection's duration.
--- @return number
local function now_ms()
	return require("infra.monotonic").now_ms()
end

--- Builds the synchronous (phase A) snapshot.
--- @param state table Daemon state.
--- @param detailed boolean Whether the user ticked "Include details".
--- @return table
function M.build_snapshot(state, detailed, extensive)
	state = type(state) == "table" and state or {}
	-- The budget is the collection's: the shared documents load once per
	-- session, before the clock starts
	local schema = M.config().schema
	local started = now_ms()
	local facts = collect("system facts", function() return require("infra.diagnostic_snapshot").system_facts() end)
	local permission_ids = {}
	for id in pairs(schema.permissions[M.DRIVER] or {}) do permission_ids[#permission_ids + 1] = id end
	table.sort(permission_ids)
	local sections = {
		paths       = collect("paths", function() return collect_paths(schema) end),
		versions    = collect("versions", function() return collect_versions(facts) end),
		hardware    = collect("hardware", function() return collect_hardware(facts) end),
		system      = collect("system", function() return collect_system(facts, state) end),
		input       = collect("input", function() return collect_input(state) end),
		features    = collect("features", function() return collect_features(state) end),
		ai          = collect("ai", function() return collect_ai(state) end),
		network     = {},
		permissions = collect("permissions", function() return collect_permissions(permission_ids) end),
		peripherals = collect("peripherals", function() return collect_peripherals(detailed == true) end),
		issues      = collect("issues", collect_issues),
		developer   = collect("developer", function() return collect_developer(state) end),
	}
	local snapshot = {
		schema_version = schema.schema_version,
		driver         = M.DRIVER,
		generated_at   = Snapshot.utc_now(),
		detailed       = detailed == true,
		extensive      = extensive == true,
		sections       = sections,
		probes         = Snapshot.pending_probes(schema, M.DRIVER, extensive == true),
	}
	local elapsed = now_ms() - started
	sections.developer.phase_a_ms = elapsed
	-- Not a warning: the next snapshot would count it among the session's
	-- problems. The report's developer section carries the duration.
	if elapsed > schema.phase_a_budget_ms then
		Logger.info(LOG, "The synchronous diagnostics took %.1f ms, over the %d ms budget.", elapsed,
			schema.phase_a_budget_ms)
	end
	local undeclared = Snapshot.check_fields(snapshot, schema)
	if #undeclared > 0 then
		Logger.error(LOG, "The diagnostics snapshot carries fields the schema does not declare: %s.",
			table.concat(undeclared, ", "))
	end
	return snapshot
end





-- ======================================
-- ======================================
-- ======= 4/ Pushing To The Page =======
-- ======================================
-- ======================================

--- Pushes a message into the page, only while the page that asked is open.
--- @param session table
--- @param message table
--- @return boolean pushed
local function push(session, message)
	if _session ~= session then return false end
	local manager = require("ui.webview_manager")
	if manager.current_epoch("healthcheck") ~= session.epoch then return false end
	local ok, json = pcall(require("json").encode, message)
	if not ok then
		Logger.error(LOG, "A diagnostics message could not be encoded: %s.", tostring(json))
		return false
	end
	return manager.eval_js("healthcheck", "if(window.receiveDiagnostics)window.receiveDiagnostics(" .. json .. ")")
end

--- Cancels the probes of a session.
--- @param session table|nil
local function cancel_probes(session)
	if session and session.probes then
		session.probes.cancel()
		session.probes = nil
	end
end

--- Archives only reported cleanup metadata; no native owner is adopted or released.
--- @param session table The exact window session being refreshed.
local function archive_cleanup_metadata(session)
	local rows = {}
	for id, result in pairs(session.snapshot.probes) do
		if result.state == "pending" or (result.cleanup ~= nil and result.cleanup ~= "settled") then
			local copied = {}
			for key, value in pairs(result) do copied[key] = value end
			if copied.state == "pending" then copied.state, copied.cleanup = "cancelled", "pending" end
			rows[id] = copied
		end
	end
	session.cleanup_history = session.cleanup_history or {}
	if next(rows) then session.cleanup_history[#session.cleanup_history + 1] = { probes = rows } end
end

--- Starts the probes of a session's snapshot.
--- @param session table
--- @param state table Daemon state.
local function start_probes(session, state)
	cancel_probes(session)
	if session.snapshot.extensive ~= true then return end
	session.probes = require("ui.healthcheck.probes").start(M.config().schema, session.snapshot.sections.paths, state,
		function(id, result, sections)
			if _session ~= session then return end
			session.snapshot.probes[id] = result
			for section_id, values in pairs(sections or {}) do
				local target = session.snapshot.sections[section_id]
				for key, value in pairs(values) do target[key] = value end
			end
			push(session, { type = "probe", id = id, result = result, sections = sections })
		end)
end

--- The first message of a page: its configuration and the first snapshot.
--- @param session table
--- @return table
local function init_message(session)
	local documents = M.config()
	return {
		type = "init",
		config = {
			schema    = documents.schema,
			redaction = documents.redaction,
			context   = require("ui.healthcheck.report").redaction_context(),
			mode      = session.mode,
		},
		snapshot = session.snapshot,
	}
end





-- ===============================
-- ===============================
-- ======= 5/ Page Actions =======
-- ===============================
-- ===============================

--- Performs one validated action.
--- @param session table
--- @param action table From healthcheck.actions.
--- @param state table Daemon state.
--- @param context table The routed message's context (close_owned_window).
--- @return table|nil The answer to the page.
local function perform(session, action, state, context)
	local Report = require("ui.healthcheck.report")
	local documents = M.config()
	if action.action == "export_snapshot" then
		return { type = "action", action = "export_snapshot", ok = true,
			export_sequence = action.export_sequence, snapshot = session.snapshot,
			share_text = require("healthcheck.share").document(session.snapshot, documents.schema,
				require("infra.i18n").get(documents.schema.share_policy.notice_key)).text }
	end
	if action.action == "cancel" then
		cancel_probes(session)
		for id, result in pairs(session.snapshot.probes) do
			if result.state == "pending" then session.snapshot.probes[id] = { state = "cancelled", cleanup = "pending" } end
		end
		return { type = "action", action = "cancel", ok = true, snapshot = session.snapshot }
	end
	if action.action == "refresh" then
		cancel_probes(session)
		archive_cleanup_metadata(session)
		session.detailed = action.detailed
		session.snapshot = M.build_snapshot(state, action.detailed, action.extensive)
		session.snapshot.retired_probes = session.cleanup_history
		start_probes(session, state)
		return { type = "snapshot", snapshot = session.snapshot }
	end
	if action.action == "close" then
		cancel_probes(session)
		if context and type(context.close_owned_window) == "function" then context.close_owned_window() end
		return nil
	end
	local result = Report.perform(action, session.snapshot.sections.paths, documents, Report.redaction_context(), nil, session.snapshot)
	result.type = "action"
	result.action = action.action
	return result
end

--- Handles an incoming page message.
--- @param payload any String or table from host_bridge.js.
--- @param state table Daemon state { engine, keylogger, config, llm, gestures, shortcuts, layout, … }.
--- @param context table|nil { app_name, epoch, close_owned_window } from the webview manager.
--- @return table|nil The answer the page receives.
function M.on_message(payload, state, context)
	state = type(state) == "table" and state or {}
	local epoch = type(context) == "table" and context.epoch or nil
	if payload == "ready" then
		Logger.info(LOG, "Diagnostics page ready.")
		cancel_probes(_session)
		_session = {
			epoch    = epoch,
			detailed = false,
			mode     = M._pending_mode,
		}
		M._pending_mode = nil
		_session.snapshot = M.build_snapshot(state, false)
		local message = init_message(_session)
		start_probes(_session, state)
		return message
	end
	if not _session or _session.epoch ~= epoch then
		Logger.warn(LOG, "A diagnostics page message arrived for a page that is gone.")
		return nil
	end
	local action, reason = Actions.validate(payload, {
		schema = M.config().schema, templates = M.config().templates, driver = M.DRIVER,
	})
	if not action then
		Logger.warn(LOG, "Refused a diagnostics page action (%s).", tostring(reason))
		return nil
	end
	Logger.info(LOG, "Diagnostics page action: %s.", action.action)
	-- The page is told its button did nothing, rather than left waiting
	local ok, answer = xpcall(perform, debug.traceback, _session, action, state, context)
	if not ok then
		Logger.error(LOG, "The diagnostics action '%s' failed: %s", action.action, tostring(answer))
		return { type = "action", action = action.action, ok = false }
	end
	return answer
end

--- Opens the diagnostics window, in report mode when asked: the page then
--- starts from the preview of what is shared and the report button. An open
--- window is replaced, as on macOS and Windows: bringing it forward would keep
--- its mode and its stale snapshot.
--- @param mode string|nil "report" or nil.
--- @return boolean opened
function M.open(mode)
	local manager = require("ui.webview_manager")
	local epoch = manager.current_epoch("healthcheck")
	if epoch ~= nil and not manager.hide("healthcheck", epoch) then
		Logger.error(LOG, "The open diagnostics window could not be replaced.")
		return false
	end
	M._pending_mode = mode
	return manager.show("healthcheck", require("infra.i18n").get_locale())
end

return M
