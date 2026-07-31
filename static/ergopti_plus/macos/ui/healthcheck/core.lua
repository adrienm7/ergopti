--- ui/healthcheck/core.lua

--- ==============================================================================
--- MODULE: Healthcheck Core
--- DESCRIPTION:
--- The healthcheck probe, public API, and report window. Extracted from the
--- former monolithic lib/healthcheck.lua (audit F2) so the macOS driver mirrors
--- the Windows ui/healthcheck/{init,core,helpers} layout.
---
--- FEATURES & RATIONALE:
--- 1. Adapter probing: iterates the canonical adapter list, attempts a require()
---    for each module, and verifies the presence of its public contract methods —
---    without side effects.
--- 2. Port validation: records pass/fail per adapter contract.
--- 3. Last error capture: reads the last Logger ERROR entry stored in module
---    state so callers can surface the most recent failure without parsing logs.
--- 4. Uptime: computes seconds since the module was first required.
--- 5. Snapshot assembly: M.run() gathers system info, session counters, and the
---    enriched runtime collectors (delegated to ui.healthcheck.helpers) into one
---    table.
--- 6. Selectable window: M.show_window() loads the shared frontend at
---    _shared/ui/healthcheck/ via ui_builder.build_injected_html(), then injects
---    the snapshot as JSON — the client-side script.js renders the report.
---    All diagnostic labels are in English (developer-facing, not translated).
---
--- The state-gathering probes live in ui.healthcheck.helpers; the HTML rendering
--- is the shared _shared/ui/healthcheck/ frontend.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("lib.logger")
local H        = require("ui.healthcheck.helpers")
local Paths    = require("lib.paths")
local Snapshot = require("healthcheck.snapshot")

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





--- ==========================================
--- ==========================================
--- ======= 1/ Adapter & Port Registry =======
--- ==========================================
--- ==========================================

-- Each entry: { id = "require.path", contract = { "method1", "method2", … }, wired = bool }
-- Contract methods are the minimal public surface that must be present for the
-- adapter to be considered operational.
--
-- `wired` records whether at least one non-test, non-healthcheck production file
-- actually calls require() on this adapter (audit F-HIGH-10). A contract-healthy
-- adapter that is NOT wired can load fine and expose every method yet still be
-- completely unreachable from any real feature — the migration onto the port/
-- adapter architecture is incomplete for it. Keeping this flag in lock-step with
-- reality is enforced by tests/meta/test_adapter_wiring_reachability.lua, which
-- greps production sources for a require("adapters.<id>") call site and fails if
-- the flag disagrees with what it finds.
local ADAPTER_SPECS = {
	{
		id       = "adapters.app_launcher",
		contract = { "launch", "launchWithArgs", "isRunning" },
		wired    = true,
	},
	{
		id       = "adapters.clipboard",
		contract = { "read", "write" },
		wired    = true,
	},
	{
		id       = "adapters.crypto",
		contract = { "sha256" },
		wired    = true,
	},
	{
		id       = "adapters.event_tap_guard",
		contract = { "handle_disabled" },
		wired    = true,
	},
	{
		id       = "adapters.file_system",
		contract = { "read", "write", "exists" },
		wired    = true,
	},
	{
		id       = "adapters.graphics_renderer",
		contract = { "createWindow", "destroyWindow", "drawBitmap", "show", "hide" },
		wired    = true,
	},
	{
		id       = "adapters.http_client",
		contract = { "get", "post" },
		wired    = true,
	},
	{
		id       = "adapters.json_codec",
		contract = { "encode", "decode" },
		wired    = true,
	},
	{
		id       = "adapters.key_state",
		contract = { "isDown", "isUp" },
		wired    = true,
	},
	{
		id       = "adapters.keyboard_hook",
		contract = { "start", "stop" },
		wired    = true,
	},
	{
		id       = "adapters.mouse_control",
		contract = { "setPos", "getPos" },
		wired    = true,
	},
	{
		id       = "adapters.network_info",
		contract = { "getSsidHash", "getSignalStrength", "isInternetReachable", "isVpnActive" },
		wired    = true,
	},
	{
		id       = "adapters.notifier",
		contract = { "send" },
		wired    = true,
	},
	{
		id       = "adapters.process_lifecycle",
		contract = { "start", "stop" },
		wired    = true,
	},
	{
		id       = "adapters.secure_field_detector",
		contract = { "isSecureField", "isSecureApp", "refresh" },
		wired    = true,
	},
	{
		id       = "adapters.shell_runner",
		contract = { "exec", "spawn" },
		wired    = true,
	},
	{
		id       = "adapters.storage",
		contract = { "get", "set" },
		wired    = true,
	},
	{
		id       = "adapters.text_sender",
		contract = { "send" },
		wired    = true,
	},
	{
		id       = "adapters.timer_scheduler",
		contract = { "after", "every" },
		wired    = true,
	},
	{
		id       = "adapters.toml_cache",
		contract = { "init", "load", "store", "stats" },
		wired    = true,
	},
	{
		id       = "adapters.tooltip_renderer",
		contract = { "show", "hide" },
		wired    = true,
	},
	{
		id       = "adapters.tray_menu",
		contract = { "setIcon", "setMenu", "setTooltip", "destroy" },
		wired    = true,
	},
	{
		id       = "adapters.window_info",
		contract = { "getFocused", "getAll" },
		wired    = true,
	},
	{
		id       = "adapters.window_manager",
		contract = { "activate", "exists", "kill", "getList" },
		wired    = true,
	},
}





