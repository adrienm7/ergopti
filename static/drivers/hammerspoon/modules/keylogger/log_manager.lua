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
-- Number of raw-log lines processed per tick during async replay. Keeping the
-- batch short (a few ms of work) lets the HID event tap run between chunks so
-- keyboard input stays responsive on keylogger startup.
local RAW_LOG_REPLAY_CHUNK_LINES = 500
-- Absolute path to openssl, required because hs.task.new bypasses the shell
-- and does not resolve $PATH. macOS ships openssl at /usr/bin/openssl.
local OPENSSL_PATH               = "/usr/bin/openssl"

-- Bucket thresholds (ms) used by the UI's "ignore pauses longer than…" dropdown.
-- These are CACHE buckets — we accumulate sums/counts at each threshold so the UI
-- can read an exact value for the user's selected pause threshold without ever
-- having to interpolate think_time. Adding a new threshold (e.g. 7000) requires
-- redeploying this list; old data without that bucket falls back to the existing
-- `m_app.time` / `m_app.think_time` aggregates which remain untouched.
-- Using string keys so JSON encoding stays stable (numeric keys would round-trip
-- as object-with-string-keys anyway, but being explicit avoids surprises).
local UI_PAUSE_BUCKETS_MS = { 1000, 2000, 3000, 5000, 10000, 20000, 30000, 60000 }
-- Maximum entries kept in the per-batch ring buffer used to retroactively
-- reclassify the inter-key delay of trigger keystrokes as HS / IA "input time"
-- when an expansion fires. 50 covers any sane trigger length and stays cheap.
local TRIGGER_LOOKBACK_LEN = 50

-- A "burst" is a stretch of typing with no inter-keydown gap > BURST_GAP_MS.
-- Anything longer breaks the burst and that previous one is finalised into the
-- per-app statistics. Used by the rhythm / records UI: top burst-CPM, longest
-- burst, length distribution, and inter-key-delay variance.
local BURST_GAP_MS         = 1000
-- Minimum number of characters in a burst before it counts toward the max-CPM
-- record. Below this, sample variance dominates and tiny "abc" bursts at high
-- transient rates would crown unrealistic personal bests.
local MIN_BURST_FOR_CPM    = 10

-- A "session" is a stretch of typing with no inter-keydown gap > SESSION_GAP_MS.
-- 5 min is the same gap a screen-time tracker would use to split work blocks.
local SESSION_GAP_MS       = 300000

-- Burst length bucket boundaries used to build the on-disk histogram. Each
-- bucket label maps to "characters in burst ≤ this many", except the last
-- which is open-ended.
local BURST_LENGTH_BUCKETS = { 1, 5, 10, 20, 50, 100, 200, 500 }
local function burst_length_bucket(n)
	for _, b in ipairs(BURST_LENGTH_BUCKETS) do
		if n <= b then return tostring(b) end
	end
	return "500+"
end

-- A key repeated within this delay since the previous identical char is treated
-- as auto-repeat (held key) rather than a separate motor decision. macOS
-- auto-repeat fires every ~30 ms, so 50 ms is a safe upper bound that still
-- excludes any human-typed double-letter pair.
local AUTO_REPEAT_MAX_DELAY_MS = 50
-- Cascade = run of ≥ N consecutive manual backspaces.
local CASCADE_MIN_BS = 3
-- Threshold separating a "tap" from a "hold" on a key whose hold duration we
-- observe (modifiers via flagsChanged, KE-managed tap-holds via the bridge).
-- ≤ threshold = tap (brief activation, e.g. typing a chord); > threshold =
-- hold (intentional sustained press, e.g. layer activation).
local HOLD_THRESHOLD_MS = 250

-- macOS virtual-keycode → finger column. MUST stay in sync with KEYCODE_DATA in
-- ui/metrics_typing/state.js (variante-en-A convention: kc 0 = QWERTY 'a' on the
-- physical left is typed by r_pinky). We only include "content" keys that take
-- part in same-finger / same-hand streaks; modifiers and thumbs are absent on
-- purpose so they don't break a streak by appearing in the middle.
local KC_TO_FINGER = {
	[0]="r_pinky",[1]="r_ring",[2]="r_mid",[3]="r_idx",[4]="l_idx",[5]="r_idx",
	[6]="r_ring",[7]="r_mid",[8]="r_idx",[9]="r_idx",[11]="r_idx",
	[12]="r_pinky",[13]="r_ring",[14]="r_mid",[15]="r_idx",[16]="l_idx",[17]="r_idx",
	[18]="r_pinky",[19]="r_ring",[20]="r_mid",[21]="r_idx",[22]="l_idx",[23]="r_idx",
	[25]="l_ring",[26]="l_idx",[28]="l_mid",[29]="l_pinky",
	[31]="l_ring",[32]="l_idx",[34]="l_mid",[35]="l_pinky",
	[37]="l_ring",[38]="l_idx",[40]="l_mid",[41]="l_pinky",
	[43]="l_mid",[44]="l_pinky",[45]="l_idx",[46]="l_idx",[47]="l_ring",
}

--- Adds `value` to every bucket field whose threshold is ≥ delay.
--- The buckets are cumulative ("≤ T" semantics) so the UI just reads the field
--- corresponding to the user-selected pause threshold — no summation in JS.
--- @param target_map table The bucket map (string-keyed) to mutate in place.
--- @param delay number Delay in milliseconds.
--- @param value number Value to accumulate (delay itself for time, 1 for counts).
local function bucket_add(target_map, delay, value)
	for _, t in ipairs(UI_PAUSE_BUCKETS_MS) do
		if delay <= t then
			local k = tostring(t)
			target_map[k] = (target_map[k] or 0) + value
		end
	end
end

--- Closes an in-flight burst and folds its statistics into the manifest entry.
--- The burst itself is a transient table living on `ctx`; we never store
--- individual bursts — only their aggregates per day per app.
local function finalize_burst(m_app, b)
	if not b or b.char_count <= 0 then return end
	m_app.burst_count_total = (m_app.burst_count_total or 0) + 1
	if b.char_count > (m_app.burst_max_chars or 0) then
		m_app.burst_max_chars = b.char_count
	end
	-- Only consider sustained bursts for the CPM record. A 3-char "abc" rip
	-- followed by a coffee break shouldn't crown a 1500 CPM personal best.
	if b.char_count >= MIN_BURST_FOR_CPM and b.sum_delays > 0 then
		local cpm = b.char_count * 60000 / b.sum_delays
		if cpm > (m_app.burst_max_cpm or 0) then m_app.burst_max_cpm = cpm end
	end
	local k = burst_length_bucket(b.char_count)
	m_app.burst_length_buckets[k] = (m_app.burst_length_buckets[k] or 0) + 1
	-- Pool inter-key delays so the UI can compute mean and std-dev across the
	-- entire day without us tracking per-burst series.
	m_app.burst_inter_delay_count = (m_app.burst_inter_delay_count or 0) + math.max(0, b.char_count - 1)
	m_app.burst_inter_delay_sum   = (m_app.burst_inter_delay_sum   or 0) + b.sum_delays
	m_app.burst_inter_delay_sumsq = (m_app.burst_inter_delay_sumsq or 0) + b.sum_delays_sq
