--- ui/healthcheck/helpers.lua

--- ==============================================================================
--- MODULE: Healthcheck Helpers
--- DESCRIPTION:
--- State-gathering probes and snapshot rendering for the healthcheck diagnostic.
--- Extracted from the former monolithic lib/healthcheck.lua (audit F2) so the
--- macOS driver mirrors the Windows ui/healthcheck/{init,core,helpers} layout.
---
--- FEATURES & RATIONALE:
--- 1. System probe: H.sys_info() captures macOS/Hammerspoon versions, CPU, RAM,
---    screen, locale, git hash — every field guarded with pcall so a single OS
---    call failure degrades to "?" instead of aborting the snapshot.
--- 2. Enriched collectors: one pcall-protected collector per runtime subsystem
---    (pause, keylogger, LLM, layout, hotstrings, logs, config) so a broken probe
---    cannot abort the whole healthcheck.
--- 3. Rendering: H.snapshot_to_html() turns a snapshot into a self-contained HTML
---    report; H.format_uptime/H.he/H.hcode are the small pure formatters it uses.
---    All diagnostic labels are in English (developer-facing, not translated).
---
--- This module returns a table H of pure-ish functions (Logger is the only shared
--- dependency). It never reaches back into core — the dependency edge is strictly
--- core → helpers, so the two files can be reasoned about independently.
--- ==============================================================================

local H = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "healthcheck"





--- ============================================
--- ===========================================
--- ======= 1/ System Information Probe =======
--- ===========================================
--- ============================================

--- Collects OS/runtime/screen fields into a flat table.
--- @return table
function H.sys_info()
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





--- ====================================================
--- ====================================================
--- ======= 2/ Enriched Runtime State Collectors =======
--- ====================================================
--- ====================================================

--- === Enriched collectors (maximum completeness, privacy-safe, pcall-protected) ===
-- (Added to make the system diagnostic as complete as possible while staying robust.)

function H.collect_pause_state()
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

function H.collect_keylogger_summary()
	-- events_session / privacy_hits have no public accessor today, so they are
	-- reported as "n/a" rather than probed against a nonexistent function. WPM is
	-- live from the keylogger; the log paths are the logger's canonical constants.
	local sum = {
		enabled = "unknown",
		wpm = "n/a",
		events_session = "n/a",
		privacy_hits = "n/a",
		today_log = Logger.UNIFIED_LOG_FILE or "",
		errors_log = Logger.ERRORS_LOG_FILE or "",
		notes = "High-severity (WARNING/ERROR) also written to dedicated ErgoptiPlus_errors_*.log (see Debug > Open Error Log)",
	}
	local ok_k, kl = pcall(require, "modules.keylogger")
	if not ok_k then
		Logger.warn(LOG, "modules.keylogger unavailable: %s.", tostring(kl))
	elseif type(kl.get_live_stats) ~= "function" then
		Logger.warn(LOG, "keylogger.get_live_stats is not a function.")
	else
		local st = kl.get_live_stats() or {}
		if st.wpm ~= nil then sum.wpm = st.wpm end
	end
	Logger.debug(LOG, "Keylogger: wpm=%s unified='%s' errors='%s'.",
		tostring(sum.wpm), tostring(sum.today_log), tostring(sum.errors_log))
	return sum
end

function H.collect_llm_state()
	local st = { enabled = "unknown", backend = "unknown", active_profile = "unknown", model = "n/a", n_predictions = "n/a", streaming = "n/a" }
	local ok, llm = pcall(require, "modules.llm.init")
	if not ok then
		Logger.warn(LOG, "modules.llm.init unavailable: %s.", tostring(llm))
	else
		if type(llm.get_runtime_llm_enabled) == "function" then
			st.enabled = tostring(llm.get_runtime_llm_enabled())
		else
			Logger.warn(LOG, "llm.get_runtime_llm_enabled is not a function.")
		end
		if type(llm.get_backend) == "function" then
			st.backend = llm.get_backend() or st.backend
		else
			Logger.warn(LOG, "llm.get_backend is not a function.")
		end
		if type(llm.get_active_profile) == "function" then
			st.active_profile = llm.get_active_profile() or st.active_profile
		else
			Logger.warn(LOG, "llm.get_active_profile is not a function.")
		end
	end
	Logger.debug(LOG, "LLM: enabled=%s backend=%s profile=%s.",
		tostring(st.enabled), tostring(st.backend), tostring(st.active_profile))
	return st
end

