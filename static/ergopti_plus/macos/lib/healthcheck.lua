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
--- 2. Port validation: records pass/fail per adapter contract.
--- 3. Last error capture: reads the last Logger ERROR entry stored in module
---    state so callers can surface the most recent failure without parsing logs.
--- 4. Uptime: computes seconds since the module was first required.
--- 5. System info: captures macOS version, Hammerspoon version, git hash,
---    screen resolution, locale, and config path for a complete snapshot.
--- 6. Session counters: counts WARNING and ERROR lines from the in-memory ring
---    buffer, and surfaces the last 100 for at-a-glance diagnosis.
--- 7. Selectable window: M.show_window() renders the report in an hs.webview.
---    HTML is generated directly from the snapshot — no JS conversion step.
---    All diagnostic labels are in English (developer-facing, not translated).
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "healthcheck"

-- Module load timestamp — used to approximate driver uptime.
local _load_time = os.time()

-- Last error captured by M.record_error(); persists until the next record_error() call.
local _last_error = nil

-- Reference to the currently open webview window (singleton — one at a time).
local _window = nil

-- Poll timer for the copy-button JS flag; module-level so show_window() can
-- stop the PREVIOUS timer when reopening (a local would be orphaned on reopen).
local _poll_timer = nil

local function _stop_poll()
	if _poll_timer then
		_poll_timer:stop()
		_poll_timer = nil
		Logger.debug(LOG, "Copy-button poll timer stopped.")
	end
end

