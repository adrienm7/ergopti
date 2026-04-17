--- modules/keylogger/log_manager.lua

--- ==============================================================================
--- MODULE: Keylogger Log Manager
--- DESCRIPTION:
--- Handles all data persistence for the keylogger: aggregating raw keystroke
--- events into N-gram indexes, managing JSON log files and daily manifests,
--- and securely merging historical data into an encrypted SQLite database.
---
--- FEATURES & RATIONALE:
--- 1. Math Offloading: Keeps N-gram computation out of the fast keystroke loop.
--- 2. Fail Fast: Every public function guards against uninitialized state.
--- 3. Atomic Writes: Uses .tmp + mv to prevent log corruption on crash.
--- 4. Persistent N-Grams: Bigram context survives real-time UI flushes.
--- 5. Encrypted History: Daily data merges into AES-256-CBC encrypted SQLite.
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




-- ================================
-- ================================
-- ======= 1/ Constants =======
-- ================================
-- ================================

-- Maximum delay between keystrokes before breaking N-gram continuity (5 seconds)
local MAX_KEYSTROKE_DELAY_MS   = 5000
-- Maximum delay before a keystroke is classified as a "thinking pause"
local THINK_PAUSE_THRESHOLD_MS = 2000
-- How long to wait after the last save before writing (debounce)
local DEBOUNCE_SAVE_SEC        = 1.5
-- Minimum gap between forced saves to avoid blocking the event loop
local FORCE_SAVE_INTERVAL_MS   = 10000
-- Maximum per-event delay capped in WPM computation to avoid outlier inflation
local WPM_MAX_EVENT_DELAY_MS   = 5000

-- French translations for macOS app category identifiers
local MAC_CATEGORIES_FR = {
	["Productivity"]     = "Productivité",
	["Social networking"] = "Réseaux sociaux",
	["Games"]            = "Jeux",
	["Entertainment"]    = "Divertissement",
	["Utilities"]        = "Utilitaires",
	["Education"]        = "Éducation",
	["Finance"]          = "Finance",
	["Business"]         = "Business",
	["Graphics design"]  = "Design graphique",
	["Photography"]      = "Photographie",
	["Video"]            = "Vidéo",
	["Music"]            = "Musique",
	["Medical"]          = "Médical",
	["Health fitness"]   = "Santé & Forme",
	["Lifestyle"]        = "Style de vie",
	["News"]             = "Actualités",
	["Weather"]          = "Météo",
	["Sports"]           = "Sport",
	["Travel"]           = "Voyage",
	["Navigation"]       = "Navigation",
	["Reference"]        = "Références",
	["Developer tools"]  = "Développement",
}




-- ==============================
-- ==============================
-- ======= 2/ Module State =======
-- ==============================
-- ==============================

local _state               = nil
local _save_timer          = nil
local _last_forced_save_ms = 0
local _mac_serial_cache    = nil




-- ============================================
-- ============================================
-- ======= 3/ Guard, Helpers, And Util =======
-- ============================================
-- ============================================

--- Guards every public function against being called before M.init().
--- @param func_name string The calling function name for the error message.
--- @return boolean False if state is not ready, true otherwise.
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — module non-functional.", func_name)
		return false
	end
	return true
end


--- Removes the last UTF-8 character from a string safely.
--- @param s string The input string.
--- @return string The string with its last character removed.
local function pop_utf8(s)
	if #s == 0 then return s end
	local ok, offset = pcall(utf8.offset, s, -1)
	if ok and offset then return s:sub(1, offset - 1) end
	-- Fallback for malformed UTF-8: strip the last byte
	return s:sub(1, -2)
end

--- Accumulates a metric into a dictionary using the compact storage schema.
--- Schema keys: c (count), t (total delay ms), e (error/backspace count),
--- hs (hotstring count), llm (LLM count), o (other synthetic count).
--- @param dict table The target metric dictionary.
--- @param key string The n-gram string used as the dict key.
--- @param delay number The inter-keystroke delay in milliseconds.
--- @param is_error boolean True if this keystroke was subsequently backspaced.
--- @param synth_type string The generation source ("hotstring", "llm", "none", …).
local function add_metric(dict, key, delay, is_error, synth_type)
	local item = dict[key]
	if type(item) ~= "table" then
		item = {}
		dict[key] = item
	end
	if is_error then
		item.e = (item.e or 0) + 1
	else
		item.c = (item.c or 0) + 1
		if synth_type == "hotstring" then
			item.hs = (item.hs or 0) + 1
		elseif synth_type == "llm" then
			item.llm = (item.llm or 0) + 1
		elseif synth_type ~= "none" then
			item.o = (item.o or 0) + 1
		elseif delay > 0 then
			item.t = (item.t or 0) + delay
		end
	end
end

--- Debounces index and manifest saves to avoid blocking the OS event loop.
--- Writes immediately if the forced-save interval has elapsed; otherwise
--- schedules a deferred write 1.5 seconds after the last call.
local function debounced_save()
	local now_ms = timer.absoluteTime() / 1000000
	if (now_ms - _last_forced_save_ms) >= FORCE_SAVE_INTERVAL_MS then
		M.save_today_index()
		M.save_manifest()
		_last_forced_save_ms = now_ms
	end

	if _save_timer then _save_timer:stop() end
	_save_timer = timer.doAfter(DEBOUNCE_SAVE_SEC, function()
		Logger.trace(LOG, "Executing debounced save…")
		M.save_today_index()
		M.save_manifest()
		_last_forced_save_ms = timer.absoluteTime() / 1000000
		Logger.done(LOG, "Debounced save completed.")
	end)
end