function H.collect_layout_state()
	-- ergopti_base (active-layout detection) and caps (capslock) have no runtime
	-- accessor — checkKeyboardModifiers only exposes shift/ctrl/alt/cmd/fn — so
	-- they stay "n/a" instead of probing a function that does not exist. altgr and
	-- shift are read live through the key_state adapter's real API.
	local st = { ergopti_base = "n/a", altgr = "unknown", shift = "unknown", caps = "n/a", prefix_latch = "clean" }
	local ok_ks, ks = pcall(require, "adapters.key_state")
	if not ok_ks then
		Logger.warn(LOG, "adapters.key_state unavailable: %s.", tostring(ks))
	else
		if type(ks.is_right_altgr_held) == "function" then st.altgr = ks.is_right_altgr_held() and "active" or "off"
		else Logger.warn(LOG, "key_state.is_right_altgr_held is not a function.") end
		if type(ks.isDown) == "function" then st.shift = ks.isDown("shift") and "active" or "off"
		else Logger.warn(LOG, "key_state.isDown is not a function.") end
	end
	Logger.debug(LOG, "Layout: altgr=%s shift=%s.", tostring(st.altgr), tostring(st.shift))
	return st
end

function H.collect_hotstrings_state()
	local st = { terminators = 0, magic_key = "", personal_count = 0, dynamic_count = 0, default_delay = "n/a" }
	local ok_t, term = pcall(require, "modules.keymap.terminators")
	if not ok_t then
		Logger.warn(LOG, "modules.keymap.terminators unavailable: %s.", tostring(term))
	elseif type(term.get_terminator_defs) ~= "function" then
		Logger.warn(LOG, "terminators.get_terminator_defs is not a function.")
	else
		local defs = term.get_terminator_defs() or {}
		local n = 0
		for _ in pairs(defs) do n = n + 1 end
		st.terminators = n
	end
	-- The magic key is the keymap's trigger char (owned by the registry).
	local ok_km, km = pcall(require, "modules.keymap")
	if not ok_km then
		Logger.warn(LOG, "modules.keymap unavailable: %s.", tostring(km))
	elseif type(km.get_trigger_char) ~= "function" then
		Logger.warn(LOG, "keymap.get_trigger_char is not a function.")
	else
		st.magic_key = km.get_trigger_char() or ""
	end
	Logger.debug(LOG, "Hotstrings: terminators=%d magic_key='%s'.", st.terminators, tostring(st.magic_key))
	return st
end

function H.collect_logs_info()
	local info = {
		unified_today = "",
		errors_today = "",
		errors_sink_active = false,
		ring_lines = 0,
		note = "Dedicated errors sink (WARNING/ERROR only) keeps the main daily log smaller and easier to read.",
	}
	-- Canonical log file paths live on the logger module as public constants,
	-- re-pointed at the dated files by Logger.init_log_path() during boot.
	info.unified_today      = Logger.UNIFIED_LOG_FILE or ""
	info.errors_today       = Logger.ERRORS_LOG_FILE or ""
	info.errors_sink_active = (info.errors_today ~= "")
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

function H.collect_config_summary()
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





--- ==============================================
--- ==============================================
--- ======= 3/ Formatters & HTML Rendering =======
--- ==============================================
--- ==============================================

--- Converts raw seconds to a human-readable uptime string (e.g. "2h 04m 37s").
--- @param sec number Elapsed seconds.
--- @return string
function H.format_uptime(sec)
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


--- Escapes a string for safe HTML text content.
--- @param s string Raw value.
--- @return string HTML-safe string.
function H.he(s)
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
function H.hcode(s)
	return "<code>" .. H.he(s) .. "</code>"
end


