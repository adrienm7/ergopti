--- modules/keylogger/log_manager.lua

--- ==============================================================================
--- MODULE: Keylogger Log Manager (SQLite Encrypted)
--- DESCRIPTION:
--- Handles the heavy lifting of data aggregation and SQLite ingestion.
--- Compiles raw keystrokes into rich N-gram indexes and tracks native app categories.
---
--- FEATURES & RATIONALE:
--- 1. Math Offloading: Keeps the mathematical processing out of the fast loop.
--- 2. Native Categorization: Dynamically queries macOS for official app categories.
--- 3. Instant UI Ready: Pushes live updates directly to Webview contexts.
--- 4. Built-in Security: Transparent encryption of the historical SQLite database.
--- ==============================================================================

local hs      = hs
local fs      = require("hs.fs")
local json    = require("hs.json")
local timer   = require("hs.timer")
local sqlite3 = require("hs.sqlite3")
local utf8    = utf8

local Logger  = require("lib.logger")
local LOG     = "keylogger.log_manager"

local M = {}

local _state = nil
local _save_timer = nil
local _last_forced_save_ms = 0
local FORCE_SAVE_INTERVAL_MS = 10000





-- ===================================
-- ===================================
-- ======= 1/ Helper Functions =======
-- ===================================
-- ===================================

--- Fetches the native macOS category for a given application dynamically.
--- @param app_name string The name of the application.
--- @return string The formatted native category.
function M.get_native_app_category(app_name)
	local app = hs.application.get(app_name)
	if app then
		local info = hs.application.infoForBundlePath(app:path())
		if info and info.LSApplicationCategoryType then
			local cat = info.LSApplicationCategoryType:gsub("public%.app%-category%.", "")
			cat = cat:gsub("%-", " ")
			return cat:sub(1, 1):upper() .. cat:sub(2)
		end
	end
	return "Unknown"
end

--- Removes the last UTF-8 character from a string.
--- @param input_string string The input string.
--- @return string The string without the last character.
local function pop_utf8(input_string)
	if #input_string == 0 then return input_string end
	local offset = utf8.offset(input_string, -1)
	return offset and input_string:sub(1, offset - 1) or ""
end

--- Adds a metric count to the dictionary using an optimized schema.
--- @param dict table The target dictionary.
--- @param key string The sequence string.
--- @param delay number The delay in ms.
--- @param is_err boolean True if backspaced.
--- @param synth_type string The source generation type.
local function add_metric(dict, key, delay, is_err, synth_type)
	local item = dict[key]
	if type(item) ~= "table" then
		item = {}
		dict[key] = item
	end
	if is_err then
		item.e = (item.e or 0) + 1
	else
		item.c = (item.c or 0) + 1
		if synth_type == "hotstring" then item.hs = (item.hs or 0) + 1
		elseif synth_type == "llm" then item.llm = (item.llm or 0) + 1
		elseif synth_type ~= "none" then item.o = (item.o or 0) + 1
		elseif delay > 0 then item.t = (item.t or 0) + delay end
	end
end

--- Debounces local saves to prevent blocking the OS keystroke event loop.
local function debounced_save()
	local now_ms = timer.absoluteTime() / 1000000
	if (now_ms - _last_forced_save_ms) >= FORCE_SAVE_INTERVAL_MS then
		M.save_today_index()
		M.save_manifest()
		_last_forced_save_ms = now_ms
	end

	if _save_timer then _save_timer:stop() end
	_save_timer = timer.doAfter(1.5, function()
		Logger.debug(LOG, "Executing debounced save…")
		M.save_today_index()
		M.save_manifest()
		_last_forced_save_ms = timer.absoluteTime() / 1000000
		Logger.info(LOG, "Debounced save completed.")
	end)
end





-- ===================================
-- ===================================
-- ======= 2/ Core Aggregation =======
-- ===================================
-- ===================================

