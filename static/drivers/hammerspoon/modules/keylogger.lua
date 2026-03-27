-- modules/keylogger.lua

-- ===========================================================================
-- Keylogger Module.
--
-- Records precise keystroke timings for typing analysis and LLM fine-tuning.
-- Logs are stored in daily files within a dedicated directory.
-- Disabled by default. Poses strict privacy and security implications.
-- ===========================================================================

local M = {}

local hs   = hs
local fs   = require("hs.fs")
local json = require("hs.json")
local utf8 = utf8





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- hs.configdir points to the root Hammerspoon directory
local LOG_DIR = hs.configdir .. "/logs"

local _is_enabled      = false
local _tap             = nil
local _script_control  = nil

local _buffer_events   = {}
local _buffer_text     = ""
local _last_time       = 0

-- App & Window exclusion state
local _disabled_apps        = {}
local _active_app_bundle    = nil
local _active_app_path      = nil
local _is_private_window    = false
local _app_watcher          = nil
local _win_filter           = nil





-- ====================================
-- ====================================
-- ======= 2/ Core Operations =========
-- ====================================
-- ====================================

--- Scans the window title for private browsing keywords
local function update_private_status()
	local win = hs.window.focusedWindow()
	_is_private_window = false
	
	if win then
		local title = win:title()
		-- Keywords for Safari, Chrome, Firefox, Edge in various languages
		local keywords = {
			"Navigation privée", "Private Browsing", "Incognito", 
			"InPrivate", "Anonymous"
		}
		for _, kw in ipairs(keywords) do
			if title:find(kw) then
				_is_private_window = true
				break
			end
		end
	end
end

--- Updates the currently active application context for filtering
local function app_watcher_cb(appName, eventType, appObject)
	if eventType == hs.application.watcher.activated and appObject then
		_active_app_bundle = appObject:bundleID()
		_active_app_path   = appObject:path()
		update_private_status()
	end
end

--- Ensures the target log directory exists
local function ensure_dir()
	if not fs.attributes(LOG_DIR) then
		local ok, err = fs.mkdir(LOG_DIR)
		if not ok then
			hs.dialog.alert("Keylogger Error", "Cannot create logs directory:\n" .. tostring(err))
		end
	end
end

--- Generates the path for today's log file
--- @return string The absolute path
local function get_log_file()
	ensure_dir()
	return LOG_DIR .. "/" .. os.date("%Y_%m_%d") .. ".log"
end

--- Appends a structured JSON entry to the log file
--- @param entry table The data payload
local function append_log(entry)
	local filepath = get_log_file()
	local f = io.open(filepath, "a")
	if f then
		entry.timestamp = os.date("%Y-%m-%d %H:%M:%S")
		local ok, str = pcall(json.encode, entry)
		if ok then f:write(str .. "\n") end
		f:close()
	end
end

--- Flushes the current typing buffer into the log file
local function flush_buffer()
	if #_buffer_events == 0 then return end
	
	-- Capture the frontmost application and active window/tab context
	local app = hs.application.frontmostApplication()
	local app_name = app and app:title() or "Unknown"
	local win = app and app:mainWindow()
	local win_title = win and win:title() or "Unknown"

	append_log({ 
		type = "typing", 
		text = _buffer_text, 
		app = app_name, 
		title = win_title, 
		events = _buffer_events 
	})
	
	_buffer_events = {}
	_buffer_text   = ""
	_last_time     = 0
end

--- The low-level event interceptor for keystrokes
--- @param e userdata The event object
--- @return boolean Always false (never consumes the event)
local function handle_key(e)
	local ok, err = pcall(function()
		if not _is_enabled then return end
		
		-- 0. Check private mode and app exclusions
		if _is_private_window then return end
		
		if _disabled_apps and #_disabled_apps > 0 then
			for _, d_app in ipairs(_disabled_apps) do
				if (d_app.bundleID and d_app.bundleID == _active_app_bundle) or 
				   (d_app.appPath and d_app.appPath == _active_app_path) then
					return
				end
			end
		end

		-- Flush buffer on mouse click
		if e:getType() == hs.eventtap.event.types.leftMouseDown then
			flush_buffer()
			return
		end
		
		-- 1. AI Pause state synchronization
		if _script_control and _script_control.is_paused() then
			flush_buffer()
			return
		end

		local flags = e:getFlags() or {}
		
		-- 2. Ignore keyboard shortcuts (Cmd+C, Ctrl+V, etc.)
		if flags.cmd or flags.ctrl then return end

		local keycode = e:getKeyCode()
		local chars = e:getCharacters(true)
		
		-- 3. Filter control keys and arrows, but EXCLUDE Backspace (51), Tab (48), Enter (36), Escape (53)
		if keycode ~= 51 and keycode ~= 48 and keycode ~= 36 and keycode ~= 53 then
			if not chars or chars == "" then return end
			-- Ignore Apple Private Use Zone and standard control characters
			if chars:match("[%z\1-\31\127]") then return end
			for _, code in utf8.codes(chars) do
				if code >= 0xF700 and code <= 0xF8FF then return end
			end
		end

		local now   = hs.timer.absoluteTime() / 1000000
		local delay = 0
		if _last_time > 0 then delay = math.floor(now - _last_time) end
		_last_time = now

		-- 4. Software Detection: A human keystroke generally takes > 30ms.
		-- If delay is < 3ms, the key was likely injected by a script (LLM or Hotstring).
		local is_synth = false
		if delay >= 0 and delay < 3 and _buffer_text ~= "" then is_synth = true end

		local raw_chars = e:getCharacters(false) or chars
		local mods = {}
		for k, v in pairs(flags) do
			if v and k ~= "capslock" then table.insert(mods, k) end
		end
		table.sort(mods)
		
		-- Metadata payload
		local meta = { s = is_synth, c = flags.capslock or false, r = raw_chars, m = table.concat(mods, ",") }

		-- 5. Process special keys and text accumulation
		if keycode == 51 then
			-- Backspace: only modify the text buffer for real (non-synthetic) keypresses.
			-- Synthetic backspaces are sent by keymap.lua during hotstring expansion;
			-- _buffer_text is resynchronised afterwards via M.set_buffer().
			if not is_synth and #_buffer_text > 0 then
				local last_char_pos = utf8.offset(_buffer_text, -1)
				if last_char_pos then
					_buffer_text = string.sub(_buffer_text, 1, last_char_pos - 1)
				end
			end
			table.insert(_buffer_events, {"[BS]", delay, meta})
		elseif keycode == 48 or keycode == 53 then
			-- Tab or Escape: Acts as a sentence break
			flush_buffer()
		elseif keycode == 36 then
			-- Enter: Acts as a sentence break
			_buffer_text = _buffer_text .. "\n"
			table.insert(_buffer_events, {"\n", delay, meta})
			flush_buffer()
		else
			-- Regular character typing.
			-- Skip synthetic characters produced by keymap.lua replacements;
			-- _buffer_text is resynchronised afterwards via M.set_buffer().
			local typed_char = chars or ""
			if not is_synth then
				_buffer_text = _buffer_text .. typed_char
			end
			table.insert(_buffer_events, {typed_char, delay, meta})
			
			-- Flush buffer at the end of a sentence
			if typed_char:match("[.?!]") then
				flush_buffer()
			end
		end
	end)
	
	if not ok then print("[keylogger] Error avoided to prevent keyboard lock: " .. tostring(err)) end
	
	return false
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Updates the list of excluded applications
--- @param apps table List of application tables {name, bundleID, appPath}
function M.set_disabled_apps(apps)
	_disabled_apps = type(apps) == "table" and apps or {}