--- Builds a self-contained HTML page directly from the snapshot table.
--- NOTE: All section labels are intentionally in English and must NOT be translated.
--- Diagnostic output is developer-facing — a consistent language makes
--- cross-platform log comparison straightforward. Only the button label (btn_label)
--- is translated, as it is the sole user-facing element.
--- @param snapshot table Result from M.run().
--- @param btn_label string Translated label for the copy-and-close button.
--- @return string Complete HTML document.
function H.snapshot_to_html(snapshot, btn_label)
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
		"<tr><td>ErgoptiPlus version</td><td>" .. H.hcode(tostring(s.version)) .. "</td></tr>",
		"<tr><td>Last git commit</td><td>"      .. H.hcode(tostring(sys.git_hash or "unknown")) .. "</td></tr>",
		"<tr><td>Uptime</td><td>"               .. H.he(H.format_uptime(s.uptime_sec)) .. "</td></tr>",
		"<tr><td>Hammerspoon</td><td>"          .. H.he(tostring(sys.hs_version or "?")) .. "</td></tr>",
		"<tr><td>macOS</td><td>"                .. H.he(tostring(sys.os_version or "?")) .. "</td></tr>",
		"<tr><td>Architecture</td><td>"         .. H.he(tostring(sys.arch or "?")) .. "</td></tr>",
		"<tr><td>CPU</td><td>"                  .. H.he(tostring(sys.cpu_model or "?")) .. "</td></tr>",
		"<tr><td>Logical cores</td><td>"        .. H.he(tostring(sys.cpu_cores or "?")) .. "</td></tr>",
		"<tr><td>Total RAM</td><td>"            .. H.he(tostring(sys.ram_total or "?")) .. "</td></tr>",
		"<tr><td>Available RAM</td><td>"        .. H.he(tostring(sys.ram_free or "?")) .. "</td></tr>",
		"<tr><td>Screen resolution</td><td>"    .. H.he(tostring(sys.screen_res or "?")) .. "</td></tr>",
		"<tr><td>DPI</td><td>"                  .. H.he(tostring(sys.dpi or "?")) .. (sys.retina_scale and (" &nbsp;<em>" .. H.he(sys.retina_scale) .. " Retina</em>") or "") .. "</td></tr>",
		"<tr><td>Locale</td><td>"               .. H.he(tostring(sys.locale or "?")) .. "</td></tr>",
	}
	if sys.config_dir and sys.config_dir ~= "" then
		table.insert(sys_rows, "<tr><td>Config dir</td><td>" .. H.hcode(sys.config_dir) .. "</td></tr>")
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
		table.insert(adap_items, "<li><span class=ok>✓</span> " .. H.hcode(name) .. "</li>")
	end
	for _, name in ipairs(fail_list) do
		table.insert(adap_items, "<li><span class=fail>✗</span> " .. H.hcode(name) .. "</li>")
	end
	local adap_html = "<ul>" .. table.concat(adap_items) .. "</ul>"

	-- Last error
	local last_err_html
	if s.last_error then
		last_err_html = "<pre>" .. H.he(s.last_error) .. "</pre>"
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
			table.insert(lines_esc, H.he(l))
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
				and ("<span class=fail>PAUSED</span> (" .. H.he(tostring(ps.source or "")) .. ")")
				or  "<span class=ok>running</span>"
			enriched_html = enriched_html .. "<tr><td>Pause / Suspend</td><td>" .. pause_val .. "</td></tr>"
		end
		if s.layout then
			local ly = s.layout
			enriched_html = enriched_html
				.. "<tr><td>Layout base</td><td>"  .. H.he(tostring(ly.ergopti_base)) .. "</td></tr>"
				.. "<tr><td>AltGr</td><td>"         .. H.he(tostring(ly.altgr))        .. "</td></tr>"
				.. "<tr><td>Shift</td><td>"          .. H.he(tostring(ly.shift))        .. "</td></tr>"
				.. "<tr><td>Caps</td><td>"           .. H.he(tostring(ly.caps))         .. "</td></tr>"
				.. "<tr><td>Prefix latch</td><td>"   .. H.he(tostring(ly.prefix_latch)) .. "</td></tr>"
		end
		if s.llm then
			local ll = s.llm
			enriched_html = enriched_html
				.. "<tr><td>LLM enabled</td><td>"     .. H.he(tostring(ll.enabled))        .. "</td></tr>"
				.. "<tr><td>LLM backend</td><td>"     .. H.he(tostring(ll.backend))        .. "</td></tr>"
				.. "<tr><td>LLM profile</td><td>"     .. H.he(tostring(ll.active_profile)) .. "</td></tr>"
		end
		if s.keylogger then
			local kl = s.keylogger
			enriched_html = enriched_html
				.. "<tr><td>Keylogger events</td><td>" .. H.he(tostring(kl.events_session)) .. "</td></tr>"
				.. "<tr><td>WPM</td><td>"              .. H.he(tostring(kl.wpm))            .. "</td></tr>"
				.. "<tr><td>Privacy hits</td><td>"     .. H.he(tostring(kl.privacy_hits))   .. "</td></tr>"
		end
		if s.hotstrings then
			local ht = s.hotstrings
			enriched_html = enriched_html
				.. "<tr><td>Terminators</td><td>"          .. H.he(tostring(ht.terminators))    .. "</td></tr>"
				.. "<tr><td>Personal hotstrings</td><td>"  .. H.he(tostring(ht.personal_count)) .. "</td></tr>"
				.. "<tr><td>Dynamic hotstrings</td><td>"   .. H.he(tostring(ht.dynamic_count))  .. "</td></tr>"
				.. "<tr><td>Magic key</td><td>"            .. H.he(tostring(ht.magic_key))      .. "</td></tr>"
		end
		if s.logs then
			local lg = s.logs
			local log_val = (lg.unified_today and lg.unified_today ~= "") and H.hcode(lg.unified_today) or "<em>n/a</em>"
			local err_val = (lg.errors_today  and lg.errors_today  ~= "") and H.hcode(lg.errors_today)  or "<em>n/a</em>"
			enriched_html = enriched_html
				.. "<tr><td>Log (unified)</td><td>"     .. log_val                            .. "</td></tr>"
				.. "<tr><td>Log (errors)</td><td>"      .. err_val                            .. "</td></tr>"
				.. "<tr><td>Ring buffer lines</td><td>" .. H.he(tostring(lg.ring_lines or 0))  .. "</td></tr>"
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
		.. "<div id='footer'><button id='btnCopy'>" .. H.he(btn_label) .. "</button></div>"
		.. "</body></html>"
end

return H
