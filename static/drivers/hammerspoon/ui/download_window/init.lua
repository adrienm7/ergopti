--- ui/download_window/init.lua

--- ==============================================================================
--- MODULE: Download Progress Window UI
--- DESCRIPTION:
--- Floating progress window (hs.webview) for tracking LLM model downloads.
--- Features JS-to-Lua communication via hs.webview.usercontent.
---
--- FEATURES & RATIONALE:
--- 1. Decoupled Processing: Uses ui_builder to inject CSS and JS content securely.
--- 2. Space Teleportation: Window natively follows the user via the builder.
--- 3. GB formatting support: Understands GB number payloads directly from hardware_requirements.
--- ==============================================================================

local M = {}

local ui_builder = require("ui.ui_builder")

local _wv        = nil
local _on_cancel = nil
local _on_resolve = nil
local _on_retry  = nil
local _start_ts  = nil
local _ready     = false
local _queued    = {}
local _log_shown = false
local _is_hiding = false

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
		-- Notify central manager hook (if set) so it can mark downloads aborted.
		local hook = package.loaded and package.loaded["ui.menu.menu_llm.models_manager.download_abort_hook"]
		if type(hook) == "function" then pcall(hook) end
		if type(_on_cancel) == "function" then pcall(_on_cancel) end

	elseif msg.body == "resolve" then
		if type(_on_resolve) == "function" then pcall(_on_resolve) end

	elseif msg.body == "retry" then
		-- Un-abort the menubar icon lock so we can display progress again
		local retry_hook = package.loaded["ui.menu.menu_llm.models_manager.download_retry_hook"]
		if type(retry_hook) == "function" then pcall(retry_hook) end

		if type(_on_retry) == "function" then pcall(_on_retry) end
		
	elseif msg.body == "terminal" then
		local cmd   = M._terminal_cmd or ("ollama pull " .. (M._current_model or ""))
		local apple_script = string.format(
			"osascript -e 'tell application \"Terminal\" to do script \"%s\"' -e 'tell application \"Terminal\" to activate'",
			cmd:gsub("\"", "\\\"")
		)
		pcall(hs.execute, apple_script)

	elseif msg.body == "expand" then
		if _wv and type(_wv.frame) == "function" then
			local current = _wv:frame()
			local screen = hs.screen.mainScreen()
			local sf = screen and type(screen.frame) == "function" and screen:frame() or { x = 0, y = 0, w = 1920, h = 1080 }
			local target_h = math.floor((sf.h or 1080) * 0.5)

			if target_h > current.h then
				local bottom = current.y + current.h
				local new_frame = {
					x = current.x,
					y = bottom - target_h,
					w = current.w,
					h = target_h,
				}
				pcall(function() _wv:frame(new_frame) end)
			end
		end
	end
end)





-- ===================================
-- ===================================
-- ======= 2/ Formatting Tools =======
-- ===================================
-- ===================================

--- Formats bytes into a human-readable string.
--- @param b number The amount in bytes.
--- @return string|nil The formatted string.
local function fmt_bytes(b)
	if type(b) ~= "number" or b <= 0 then return nil end
	if b > 1e9 then return string.format("%.1f Go", b / 1e9) end
	if b > 1e6 then return string.format("%.0f Mo", b / 1e6) end
	return string.format("%.0f Ko", b / 1e3)
end

--- Formats a raw size value properly whether it's bytes or GB.
--- @param val any The value to format.
--- @return string|nil The cleanly formatted size string.
local function format_size(val)
	if type(val) == "string" then return val end
	if type(val) == "number" then
		-- High magnitude means bytes. Low magnitude means GB.
		if val > 1e6 then return fmt_bytes(val) end
		return string.format("%.1f Go", val)
	end
	return nil
end

--- Formats seconds into a human-readable time string.
--- @param s number Seconds.
--- @return string|nil The formatted string.
local function fmt_time(s)
	if type(s) ~= "number" or s <= 0 or s ~= s or s == math.huge then return nil end
	if s > 3600 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor((s % 3600) / 60)) end
	if s > 60   then return string.format("%dm %02ds", math.floor(s / 60), math.floor(s % 60)) end
	return string.format("%ds", math.floor(s))
end

