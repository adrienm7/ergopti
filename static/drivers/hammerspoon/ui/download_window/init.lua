--- ui/download_window/init.lua

--- ==============================================================================
--- MODULE: Download Progress Window UI
--- DESCRIPTION:
--- Floating progress window (hs.webview) for tracking LLM model downloads.
--- Features JS-to-Lua communication via hs.webview.usercontent.
---
--- FEATURES & RATIONALE:
--- 1. Decoupled Processing: Uses ui_builder to inject CSS and JS content securely.
--- 2. Space Teleportation & Focus: Leverages the UI builder to natively teleport the window to the active macOS space and grant it focus, while allowing other apps to overlap it when clicked.
--- 3. Centralized Creation: Window properties are managed via the ui_builder factory.
--- ==============================================================================

local M = {}

local ui_builder = require("ui.ui_builder")

local _wv        = nil
local _on_cancel = nil
local _start_ts  = nil
local _ready     = false
local _queued    = {}

-- Determine absolute path to the assets directory
local _src  = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"





-- ====================================
-- ====================================
-- ======= 1/ Javascript Bridge =======
-- ====================================
-- ====================================

local _ucc = hs.webview.usercontent.new("dl_bridge")
_ucc:setCallback(function(msg)
	if type(msg) ~= "table" then return end
	
	if msg.body == "cancel" then
		if type(_on_cancel) == "function" then pcall(_on_cancel) end
		
	elseif msg.body == "terminal" then
		local model = type(M._current_model) == "string" and M._current_model or ""
		local cmd   = "ollama pull " .. model
		local apple_script = string.format(
			"osascript -e 'tell application \"Terminal\" to do script \"%s\"' -e 'tell application \"Terminal\" to activate'",
			cmd:gsub("\"", "\\\"")
		)
		pcall(hs.execute, apple_script)
	end
end)





-- ===================================
-- ===================================
-- ======= 2/ Formatting Tools =======
-- ===================================
-- ===================================

--- Formats bytes into a human-readable string (KB, MB, GB).
--- @param b number The amount in bytes.
--- @return string|nil The formatted string.
local function fmt_bytes(b)
	if type(b) ~= "number" or b <= 0 then return nil end
	if b > 1e9 then return string.format("%.1f Go", b / 1e9) end
	if b > 1e6 then return string.format("%.0f Mo", b / 1e6) end
	return string.format("%.0f Ko", b / 1e3)
end

--- Formats seconds into a human-readable time string.
--- @param s number Seconds.
--- @return string|nil The formatted string.
local function fmt_time(s)
	if type(s) ~= "number" or s <= 0 or s ~= s or s == math.huge then return nil end
	if s > 3600 then return string.format("%dh%02dm", math.floor(s / 3600), math.floor((s % 3600) / 60)) end
	if s > 60   then return string.format("%dm%02ds", math.floor(s / 60), math.floor(s % 60)) end
	return string.format("%ds", math.floor(s))
end

--- Safely escapes a string for injection into JavaScript.
--- @param s string|nil The input string.
--- @return string The escaped string wrapped in quotes.
local function js_str(s)
	if not s then return "null" end
	return "\"" .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"') .. "\""
end

--- Safely evaluates a JavaScript string in the active webview.
--- @param code string The JS code to execute.
local function eval(code)
	if _wv and type(_wv.evaluateJavaScript) == "function" then 
		pcall(function() _wv:evaluateJavaScript(code) end) 
	end
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Hides and destroys the download window.
function M.hide()
	if _wv and type(_wv.delete) == "function" then 
		pcall(function() _wv:delete() end) 
		_wv = nil 
	end
	_on_cancel = nil
	_start_ts  = nil
	_ready     = false
	_queued    = {}
end