end

-- Maximum number of finalised session durations kept on each per-app/day
-- entry. Sessions beyond this are summarised in aggregates only — the cap
-- bounds JSON growth on heavy-typing days while still giving the boxplot
-- enough samples for stable quantiles.
local SESSION_DURATIONS_CAP = 100

--- Closes an in-flight session and folds it into the per-day aggregates.
local function finalize_session(m_app, s)
	if not s or s.char_count <= 0 then return end
	m_app.session_count_total = (m_app.session_count_total or 0) + 1
	if s.total_ms   > (m_app.session_longest_ms    or 0) then m_app.session_longest_ms    = s.total_ms   end
	if s.char_count > (m_app.session_longest_chars or 0) then m_app.session_longest_chars = s.char_count end
	m_app.session_total_active_ms = (m_app.session_total_active_ms or 0) + s.total_ms
	-- Per-session durations array (#28 boxplot). Capped to avoid manifest bloat.
	m_app.session_durations = m_app.session_durations or {}
	if #m_app.session_durations < SESSION_DURATIONS_CAP then
		table.insert(m_app.session_durations, s.total_ms)
	end
end

-- Cheap UTF-8-aware character classifier used to bucket every typed
-- character into letter / digit / punct / space / other.
local function char_class(c)
	if not c or #c == 0 then return "other" end
	if c == " " or c == "\t" or c == "\n" or c == "\194\160" or c == "\226\128\175" then
		return "space"
	end
	local b = c:byte(1)
	if b >= 48 and b <= 57 then return "digit" end
	-- Latin letters (low ASCII) — fast path.
	if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return "letter" end
	-- High UTF-8 codepoint: assume letter if it starts in the Latin Extended
	-- ranges (0xC2..0xC3, 0xC4..0xC5 etc.). We don't need surgical accuracy —
	-- this only feeds the breakdown chart.
	if b >= 0xC2 and b <= 0xCF then return "letter" end
	if b >= 0xD0 and b <= 0xD7 then return "letter" end
	-- Bracket markers like [BS], [TAB] etc. produced by the keylogger pipeline
	-- shouldn't pollute the breakdown.
	if c:sub(1, 1) == "[" and c:sub(-1) == "]" then return "other" end
	if c:match("^[%p<>=+%*/\\|%-]$") then return "punct" end
	return "other"
end

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

local _state                = nil
local _save_timer           = nil
local _last_forced_save_ms  = 0
local _mac_serial_cache     = nil
-- Guards M.rebuild_index_if_needed_async() against overlapping invocations.
-- A second call while the async chain is still in flight would race on file
-- removal (idx migration) and re-replay the raw log on top of itself.
local _rebuild_in_progress  = false




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
		-- ── Speed / precision cache buckets ─────────────────────────────────────
		-- All these maps are CACHE fields keyed by bucket threshold (ms, string).
		-- They never replace the raw aggregates above (chars / time / think_time):
		-- they only let the UI read a precise value for the user-selected pause
		-- threshold without re-interpolating think_time at display time.
		--   time_buckets[T]      : sum of inter-key delays ≤ T ms for non-synth typing.
		--   credited_buckets[T]  : count of those events. Used as the numerator of
		--                          CPM at threshold T — we credit "transitions"
		--                          rather than "chars" so that single-char bursts
		--                          (whose delay is excluded as a pause) don't
		--                          create a divide-by-zero / infinite-speed bias.
		--   hs_input_*_buckets   : same accounting restricted to manual chars that
		--   llm_input_*_buckets    were consumed by an HS / IA expansion. Their
		--                          delays must be SUBTRACTED from time_buckets in
		--                          the default ("manual only") view because those
		--                          trigger keystrokes are credited to the HS / IA
		--                          gain, not to the raw typing speed.
		hs_input_chars              = 0,
		llm_input_chars             = 0,
		time_buckets                = {},
		credited_buckets            = {},
		hs_input_time_buckets       = {},
		hs_input_credited_buckets   = {},
		llm_input_time_buckets      = {},
		llm_input_credited_buckets  = {},
		-- ── Burst statistics (rhythm / records UI) ──────────────────────────
		--   burst_count_total        : total bursts finalised on this day.
		--   burst_max_cpm            : best CPM over a burst of ≥ MIN_BURST_FOR_CPM
		--                              characters — the user's "personal best"
		--                              under realistic conditions.
		--   burst_max_chars          : longest burst observed (in characters).
		--   burst_length_buckets     : histogram keyed by BURST_LENGTH_BUCKETS.
		--   burst_inter_delay_*      : Σ delay, Σ delay², count — together yield
		--                              the std-dev of inter-key delays for the
		--                              "rhythm regularity" metric.
		burst_count_total           = 0,
		burst_max_cpm               = 0,
		burst_max_chars             = 0,
		burst_length_buckets        = {},
		burst_inter_delay_count     = 0,
		burst_inter_delay_sum       = 0,
		burst_inter_delay_sumsq     = 0,
		-- ── Session statistics ──────────────────────────────────────────────
		--   session_count_total      : sessions finalised on this day.
		--   session_longest_ms/chars : longest single session by duration / chars.
		--   session_total_active_ms  : sum of session durations — useful for a
		--                              "minutes spent typing" headline metric.
		session_count_total         = 0,
		session_longest_ms          = 0,
		session_longest_chars       = 0,
		session_total_active_ms     = 0,
		-- ── Character-type breakdown (Sankey / lexical UI) ──────────────────
		--   Each non-synthetic typed character is bucketed into one of these by
		--   simple regex on the produced string. Useful to characterise typing
		--   style: code-heavy → high digits/symbols, prose → high letters.
		char_letter                 = 0,
		char_digit                  = 0,
		char_punct                  = 0,
		char_space                  = 0,
		char_other                  = 0,
		-- ── First / last typing minute of the day ───────────────────────────
		--   Hour:minute of the first / last manual keystroke. Lets the records
		--   UI surface "earliest / latest typed today".
		first_typed_min             = nil,
		last_typed_min              = nil,
		-- ── Error-pattern analytics (errors dashboard) ──────────────────────
		--   recovery_time_*   : delay between a manual backspace and the next
		--                       non-backspace keystroke. Sum + count let the UI
		--                       compute mean recovery time = "how fast you
		--                       resume typing after a correction".
		--   cascade_count     : number of "cascade" backspace runs (≥ 3 BS in
		--                       a row) — the user erased multiple characters,
		--                       suggesting a major mistake or rewrite.
		--   cascade_max_len   : length of the longest such cascade.
		--   bs_total          : every manual backspace, including isolated ones.
		recovery_time_sum_ms        = 0,
		recovery_time_count         = 0,
		cascade_count_total         = 0,
		cascade_max_len             = 0,
		bs_total                    = 0,
		-- ── Ergonomic streaks (rhythm dashboard) ────────────────────────────
		--   Longest consecutive run of keystrokes typed by the same finger or
		--   the same hand. High values signal anti-alternation patterns that
		--   are costly at high speed. Computed Lua-side via the kc → finger
		--   table embedded below; KC_TO_FINGER must mirror KEYCODE_DATA in
		--   ui/metrics_typing/state.js (variante-en-A convention).
		same_finger_streak_max      = 0,
		same_hand_streak_max        = 0,
		-- ── Auto-repeat detection ───────────────────────────────────────────
		--   Macros / held keys (e.g. holding "a" to type "aaaa…") fire repeated
		--   keyDown events at ~30 ms intervals. We flag any same-character
		--   bigram with delay ≤ AUTO_REPEAT_MAX_DELAY_MS as auto-repeat — the
		--   conscious decision was made once, even though many chars hit the
		--   counter.
		auto_repeat_count           = 0,
		-- ── Time-to-first-key after focus change ───────────────────────────
		--   Latency between the most recent app-focus event and the first
		--   manual keystroke after it. We accumulate sum + count per app/day
		--   for a clean mean.
		focus_to_first_key_sum_ms   = 0,
		focus_to_first_key_count    = 0,
		-- ── Keyboard layouts seen on this app/day ──────────────────────────
		--   Map of layout_id → count of typing flushes captured under it.
		--   Lets the UI surface "you used QWERTY 18× and Ergopti 142× today"
		--   and detect per-app layout patterns (code editor in QWERTY, prose
		--   in Ergopti, etc.).
		layouts_seen                = {},
		-- ── Modifier / tap-hold key duration stats (per physical keycode) ──
		--   Map of kc_str → { s=sum_ms, n=count, m=max_ms, tap=N, hold=N }.
		--   Each release is classified as a tap (≤ HOLD_THRESHOLD_MS) or a
		--   hold (>); tap + hold == n. The heatmap tooltip uses tap/hold
		--   counts to show a unified breakdown for keys we observe both
		--   sides of (HS-handled modifiers + KE-managed tap-holds).
		kc_hold                     = {},
		-- ── Active vs passive time ─────────────────────────────────────────
		--   active_time_ms = sum of inter-key gaps the user spent actively
		--                    typing (already proxied by `time` ; redundant alias
		--                    for clarity in the wellness dashboard).
		--   passive_time_ms = computed in JS as max(0, app_time_ms - active_time_ms).
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

--- Replays a single raw-log line into today's in-memory index and manifest.
--- Extracted so the sync replay (M.rebuild_today_from_raw_log) and the chunked
--- async replay (M.rebuild_today_from_raw_log_async) share the exact same
--- per-line behaviour — drift between the two paths would silently skew metrics.
--- @param line string A single JSON-encoded log line.
--- @param today string The date key for today ("YYYY-MM-DD").
--- @param prev_sc_by_app table Mutable lookup of the last shortcut seen per app, used to rebuild `sc_bg` bigrams across the replay.
--- @return boolean True when the line was a valid typing event (for counter increment).
local function process_replay_line(line, today, prev_sc_by_app)
	local ok, entry = pcall(json.decode, line)
	if not ok or type(entry) ~= "table" then
		Logger.debug(LOG, "Skipping malformed log line during rebuild.")
		return false
	end
	if entry.type == "typing" and type(entry.events) == "table" and #entry.events > 0 then
		M.aggregate_events(entry.events, entry.app or "Unknown", today)
		return true
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
	return false
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

	-- Tag the manifest with the keyboard layout that produced this buffer so
	-- the UI can correlate stats with the active layout (Ergopti vs QWERTY…)
	if type(_state.session_layout) == "string" and _state.session_layout ~= "" then
		m_app.layouts_seen = type(m_app.layouts_seen) == "table" and m_app.layouts_seen or {}
		m_app.layouts_seen[_state.session_layout] =
			(m_app.layouts_seen[_state.session_layout] or 0) + 1
	end

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
	-- Ring buffer of the last few non-synthetic typed events with their inter-key
	-- delay. When a synth backspace fires inside an HS / IA burst it deletes the
	-- last manually-typed char, so popping from this buffer tells us exactly what
	-- the trigger was and how long it took to type — which we then route into the
	-- hs_input_*_buckets / llm_input_*_buckets caches.
	ctx.recent_typing = ctx.recent_typing or {}
	-- In-flight burst / session aggregates. They're persisted on ctx so a single
	-- burst or session can span multiple flush_buffer batches; they get finalised
	-- only when the next inter-key gap exceeds the corresponding threshold.
	ctx.current_burst   = ctx.current_burst   or nil
	ctx.current_session = ctx.current_session or nil
	-- Cascade / recovery / streak state, persisted across flushes.
	ctx.bs_run_len      = ctx.bs_run_len      or 0       -- current consecutive-BS count
	ctx.last_was_bs     = ctx.last_was_bs     or false   -- prev manual event was a backspace
	ctx.last_finger     = ctx.last_finger     or nil     -- finger of the last typed char
	ctx.same_finger_run = ctx.same_finger_run or 0       -- current same-finger streak
	ctx.same_hand_run   = ctx.same_hand_run   or 0       -- current same-hand streak
	ctx.last_char       = ctx.last_char       or nil     -- last typed char (for auto-repeat detection)

	local p1, p2, p3, p4, p5, p6 = ctx.p1, ctx.p2, ctx.p3, ctx.p4, ctx.p5, ctx.p6
	local cur_word   = ctx.cur_word or ""   -- guard: nil if context was persisted in an older format
	local word_err   = ctx.word_err or false
	local backtrack  = ctx.hist or {}       -- guard: nil if context was persisted in an older format
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
					-- Each synthetic backspace inside an HS/LLM burst deletes exactly one
					-- trigger char that the user had typed manually. Popping from the
					-- recent-typing buffer gives us the original delay of that trigger
					-- char so we can route it to the trigger-time cache buckets.
					local trigger_evt = table.remove(ctx.recent_typing)
					if synth_type == "hotstring" then
						m_app.hs_chars = math.max(0, (m_app.hs_chars or 0) - 1)
						m_app.hs_input_chars = (m_app.hs_input_chars or 0) + 1
						if trigger_evt then
							bucket_add(m_app.hs_input_time_buckets,     trigger_evt.delay, trigger_evt.delay)
							bucket_add(m_app.hs_input_credited_buckets, trigger_evt.delay, 1)
						end
					elseif synth_type == "llm" then
						m_app.llm_chars = math.max(0, (m_app.llm_chars or 0) - 1)
						m_app.llm_input_chars = (m_app.llm_input_chars or 0) + 1
						if trigger_evt then
							bucket_add(m_app.llm_input_time_buckets,     trigger_evt.delay, trigger_evt.delay)
							bucket_add(m_app.llm_input_credited_buckets, trigger_evt.delay, 1)
						end
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
					-- Cache: bucketed manual-error counts (per-hour and per-5min), indexed
					-- by delay since previous keystroke. The UI uses this to honour the
					-- user-selected pause threshold without having to hardcode 2 s. A
					-- backspace fired after a long pause (typically deleting a selection
					-- / line) is naturally excluded from low-threshold buckets.
					m_app.hourly[current_hour].e_buckets       = m_app.hourly[current_hour].e_buckets       or {}
					m_app.hourly_min5[current_min5].e_buckets  = m_app.hourly_min5[current_min5].e_buckets  or {}
					bucket_add(m_app.hourly[current_hour].e_buckets,      delay, 1)
					bucket_add(m_app.hourly_min5[current_min5].e_buckets, delay, 1)
					-- A manual backspace just deleted the most recently typed char from
					-- screen. Pop it from the lookback buffer so a later HS / IA expansion
					-- does not mis-attribute it as a trigger.
					table.remove(ctx.recent_typing)
					-- Cascade tracking: count consecutive manual backspaces. The cascade
					-- closes when the next non-BS event fires (in the typing branch).
					ctx.bs_run_len = (ctx.bs_run_len or 0) + 1
					ctx.last_was_bs = true
					m_app.bs_total = (m_app.bs_total or 0) + 1
					-- A backspace breaks the typing flow; reset same-finger / same-hand
					-- streaks so we don't double-count post-correction continuity.
					ctx.last_finger     = nil
					ctx.same_finger_run = 0
					ctx.same_hand_run   = 0
					ctx.last_char       = nil
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
						-- Cache: bucketed time + credited-event counts, keyed by delay.
						-- We credit "transitions" (one per inter-key delay actually counted,
						-- never the first char of a burst whose delay is excluded as a
						-- pause) so single-char bursts cannot inflate CPM via a 0 / 0
						-- divide. record_delay is what we charge to time; bucketing on the
						-- same value keeps numerator and denominator perfectly aligned.
						bucket_add(m_app.time_buckets,     record_delay, record_delay)
						bucket_add(m_app.credited_buckets, record_delay, 1)
						-- Push this event onto the lookback ring buffer so a future HS / IA
						-- synthetic backspace can retroactively reclassify its delay as
						-- "trigger time" instead of "pure typing time".
						table.insert(ctx.recent_typing, { delay = record_delay })
						if #ctx.recent_typing > TRIGGER_LOOKBACK_LEN then
							table.remove(ctx.recent_typing, 1)
						end

						-- Burst tracking: a "fresh start" means the current keystroke
						-- is the first in a new burst, either because we have no
						-- in-flight one or because the inter-key gap exceeded
						-- BURST_GAP_MS.
						if (not ctx.current_burst) or record_delay > BURST_GAP_MS then
							finalize_burst(m_app, ctx.current_burst)
							ctx.current_burst = { char_count = 1, sum_delays = 0, sum_delays_sq = 0, max_delay = 0 }
						else
							local b = ctx.current_burst
							b.char_count    = b.char_count + 1
							b.sum_delays    = b.sum_delays + record_delay
							b.sum_delays_sq = b.sum_delays_sq + (record_delay * record_delay)
							if record_delay > b.max_delay then b.max_delay = record_delay end
						end

						-- Session tracking: same idea with a much larger gap (5 min).
						-- A single session can span hundreds of bursts.
						if (not ctx.current_session) or record_delay > SESSION_GAP_MS then
							finalize_session(m_app, ctx.current_session)
							ctx.current_session = { char_count = 1, total_ms = 0 }
						else
							local s = ctx.current_session
							s.char_count = s.char_count + 1
							s.total_ms   = s.total_ms + record_delay
						end

						-- Cascade closure + recovery time: if the previous manual event
						-- was a backspace, this is the first char "after correction".
						if ctx.last_was_bs then
							if ctx.bs_run_len >= CASCADE_MIN_BS then
								m_app.cascade_count_total = (m_app.cascade_count_total or 0) + 1
								if ctx.bs_run_len > (m_app.cascade_max_len or 0) then
									m_app.cascade_max_len = ctx.bs_run_len
								end
							end
							-- Only count "real" recoveries: delays short enough to be a
							-- continuation of typing rather than a long pause.
							if record_delay <= MAX_KEYSTROKE_DELAY_MS then
								m_app.recovery_time_sum_ms = (m_app.recovery_time_sum_ms or 0) + record_delay
								m_app.recovery_time_count  = (m_app.recovery_time_count  or 0) + 1
							end
							ctx.bs_run_len = 0
							ctx.last_was_bs = false
						end

						-- Same-finger / same-hand streak update.
						local kc_num     = type(meta.kc) == "number" and meta.kc or nil
						local cur_finger = kc_num and KC_TO_FINGER[kc_num] or nil
						if cur_finger then
							if ctx.last_finger == cur_finger then
								ctx.same_finger_run = (ctx.same_finger_run or 1) + 1
							else
								ctx.same_finger_run = 1
							end
							if ctx.same_finger_run > (m_app.same_finger_streak_max or 0) then
								m_app.same_finger_streak_max = ctx.same_finger_run
							end
							local cur_hand  = cur_finger:sub(1, 1)
							local last_hand = ctx.last_finger and ctx.last_finger:sub(1, 1) or nil
							if last_hand == cur_hand then
								ctx.same_hand_run = (ctx.same_hand_run or 1) + 1
							else
								ctx.same_hand_run = 1
							end
							if ctx.same_hand_run > (m_app.same_hand_streak_max or 0) then
								m_app.same_hand_streak_max = ctx.same_hand_run
							end
							ctx.last_finger = cur_finger
						else
							ctx.last_finger     = nil
							ctx.same_finger_run = 0
							ctx.same_hand_run   = 0
						end

						-- Auto-repeat: same character within AUTO_REPEAT_MAX_DELAY_MS.
						if ctx.last_char == k_c and record_delay > 0 and record_delay <= AUTO_REPEAT_MAX_DELAY_MS then
							m_app.auto_repeat_count = (m_app.auto_repeat_count or 0) + 1
						end
						ctx.last_char = k_c

						-- Character-type breakdown — feeds the Sankey / lexical mix view.
						local cls = char_class(k_c)
						if     cls == "letter" then m_app.char_letter = (m_app.char_letter or 0) + 1
						elseif cls == "digit"  then m_app.char_digit  = (m_app.char_digit  or 0) + 1
						elseif cls == "punct"  then m_app.char_punct  = (m_app.char_punct  or 0) + 1
						elseif cls == "space"  then m_app.char_space  = (m_app.char_space  or 0) + 1
						else                        m_app.char_other  = (m_app.char_other  or 0) + 1
						end

						-- First / last typed minute markers for the records UI.
						if not m_app.first_typed_min then m_app.first_typed_min = current_min5 end
						m_app.last_typed_min = current_min5
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
--- Synchronous — blocks the caller until the full file has been replayed.
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
		if process_replay_line(line, today, prev_sc_by_app) then
			typing_event_count = typing_event_count + 1
		end
	end

	fh:close()
	M.save_today_index()
	M.save_manifest()
	_last_forced_save_ms = timer.absoluteTime() / 1000000

	Logger.info(LOG, "Rebuild from raw log complete (%d typing event(s) replayed).", typing_event_count)
	return typing_event_count > 0
end

--- Asynchronous variant of M.rebuild_today_from_raw_log: reads the raw log in
--- small chunks and yields back to the main Hammerspoon runloop between chunks
--- so the HID event tap (and menu UI) stay responsive during a large replay.
--- Called from the keylogger bootstrap, where blocking for tens of seconds
--- would freeze the keyboard.
--- @param on_done fun(did_replay: boolean)? Optional callback, invoked on the main thread once the replay has finished (successfully or not).
function M.rebuild_today_from_raw_log_async(on_done)
	if not require_state("rebuild_today_from_raw_log_async") then
		if on_done then on_done(false) end
		return
	end
	local today = os.date("%Y-%m-%d")
	local raw_log_path = _state.LOG_DIR .. "/" .. today .. ".log"

	if not fs.attributes(raw_log_path) then
		Logger.debug(LOG, "No raw log found at '%s' — nothing to rebuild.", raw_log_path)
		if on_done then on_done(false) end
		return
	end

	local fh, err = io.open(raw_log_path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open raw log '%s': %s.", raw_log_path, tostring(err))
		if on_done then on_done(false) end
		return
	end

	-- Reset in-memory state before replaying
	_state.today_idx        = {}
	_state.manifest[today]  = {}
	_state.ngram_context    = nil  -- reset N-gram context for clean replay

	local typing_event_count = 0
	local prev_sc_by_app     = {}

	Logger.trace(LOG, "Replaying raw log asynchronously (chunks of %d lines)…", RAW_LOG_REPLAY_CHUNK_LINES)

	local function finalize()
		fh:close()
		M.save_today_index()
		M.save_manifest()
		_last_forced_save_ms = timer.absoluteTime() / 1000000
		Logger.done(LOG, "Async raw log replay complete (%d typing event(s) replayed).", typing_event_count)
		if on_done then on_done(typing_event_count > 0) end
	end

	local function process_chunk()
		for _ = 1, RAW_LOG_REPLAY_CHUNK_LINES do
			local line = fh:read("*l")
			if not line then
				finalize()
				return
			end
			if process_replay_line(line, today, prev_sc_by_app) then
				typing_event_count = typing_event_count + 1
			end
		end
		-- Yield to the runloop; HID events, timers, and UI interactions can
		-- now run before we resume with the next chunk on the next tick.
		timer.doAfter(0, process_chunk)
	end

	process_chunk()
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
	-- hs.fs.dir returns (iter_fn, dir_state): the iterator is stateless and
	-- the for loop hands dir_state back on every step. Dropping dir_state
	-- causes "directory metatable expected, got nil" on the first iteration.
	local dir_ok, dir_iter, dir_state = pcall(fs.dir, _state.LOG_DIR)
	if not dir_ok or not dir_iter then
		Logger.error(LOG, "Cannot iterate log directory '%s': %s.", _state.LOG_DIR, tostring(dir_iter))
		Logger.success(LOG, "Index evaluation done (directory error during migration).")
		return
	end

	for file_name in dir_iter, dir_state do
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

--- Asynchronous orchestrator for index rebuild and past-day migration.
--- Performs the cheap synchronous setup (manifest load, today's idx load) on
--- the main thread, then hands the two heavy phases to their async variants:
---   • raw-log replay (chunked, M.rebuild_today_from_raw_log_async)
---   • per-day migration into the encrypted DB (M.merge_day_to_db_async)
--- past-day migrations are chained one at a time so no two openssl passes run
--- concurrently — openssl is CPU-bound and doubling it up on a small machine
--- only makes each pass slower.
--- Guarded by _rebuild_in_progress against overlapping calls: re-entering while
--- a migration is mid-flight would race on os.remove of the .idx files.
--- @param on_done fun(success: boolean)? Optional callback, invoked on the main thread once every phase has completed (or been skipped).
function M.rebuild_index_if_needed_async(on_done)
	if not require_state("rebuild_index_if_needed_async") then
		if on_done then on_done(false) end
		return
	end

	if _rebuild_in_progress then
		Logger.warn(LOG, "rebuild_index_if_needed_async() called while another rebuild is in flight — ignoring.")
		if on_done then on_done(false) end
		return
	end

	Logger.start(LOG, "Evaluating index state for rebuild (async)…")
	_rebuild_in_progress = true

	local function finish(success)
		_rebuild_in_progress = false
		if success then
			Logger.success(LOG, "Async index evaluation and migration complete.")
		end
		if on_done then on_done(success and true or false) end
	end

	-- Ensure the log directory exists (cheap, synchronous)
	if not fs.attributes(_state.LOG_DIR) then
		local ok, err = pcall(fs.mkdir, _state.LOG_DIR)
		if not ok then
			Logger.error(LOG, "Cannot create log directory '%s': %s.", _state.LOG_DIR, tostring(err))
			return finish(false)
		end
	end

	-- Load persisted manifest (cheap)
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

	-- Load today's persisted index (cheap)
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

	--- Collects past-day .idx files on disk, then migrates them one by one
	--- through the async merge. Called once the raw-log replay phase is done.
	local function migrate_past_idx_files()
		local dir_ok, dir_iter, dir_state = pcall(fs.dir, _state.LOG_DIR)
		if not dir_ok or not dir_iter then
			Logger.error(LOG, "Cannot iterate log directory '%s': %s.", _state.LOG_DIR, tostring(dir_iter))
			return finish(true)
		end

		-- Gather pending files first so we don't keep the directory iterator
		-- alive across async ticks (safer: the state table has a __gc that
		-- would close the underlying dir handle mid-iteration otherwise).
		local pending = {}
		for file_name in dir_iter, dir_state do
			local y, mo, d = file_name:match("^(%d%d%d%d)-(%d%d)-(%d%d)%.idx$")
			if y and mo and d then
				local file_date = string.format("%s-%s-%s", y, mo, d)
				if file_date ~= today then
					pending[#pending + 1] = { date = file_date, name = file_name }
				end
			end
		end

		if #pending == 0 then
			return finish(true)
		end

		Logger.info(LOG, "Queued %d past-day .idx file(s) for async migration.", #pending)

		local i = 0
		local function process_next()
			i = i + 1
			if i > #pending then
				return finish(true)
			end
			local entry     = pending[i]
			local full_path = _state.LOG_DIR .. "/" .. entry.name
			local f, err    = io.open(full_path, "r")
			if not f then
				Logger.warn(LOG, "Cannot open '%s' for migration: %s.", full_path, tostring(err))
				return timer.doAfter(0, process_next)
			end
			local content = f:read("*a")
			f:close()
			local ok, old_idx = pcall(json.decode, content)
			if not ok or type(old_idx) ~= "table" then
				Logger.warn(LOG, "Could not parse '%s' — skipping migration.", entry.name)
				return timer.doAfter(0, process_next)
			end
			local old_manifest = (_state.manifest[entry.date]) or {}
			Logger.debug(LOG, "Migrating '%s' into encrypted database (async)…", entry.date)
			M.merge_day_to_db_async(entry.date, old_idx, old_manifest, function(success)
				if success then
					os.remove(full_path)
				end
				-- Yield a tick before the next migration so UI/input can run.
				timer.doAfter(0, process_next)
			end)
		end

		process_next()
	end

	-- If today's index is sparse, replay the raw log asynchronously first,
	-- THEN migrate past-day files. Sequencing matters: the raw log replay
	-- rewrites today's .idx, which must land before any .sqlite read that
	-- might follow the migration.
	if is_today_idx_sparse() then
		Logger.info(LOG, "Today's index is sparse — rebuilding from raw log asynchronously…")
		M.rebuild_today_from_raw_log_async(function()
			migrate_past_idx_files()
		end)
	else
		migrate_past_idx_files()
	end
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

--- Asynchronous variant of M.merge_day_to_db.
--- Runs the two openssl passes (decrypt, re-encrypt) through hs.task.new so the
--- main thread is never blocked by the PBKDF2 key derivation — which, on a
--- multi-MB encrypted DB, can take several seconds per call and otherwise
--- freezes the event tap. The SQLite work in between is fast enough to keep
--- synchronous on the main thread.
--- @param date_str string The date to archive ("YYYY-MM-DD").
--- @param idx_data table The daily N-gram index for that date.
--- @param manifest_data table The daily manifest for that date.
--- @param on_done fun(success: boolean)? Optional callback, invoked on the main thread once the whole decrypt → SQLite → re-encrypt chain has finished.
function M.merge_day_to_db_async(date_str, idx_data, manifest_data, on_done)
	if not require_state("merge_day_to_db_async") then
		if on_done then on_done(false) end
		return
	end
	Logger.start(LOG, "Merging %s into encrypted database (async)…", date_str)

	local db_path  = _state.LOG_DIR .. "/metrics.sqlite"
	local enc_path = db_path .. ".enc"
	local tmp_path = os.tmpname()
	-- hs.task.new passes arguments straight to execvp, so no shell escaping is
	-- needed on the password — unlike the sync path which concatenates into a
	-- shell command string.
	local pwd      = M.get_mac_serial()

	local function finish(success)
		if on_done then on_done(success and true or false) end
	end

	local function sqlite_work_and_reencrypt()
		local db = sqlite3.open(tmp_path)
		if not db then
			Logger.error(LOG, "Failed to open SQLite database at '%s' — aborting merge for %s.", tmp_path, date_str)
			os.remove(tmp_path)
			return finish(false)
		end

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
			return finish(false)
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

		-- Re-encrypt asynchronously so the PBKDF2 run does not freeze the UI.
		local enc_task = hs.task.new(OPENSSL_PATH, function(exit_code, _, stderr)
			if exit_code ~= 0 then
				Logger.error(LOG, "Re-encryption failed (exit %s) for %s: %s — unencrypted tmp left at '%s'.",
					tostring(exit_code), date_str, tostring(stderr), tmp_path)
				return finish(false)
			end
			os.remove(tmp_path)
			Logger.success(LOG, "Merge of %s into encrypted database complete.", date_str)
			finish(true)
		end, {
			"enc", "-aes-256-cbc", "-a", "-A", "-salt", "-pbkdf2",
			"-pass", "pass:" .. pwd,
			"-in",   tmp_path,
			"-out",  enc_path,
		})
		if not enc_task or not enc_task:start() then
			Logger.error(LOG, "Could not launch openssl re-encrypt task for %s — tmp left at '%s'.", date_str, tmp_path)
			finish(false)
		end
	end

	if fs.attributes(enc_path) then
		local dec_task = hs.task.new(OPENSSL_PATH, function(exit_code, _, stderr)
			if exit_code ~= 0 then
				Logger.warn(LOG, "Decryption returned non-zero (exit %s) for %s: %s — DB may be new or corrupted; proceeding.",
					tostring(exit_code), date_str, tostring(stderr))
			end
			sqlite_work_and_reencrypt()
		end, {
			"enc", "-d", "-aes-256-cbc", "-a", "-A", "-salt", "-pbkdf2",
			"-pass", "pass:" .. pwd,
			"-in",   enc_path,
			"-out",  tmp_path,
		})
		if not dec_task or not dec_task:start() then
			Logger.warn(LOG, "Could not launch openssl decrypt task for %s — proceeding with fresh DB.", date_str)
			sqlite_work_and_reencrypt()
		end
	else
		sqlite_work_and_reencrypt()
	end
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
		local _date_str = os.date("%Y-%m-%d")
		M.aggregate_events(_state.buffer_events, _state.session_app_name, _date_str)

		-- #39 — Aggregate window title into manifest for the top-windows table.
		-- Capped at 100 distinct titles per app/day to bound JSON growth.
		local _title = _state.session_win_title
		if type(_title) == "string" and _title ~= "" then
			local _m_app = get_or_create_manifest_app(_date_str, _state.session_app_name or "Unknown")
			_m_app.win_titles = _m_app.win_titles or {}
			-- Truncate excessive title strings to 200 chars
			if #_title > 200 then _title = _title:sub(1, 200) end
			local _entry = _m_app.win_titles[_title]
			if not _entry then
				if next(_m_app.win_titles) and (function()
					local _n = 0
					for _ in pairs(_m_app.win_titles) do _n = _n + 1 end
					return _n
				end)() >= 100 then
					-- skip new keys once cap reached
					_entry = nil
				else
					_entry = { c = 0, ms = 0 }
					_m_app.win_titles[_title] = _entry
				end
			end
			if _entry then
				local _len = (type(_state.buffer_text) == "string") and #_state.buffer_text or 0
				_entry.c   = _entry.c  + _len
				_entry.ms  = _entry.ms + math.max(0, tonumber(_state.current_session_pause) or 0)
			end
		end

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

-- Module-local state for audio mute duration tracking. We accumulate the total
-- muted time per day in the manifest, but the "currently muted since" timestamp
-- is transient and lives only in memory.
local _audio_muted_started_at = nil  -- monotonic ms when mute started, nil if not muted

--- Aggregates a system event into the per-day "_system" pseudo-app counters.
--- Counters surfaced: wifi_changes, space_switches, battery (sum/count/min/max),
--- audio_muted_ms. Lets the dashboard display "12 Wi-Fi changes today" without
--- having to replay the raw log.
--- @param event_type string The event type ("wifi_change", "space_change", …).
--- @param metadata table|nil Optional metadata bag for value-bearing events.
local function aggregate_system_event(event_type, metadata)
	local date_str = os.date("%Y-%m-%d")
	local m_app    = get_or_create_manifest_app(date_str, "_system")

	if event_type == "wifi_change" then
		m_app.wifi_changes = (m_app.wifi_changes or 0) + 1
	elseif event_type == "space_change" then
		m_app.space_switches = (m_app.space_switches or 0) + 1
	elseif event_type == "power_change" then
		local lvl = type(metadata) == "table" and tonumber(metadata.level) or nil
		if lvl and lvl >= 0 and lvl <= 100 then
			m_app.battery_sum   = (m_app.battery_sum   or 0) + lvl
			m_app.battery_count = (m_app.battery_count or 0) + 1
			if not m_app.battery_min or lvl < m_app.battery_min then m_app.battery_min = lvl end
			if not m_app.battery_max or lvl > m_app.battery_max then m_app.battery_max = lvl end
		end
	elseif event_type == "audio_change" then
		local muted = type(metadata) == "table" and metadata.muted or nil
		local now_ms = hs.timer.absoluteTime() / 1e6
		if muted and not _audio_muted_started_at then
			_audio_muted_started_at = now_ms
		elseif (not muted) and _audio_muted_started_at then
			m_app.audio_muted_ms = (m_app.audio_muted_ms or 0) + (now_ms - _audio_muted_started_at)
			_audio_muted_started_at = nil
		end
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
	pcall(aggregate_system_event, event_type, metadata)
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

--- Records a single modifier-key press (flagsChanged) into the kc dict.
--- Modifier keys are not keyDown events and therefore never reach aggregate_events,
--- so this dedicated function gives them a direct path into the Keycodes tab data.
--- @param keycode number The macOS virtual keycode of the modifier key.
--- @param app_name string The frontmost application at the time of the press.
function M.log_modifier_press(keycode, app_name)
	if not require_state("log_modifier_press") then return end
	local safe_app = (type(app_name) == "string" and app_name ~= "") and app_name or "Unknown"

	local app_idx = _state.today_idx[safe_app]
	if type(app_idx) ~= "table" then
		app_idx = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
		_state.today_idx[safe_app] = app_idx
	end
	app_idx.kc = type(app_idx.kc) == "table" and app_idx.kc or {}
	add_metric(app_idx.kc, tostring(keycode), 0, false, "none")
	debounced_save()

	-- Push a live refresh so the heatmap and Keycodes tab reflect modifier presses
	-- immediately, just like character events do via flush_buffer
	local metrics_typing = package.loaded["ui.metrics_typing.init"]
	if metrics_typing and type(metrics_typing.push_live_update) == "function" then
		pcall(metrics_typing.push_live_update, _state.today_idx)
	end
end


--- Records a single Karabiner-intercepted physical key press into the kc dict.
--- Called by modules/keylogger/kc_bridge when it drains the KE physical-kc log;
--- the kc_num here is the TRUE physical key the user pressed, not the remapped
--- output that the HS event tap would observe.
--- @param kc_num number The macOS virtual keycode of the physical key.
--- @param app_name string The frontmost application at the time of the press.
function M.log_karabiner_press(kc_num, app_name)
	if not require_state("log_karabiner_press") then return end
	local safe_app = (type(app_name) == "string" and app_name ~= "") and app_name or "Unknown"

	local app_idx = _state.today_idx[safe_app]
	if type(app_idx) ~= "table" then
		app_idx = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
		_state.today_idx[safe_app] = app_idx
	end
	app_idx.kc = type(app_idx.kc) == "table" and app_idx.kc or {}
	add_metric(app_idx.kc, tostring(kc_num), 0, false, "none")
	debounced_save()

	-- Push a live refresh so the heatmap reflects KE-intercepted physical
	-- presses (tap-holds on cmd, shift, etc.) the moment they arrive
	local metrics_typing = package.loaded["ui.metrics_typing.init"]
	if metrics_typing and type(metrics_typing.push_live_update) == "function" then
		pcall(metrics_typing.push_live_update, _state.today_idx)
	end
end


--- Records a closed system-passive period (screen locked, system asleep, or
--- keep-awake interval). Stored under the "_system" pseudo-app so the UI can
--- compute precise active = Σ app_time_ms - (locked_ms + sleep_ms + awake_ms).
--- @param kind string One of "lock", "sleep", or "awake".
--- @param duration_ms number Length of the closed period in milliseconds.
function M.log_passive_period(kind, duration_ms)
	if not require_state("log_passive_period") then return end
	local dur = tonumber(duration_ms)
	if not dur or dur <= 0 then return end
	local date_str = os.date("%Y-%m-%d")
	local m_app    = get_or_create_manifest_app(date_str, "_system")
	if kind == "lock" then
		m_app.locked_ms = (m_app.locked_ms or 0) + dur
	elseif kind == "awake" then
		-- Keep-awake jitter time: not real user activity but the OS-foreground
		-- timer keeps running. Tracked separately so the dashboard can opt
		-- out of counting it via a UI toggle.
		m_app.awake_ms = (m_app.awake_ms or 0) + dur
	else
		m_app.sleep_ms = (m_app.sleep_ms or 0) + dur
	end
	-- Don't bump passive_count for awake — it's not a lock / sleep event
	if kind ~= "awake" then
		m_app.passive_count = (m_app.passive_count or 0) + 1
	end
	-- Night wakes: a passive lock/sleep period that closed between 00:00 and
	-- 06:00 local time means the user resumed activity in the middle of the
	-- night. Excluded for "awake" kind — that's only a metric-correction
	-- marker, not a real wake-up event.
	if kind ~= "awake" then
		local hour = tonumber(os.date("%H")) or 0
		if hour >= 0 and hour < 6 then
			m_app.night_wake_count = (m_app.night_wake_count or 0) + 1
		end
	end
end

--- Tags the duration of a keep-awake interval onto the focused app's manifest
--- entry as `awake_ms`. The dashboard subtracts this from `app_time_ms` when
--- the user opts out of counting keep-awake time, so the underlying focus
--- aggregate is preserved (toggle is reversible).
--- @param app_name string Name of the app that held the focus during the interval.
--- @param dur_ms number Length of the keep-awake period in milliseconds.
function M.tag_awake_focus(app_name, dur_ms)
	if not require_state("tag_awake_focus") then return end
	local d = tonumber(dur_ms)
	if not d or d <= 0 then return end
	if type(app_name) ~= "string" or app_name == "" then return end
	local date_str = os.date("%Y-%m-%d")
	local m_app    = get_or_create_manifest_app(date_str, app_name)
	m_app.awake_ms = (m_app.awake_ms or 0) + d
end


--- Records a modifier key release with the time it was held down.
--- Updates per-keycode aggregates (sum, count, max) on the manifest so the
--- UI can surface "your average shift hold is 280 ms" or flag chord-typing
--- patterns where a modifier is held for unusually long.
--- @param keycode number Physical macOS virtual keycode of the modifier.
--- @param app_name string Frontmost app at release time.
--- @param hold_ms number Duration the key was held down.
--- Records a key release event with the time it was held down. Classifies
--- the release as a tap (≤ HOLD_THRESHOLD_MS) or a hold (>) and accumulates
--- per-keycode statistics in the manifest's kc_hold map. Shared by both
--- the modifier-keys path (flagsChanged) and the KE-managed bridge path so
--- the heatmap tooltip can show a unified tap/hold breakdown.
--- @param keycode number Physical macOS virtual keycode.
--- @param app_name string Frontmost app at release time.
--- @param hold_ms number Duration the key was held down.
local function _credit_kc_hold(keycode, app_name, hold_ms)
	local hold = tonumber(hold_ms)
	if not hold or hold < 0 then return end
	local date_str = os.date("%Y-%m-%d")
	local m_app    = get_or_create_manifest_app(date_str, app_name or "Unknown")
	m_app.kc_hold = type(m_app.kc_hold) == "table" and m_app.kc_hold or {}
	local kc_str  = tostring(keycode)
	local entry   = m_app.kc_hold[kc_str]
	if type(entry) ~= "table" then
		entry = { s = 0, n = 0, m = 0, tap = 0, hold = 0 }
		m_app.kc_hold[kc_str] = entry
	end
	entry.s = (entry.s or 0) + hold
	entry.n = (entry.n or 0) + 1
	if hold > (entry.m or 0) then entry.m = hold end
	if hold > HOLD_THRESHOLD_MS then
		entry.hold = (entry.hold or 0) + 1
	else
		entry.tap = (entry.tap or 0) + 1
	end
end

function M.log_modifier_hold(keycode, app_name, hold_ms)
	if not require_state("log_modifier_hold") then return end
	_credit_kc_hold(keycode, app_name, hold_ms)
end

--- Records a Karabiner-managed key release with hold duration.
--- Same accounting as log_modifier_hold so the heatmap UI sees a unified
--- kc_hold table regardless of whether the press came through flagsChanged
--- (HS-handled modifier) or the KE physical-kc bridge (tap-hold key).
--- @param kc_num number Physical macOS virtual keycode.
--- @param app_name string Frontmost app at release time.
--- @param hold_ms number Duration the key was held down.
function M.log_karabiner_release(kc_num, app_name, hold_ms)
	if not require_state("log_karabiner_release") then return end
	_credit_kc_hold(kc_num, app_name, hold_ms)
end


--- Records the latency between an app-focus event and the first manual
--- keystroke that followed it. Accumulates Σ delay + count per app/day so
--- the wellness/UX dashboard can surface a mean "time-to-first-key".
--- Called once per focus, on the very first non-synthetic keyDown in that app.
--- @param app_name string The application that just received focus.
--- @param latency_ms number Time elapsed between focus and first keystroke.
function M.log_focus_first_key(app_name, latency_ms)
	if not require_state("log_focus_first_key") then return end
	local lat = tonumber(latency_ms)
	if not lat or lat < 0 then return end
	local date_str = os.date("%Y-%m-%d")
	local m_app    = get_or_create_manifest_app(date_str, app_name or "Unknown")
	m_app.focus_to_first_key_sum_ms = (m_app.focus_to_first_key_sum_ms or 0) + lat
	m_app.focus_to_first_key_count  = (m_app.focus_to_first_key_count  or 0) + 1
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