--- Safely escapes a string for injection into JavaScript.
--- @param s string|nil The input string.
--- @return string The escaped string wrapped in quotes.
local function js_str(s)
	if not s then return "null" end
	return "\"" .. tostring(s):gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\""
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
	_is_hiding = true
	if _wv and type(_wv.delete) == "function" then 
		pcall(function() _wv:delete() end) 
	end
	_wv = nil 
	_on_cancel = nil
	_on_resolve = nil
	_on_retry  = nil
	_start_ts  = nil
	_ready     = false
	_queued    = {}
	_log_shown = false
	_is_hiding = false
	M._total_files = nil
	M._last_file_count = nil
end

--- Shows the download window for a given model.
--- @param model string|table The model name or model table containing metadata.
--- @param on_cancel function Callback invoked if the user cancels.
--- @param terminal_cmd string Optional override for the terminal fallback command.
--- @param sizes table Optional table explicitly containing the sizes metadata to display.
--- @param actions table|nil Optional callbacks: on_resolve and on_retry.
function M.show(model, on_cancel, terminal_cmd, sizes, actions)
	local model_name = type(model) == "table" and (model.name or model.repo) or model
	M._current_model = type(model_name) == "string" and model_name or "inconnu"
	M._terminal_cmd  = type(terminal_cmd) == "string" and terminal_cmd or ("ollama pull " .. M._current_model)
	
	_on_cancel = type(on_cancel) == "function" and on_cancel or nil
	_on_resolve = type(actions) == "table" and type(actions.on_resolve) == "function" and actions.on_resolve or nil
	_on_retry = type(actions) == "table" and type(actions.on_retry) == "function" and actions.on_retry or nil
	
	if _wv then
		-- Window is already open, just reset its state to prevent zombie placeholders
		_start_ts  = hs.timer.secondsSinceEpoch()
		_queued    = {}
		_ready     = true
		_log_shown = false
		M._total_files = nil
		M._last_file_count = nil
		
		eval("resetUI()")
		local safe = M._current_model:gsub("'", "\\'"):gsub("\"", "\\\"")
		eval("setModel(\"" .. safe .. "\")")
		return
	end

	_start_ts  = hs.timer.secondsSinceEpoch()
	_ready     = false
	_queued    = {}
	M._total_files = nil
	M._last_file_count = nil

	local screen = hs.screen.mainScreen()
	local f = screen and type(screen.frame) == "function" and screen:frame() or {x=0, y=0, w=1920, h=1080}
	
	-- Fixed size perfectly crafted to contain ~7 terminal log lines without overflowing
	local W, H = 460, 380
	local frame = {
		x = f.x + f.w - W - 10,
		y = f.y + f.h - H - 10,
		w = W,
		h = H
	}

	_wv = ui_builder.show_webview({
		frame             = frame,
		title             = "Téléchargement du modèle",
		style_masks       = {"titled", "closable", "miniaturizable", "resizable", "nonactivating"},
		level             = hs.drawing.windowLevels.floating,
		allow_text_entry  = false,
		allow_gestures    = false,
		allow_new_windows = false,
		usercontent       = _ucc,
		assets_dir        = ASSETS_DIR,
		on_navigation     = function(action)
			if action == "didFinishNavigation" then
				_ready = true
				local safe = M._current_model:gsub("'", "\\'"):gsub("\"", "\\\"")
				eval("setModel(\"" .. safe .. "\")")
				
				for _, q in ipairs(_queued) do eval(q) end
				_queued = {}
			end
			return true
		end,
		on_close          = function()
			-- Skip if we are programmatically closing the window via M.hide()
			if _is_hiding then return end
			_wv = nil
			M._total_files = nil
			M._last_file_count = nil
			
			-- Auto-abort download and reset menubar if the window is closed natively
			local hook = package.loaded and package.loaded["ui.menu.menu_llm.models_manager.download_abort_hook"]
			if type(hook) == "function" then pcall(hook) end
			if type(_on_cancel) == "function" then pcall(_on_cancel) end
		end
	})

	hs.timer.doAfter(1.0, function()
		if _wv and not _ready then
			_ready = true
			local safe = M._current_model:gsub("'", "\\'"):gsub("\"", "\\\"")
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
	
	local pct = tonumber(pct_str) or 0
	local elapsed = hs.timer.secondsSinceEpoch() - (_start_ts or hs.timer.secondsSinceEpoch())

	local dl_str, speed_str, eta_str, file_count_str

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

	-- Parse file counts for MLX and rich stats for Ollama directly from the logs
	if type(raw_line) == "string" and raw_line ~= "" then
		local clean_line = raw_line:gsub("\27%[[%d;]*%a", "")
		
		-- 1. Extract Ollama native progress (Ollama doesn't pass bytes_done via parameters)
		if not bytes_done then
			local o_pct = clean_line:match("(%d+)%%")
			if o_pct and tonumber(o_pct) then pct = tonumber(o_pct) end
			
			local o_dl = clean_line:match("(%d+%.?%d*%s*[KMG]?B%s*/%s*%d+%.?%d*%s*[KMG]?B)")
			if o_dl then dl_str = o_dl end
			
			local o_speed = clean_line:match("(%d+%.?%d*%s*[KMG]?B/s)")
			if o_speed then speed_str = o_speed end
			
			local o_eta = clean_line:match("%s+(%d+[hms%d]+)%s*$")
			if o_eta then eta_str = o_eta end
		end

		-- 2. MLX / HuggingFace file progress - Extremely strict matching
		for total in clean_line:gmatch("Fetching (%d+) files") do
			M._total_files = tonumber(total)
		end
		
		local found_files = false
		-- [^\n\r]- forbids the regex to span across newlines (which avoids catching file-specific progress bars)
		for a, b in clean_line:gmatch("Fetching[^\n\r]-(%d+)%s*/%s*(%d+)") do
			file_count_str = a .. "/" .. b
			M._last_file_count = file_count_str
			found_files = true
		end
		
		-- Fallback: Look for X/Y anywhere, BUT only if Y matches our known absolute total files exactly
		if not found_files and M._total_files then
			for a, b in clean_line:gmatch("(%d+)%s*/%s*(%d+)") do
				if tonumber(b) == M._total_files then
					file_count_str = a .. "/" .. b
					M._last_file_count = file_count_str
					found_files = true
				end
			end
		end

		if not file_count_str and M._last_file_count then
			file_count_str = M._last_file_count
		end
	elseif M._last_file_count then
		file_count_str = M._last_file_count
	end

	-- Cap at 99% during download: 100% is reserved exclusively for done()
	pct = math.min(math.max(0, pct), 99)

	local js = string.format("update(%d,%s,%s,%s,%s)",
		math.floor(pct), js_str(dl_str), js_str(speed_str), js_str(eta_str), js_str(file_count_str))

	if _ready then
		eval(js)
		if not _log_shown then
			_log_shown = true
			eval("showLog()")
		end
		if type(raw_line) == "string" and raw_line ~= "" then
			local normalized = raw_line:gsub("\r\n", "\n"):gsub("\r", "\n")
			for line in normalized:gmatch("([^\n]+)") do
				if line ~= "" then
					local safe = line:gsub("\\", "\\\\"):gsub("\"", "\\\"")
					eval("addLog(\"" .. safe .. "\")")
				end
			end
			-- Make sure the log area is visible and the window expanded the first time we receive output
			if not _log_shown then
				_log_shown = true
				eval("showLog()")
			end
		end
	else
		table.insert(_queued, js)
		if not _log_shown then
			_log_shown = true
			table.insert(_queued, "showLog()")
		end
		if type(raw_line) == "string" and raw_line ~= "" then
			local normalized = raw_line:gsub("\r\n", "\n"):gsub("\r", "\n")
			for line in normalized:gmatch("([^\n]+)") do
				if line ~= "" then
					local safe = line:gsub("\\", "\\\\"):gsub("\"", "\\\"")
					table.insert(_queued, "addLog(\"" .. safe .. "\")")
				end
			end
			if not _log_shown then
				_log_shown = true
				table.insert(_queued, "showLog()")
			end
		end
		if #_queued > 30 then table.remove(_queued, 1) end
	end
end

--- Finalizes the download UI state.
--- @param success boolean True if download was successful.
--- @param _model_name string The name of the downloaded model.
--- @param error_kind string|nil Error kind metadata for contextual actions.
function M.complete(success, _model_name, error_kind)
	if not _wv then return end
	
	local is_ok = success == true
	local msg   = is_ok and "✅ Installation terminée !" or "Échec du téléchargement"
	local js    = string.format("done(%s,%s,%s); showLog()", is_ok and "true" or "false", js_str(msg), js_str(error_kind))
	
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