--- Builds a fresh manifest app entry with all fields zeroed.
--- Centralizes the structure so it only needs to be defined once.
--- @param app_name string The application name (used to fetch its category).
--- @return table A fully-initialized manifest entry for one app.
local function new_manifest_app_entry(app_name)
	return {
		chars         = 0,
		pauses        = 0,
		time          = 0,
		think_time    = 0,
		sent          = 0,
		sent_time     = 0,
		sent_chars    = 0,
		hs_chars      = 0,
		llm_chars     = 0,
		hs_triggers   = 0,
		llm_triggers  = 0,
		hs_suggested  = 0,
		llm_suggested = 0,
		app_time_ms   = 0,
		hourly        = {},
		switches_to   = {},
		category      = M.get_native_app_category(app_name),
	}
end

--- Returns (or creates) the manifest entry for a given app on a given day.
--- Avoids repeated boilerplate throughout flush, rebuild, and log functions.
--- @param date_str string The date key ("YYYY-MM-DD").
--- @param app_name string The application name.
--- @return table The manifest entry table (always non-nil).
local function get_or_create_manifest_app(date_str, app_name)
	local m_day = _state.manifest[date_str]
	if type(m_day) ~= "table" then
		m_day = {}
		_state.manifest[date_str] = m_day
	end
	local safe_name = (type(app_name) == "string" and app_name ~= "") and app_name or "Unknown"
	local m_app = m_day[safe_name]
	if type(m_app) ~= "table" then
		m_app = new_manifest_app_entry(safe_name)
		m_day[safe_name] = m_app
	end
	return m_app
end




-- ==========================================
-- ==========================================
-- ======= 4/ App Category Detection =======
-- ==========================================
-- ==========================================

--- Queries macOS for the official App Store category of an application.
--- Falls back to "Général" when the bundle info is unavailable.
--- @param app_name string The application display name.
--- @return string The French category label.
function M.get_native_app_category(app_name)
	local app = hs.application.get(app_name)
	if app then
		local info = hs.application.infoForBundlePath(app:path())
		if info and info.LSApplicationCategoryType then
			local raw_cat = info.LSApplicationCategoryType:gsub("public%.app%-category%.", "")
			raw_cat = raw_cat:gsub("%-", " ")
			local capitalized = raw_cat:sub(1, 1):upper() .. raw_cat:sub(2)
			return MAC_CATEGORIES_FR[capitalized] or capitalized
		end
	end
	return "Général"
end




-- ==========================================
-- ==========================================
-- ======= 5/ N-Gram Aggregation Core =======
-- ==========================================
-- ==========================================

