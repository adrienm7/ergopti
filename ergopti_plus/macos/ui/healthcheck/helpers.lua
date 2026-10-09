--- ui/healthcheck/helpers.lua

--- ==============================================================================
--- MODULE: Healthcheck Collectors (macOS)
--- DESCRIPTION:
--- The synchronous half of the diagnostics snapshot (version 2 of
--- _shared/modules/diagnostics/schema.json): one collector per section, each
--- returning that section's fields. The asynchronous probes (network, AI
--- backend, sysctl, df) live in ui.healthcheck.probes.
---
--- FEATURES & RATIONALE:
--- 1. Phase A never leaves the process: memory, Hammerspoon queries, cached
---    values and small files. hs.execute used to run sysctl and uname here, on
---    the main run loop that also dispatches the event taps, so opening the
---    window could stall typing. Every subprocess is now a probe.
--- 2. Values are raw (bytes, seconds, booleans); the shared page formats them,
---    so the three drivers show one format.
--- 3. A fact that cannot be read is left out and logged; the page shows it as
---    unknown. A fabricated default would read as a measurement.
--- 4. Nothing identifies a place or a device: no Wi-Fi name, no serial, no
---    host name. Open applications and device names are collected only when
---    the user ticks "Include details".
--- ==============================================================================

local H = {}

local hs       = hs
local Logger   = require("infra.logger")

local LOG = "healthcheck"

-- The remap guardian states platform.remap.guardian_state() reports, as
-- permission states: a guardian needing approval is a missing grant, one that
-- is unavailable leaves every remap inert, and it is not used at all while
-- « Ergopti uses Karabiner » is off. Anything else reads as unknown.
local GUARDIAN_PERMISSION = {
	ready             = "granted",
	requires_approval = "missing",
	unavailable       = "unavailable",
	not_used          = "not_used",
}

-- The manifest's platform codes, as the drivers are named
local PLATFORM_NAMES = { ahk = "Windows", hs = "macOS", linux = "Linux" }

-- The words a USB product name is classified by; the name itself is opt-in
local DEVICE_KINDS = {
	{ pattern = "keyboard", kind = "keyboard" },
	{ pattern = "trackpad", kind = "touchpad" },
	{ pattern = "touchpad", kind = "touchpad" },
	{ pattern = "mouse",    kind = "mouse" },
}

--- Calls a probe, logging and dropping a failure.
--- @param label string What was read, for the log.
--- @param fn function
--- @return any
local function read(label, fn)
	local ok, value = pcall(fn)
	if not ok then
		Logger.warn(LOG, "Diagnostics could not read %s: %s.", label, tostring(value))
		return nil
	end
	return value
end

--- The folder part of a path.
--- @param path string|nil
--- @return string|nil
local function dirname(path)
	if type(path) ~= "string" then return nil end
	return path:match("^(.*)/[^/]*$")
end





-- ========================
-- ========================
-- ======= 1/ Paths =======
-- ========================
-- ========================

--- The folders and files the diagnostics page lists and opens by id.
--- @param report_subdir string The schema's report.subdir.
--- @return table
function H.collect_paths(report_subdir)
	local ConfigPaths = require("infra.config_paths")
	local logs_dir = Logger.logs_dir()
	return {
		config_dir      = ConfigPaths.is_initialized() and ConfigPaths.get_config_dir() or nil,
		logs_dir        = logs_dir,
		log_today       = Logger.today_log_path(),
		errors_today    = Logger.today_errors_path(),
		crash_dir       = read("the crash reports folder", function()
			return require("modules.diagnostics.crash_reporter").reports_dir()
		end),
		diagnostics_dir = logs_dir and (logs_dir .. "/" .. report_subdir) or nil,
		app_dir         = type(hs.configdir) == "string" and hs.configdir or nil,
		launcher_log    = read("the launcher log", function()
			local env = require("adapters.boot_fatal").LAUNCHER_LOG_ENV
			local path = os.getenv(env)
			return (type(path) == "string" and path ~= "") and path or nil
		end),
	}
end





-- ===========================
-- ===========================
-- ======= 2/ Versions =======
-- ===========================
-- ===========================

--- The versions a bug report is triaged by.
--- @return table
function H.collect_versions()
	local SystemInfo = require("adapters.system_info")
	local commit, source = require("infra.diagnostic_snapshot").resolve_commit()
	local runtime = SystemInfo.runtime_version()
	return {
		ergopti_version = read("the ErgoptiPlus version", function()
			return require("modules.updater").current_version()
		end),
		commit          = commit .. " (" .. source .. ")",
		channel         = read("the update channel", function()
			return require("modules.updater").installed_channel()
		end),
		runtime         = runtime and ("Hammerspoon " .. runtime) or nil,
		-- The version the package pins, and whether its CLI is installed: the fork
		-- ships no version file to read
		karabiner       = read("the Karabiner-Elements version", function()
			local manifest = require("vendor.karabiner-elements.manifest")
			local installed = require("adapters.file_system").exists(require("platform.remap.ke_paths").CLI)
			return tostring(manifest.version) .. (installed and "" or " (not installed)")
		end),
	}