local _sys_info
local _format_uptime
local _js_str
local _he
local _hcode
local _snapshot_to_html
local _collect_pause_state
local _collect_keylogger_summary
local _collect_llm_state
local _collect_layout_state
local _collect_hotstrings_state
local _collect_logs_info
local _collect_config_summary




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
		contract = { "send" },
	},
	{
		id       = "adapters.process_lifecycle",
		contract = { "start", "stop" },
	},
	{
		id       = "adapters.secure_field_detector",
		contract = { "isSecureField", "isSecureApp", "refresh" },
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
		contract = { "getFocused", "getAll" },
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
--- table with: version, loaded_adapters, ports_validated, last_error, uptime_sec, sys.
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
	Logger.debug(LOG, "Driver version: %s.", version)

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
			Logger.debug(LOG, "Adapter '%s' loaded.", spec.id)

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
				Logger.debug(LOG, "Adapter '%s' contract validated.", spec.id)
			else
				table.insert(failed_adapters, spec.id .. " (contract incomplete)")
			end
		end
	end

	local uptime_sec = os.time() - _load_time
	Logger.debug(LOG, "Uptime: %ds.", uptime_sec)

	-- Collect recent WARNING/ERROR lines from the in-memory ring buffer
	local recent_issues = {}
	local warn_count    = 0
	local err_count     = 0
	local all_lines     = Logger.ring_buffer_snapshot()
	if not all_lines then
		Logger.error(LOG, "Logger.ring_buffer_snapshot() returned nil — ring buffer unavailable.")
		all_lines = {}
	end
	for _, line in ipairs(all_lines) do
		if line:find("%[WARNING%]") or line:find("%[ERROR%]") then
			table.insert(recent_issues, line)
			if line:find("%[WARNING%]") then warn_count = warn_count + 1 end
			if line:find("%[ERROR%]")   then err_count  = err_count  + 1 end
		end
	end
	-- Keep only the last 100
	if #recent_issues > 100 then
		local trimmed = {}
		for i = #recent_issues - 99, #recent_issues do
			table.insert(trimmed, recent_issues[i])
		end
		recent_issues = trimmed
	end
	Logger.debug(LOG, "Ring buffer: %d line(s), %d warning(s), %d error(s).",
		#all_lines, warn_count, err_count)

	-- Run each enriched collector in a protected call so a single broken
	-- collector cannot abort the entire healthcheck.
	local function safe_collect(name, fn)
		local ok, val = pcall(fn)
		if not ok then
			Logger.error(LOG, "Collector '%s' crashed: %s.", name, tostring(val))
			return nil
		end
		Logger.debug(LOG, "Collector '%s' done.", name)
		return val
	end

	local result = {
		version         = version,
		loaded_adapters = loaded_adapters,
		ports_validated = ports_validated,
		failed_adapters = failed_adapters,
		last_error      = _last_error,
		uptime_sec      = uptime_sec,
		warn_count      = warn_count,
		err_count       = err_count,
		recent_issues   = recent_issues,
		sys             = safe_collect("sys_info",            _sys_info),
		pause_state     = safe_collect("pause_state",         _collect_pause_state),
		keylogger       = safe_collect("keylogger_summary",   _collect_keylogger_summary),
		llm             = safe_collect("llm_state",           _collect_llm_state),
		layout          = safe_collect("layout_state",        _collect_layout_state),
		hotstrings      = safe_collect("hotstrings_state",    _collect_hotstrings_state),
		logs            = safe_collect("logs_info",           _collect_logs_info),
		config          = safe_collect("config_summary",      _collect_config_summary),
	}

	Logger.success(LOG, "Healthcheck complete — %d adapter(s) OK, %d failed, uptime %ds.",
		#ports_validated, #failed_adapters, uptime_sec)

	return result
end


--- Opens a dedicated webview window displaying the healthcheck report.
--- Text is fully selectable and copyable. Replaces any existing window (singleton).
function M.show_window()
	Logger.start(LOG, "Opening healthcheck window…")

	if _window then
		Logger.debug(LOG, "Closing existing healthcheck window before reopening.")
		_stop_poll()
		pcall(function() _window:delete() end)
		_window = nil
	end

	local ok_snap, snapshot = pcall(M.run)
	if not ok_snap or not snapshot then
		Logger.error(LOG, "M.run() failed — cannot show healthcheck window: %s.", tostring(snapshot))
		return
	end

	local ok_plain, plain = pcall(M.format_plain, snapshot)
	if not ok_plain or not plain then
		Logger.error(LOG, "M.format_plain() failed: %s.", tostring(plain))
		plain = "(format error)"
	end

	local i18n_ok, i18n = pcall(require, "lib.i18n")
	if not i18n_ok then
		Logger.warn(LOG, "lib.i18n unavailable — using key names as labels.")
	end
	local t = (i18n_ok and type(i18n) == "table" and type(i18n.get) == "function")
		and function(k) return i18n.get(k) end
		or  function(k) return k end

	local title = t("menu.debug.healthcheck") or "System diagnostic"
	if not title:find("ErgoptiPlus") then
		title = "ErgoptiPlus — " .. title
	end
	local btn_label = t("healthcheck.copy_and_close") or "Copy to clipboard and close"

	local ok_html, html = pcall(_snapshot_to_html, snapshot, btn_label)
	if not ok_html or not html then
		Logger.error(LOG, "_snapshot_to_html() failed: %s.", tostring(html))
		-- Fall back to plain-text alert rather than showing a blank window
		local ok_d, dialog = pcall(require, "lib.dialog_util")
		if ok_d and dialog then
			dialog.block_alert(title, plain, "OK")
		end
		return
	end

	local ok_scr, screen = pcall(function() return hs.screen.mainScreen() end)
	if not ok_scr or not screen then
		Logger.warn(LOG, "hs.screen.mainScreen() failed — using default frame.")
	end
	local sf = (ok_scr and screen and type(screen.frame) == "function" and screen:frame())
		or { x = 0, y = 0, w = 1440, h = 900 }

	local W, H = 700, 600
	local frame = {
		x = math.floor(sf.x + (sf.w - W) / 2),
		y = math.floor(sf.y + (sf.h - H) / 2),
		w = W,
		h = H,
	}
	Logger.debug(LOG, "Webview frame: x=%d y=%d w=%d h=%d.", frame.x, frame.y, frame.w, frame.h)

	local ok_wv, wv = pcall(hs.webview.new, frame, { developerExtrasEnabled = false })
	if not ok_wv or not wv then
		Logger.error(LOG, "hs.webview.new() failed — falling back to text alert: %s.", tostring(wv))
		local ok_d, dialog = pcall(require, "lib.dialog_util")
		if ok_d and dialog then
			dialog.block_alert(title, plain, "OK")
		end
		return
	end
	Logger.debug(LOG, "Webview created.")

	local masks = hs.webview.windowMasks
	local ok_style, style_err = pcall(function()
		wv:windowStyle((masks["titled"] or 1) + (masks["closable"] or 2) + (masks["miniaturizable"] or 4))
	end)
	if not ok_style then Logger.warn(LOG, "windowStyle() failed: %s.", tostring(style_err)) end

	pcall(function() wv:windowTitle(title) end)
	pcall(function() wv:allowTextEntry(true) end)
	pcall(function() wv:allowNewWindows(false) end)
	pcall(function() wv:allowGestures(false) end)

	-- floating ensures the window appears on top of the menu bar and other apps
	local ok_lvl, lvl_err = pcall(function() wv:level(hs.drawing.windowLevels.floating) end)
	if not ok_lvl then Logger.warn(LOG, "wv:level(floating) failed: %s.", tostring(lvl_err)) end

	-- Wire up the copy-and-close button using a flag polled from Lua.
	-- WKWebView rejects custom URL schemes (ergopti://) with NSURLErrorDomain -1002
	-- before willNavigate fires, so we set a JS global instead and poll it.
	-- _poll_timer and _stop_poll() are module-level so reopening the window
	-- can stop the previous timer before orphaning it.

	local ok_wcb, wcb_err = pcall(function()
		wv:windowCallback(function(action)
			Logger.debug(LOG, "Window callback: action='%s'.", tostring(action))
			if action == "closing" or action == "closed" then
				_stop_poll()
				_window = nil
			end
		end)
	end)
	if not ok_wcb then Logger.warn(LOG, "windowCallback() failed: %s.", tostring(wcb_err)) end

	local ok_ncb, ncb_err = pcall(function()
		wv:navigationCallback(function(action, _)
			Logger.debug(LOG, "Navigation callback: action='%s'.", tostring(action))
			if action == "didFinishNavigation" then
				-- Inject a flag variable and a click handler that sets it
				local ok_js, js_err = pcall(function()
					wv:evaluateJavaScript(
						"window.__hs_copy_requested = false;"
						.. "document.getElementById('btnCopy').onclick=function(){"
						.. "window.__hs_copy_requested=true;"
						.. "};"
					)
				end)
				if not ok_js then
					Logger.warn(LOG, "JS injection failed: %s.", tostring(js_err))
				end
				-- Stop any previous poll timer before arming a new one; a second
				-- didFinishNavigation (re-navigation or webview redraw) would otherwise
				-- orphan the existing timer and leave two timers polling in parallel.
				_stop_poll()
				-- Poll every 200 ms for the flag; stop and clean up when triggered
				_poll_timer = hs.timer.new(0.2, function()
					if not wv then _stop_poll(); return end
					wv:evaluateJavaScript("window.__hs_copy_requested", function(result)
						if result == true then
							Logger.debug(LOG, "Copy button clicked — copying plain text to clipboard.")
							hs.pasteboard.setContents(plain)
							_stop_poll()
							if _window then
								pcall(function() _window:delete() end)
								_window = nil
							end
						end
					end)
				end)
				_poll_timer:start()
				Logger.debug(LOG, "Copy-button poll timer started.")
			end
		end)
	end)
	if not ok_ncb then Logger.warn(LOG, "navigationCallback() failed: %s.", tostring(ncb_err)) end

	local ok_h, h_err = pcall(function() wv:html(html) end)
	if not ok_h then Logger.error(LOG, "wv:html() failed: %s.", tostring(h_err)) end

	local ok_sh, sh_err = pcall(function() wv:show() end)
	if not ok_sh then
		Logger.error(LOG, "wv:show() failed — window will not appear: %s.", tostring(sh_err))
	end

	_window = wv

	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if ok_ui and ui_builder then
		Logger.debug(LOG, "Delegating focus to ui_builder.force_focus().")
		ui_builder.force_focus(wv, true)
	else
		Logger.warn(LOG, "ui.ui_builder unavailable (%s) — using fallback focus.", tostring(ui_builder))
		hs.timer.doAfter(0.08, function()
			pcall(hs.focus)
			local ok_win, win = pcall(function() return wv:hswindow() end)
			if ok_win and win and type(win.focus) == "function" then
				pcall(function() win:focus() end)
			else
				pcall(function() wv:bringToFront() end)
			end
		end)
	end

	Logger.success(LOG, "Healthcheck window opened.")
end


--- Formats a snapshot as plain text (last-resort fallback when webview fails).
--- All labels are in English — diagnostic output is developer-facing, not user-facing.
--- @param snapshot table|nil Result from M.run(), or nil to run fresh.
--- @return string Plain-text diagnostic string.
function M.format_plain(snapshot)
	local s      = snapshot or M.run()
	local sys    = s.sys or {}
	local lines  = {}

	table.insert(lines, "=== System diagnostic ===")
	table.insert(lines, "")
	table.insert(lines, string.format("Version          : %s", s.version))
	table.insert(lines, string.format("Last git commit  : %s", tostring(sys.git_hash or "unknown")))
	table.insert(lines, string.format("Uptime           : %s", _format_uptime(s.uptime_sec)))
	table.insert(lines, string.format("Hammerspoon      : %s", tostring(sys.hs_version or "?")))
	table.insert(lines, string.format("macOS            : %s", tostring(sys.os_version or "?")))
	table.insert(lines, string.format("Architecture     : %s", tostring(sys.arch or "?")))
	table.insert(lines, string.format("CPU              : %s", tostring(sys.cpu_model or "?")))
	table.insert(lines, string.format("Logical cores    : %s", tostring(sys.cpu_cores or "?")))
	table.insert(lines, string.format("Total RAM        : %s", tostring(sys.ram_total or "?")))
	table.insert(lines, string.format("Available RAM    : %s", tostring(sys.ram_free or "?")))
	table.insert(lines, string.format("Screen           : %s", tostring(sys.screen_res or "?")))
	table.insert(lines, string.format("DPI              : %s%s", tostring(sys.dpi or "?"), sys.retina_scale and (" (" .. sys.retina_scale .. " Retina)") or ""))
	table.insert(lines, string.format("Locale           : %s", tostring(sys.locale or "?")))
	if sys.config_dir and sys.config_dir ~= "" then
		table.insert(lines, string.format("Config dir       : %s", sys.config_dir))
	end
	table.insert(lines, "")
	table.insert(lines, string.format("Warnings         : %d", s.warn_count or 0))
	table.insert(lines, string.format("Errors           : %d", s.err_count  or 0))
	table.insert(lines, "")

	-- Enriched sections (maximum diagnostic value)
	if s.pause_state then
		local ps = s.pause_state
		table.insert(lines, string.format("Pause / Suspend  : %s (%s)", ps.is_paused and "PAUSED" or "running", ps.source or "unknown"))
	end
	if s.logs then
		local lg = s.logs
		table.insert(lines, string.format("Logs (unified)   : %s", lg.unified_today or "n/a"))
		table.insert(lines, string.format("Errors sink      : %s  (WARNING/ERROR only — keeps main log clean)", lg.errors_today or "n/a"))
	end
	if s.keylogger then
		local kl = s.keylogger
		table.insert(lines, string.format("Keylogger        : events=%s wpm=%s privacy_hits=%s", tostring(kl.events_session), tostring(kl.wpm), tostring(kl.privacy_hits)))
	end
	if s.llm then
		local ll = s.llm
		table.insert(lines, string.format("LLM              : enabled=%s backend=%s profile=%s", tostring(ll.enabled), tostring(ll.backend), tostring(ll.active_profile)))
	end
	if s.layout then
		local ly = s.layout
		table.insert(lines, string.format("Layout           : base=%s altgr=%s shift=%s caps=%s prefix_latch=%s", tostring(ly.ergopti_base), tostring(ly.altgr), tostring(ly.shift), tostring(ly.caps), tostring(ly.prefix_latch)))
	end
	if s.hotstrings then
		local hs = s.hotstrings
		table.insert(lines, string.format("Hotstrings       : terminators=%s personal=%s dyn=%s magic=%s", tostring(hs.terminators), tostring(hs.personal_count), tostring(hs.dynamic_count), tostring(hs.magic_key)))
	end

	local ok_list   = s.ports_validated or {}
	local fail_list = s.failed_adapters or {}
	table.insert(lines, string.format("Adapters OK (%d):", #ok_list))
	for _, name in ipairs(ok_list) do
		table.insert(lines, "  + " .. name)
	end
	if #fail_list > 0 then
		table.insert(lines, string.format("Failed (%d):", #fail_list))
		for _, name in ipairs(fail_list) do
			table.insert(lines, "  x " .. name)
		end
	else
		table.insert(lines, "Failed : none")
	end

	table.insert(lines, "")
	if s.last_error then
		table.insert(lines, "Last error : " .. s.last_error)
	else
		table.insert(lines, "Last error : none")
	end

	local issues = s.recent_issues or {}
	if #issues > 0 then
		table.insert(lines, "")
		table.insert(lines, string.format("--- Recent warnings / errors (%d) ---", #issues))
		for _, l in ipairs(issues) do
			table.insert(lines, l)
		end
	end

	return table.concat(lines, "\n")
end




-- ============================================
-- ============================================
-- ======= 3/ Internal Helpers ===============
-- ============================================
-- ============================================

--- Collects OS/runtime/screen fields into a flat table.
--- @return table
_sys_info = function()
	local info = {}

	-- Hammerspoon version
	local hs_ver = "?"
	if hs and hs.processInfo and type(hs.processInfo) == "table" then
		local v = hs.processInfo.version
		if type(v) == "string" and v ~= "" then hs_ver = v
		else Logger.warn(LOG, "hs.processInfo.version is absent or empty.") end
	else
		Logger.warn(LOG, "hs.processInfo is unavailable.")
	end
	info.hs_version = hs_ver
	Logger.debug(LOG, "hs_version: %s.", hs_ver)

	-- macOS version
	local os_ver = "?"
	local ok_host, hs_host = pcall(require, "hs.host")
	if not ok_host then
		Logger.warn(LOG, "hs.host unavailable: %s.", tostring(hs_host))
	elseif type(hs_host.operatingSystemVersionString) ~= "function" then
		Logger.warn(LOG, "hs.host.operatingSystemVersionString is not a function.")
	else
		local ok_v, v = pcall(hs_host.operatingSystemVersionString)
		if ok_v and type(v) == "string" then os_ver = v
		else Logger.warn(LOG, "operatingSystemVersionString() failed: %s.", tostring(v)) end
	end
	info.os_version = os_ver
	Logger.debug(LOG, "os_version: %s.", os_ver)

	-- Primary screen resolution
	local res = "?"
	local ok_scr, scr = pcall(function() return hs.screen.mainScreen() end)
	if not ok_scr or not scr then
		Logger.warn(LOG, "hs.screen.mainScreen() unavailable: %s.", tostring(scr))
	elseif type(scr.currentMode) ~= "function" then
		Logger.warn(LOG, "screen.currentMode is not a function.")
	else
		local ok_m, m = pcall(function() return scr:currentMode() end)
		if ok_m and m and m.w and m.h then
			res = m.w .. "×" .. m.h
		else
			Logger.warn(LOG, "screen:currentMode() failed or returned incomplete data: %s.", tostring(m))
		end
	end
	info.screen_res = res
	Logger.debug(LOG, "screen_res: %s.", res)

	-- System locale — hs.host.locale is a table; current() is the function
	local locale = "?"
	if ok_host and hs_host then
		if type(hs_host.locale) ~= "table" then
			Logger.warn(LOG, "hs.host.locale is not a table.")
		elseif type(hs_host.locale.current) ~= "function" then
			Logger.warn(LOG, "hs.host.locale.current is not a function.")
		else
			local ok_l, l = pcall(hs_host.locale.current)
			if ok_l and type(l) == "string" and l ~= "" then locale = l
			else Logger.warn(LOG, "locale.current() failed: %s.", tostring(l)) end
		end
	end
	info.locale = locale
	Logger.debug(LOG, "locale: %s.", locale)

	-- Config directory
	local config_dir = ""
	if hs and type(hs.configdir) == "string" then
		config_dir = hs.configdir
	else
		Logger.warn(LOG, "hs.configdir is not a string.")
	end
	info.config_dir = config_dir

	-- CPU model + core count via sysctl
	local cpu_model = "?"
	local cpu_cores = "?"
	local ok_cpu, cpu_out = pcall(hs.execute, "sysctl -n machdep.cpu.brand_string 2>/dev/null")
	if ok_cpu and type(cpu_out) == "string" and cpu_out ~= "" then
		cpu_model = cpu_out:match("^%s*(.-)%s*$")
	else
		-- Apple Silicon fallback
		local ok_ap, ap_out = pcall(hs.execute, "sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null")
		if ok_ap and type(ap_out) == "string" and ap_out ~= "" then cpu_model = ap_out:match("^%s*(.-)%s*$") end
	end
	local ok_cores, cores_out = pcall(hs.execute, "sysctl -n hw.logicalcpu 2>/dev/null")
	if ok_cores and type(cores_out) == "string" and cores_out ~= "" then
		cpu_cores = cores_out:match("^%s*(.-)%s*$")
	end
	info.cpu_model = cpu_model
	info.cpu_cores = cpu_cores
	Logger.debug(LOG, "cpu_model: %s cores: %s.", cpu_model, cpu_cores)

	-- Total + free RAM via host_statistics (vm_stat) — safe approximation
	local ram_total = "?"
	local ram_free  = "?"
	local ok_mem, mem_out = pcall(hs.execute, "sysctl -n hw.memsize 2>/dev/null")
	if ok_mem and type(mem_out) == "string" and mem_out ~= "" then
		local bytes = tonumber(mem_out:match("^%s*(.-)%s*$"))
		if bytes then ram_total = string.format("%.1f GB", bytes / 1073741824) end
	end
	local ok_vm, vm_out = pcall(hs.execute, "vm_stat 2>/dev/null | awk '/Pages free/ {print $3}' | tr -d '.'")
	if ok_vm and type(vm_out) == "string" and vm_out ~= "" then
		local pages = tonumber(vm_out:match("^%s*(.-)%s*$"))
		if pages then ram_free = string.format("%.1f GB", pages * 4096 / 1073741824) end
	end
	info.ram_total = ram_total
	info.ram_free  = ram_free
	Logger.debug(LOG, "ram_total: %s ram_free: %s.", ram_total, ram_free)

	-- Architecture
	local arch = "?"
	local ok_arch, arch_out = pcall(hs.execute, "uname -m 2>/dev/null")
	if ok_arch and type(arch_out) == "string" and arch_out ~= "" then
		arch = arch_out:match("^%s*(.-)%s*$")
	end
	info.arch = arch
	Logger.debug(LOG, "arch: %s.", arch)

	-- Screen DPI (points per inch from Hammerspoon screen info)
	local dpi = "?"
	local ok_dpi, scr_d = pcall(function() return hs.screen.mainScreen() end)
	if ok_dpi and scr_d and type(scr_d.currentMode) == "function" then
		local ok_md, md = pcall(function() return scr_d:currentMode() end)
		if ok_md and md and md.w and md.h then
			-- physicalSize is in mm; derive PPI if available
			if type(scr_d.physicalSize) == "function" then
				local ok_ps, ps = pcall(function() return scr_d:physicalSize() end)
				if ok_ps and ps and ps.w and ps.w > 0 then
					dpi = string.format("%d", math.floor(md.w / (ps.w / 25.4) + 0.5))
				end
			end
			-- Retina scale factor (logical vs native pixels)
			if type(scr_d.frame) == "function" and type(scr_d.fullFrame) == "function" then
				local ok_f, f   = pcall(function() return scr_d:frame() end)
				local ok_ff, ff = pcall(function() return scr_d:fullFrame() end)
				if ok_f and f and ok_ff and ff and f.w and f.w > 0 then
					info.retina_scale = string.format("%.1f×", ff.w / f.w)
				end
			end
		end
	end
	info.dpi = dpi
	Logger.debug(LOG, "dpi: %s.", dpi)

	-- Short git commit hash — run git from this file's directory so it reaches
	-- the actual repo root even when hs.configdir is ~/.hammerspoon (not a repo).
	local _this_dir = (function()
		local src = (debug.getinfo(1, "S") or {}).source or ""
		src = src:gsub("^@", "")
		return src:match("^(.*)[/\\][^/\\]+$") or hs.configdir
	end)()
	local git_hash = "unknown"
	local ok_git, out = pcall(hs.execute, "git -C " .. _this_dir .. " rev-parse --short HEAD 2>/dev/null")
	if ok_git and type(out) == "string" and out ~= "" then
		git_hash = out:match("^%s*(.-)%s*$")
	else
		Logger.warn(LOG, "git rev-parse failed (not a git repo or git not on PATH): %s.", tostring(out))
	end
	info.git_hash = git_hash
	Logger.debug(LOG, "git_hash: %s.", git_hash)

	return info
end

--- === Enriched collectors (maximum completeness, privacy-safe, pcall-protected) ===
-- (Added to make the system diagnostic as complete as possible while staying robust.)

_collect_pause_state = function()
	local st = { is_paused = false, source = "unknown" }
	local ok, sc = pcall(require, "modules.shortcuts.script_control")
	if not ok then
		Logger.warn(LOG, "script_control unavailable: %s.", tostring(sc))
		st.source = "script_control (unavailable)"
	elseif type(sc.is_paused) ~= "function" then
		Logger.warn(LOG, "script_control.is_paused is not a function.")
		st.source = "script_control (contract missing)"
	else
		st.is_paused = not not sc.is_paused()
		st.source = "script_control"
	end
	Logger.debug(LOG, "Pause state: is_paused=%s source=%s.", tostring(st.is_paused), st.source)
	return st
end

_collect_keylogger_summary = function()
	local sum = {
		enabled = "unknown",
		wpm = "n/a",
		events_session = 0,
		privacy_hits = 0,
		today_log = "",
		errors_log = "",
		notes = "High-severity (WARNING/ERROR) also written to dedicated ErgoptiPlus_errors_*.log (see Debug > Open Error Log)",
	}
	local ok_l, logm = pcall(require, "modules.keylogger.log_manager")
	if not ok_l then
		Logger.warn(LOG, "log_manager unavailable: %s.", tostring(logm))
	elseif type(logm.get_paths) ~= "function" then
		Logger.warn(LOG, "log_manager.get_paths is not a function.")
	else
		local p = logm.get_paths() or {}
		sum.today_log  = p.unified or ""
		sum.errors_log = p.errors  or ""
	end
	local ok_a, agg = pcall(require, "modules.keylogger.aggregator")
	if not ok_a then
		Logger.warn(LOG, "keylogger.aggregator unavailable: %s.", tostring(agg))
	elseif type(agg.get_stats) ~= "function" then
		Logger.warn(LOG, "aggregator.get_stats is not a function.")
	else
		local s = agg.get_stats() or {}
		sum.events_session = s.events or sum.events_session
		sum.wpm            = s.wpm    or sum.wpm
	end
	local ok_p, priv = pcall(require, "modules.keylogger.privacy")
	if not ok_p then
		Logger.warn(LOG, "keylogger.privacy unavailable: %s.", tostring(priv))
	elseif type(priv.get_hit_count) ~= "function" then
		Logger.warn(LOG, "privacy.get_hit_count is not a function.")
	else
		sum.privacy_hits = priv.get_hit_count() or 0
	end
	Logger.debug(LOG, "Keylogger: events=%s wpm=%s privacy_hits=%s.",
		tostring(sum.events_session), tostring(sum.wpm), tostring(sum.privacy_hits))
	return sum
end

_collect_llm_state = function()
	local st = { enabled = "unknown", backend = "unknown", active_profile = "unknown", model = "n/a", n_predictions = "n/a", streaming = "n/a" }
	local ok, llm = pcall(require, "modules.llm.init")
	if not ok then
		Logger.warn(LOG, "modules.llm.init unavailable: %s.", tostring(llm))
	elseif type(llm.get_state) ~= "function" then
		Logger.warn(LOG, "llm.get_state is not a function.")
	else
		local s = llm.get_state() or {}
		st.enabled        = tostring(s.llm_enabled       or "unknown")
		st.backend        = s.llm_backend                or st.backend
		st.active_profile = s.llm_active_profile         or st.active_profile
	end
	Logger.debug(LOG, "LLM: enabled=%s backend=%s profile=%s.",
		tostring(st.enabled), tostring(st.backend), tostring(st.active_profile))
	return st
end

_collect_layout_state = function()
	local st = { ergopti_base = "unknown", altgr = "unknown", shift = "unknown", caps = "unknown", prefix_latch = "clean" }
	local ok, lay = pcall(require, "lib.layout")
	if not ok then
		Logger.warn(LOG, "lib.layout unavailable: %s.", tostring(lay))
	elseif type(lay.is_ergopti_base) ~= "function" then
		Logger.warn(LOG, "layout.is_ergopti_base is not a function.")
	else
		st.ergopti_base = lay.is_ergopti_base() and "on" or "off"
	end
	local ok_ks, ks = pcall(require, "adapters.key_state")
	if not ok_ks then
		Logger.warn(LOG, "adapters.key_state unavailable: %s.", tostring(ks))
	else
		if type(ks.get_altgr) == "function" then st.altgr = ks.get_altgr() and "active" or "off"
		else Logger.warn(LOG, "key_state.get_altgr is not a function.") end
		if type(ks.get_shift) == "function" then st.shift = ks.get_shift() and "active" or "off"
		else Logger.warn(LOG, "key_state.get_shift is not a function.") end
		if type(ks.get_caps) == "function" then st.caps = ks.get_caps() and "active" or "off"
		else Logger.warn(LOG, "key_state.get_caps is not a function.") end
	end
	Logger.debug(LOG, "Layout: base=%s altgr=%s shift=%s caps=%s.",
		tostring(st.ergopti_base), tostring(st.altgr), tostring(st.shift), tostring(st.caps))
	return st
end

_collect_hotstrings_state = function()
	local st = { terminators = 0, magic_key = "", personal_count = 0, dynamic_count = 0, default_delay = "n/a" }
	local ok_t, term = pcall(require, "modules.keymap.terminators")
	if not ok_t then
		Logger.warn(LOG, "modules.keymap.terminators unavailable: %s.", tostring(term))
	else
		if type(term.count) == "function" then
			st.terminators = term.count()
		else
			Logger.warn(LOG, "terminators.count is not a function.")
		end
		if type(term.get_magic_key) == "function" then
			st.magic_key = term.get_magic_key() or ""
		else
			Logger.warn(LOG, "terminators.get_magic_key is not a function.")
		end
	end
	Logger.debug(LOG, "Hotstrings: terminators=%d magic_key='%s'.", st.terminators, tostring(st.magic_key))
	return st
end

_collect_logs_info = function()
	local info = {
		unified_today = "",
		errors_today = "",
		errors_sink_active = false,
		ring_lines = 0,
		note = "Dedicated errors sink (WARNING/ERROR only) keeps the main daily log smaller and easier to read.",
	}
	local ok, logm = pcall(require, "modules.keylogger.log_manager")
	if not ok then
		Logger.warn(LOG, "log_manager unavailable for logs_info: %s.", tostring(logm))
	elseif type(logm.get_paths) ~= "function" then
		Logger.warn(LOG, "log_manager.get_paths is not a function.")
	else
		local p = logm.get_paths() or {}
		info.unified_today     = p.unified or ""
		info.errors_today      = p.errors  or ""
		info.errors_sink_active = (p.errors and p.errors ~= "") or false
	end
	-- Logger is already required at module level; re-require only to check ring_buffer_snapshot
	if type(Logger.ring_buffer_snapshot) == "function" then
		local rb = Logger.ring_buffer_snapshot() or {}
		info.ring_lines = #rb
	else
		Logger.warn(LOG, "Logger.ring_buffer_snapshot is not a function.")
	end
	Logger.debug(LOG, "Logs info: ring_lines=%d errors_sink_active=%s.",
		info.ring_lines, tostring(info.errors_sink_active))
	return info
end

_collect_config_summary = function()
	local sum = { overrides = 0, enabled_hotstrings = "n/a", enabled_gestures = "n/a", enabled_llm = "n/a", config_files = {} }
	local cfgdir = hs and hs.configdir or ""
	if cfgdir == "" then
		Logger.warn(LOG, "hs.configdir is empty — cannot locate config files.")
	else
		table.insert(sum.config_files, cfgdir .. "/config.toml")
		table.insert(sum.config_files, cfgdir .. "/tap_hold.toml")
	end
	Logger.debug(LOG, "Config summary: cfgdir='%s' files=%d.", cfgdir, #sum.config_files)
	return sum
end


--- Converts raw seconds to a human-readable uptime string (e.g. "2h 04m 37s").
--- @param sec number Elapsed seconds.
--- @return string
function _format_uptime(sec)
	sec = math.floor(sec or 0)
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	local s = sec % 60
	if h > 0 then
		return string.format("%dh %02dm %02ds", h, m, s)
	elseif m > 0 then
		return string.format("%dm %02ds", m, s)
	else
		return string.format("%ds", s)
	end
end


--- Escapes a string for safe embedding as a JS single-quoted string literal.
--- @param s string Raw value.
--- @return string JS-safe single-quoted literal (including the surrounding quotes).
function _js_str(s)
	s = tostring(s)
	s = s:gsub("\\", "\\\\")
	s = s:gsub("'",  "\\'")
	s = s:gsub("\n", "\\n")
	s = s:gsub("\r", "")
	s = s:gsub("\t", "\\t")
	return "'" .. s .. "'"
end


--- Escapes a string for safe HTML text content.
--- @param s string Raw value.
--- @return string HTML-safe string.
function _he(s)
	s = tostring(s)
	s = s:gsub("&",  "&amp;")
	s = s:gsub("<",  "&lt;")
	s = s:gsub(">",  "&gt;")
	s = s:gsub('"',  "&quot;")
	return s
end


--- Wraps a value in a <code> tag with HTML-escaped content.
--- @param s string Raw value.
--- @return string HTML fragment.
function _hcode(s)
	return "<code>" .. _he(s) .. "</code>"
end


--- Builds a self-contained HTML page directly from the snapshot table.
--- NOTE: All section labels are intentionally in English and must NOT be translated.
--- Diagnostic output is developer-facing — a consistent language makes
--- cross-platform log comparison straightforward. Only the button label (btn_label)
--- is translated, as it is the sole user-facing element.
--- @param snapshot table Result from M.run().
--- @param btn_label string Translated label for the copy-and-close button.
--- @return string Complete HTML document.
_snapshot_to_html = function(snapshot, btn_label)
	local s         = snapshot
	local sys       = s.sys or {}
	local ok_list   = s.ports_validated or {}
	local fail_list = s.failed_adapters or {}
	local total     = #ok_list + #fail_list
	local warn_count = s.warn_count or 0
	local err_count  = s.err_count  or 0
	local issues     = s.recent_issues or {}

	-- CSS — mirrors the Windows healthcheck UI for consistency across platforms
	local css = table.concat({
		"html,body{margin:0;padding:0;height:100%;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:13px;color:#1a1a1a;background:#fff;}",
		-- Scrollable content area with bottom padding so text is never hidden behind the fixed footer
		"#content{padding:16px 20px 70px;overflow-x:hidden;overflow-y:auto;height:100%;box-sizing:border-box;word-break:break-word;}",
		"h1{font-size:1.25em;margin:0 0 .6em;}",
		"h2{font-size:1.05em;margin:1.2em 0 .3em;border-bottom:1px solid #e0e0e0;padding-bottom:.2em;color:#333;}",
		"table{border-collapse:collapse;width:100%;margin:.4em 0 .8em;}",
		"th,td{border:1px solid #e0e0e0;padding:.3em .65em;text-align:left;}",
		"th{background:#f6f6f6;font-weight:600;}",
		"td:first-child{white-space:nowrap;color:#555;font-weight:500;}",
		"ul{margin:.3em 0 .3em 1.2em;padding:0;}li{margin:.2em 0;}",
		"code{background:#f3f3f3;border-radius:3px;padding:.1em .35em;font-family:'SF Mono',Menlo,monospace;font-size:.88em;}",
		"pre{background:#1e1e1e;color:#d4d4d4;border-radius:4px;padding:.7em 1em;overflow-x:hidden;white-space:pre-wrap;word-break:break-all;font-family:'SF Mono',Menlo,monospace;font-size:.82em;line-height:1.45;}",
		-- Fixed footer bar — stays at bottom regardless of scroll position
		"#footer{position:fixed;bottom:0;left:0;right:0;padding:10px 20px;background:#fff;border-top:1px solid #e0e0e0;}",
		"#footer button{display:block;width:100%;padding:7px 20px;font-family:-apple-system,sans-serif;font-size:13px;background:#0078d4;color:#fff;border:none;border-radius:4px;cursor:pointer;}",
		"#footer button:hover{background:#106ebe;}",
		"em{font-style:italic;color:#666;}",
		".ok{color:#1a7f37;font-weight:600;}.fail{color:#cf222e;font-weight:600;}",
	}, "")

	-- System table
	local sys_rows = {
		"<tr><td>ErgoptiPlus version</td><td>" .. _hcode(tostring(s.version)) .. "</td></tr>",
		"<tr><td>Last git commit</td><td>"      .. _hcode(tostring(sys.git_hash or "unknown")) .. "</td></tr>",
		"<tr><td>Uptime</td><td>"               .. _he(_format_uptime(s.uptime_sec)) .. "</td></tr>",
		"<tr><td>Hammerspoon</td><td>"          .. _he(tostring(sys.hs_version or "?")) .. "</td></tr>",
		"<tr><td>macOS</td><td>"                .. _he(tostring(sys.os_version or "?")) .. "</td></tr>",
		"<tr><td>Architecture</td><td>"         .. _he(tostring(sys.arch or "?")) .. "</td></tr>",
		"<tr><td>CPU</td><td>"                  .. _he(tostring(sys.cpu_model or "?")) .. "</td></tr>",
		"<tr><td>Logical cores</td><td>"        .. _he(tostring(sys.cpu_cores or "?")) .. "</td></tr>",
		"<tr><td>Total RAM</td><td>"            .. _he(tostring(sys.ram_total or "?")) .. "</td></tr>",
		"<tr><td>Available RAM</td><td>"        .. _he(tostring(sys.ram_free or "?")) .. "</td></tr>",
		"<tr><td>Screen resolution</td><td>"    .. _he(tostring(sys.screen_res or "?")) .. "</td></tr>",
		"<tr><td>DPI</td><td>"                  .. _he(tostring(sys.dpi or "?")) .. (sys.retina_scale and (" &nbsp;<em>" .. _he(sys.retina_scale) .. " Retina</em>") or "") .. "</td></tr>",
		"<tr><td>Locale</td><td>"               .. _he(tostring(sys.locale or "?")) .. "</td></tr>",
	}
	if sys.config_dir and sys.config_dir ~= "" then
		table.insert(sys_rows, "<tr><td>Config dir</td><td>" .. _hcode(sys.config_dir) .. "</td></tr>")
	end
	local sys_tbl = "<table><tr><th>Field</th><th>Value</th></tr>"
		.. table.concat(sys_rows) .. "</table>"

	-- Session counters table
	local w_count = (warn_count == 0 and "<span class=ok>✅ " or "<span class=fail>❌ ") .. warn_count .. "</span>"
	local e_count = (err_count  == 0 and "<span class=ok>✅ " or "<span class=fail>❌ ") .. err_count  .. "</span>"
	local ctr_tbl = "<table><tr><th>Type</th><th>Count</th></tr>"
		.. "<tr><td>⚠️ Warnings</td><td>" .. w_count .. "</td></tr>"
		.. "<tr><td>🔴 Errors</td><td>"   .. e_count .. "</td></tr>"
		.. "</table>"

	-- Adapters list
	local adap_items = {}
	for _, name in ipairs(ok_list) do
		table.insert(adap_items, "<li><span class=ok>✓</span> " .. _hcode(name) .. "</li>")
	end
	for _, name in ipairs(fail_list) do
		table.insert(adap_items, "<li><span class=fail>✗</span> " .. _hcode(name) .. "</li>")
	end
	local adap_html = "<ul>" .. table.concat(adap_items) .. "</ul>"

	-- Last error
	local last_err_html
	if s.last_error then
		last_err_html = "<pre>" .. _he(s.last_error) .. "</pre>"
	else
		last_err_html = "<em>No error recorded.</em>"
	end

	-- Recent issues
	local issues_html
	if #issues == 0 then
		issues_html = "<em>No warnings or errors since startup.</em>"
	else
		local lines_esc = {}
		for _, l in ipairs(issues) do
			table.insert(lines_esc, _he(l))
		end
		issues_html = "<pre>" .. table.concat(lines_esc, "\n") .. "</pre>"
	end

	-- Enriched runtime sections
	local enriched_html = ""
	if s.pause_state or s.layout or s.llm or s.keylogger or s.hotstrings or s.logs then
		enriched_html = enriched_html .. "<h2>Runtime state</h2><table><tr><th>Field</th><th>Value</th></tr>"
		if s.pause_state then
			local ps = s.pause_state
			local pause_val = ps.is_paused
				and ("<span class=fail>PAUSED</span> (" .. _he(tostring(ps.source or "")) .. ")")
				or  "<span class=ok>running</span>"
			enriched_html = enriched_html .. "<tr><td>Pause / Suspend</td><td>" .. pause_val .. "</td></tr>"
		end
		if s.layout then
			local ly = s.layout
			enriched_html = enriched_html
				.. "<tr><td>Layout base</td><td>"  .. _he(tostring(ly.ergopti_base)) .. "</td></tr>"
				.. "<tr><td>AltGr</td><td>"         .. _he(tostring(ly.altgr))        .. "</td></tr>"
				.. "<tr><td>Shift</td><td>"          .. _he(tostring(ly.shift))        .. "</td></tr>"
				.. "<tr><td>Caps</td><td>"           .. _he(tostring(ly.caps))         .. "</td></tr>"
				.. "<tr><td>Prefix latch</td><td>"   .. _he(tostring(ly.prefix_latch)) .. "</td></tr>"
		end
		if s.llm then
			local ll = s.llm
			enriched_html = enriched_html
				.. "<tr><td>LLM enabled</td><td>"     .. _he(tostring(ll.enabled))        .. "</td></tr>"
				.. "<tr><td>LLM backend</td><td>"     .. _he(tostring(ll.backend))        .. "</td></tr>"
				.. "<tr><td>LLM profile</td><td>"     .. _he(tostring(ll.active_profile)) .. "</td></tr>"
		end
		if s.keylogger then
			local kl = s.keylogger
			enriched_html = enriched_html
				.. "<tr><td>Keylogger events</td><td>" .. _he(tostring(kl.events_session)) .. "</td></tr>"
				.. "<tr><td>WPM</td><td>"              .. _he(tostring(kl.wpm))            .. "</td></tr>"
				.. "<tr><td>Privacy hits</td><td>"     .. _he(tostring(kl.privacy_hits))   .. "</td></tr>"
		end
		if s.hotstrings then
			local ht = s.hotstrings
			enriched_html = enriched_html
				.. "<tr><td>Terminators</td><td>"          .. _he(tostring(ht.terminators))    .. "</td></tr>"
				.. "<tr><td>Personal hotstrings</td><td>"  .. _he(tostring(ht.personal_count)) .. "</td></tr>"
				.. "<tr><td>Dynamic hotstrings</td><td>"   .. _he(tostring(ht.dynamic_count))  .. "</td></tr>"
				.. "<tr><td>Magic key</td><td>"            .. _he(tostring(ht.magic_key))      .. "</td></tr>"
		end
		if s.logs then
			local lg = s.logs
			local log_val = (lg.unified_today and lg.unified_today ~= "") and _hcode(lg.unified_today) or "<em>n/a</em>"
			local err_val = (lg.errors_today  and lg.errors_today  ~= "") and _hcode(lg.errors_today)  or "<em>n/a</em>"
			enriched_html = enriched_html
				.. "<tr><td>Log (unified)</td><td>"     .. log_val                            .. "</td></tr>"
				.. "<tr><td>Log (errors)</td><td>"      .. err_val                            .. "</td></tr>"
				.. "<tr><td>Ring buffer lines</td><td>" .. _he(tostring(lg.ring_lines or 0))  .. "</td></tr>"
		end
		enriched_html = enriched_html .. "</table>"
	end

	return "<!DOCTYPE html><html><head><meta charset='utf-8'>"
		.. "<style>" .. css .. "</style>"
		.. "</head><body>"
		.. "<div id='content'>"
		.. "<h1>System diagnostic</h1>"
		.. "<h2>System</h2>"           .. sys_tbl
		.. "<h2>Session counters</h2>" .. ctr_tbl
		.. enriched_html
		.. "<h2>Adapters (" .. #ok_list .. "/" .. total .. " OK)</h2>" .. adap_html
		.. "<h2>Last recorded error</h2>" .. last_err_html
		.. "<h2>Recent warnings / errors (" .. #issues .. "/100)</h2>" .. issues_html
		.. "</div>"
		.. "<div id='footer'><button id='btnCopy'>" .. _he(btn_label) .. "</button></div>"
		.. "</body></html>"
end

return M