--- Compiles a batch of raw keystroke events into the in-memory N-gram index
--- and updates the daily manifest with productivity statistics.
--- N-gram context (the rolling window of previous characters) is persisted
--- on CoreState so real-time UI flushes do not break cross-flush bigrams.
--- @param events table Raw keystroke event array from the buffer.
--- @param app_name string The application that was focused during typing.
--- @param date_str string The date key for this batch ("YYYY-MM-DD").
function M.aggregate_events(events, app_name, date_str)
	if not require_state("aggregate_events") then return end
	date_str = date_str or os.date("%Y-%m-%d")

	-- Get-or-create the per-app index bucket
	local app_idx = _state.today_idx[app_name]
	if type(app_idx) ~= "table" then
		app_idx = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
		_state.today_idx[app_name] = app_idx
	end
	-- Ensure secondary sub-tables always exist (for indexes loaded from older .idx files)
	app_idx.sc    = type(app_idx.sc)    == "table" and app_idx.sc    or {}
	app_idx.sc_bg = type(app_idx.sc_bg) == "table" and app_idx.sc_bg or {}
	app_idx.w_bg  = type(app_idx.w_bg)  == "table" and app_idx.w_bg  or {}

	local m_app = get_or_create_manifest_app(date_str, app_name)

	local t            = os.date("*t")
	local current_hour = string.format("%02d", t.hour)
	local current_min5 = string.format("%02d:%02d", t.hour, math.floor(t.min / 5) * 5)

	m_app.hourly = type(m_app.hourly) == "table" and m_app.hourly or {}
	if type(m_app.hourly[current_hour]) ~= "table" then
		m_app.hourly[current_hour] = { c = 0, e = 0, em = 0, es = 0 }
	end

	m_app.hourly_min5 = type(m_app.hourly_min5) == "table" and m_app.hourly_min5 or {}
	if type(m_app.hourly_min5[current_min5]) ~= "table" then
		m_app.hourly_min5[current_min5] = { c = 0, e = 0, es = 0 }
	end

	-- Restore the persistent N-gram context so UI flushes don't break bigrams
	_state.ngram_context = _state.ngram_context or {
		p1 = nil, p2 = nil, p3 = nil, p4 = nil, p5 = nil, p6 = nil,
		cur_word = "", word_err = false, hist = {},
		prev_word = nil, prev_sc = nil
	}
	local ctx = _state.ngram_context

	local p1, p2, p3, p4, p5, p6 = ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6
	local cur_word   = ctx.cur_word
	local word_err   = ctx.word_err
	local backtrack  = ctx.hist   -- history of recorded n-gram keys, for backspace undo
	local prev_word  = ctx.prev_word
	local prev_sc    = ctx.prev_sc
	local prev_synth_type = "none"

	for _, ev in ipairs(events) do
		local char         = ev[1]
		local delay        = ev[2] or 0
		local meta         = ev[3] or {}
		local shortcut_key = meta.sc
		local is_backspace = (char == "[BS]")
		local synth_type   = meta.st or "none"
		local is_synthetic = meta.s or false

		-- Shortcuts are indexed separately and do not participate in N-gram chains
		if type(shortcut_key) == "string" and shortcut_key ~= "" then
			if prev_sc then
				add_metric(app_idx.sc_bg, prev_sc .. "→" .. shortcut_key, delay, false, "none")
			end
			add_metric(app_idx.sc, shortcut_key, delay, false, "none")
			prev_sc = shortcut_key
		else

			-- A very long pause between keystrokes breaks N-gram continuity
			if delay >= MAX_KEYSTROKE_DELAY_MS and not is_synthetic then
				p1, p2, p3, p4, p5, p6 = nil, nil, nil, nil, nil, nil
				backtrack = {}
				-- Flush any in-progress word before resetting context
				if #cur_word > 0 then
					if prev_word then
						add_metric(app_idx.w_bg, prev_word .. " " .. cur_word, 0, word_err, "none")
					end
					add_metric(app_idx.w, cur_word, 0, word_err, "none")
				end
				cur_word  = ""
				word_err  = false
				prev_word = nil
				prev_sc   = nil
			end

			-- Count trigger events once per synthetic burst (avoids per-char inflation)
			if is_synthetic and synth_type ~= "none" and synth_type ~= prev_synth_type then
				if synth_type == "hotstring" then
					m_app.hs_triggers = (m_app.hs_triggers or 0) + 1
				elseif synth_type == "llm" then
					m_app.llm_triggers = (m_app.llm_triggers or 0) + 1
				end
			end
			prev_synth_type = is_synthetic and synth_type or "none"

			if is_backspace then
				-- Undo the last recorded n-gram so the error rate is accurate
				if #backtrack > 0 then
					local last_entry = table.remove(backtrack)
					if last_entry.c ~= "[BS]" then
						if last_entry.c  then add_metric(app_idx.c,  last_entry.c,  0, true) end
						if last_entry.bg then add_metric(app_idx.bg, last_entry.bg, 0, true) end
						if last_entry.tg then add_metric(app_idx.tg, last_entry.tg, 0, true) end
						if last_entry.qg then add_metric(app_idx.qg, last_entry.qg, 0, true) end
						if last_entry.pg then add_metric(app_idx.pg, last_entry.pg, 0, true) end
						if last_entry.hx then add_metric(app_idx.hx, last_entry.hx, 0, true) end
						if last_entry.hp then add_metric(app_idx.hp, last_entry.hp, 0, true) end
					end
				end

				cur_word = pop_utf8(cur_word)
				word_err = true

				-- Hourly error tracking (distinguish physical vs synthetic errors)
				if is_synthetic then
					m_app.hourly[current_hour].es     = (m_app.hourly[current_hour].es     or 0) + 1
					m_app.hourly_min5[current_min5].es = (m_app.hourly_min5[current_min5].es or 0) + 1
					if synth_type == "hotstring" then
						m_app.hs_chars = math.max(0, (m_app.hs_chars or 0) - 1)
					elseif synth_type == "llm" then
						m_app.llm_chars = math.max(0, (m_app.llm_chars or 0) - 1)
					end
				else
					m_app.hourly[current_hour].e      = (m_app.hourly[current_hour].e      or 0) + 1
					m_app.hourly[current_hour].em     = (m_app.hourly[current_hour].em     or 0) + 1
					m_app.hourly_min5[current_min5].e = (m_app.hourly_min5[current_min5].e or 0) + 1
					m_app.chars     = (m_app.chars or 0) + 1
					if delay > THINK_PAUSE_THRESHOLD_MS then
						m_app.think_time = (m_app.think_time or 0) + delay
						m_app.pauses     = (m_app.pauses or 0) + 1
					else
						m_app.time = (m_app.time or 0) + delay
					end
				end

				-- Record the backspace keystroke and its bigram/trigram for pattern analysis
				local bs_entry = {}
				add_metric(app_idx.c, "[BS]", delay, false, synth_type); bs_entry.c = "[BS]"
				if p1 then
					add_metric(app_idx.bg, p1 .. "[BS]", delay, false, synth_type)
					bs_entry.bg = p1 .. "[BS]"
				end
				if p2 then
					add_metric(app_idx.tg, p2 .. p1 .. "[BS]", delay, false, synth_type)
					bs_entry.tg = p2 .. p1 .. "[BS]"
				end
				table.insert(backtrack, bs_entry)
				p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = "[BS]"

			else
				-- Normal (non-backspace) character
				local k_c  = char
				local k_bg = p1 and (p1 .. k_c) or nil
				local k_tg = p2 and (p2 .. p1 .. k_c) or nil
				local k_qg = p3 and (p3 .. p2 .. p1 .. k_c) or nil
				local k_pg = p4 and (p4 .. p3 .. p2 .. p1 .. k_c) or nil
				local k_hx = p5 and (p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil
				local k_hp = p6 and (p6 .. p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil

				-- Bracket markers ([LEFT], [ENTER], [F1]…) represent genuine key presses that
				-- are always worth recording regardless of how long the user paused before
				-- pressing them. Navigation is typically done after reading pauses (> 5 s),
				-- so without this exception they would be silently dropped. The delay is
				-- clamped to 0 for bracket keys exceeding the threshold so the long pause
				-- is not attributed to inter-key typing speed.
				local is_bracket_key  = k_c:sub(1, 1) == "[" and k_c:sub(-1) == "]"
				local record_delay    = delay < MAX_KEYSTROKE_DELAY_MS and delay or 0

				local entry = {}
				if is_synthetic or is_bracket_key or delay < MAX_KEYSTROKE_DELAY_MS then
					add_metric(app_idx.c, k_c, record_delay, false, synth_type); entry.c = k_c
					if k_bg then add_metric(app_idx.bg, k_bg, record_delay, false, synth_type); entry.bg = k_bg end
					if k_tg then add_metric(app_idx.tg, k_tg, record_delay, false, synth_type); entry.tg = k_tg end
					if k_qg then add_metric(app_idx.qg, k_qg, record_delay, false, synth_type); entry.qg = k_qg end
					if k_pg then add_metric(app_idx.pg, k_pg, record_delay, false, synth_type); entry.pg = k_pg end
					if k_hx then add_metric(app_idx.hx, k_hx, record_delay, false, synth_type); entry.hx = k_hx end
					if k_hp then add_metric(app_idx.hp, k_hp, record_delay, false, synth_type); entry.hp = k_hp end

					if not is_synthetic then
						m_app.chars      = (m_app.chars or 0) + 1
						m_app.sent_chars = (m_app.sent_chars or 0) + 1
						m_app.sent_time  = (m_app.sent_time or 0) + record_delay
						m_app.hourly[current_hour].c      = (m_app.hourly[current_hour].c      or 0) + 1
						m_app.hourly_min5[current_min5].c = (m_app.hourly_min5[current_min5].c or 0) + 1
						if record_delay > THINK_PAUSE_THRESHOLD_MS then
							m_app.think_time = (m_app.think_time or 0) + record_delay
							m_app.pauses     = (m_app.pauses or 0) + 1
						else
							m_app.time = (m_app.time or 0) + record_delay
						end
					else
						if synth_type == "hotstring" then
							m_app.hs_chars = (m_app.hs_chars or 0) + 1
						elseif synth_type == "llm" then
							m_app.llm_chars = (m_app.llm_chars or 0) + 1
						end
					end

					-- Word boundary detection: flush cur_word on separators
					local is_separator = k_c:match("[%s.,!?;:\"'()%%{}%[%]<>=+*/\\|%-]") ~= nil
						or k_c == "\n" or k_c == "\194\160" or k_c == "\226\128\175"
					if is_separator then
						if #cur_word > 0 then
							-- Track consecutive word pair before committing the current word
							if prev_word then
								add_metric(app_idx.w_bg, prev_word .. " " .. cur_word, 0, word_err, "none")
							end
							add_metric(app_idx.w, cur_word, 0, word_err, "none")
							prev_word = cur_word
							cur_word  = ""
							word_err  = false
						end
					else
						cur_word = cur_word .. k_c
					end
				end

				table.insert(backtrack, entry)
				p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = k_c
			end
		end

		-- Log the physical keycode for every non-synthetic keystroke so the Keycodes
		-- tab can show raw physical-key frequency independently of character encoding
		if not is_synthetic then
			local kc_num = meta.kc
			if type(kc_num) == "number" then
				add_metric(app_idx.kc, tostring(kc_num), delay, false, "none")
			end
		end
	end

	-- Persist N-gram context back to state for the next flush
	ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6 = p1, p2, p3, p4, p5, p6
	ctx.cur_word  = cur_word
	ctx.word_err  = word_err
	ctx.hist      = backtrack
	ctx.prev_word = prev_word
	ctx.prev_sc   = prev_sc
end




-- =========================================
-- =========================================
-- ======= 6/ File Persistence Layer =======
-- =========================================
-- =========================================

--- Returns the path to today's plain-text event log file.
--- @return string The absolute file path.
local function get_log_file()
	return _state.LOG_DIR .. "/" .. os.date("%Y-%m-%d") .. ".log"
end

--- Atomically writes today's in-memory index to a JSON file.
--- Uses a .tmp intermediate to prevent corruption if the process is killed mid-write.
function M.save_today_index()
	if not require_state("save_today_index") then return end
	local idx_path = _state.LOG_DIR .. "/" .. os.date("%Y-%m-%d") .. ".idx"
	local tmp_path = idx_path .. ".tmp"

	local ok, raw = pcall(json.encode, _state.today_idx)
	if not ok then
		Logger.error(LOG, "Failed to JSON-encode today's index: %s.", tostring(raw))
		return
	end

	local f, err = io.open(tmp_path, "w")
	if not f then
		Logger.error(LOG, "Cannot open '%s' for writing: %s.", tmp_path, tostring(err))
		return
	end
	f:write(raw)
	f:close()

	local mv_ok = os.execute(string.format("mv %q %q", tmp_path, idx_path))
	if not mv_ok then
		Logger.error(LOG, "Atomic rename failed for today's index (tmp → idx).")
	end
end

--- Atomically writes the daily manifest to a JSON file.
--- Uses a .tmp intermediate to prevent corruption if the process is killed mid-write.
function M.save_manifest()
	if not require_state("save_manifest") then return end
	local manifest_path = _state.LOG_DIR .. "/manifest.json"
	local tmp_path      = manifest_path .. ".tmp"

	local ok, raw = pcall(json.encode, _state.manifest)
	if not ok then
		Logger.error(LOG, "Failed to JSON-encode manifest: %s.", tostring(raw))
		return
	end

	local f, err = io.open(tmp_path, "w")
	if not f then
		Logger.error(LOG, "Cannot open '%s' for writing: %s.", tmp_path, tostring(err))
		return
	end
	f:write(raw)
	f:close()

	local mv_ok = os.execute(string.format("mv %q %q", tmp_path, manifest_path))
	if not mv_ok then
		Logger.error(LOG, "Atomic rename failed for manifest (tmp → json).")
	end
end

--- Replays today's raw .log file to rebuild the in-memory index from scratch.
--- Called on boot when the .idx file is found to be empty or missing.
--- @return boolean True when at least one typing event was successfully replayed.
function M.rebuild_today_from_raw_log()
	if not require_state("rebuild_today_from_raw_log") then return false end
	local today = os.date("%Y-%m-%d")
	local raw_log_path = _state.LOG_DIR .. "/" .. today .. ".log"

	if not fs.attributes(raw_log_path) then
		Logger.debug(LOG, "No raw log found at '%s' — nothing to rebuild.", raw_log_path)
		return false
	end

	local fh, err = io.open(raw_log_path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open raw log '%s': %s.", raw_log_path, tostring(err))
		return false
	end

	-- Reset in-memory state before replaying
	_state.today_idx        = {}
	_state.manifest[today]  = {}
	_state.ngram_context    = nil  -- reset N-gram context for clean replay

	local typing_event_count = 0
	-- Track the last shortcut per app to rebuild sc_bg (consecutive shortcut bigrams)
	local prev_sc_by_app = {}

	for line in fh:lines() do
		local ok, entry = pcall(json.decode, line)
		if not ok or type(entry) ~= "table" then
			Logger.debug(LOG, "Skipping malformed log line during rebuild.")
		elseif entry.type == "typing" and type(entry.events) == "table" and #entry.events > 0 then
			M.aggregate_events(entry.events, entry.app or "Unknown", today)
			typing_event_count = typing_event_count + 1
		elseif entry.type == "shortcut" then
			local app_name = (type(entry.app) == "string" and entry.app ~= "") and entry.app or "Unknown"
			local app_idx  = _state.today_idx[app_name]
			if type(app_idx) ~= "table" then
				app_idx = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
				_state.today_idx[app_name] = app_idx
			end
			app_idx.sc    = type(app_idx.sc)    == "table" and app_idx.sc    or {}
			app_idx.sc_bg = type(app_idx.sc_bg) == "table" and app_idx.sc_bg or {}
			app_idx.w_bg  = type(app_idx.w_bg)  == "table" and app_idx.w_bg  or {}
			local sc_entry = app_idx.sc[entry.key] or {}
			sc_entry.c = (sc_entry.c or 0) + 1
			app_idx.sc[entry.key] = sc_entry
			-- Rebuild consecutive shortcut bigrams (same logic as aggregate_events live path)
			if type(prev_sc_by_app[app_name]) == "string" then
				local bg_key  = prev_sc_by_app[app_name] .. "→" .. entry.key
				local bg_entry = app_idx.sc_bg[bg_key] or {}
				bg_entry.c = (bg_entry.c or 0) + 1
				app_idx.sc_bg[bg_key] = bg_entry
			end
			prev_sc_by_app[app_name] = entry.key
		elseif entry.type == "app_switch" then
			local prev_app    = (type(entry.prev_app) == "string" and entry.prev_app ~= "") and entry.prev_app or "Unknown"
			local next_app    = (type(entry.next_app) == "string" and entry.next_app ~= "") and entry.next_app or "Unknown"
			local duration_ms = tonumber(entry.duration_ms) or 0
			local m_app       = get_or_create_manifest_app(today, prev_app)
			m_app.app_time_ms  = (m_app.app_time_ms or 0) + duration_ms
			m_app.switches_to  = type(m_app.switches_to) == "table" and m_app.switches_to or {}
			m_app.switches_to[next_app] = (m_app.switches_to[next_app] or 0) + 1
		elseif entry.type == "hotstring_suggested" or entry.type == "llm_suggested" then
			local app_name = (type(entry.app) == "string" and entry.app ~= "") and entry.app or "Unknown"
			local m_app    = get_or_create_manifest_app(today, app_name)
			if entry.type == "hotstring_suggested" then
				m_app.hs_suggested = (m_app.hs_suggested or 0) + 1
			else
				m_app.llm_suggested = (m_app.llm_suggested or 0) + 1
			end
		end
	end

	fh:close()
	M.save_today_index()
	M.save_manifest()
	_last_forced_save_ms = timer.absoluteTime() / 1000000

	Logger.info(LOG, "Rebuild from raw log complete (%d typing event(s) replayed).", typing_event_count)
	return typing_event_count > 0
end

--- Returns true if today's in-memory index is empty (no character or n-gram data).
--- Shortcuts alone are not sufficient to consider the index populated.
--- @return boolean True when the index has no usable N-gram data.
local function is_today_idx_sparse()
	if type(_state.today_idx) ~= "table" then return true end

	for _, app_data in pairs(_state.today_idx) do
		if type(app_data) == "table" then
			local non_empty_buckets = { "c", "bg", "tg", "qg", "pg", "hx", "hp", "w" }
			for _, bucket in ipairs(non_empty_buckets) do
				if type(app_data[bucket]) == "table" and next(app_data[bucket]) ~= nil then
					return false
				end
			end
		end
	end
	return true
end

--- Loads persisted state from disk on startup and triggers a rebuild when needed.
--- Also migrates any leftover .idx files from previous days into the encrypted DB.
function M.rebuild_index_if_needed()
	if not require_state("rebuild_index_if_needed") then return end
	Logger.start(LOG, "Evaluating index state for rebuild…")

	-- Ensure the log directory exists
	if not fs.attributes(_state.LOG_DIR) then
		local ok, err = pcall(fs.mkdir, _state.LOG_DIR)
		if not ok then
			Logger.error(LOG, "Cannot create log directory '%s': %s.", _state.LOG_DIR, tostring(err))
			return
		end
	end

	-- Load persisted manifest
	local manifest_path = _state.LOG_DIR .. "/manifest.json"
	local mf, _ = io.open(manifest_path, "r")
	if mf then
		local content = mf:read("*a")
		mf:close()
		local ok, decoded = pcall(json.decode, content)
		if ok and type(decoded) == "table" then
			_state.manifest = decoded
		else
			Logger.warn(LOG, "Manifest file could not be parsed — starting with empty manifest.")
		end
	end

	-- Load today's persisted index
	local today = os.date("%Y-%m-%d")
	local idx_path = _state.LOG_DIR .. "/" .. today .. ".idx"
	local fi, _ = io.open(idx_path, "r")
	if fi then
		local content = fi:read("*a")
		fi:close()
		local ok, decoded = pcall(json.decode, content)
		if ok and type(decoded) == "table" then
			_state.today_idx = decoded
		else
			Logger.warn(LOG, "Today's index file could not be parsed — will attempt rebuild from raw log.")
		end
	end

	-- If the index appears empty, replay the raw log to reconstruct it
	if is_today_idx_sparse() then
		Logger.info(LOG, "Today's index is sparse — rebuilding from raw log…")
		local ok, err = pcall(M.rebuild_today_from_raw_log)
		if not ok then
			Logger.error(LOG, "Rebuild from raw log failed: %s.", tostring(err))
		end
	end

	-- Migrate any previous-day .idx files into the encrypted database
	-- Pattern matches "YYYY-MM-DD.idx" — the format used by save_today_index()
	local dir_ok, dir_iter = pcall(fs.dir, _state.LOG_DIR)
	if not dir_ok then
		Logger.error(LOG, "Cannot iterate log directory '%s'.", _state.LOG_DIR)
		Logger.success(LOG, "Index evaluation done (directory error during migration).")
		return
	end

	for file_name in dir_iter do
		local y, mo, d = file_name:match("^(%d%d%d%d)-(%d%d)-(%d%d)%.idx$")
		if y and mo and d then
			local file_date = string.format("%s-%s-%s", y, mo, d)
			-- Only migrate files from previous days
			if file_date ~= today then
				local full_path = _state.LOG_DIR .. "/" .. file_name
				local f, err = io.open(full_path, "r")
				if not f then
					Logger.warn(LOG, "Cannot open '%s' for migration: %s.", full_path, tostring(err))
				else
					local content = f:read("*a")
					f:close()
					local ok, old_idx = pcall(json.decode, content)
					if ok and type(old_idx) == "table" then
						local old_manifest = (_state.manifest[file_date]) or {}
						Logger.debug(LOG, "Migrating '%s' into encrypted database…", file_date)
						M.merge_day_to_db(file_date, old_idx, old_manifest)
						os.remove(full_path)
					else
						Logger.warn(LOG, "Could not parse '%s' — skipping migration.", file_name)
					end
				end
			end
		end
	end

	Logger.success(LOG, "Index evaluation and migration complete.")
end




-- ==========================================
-- ==========================================
-- ======= 7/ Encrypted Database Core =======
-- ==========================================
-- ==========================================

--- Retrieves or computes the Mac hardware serial number, used as the default
--- database encryption password. Caches the result after the first call.
--- @return string The serial number string, or a static fallback key.
function M.get_mac_serial()
	if _mac_serial_cache then return _mac_serial_cache end

	-- Primary: IORegistry (most reliable)
	local serial = hs.execute("ioreg -l | grep IOPlatformSerialNumber | sed 's/.*= \"//;s/\"//'")
	if serial and serial ~= "" and not serial:find("UNKNOWN") then
		_mac_serial_cache = serial:gsub("%s+", "")
		return _mac_serial_cache
	end

	-- Secondary: system_profiler
	local profiler = hs.execute("system_profiler SPHardwareDataType | awk '/Serial Number/ {print $4}'")
	if profiler and profiler ~= "" then
		_mac_serial_cache = profiler:gsub("%s+", "")
		return _mac_serial_cache
	end

	-- Tertiary: platform UUID
	local uuid = hs.execute("ioreg -rd1 -c IOPlatformExpertDevice | grep -E 'IOPlatformUUID' | sed 's/.*= \"//;s/\"//'")
	if uuid and uuid ~= "" then
		_mac_serial_cache = uuid:gsub("%s+", "")
		return _mac_serial_cache
	end

	Logger.warn(LOG, "Could not retrieve Mac serial — using static fallback encryption key.")
	return "ERGOPTI_FALLBACK_KEY"
end

--- Decrypts (if present), opens, merges one day of data, and re-encrypts the
--- SQLite database. This is the archival step that happens after midnight.
--- @param date_str string The date to archive ("YYYY-MM-DD").
--- @param idx_data table The daily N-gram index for that date.
--- @param manifest_data table The daily manifest for that date.
function M.merge_day_to_db(date_str, idx_data, manifest_data)
	if not require_state("merge_day_to_db") then return end
	Logger.start(LOG, "Merging %s into encrypted database…", date_str)

	local db_path  = _state.LOG_DIR .. "/metrics.sqlite"
	local enc_path = db_path .. ".enc"
	local tmp_path = os.tmpname()
	local pwd      = M.get_mac_serial():gsub("\"", "\\\"")

	-- Decrypt existing DB if it exists
	if fs.attributes(enc_path) then
		local dec_ok = os.execute(string.format(
			"openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>/dev/null",
			pwd, enc_path, tmp_path
		))
		if not dec_ok then
			Logger.warn(LOG, "Decryption returned non-zero for %s — DB may be new or corrupted; proceeding.", date_str)
		end
	end

	local db = sqlite3.open(tmp_path)
	if not db then
		Logger.error(LOG, "Failed to open SQLite database at '%s' — aborting merge for %s.", tmp_path, date_str)
		os.remove(tmp_path)
		return
	end

	-- Create tables if this is a fresh database
	local schema_ok = db:exec([[
		CREATE TABLE IF NOT EXISTS daily_manifest
			(date TEXT, app_name TEXT, stats_json TEXT, UNIQUE(date, app_name));
		CREATE TABLE IF NOT EXISTS daily_index
			(date TEXT, app_name TEXT, index_json TEXT, UNIQUE(date, app_name));
	]])
	if schema_ok ~= sqlite3.OK then
		Logger.error(LOG, "Schema creation failed (code %d) — aborting merge for %s.", schema_ok, date_str)
		db:close()
		os.remove(tmp_path)
		return
	end

	db:exec("BEGIN TRANSACTION;")

	local stmt_idx = db:prepare("INSERT OR REPLACE INTO daily_index (date, app_name, index_json) VALUES (?, ?, ?)")
	if stmt_idx then
		for app_name, data in pairs(idx_data or {}) do
			local ok, encoded = pcall(json.encode, data)
			if ok then
				stmt_idx:bind_values(date_str, app_name, encoded)
				stmt_idx:step()
				stmt_idx:reset()
			else
				Logger.warn(LOG, "Skipping index entry for app '%s' — JSON encode failed.", app_name)
			end
		end
		stmt_idx:finalize()
	else
		Logger.error(LOG, "Failed to prepare daily_index INSERT statement for %s.", date_str)
	end

	local stmt_man = db:prepare("INSERT OR REPLACE INTO daily_manifest (date, app_name, stats_json) VALUES (?, ?, ?)")
	if stmt_man then
		for app_name, data in pairs(manifest_data or {}) do
			local ok, encoded = pcall(json.encode, data)
			if ok then
				stmt_man:bind_values(date_str, app_name, encoded)
				stmt_man:step()
				stmt_man:reset()
			else
				Logger.warn(LOG, "Skipping manifest entry for app '%s' — JSON encode failed.", app_name)
			end
		end
		stmt_man:finalize()
	else
		Logger.error(LOG, "Failed to prepare daily_manifest INSERT statement for %s.", date_str)
	end

	db:exec("COMMIT;")
	db:close()

	-- Re-encrypt the updated database
	local enc_ok = os.execute(string.format(
		"openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q",
		pwd, tmp_path, enc_path
	))
	if not enc_ok then
		Logger.error(LOG, "Re-encryption failed for %s — unencrypted tmp file left at '%s'.", date_str, tmp_path)
		return
	end

	os.remove(tmp_path)
	Logger.success(LOG, "Merge of %s into encrypted database complete.", date_str)
end




-- =============================================
-- =============================================
-- ======= 8/ Public Event Logging API =======
-- =============================================
-- =============================================

--- Atomically appends a single JSON event entry to today's log file.
--- Adds a millisecond-precision timestamp to every entry.
--- @param entry table The event payload to serialize and append.
function M.append_log(entry)
	if not require_state("append_log") then return end

	local now_ms  = hs.timer.absoluteTime() / 1000000
	local ms_part = math.floor(now_ms) % 1000
	entry.timestamp = string.format("%s.%03d", os.date("%Y-%m-%d %H:%M:%S"), ms_part)

	local ok, str = pcall(json.encode, entry)
	if not ok then
		Logger.error(LOG, "JSON encode failed for entry type '%s': %s.", tostring(entry.type), tostring(str))
		return
	end

	-- Strip embedded newlines to keep the file strictly one JSON object per line
	str = str:gsub("\n", "")

	local filepath = get_log_file()
	local f, err = io.open(filepath, "a")
	if not f then
		Logger.error(LOG, "Cannot append to log file '%s': %s.", filepath, tostring(err))
		return
	end
	f:write(str .. "\n")
	f:close()
end

--- Serializes the current keystroke buffer to disk, runs N-gram aggregation,
--- and pushes live data to any open metric UI webviews.
--- This is the main flush path, called at sentence boundaries and on context switches.
function M.flush_buffer()
	if not require_state("flush_buffer") then return end
	if #_state.buffer_events == 0
		and _state.session_mouse_clicks == 0
		and _state.session_mouse_scrolls == 0
	then return end

	Logger.trace(LOG, "Flushing event buffer (%d event(s))…", #_state.buffer_events)

	-- Compute a rough WPM for the buffer for metadata tagging
	local total_time_ms, total_chars = 0, 0
	for _, ev in ipairs(_state.buffer_events) do
		local meta = ev[3] or {}
		if not meta.s then
			local d = math.min(ev[2] or 0, WPM_MAX_EVENT_DELAY_MS)
			total_time_ms = total_time_ms + d
			total_chars   = total_chars + 1
		end
	end
	local wpm = total_time_ms > 0 and ((total_chars / 5) / (total_time_ms / 60000)) or 0

	-- Build a rich-text representation of the typed content for qualitative analysis
	local rich_str  = ""
	local cur_type  = nil
	local cur_text  = ""
	for _, chunk in ipairs(_state.rich_chunks) do
		if chunk.type == cur_type then
			cur_text = cur_text .. chunk.text
		else
			if cur_type then
				if cur_type == "text" then
					rich_str = rich_str .. cur_text
				elseif cur_type == "correction" then
					rich_str = rich_str .. "<correction><del>" .. cur_text .. "</del></correction>"
				else
					rich_str = rich_str .. "<autocomplete type=\"" .. cur_type .. "\">" .. cur_text .. "</autocomplete>"
				end
			end
			cur_type = chunk.type
			cur_text = chunk.text
		end
	end
	if cur_type then
		if cur_type == "text" then
			rich_str = rich_str .. cur_text
		elseif cur_type == "correction" then
			rich_str = rich_str .. "<correction><del>" .. cur_text .. "</del></correction>"
		else
			rich_str = rich_str .. "<autocomplete type=\"" .. cur_type .. "\">" .. cur_text .. "</autocomplete>"
		end
	end

	M.append_log({
		type              = "typing",
		text              = _state.buffer_text,
		rich_text         = rich_str,
		app               = _state.session_app_name,
		title             = _state.session_win_title,
		url               = _state.session_url,
		field_role        = _state.session_field_role,
		layout            = _state.session_layout,
		document_path     = _state.session_document_path,
		is_fullscreen     = _state.is_fullscreen,
		in_meeting        = _state.in_meeting,
		mouse_clicks      = _state.session_mouse_clicks,
		mouse_scrolls     = _state.session_mouse_scrolls,
		mouse_distance_px = math.floor(_state.mouse_distance_px),
		pause_before_ms   = _state.current_session_pause,
		battery_level     = _state.current_battery_level,
		audio_volume      = _state.current_audio_volume,
		wpm               = tonumber(string.format("%.1f", wpm)),
		events            = _state.buffer_events,
	})

	-- Aggregate into N-gram index; log failure but do not crash
	local ok, err = pcall(function()
		M.aggregate_events(_state.buffer_events, _state.session_app_name, os.date("%Y-%m-%d"))
		debounced_save()
	end)
	if not ok then
		Logger.error(LOG, "N-gram aggregation failed: %s.", tostring(err))
	end

	-- Push live update to open typing metrics UI (direct table lookup — no pcall overhead)
	local metrics_typing = package.loaded["ui.metrics_typing.init"]
	if metrics_typing and type(metrics_typing.push_live_update) == "function" then
		pcall(metrics_typing.push_live_update, _state.today_idx)
	end

	-- Push live update to open app metrics UI
	local metrics_apps = package.loaded["ui.metrics_apps.init"]
	if metrics_apps and type(metrics_apps.push_live_update) == "function" then
		pcall(metrics_apps.push_live_update, _state.manifest)
	end

	-- Reset buffer state; last_time reset forces the next event's delay to 0
	_state.buffer_events          = {}
	_state.buffer_text            = ""
	_state.rich_chunks            = {}
	_state.last_time              = 0
	_state.pending_keyup          = {}
	_state.session_mouse_clicks   = 0
	_state.session_mouse_scrolls  = 0
	_state.mouse_distance_px      = 0
	_state.last_flush_time        = hs.timer.absoluteTime() / 1000000

	Logger.done(LOG, "Buffer flushed.")
end

--- Records an application context switch and updates the app-time manifest.
--- @param prev_app string The application that just lost focus.
--- @param next_app string The application that gained focus.
--- @param duration_ms number Milliseconds spent in prev_app.
function M.log_app_switch(prev_app, next_app, duration_ms)
	if not require_state("log_app_switch") then return end

	local date_str = os.date("%Y-%m-%d")
	local m_app    = get_or_create_manifest_app(date_str, prev_app or "Unknown")

	m_app.app_time_ms   = (m_app.app_time_ms or 0) + (tonumber(duration_ms) or 0)
	m_app.switches_to   = type(m_app.switches_to) == "table" and m_app.switches_to or {}
	local safe_next     = (type(next_app) == "string" and next_app ~= "") and next_app or "Unknown"
	m_app.switches_to[safe_next] = (m_app.switches_to[safe_next] or 0) + 1

	M.append_log({
		type        = "app_switch",
		prev_app    = prev_app,
		next_app    = next_app,
		duration_ms = duration_ms,
	})
	debounced_save()

	-- Push live update to app metrics UI
	local metrics_apps = package.loaded["ui.metrics_apps.init"]
	if metrics_apps and type(metrics_apps.push_live_update) == "function" then
		pcall(metrics_apps.push_live_update, _state.manifest)
	end
end

--- Records a system-level event (sleep, wake, wifi change, volume, etc.).
--- @param event_type string A short identifier for the event.
--- @param metadata table|nil Optional key-value metadata to include.
function M.log_system_event(event_type, metadata)
	if not require_state("log_system_event") then return end
	local entry = { type = "system_event", action = event_type }
	if type(metadata) == "table" then
		for k, v in pairs(metadata) do entry[k] = v end
	end
	M.append_log(entry)
end

--- Records a single keyboard shortcut directly into the N-gram index and log file.
--- @param shortcut_key string Canonical label (e.g. "Cmd+C").
--- @param app_name string The frontmost application at time of press.
function M.log_shortcut(shortcut_key, app_name)
	if not require_state("log_shortcut") then return end
	if type(shortcut_key) ~= "string" or shortcut_key == "" then
		Logger.warn(LOG, "log_shortcut() called with empty key — ignoring.")
		return
	end
	local safe_app = (type(app_name) == "string" and app_name ~= "") and app_name or "Unknown"

	local app_idx = _state.today_idx[safe_app]
	if type(app_idx) ~= "table" then
		app_idx = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
		_state.today_idx[safe_app] = app_idx
	end
	app_idx.sc    = type(app_idx.sc)    == "table" and app_idx.sc    or {}
	app_idx.sc_bg = type(app_idx.sc_bg) == "table" and app_idx.sc_bg or {}

	-- Track consecutive shortcut bigram (shares the same prev_sc context as aggregate_events)
	local ctx = _state.ngram_context
	if ctx and type(ctx.prev_sc) == "string" then
		add_metric(app_idx.sc_bg, ctx.prev_sc .. "→" .. shortcut_key, 0, false, "none")
	end

	local sc_entry = app_idx.sc[shortcut_key] or {}
	sc_entry.c = (sc_entry.c or 0) + 1
	app_idx.sc[shortcut_key] = sc_entry

	-- Persist prev_sc so the next shortcut or typing-stream shortcut can form a bigram
	if not _state.ngram_context then
		_state.ngram_context = { prev_sc = shortcut_key }
	else
		_state.ngram_context.prev_sc = shortcut_key
	end

	M.append_log({ type = "shortcut", key = shortcut_key, app = safe_app })
	debounced_save()
end

--- Increments a scalar metric field in the manifest for an app, then saves.
--- Used for quick stats like hs_suggested or llm_suggested.
--- @param app_name string The application to update.
--- @param stat_key string The manifest field name to increment.
--- @param amount number|nil The increment value (defaults to 1).
function M.increment_manifest_stat(app_name, stat_key, amount)
	if not require_state("increment_manifest_stat") then return end
	local date_str = os.date("%Y-%m-%d")
	local m_app    = get_or_create_manifest_app(date_str, app_name or "Unknown")
	m_app[stat_key] = (m_app[stat_key] or 0) + (tonumber(amount) or 1)
	debounced_save()

	-- Push live update to app metrics UI
	local metrics_apps = package.loaded["ui.metrics_apps.init"]
	if metrics_apps and type(metrics_apps.push_live_update) == "function" then
		pcall(metrics_apps.push_live_update, _state.manifest)
	end
end




-- ====================================
-- ====================================
-- ======= 9/ Module Lifecycle =======
-- ====================================
-- ====================================

--- Initializes the log manager with the shared CoreState table.
--- Must be called exactly once before any other public function.
--- @param core_state table The shared state object from init.lua.
function M.init(core_state)
	Logger.start(LOG, "Initializing log manager…")
	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table — log manager non-functional.")
		return
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	_state = core_state
	Logger.success(LOG, "Log manager initialized.")
end

return M
