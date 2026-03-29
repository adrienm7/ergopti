--- modules/keylogger.lua

--- ==============================================================================
--- MODULE: Core Keylogger Engine
--- DESCRIPTION:
--- This is the low-level event tap daemon responsible for intercepting, measuring,
--- and aggregating human keystrokes globally across the operating system.
---
--- FEATURES & RATIONALE:
--- 1. Precision Profiling: Captures the exact millisecond delay between keys.
--- 2. Zero-Lag Architecture: Lazy loads metrics UI using daily fragments.
--- 3. Enterprise-Grade Security: Robust hardware ID detection for corporate Macs.
--- 4. Live Telemetry: Computes real-time typing speed for external UI consumption.
--- 5. Dead Keys & Composed Accents: Explicitly identifies dead keys and their composed results as distinct events.
--- 6. System Autocorrect: Observes accessibility text replacements to catch macOS native autocorrects bypassing eventtap.
--- 7. Semantic Context: Captures field role, layout, app, window title, and active URL.
--- 8. Enrichment: Tags manual corrections, LLM/hotstring expansions, and physical shift side.
--- 9. Robust NDJSON: Writes logs atomically with high-precision timestamps to prevent corruption.
--- 10. Automated Rotation: Compresses logs older than the current day via Gzip.
--- 11. Privacy Filters: Automatically ignores AXSecureTextFields (passwords).
--- 12. Idle Detection: Segments typing into logical sessions based on idle timeouts.
--- ==============================================================================

local M = {}

local hs   = hs
local fs   = require("hs.fs")
local json = require("hs.json")
local utf8 = utf8





-- ======================================
-- ======================================
-- ======= 1/ Constants And State =======
-- ======================================
-- ======================================

local LOG_DIR = hs.configdir .. "/logs"

local _is_enabled      = false
local _tap             = nil
local _script_control  = nil
local _options         = { encrypt = false }

local _buffer_events   = {}
local _buffer_text     = ""
local _last_time       = 0

local _synth_queue     = {}
local _pending_keyup   = {}
local _rich_chunks     = {}

-- Session tracking parameters
local _last_flush_time           = hs.timer.absoluteTime() / 1000000
local _current_session_pause     = 0
local _session_chars             = 0
local _session_time_ms           = 0
local _session_start_time        = 0
local _session_last_active       = 0
local _idle_timer                = nil
local IDLE_TIMEOUT_MINUTES       = 5
local WPM_WIDGET_IDLE_TIMEOUT_MS = 5000
local _current_day               = os.date("%Y_%m_%d")

-- Live sliding window buffer
local _recent_typing         = {}

-- Context buffers
local _session_app_name    = "Unknown"
local _session_win_title   = "Unknown"
local _session_url         = nil
local _session_field_role  = "Unknown"
local _session_layout      = "Unknown"
local _is_secure_field     = false

-- Exclusions
local _disabled_apps        = {}
local _active_app_bundle    = nil
local _active_app_path      = nil
local _active_app_pid       = nil
local _is_private_window    = false
local _app_watcher          = nil
local _win_filter           = nil

-- Background routines
local _maintenance_timer = nil

-- System Autocorrect & Accessibility Observers
local _ax_observer          = nil
local _last_focused_element = nil
local _last_ax_value        = ""

-- Zero-lag indices
local _today_idx  = {}
local _manifest   = {}

local _mac_serial = nil





-- ===================================
-- ===================================
-- ======= 2/ OS Interfacing =========
-- ===================================
-- ===================================

--- Reliably fetches a unique hardware identifier (Serial or UUID).
--- Handles Enterprise MDM restrictions by using a triple-layer fallback.
--- @return string The hardware key.
local function get_mac_serial()
	if _mac_serial then return _mac_serial end
	
	-- Method 1: Direct IOKit query (Robust sed parsing)
	local serial = hs.execute("ioreg -l | grep IOPlatformSerialNumber | sed 's/.*= \"//;s/\"//'")
	if serial and serial ~= "" and not serial:find("UNKNOWN") then 
		_mac_serial = serial:gsub("%s+", "")
		return _mac_serial
	end
	
	-- Method 2: System Profiler (Fallback for corporate Macs)
	local profiler = hs.execute("system_profiler SPHardwareDataType | awk '/Serial Number/ {print $4}'")
	if profiler and profiler ~= "" then
		_mac_serial = profiler:gsub("%s+", "")
		return _mac_serial
	end

	-- Method 3: Hardware UUID (Ultimate fallback)
	local uuid = hs.execute("ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'IOPlatformUUID' | sed 's/.*= \"//;s/\"//'")
	if uuid and uuid ~= "" then
		_mac_serial = uuid:gsub("%s+", "")
		return _mac_serial
	end

	return "ERGOPTI_FALLBACK_KEY"
