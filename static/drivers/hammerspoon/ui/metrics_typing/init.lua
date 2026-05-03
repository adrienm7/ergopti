--- ui/metrics_typing/init.lua

--- ==============================================================================
--- MODULE: Metrics Dashboard UI
--- DESCRIPTION:
--- Injects and manages the HTML/JS webview to display typing metrics.
---
--- FEATURES & RATIONALE:
--- 1. Decoupled Architecture: Connects raw SQLite DB to an isolated Webview.
--- 2. Instant Re-Open: Historical caches persist across UI close/reopen within
---    the same Hammerspoon session. The expensive openssl decrypt + SQLite query
---    runs at most ONCE per day — every subsequent open is served from memory.
--- 3. Real-Time Push: Subscribes to the Keylogger event bus to sync actively.
--- 4. Day-Boundary Invalidation: All caches are flushed automatically when the
---    calendar date changes so stale data from the previous day never leaks in.
--- 5. Retry Injection: Manifest data is injected via a retry loop instead of a
---    fixed delay, ensuring KPI blocks populate even when CDN scripts are slow.
--- ==============================================================================

local M = {}

local hs         = hs
local fs         = require("hs.fs")
local json       = require("hs.json")
local sqlite3    = require("hs.sqlite3")
local ui_builder = require("ui.ui_builder")
local Logger     = require("lib.logger")

local LOG = "metrics_typing"

-- On-disk cache file: lets the dashboard pre-fill INSTANTLY from the last
-- successful render even after a Hammerspoon reload (the in-memory caches
-- below survive close/reopen but not a full HS reload).  The user is happy
-- to see slightly stale numbers (1 h, 1 day) provided the UI is instant —
-- a fresh refresh runs in the background and overwrites the cache.
-- Stored in $TMPDIR (per-user macOS temp dir, falling back to /tmp) so
-- the cache lives outside the versioned ~/.hammerspoon tree and is wiped
-- naturally by the OS on disk-pressure / reboots.
local UI_CACHE_DIR  = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/")
local UI_CACHE_FILE = UI_CACHE_DIR .. "ergopti_metrics_typing_cache.json"

M._wv             = nil
M._timer          = nil
M._last_req       = nil
M._app_icon_cache = {}

-- ── Persistent caches (survive UI close/reopen within the Hammerspoon session) ──
-- These are intentionally module-level (not reset on close) so that the expensive
-- openssl decrypt runs at most once per calendar day regardless of how many times
-- the user opens the dashboard.
M._data_cache     = {}    -- make_cache_key(…) → historical n-gram dict
M._hist_manifest  = nil   -- date → app_name → stats (from SQLite daily_manifest)
M._cache_date     = nil   -- date string when the caches were last populated





-- =================================
-- =================================
-- ======= 1/ Data Retrieval =======
-- =================================
-- =================================

local MAX_ICON_LOOKUPS_PER_OPEN = 24

--- Extracts the app icon safely from macOS.
--- @param app_name string The name of the application.
--- @return string Base64 encoded string of the icon.
local function get_app_icon(app_name)
	local app = hs.application.find(app_name)
	if app and type(app.bundleID) == "function" then
		local ok, img = pcall(hs.image.imageFromAppBundle, app:bundleID())
		if ok and img then 
			img:setSize({ w = 32, h = 32 })
			return img:encodeAsURLString() 
		end
	end
	return nil
end

