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
--- 5. System info: captures macOS version, Hammerspoon version, screen resolution,
---    locale, and config path for a complete at-a-glance snapshot.
--- 6. Selectable window: M.show_window() renders the report in an hs.webview so
---    the user can select and copy any part of the diagnostic text.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "healthcheck"

-- Module load timestamp — used to approximate driver uptime.
local _load_time = os.time()

-- Last error captured by M.record_error(); reset to nil on each M.run() call.
local _last_error = nil

-- Reference to the currently open webview window (singleton — one at a time).
local _window = nil




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
		sys             = _sys_info(),
	}

	Logger.success(LOG, "Healthcheck complete — %d adapter(s) OK, %d failed, uptime %ds.",
		#ports_validated, #failed_adapters, uptime_sec)

	return result
end


--- Formats a healthcheck result table as a Markdown string for WebView rendering.
--- Calls M.run() internally if no snapshot is provided.
--- @param snapshot table|nil Result from M.run(), or nil to run fresh.
--- @return string Formatted Markdown diagnostic string.
function M.format(snapshot)
	local s   = snapshot or M.run()
	local sys = s.sys or {}

	local lines = {}

	-- Header
	table.insert(lines, "# Diagnostic système — ErgoptiPlus")
	table.insert(lines, "")

	-- System info table
	table.insert(lines, "## Système")
	table.insert(lines, "")
	table.insert(lines, "| Champ | Valeur |")
	table.insert(lines, "|---|---|")
	table.insert(lines, "| Version ErgoptiPlus | `" .. tostring(s.version) .. "` |")
	table.insert(lines, "| Durée de fonctionnement | " .. _format_uptime(s.uptime_sec) .. " |")
	table.insert(lines, "| Hammerspoon | " .. tostring(sys.hs_version or "?") .. " |")
	table.insert(lines, "| macOS | " .. tostring(sys.os_version or "?") .. " |")
	table.insert(lines, "| Résolution écran | " .. tostring(sys.screen_res or "?") .. " |")
	table.insert(lines, "| Locale | " .. tostring(sys.locale or "?") .. " |")
	if sys.config_dir and sys.config_dir ~= "" then
		table.insert(lines, "| Dossier config | `" .. sys.config_dir .. "` |")
	end
	table.insert(lines, "")

	-- Adapter status
	local ok_list   = s.ports_validated or {}
	local fail_list = s.failed_adapters or {}
	local total     = #ok_list + #fail_list

	table.insert(lines, "## Adaptateurs (" .. #ok_list .. "/" .. total .. " OK)")
	table.insert(lines, "")
	for _, name in ipairs(ok_list) do
		table.insert(lines, "- ✓ `" .. name .. "`")
	end
	for _, name in ipairs(fail_list) do
		table.insert(lines, "- ✗ `" .. name .. "`")
	end
	table.insert(lines, "")

	-- Last error
	table.insert(lines, "## Dernière erreur")
	table.insert(lines, "")
	if s.last_error then
		table.insert(lines, "```")
		table.insert(lines, s.last_error)
		table.insert(lines, "```")
	else
		table.insert(lines, "_Aucune erreur enregistrée._")
	end

	return table.concat(lines, "\n")
end


--- Opens a dedicated webview window displaying the healthcheck report.
--- Text is fully selectable and copyable. Re-uses the existing window if already open.
function M.show_window()
	-- Close any stale window before rebuilding
	if _window then
		pcall(function() _window:delete() end)
		_window = nil
	end

	local snapshot = M.run()
	local md       = M.format(snapshot)
	local html     = _make_html(md)

	local i18n_ok, i18n = pcall(require, "lib.i18n")
	local title = (i18n_ok and type(i18n) == "table" and type(i18n.get) == "function")
		and i18n.get("menu.debug.healthcheck")
		or "Diagnostic système"

	local screen = hs.screen.mainScreen()
	local sf     = screen and type(screen.frame) == "function" and screen:frame()
		or { x = 0, y = 0, w = 1440, h = 900 }

	local W, H = 700, 560
	local frame = {
		x = math.floor(sf.x + (sf.w - W) / 2),
		y = math.floor(sf.y + (sf.h - H) / 2),
		w = W,
		h = H,
	}

	local ok_wv, wv = pcall(hs.webview.new, frame, { developerExtrasEnabled = false })
	if not ok_wv or not wv then
		Logger.error(LOG, "Failed to create healthcheck webview: %s.", tostring(wv))
		-- Last-resort fallback: blocking alert (non-selectable but always works)
		pcall(hs.focus)
		hs.dialog.blockAlert(title, M.format_plain(snapshot), "OK")
		return
	end

	local masks = hs.webview.windowMasks
	pcall(function()
		wv:windowStyle((masks["titled"] or 1) + (masks["closable"] or 2) + (masks["miniaturizable"] or 4))
	end)
	pcall(function() wv:windowTitle(title) end)
	pcall(function() wv:allowTextEntry(true) end)
	pcall(function() wv:allowNewWindows(false) end)
	pcall(function() wv:level(hs.drawing.windowLevels.normal) end)

	pcall(function()
		wv:windowCallback(function(action)
			if action == "closing" or action == "closed" then
				_window = nil
			end
		end)
	end)

	pcall(function() wv:html(html) end)
	pcall(function() wv:show() end)

	-- Bring to front after a short delay so WebKit finishes compositing
	hs.timer.doAfter(0.08, function()
		pcall(hs.focus)
		local ok_win, win = pcall(function() return wv:hswindow() end)
		if ok_win and win and type(win.focus) == "function" then
			pcall(function() win:focus() end)
		else
			pcall(function() wv:bringToFront() end)
		end
	end)

	_window = wv
end


--- Formats a snapshot as plain text (used as last-resort fallback when webview fails).
--- @param snapshot table|nil Result from M.run(), or nil to run fresh.
--- @return string Plain-text diagnostic string.
function M.format_plain(snapshot)
	local s   = snapshot or M.run()
	local sys = s.sys or {}

	local lines = {}
	table.insert(lines, "=== ErgoptiPlus — Diagnostic système ===")
	table.insert(lines, "")
	table.insert(lines, string.format("Version     : %s", s.version))
	table.insert(lines, string.format("Uptime      : %s", _format_uptime(s.uptime_sec)))
	table.insert(lines, string.format("Hammerspoon : %s", tostring(sys.hs_version or "?")))
	table.insert(lines, string.format("macOS       : %s", tostring(sys.os_version or "?")))
	table.insert(lines, string.format("Résolution  : %s", tostring(sys.screen_res or "?")))
	table.insert(lines, string.format("Locale      : %s", tostring(sys.locale or "?")))
	if sys.config_dir and sys.config_dir ~= "" then
		table.insert(lines, string.format("Config dir  : %s", sys.config_dir))
	end
	table.insert(lines, "")

	local ok_list   = s.ports_validated or {}
	local fail_list = s.failed_adapters or {}

	table.insert(lines, string.format("Adaptateurs OK (%d) :", #ok_list))
	for _, name in ipairs(ok_list) do
		table.insert(lines, "  ✓ " .. name)
	end

	if #fail_list > 0 then
		table.insert(lines, string.format("Échecs (%d) :", #fail_list))
		for _, name in ipairs(fail_list) do
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




-- ============================================
-- ============================================
-- ======= 3/ Internal Helpers ===============
-- ============================================
-- ============================================

--- Collects OS/runtime/screen fields into a flat table.
--- @return table
function _sys_info()
	local info = {}

	-- Hammerspoon version
	local hs_ver = "?"
	if hs and hs.processInfo and type(hs.processInfo) == "table" then
		local v = hs.processInfo.version
		if type(v) == "string" and v ~= "" then hs_ver = v end
	end
	info.hs_version = hs_ver

	-- macOS version
	local os_ver = "?"
	local ok_host, hs_host = pcall(require, "hs.host")
	if ok_host and hs_host and type(hs_host.operatingSystemVersionString) == "function" then
		local ok_v, v = pcall(hs_host.operatingSystemVersionString)
		if ok_v and type(v) == "string" then os_ver = v end
	end
	info.os_version = os_ver

	-- Primary screen resolution
	local res = "?"
	local ok_scr, scr = pcall(function() return hs.screen.mainScreen() end)
	if ok_scr and scr and type(scr.currentMode) == "function" then
		local ok_m, m = pcall(function() return scr:currentMode() end)
		if ok_m and m and m.w and m.h then
			res = m.w .. "×" .. m.h
		end
	end
	info.screen_res = res

	-- System locale
	local locale = "?"
	if ok_host and hs_host and type(hs_host.locale) == "function" then
		local ok_l, l = pcall(hs_host.locale)
		if ok_l and type(l) == "string" then locale = l end
	end
	info.locale = locale

	-- Config directory (Hammerspoon config path)
	local config_dir = ""
	if hs and type(hs.configdir) == "string" then
		config_dir = hs.configdir
	end
	info.config_dir = config_dir

	return info
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


--- Builds a self-contained HTML page from a Markdown string.
--- The inline JS renderer handles headings, tables, bold, italic, code, lists.
--- @param md string Markdown source.
--- @return string HTML document.
function _make_html(md)
	-- Escape for embedding as a JS template literal
	local safe = md
		:gsub("\\", "\\\\")
		:gsub("`",  "\\`")
		:gsub("${", "\\${")

	return [[<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
html,body{margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:13px;color:#1a1a1a;background:#fff;}
body{padding:16px 20px;box-sizing:border-box;overflow-y:auto;}
h1{font-size:1.2em;margin:0 0 .6em;}
h2{font-size:1em;font-weight:600;margin:1em 0 .3em;border-bottom:1px solid #e0e0e0;padding-bottom:.2em;}
table{border-collapse:collapse;width:100%;margin:.4em 0;}
th,td{border:1px solid #e0e0e0;padding:.3em .65em;text-align:left;}
th{background:#f6f6f6;font-weight:600;}
td:first-child{white-space:nowrap;color:#555;}
ul{margin:.3em 0 .3em 1.2em;padding:0;}li{margin:.2em 0;}
code{background:#f3f3f3;border-radius:3px;padding:.1em .35em;font-family:'SF Mono',Menlo,monospace;font-size:.88em;}
pre{background:#f3f3f3;border-radius:4px;padding:.6em 1em;overflow-x:auto;white-space:pre-wrap;word-break:break-all;}
pre code{background:none;padding:0;}
em{font-style:italic;color:#666;}
.ok{color:#1a7f37;}.fail{color:#cf222e;}
</style></head><body>
<script>
(function(){
var md=`]] .. safe .. [[`;
function esc(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function inline(t){
  t=esc(t);
  t=t.replace(/`([^`]+)`/g,'<code>$1</code>');
  t=t.replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>');
  t=t.replace(/__(.+?)__/g,'<strong>$1</strong>');
  t=t.replace(/\*(.+?)\*/g,'<em>$1</em>');
  t=t.replace(/_(.+?)_/g,'<em>$1</em>');
  t=t.replace(/✓/g,'<span class=ok>✓</span>');
  t=t.replace(/✗/g,'<span class=fail>✗</span>');
  return t;
}
var lines=md.split('\n'),out=[],inPre=false,inUl=false,inOl=false,inTbl=false;
function closeBlocks(){if(inUl){out.push('</ul>');inUl=false;}if(inOl){out.push('</ol>');inOl=false;}if(inTbl){out.push('</table>');inTbl=false;}}
for(var i=0;i<lines.length;i++){
  var l=lines[i];
  if(/^```/.test(l)){if(inPre){out.push('</code></pre>');inPre=false;}else{closeBlocks();out.push('<pre><code>');inPre=true;}continue;}
  if(inPre){out.push(esc(l));continue;}
  if(/^\s*$/.test(l)){closeBlocks();continue;}
  var hm=l.match(/^(#{1,6})\s+(.*)/);if(hm){closeBlocks();var n=hm[1].length;out.push('<h'+n+'>'+inline(hm[2])+'</h'+n+'>');continue;}
  if(/^\|/.test(l)&&/\|/.test(l)){if(!inTbl){closeBlocks();out.push('<table>');inTbl=true;}
    if(/^[\s|:-]+$/.test(l))continue;
    var cells=l.replace(/^\||\|$/g,'').split('|');
    var isHdr=(out.length>0&&out[out.length-1]==='<table>');
    var tag=isHdr?'th':'td';
    out.push('<tr>'+cells.map(function(c){return'<'+tag+'>'+inline(c.trim())+'</'+tag+'>';}).join('')+'</tr>');continue;}
  var ul=l.match(/^[-*+]\s+(.*)/);if(ul){if(!inUl){closeBlocks();out.push('<ul>');inUl=true;}out.push('<li>'+inline(ul[1])+'</li>');continue;}
  var ol=l.match(/^\d+\.\s+(.*)/);if(ol){if(!inOl){closeBlocks();out.push('<ol>');inOl=true;}out.push('<li>'+inline(ol[1])+'</li>');continue;}
  closeBlocks();out.push('<p>'+inline(l)+'</p>');
}
if(inPre)out.push('</code></pre>');closeBlocks();
document.body.innerHTML=out.join('\n');
})();
</script></body></html>]]
end

return M