end





-- ====================================
-- ====================================
-- ======= 3/ Index Aggregation =======
-- ====================================
-- ====================================

--- Removes the last UTF-8 character from a string.
--- @param input_string string The input string.
--- @return string The string without the last character.
local function pop_utf8(input_string)
	if #input_string == 0 then return input_string end
	local offset = utf8.offset(input_string, -1)
	return offset and input_string:sub(1, offset - 1) or ""
end

--- Adds a metric count to the dictionary.
--- @param dict table The target dictionary.
--- @param key string The sequence string.
--- @param delay number The delay in ms.
--- @param is_err boolean True if backspaced.
--- @param synth_type string The source generation type.
local function add_metric(dict, key, delay, is_err, synth_type)
	local item = dict[key]
	if not item then
		item = { c = 0, t = 0, hs = 0, llm = 0, o = 0, e = 0 }
		dict[key] = item
	end
	if is_err then
		item.e = item.e + 1
	else
		item.c = item.c + 1
		if synth_type == "hotstring" then item.hs = item.hs + 1
		elseif synth_type == "llm" then item.llm = item.llm + 1
		elseif synth_type ~= "none" then item.o = item.o + 1
		elseif delay > 0 then item.t = item.t + delay end
	end
end

--- Compiles raw events into aggregated dictionaries.
--- @param events table Raw key array.
--- @param app_name string Focus app.
--- @param date_str string Day identifier.
local function aggregate_events(events, app_name, date_str)
	date_str = date_str or os.date("%Y-%m-%d")
	
	local a = _today_idx[app_name]
	if not a then
		a = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {} }
		_today_idx[app_name] = a
	end

	local m_day = _manifest[date_str]
	if not m_day then m_day = {}; _manifest[date_str] = m_day end
	local m_app = m_day[app_name]
	if not m_app then m_app = { chars = 0, time = 0, sent = 0, sent_time = 0, sent_chars = 0 }; m_day[app_name] = m_app end

	local p1, p2, p3, p4, p5, p6 = nil, nil, nil, nil, nil, nil
	local cur_word = ""
	local word_err = false
	local hist = {}
	local MAX_DELAY = 5000

	for _, ev in ipairs(events) do
		local char = ev[1]
		local delay = ev[2]
		local meta = ev[3] or {}
		local is_bs = (char == "[BS]")
		local stype = meta.st or "none"
		local is_synth = meta.s or false

		if is_bs then
			if #hist > 0 then
				local l = table.remove(hist)
				if l.c then add_metric(a.c, l.c, 0, true) end
				if l.bg then add_metric(a.bg, l.bg, 0, true) end
				if l.tg then add_metric(a.tg, l.tg, 0, true) end
				if l.qg then add_metric(a.qg, l.qg, 0, true) end
				if l.pg then add_metric(a.pg, l.pg, 0, true) end
				if l.hx then add_metric(a.hx, l.hx, 0, true) end
				if l.hp then add_metric(a.hp, l.hp, 0, true) end
			end
			word_err = true
			cur_word = pop_utf8(cur_word)
		else
			local k_c = char
			local k_bg = p1 and (p1 .. k_c) or nil
			local k_tg = p2 and (p2 .. p1 .. k_c) or nil
			local k_qg = p3 and (p3 .. p2 .. p1 .. k_c) or nil
			local k_pg = p4 and (p4 .. p3 .. p2 .. p1 .. k_c) or nil
			local k_hx = p5 and (p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil
			local k_hp = p6 and (p6 .. p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil

			local h_obj = {}
			if is_synth or delay < MAX_DELAY then
				add_metric(a.c, k_c, delay, false, stype); h_obj.c = k_c
				if k_bg then add_metric(a.bg, k_bg, delay, false, stype); h_obj.bg = k_bg end
				if k_tg then add_metric(a.tg, k_tg, delay, false, stype); h_obj.tg = k_tg end
				if k_qg then add_metric(a.qg, k_qg, delay, false, stype); h_obj.qg = k_qg end
				if k_pg then add_metric(a.pg, k_pg, delay, false, stype); h_obj.pg = k_pg end
				if k_hx then add_metric(a.hx, k_hx, delay, false, stype); h_obj.hx = k_hx end
				if k_hp then add_metric(a.hp, k_hp, delay, false, stype); h_obj.hp = k_hp end

				if not is_synth then
					m_app.chars = m_app.chars + 1
					m_app.time  = m_app.time + delay
					m_app.sent_chars = (m_app.sent_chars or 0) + 1
					m_app.sent_time = (m_app.sent_time or 0) + delay
				end
			end

			table.insert(hist, h_obj)
			p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = k_c
		end
	end
end

--- Persists today's index into a dedicated file.
local function save_today_index()
	local idx_file = LOG_DIR .. "/" .. os.date("%Y_%m_%d") .. ".idx"
	local ok, raw = pcall(json.encode, _today_idx)
	if not ok then return end

	local f = io.open(idx_file .. ".tmp", "w")
	if f then 
		f:write(raw)
		f:close() 
		os.execute(string.format("mv %q %q", idx_file .. ".tmp", idx_file))
	end
end

--- Persists the fast-load manifest.
local function save_manifest()
	local manifest_file = LOG_DIR .. "/manifest.json"
	local ok, raw = pcall(json.encode, _manifest)
	if not ok then return end

	local f = io.open(manifest_file .. ".tmp", "w")
	if f then 
		f:write(raw)
		f:close() 
		os.execute(string.format("mv %q %q", manifest_file .. ".tmp", manifest_file))
	end
end

--- Parses unindexed raw logs on boot to heal the state.
local function rebuild_index_if_needed()
	local manifest_file = LOG_DIR .. "/manifest.json"
	local f = io.open(manifest_file, "r")
	if f then
		local c = f:read("*a")
		f:close()
		pcall(function() _manifest = json.decode(c) or {} end)
	end

	local today_idx_file = LOG_DIR .. "/" .. os.date("%Y_%m_%d") .. ".idx"
	local f_idx = io.open(today_idx_file, "r")
	if f_idx then
		local c = f_idx:read("*a")
		f_idx:close()
		pcall(function() _today_idx = json.decode(c) or {} end)
	end

	local changed = false
	
	for f_name in hs.fs.dir(LOG_DIR) do
		local y, m, d = f_name:match("^(%d%d%d%d)_(%d%d)_(%d%d)%.log")
		if not y then y, m, d = f_name:match("^(%d%d%d%d)_(%d%d)_(%d%d)%.log%.gz") end
		
		if y and m and d then
			local date_str = y .. "-" .. m .. "-" .. d
			local idx_file = string.format("%s/%s_%s_%s.idx", LOG_DIR, y, m, d)
			local idx_gz_file = idx_file .. ".gz"
			
			if not fs.attributes(idx_file) and not fs.attributes(idx_gz_file) then
				local full_path = LOG_DIR .. "/" .. f_name
				local content = ""
				
				if f_name:match("%.log%.gz%.enc$") then
					local safe_pwd = get_mac_serial():gsub("\"", "\\\"")
					local p = io.popen(string.format("gzip -c -d %q | openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" 2>/dev/null", full_path, safe_pwd), "r")
					if p then content = p:read("*a"); p:close() end
				elseif f_name:match("%.gz$") then
					local p = io.popen(string.format("gzip -c -d %q 2>/dev/null", full_path), "r")
					if p then content = p:read("*a"); p:close() end
				else
					local file = io.open(full_path, "r")
					if file then content = file:read("*a"); file:close() end
				end

				if content and content ~= "" then
					local backup_today = _today_idx
					_today_idx = {}
					
					for line in content:gmatch("[^\r\n]+") do
						if _options.encrypt and not line:match("^{") then
							local safe_line = line:gsub("\"", "\\\"")
							local safe_pwd = get_mac_serial():gsub("\"", "\\\"")
							local dec = hs.execute(string.format("echo \"%s\" | openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" 2>/dev/null", safe_line, safe_pwd))
							if dec and dec:match("^{") then line = dec end
						end

						if line:match("^{") then
							local ok, entry = pcall(json.decode, line)
							if ok and entry and entry.type == "typing" and entry.events then
								aggregate_events(entry.events, entry.app or "Unknown", date_str)
								changed = true
							end
						end
					end
					
					if date_str ~= os.date("%Y-%m-%d") then
						local tmp = idx_file .. ".tmp"
						local tmp_f = io.open(tmp, "w")
						if tmp_f then
							tmp_f:write(json.encode(_today_idx))
							tmp_f:close()
							os.execute(string.format("gzip -c %q > %q && rm %q", tmp, idx_gz_file, tmp))
						end
					else
						save_today_index()
						backup_today = _today_idx
					end
					
					_today_idx = backup_today
				end
			end
		end
	end
	
	if changed then save_manifest() end
end





-- =================================
-- =================================
-- ======= 4/ Log Management =======
-- =================================
-- =================================

--- Checks if focused browser is in incognito mode.
local function update_private_status()
	local win = hs.window.focusedWindow()
	_is_private_window = false
	if win then
		local title = win:title()
		local keywords = { "Navigation privée", "Private Browsing", "Incognito", "InPrivate", "Anonymous" }
		for _, kw in ipairs(keywords) do
			if title:find(kw) then _is_private_window = true break end
		end
	end
end

--- Watches for application context switches.
--- @param app_name string The name of the application.
--- @param event_type number The application event type.
--- @param app_object table The hs.application object.
local function app_watcher_cb(app_name, event_type, app_object)
	if event_type == hs.application.watcher.activated and app_object then
		_active_app_bundle = app_object:bundleID()
		_active_app_path   = app_object:path()
		_active_app_pid    = app_object:pid()
		update_private_status()
		update_ax_observer(_active_app_pid)
	end
end

--- Compresses old log files retroactively.
local function ensure_dir_and_rotate()
	if not fs.attributes(LOG_DIR) then fs.mkdir(LOG_DIR) end
	
	local today = os.date("%Y_%m_%d")
	for f in hs.fs.dir(LOG_DIR) do
		if f:match("^%d%d%d%d_%d%d_%d%d%.log$") and not f:find(today) then
			local full_path = LOG_DIR .. "/" .. f
			if _options.encrypt then
				local enc_path = full_path .. ".gz.enc"
				local safe_pwd = get_mac_serial():gsub("\"", "\\\"")
				os.execute(string.format("gzip -c %q | openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" > %q && rm %q", full_path, safe_pwd, enc_path, full_path))
			else
				os.execute(string.format("gzip %q", full_path))
			end
		end
		
		if f:match("^%d%d%d%d_%d%d_%d%d%.idx$") and not f:find(today) then
			local full_path = LOG_DIR .. "/" .. f
			os.execute(string.format("gzip %q", full_path))
		end
	end
end

--- Returns today's active plain log file.
--- @return string Filepath.
local function get_log_file() return LOG_DIR .. "/" .. os.date("%Y_%m_%d") .. ".log" end

--- Atomic log appender.
--- @param entry table Dictionary payload.
local function append_log(entry)
	local filepath = get_log_file()
	local now_ms = hs.timer.absoluteTime() / 1000000
	local ms_part = math.floor(now_ms) % 1000
	entry.timestamp = string.format("%s.%03d", os.date("%Y-%m-%d %H:%M:%S"), ms_part)
	
	local ok, str = pcall(json.encode, entry)
	if not ok then return end
	str = str:gsub("\n", "")
	
	local tmp = filepath .. ".tmp." .. hs.timer.absoluteTime()
	local f = io.open(tmp, "w")
	if f then
		f:write(str .. "\n")
		f:close()
		os.execute(string.format("cat %q >> %q; rm %q", tmp, filepath, tmp))
	end
end

--- Writes buffer to disk and resets memory strings.
local function flush_buffer()
	if #_buffer_events == 0 then return end
	
	local total_time_ms, total_chars = 0, 0
	for _, ev in ipairs(_buffer_events) do
		local meta = ev[3] or {}
		if not meta.s then
			local d = ev[2] or 0
			if d > 5000 then d = 5000 end
			total_time_ms = total_time_ms + d
			total_chars = total_chars + 1
		end
	end
	local wpm = total_time_ms > 0 and ((total_chars / 5) / (total_time_ms / 60000)) or 0

	local rich_str, cur_type, cur_text = "", nil, ""
	for _, chunk in ipairs(_rich_chunks) do
		if chunk.type == cur_type then cur_text = cur_text .. chunk.text
		else
			if cur_type then
				if cur_type == "text" then rich_str = rich_str .. cur_text
				elseif cur_type == "correction" then rich_str = rich_str .. "<correction><del>" .. cur_text .. "</del></correction>"
				else rich_str = rich_str .. "<autocomplete type=\"" .. cur_type .. "\">" .. cur_text .. "</autocomplete>" end
			end
			cur_type = chunk.type; cur_text = chunk.text
		end
	end
	if cur_type then
		if cur_type == "text" then rich_str = rich_str .. cur_text
		elseif cur_type == "correction" then rich_str = rich_str .. "<correction><del>" .. cur_text .. "</del></correction>"
		else rich_str = rich_str .. "<autocomplete type=\"" .. cur_type .. "\">" .. cur_text .. "</autocomplete>" end
	end

	append_log({ 
		type = "typing", text = _buffer_text, rich_text = rich_str, 
		app = _session_app_name, title = _session_win_title, url = _session_url,
		field_role = _session_field_role, layout = _session_layout,
		pause_before_ms = _current_session_pause,
		wpm = tonumber(string.format("%.1f", wpm)), events = _buffer_events 
	})

	aggregate_events(_buffer_events, _session_app_name, os.date("%Y-%m-%d"))
	save_today_index()
	save_manifest()
	
	_buffer_events = {}; _buffer_text = ""; _rich_chunks = {}; _last_time = 0; _pending_keyup = {}
	_last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Cleans up sessions if typing is abandoned for a while.
local function check_idle()
	local now = hs.timer.absoluteTime() / 1000000
	if _session_last_active > 0 and (now - _session_last_active) > (IDLE_TIMEOUT_MINUTES * 60 * 1000) then
		if #_buffer_events > 0 then flush_buffer() end
		append_log({ type = "session_end", duration_ms = _session_last_active - _session_start_time })
		_session_last_active = 0; _session_start_time = 0
	end
end

--- Routinely verifies log rotations to keep disk clean without blocking UI.
local function perform_maintenance()
	local today = os.date("%Y_%m_%d")
	if _current_day ~= today then
		flush_buffer()
		save_today_index()
		_today_idx = {}
		_current_day = today
		ensure_dir_and_rotate()
	end
end





-- =====================================
-- =====================================
-- ======= 5/ Advanced Observers =======
-- =====================================
-- =====================================

--- Callbacks for when the native text input modifies its buffer natively (Autocorrect).
--- @param element table The UI element firing the event.
--- @param event string The event name.
--- @param watcher table The AX observer instance.
--- @param user_data table Custom data.
local function handle_ax_value_changed(element, event, watcher, user_data)
	if event == "AXValueChanged" then
		local ok, val = pcall(function() return element:attributeValue("AXValue") end)
		if ok and type(val) == "string" then
			local now = hs.timer.absoluteTime() / 1000000
			
			-- If the value changed significantly but no physical keys were pressed in the last 100ms,
			-- it is highly likely macOS triggered a native text replacement or autocorrect.
			if (now - _last_time) > 100 and #val > 0 and #_last_ax_value > 0 and math.abs(#val - #_last_ax_value) > 1 then
				flush_buffer()
				append_log({
					type = "sys_autocorrect",
					tag = "<sys_autocorrect_detected>",
					app = _session_app_name,
					title = _session_win_title
				})
			end
			
			_last_ax_value = val
		end
	end
end

--- Hooks the accessibility observer to the new active application.
--- @param app_pid number The Process ID of the active application.
function update_ax_observer(app_pid)
	if _ax_observer then
		_ax_observer:stop()
		_ax_observer = nil
	end
	if not app_pid then return end
	
	_ax_observer = hs.axuielement.observer.new(app_pid)
	if _ax_observer then
		local app_element = hs.axuielement.applicationElement(app_pid)
		if app_element then
			_ax_observer:addWatcher(app_element, "AXFocusedUIElementChanged")
			
			-- Instantly hook the currently focused sub-element
			local focused = app_element:attributeValue("AXFocusedUIElement")
			if focused then
				pcall(function() _ax_observer:addWatcher(focused, "AXValueChanged") end)
			end
		end
		
		_ax_observer:callback(function(element, event, watcher, user_data)
			if event == "AXFocusedUIElementChanged" then
				if _last_focused_element then
					pcall(function() watcher:removeWatcher(_last_focused_element, "AXValueChanged") end)
				end
				_last_focused_element = element
				if element then
					pcall(function() watcher:addWatcher(element, "AXValueChanged") end)
					local ok, val = pcall(function() return element:attributeValue("AXValue") end)
					if ok and type(val) == "string" then _last_ax_value = val end
				end
			elseif event == "AXValueChanged" then
				handle_ax_value_changed(element, event, watcher, user_data)
			end
		end)
		
		_ax_observer:start()
	end
end





-- =====================================
-- =====================================
-- ======= 6/ Event Interception =======
-- =====================================
-- =====================================

--- Main eventtap listener callback.
--- @param event_obj table Event object.
--- @return boolean True to swallow, false to propagate.
local function handle_key(event_obj)
	-- Ensure no crash locks the keyboard globally
	local ok, err = pcall(function()
		if not _is_enabled then return end
		if _is_private_window then return end
		
		if _disabled_apps and #_disabled_apps > 0 then
			for _, d_app in ipairs(_disabled_apps) do
				if (d_app.bundleID and d_app.bundleID == _active_app_bundle) or 
				   (d_app.appPath and d_app.appPath == _active_app_path) then return end
			end
		end

		local evt_type = event_obj:getType()
		local now = hs.timer.absoluteTime() / 1000000

		if evt_type == hs.eventtap.event.types.leftMouseDown or evt_type == hs.eventtap.event.types.leftMouseDragged then
			flush_buffer()
			return
		end
		
		if evt_type == hs.eventtap.event.types.keyUp then
			local keycode = event_obj:getKeyCode()
			if _pending_keyup[keycode] then
				_pending_keyup[keycode].event[3].h = math.floor(now - _pending_keyup[keycode].down_time)
				_pending_keyup[keycode] = nil
			end
			return
		end

		if evt_type ~= hs.eventtap.event.types.keyDown then return end

		if _script_control and type(_script_control.is_paused) == "function" and _script_control.is_paused() then
			flush_buffer()
			return
		end

		local flags = event_obj:getFlags() or {}
		local keycode = event_obj:getKeyCode()
		
		if flags.cmd and keycode == 0 then flush_buffer(); return end
		if flags.shift and (keycode >= 123 and keycode <= 126) then flush_buffer(); return end
		if flags.cmd or flags.ctrl then return end

		local chars = event_obj:getCharacters(true)
		if keycode ~= 51 and keycode ~= 48 and keycode ~= 36 and keycode ~= 53 then
			if not chars or chars == "" then return end
			if chars:match("[%z\1-\31\127]") then return end
			for _, code in utf8.codes(chars) do if code >= 0xF700 and code <= 0xF8FF then return end end
		end

		local delay = _last_time > 0 and math.floor(now - _last_time) or 0
		_last_time = now

		if _session_start_time == 0 then
			_session_start_time = now
			append_log({ type = "session_start" })
		end
		
		if #_buffer_events == 0 then
			_current_session_pause = math.floor(now - _last_flush_time)
			local app = hs.application.frontmostApplication()
			_session_app_name = app and app:title() or "Unknown"
			local win = app and app:mainWindow()
			_session_win_title = win and win:title() or "Unknown"
			_session_layout = hs.keycodes.currentLayout()
			_session_field_role = "Unknown"
			_session_url = nil
			_is_secure_field = false

			hs.timer.doAfter(0, function()
				local ok_sys, sys = pcall(hs.axuielement.systemWideElement)
				if ok_sys and sys then
					local focused = sys:attributeValue("AXFocusedUIElement")
					if focused then
						local role = focused:attributeValue("AXRole")
						local subrole = focused:attributeValue("AXSubrole")
						_session_field_role = (subrole and subrole ~= "") and subrole or role
						if role == "AXSecureTextField" or subrole == "AXSecureTextField" then
							_is_secure_field = true
							_buffer_events = {}; _buffer_text = ""; _rich_chunks = {}
						end
					end
				end
				
				if not _is_secure_field then
					local script = ""
					if _session_app_name == "Safari" then script = "tell application \"Safari\" to return URL of front document"
					elseif _session_app_name == "Google Chrome" or _session_app_name == "Brave Browser" or _session_app_name == "Microsoft Edge" or _session_app_name == "Arc" then
						script = "tell application \"" .. _session_app_name .. "\" to return URL of active tab of front window"
					end
					if script ~= "" then
						pcall(hs.osascript.applescript, script, function(succ, res) if succ and type(res) == "string" then _session_url = res end end)
					end
				end
			end)
		end

		if _is_secure_field then return end

		local raw_chars = event_obj:getCharacters(false) or chars
		local is_synth = false
		local synth_type = "none"
		local is_dead_key = false
		local is_composed = false

		if #_synth_queue > 0 then
			local next_synth = _synth_queue[1]
			if raw_chars == next_synth.char then
				is_synth = true; synth_type = next_synth.type; table.remove(_synth_queue, 1)
			elseif delay < 3 then
				is_synth = true; synth_type = next_synth.type
			end
		end

		if not is_synth then
			table.insert(_recent_typing, now)
			_session_last_active = now
			
			-- Dead key and composed characters tracking
			if keycode ~= 51 and keycode ~= 48 and keycode ~= 36 and keycode ~= 53 then
				local raw = event_obj:getCharacters(false) or ""
				local cooked = event_obj:getCharacters(true) or ""
				
				if cooked == "" and raw ~= "" then
					is_dead_key = true
					chars = raw
				elseif cooked ~= raw and #cooked > 0 then
					is_composed = true
				end
			end
		end

		local mods = {}
		for k, v in pairs(flags) do if v and k ~= "capslock" then table.insert(mods, k) end end
		table.sort(mods)

		local keymap_mod = require("modules.keymap")
		local shift_side = flags.capslock and "capslock" or (type(keymap_mod.get_shift_side) == "function" and keymap_mod.get_shift_side() or "none")
		local meta = { s = is_synth, st = synth_type, c = flags.capslock or false, ss = shift_side, r = raw_chars, m = table.concat(mods, ","), h = 0, d = delay, dk = is_dead_key, cp = is_composed }

		local ev_entry = nil

		if keycode == 51 then
			local deleted_char = ""
			if not is_synth and #_buffer_text > 0 then
				local last_char_pos = utf8.offset(_buffer_text, -1)
				if last_char_pos then
					deleted_char = string.sub(_buffer_text, last_char_pos)
					_buffer_text = string.sub(_buffer_text, 1, last_char_pos - 1)
				end
			end
			ev_entry = {"[BS]", delay, meta}
			table.insert(_buffer_events, ev_entry)
			if not is_synth and deleted_char ~= "" then table.insert(_rich_chunks, { type = "correction", text = deleted_char }) end
		elseif keycode == 48 or keycode == 53 then flush_buffer()
		elseif keycode == 36 then
			_buffer_text = _buffer_text .. "\n"
			ev_entry = {"\n", delay, meta}; table.insert(_buffer_events, ev_entry)
			table.insert(_rich_chunks, { type = is_synth and synth_type or "text", text = "\n" })
			flush_buffer()
		else
			local typed_char = chars or ""
			if not is_synth then _buffer_text = _buffer_text .. typed_char end
			ev_entry = {typed_char, delay, meta}; table.insert(_buffer_events, ev_entry)
			table.insert(_rich_chunks, { type = is_synth and synth_type or "text", text = typed_char })
			if typed_char:match("[.?!]") then flush_buffer() end
		end

		if ev_entry then _pending_keyup[keycode] = { down_time = now, event = ev_entry } end
	end)
	
	if not ok then print("[keylogger] Évitement d’un verrouillage clavier : " .. tostring(err)) end
	return false
end





-- ==================================
-- ==================================
-- ======= 7/ Public Core API =======
-- ==================================
-- ==================================

--- Configures the keylogger global constraints.
--- @param opts table The options dictionary.
function M.set_options(opts)
	_options = opts or {}
end

--- Replaces the current disabled app list.
--- @param apps table The array of app bundles.
function M.set_disabled_apps(apps) _disabled_apps = type(apps) == "table" and apps or {} end

--- Injects simulated strings into the tracking buffer.
--- @param text string The payload.
function M.set_buffer(text) _buffer_text = type(text) == "string" and text or "" end

--- Queues synthetic characters to be marked distinctly in logs.
--- @param text string The synthetic text.
--- @param source_type string Origin identifier.
function M.notify_synthetic(text, source_type)
	if not text or text == "" then return end
	for _, code in utf8.codes(text) do table.insert(_synth_queue, { char = utf8.char(code), type = source_type }) end
end

--- Extracts the rolling array to compute current Words-Per-Minute.
--- @return table Dictionary with `wpm` integer property.
function M.get_live_stats()
	local now = hs.timer.absoluteTime() / 1000000
	while #_recent_typing > 0 and (now - _recent_typing[1]) > 15000 do
		table.remove(_recent_typing, 1)
	end
	
	local live_wpm = #_recent_typing * 0.8
	local is_idle = (_session_last_active == 0) or ((now - _session_last_active) > WPM_WIDGET_IDLE_TIMEOUT_MS)
	local display_wpm = is_idle and 0 or math.floor(live_wpm + 0.5)
	
	return { wpm = display_wpm }
end

--- Boots up the engine and background daemons.
--- @param script_control table Module to allow pauses.
function M.start(script_control)
	_script_control = script_control
	if not _is_enabled then
		_is_enabled = true
		rebuild_index_if_needed()
		ensure_dir_and_rotate()
		_last_flush_time = hs.timer.absoluteTime() / 1000000

		if not _app_watcher then _app_watcher = hs.application.watcher.new(app_watcher_cb) end
		_app_watcher:start()

		if not _win_filter then
			local target_browsers = { "Safari", "Google Chrome", "Firefox", "Microsoft Edge", "Brave Browser", "Arc", "Opera", "Vivaldi" }
			_win_filter = hs.window.filter.new(target_browsers)
			_win_filter:subscribe({ hs.window.filter.windowFocused, hs.window.filter.windowTitleChanged }, update_private_status)
		end
		update_private_status()

		if not _tap then 
			_tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp, hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.leftMouseDragged }, handle_key) 
		end
		_tap:start()

		if not _idle_timer then _idle_timer = hs.timer.new(60, check_idle) end
		_idle_timer:start()

		if not _maintenance_timer then _maintenance_timer = hs.timer.new(1.0, perform_maintenance) end
		_maintenance_timer:start()
		
		local current_app = hs.application.frontmostApplication()
		if current_app then update_ax_observer(current_app:pid()) end
	end
end

--- Halts tracking and clears all visual elements.
function M.stop()
	if _is_enabled then
		_is_enabled = false
		flush_buffer()
		if _tap then _tap:stop() end
		if _app_watcher then _app_watcher:stop() end
		if _win_filter then _win_filter:unsubscribeAll() end
		if _idle_timer then _idle_timer:stop() end
		if _maintenance_timer then _maintenance_timer:stop() end
		if _ax_observer then _ax_observer:stop(); _ax_observer = nil end
	end
end

--- Captures shortcut expansion cleanly.
--- @param trigger string Sequence trigger.
--- @param replacement string Resulting string.
function M.log_hotstring(trigger, replacement)
	if not _is_enabled then return end
	flush_buffer()
	append_log({ type = "hotstring", trigger = trigger, replacement = replacement, tag = "<hotstring>" .. replacement .. "</hotstring>" })
	_last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Captures LLM generations.
--- @param context string Previous words.
--- @param results table Options generated.
function M.log_llm(context, results)
	if not _is_enabled then return end
	flush_buffer()
	local preds = {}
	for _, r in ipairs(results or {}) do table.insert(preds, r.to_type) end
	append_log({ type = "llm_generation", context = context, predictions = preds, tag = "<llm_generated>" .. (preds[1] or "") .. "</llm_generated>" })
	_last_flush_time = hs.timer.absoluteTime() / 1000000
end

--- Triggers the massive HTML interface metrics canvas.
function M.show_metrics()
	local ok, metrics_ui = pcall(require, "ui.metrics")
	if not ok or type(metrics_ui) ~= "table" or type(metrics_ui.show) ~= "function" then
		local ok2, explicit_ui = pcall(require, "ui.metrics.init")
		if ok2 and type(explicit_ui) == "table" and type(explicit_ui.show) == "function" then metrics_ui = explicit_ui; ok = true end
	end
	if ok and type(metrics_ui) == "table" and type(metrics_ui.show) == "function" then
		metrics_ui.show(LOG_DIR)
	else
		local err_msg = tostring(metrics_ui)
		hs.dialog.blockAlert("Erreur Keylogger", "Impossible de charger l’interface des métriques.\n\nVérifiez ui/metrics/init.lua.\nDétails :\n" .. err_msg, "OK")
	end
end

return M
