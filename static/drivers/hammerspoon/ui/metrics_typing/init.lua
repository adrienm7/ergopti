--- ui/metrics_typing/init.lua

--- ==============================================================================
--- MODULE: Metrics Dashboard UI
--- DESCRIPTION:
--- Injects and manages the HTML/JS webview to display typing metrics.
---
--- FEATURES & RATIONALE:
--- 1. Decoupled Architecture: Connects raw SQLite DB to an isolated Webview.
--- 2. Instant Rendering: Leverages SQLite for sub-millisecond historical queries.
--- 3. Real-Time Push: Subscribes to the Keylogger event bus to sync actively.
--- ==============================================================================

local M = {}

local hs         = hs
local fs         = require("hs.fs")
local json       = require("hs.json")
local sqlite3    = require("hs.sqlite3")
local ui_builder = require("ui.ui_builder")
local Logger     = require("lib.logger")

local LOG = "metrics_typing"

M._wv             = nil
M._timer          = nil
M._last_req       = nil
M._app_icon_cache = {}





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

	local historical_merged = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {} }
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
			local query = "SELECT app_name, index_json FROM daily_index WHERE 1=1"
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
	
	local f_idx = io.open(log_dir .. "/" .. os.date("%Y_%m_%d") .. ".idx", "r")
	local today_idx = {}
	if f_idx then
		local c = f_idx:read("*a")
		f_idx:close()
		pcall(function() today_idx = json.decode(c) or {} end)
	end

	return { historical = historical_merged, today = today_idx }
end





-- ===============================
-- ===============================
-- ======= 2/ UI Injection =======
-- ===============================
-- ===============================

--- Injects the instant manifest and polls for lazy loading requests.
--- @param log_dir string Path to the logging directory.
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
	
	Logger.debug(LOG, "Building typing metrics dashboard UI…")
	local log_manager = require("modules.keylogger.log_manager")
	pcall(log_manager.rebuild_today_from_raw_log)

	local manifest_path = log_dir .. "/manifest.json"
	local manifest = {}
	local f = io.open(manifest_path, "r")
	if f then
		local content = f:read("*a")
		f:close()
		pcall(function() manifest = json.decode(content) or {} end)
	end

	local enc_path = log_dir .. "/metrics.sqlite.enc"
	local pwd = log_manager.get_mac_serial():gsub("\"", "\\\"")

	if fs.attributes(enc_path) then
		Logger.debug(LOG, "Extracting historical manifest data from encrypted DB…")
		local tmp_path = os.tmpname()
		hs.execute(string.format("openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>/dev/null", pwd, enc_path, tmp_path))
		local db = sqlite3.open(tmp_path)
		if db then
			for row in db:nrows("SELECT date, app_name, stats_json FROM daily_manifest") do
				manifest[row.date] = manifest[row.date] or {}
				local ok, parsed = pcall(json.decode, row.stats_json)
				if ok then manifest[row.date][row.app_name] = parsed end
			end
			db:close()
		end
		os.remove(tmp_path)
	end

	local app_icons = {}
	local icon_lookups = 0
	for _, day_data in pairs(manifest) do
		for app_name, _ in pairs(day_data) do
			if app_name ~= "Unknown" and app_icons[app_name] == nil then
				local cached_icon = M._app_icon_cache[app_name]
				if cached_icon ~= nil then
					app_icons[app_name] = cached_icon or nil
				elseif icon_lookups < MAX_ICON_LOOKUPS_PER_OPEN then
					local icon = get_app_icon(app_name)
					M._app_icon_cache[app_name] = icon or false
					app_icons[app_name] = icon
					icon_lookups = icon_lookups + 1
				else
					app_icons[app_name] = nil
				end
			end
		end
	end

	local sf = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = "Métriques de frappe",
		style_masks = 15,
		assets_dir  = hs.configdir .. "/ui/metrics_typing/",
		on_close    = function()
			M._wv = nil
			if M._timer then 
				M._timer:stop()
				M._timer = nil 
			end
			Logger.info(LOG, "Typing metrics dashboard closed.")
		end
	})

	hs.timer.doAfter(0.5, function()
		if M._wv then 
			local js = string.format("window.metrics_manifest = %s; window.app_icons = %s; if(window.process_manifest) window.process_manifest();", json.encode(manifest), json.encode(app_icons))
			pcall(function() M._wv:evaluateJavaScript(js) end)
		end
	end)

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
						Logger.debug(LOG, "Handling requested data range from frontend…")
						local raw_data = fetch_range(log_dir, query.start_date, query.end_date, query.apps)
						local js_cmd = string.format("window.receive_range_data(%s)", json.encode(raw_data))
						pcall(function() M._wv:evaluateJavaScript(js_cmd) end)
					end
				end
			end)
		end)
	end)
	
	M._timer:start()
	Logger.info(LOG, "Typing metrics dashboard displayed successfully.")
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
