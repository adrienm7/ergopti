--- lib/healthcheck.lua

--- ==============================================================================
--- MODULE: Healthcheck
--- DESCRIPTION:
--- Diagnostic probe that snapshots the runtime state of the Hammerspoon driver
--- and returns it in both structured (table) and human-readable (string) form.
--- Designed to be called from the tray-menu "Healthcheck" item, an hs.ipc
--- command, or any other surface that needs a quick sanity check.
---
--- FEATURES & RATIONALE:
--- 1. Adapter probing: iterates the canonical adapter list, attempts a require()
---    for each module, and verifies the presence of its public contract methods —
---    without side effects.
--- 2. Port validation: checks that each port adapter responds to the four
---    canonical port methods (setIcon, setMenu, setTooltip, destroy for TrayMenu,
---    etc.) and records pass/fail per port.
--- 3. Last error capture: reads the last Logger ERROR entry stored in module
---    state so callers can surface the most recent failure without parsing logs.
--- 4. Uptime: computes seconds since the module was first required, giving a
---    lightweight proxy for driver uptime.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "healthcheck"

-- Module load timestamp — used to approximate driver uptime.
local _load_time = os.time()

-- Last error captured by M.record_error(); reset to nil on each M.run() call.
local _last_error = nil




-- ============================================
-- ============================================
-- ======= 1/ Adapter & Port Registry ========
-- ============================================
-- ============================================

-- Each entry: { id = "require.path", contract = { "method1", "method2", … } }
-- Contract methods are the minimal public surface that must be present for the
-- adapter to be considered operational.
local ADAPTER_SPECS = {
	{
		id       = "adapters.clipboard",
		contract = { "read", "write" },
	},
	{
		id       = "adapters.file_system",
		contract = { "read", "write", "exists" },
	},
	{
		id       = "adapters.http_client",
		contract = { "get", "post" },
	},
	{
		id       = "adapters.keyboard_hook",
		contract = { "start", "stop" },
	},
	{
		id       = "adapters.notifier",
		contract = { "notify" },
	},
	{
		id       = "adapters.process_lifecycle",
		contract = { "launch", "kill" },
	},
	{
		id       = "adapters.secure_field_detector",
		contract = { "is_secure" },
	},
	{
		id       = "adapters.storage",
		contract = { "get", "set" },
	},
	{
		id       = "adapters.text_sender",
		contract = { "send" },
	},
	{
		id       = "adapters.timer_scheduler",
		contract = { "after", "every" },
	},
	{
		id       = "adapters.tooltip_renderer",
		contract = { "show", "hide" },
	},
	{
		id       = "adapters.tray_menu",
		contract = { "setIcon", "setMenu", "setTooltip", "destroy" },
	},
	{
		id       = "adapters.window_info",
		contract = { "focused_app", "focused_title" },
	},
}




-- ============================================
-- ============================================
-- ======= 2/ Public API =====================
-- ============================================
-- ============================================

--- Records the most recent driver error so M.run() can surface it.
--- Call this from any error handler that wants healthcheck visibility.
--- @param msg string Human-readable error description.
function M.record_error(msg)
	_last_error = tostring(msg)
	Logger.debug(LOG, "Last error recorded: %s.", _last_error)
end


--- Probes all registered adapters and port contracts, then returns a snapshot
--- table with: version, loaded_adapters, ports_validated, last_error, uptime_sec.
--- @return table Snapshot with fields described above.
function M.run()
	Logger.start(LOG, "Running healthcheck…")

	-- Resolve the driver version (mirrors menu_about.lua logic).
	local version = "local"
	if hs and hs.processInfo then
		local info = hs.processInfo
		if type(info) == "table" and type(info.version) == "string" and info.version ~= "" then
			version = info.version
		end
	end

	local loaded_adapters  = {}
	local ports_validated  = {}
	local failed_adapters  = {}

	for _, spec in ipairs(ADAPTER_SPECS) do
		local ok, mod = pcall(require, spec.id)
		if not ok then
			table.insert(failed_adapters, spec.id .. " (load failed)")
			Logger.warn(LOG, "Adapter '%s' could not be loaded: %s.", spec.id, tostring(mod))
		else
			table.insert(loaded_adapters, spec.id)

			-- Validate each method in the contract
			local all_ok = true
			for _, method in ipairs(spec.contract) do
				if type(mod[method]) ~= "function" then
					all_ok = false
					Logger.warn(LOG, "Adapter '%s' missing contract method '%s'.", spec.id, method)
				end
			end

			if all_ok then
				table.insert(ports_validated, spec.id)
			else
				table.insert(failed_adapters, spec.id .. " (contract incomplete)")
			end
		end
	end

	local uptime_sec = os.time() - _load_time

	local result = {
		version         = version,
		loaded_adapters = loaded_adapters,
		ports_validated = ports_validated,
		failed_adapters = failed_adapters,
		last_error      = _last_error,
		uptime_sec      = uptime_sec,
	}

	Logger.success(LOG, "Healthcheck complete — %d adapter(s) OK, %d failed, uptime %ds.",
		#ports_validated, #failed_adapters, uptime_sec)

	return result
end


--- Formats a healthcheck result table as a human-readable string for display.
--- Calls M.run() internally if no snapshot is provided.
--- @param snapshot table|nil Result from M.run(), or nil to run fresh.
--- @return string Formatted diagnostic string.
function M.format(snapshot)
	local s = snapshot or M.run()

	local lines = {}
	table.insert(lines, "=== ErgoptiPlus — Hammerspoon Healthcheck ===")
	table.insert(lines, string.format("Version  : %s", s.version))
	table.insert(lines, string.format("Uptime   : %ds", s.uptime_sec))
	table.insert(lines, "")

	table.insert(lines, string.format("Adapters chargés (%d) :", #s.loaded_adapters))
	for _, name in ipairs(s.loaded_adapters) do
		table.insert(lines, "  ✓ " .. name)
	end

	table.insert(lines, string.format("Ports validés (%d) :", #s.ports_validated))
	for _, name in ipairs(s.ports_validated) do
		table.insert(lines, "  ✓ " .. name)
	end

	if #s.failed_adapters > 0 then
		table.insert(lines, string.format("Échecs (%d) :", #s.failed_adapters))
		for _, name in ipairs(s.failed_adapters) do
			table.insert(lines, "  ✗ " .. name)
		end
	else
		table.insert(lines, "Échecs : aucun")
	end

	table.insert(lines, "")
	if s.last_error then
		table.insert(lines, "Dernière erreur : " .. s.last_error)
	else
		table.insert(lines, "Dernière erreur : aucune")
	end

	return table.concat(lines, "\n")
end

return M
