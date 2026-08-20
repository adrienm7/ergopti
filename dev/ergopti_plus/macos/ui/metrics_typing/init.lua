--- ui/metrics_typing/init.lua

--- ==============================================================================
--- MODULE: Typing Metrics Dashboard UI
--- DESCRIPTION:
--- Hosts the typing-metrics WebView. Reads from `db.sqlite` (the tmpdir cache
--- rebuildable from `data.sql`) via `modules.keylogger.sqlite_reader` and
--- projects the result into the JSON shape consumed by the (unchanged)
--- frontend JS.
---
--- FEATURES & RATIONALE:
--- 1. SQLite-only data path: no openssl decrypt, no manifest.json, no .idx
---    file — every value originates from `db.sqlite`.
--- 2. rev-keyed cache: cached projection is reused across opens until the
---    SQLite `meta.rev` advances (bumped on every ingest batch).
--- 3. Two-stage paint: pre-fill from disk-cached snapshot, then overwrite
---    with fresh SQL projection in the background.
--- 4. Filter requests: the JS frontend pushes `(start_date, end_date, apps)`
---    via `window._lua_request`; the poll timer reads it, runs the query
---    (cached), and pushes back the result.
--- ==============================================================================

local M = {}

local hs         = hs
local fs         = require("hs.fs")
local json       = require("hs.json")
local ui_builder = require("ui.ui_builder")
local Logger     = require("infra.logger")
local Paths      = require("infra.paths")
local i18n       = require("infra.i18n")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "metrics_typing"

-- Lazy-loaded to avoid circular require; populated on first open().
local _log_manager = nil
local function _get_log_manager()
	if not _log_manager then
		_log_manager = require("modules.keylogger.log_manager")
	end
	return _log_manager
end

--- Acquires the module-lifetime ingest subscription before any window is
--- published. A dashboard without this owner would silently stop refreshing,
--- so subscription failure is a startup refusal rather than optional telemetry.
--- @return boolean registered
local function ensure_ingest_listener()
	if M and M._ingest_listener_registered then return true end
	local ok, registered_or_err = xpcall(function()
		local manager = _get_log_manager()
		if type(manager) ~= "table" or type(manager.on_ingest_done) ~= "function" then
			error("LogManager.on_ingest_done is unavailable")
		end
		return manager.on_ingest_done(function()
			M.push_live_update()
		end)
	end, debug.traceback)
	if not ok or registered_or_err ~= true then
		Logger.error(LOG, "Typing metrics ingest-listener acquisition failed: %s.",
			tostring(ok and registered_or_err or registered_or_err))
		return false
	end
	M._ingest_listener_registered = true
	Logger.debug(LOG, "Post-ingest live-update listener registered.")
	return true
end

local UI_CACHE_DIR  = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/")
local UI_CACHE_FILE = UI_CACHE_DIR .. "ergopti_metrics_typing_cache.json"

M._wv             = nil
M._timer          = nil
M._app_icon_cache = {}
--- True once we have registered our on_ingest_done listener.
--- The listener is registered once for the module lifetime; subsequent
--- opens reuse it (the dashboard state is on M which is always live).
M._ingest_listener_registered = false
local _generation = 0
local _continuation_timers = {}

--- Cancels one exact scheduler handle without dropping refused cleanup debt.
--- @param handle table|nil Scheduler handle.
--- @return boolean settled True only when no native timer remains owned.
local function cancel_timer(handle)
	if type(handle) ~= "table" then return true end
	local ok, settled = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or settled ~= true then
		Logger.error(LOG, "Dashboard timer cleanup failed; exact handle retained: %s.",
			tostring(ok and settled or settled))
		return false
	end
	return true
end

--- Cancels the JS request poller while retaining a refused exact handle.
--- @return boolean settled True only when the poller was released.
local function cancel_poller()
	if not M._timer then return true end
	local handle = M._timer
	if not cancel_timer(handle) then return false end
	if M._timer == handle then M._timer = nil end
	return true
end