end

--- Synchronizes the internal text buffer with the actual on-screen content.
--- Must be called by keymap.lua after every text replacement (hotstring, LLM
--- prediction, etc.) so that logged text reflects what is really on screen
--- rather than the raw unprocessed keystrokes.
--- @param text string The current on-screen text as tracked by keymap's buffer
function M.set_buffer(text)
	_buffer_text = type(text) == "string" and text or ""
end

--- Starts the keylogger engine
--- @param script_control table The module reference to check pause state
function M.start(script_control)
	_script_control = script_control
	if not _is_enabled then
		_is_enabled = true
		ensure_dir()

		-- Start app watcher for exclusion list
		if not _app_watcher then
			_app_watcher = hs.application.watcher.new(app_watcher_cb)
		end
		_app_watcher:start()

		if not _win_filter then
			_win_filter = hs.window.filter.new(true)
			_win_filter:subscribe({
				hs.window.filter.windowFocused,
				hs.window.filter.windowTitleChanged
			}, update_private_status)
		end
		update_private_status()

		local app = hs.application.frontmostApplication()
		if app then
			_active_app_bundle = app:bundleID()
			_active_app_path   = app:path()
		end

		-- Listen to both Keyboard events and Mouse Clicks
		if not _tap then 
			_tap = hs.eventtap.new({
				hs.eventtap.event.types.keyDown, 
				hs.eventtap.event.types.leftMouseDown
			}, handle_key) 
		end
		_tap:start()
	end
end

--- Stops the keylogger engine and flushes pending data
function M.stop()
	if _is_enabled then
		_is_enabled = false
		flush_buffer()
		if _tap then _tap:stop() end
		if _app_watcher then _app_watcher:stop() end
		if _win_filter then _win_filter:unsubscribeAll() end
	end
end

--- Injects a hotstring resolution event into the logs
--- @param trigger string The typed trigger sequence
--- @param replacement string The expanded output
function M.log_hotstring(trigger, replacement)
	if not _is_enabled then return end
	flush_buffer()
	append_log({ type = "hotstring", trigger = trigger, replacement = replacement, tag = "<hotstring>" .. replacement .. "</hotstring>" })
end

--- Injects an LLM generation event into the logs
--- @param context string The prompt context
--- @param results table Array of prediction blocks
function M.log_llm(context, results)
	if not _is_enabled then return end
	flush_buffer()
	local preds = {}
	for _, r in ipairs(results or {}) do table.insert(preds, r.to_type) end
	append_log({ type = "llm_generation", context = context, predictions = preds, tag = "<llm_generated>" .. (preds[1] or "") .. "</llm_generated>" })
end

--- Opens a webview interface to process and display typing metrics
function M.show_metrics()
	local ok, metrics_ui = pcall(require, "ui.metrics")
	
	-- Explicit fallback if parent module isn't resolved properly by macOS
	if not ok or type(metrics_ui) ~= "table" or type(metrics_ui.show) ~= "function" then
		local ok2, explicit_ui = pcall(require, "ui.metrics.init")
		if ok2 and type(explicit_ui) == "table" and type(explicit_ui.show) == "function" then
			metrics_ui = explicit_ui
			ok = true
		end
	end

	if ok and type(metrics_ui) == "table" and type(metrics_ui.show) == "function" then
		metrics_ui.show(LOG_DIR)
	else
		local err_msg = tostring(metrics_ui)
		hs.dialog.alert("Keylogger Error", "Cannot load Metrics UI.\n\nEnsure ui/metrics/init.lua is valid.\nDetails:\n" .. err_msg)
		print("[keylogger] UI ERROR: " .. err_msg)
	end
end

return M