--- Retrieves the pre-calculated daily metrics from Encrypted SQLite.
--- @param log_dir string Path to logs.
--- @param start_date string Minimum date boundary.
--- @param end_date string Maximum date boundary.
--- @param selected_apps table Array of requested applications.
--- @return table The fully merged big dictionary for the UI.
local function fetch_range(log_dir, start_date, end_date, selected_apps)
	local log_manager = require("modules.keylogger.log_manager")
	local enc_path = log_dir .. "/metrics.sqlite.enc"
	local pwd = log_manager.get_mac_serial():gsub("\"", "\\\"")

	local historical_merged = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
	local app_set = {}
	local has_app_filter = false
	
	if selected_apps and type(selected_apps) == "table" then
		for _, app in ipairs(selected_apps) do
			app_set[app] = true
			has_app_filter = true
		end
	end

	if fs.attributes(enc_path) then
		local tmp_path = os.tmpname()
		hs.execute(string.format("openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>/dev/null", pwd, enc_path, tmp_path))
		
		local db = sqlite3.open(tmp_path)
		if db then
			-- Always exclude today from the SQLite query: today's data comes exclusively
			-- from the flat .idx live file to avoid double-counting when both sources overlap.
			local today_str = os.date("%Y-%m-%d")
			local query = "SELECT app_name, index_json FROM daily_index WHERE date < '" .. today_str .. "'"
			if start_date and start_date ~= "" then query = query .. string.format(" AND date >= '%s'", start_date) end
			if end_date and end_date ~= "" then query = query .. string.format(" AND date <= '%s'", end_date) end

			for row in db:nrows(query) do
				local appName = row.app_name
				if (not has_app_filter) or app_set[appName] then
					local ok, appData = pcall(json.decode, row.index_json)
					if ok and type(appData) == "table" then
						for k_type, k_dict in pairs(appData) do
							if historical_merged[k_type] and type(k_dict) == "table" then
								for k_seq, k_stats in pairs(k_dict) do
									local t = historical_merged[k_type][k_seq]
									if not t then
										t = { c = 0, t = 0, hs = 0, llm = 0, o = 0, e = 0 }
										historical_merged[k_type][k_seq] = t
									end

									if k_stats[1] or k_stats[2] or k_stats[3] then
										t.c = t.c + (k_stats[1] or 0)
										t.t = t.t + (k_stats[2] or 0)
										t.e = t.e + (k_stats[3] or 0)
										t.hs = t.hs + (k_stats[4] or 0)
										t.llm = t.llm + (k_stats[5] or 0)
										t.o = t.o + (k_stats[6] or 0)
									else
										t.c = t.c + (k_stats.c or 0)
										t.t = t.t + (k_stats.t or 0)
										t.hs = t.hs + (k_stats.hs or 0)
										t.llm = t.llm + (k_stats.llm or 0)
										t.o = t.o + (k_stats.o or 0)
										t.e = t.e + (k_stats.e or 0)
									end
								end
							end
						end
					end
				end
			end
			db:close()
		end
		os.remove(tmp_path)
	end
	
	local f_idx = io.open(log_dir .. "/" .. os.date("%Y-%m-%d") .. ".idx", "r")
	local today_idx = {}
	if f_idx then
		local c = f_idx:read("*a")
		f_idx:close()
		pcall(function() today_idx = json.decode(c) or {} end)
	end

	return { historical = historical_merged, today = today_idx }
end



-- ==================================
-- ===== 1.1) Query Cache Layer =====
-- ==================================

--- Builds a deterministic cache key from query parameters.
--- Apps are sorted so the same set in any order maps to the same key.
--- @param start_date string Start date boundary.
--- @param end_date string End date boundary.
--- @param apps table Array of application names.
--- @return string Pipe-delimited cache key.
local function make_cache_key(start_date, end_date, apps)
	local sorted = {}
	if type(apps) == "table" then
		for _, v in ipairs(apps) do table.insert(sorted, v) end
		table.sort(sorted)
	end
	return (start_date or "") .. "|" .. (end_date or "") .. "|" .. table.concat(sorted, ",")
end

--- Reads today's live index file without decryption (plaintext, cheap).
--- @param log_dir string Path to the logging directory.
--- @return table The live index dictionary, or an empty table on failure.
local function read_today_idx(log_dir)
	local today_idx = {}
	local f = io.open(log_dir .. "/" .. os.date("%Y-%m-%d") .. ".idx", "r")
	if f then
		local content = f:read("*a")
		f:close()
		pcall(function() today_idx = json.decode(content) or {} end)
	end
	return today_idx