--- =============================
--- =============================
--- ======= 2/ Public API =======
--- =============================
--- =============================

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
	local wired_count      = 0
	local unwired_adapters = {}

	for _, spec in ipairs(ADAPTER_SPECS) do
		if spec.wired then wired_count = wired_count + 1 else table.insert(unwired_adapters, spec.id) end

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
	local all_lines = Logger.ring_buffer_snapshot()
	if not all_lines then
		Logger.error(LOG, "Logger.ring_buffer_snapshot() returned nil — ring buffer unavailable.")
		all_lines = {}
	end
	local warn_count, err_count = Snapshot.count_issues(all_lines)
	local recent_issues         = Snapshot.extract_recent_issues(all_lines, 100)
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
		version          = version,
		loaded_adapters  = loaded_adapters,
		ports_validated  = ports_validated,
		failed_adapters  = failed_adapters,
		wired_count      = wired_count,
		adapter_count    = #ADAPTER_SPECS,
		unwired_adapters = unwired_adapters,
		last_error       = _last_error,
		uptime_sec       = uptime_sec,
		warn_count       = warn_count,
		err_count        = err_count,
		recent_issues    = recent_issues,
		sys              = safe_collect("sys_info",            H.sys_info),
		pause_state      = safe_collect("pause_state",         H.collect_pause_state),
		keylogger        = safe_collect("keylogger_summary",   H.collect_keylogger_summary),
		llm              = safe_collect("llm_state",           H.collect_llm_state),
		layout           = safe_collect("layout_state",        H.collect_layout_state),
		hotstrings       = safe_collect("hotstrings_state",    H.collect_hotstrings_state),
		logs             = safe_collect("logs_info",           H.collect_logs_info),
		config           = safe_collect("config_summary",      H.collect_config_summary),
	}

	Logger.success(LOG, "Healthcheck complete — %d/%d adapter(s) wired, %d contract-healthy, %d failed, uptime %ds.",
		wired_count, #ADAPTER_SPECS, #ports_validated, #failed_adapters, uptime_sec)

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

	-- Build the self-contained HTML from the shared frontend (inlines CSS + JS).
	local shared_ui_dir = (Paths.shared("ui/healthcheck") or "") .. "/"
	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui or not ui_builder then
		Logger.error(LOG, "ui.ui_builder unavailable — falling back to text alert: %s.", tostring(ui_builder))
		local ok_d, dialog = pcall(require, "lib.dialog_util")
		if ok_d and dialog then
			dialog.block_alert(title, plain, "OK")
		end
		return
	end
	local ok_html, html = pcall(ui_builder.build_injected_html, shared_ui_dir)
	if not ok_html or not html then
		Logger.error(LOG, "build_injected_html() failed: %s.", tostring(html))
		local ok_d, dialog = pcall(require, "lib.dialog_util")
		if ok_d and dialog then
			dialog.block_alert(title, plain, "OK")
		end
		return
	end

	-- Encode the snapshot as JSON for client-side rendering.
	local ok_enc, snapshot_json = pcall(hs.json.encode, snapshot)
	if not ok_enc or not snapshot_json then
		Logger.error(LOG, "hs.json.encode() failed: %s.", tostring(snapshot_json))
		local ok_d, dialog = pcall(require, "lib.dialog_util")
		if ok_d and dialog then
			dialog.block_alert(title, plain, "OK")
		end
		return
	end
	local render_js = "if(window.renderHealthcheck)window.renderHealthcheck(" .. snapshot_json .. ")"

	local ok_scr, screen = pcall(function() return hs.screen.mainScreen() end)
	if not ok_scr or not screen then
		Logger.warn(LOG, "hs.screen.mainScreen() failed — using default frame.")
	end
	local sf = (ok_scr and screen and type(screen.frame) == "function" and screen:frame())
		or { x = 0, y = 0, w = 1440, h = 900 }

	-- Geometry comes from _shared/ui/apps.manifest.json (SSoT). This window used
	-- to hardcode 700x600 while Windows opened the same diagnostic at the
	-- manifest's 740x560 — the drift the manifest exists to prevent, invisible
	-- because the geometry gate had no entry for the macOS healthcheck.
	local geo = ui_builder.get_app_geometry("healthcheck")
	if not geo then
		Logger.error(LOG, "No geometry for 'healthcheck' in apps.manifest.json — cannot open the window.")
		return
	end
	local frame = {
		x = math.floor(sf.x + (sf.w - geo.width) / 2),
		y = math.floor(sf.y + (sf.h - geo.height) / 2),
		w = geo.width,
		h = geo.height,
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
				-- Render the report from the snapshot JSON, then wire the
				-- copy button (injected into the page after render).
				local ok_js, js_err = pcall(function()
					wv:evaluateJavaScript(
						render_js .. ";"
						.. "window.__hs_copy_requested = false;"
						.. "(function(){"
						.. "var b=document.getElementById('btnCopy');"
						.. "if(!b){b=document.createElement('button');b.id='btnCopy';"
						.. "b.textContent='" .. btn_label:gsub("\\", "\\\\"):gsub("'", "\\'") .. "';"
						.. "b.style.cssText='display:block;width:100%;padding:7px 20px;"
						.. "font-family:-apple-system,sans-serif;font-size:13px;"
						.. "background:#0078d4;color:#fff;border:none;border-radius:4px;cursor:pointer;';"
						.. "var f=document.createElement('div');f.id='footer';"
						.. "f.style.cssText='position:fixed;bottom:0;left:0;right:0;"
						.. "padding:10px 20px;background:#fff;border-top:1px solid #e0e0e0;';"
						.. "f.appendChild(b);document.body.appendChild(f);}"
						.. "b.onclick=function(){window.__hs_copy_requested=true;};"
						.. "})();"
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
					-- Wrap in pcall: a natively-closed webview is NOT nil in Lua but
					-- becomes "dead userdata" — a stale Lua handle whose backing C object
					-- is gone. :evaluateJavaScript() on a dead userdata raises a runtime
					-- error every 200 ms until Hammerspoon is force-quit
					-- (healthcheck-webview-dead-userdata).
					local ok_ev, ev_err = pcall(function()
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
					if not ok_ev then
						Logger.warn(LOG, "evaluateJavaScript on dead webview — stopping poll: %s.", tostring(ev_err))
						_stop_poll()
					end
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
	table.insert(lines, string.format("Uptime           : %s", H.format_uptime(s.uptime_sec)))
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

	local ok_list      = s.ports_validated  or {}
	local fail_list    = s.failed_adapters  or {}
	local unwired_list = s.unwired_adapters or {}
	-- "Contract-healthy" (all methods present) is NOT the same claim as "reachable
	-- from a real feature" — an unwired adapter can be 100% contract-healthy while
	-- no production code ever calls it (audit F-HIGH-10). Report both numbers so
	-- this window can never again imply full coverage when it is not the case.
	table.insert(lines, string.format("Adapters: %d/%d wired, %d/%d contract-healthy",
		s.wired_count or 0, s.adapter_count or 0, #ok_list, s.adapter_count or 0))
	table.insert(lines, string.format("Contract-healthy (%d):", #ok_list))
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
	if #unwired_list > 0 then
		table.insert(lines, string.format("Unwired (%d) — no production call site yet:", #unwired_list))
		for _, name in ipairs(unwired_list) do
			table.insert(lines, "  ~ " .. name)
		end
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

return M
