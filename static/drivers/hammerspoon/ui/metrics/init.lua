--- ui/metrics/init.lua

--- ==============================================================================
--- MODULE: Metrics Dashboard UI
--- DESCRIPTION:
--- Injects and manages the HTML/JS webview to display typing metrics.
---
--- FEATURES & RATIONALE:
--- 1. Decoupled Architecture: Connects raw local logs to an isolated Webview.
--- 2. Singleton Preservation: Reuses instances without reloading the DOM.
--- 3. Format Resiliency: Understands both optimized index schema and legacy formats.
--- ==============================================================================

local M = {}
local hs = hs
local fs = require("hs.fs")
local json = require("hs.json")
local ui_builder = require("ui.ui_builder")

M._wv       = nil
M._timer    = nil
M._last_req = nil





-- =====================================
-- =====================================
-- ======= 1/ Data Retrieval =======
-- =====================================
-- =====================================

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

--- Lazily loads compressed daily index files on demand for the JavaScript UI.
--- @param log_dir string Path to logs.
--- @param start_date string Minimum date boundary.
--- @param end_date string Maximum date boundary.
--- @param selected_apps table Array of requested applications.
--- @return table The fully merged big dictionary for the UI.
local function fetch_range(log_dir, start_date, end_date, selected_apps)
	local merged = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {} }
	local app_set = {}
	
	if selected_apps and type(selected_apps) == "table" then
		for _, app in ipairs(selected_apps) do app_set[app] = true end
	end

	for f in fs.dir(log_dir) do
		local y, m, d = f:match("^(%d%d%d%d)_(%d%d)_(%d%d)%.idx")
		if y and m and d then
			local date_str = string.format("%s-%s-%s", y, m, d)
			local is_in_range = true
			if start_date and start_date ~= "" and date_str < start_date then is_in_range = false end
			if end_date and end_date ~= "" and date_str > end_date then is_in_range = false end

			if is_in_range then
				local content = ""
				local full_path = log_dir .. "/" .. f
				
				if f:match("%.gz$") then
					local p = io.popen(string.format("gzip -c -d %q 2>/dev/null", full_path), "r")
					if p then 
						content = p:read("*a")
						p:close() 
					end
				else
					local file = io.open(full_path, "r")
					if file then 
						content = file:read("*a")
						file:close() 
					end
				end

				if content and content ~= "" then
					local ok, day_data = pcall(json.decode, content)
					if ok and type(day_data) == "table" then
						for appName, appData in pairs(day_data) do
							if app_set[appName] then
								for k_type, k_dict in pairs(appData) do
									if merged[k_type] and type(k_dict) == "table" then
										for k_seq, k_stats in pairs(k_dict) do
											local t = merged[k_type][k_seq]
											if not t then
												t = { c = 0, t = 0, hs = 0, llm = 0, o = 0, e = 0 }
												merged[k_type][k_seq] = t
											end
											
											-- Accommodate varying schemas (array/legacy dict/omitted zeroes)
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
				end
			end
		end
	end
	
	return merged
end





-- =====================================
-- =====================================
-- ======= 2/ UI Injection =======
-- =====================================
-- =====================================

--- Injects the instant manifest and polls for lazy loading requests.
--- @param log_dir string Path to the logging directory.
function M.show(log_dir)
	if fs.attributes(log_dir, "mode") ~= "directory" then return end
	
	-- Early return: Reuse the webview if it is already open to strictly preserve state
	if M._wv then
		ui_builder.force_focus(M._wv)
		return
	end
	
	local manifest_path = log_dir .. "/manifest.json"
	local manifest = {}
	local f = io.open(manifest_path, "r")
	
	if f then
		local content = f:read("*a")
		f:close()
		pcall(function() manifest = json.decode(content) or {} end)
	end

	local app_icons = {}
	for _, day_data in pairs(manifest) do
		for app_name, _ in pairs(day_data) do
			if app_name ~= "Unknown" and not app_icons[app_name] then
				app_icons[app_name] = get_app_icon(app_name)
			end
		end
	end

	local sf = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	-- Request the webview creation/focus from the centralized UI builder
	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = "Métriques de frappe",
		style_masks = 15,
		assets_dir  = hs.configdir .. "/ui/metrics/",
		on_close    = function()
			M._wv = nil
			if M._timer then 
				M._timer:stop()
				M._timer = nil 
			end
		end
	})

	-- Load manifest safely into the browser
	hs.timer.doAfter(0.5, function()
		if M._wv then 
			local js = string.format("window.metrics_manifest = %s; window.app_icons = %s; if(window.process_manifest) window.process_manifest();", json.encode(manifest), json.encode(app_icons))
			pcall(function() M._wv:evaluateJavaScript(js) end)
		end
	end)

	if M._timer then M._timer:stop() end
	
	-- Data polling loop
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
						local raw_data = fetch_range(log_dir, query.start_date, query.end_date, query.apps)
						local js_cmd = string.format("window.receive_range_data(%s)", json.encode(raw_data))
						pcall(function() M._wv:evaluateJavaScript(js_cmd) end)
					end
				end
			end)
		end)
	end)
	
	M._timer:start()
end

return M