end

--- Wraps fetch_range with a per-session cache keyed on (start, end, apps).
--- Only the historical part is cached; today's live index is always read fresh
--- because it changes on every keystroke.
--- @param log_dir string Path to the logging directory.
--- @param start_date string Start date boundary.
--- @param end_date string End date boundary.
--- @param selected_apps table Array of requested applications.
--- @return table { historical, today } payload.
local function fetch_range_cached(log_dir, start_date, end_date, selected_apps)
	local key = make_cache_key(start_date, end_date, selected_apps)
	if M._data_cache[key] then
		Logger.done(LOG, "Historical n-gram cache hit.")
		return { historical = M._data_cache[key], today = read_today_idx(log_dir) }
	end
	Logger.trace(LOG, "Historical n-gram cache miss — querying encrypted DB…")
	local result = fetch_range(log_dir, start_date, end_date, selected_apps)
	M._data_cache[key] = result.historical
	Logger.done(LOG, "Historical n-gram data cached.")
	return result
end





-- ===============================
-- ===============================
-- ======= 2/ UI Injection =======
-- ===============================
-- ===============================

--- Opens the dashboard, pre-fetches n-gram data while the webview loads its
--- scripts, then injects the manifest and data the instant JS is ready.
--- Using a retry loop instead of a fixed delay guarantees the injection fires
--- even when CDN scripts slow down the initial HTML parse.
--- Persists a snapshot of the data injected into the webview to disk so the
--- next open (even after HS reload) can render instantly from this cache.
--- Stored as a JSON wrapper whose four string fields are themselves the JSON
--- payloads used by process_manifest() — no re-encoding needed at load time.
--- @param payload table { manifest, app_icons, initial_data, kc_layout } as JSON strings.
local function save_disk_cache(payload)
	-- TMPDIR always exists on macOS so no mkdir needed.  Skip the os.execute
	-- call which costs a fork+shell roundtrip and was a startup cost on its own.
	local ok_enc, body = pcall(json.encode, payload)
	if not ok_enc then
		Logger.warn(LOG, "Failed to encode disk cache payload — skipping persist.")
		return
	end
	local f = io.open(UI_CACHE_FILE, "w")
	if f then
		f:write(body)
		f:close()
		Logger.debug(LOG, "Dashboard snapshot persisted to disk cache.")
	else
		Logger.warn(LOG, "Cannot open '%s' for writing — disk cache not persisted.", UI_CACHE_FILE)
	end
end

--- Reads the previously-saved disk cache snapshot.  Used to pre-fill the
--- dashboard with last-known values within milliseconds of opening, while
--- the slow decrypt+SQL refresh runs in the background.
--- @return table|nil Snapshot with manifest/app_icons/initial_data/kc_layout JSON strings.
local function load_disk_cache()
	local f = io.open(UI_CACHE_FILE, "r")
	if not f then return nil end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(json.decode, content)
	if not ok or type(data) ~= "table" then return nil end
	return data
end

--- Aggressively raises the dashboard window above any compositing menu and
--- gives Hammerspoon foreground focus.  Called multiple times on a schedule
--- after window creation because, on a fresh HS reload, the menu-bar item
--- that triggered M.show() is still being dismissed and macOS otherwise
--- lets the previous app steal focus, leaving the new window invisible.
--- @param above_everything boolean Pass true to float the window above
---   every other app temporarily; false drops back to normal level.
local function raise_now(wv, above_everything)
	if not wv then return end
	pcall(function() wv:show() end)
	pcall(function() wv:bringToFront(above_everything) end)
	pcall(hs.focus)
	local ok, win = pcall(function() return wv:hswindow() end)
	if ok and win then
		pcall(function() win:raise() end)
		pcall(function() win:focus() end)
	end
end