--- Cancels every delayed dashboard continuation independently.
--- @return boolean settled True only when all exact handles were released.
local function cancel_continuations()
	local snapshot = {}
	for handle in pairs(_continuation_timers) do snapshot[#snapshot + 1] = handle end
	local settled = true
	for _, handle in ipairs(snapshot) do
		if cancel_timer(handle) then
			_continuation_timers[handle] = nil
		else
			settled = false
		end
	end
	return settled
end

--- Invalidates callbacks and releases every timer owned by the current window.
--- @return boolean settled True only when all exact timers were released.
local function stop_runtime()
	_generation = _generation + 1
	M._pending_full_refresh = false
	local poller_stopped = cancel_poller()
	local continuations_stopped = cancel_continuations()
	return poller_stopped and continuations_stopped
end

--- Schedules one generation-owned delayed continuation.
--- @param delay number Delay in seconds.
--- @param generation integer Dashboard generation.
--- @param webview table Exact webview owner.
--- @param callback function Continuation body.
--- @param label string Diagnostic label.
--- @return boolean committed True only when the timer was armed.
local function schedule_continuation(delay, generation, webview, callback, label)
	local handle
	local timer_committed = false
	local ok, candidate, committed = xpcall(function()
		return TimerScheduler.after(delay, function()
			if timer_committed ~= true then return end
			if handle and handle.timer ~= nil then
				-- TimerScheduler fences one-shot user delivery before attempting stop;
				-- cleanup debt is retained globally and locally, but must not turn a
				-- committed first paint into a permanently blank dashboard.
				Logger.error(LOG, "%s continuation retained timer cleanup debt.", label)
			else
				if handle then _continuation_timers[handle] = nil end
			end
			if generation ~= _generation or M._wv ~= webview then return end
			callback()
		end)
	end, debug.traceback)
	handle = candidate
	if type(handle) == "table" then _continuation_timers[handle] = true end
	if not ok or type(handle) ~= "table" or committed ~= true then
		if type(handle) == "table" and cancel_timer(handle) then
			_continuation_timers[handle] = nil
		end
		Logger.error(LOG, "%s continuation timer was not committed: %s.", label,
			tostring(ok and committed or candidate))
		return false
	end
	timer_committed = true
	return true
end



--- Resolves the path to shared UI assets (fail-fast).
--- Priority: module-relative > upward search > ERROR
--- @param subdir string Subdirectory name under static/ergopti_plus/_shared/ui/.
--- @return string|nil Absolute path if found, nil if missing (ERROR logged).
local function resolve_ui_assets_dir(subdir)
	-- Resolved through the single shared-tree resolver (Paths.shared). The
	-- trailing slash is preserved because callers concatenate asset filenames
	-- directly onto the returned directory path.
	local base = Paths.shared("ui/" .. subdir)
	if base and fs.dir(base) then
		Logger.debug(LOG, "resolve_ui_assets_dir('%s'): resolved via Paths.shared.", subdir)
		return base .. "/"
	end

	Logger.error(LOG, "resolve_ui_assets_dir('%s'): directory not found after all attempts.", subdir)
	return nil
end

--- rev-keyed projection caches.
M._manifest_cache    = nil
M._manifest_rev      = -1
M._range_cache       = {}    -- cache_key → { historical, today }
M._range_cache_rev   = -1

--- Last query parameters seen by the poller.
M._last_query = nil
--- Coalesces one full manifest refresh per completed ingest cycle.
M._pending_full_refresh = false





-- ============================
-- ============================
-- ======= 1/ App icons =======
-- ============================
-- ============================

local MAX_ICON_LOOKUPS_PER_OPEN = 24

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





-- ===============================
-- ===============================
-- ======= 2/ Data loaders =======
-- ===============================
-- ===============================

--- Build a stable cache key for a (start, end, apps) query.
local function make_cache_key(start_date, end_date, apps)
	local sorted = {}
	if type(apps) == "table" then
		for _, v in ipairs(apps) do table.insert(sorted, v) end
		table.sort(sorted)
	end
	return (start_date or "") .. "|" .. (end_date or "") .. "|" .. table.concat(sorted, ",")
end

--- Reset the range cache when meta.rev advances.
local function _maybe_invalidate_range_cache(rev)
	if rev ~= M._range_cache_rev then
		M._range_cache     = {}
		M._range_cache_rev = rev
		Logger.info(LOG, "rev advanced (%d) — flushing n-gram range cache.", rev)
	end
end

--- Cached fetch_range — historical + today's per-app idx merged from SQLite.
local function fetch_range_cached(start_date, end_date, selected_apps)
	local log_manager   = require("modules.keylogger.log_manager")
	local sqlite_reader = require("modules.keylogger.sqlite_reader")
	local sqlite_path   = log_manager.get_sqlite_path()
	if not sqlite_path or not fs.attributes(sqlite_path) then
		return { historical = {}, today = {} }
	end

	local rev = log_manager.get_db_rev()
	_maybe_invalidate_range_cache(rev)

	local key = make_cache_key(start_date, end_date, selected_apps)
	if M._range_cache[key] then
		Logger.done(LOG, "n-gram range cache hit.")
		return M._range_cache[key]
	end
	Logger.trace(LOG, "n-gram range cache miss — projecting…")
	local result = sqlite_reader.read_range_split_today(sqlite_path, start_date, end_date, selected_apps)
	M._range_cache[key] = result
	Logger.done(LOG, "n-gram range cached.")
	return result
end

--- Cached manifest — invalidated on rev bump.
local function read_manifest_cached()
	local log_manager   = require("modules.keylogger.log_manager")
	local sqlite_reader = require("modules.keylogger.sqlite_reader")
	local sqlite_path   = log_manager.get_sqlite_path()
	if not sqlite_path or not fs.attributes(sqlite_path) then return {} end

	local rev = log_manager.get_db_rev()
	if M._manifest_cache and M._manifest_rev == rev then
		return M._manifest_cache
	end
	M._manifest_cache = sqlite_reader.read_manifest(sqlite_path)
	M._manifest_rev   = rev
	return M._manifest_cache
end





-- ================================
-- ================================
-- ======= 3/ Disk pre-fill =======
-- ================================
-- ================================

local function save_disk_cache(payload)
	local ok_enc, body = pcall(json.encode, payload)
	if not ok_enc then return end
	local f = io.open(UI_CACHE_FILE, "w")
	if f then f:write(body); f:close() end
end

local function load_disk_cache()
	local f = io.open(UI_CACHE_FILE, "r")
	if not f then return nil end
	local content = f:read("*a"); f:close()
	local ok, data = pcall(json.decode, content)
	if not ok or type(data) ~= "table" then return nil end
	return data
end





-- ===============================
-- ===============================
-- ======= 4/ Data refresh =======
-- ===============================
-- ===============================

local function load_and_inject(generation, webview)
	if generation ~= _generation or M._wv ~= webview then return false end

	local manifest = read_manifest_cached()
	if generation ~= _generation or M._wv ~= webview then return false end

	-- App icons + apps list + first_date computed from manifest.
	local app_icons      = {}
	local icon_lookups   = 0
	local first_date     = nil
	local all_apps_set   = {}
	local all_apps_list  = {}
	for date_str, day_data in pairs(manifest) do
		if first_date == nil or date_str < first_date then first_date = date_str end
		for app_name, _ in pairs(day_data) do
			if app_name ~= "Unknown" and not all_apps_set[app_name] then
				all_apps_set[app_name] = true
				table.insert(all_apps_list, app_name)
			end
			if app_name ~= "Unknown" and app_icons[app_name] == nil then
				local cached = M._app_icon_cache[app_name]
				if cached ~= nil then
					if cached then app_icons[app_name] = cached end
				elseif icon_lookups < MAX_ICON_LOOKUPS_PER_OPEN then
					local icon = get_app_icon(app_name)
					M._app_icon_cache[app_name] = icon or false
					if icon then app_icons[app_name] = icon end
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

	-- Initial range pre-fetch (first_date → today).
	local today_str         = os.date("%Y-%m-%d")
	local initial_data_json = "null"
	if first_date then
		local initial_data = fetch_range_cached(first_date, today_str, all_apps_list)
		initial_data_json  = json.encode(initial_data)
	end

	if generation ~= _generation or M._wv ~= webview then return false end

	local manifest_json  = json.encode(manifest)
	local app_icons_json = json.encode(app_icons)
	local ok_json, kc_layout_json = pcall(json.encode, kc_layout)
	if not ok_json then kc_layout_json = "{}" end

	save_disk_cache({
		manifest     = manifest_json,
		app_icons    = app_icons_json,
		initial_data = initial_data_json,
		kc_layout    = kc_layout_json,
	})

	local function try_inject(remaining)
		if generation ~= _generation or M._wv ~= webview then return end
		webview:evaluateJavaScript("typeof window.process_manifest", function(t)
			if generation ~= _generation or M._wv ~= webview then return end
			if t == "function" then
				local js = string.format(
					"window.metrics_manifest=%s;window.app_icons=%s;window._prefetch_data=%s;window.keycode_layout=%s;window.process_manifest();",
					manifest_json, app_icons_json, initial_data_json, kc_layout_json)
				local ok_inject, inject_result = pcall(function()
					return webview:evaluateJavaScript(js)
				end)
				if not ok_inject or inject_result == false then
					Logger.error(LOG, "Dashboard manifest injection failed: %s.",
						tostring(inject_result))
					return
				end
				Logger.success(LOG, "Dashboard manifest and data injected.")
			elseif remaining > 0 then
				schedule_continuation(0.15, generation, webview,
					function() try_inject(remaining - 1) end, "Dashboard manifest retry")
			else
				Logger.error(LOG, "load_and_inject(): process_manifest() not available.")
			end
		end)
	end
	try_inject(60)
	return true
end

--- Refresh just the manifest-backed UI state after an ingest. `process_manifest`
--- preserves the current filters and requests their n-gram range again, avoiding
--- load_and_inject()'s expensive all-app prefetch on every live update.
local function refresh_live_manifest(generation, webview)
	if generation ~= _generation or M._wv ~= webview then return false end
	local manifest = read_manifest_cached()
	if generation ~= _generation or M._wv ~= webview then return false end
	local encoded_ok, manifest_json = pcall(json.encode, manifest)
	if not encoded_ok then return false end
	local ok_inject, inject_result = pcall(function()
		return webview:evaluateJavaScript(string.format(
			"window.metrics_manifest=%s;if(typeof window.process_manifest==='function'){window._prefetch_data=null;window.process_manifest();}",
			manifest_json))
	end)
	return ok_inject and inject_result ~= false
end

local function prefill_from_disk_cache(generation, webview)
	if generation ~= _generation or M._wv ~= webview then return false end
	local cached = load_disk_cache()
	if not cached or type(cached.manifest) ~= "string" then return false end
	local function try_inject_cache(remaining)
		if generation ~= _generation or M._wv ~= webview then return end
		webview:evaluateJavaScript("typeof window.process_manifest", function(t)
			if generation ~= _generation or M._wv ~= webview then return end
			if t == "function" then
				local js = string.format(
					"window.metrics_manifest=%s;window.app_icons=%s;window._prefetch_data=%s;window.keycode_layout=%s;window.process_manifest();",
					cached.manifest or "{}", cached.app_icons or "{}",
					cached.initial_data or "null", cached.kc_layout or "{}")
				local ok_inject, inject_result = pcall(function()
					return webview:evaluateJavaScript(js)
				end)
				if not ok_inject or inject_result == false then
					Logger.error(LOG, "Dashboard cache injection failed: %s.",
						tostring(inject_result))
					return
				end
				Logger.success(LOG, "Dashboard pre-filled from disk cache.")
			elseif remaining > 0 then
				schedule_continuation(0.10, generation, webview,
					function() try_inject_cache(remaining - 1) end, "Dashboard cache retry")
			end
		end)
	end
	try_inject_cache(50)
	return true
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

function M.show()
	if M._wv then
		local already_focused = false
		pcall(function()
			local win     = M._wv:hswindow()
			if win then
				local focused   = hs.window.focusedWindow()
				already_focused = focused and focused:id() == win:id()
			end
		end)
		if already_focused then
			Logger.debug(LOG, "Dashboard already focused — closing.")
			local window = M._wv
			M._wv = nil
			local stopped = stop_runtime()
			pcall(function() window:delete() end)
			return stopped
		end
		Logger.debug(LOG, "Dashboard already open, bringing to front…")
		pcall(function()
			local win = M._wv:hswindow()
			if win then win:focus()
			else M._wv:bringToFront(false); pcall(hs.focus) end
		end)
		pcall(function()
			M._wv:evaluateJavaScript("if(window.apply_date_app_filters) window.apply_date_app_filters();")
		end)
		return true
	end

	Logger.start(LOG, "Opening typing metrics dashboard…")

	local sf    = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	local assets_dir = resolve_ui_assets_dir("metrics_typing")
	if not assets_dir then
		Logger.error(LOG, "Cannot open dashboard — shared UI assets not found.")
		return false
	end
	if not ensure_ingest_listener() then return false end

	_generation = _generation + 1
	local generation = _generation
	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = i18n.get("metrics_apps.title"),
		style_masks = 15,
		assets_dir = assets_dir,
		on_close   = function()
			if generation ~= _generation then return end
			_generation = _generation + 1
			M._wv = nil
			local poller_stopped = cancel_poller()
			local continuations_stopped = cancel_continuations()
			if not poller_stopped or not continuations_stopped then
				Logger.error(LOG, "Typing metrics close retained timer cleanup debt.")
			end
			Logger.info(LOG, "Typing metrics dashboard closed.")
		end,
	})
	local webview = M._wv
	if not webview then
		Logger.error(LOG, "Typing metrics dashboard webview creation failed.")
		return false
	end

	local bootstrap_committed = schedule_continuation(0.05, generation, webview, function()
		local had_cache     = prefill_from_disk_cache(generation, webview)
		local refresh_delay = had_cache and 0.40 or 0.05
		if not schedule_continuation(refresh_delay, generation, webview,
			function() load_and_inject(generation, webview) end,
			"Dashboard fresh-data load")
		then
			Logger.error(LOG, "Dashboard fresh-data load could not be scheduled.")
		end
	end, "Dashboard bootstrap")
	if not bootstrap_committed then
		M._wv = nil
		stop_runtime()
		pcall(function() webview:delete() end)
		Logger.error(LOG, "Typing metrics dashboard startup failed: bootstrap timer unavailable.")
		return false
	end

	-- JS-side filter request poller.
	if not cancel_poller() then
		M._wv = nil
		stop_runtime()
		pcall(function() webview:delete() end)
		Logger.error(LOG, "Typing metrics dashboard startup failed: prior poller cleanup remains pending.")
		return false
	end
	local poll_ok, poll_candidate, poll_committed = xpcall(function()
		return TimerScheduler.every(0.3, function()
		if generation ~= _generation or M._wv ~= webview then return end
		pcall(function()
			webview:evaluateJavaScript("window._lua_request", function(req)
				if generation ~= _generation or M._wv ~= webview then return end
				if req and type(req) == "string" and req ~= "" and req ~= "null" then
					pcall(function() webview:evaluateJavaScript("window._lua_request = null;") end)
					local ok, query = pcall(json.decode, req)
					if ok and query then
						if query.action == "clear_cache" then
							os.remove(UI_CACHE_FILE)
							M._range_cache    = {}
							M._manifest_cache = nil
							-- Also clear _last_query so push_live_update does not re-issue
							-- a fetch against the freshly wiped state (ui-windows-b-3).
							M._last_query = nil
							Logger.info(LOG, "Caches cleared by user reset.")
					else
						M._last_query = query
						local raw_data = fetch_range_cached(query.start_date, query.end_date, query.apps)
						local request_id = tonumber(query.request_id)
						local js_cmd
						if request_id and request_id > 0 and request_id % 1 == 0 then
							js_cmd = string.format(
								"window.receive_range_data(%s,%d)", json.encode(raw_data), request_id)
						else
							-- Backward compatibility for a cached dashboard loaded before the
							-- request-id protocol was introduced.
							js_cmd = string.format("window.receive_range_data(%s)", json.encode(raw_data))
						end
						pcall(function() webview:evaluateJavaScript(js_cmd) end)
					end
				end
				end
			end)
		end)
		end)
	end, debug.traceback)
	if type(poll_candidate) == "table" then M._timer = poll_candidate end
	if not poll_ok or type(poll_candidate) ~= "table" or poll_committed ~= true then
		M._wv = nil
		stop_runtime()
		pcall(function() webview:delete() end)
		Logger.error(LOG, "Typing metrics dashboard startup failed: request poller unavailable: %s.",
			tostring(poll_ok and poll_committed or poll_candidate))
		return false
	end

	Logger.success(LOG, "Typing metrics dashboard window opened.")
	return true
end

--- Signals that a fresh ingest cycle just completed. Both the n-gram tables
--- and the manifest-backed KPIs change, so refresh the manifest and replay the
--- active range without recomputing the global all-app prefetch.
function M.push_live_update(_unused)
	if M._wv and not M._pending_full_refresh then
		local generation = _generation
		local webview = M._wv
		M._pending_full_refresh = true
		if not schedule_continuation(0, generation, webview, function()
			M._pending_full_refresh = false
			if not refresh_live_manifest(generation, webview) then
				Logger.error(LOG, "Live metrics manifest refresh failed.")
			end
		end, "Live metrics manifest refresh") then
			M._pending_full_refresh = false
			return false
		end
		Logger.debug(LOG, "push_live_update: scheduled full manifest refresh.")
		return true
	end
	return false
end

return M
