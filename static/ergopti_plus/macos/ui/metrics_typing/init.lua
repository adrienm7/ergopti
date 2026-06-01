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
local Logger     = require("lib.logger")
local i18n       = require("lib.i18n")

local LOG = "metrics_typing"

local UI_CACHE_DIR  = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/")
local UI_CACHE_FILE = UI_CACHE_DIR .. "ergopti_metrics_typing_cache.json"

M._wv             = nil
M._timer          = nil
M._app_icon_cache = {}



--- Resolves the path to shared UI assets (fail-fast).
--- Priority: module-relative > upward search > ERROR
--- @param subdir string Subdirectory name under static/ergopti_plus/shared/ui/.
--- @return string|nil Absolute path if found, nil if missing (ERROR logged).
local function resolve_ui_assets_dir(subdir)
	local source = debug.getinfo(1, "S").source or ""
	source = source:sub(1, 1) == "@" and source:sub(2) or source
	local this_dir = source:match("^(.*)/[^/]+$") or ""
	if this_dir ~= "" then
		local by_module = this_dir .. "/../../shared/ui/" .. subdir
		if fs.dir(by_module) then
			Logger.debug(LOG, "resolve_ui_assets_dir('%s'): module path OK.", subdir)
			return by_module .. "/"
		end
	end

	local Paths = require("lib.paths")
	local base = Paths.find_from_configdir("static/ergopti_plus/shared/ui/" .. subdir)
	if base and fs.dir(base) then
		Logger.debug(LOG, "resolve_ui_assets_dir('%s'): upward search OK.", subdir)
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




-- =================================
--- ============================
-- ======= 1/ App icons =======
--- ============================
-- =================================

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




-- ====================================
--- ===============================
-- ======= 2/ Data loaders =======
--- ===============================
-- ====================================

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




-- ====================================
--- ================================
-- ======= 3/ Disk pre-fill =======
--- ================================
-- ====================================

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

local function raise_now(wv)
	if not wv then return end
	pcall(function() wv:show() end)
	pcall(hs.focus)
	local ok, win = pcall(function() return wv:hswindow() end)
	if ok and win then pcall(function() win:focus() end) end
end

local function poll_and_set_behavior(wv, attempts)
	if not wv then return end
	local ok, win = pcall(function() return wv:hswindow() end)
	if ok and win then
		local beh    = (hs.drawing and hs.drawing.windowBehaviors) or {}
		local target = (beh.managed or 4) + (beh.participatesInCycle or 32)
		pcall(function() wv:behavior(target) end)
		pcall(function() win:focus() end)
		pcall(hs.focus)
	elseif attempts > 0 then
		hs.timer.doAfter(0.05, function() poll_and_set_behavior(wv, attempts - 1) end)
	end
end




-- ====================================
--- ===============================
-- ======= 4/ Data refresh =======
--- ===============================
-- ====================================

local function load_and_inject()
	if not M._wv then return end

	local manifest = read_manifest_cached()
	if not M._wv then return end

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

	if not M._wv then return end

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
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.process_manifest", function(t)
			if t == "function" then
				local js = string.format(
					"window.metrics_manifest=%s;window.app_icons=%s;window._prefetch_data=%s;window.keycode_layout=%s;window.process_manifest();",
					manifest_json, app_icons_json, initial_data_json, kc_layout_json)
				pcall(function() M._wv:evaluateJavaScript(js) end)
				Logger.success(LOG, "Dashboard manifest and data injected.")
			elseif remaining > 0 then
				hs.timer.doAfter(0.15, function() try_inject(remaining - 1) end)
			else
				Logger.error(LOG, "load_and_inject(): process_manifest() not available.")
			end
		end)
	end
	try_inject(60)
end

local function prefill_from_disk_cache()
	if not M._wv then return false end
	local cached = load_disk_cache()
	if not cached or type(cached.manifest) ~= "string" then return false end
	local function try_inject_cache(remaining)
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.process_manifest", function(t)
			if t == "function" then
				local js = string.format(
					"window.metrics_manifest=%s;window.app_icons=%s;window._prefetch_data=%s;window.keycode_layout=%s;window.process_manifest();",
					cached.manifest or "{}", cached.app_icons or "{}",
					cached.initial_data or "null", cached.kc_layout or "{}")
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




-- =====================================
--- =============================
-- ======= 5/ Public API =======
--- =============================
-- =====================================

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
			M._wv:delete(); M._wv = nil
			if M._timer then M._timer:stop(); M._timer = nil end
			return
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
		return
	end

	Logger.start(LOG, "Opening typing metrics dashboard…")

	local sf    = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	local assets_dir = resolve_ui_assets_dir("metrics_typing")
	if not assets_dir then
		Logger.error(LOG, "Cannot open dashboard — shared UI assets not found.")
		return
	end

	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = i18n.get("metrics_apps.title"),
		style_masks = 15,
		assets_dir = assets_dir,
		on_close   = function()
			M._wv = nil
			if M._timer then M._timer:stop(); M._timer = nil end
			Logger.info(LOG, "Typing metrics dashboard closed.")
		end,
	})

	raise_now(M._wv)
	poll_and_set_behavior(M._wv, 20)

	hs.timer.doAfter(0.05, function()
		local had_cache     = prefill_from_disk_cache()
		local refresh_delay = had_cache and 0.40 or 0.05
		hs.timer.doAfter(refresh_delay, load_and_inject)
	end)

	-- JS-side filter request poller.
	if M._timer then M._timer:stop() end
	M._timer = hs.timer.new(0.3, function()
		if not M._wv then
			M._timer:stop(); M._timer = nil
			return
		end
		pcall(function()
			M._wv:evaluateJavaScript("window._lua_request", function(req)
				if req and type(req) == "string" and req ~= "" and req ~= "null" then
					pcall(function() M._wv:evaluateJavaScript("window._lua_request = null;") end)
					local ok, query = pcall(json.decode, req)
					if ok and query then
						if query.action == "clear_cache" then
							os.remove(UI_CACHE_FILE)
							M._range_cache    = {}
							M._manifest_cache = nil
							Logger.info(LOG, "Caches cleared by user reset.")
						else
							local raw_data = fetch_range_cached(query.start_date, query.end_date, query.apps)
							local js_cmd   = string.format("window.receive_range_data(%s)", json.encode(raw_data))
							pcall(function() M._wv:evaluateJavaScript(js_cmd) end)
						end
					end
				end
			end)
		end)
	end)
	M._timer:start()

	Logger.success(LOG, "Typing metrics dashboard window opened.")
end

--- Live-update hook kept for API compatibility; the rev-keyed cache picks
--- up new data on the next read.
function M.push_live_update(_unused)
	-- No-op: the SQLite cache is the source of truth and the range cache
	-- invalidates itself when meta.rev advances on the next ingest tick.
end

return M