--- Performs all expensive disk I/O and DB decryption in a single deferred
--- pass: past-day migration, manifest.json read, encrypted SQLite decrypt,
--- app icon resolution, n-gram pre-fetch, then injects the result into the
--- already-visible webview.  Decoupling this from M.show() is what makes
--- the window appear instantly on first open: the user sees "Chargement
--- de l'interface…" immediately and data fills in once decrypt completes.
--- @param log_dir string Path to the logging directory.
local function load_and_inject(log_dir)
	if not M._wv then return end

	local log_manager = require("modules.keylogger.log_manager")
	local today_str   = os.date("%Y-%m-%d")

	-- Scan for uncommitted past-day .idx files BEFORE running any migration.
	-- A past-day .idx means the Mac was off at midnight and merge_day_to_db
	-- never ran for that day (e.g. typed on Monday, Mac off until Thursday).
	local has_pending_past_idx = false
	local dir_iter, dir_state = fs.dir(log_dir)
	if dir_iter then
		for file_name in dir_iter, dir_state do
			local y, mo, d = file_name:match("^(%d%d%d%d)-(%d%d)-(%d%d)%.idx$")
			if y and mo and d then
				local file_date = string.format("%s-%s-%s", y, mo, d)
				if file_date ~= today_str then
					has_pending_past_idx = true
					break
				end
			end
		end
	end

	-- Past-day migration: commits any pending .idx into encrypted DB.
	pcall(log_manager.rebuild_index_if_needed)

	-- Invalidate caches on day boundary or after past-day migration.
	if M._cache_date ~= today_str or has_pending_past_idx then
		if has_pending_past_idx then
			Logger.info(LOG, "Past-day migration completed — flushing historical caches.")
		else
			Logger.info(LOG, "New day detected — flushing historical caches.")
		end
		M._cache_date    = today_str
		M._data_cache    = {}
		M._hist_manifest = nil
	end

	-- Today's live manifest (cheap plaintext read, changes live).
	local manifest = {}
	local f = io.open(log_dir .. "/manifest.json", "r")
	if f then
		local content = f:read("*a")
		f:close()
		pcall(function() manifest = json.decode(content) or {} end)
	end

	-- Historical manifest from SQLite — cached after first decrypt.
	local enc_path = log_dir .. "/metrics.sqlite.enc"
	local pwd      = log_manager.get_mac_serial():gsub("\"", "\\\"")
	if M._hist_manifest then
		Logger.done(LOG, "Historical manifest cache hit — skipping DB decrypt.")
		for date_str, day_data in pairs(M._hist_manifest) do
			manifest[date_str] = manifest[date_str] or {}
			for app_name, stats in pairs(day_data) do
				manifest[date_str][app_name] = stats
			end
		end
	elseif fs.attributes(enc_path) then
		Logger.trace(LOG, "Historical manifest cache miss — decrypting DB…")
		M._hist_manifest = {}
		local tmp_path = os.tmpname()
		hs.execute(string.format(
			"openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>/dev/null",
			pwd, enc_path, tmp_path
		))
		local db = sqlite3.open(tmp_path)
		if db then
			for row in db:nrows("SELECT date, app_name, stats_json FROM daily_manifest") do
				local ok, parsed = pcall(json.decode, row.stats_json)
				if ok then
					M._hist_manifest[row.date]             = M._hist_manifest[row.date] or {}
					M._hist_manifest[row.date][row.app_name] = parsed
					manifest[row.date]                     = manifest[row.date] or {}
					manifest[row.date][row.app_name]       = parsed
				end
			end
			db:close()
		end
		os.remove(tmp_path)
		Logger.done(LOG, "Historical manifest decrypted and cached.")
	end

	-- Bail if the user closed the window during the slow decrypt above.
	if not M._wv then return end

	-- Build app icon map and compute the initial query parameters.
	local app_icons      = {}
	local icon_lookups   = 0
	local first_date     = nil
	local all_apps_set   = {}
	local all_apps_list  = {}

	for date_str, day_data in pairs(manifest) do
		if first_date == nil or date_str < first_date then first_date = date_str end
		for app_name, _ in pairs(day_data) do
			if app_name ~= "Unknown" and not all_apps_set[app_name] then
				all_apps_set[app_name]  = true
				table.insert(all_apps_list, app_name)
			end
			if app_name ~= "Unknown" and app_icons[app_name] == nil then
				local cached_icon = M._app_icon_cache[app_name]
				if cached_icon ~= nil then
					app_icons[app_name] = cached_icon or nil
				elseif icon_lookups < MAX_ICON_LOOKUPS_PER_OPEN then
					local icon = get_app_icon(app_name)
					M._app_icon_cache[app_name] = icon or false
					app_icons[app_name] = icon
					icon_lookups = icon_lookups + 1
				end
			end
		end
	end
	table.sort(all_apps_list)

	-- Build keycode layout (numeric kc → character) for the keyboard heatmap.
	local kc_layout = {}
	local ok_kc, raw_kc_map = pcall(function() return hs.keycodes.map end)
	if ok_kc and type(raw_kc_map) == "table" then
		for k, v in pairs(raw_kc_map) do
			if type(k) == "number" then kc_layout[tostring(k)] = tostring(v) end
		end
	end

	-- Pre-fetch the initial n-gram range (first_date → today, all apps).
	local initial_data_json = "null"
	if first_date then
		local initial_data = fetch_range_cached(log_dir, first_date, today_str, all_apps_list)
		initial_data_json = json.encode(initial_data)
	end

	if not M._wv then return end

	local manifest_json    = json.encode(manifest)
	local app_icons_json   = json.encode(app_icons)
	local ok_json, kc_layout_json = pcall(json.encode, kc_layout)
	if not ok_json then kc_layout_json = "{}" end

	-- Persist the freshly-built snapshot so the next open (even after HS
	-- reload) can render instantly from disk.  Done BEFORE the JS injection
	-- so a JS retry-loop failure does not block cache persistence.
	save_disk_cache({
		manifest     = manifest_json,
		app_icons    = app_icons_json,
		initial_data = initial_data_json,
		kc_layout    = kc_layout_json,
	})

	-- Retry injection every 150 ms until process_manifest is defined (up to ~9 s).
	-- Robust against slow CDN script loading on first open after fresh launch.
	local function try_inject(remaining)
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.process_manifest", function(t)
			if t == "function" then
				local js = string.format(
					"window.metrics_manifest=%s;window.app_icons=%s;window._prefetch_data=%s;window.keycode_layout=%s;window.process_manifest();",
					manifest_json, app_icons_json, initial_data_json, kc_layout_json
				)
				pcall(function() M._wv:evaluateJavaScript(js) end)
				Logger.success(LOG, "Dashboard manifest and data injected.")
			elseif remaining > 0 then
				hs.timer.doAfter(0.15, function() try_inject(remaining - 1) end)
			else
				Logger.error(LOG, "load_and_inject(): process_manifest() not available — JS may have failed to load.")
			end
		end)
	end
	try_inject(60)