--- Compiles raw events into aggregated dictionaries safely.
--- @param events table Raw key array.
--- @param app_name string Focus app.
--- @param date_str string Day identifier.
function M.aggregate_events(events, app_name, date_str)
	date_str = date_str or os.date("%Y-%m-%d")
	
	local a = _state.today_idx[app_name]
	if type(a) ~= "table" then
		a = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {} }
		_state.today_idx[app_name] = a
	end
	a.sc = type(a.sc) == "table" and a.sc or {}

	local m_day = _state.manifest[date_str]
	if type(m_day) ~= "table" then m_day = {}; _state.manifest[date_str] = m_day end
	
	local m_app = m_day[app_name]
	if type(m_app) ~= "table" then 
		m_app = { chars = 0, time = 0, think_time = 0, sent = 0, sent_time = 0, sent_chars = 0, hs_chars = 0, llm_chars = 0, hs_triggers = 0, llm_triggers = 0, hs_suggested = 0, llm_suggested = 0, hourly = {}, app_time_ms = 0, switches_to = {}, category = M.get_native_app_category(app_name) }
		m_day[app_name] = m_app 
	end
	
	local current_hour = tostring(os.date("%H"))
	m_app.hourly = type(m_app.hourly) == "table" and m_app.hourly or {}
	if type(m_app.hourly[current_hour]) ~= "table" then m_app.hourly[current_hour] = { c = 0, e = 0, em = 0, es = 0 } end
	m_app.hourly[current_hour].em = m_app.hourly[current_hour].em or 0
	m_app.hourly[current_hour].es = m_app.hourly[current_hour].es or 0

	local p1, p2, p3, p4, p5, p6 = nil, nil, nil, nil, nil, nil
	local cur_word = ""
	local word_err = false
	local hist = {}
	local MAX_DELAY = 5000
	local prev_stype = "none"

	for _, ev in ipairs(events) do
		local char = ev[1]
		local delay = ev[2] or 0
		local meta = ev[3] or {}
		local shortcut_key = meta.sc
		local is_bs = (char == "[BS]")
		local stype = meta.st or "none"
		local is_synth = meta.s or false

		if type(shortcut_key) == "string" and shortcut_key ~= "" then
			add_metric(a.sc, shortcut_key, delay, false, "none")
		else

		if is_synth and stype ~= "none" and stype ~= prev_stype then
			if stype == "hotstring" then m_app.hs_triggers = (m_app.hs_triggers or 0) + 1 end
			if stype == "llm" then m_app.llm_triggers = (m_app.llm_triggers or 0) + 1 end
		end
		prev_stype = is_synth and stype or "none"

		if is_bs then
			if is_synth then
				if stype == "hotstring" then m_app.hs_chars = math.max(0, (m_app.hs_chars or 0) - 1)
				elseif stype == "llm" then m_app.llm_chars = math.max(0, (m_app.llm_chars or 0) - 1) end
			end
			
			-- Always pop char to reflect screen accurately
			cur_word = pop_utf8(cur_word)

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
			if is_synth then
				m_app.hourly[current_hour].es = (m_app.hourly[current_hour].es or 0) + 1
			else
				m_app.hourly[current_hour].e = (m_app.hourly[current_hour].e or 0) + 1
				m_app.hourly[current_hour].em = (m_app.hourly[current_hour].em or 0) + 1
			end
			
			local h_obj = {}
			add_metric(a.c, "[BS]", delay, false, stype); h_obj.c = "[BS]"
			if p1 then add_metric(a.bg, p1 .. "[BS]", delay, false, stype); h_obj.bg = p1 .. "[BS]" end
			if p2 then add_metric(a.tg, p2 .. p1 .. "[BS]", delay, false, stype); h_obj.tg = p2 .. p1 .. "[BS]" end
			
			if not is_synth then
				m_app.chars = (m_app.chars or 0) + 1
				if delay > 1000 then m_app.think_time = (m_app.think_time or 0) + delay else m_app.time = (m_app.time or 0) + delay end
			else
				if stype == "hotstring" then m_app.hs_chars = (m_app.hs_chars or 0) + 1
				elseif stype == "llm" then m_app.llm_chars = (m_app.llm_chars or 0) + 1 end
			end
			
			table.insert(hist, h_obj)
			p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = "[BS]"
		else
			local k_c = char
			local k_bg = p1 and (p1 .. k_c) or nil
			local k_tg = p2 and (p2 .. p1 .. k_c) or nil
			local k_qg = p3 and (p3 .. p2 .. p1 .. k_c) or nil
			local k_pg = p4 and (p4 .. p3 .. p2 .. p1 .. k_c) or nil
			local k_hx = p5 and (p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil
			local k_hp = p6 and (p6 .. p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil

			local h_obj = {}
			if is_synth or (delay < MAX_DELAY) then
				add_metric(a.c, k_c, delay, false, stype); h_obj.c = k_c
				if k_bg then add_metric(a.bg, k_bg, delay, false, stype); h_obj.bg = k_bg end
				if k_tg then add_metric(a.tg, k_tg, delay, false, stype); h_obj.tg = k_tg end
				if k_qg then add_metric(a.qg, k_qg, delay, false, stype); h_obj.qg = k_qg end
				if k_pg then add_metric(a.pg, k_pg, delay, false, stype); h_obj.pg = k_pg end
				if k_hx then add_metric(a.hx, k_hx, delay, false, stype); h_obj.hx = k_hx end
				if k_hp then add_metric(a.hp, k_hp, delay, false, stype); h_obj.hp = k_hp end

				if not is_synth then
					m_app.chars = (m_app.chars or 0) + 1
					m_app.hourly[current_hour].c = (m_app.hourly[current_hour].c or 0) + 1
					if delay > 1000 then m_app.think_time = (m_app.think_time or 0) + delay else m_app.time = (m_app.time or 0) + delay end
					m_app.sent_chars = (m_app.sent_chars or 0) + 1
					m_app.sent_time = (m_app.sent_time or 0) + delay
				else
					if stype == "hotstring" then m_app.hs_chars = (m_app.hs_chars or 0) + 1
					elseif stype == "llm" then m_app.llm_chars = (m_app.llm_chars or 0) + 1 end
				end

				local is_separator = k_c:match("[%s.,!?;:\"()%%]") or k_c == "\n" or k_c == "\194\160" or k_c == "\226\128\175"
				if is_separator then
					if #cur_word > 0 then
						if cur_word:match("[%w\128-\255]") then
							add_metric(a.w, cur_word, 0, word_err, "none")
						end
						cur_word = ""
						word_err = false
					end
				else
					cur_word = cur_word .. k_c
				end
			end

			table.insert(hist, h_obj)
			p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = k_c
		end
		end
	end
end





-- ==================================
-- ==================================
-- ======= 3/ File Management =======
-- ==================================
-- ==================================

--- Returns today's active plain log file.
--- @return string Filepath.
local function get_log_file() 
	local d = os.date("%Y-%m-%d")
	return _state.LOG_DIR .. "/" .. d .. ".log" 
end

--- Persists today's index into a dedicated JSON file (fast write).
function M.save_today_index()
	local idx_file = _state.LOG_DIR .. "/" .. os.date("%Y-%m-%d") .. ".idx"
	local ok, raw = pcall(json.encode, _state.today_idx)
	if not ok then return end

	local f = io.open(idx_file .. ".tmp", "w")
	if f then 
		f:write(raw)
		f:close() 
		os.execute(string.format("mv %q %q", idx_file .. ".tmp", idx_file))
	end
end

--- Persists the fast-load manifest into JSON.
function M.save_manifest()
	local manifest_file = _state.LOG_DIR .. "/manifest.json"
	local ok, raw = pcall(json.encode, _state.manifest)
	if not ok then return end

	local f = io.open(manifest_file .. ".tmp", "w")
	if f then 
		f:write(raw)
		f:close() 
		os.execute(string.format("mv %q %q", manifest_file .. ".tmp", manifest_file))
	end
end

--- Rebuilds today's in-memory index and manifest from the raw log file.
--- @return boolean True when at least one typing event was reconstructed.
function M.rebuild_today_from_raw_log()
	local day_dash = os.date("%Y-%m-%d")
	local day_underscore = os.date("%Y-%m-%d")
	local raw_log_path = _state.LOG_DIR .. "/" .. day_underscore .. ".log"

	if not fs.attributes(raw_log_path) then return false end

	local fh = io.open(raw_log_path, "r")
	if not fh then return false end

	_state.today_idx = {}
	_state.manifest[day_dash] = {}

	local reconstructed_typing_events = 0

	for line in fh:lines() do
		local ok, entry = pcall(json.decode, line)
		if ok and type(entry) == "table" then
			if entry.type == "typing" and type(entry.events) == "table" and #entry.events > 0 then
				M.aggregate_events(entry.events, entry.app or "Unknown", day_dash)
				reconstructed_typing_events = reconstructed_typing_events + 1
			elseif entry.type == "shortcut" and type(entry.key) == "string" and entry.key ~= "" then
				local app_name = (type(entry.app) == "string" and entry.app ~= "") and entry.app or "Unknown"
				local a = _state.today_idx[app_name]
				if type(a) ~= "table" then
					a = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {} }
					_state.today_idx[app_name] = a
				end
				a.sc = type(a.sc) == "table" and a.sc or {}
				local sc_item = a.sc[entry.key]
				if type(sc_item) ~= "table" then sc_item = {}; a.sc[entry.key] = sc_item end
				sc_item.c = (sc_item.c or 0) + 1
			elseif entry.type == "app_switch" then
				local prev_app = (type(entry.prev_app) == "string" and entry.prev_app ~= "") and entry.prev_app or "Unknown"
				local next_app = (type(entry.next_app) == "string" and entry.next_app ~= "") and entry.next_app or "Unknown"
				local duration_ms = tonumber(entry.duration_ms) or 0
				local m_day = _state.manifest[day_dash]
				local m_app = m_day[prev_app]
				if type(m_app) ~= "table" then
					m_app = { chars = 0, time = 0, think_time = 0, sent = 0, sent_time = 0, sent_chars = 0, hs_chars = 0, llm_chars = 0, hs_triggers = 0, llm_triggers = 0, hs_suggested = 0, llm_suggested = 0, hourly = {}, app_time_ms = 0, switches_to = {}, category = M.get_native_app_category(prev_app) }
					m_day[prev_app] = m_app
				end
				m_app.app_time_ms = (m_app.app_time_ms or 0) + duration_ms
				m_app.switches_to = type(m_app.switches_to) == "table" and m_app.switches_to or {}
				m_app.switches_to[next_app] = (m_app.switches_to[next_app] or 0) + 1
			elseif entry.type == "hotstring_suggested" or entry.type == "llm_suggested" then
				local app_name = (type(entry.app) == "string" and entry.app ~= "") and entry.app or "Unknown"
				local m_day = _state.manifest[day_dash]
				local m_app = m_day[app_name]
				if type(m_app) ~= "table" then
					m_app = { chars = 0, time = 0, think_time = 0, sent = 0, sent_time = 0, sent_chars = 0, hs_chars = 0, llm_chars = 0, hs_triggers = 0, llm_triggers = 0, hs_suggested = 0, llm_suggested = 0, hourly = {}, app_time_ms = 0, switches_to = {}, category = M.get_native_app_category(app_name) }
					m_day[app_name] = m_app
				end
				if entry.type == "hotstring_suggested" then
					m_app.hs_suggested = (m_app.hs_suggested or 0) + 1
				else
					m_app.llm_suggested = (m_app.llm_suggested or 0) + 1
				end
			end
		end
	end

	fh:close()
	M.save_today_index()
	M.save_manifest()
	_last_forced_save_ms = timer.absoluteTime() / 1000000

	return reconstructed_typing_events > 0
end

--- Detects whether today's index is effectively empty outside shortcuts.
--- @return boolean True if only shortcuts are present or all buckets are empty.
local function is_today_idx_sparse()
	if type(_state.today_idx) ~= "table" then return true end

	for _, app_data in pairs(_state.today_idx) do
		if type(app_data) == "table" then
			if type(app_data.c) == "table" and next(app_data.c) ~= nil then return false end
			if type(app_data.bg) == "table" and next(app_data.bg) ~= nil then return false end
			if type(app_data.tg) == "table" and next(app_data.tg) ~= nil then return false end
			if type(app_data.qg) == "table" and next(app_data.qg) ~= nil then return false end
			if type(app_data.pg) == "table" and next(app_data.pg) ~= nil then return false end
			if type(app_data.hx) == "table" and next(app_data.hx) ~= nil then return false end
			if type(app_data.hp) == "table" and next(app_data.hp) ~= nil then return false end
			if type(app_data.w) == "table" and next(app_data.w) ~= nil then return false end
		end
	end

	return true
end

--- Parses unindexed raw files on boot to heal the state.
function M.rebuild_index_if_needed()
	Logger.debug(LOG, "Rebuilding log index if necessary…")
	if not fs.attributes(_state.LOG_DIR) then fs.mkdir(_state.LOG_DIR) end

	local manifest_file = _state.LOG_DIR .. "/manifest.json"
	local f = io.open(manifest_file, "r")
	if f then
		local c = f:read("*a")
		f:close()
		pcall(function() _state.manifest = json.decode(c) or {} end)
	end

	local today_str = os.date("%Y-%m-%d")
	local today_idx_file = _state.LOG_DIR .. "/" .. today_str .. ".idx"
	local f_idx = io.open(today_idx_file, "r")
	if f_idx then
		local c = f_idx:read("*a")
		f_idx:close()
		pcall(function() _state.today_idx = json.decode(c) or {} end)
	end

	if is_today_idx_sparse() then
		local ok = pcall(M.rebuild_today_from_raw_log)
		if ok then Logger.info(LOG, "Today's metrics were rebuilt from raw logs.") end
	end

	-- Look for old orphan .idx files and merge them into the DB
	for f_name in hs.fs.dir(_state.LOG_DIR) do
		local y, m, d = f_name:match("^(%d%d%d%d)_(%d%d)_(%d%d)%.idx$")
		if y and m and d then
			local d_str = string.format("%s_%s_%s", y, m, d)
			if d_str ~= today_str then
				local full_path = _state.LOG_DIR .. "/" .. f_name
				local file = io.open(full_path, "r")
				if file then
					local c = file:read("*a")
					file:close()
					local ok, old_idx = pcall(json.decode, c)
					if ok and type(old_idx) == "table" then
						local m_date_str = string.format("%s-%s-%s", y, m, d)
						local old_manifest = _state.manifest[m_date_str] or {}
						M.merge_day_to_db(m_date_str, old_idx, old_manifest)
						os.remove(full_path)
					end
				end
			end
		end
	end
	Logger.info(LOG, "Index rebuild evaluation completed.")
end





-- ====================================
-- ====================================
-- ======= 4/ Encrypted DB Core =======
-- ====================================
-- ====================================

--- Securely opens, merges a day, and re-encrypts the SQLite DB.
--- @param date_str string The date string (YYYY-MM-DD).
--- @param idx_data table The daily index object.
--- @param manifest_data table The daily manifest object.
function M.merge_day_to_db(date_str, idx_data, manifest_data)
	Logger.debug(LOG, string.format("Merging daily logs into encrypted database for %s…", date_str))
	local db_path = _state.LOG_DIR .. "/metrics.sqlite"
	local enc_path = db_path .. ".enc"
	local tmp_path = os.tmpname()
	local pwd = _state.get_mac_serial():gsub("\"", "\\\"")

	if fs.attributes(enc_path) then
		hs.execute(string.format("openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>/dev/null", pwd, enc_path, tmp_path))
	end
	
	local db = sqlite3.open(tmp_path)
	if db then
		db:exec([[
			CREATE TABLE IF NOT EXISTS daily_manifest (date TEXT, app_name TEXT, stats_json TEXT, UNIQUE(date, app_name));
			CREATE TABLE IF NOT EXISTS daily_index (date TEXT, app_name TEXT, index_json TEXT, UNIQUE(date, app_name));
		]])
		
		db:exec("BEGIN TRANSACTION;")
		
		local stmt_idx = db:prepare("INSERT OR REPLACE INTO daily_index (date, app_name, index_json) VALUES (?, ?, ?)")
		if stmt_idx then
			for app_name, data in pairs(idx_data or {}) do
				stmt_idx:bind_values(date_str, app_name, json.encode(data))
				stmt_idx:step()
				stmt_idx:reset()
			end
			stmt_idx:finalize()
		end
		
		local stmt_man = db:prepare("INSERT OR REPLACE INTO daily_manifest (date, app_name, stats_json) VALUES (?, ?, ?)")
		if stmt_man then
			for app_name, data in pairs(manifest_data or {}) do
				stmt_man:bind_values(date_str, app_name, json.encode(data))
				stmt_man:step()
				stmt_man:reset()
			end
			stmt_man:finalize()
		end
		
		db:exec("COMMIT;")
		db:close()
		
		hs.execute(string.format("openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q", pwd, tmp_path, enc_path))
	end
	os.remove(tmp_path)
	Logger.info(LOG, "Daily logs merged successfully.")
end

--- Retrieves a unique device serial key safely.
--- @return string The MAC serial or fallback identifier.
function M.get_mac_serial()
	return _state.get_mac_serial()
end

--- Increments a simple stat in the fast manifest immediately.
--- @param app_name string Focus app.
--- @param stat_key string The metric to increment.
function M.increment_manifest_stat(app_name, stat_key)
	local date_str = os.date("%Y-%m-%d")
	local m_day = _state.manifest[date_str]
	if type(m_day) ~= "table" then m_day = {}; _state.manifest[date_str] = m_day end
	local m_app = m_day[app_name or "Unknown"]
	if type(m_app) ~= "table" then m_app = { chars = 0, time = 0, think_time = 0, sent = 0, sent_time = 0, sent_chars = 0, hs_chars = 0, llm_chars = 0, hs_triggers = 0, llm_triggers = 0, hs_suggested = 0, llm_suggested = 0, hourly = {}, app_time_ms = 0, switches_to = {}, category = M.get_native_app_category(app_name) }; m_day[app_name or "Unknown"] = m_app end
	
	m_app[stat_key] = (m_app[stat_key] or 0) + 1
	debounced_save()
end

--- Records an application context switch with focus duration.
--- @param prev_app string Previously focused application.
--- @param next_app string The new application taking focus.
--- @param duration_ms number Duration spent in the previous app.
function M.log_app_switch(prev_app, next_app, duration_ms)
	local date_str = os.date("%Y-%m-%d")
	local m_day = _state.manifest[date_str]
	if type(m_day) ~= "table" then m_day = {}; _state.manifest[date_str] = m_day end

	local m_app = m_day[prev_app or "Unknown"]
	if type(m_app) ~= "table" then
		m_app = { chars = 0, time = 0, think_time = 0, sent = 0, sent_time = 0, sent_chars = 0, hs_chars = 0, llm_chars = 0, hs_triggers = 0, llm_triggers = 0, hs_suggested = 0, llm_suggested = 0, hourly = {}, app_time_ms = 0, switches_to = {}, category = M.get_native_app_category(prev_app) }
		m_day[prev_app or "Unknown"] = m_app
	end

	m_app.app_time_ms = (m_app.app_time_ms or 0) + duration_ms
	m_app.switches_to = type(m_app.switches_to) == "table" and m_app.switches_to or {}
	m_app.switches_to[next_app or "Unknown"] = (m_app.switches_to[next_app or "Unknown"] or 0) + 1

	M.append_log({ type = "app_switch", prev_app = prev_app, next_app = next_app, duration_ms = duration_ms })
	debounced_save()
end

--- Records system-level activities like waking or sleeping.
--- @param event_type string Identifier for the event ("sleep", "wake").
function M.log_system_event(event_type)
	M.append_log({ type = "system_event", action = event_type })
end

--- Records a single keyboard shortcut immediately into the index and the log file.
--- @param shortcut_key string The formatted shortcut string (e.g. "Cmd+C").
--- @param app_name string The frontmost application name at time of press.
function M.log_shortcut(shortcut_key, app_name)
	if type(shortcut_key) ~= "string" or shortcut_key == "" then return end
	app_name = (type(app_name) == "string" and app_name ~= "") and app_name or "Unknown"

	local a = _state.today_idx[app_name]
	if type(a) ~= "table" then
		a = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {} }
		_state.today_idx[app_name] = a
	end
	a.sc = type(a.sc) == "table" and a.sc or {}

	local sc_item = a.sc[shortcut_key]
	if type(sc_item) ~= "table" then sc_item = {}; a.sc[shortcut_key] = sc_item end
	sc_item.c = (sc_item.c or 0) + 1

	M.append_log({ type = "shortcut", key = shortcut_key, app = app_name })
	M.save_today_index()
	debounced_save()