--- Shows the download window for a given model.
--- @param model_name string The name of the model being downloaded.
--- @param on_cancel function Callback invoked if the user cancels.
function M.show(model_name, on_cancel)
	M.hide() -- Ensure any old download window is strictly cleared
	
	M._current_model = type(model_name) == "string" and model_name or "inconnu"
	_on_cancel = type(on_cancel) == "function" and on_cancel or nil
	_start_ts  = hs.timer.secondsSinceEpoch()
	_ready     = false
	_queued    = {}

	local screen = hs.screen.mainScreen()
	local f = screen and type(screen.frame) == "function" and screen:frame() or {x=0, y=0, w=1920, h=1080}
	
	local W, H = 380, 240
	local frame = {
		x = f.x + f.w - W - 18,
		y = f.y + f.h - H - 50,
		w = W,
		h = H
	}

	-- Request the webview creation/focus from the centralized UI builder
	_wv = ui_builder.show_webview({
		frame             = frame,
		title             = "Téléchargement du modèle",
		style_masks       = {"titled", "closable", "nonactivating"},
		level             = hs.drawing.windowLevels.floating,
		allow_text_entry  = false,
		allow_gestures    = false,
		allow_new_windows = false,
		usercontent       = _ucc,
		assets_dir        = ASSETS_DIR,
		on_navigation     = function(action)
			if action == "didFinishNavigation" then
				_ready = true
				local safe = M._current_model:gsub("'", "\\'"):gsub('"', '\\"')
				eval("setModel(\"" .. safe .. "\")")
				
				for _, q in ipairs(_queued) do eval(q) end
				_queued = {}
			end
			return true
		end,
		on_close          = function()
			_wv = nil
		end
	})

	-- Fallback mechanism if the didFinishNavigation event is never caught
	hs.timer.doAfter(1.0, function()
		if _wv and not _ready then
			_ready = true
			local safe = M._current_model:gsub("'", "\\'"):gsub('"', '\\"')
			eval("setModel(\"" .. safe .. "\")")
			
			for _, q in ipairs(_queued) do eval(q) end
			_queued = {}
		end
	end)
end

--- Updates the UI with current download metrics.
--- @param pct_str string|number Percentage complete.
--- @param bytes_done number Bytes downloaded so far.
--- @param bytes_total number Total bytes expected.
--- @param raw_line string The raw log line from Ollama to display.
function M.update(pct_str, bytes_done, bytes_total, raw_line)
	if not _wv then return end
	
	local pct     = tonumber(pct_str) or 0
	local elapsed = hs.timer.secondsSinceEpoch() - (_start_ts or hs.timer.secondsSinceEpoch())

	local dl_str, speed_str, eta_str

	if type(bytes_total) == "number" and bytes_total > 0 then
		local ds = fmt_bytes(bytes_done)
		local ts = fmt_bytes(bytes_total)
		if ds and ts then dl_str = ds .. " / " .. ts end
	elseif type(bytes_done) == "number" and bytes_done > 0 then
		dl_str = fmt_bytes(bytes_done)
	end

	if type(bytes_done) == "number" and bytes_done > 0 and elapsed > 2 then
		local speed = bytes_done / elapsed
		speed_str = fmt_bytes(speed) and (fmt_bytes(speed) .. "/s") or nil
		
		if type(bytes_total) == "number" and bytes_total > bytes_done and speed > 0 then
			eta_str = fmt_time((bytes_total - bytes_done) / speed)
		end
	end

	local js = string.format("update(%d,%s,%s,%s)",
		math.floor(pct), js_str(dl_str), js_str(speed_str), js_str(eta_str))

	if _ready then
		eval(js)
		if type(raw_line) == "string" and raw_line ~= "" then
			local safe = raw_line:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "")
			eval("addLog(\"" .. safe .. "\")")
		end
	else
		table.insert(_queued, js)
		if #_queued > 30 then table.remove(_queued, 1) end
	end
end

--- Finalizes the download UI state.
--- @param success boolean True if download was successful.
--- @param _model_name string The name of the downloaded model.
function M.complete(success, _model_name)
	if not _wv then return end
	
	local is_ok = success == true
	local msg   = is_ok and "✅ Installation terminée !" or "❌ Échec du téléchargement"
	local js    = string.format("done(%s,%s); showLog()", is_ok and "true" or "false", js_str(msg))
	
	if _ready then 
		eval(js)
	else 
		table.insert(_queued, js) 
	end
	
	if is_ok then 
		hs.timer.doAfter(4, M.hide) 
	end
end

return M