end

--- Pre-fills the dashboard with the on-disk snapshot from the previous run
--- so the user sees populated KPIs/charts within milliseconds of opening,
--- well before the slow openssl decrypt + SQL refresh in load_and_inject()
--- completes.  Returns true when a cached payload was found and injection
--- was scheduled — the caller delays the background refresh slightly so JS
--- finishes parsing the cached data before the fresh values overwrite it.
--- @return boolean True if a cache existed and pre-fill was scheduled.
local function prefill_from_disk_cache()
	if not M._wv then return false end
	local cached = load_disk_cache()
	if not cached or type(cached.manifest) ~= "string" then
		Logger.debug(LOG, "No disk cache available — UI will fill from fresh decrypt.")
		return false
	end
	local function try_inject_cache(remaining)
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.process_manifest", function(t)
			if t == "function" then
				local js = string.format(
					"window.metrics_manifest=%s;window.app_icons=%s;window._prefetch_data=%s;window.keycode_layout=%s;window.process_manifest();",
					cached.manifest or "{}",
					cached.app_icons or "{}",
					cached.initial_data or "null",
					cached.kc_layout or "{}"
				)
				pcall(function() M._wv:evaluateJavaScript(js) end)
				Logger.success(LOG, "Dashboard pre-filled from disk cache.")
			elseif remaining > 0 then
				hs.timer.doAfter(0.10, function() try_inject_cache(remaining - 1) end)
			end
		end)
	end
	try_inject_cache(50)
	return true