end

--- Atomic log appender. Uses fast native append mode.
--- @param entry table Dictionary payload.
function M.append_log(entry)
	local filepath = get_log_file()
	local now_ms = hs.timer.absoluteTime() / 1000000
	local ms_part = math.floor(now_ms) % 1000
	entry.timestamp = string.format("%s.%03d", os.date("%Y-%m-%d %H:%M:%S"), ms_part)
	
	local ok, str = pcall(json.encode, entry)
	if not ok then return end
	str = str:gsub("\n", "")
	
	local f = io.open(filepath, "a")
	if f then
		f:write(str .. "\n")
		f:close()
	end
end

--- Writes buffer to disk, aggregates, and alerts the UI contexts real-time.
function M.flush_buffer()
	if #_state.buffer_events == 0 and _state.session_mouse_clicks == 0 and _state.session_mouse_scrolls == 0 then return end
	Logger.debug(LOG, "Flushing event buffer…")
	
	local total_time_ms, total_chars = 0, 0
	for _, ev in ipairs(_state.buffer_events) do
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
	for _, chunk in ipairs(_state.rich_chunks) do
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

	M.append_log({ 
		type            = "typing", 
		text            = _state.buffer_text, 
		rich_text       = rich_str, 
		app             = _state.session_app_name, 
		title           = _state.session_win_title, 
		url             = _state.session_url,
		field_role      = _state.session_field_role, 
		layout          = _state.session_layout,
		document_path   = _state.session_document_path,
		is_fullscreen   = _state.is_fullscreen,
		in_meeting      = _state.in_meeting,
		mouse_clicks    = _state.session_mouse_clicks,
		mouse_scrolls   = _state.session_mouse_scrolls,
		pause_before_ms = _state.current_session_pause,
		wpm             = tonumber(string.format("%.1f", wpm)), 
		events          = _state.buffer_events 
	})

	local ok, err = pcall(function()
		M.aggregate_events(_state.buffer_events, _state.session_app_name, os.date("%Y-%m-%d"))
		debounced_save()
	end)
	
	if not ok then Logger.error(LOG, string.format("Aggregation failure: %s.", tostring(err))) end
	
	-- Push Real-Time Updates to Open WebViews
	local ok_metrics, metrics = pcall(require, "ui.metrics_typing.init")
	if ok_metrics and type(metrics.push_live_update) == "function" then
		metrics.push_live_update(_state.today_idx)
	end

	local ok_apps, apps_time = pcall(require, "ui.metrics_apps.init")
	if ok_apps and type(apps_time.push_live_update) == "function" then
		apps_time.push_live_update(_state.manifest)
	end
	
	_state.buffer_events = {}
	_state.buffer_text = ""
	_state.rich_chunks = {}
	_state.last_time = 0
	_state.pending_keyup = {}
	_state.session_mouse_clicks = 0
	_state.session_mouse_scrolls = 0
	_state.last_flush_time = hs.timer.absoluteTime() / 1000000
	Logger.info(LOG, "Event buffer flushed successfully.")
end

--- Mounts the shared state.
--- @param core_state table The shared state object.
function M.init(core_state)
	_state = core_state
end

return M