end





-- ====================================
-- ====================================
-- ======= 3/ Hardware And Load =======
-- ====================================
-- ====================================

--- The host's memory statistics, or nil.
--- @return table|nil
local function vm_stat()
	return read("the memory statistics", function() return hs.host.vmStat() end)
end

--- One display: its resolution, backing scale and whether it is the main one.
--- @param screen table hs.screen
--- @param main table|nil The main screen.
--- @return string|nil
local function describe_display(screen, main)
	local mode = screen:currentMode()
	if type(mode) ~= "table" or not mode.w or not mode.h then return nil end
	local text = string.format("%d×%d", mode.w, mode.h)
	if type(mode.scale) == "number" and mode.scale > 0 then text = text .. string.format(" @%gx", mode.scale) end
	-- Compared by id: every hs.screen query returns a new object
	if main and screen:id() == main:id() then text = text .. " (main)" end
	return text
end

--- The hardware section, without the facts only sysctl knows (a probe).
--- @return table
function H.collect_hardware()
	local SystemInfo = require("adapters.system_info")
	local stat = vm_stat()
	local displays = read("the displays", function()
		local main = hs.screen.mainScreen()
		local list = {}
		for _, screen in ipairs(hs.screen.allScreens()) do
			local text = describe_display(screen, main)
			if text then list[#list + 1] = text end
		end
		return list
	end)
	return {
		arch      = SystemInfo.arch(),
		ram_total = (type(stat) == "table" and type(stat.memSize) == "number" and stat.memSize > 0)
			and stat.memSize or nil,
		displays  = displays,
	}
end

--- The names of the regular applications running now (opt-in).
--- @return table
local function running_apps()
	local names = {}
	for _, app in ipairs(hs.application.runningApplications()) do
		-- Regular applications only: background agents are not what a user
		-- means by "open applications"
		if app:kind() == 1 then
			local name = app:name()
			if type(name) == "string" and name ~= "" then names[#names + 1] = name end
		end
	end
	table.sort(names)
	return names
end

--- The system section and its load.
--- @param detailed boolean Whether the user ticked "Include details".
--- @param uptime_sec number Seconds since the driver started.
--- @return table
function H.collect_system(detailed, uptime_sec)
	local SystemInfo = require("adapters.system_info")
	local stat = vm_stat()
	local version = SystemInfo.os_version()
	local ram_free = nil
	if type(stat) == "table" and type(stat.pagesFree) == "number" and stat.pagesFree >= 0
		and type(stat.pageSize) == "number" and stat.pageSize > 0 then
		-- The page size comes from the host: assuming 4 KiB undercounts free
		-- memory on the 16 KiB pages of Apple silicon
		ram_free = stat.pagesFree * stat.pageSize
	end
	return {
		os              = version and ("macOS " .. version) or nil,
		locale          = read("the locale", function() return hs.host.locale.current() end),
		keyboard_layout = SystemInfo.keyboard_layout(),
		ram_free        = ram_free,
		uptime          = uptime_sec,
		elevated        = SystemInfo.elevated() == "true",
		running_apps    = detailed and read("the open applications", running_apps) or nil,
	}
end





-- ========================
-- ========================
-- ======= 4/ Input =======
-- ========================
-- ========================

--- The keyboard state at this instant, and the remapping engine's phase.
--- @return table
function H.collect_input()
	local KeyState = require("adapters.key_state")
	local input = {
		paused    = read("the pause state", function()
			return require("modules.shortcuts.script_control").is_paused() == true
		end),
		shift     = KeyState.isDown("shift"),
		ctrl      = KeyState.isDown("ctrl"),
		alt       = KeyState.isDown("alt"),
		altgr     = KeyState.is_right_altgr_held(),
		meta      = KeyState.isDown("cmd"),
		caps_lock = read("the CapsLock state", function()
			local on, err = KeyState.capslock_on()
			if on == nil then error(err) end
			return on
		end),
	}
	local phase = read("the remapping lease", function()
		return (require("platform.remap.lease_controller").status())
	end)
	input.remap_phase = phase and tostring(phase) or nil
	return input
end





-- ===========================================
-- ===========================================
-- ======= 5/ Network, Features And AI =======
-- ===========================================
-- ===========================================

--- The feature switches this driver can answer, as { id, enabled } items.
--- @param state table|nil The menu state (the menu hands it over).
--- @return table
function H.collect_features(state)
	local items = {}
	local function add(id, enabled)
		if type(enabled) == "boolean" then items[#items + 1] = { id = id, enabled = enabled } end
	end
	if type(state) == "table" then
		if type(state.hotstrings) == "table" then
			local any = false
			for _, on in pairs(state.hotstrings) do if on == true then any = true end end
			add("hotstrings", any)
		end
		add("layout", state.keymap)
		add("shortcuts", state.shortcuts)
		add("gestures", state.gestures)
		add("metrics", state.keylogger_enabled)
	end
	add("llm", read("the AI switch", function()
		return require("modules.llm").get_runtime_llm_enabled() == true
	end))
	return { items = items }
end

--- The network facts phase A can read: the Wi-Fi signal only. The network's
--- name identifies a place, and a hash of it is reversed with a list of common
--- names (no-network-identity); GitHub's reachability is a probe.
--- @return table
function H.collect_network()
	local signal = require("adapters.network_info").getSignalStrength()
	return { wifi_signal = type(signal) == "number" and string.format("%d%%", signal) or nil }
end

--- The features this platform lacks, from the generated manifest: the only
--- place a user can ask why a menu row they read about is not in their menu.
--- Every absence is listed, explained or not: a list of only the explained
--- ones would look complete while hiding the ones that matter most. The page
--- translates each reason key.
--- @return table { items = { { feature, platforms, reason } } }
function H.collect_unavailable()
	local explained, silent = require("infra.manifest_reader").coverage_gaps()
	local items = {}
	for _, gaps in ipairs({ explained, silent }) do
		for _, gap in ipairs(gaps) do
			local names = {}
			for _, code in ipairs(gap.platforms or {}) do
				local name = PLATFORM_NAMES[code]
				if not name then error("the manifest names an unknown platform: " .. tostring(code)) end
				names[#names + 1] = name
			end
			items[#items + 1] = {
				feature   = gap.path,
				platforms = table.concat(names, ", "),
				reason    = (type(gap.reason_key) == "string" and gap.reason_key ~= "") and gap.reason_key or nil,
			}
		end
	end
	table.sort(items, function(a, b) return a.feature < b.feature end)
	return { items = items }
end

--- The AI section: the switch, the backend, the model and the profile.
--- @return table
function H.collect_ai()
	local llm = require("modules.llm")
	return {
		ai_enabled = read("the AI switch", function() return llm.get_runtime_llm_enabled() == true end),
		ai_backend = read("the AI backend", function() return llm.get_backend() end),
		ai_model   = read("the AI model", function() return llm.get_current_model() end),
		ai_profile = read("the AI profile", function() return llm.get_active_profile() end),
	}
end





-- ==============================
-- ==============================
-- ======= 6/ Permissions =======
-- ==============================
-- ==============================

--- A native permission answer as a schema state.
--- @param id string The permission, for the log.
--- @param granted boolean|nil
--- @param detail string|nil Why the query failed.
--- @return string "granted", "missing" or "unknown"
local function permission_state(id, granted, detail)
	if granted == true then return "granted" end
	if granted == false then return "missing" end
	Logger.warn(LOG, "The %s permission could not be read: %s.", id, tostring(detail or "no answer"))
	return "unknown"
end

--- The macOS permissions, read without prompting, in the schema's order.
--- @param ids table The schema's permission ids for this driver, ordered.
--- @return table
function H.collect_permissions(ids)
	local states = {
		accessibility    = function()
			return permission_state("accessibility", require("adapters.accessibility_permission").is_trusted())
		end,
		screen_recording = function()
			return permission_state("screen_recording", require("adapters.screen_capture").permission_state())
		end,
		-- Hammerspoon has no query for Input Monitoring that does not prompt, and
		-- the grant belongs to the Karabiner grabber rather than to this process
		input_monitoring = function() return "unknown" end,
		-- Phase A only reads memory: a remap owner that never loaded is unknown
		login_items      = function()
			local remap = package.loaded["platform.remap"]
			if type(remap) ~= "table" or type(remap.guardian_state) ~= "function" then return "unknown" end
			return GUARDIAN_PERMISSION[remap.guardian_state()] or "unknown"
		end,
	}
	local items = {}
	for _, id in ipairs(ids) do
		local reader = states[id]
		if not reader then error("no reader for the permission " .. tostring(id)) end
		items[#items + 1] = { id = id, state = read("the permission " .. id, reader) or "unknown" }
	end
	return { items = items }
end





-- ==========================
-- ==========================
-- ======= 7/ Devices =======
-- ==========================
-- ==========================

--- The kind of a device, from its USB product name or its Bluetooth minor
--- type ("Keyboard", "Mouse", "Trackpad").
--- @param name string|nil
--- @return string
function H.device_kind(name)
	local lower = type(name) == "string" and name:lower() or ""
	for _, entry in ipairs(DEVICE_KINDS) do
		if lower:find(entry.pattern, 1, true) then return entry.kind end
	end
	return "other"
end

--- The attached USB devices: bus, kind and ids, and their names only when
--- the user ticked "Include details". hs.usb sees no Bluetooth device: the
--- bluetooth probe (ui.healthcheck.probes) completes the list.
--- @param detailed boolean
--- @return table
function H.collect_peripherals(detailed)
	local items = {}
	for _, device in ipairs(read("the USB devices", function() return hs.usb.attachedDevices() end) or {}) do
		local item = {
			bus        = "usb",
			kind       = H.device_kind(device.productName),
			vendor_id  = type(device.vendorID) == "number" and string.format("%04x", device.vendorID) or nil,
			product_id = type(device.productID) == "number" and string.format("%04x", device.productID) or nil,
		}
		if detailed then item.name = device.productName end
		items[#items + 1] = item
	end
	return { items = items }
end

return H