end

function M.show(log_dir)
	if fs.attributes(log_dir, "mode") ~= "directory" then return end

	if M._wv then
		Logger.debug(LOG, "Dashboard already open, bringing to front…")
		ui_builder.force_focus(M._wv)
		pcall(function()
			M._wv:evaluateJavaScript("if(window.apply_date_app_filters) window.apply_date_app_filters();")
		end)
		return
	end

	Logger.start(LOG, "Opening typing metrics dashboard…")

	-- Create the webview FIRST with zero disk I/O so the window appears
	-- instantly.  All migration, decrypt, and SQL queries are deferred to
	-- load_and_inject() which fires once the window is on screen and the
	-- raise sequence has settled.  The HTML shows "Chargement de
	-- l'interface…" until the data injection completes.
	local sf    = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = "Métriques de frappe",
		style_masks = 15,
		assets_dir  = hs.configdir .. "/ui/metrics_typing/",
		on_close    = function()
			M._wv = nil
			-- Caches are intentionally NOT cleared on close: they are reused on re-open.
			if M._timer then M._timer:stop(); M._timer = nil end
			Logger.info(LOG, "Typing metrics dashboard closed.")
		end
	})

	-- Aggressive raise schedule: covers menu-dismiss / app-switch / compositor races.
	raise_now(M._wv, true)
	hs.timer.doAfter(0.05, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.15, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.35, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.70, function() raise_now(M._wv, false) end)

	-- Two-stage data fill:
	--   1. Pre-fill from on-disk snapshot (≈ 50 ms): the user sees real
	--      KPIs/charts within a frame, even if slightly stale.
	--   2. Refresh from fresh decrypt+SQL in the background and overwrite
	--      the cached values once ready.  The delay before refresh is
	--      longer when a cache hit was scheduled so JS has time to parse
	--      the cached payload before the fresh one overwrites it.
	hs.timer.doAfter(0.05, function()
		local had_cache = prefill_from_disk_cache()
		local refresh_delay = had_cache and 0.40 or 0.05
		hs.timer.doAfter(refresh_delay, function() load_and_inject(log_dir) end)
	end)

	-- Poll timer: serves subsequent filter-change requests from JS (cached).
	if M._timer then M._timer:stop() end
	M._timer = hs.timer.new(0.3, function()
		if not M._wv then
			M._timer:stop()
			M._timer = nil
			return
		end

		pcall(function()
			M._wv:evaluateJavaScript("window._lua_request", function(req)
				if req and type(req) == "string" and req ~= "" and req ~= "null" then
					pcall(function() M._wv:evaluateJavaScript("window._lua_request = null;") end)
					local ok, query = pcall(json.decode, req)
					if ok and query then
						Logger.debug(LOG, "Handling n-gram range request from frontend…")
						local raw_data = fetch_range_cached(log_dir, query.start_date, query.end_date, query.apps)
						local js_cmd = string.format("window.receive_range_data(%s)", json.encode(raw_data))
						pcall(function() M._wv:evaluateJavaScript(js_cmd) end)
					end
				end
			end)
		end)
	end)

	M._timer:start()
	Logger.success(LOG, "Typing metrics dashboard window opened (data loading…).")
end

--- Broadcasts real-time events to the webview UI without requiring a reload.
--- @param today_idx table The live dictionary state.
function M.push_live_update(today_idx)
	if M._wv then
		local js = string.format("if(window.receive_live_update) window.receive_live_update(%s);", json.encode(today_idx))
		pcall(function() M._wv:evaluateJavaScript(js) end)
	end
end

return M
