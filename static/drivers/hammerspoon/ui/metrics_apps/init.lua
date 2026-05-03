--- ui/metrics_apps/init.lua

--- ==============================================================================
--- MODULE: Apps Time Dashboard UI
--- DESCRIPTION:
--- Injects and manages the HTML/JS webview to display app time metrics.
---
--- FEATURES & RATIONALE:
--- 1. Decoupled Architecture: Connects raw SQLite DB to an isolated Webview.
--- 2. File Injection: Writes the data directly to disk for reliable loading.
--- 3. Centralized JSON Config: Manages custom user categories directly from Lua.
--- 4. App Picker Integration: Prompts users with native dialogs to reclassify apps.
--- ==============================================================================

local M = {}

local hs         = hs
local fs         = require("hs.fs")
local json       = require("hs.json")
local sqlite3    = require("hs.sqlite3")
local ui_builder = require("ui.ui_builder")
local Logger     = require("lib.logger")
local dialog     = require("lib.dialog_util")

local LOG = "metrics_apps"

M._wv = nil

-- Persistent caches — survive UI close/reopen within the same Hammerspoon session
-- so that the expensive openssl decrypt runs at most once per calendar day.
M._hist_manifest_cache = nil   -- date → app_name → stats (from SQLite daily_manifest)
M._cache_date          = nil   -- date string when the cache was last populated

local CONFIG_DIR = hs.configdir .. "/data"
local CATEGORIES_FILE = CONFIG_DIR .. "/app_categories.json"





-- =======================================
-- =======================================
-- ======= 1/ JSON Data Management =======
-- =======================================
-- =======================================

--- Reads the custom categories from the JSON configuration file.
--- @return table The dictionary of overridden app categories.
local function load_categories()
	local f = io.open(CATEGORIES_FILE, "r")
	if f then
		local content = f:read("*a")
		f:close()
		local ok, data = pcall(json.decode, content)
		if ok and type(data) == "table" then return data end
	end
	return {}
end

--- Persists the categories dictionary back to the JSON file securely.
--- @param data table The full categories mapping.
local function save_categories(data)
	os.execute(string.format("mkdir -p %q", CONFIG_DIR))
	local f = io.open(CATEGORIES_FILE, "w")
	if f then
		f:write(json.encode(data))
		f:close()
		Logger.debug(LOG, "App categories JSON saved successfully.")
	end
end





-- ===================================
-- ===================================
-- ======= 2/ User Interaction =======
-- ===================================
-- ===================================

--- Opens the native dialogs to let the user reclassify an application.
--- @param app_name string The name of the application.
--- @param default_cat string The default category to pre-fill.
--- @param default_score number The default score to pre-fill.
function M.prompt_category(app_name, default_cat, default_score)
	local button, new_cat = dialog.text_prompt("Catégorie", "Nouvelle catégorie pour " .. app_name .. " (ex: Code, Bureautique, Loisir) :", default_cat or "Général", "OK", "Annuler")
	if button == "OK" and new_cat ~= "" then
		local btn2, new_score_str = dialog.text_prompt("Score", "Nouveau score de productivité pour " .. app_name .. "\n(-2 très distrayant à 2 très productif) :", tostring(default_score or 0), "OK", "Annuler")
		if btn2 == "OK" then
			local score = tonumber(new_score_str) or 0
			if score >= -2 and score <= 2 then
				local cats = load_categories()
				cats[app_name] = { type = new_cat, score = score }
				save_categories(cats)
				
				if M._wv then
					Logger.debug(LOG, "Pushing updated JSON categories to Webview…")
					M._wv:evaluateJavaScript(string.format("window.updateUserCategories(%s);", json.encode(cats)))
				end
			else
				dialog.alert("Erreur", "Le score doit être compris entre -2 et 2.", "OK")
			end
		end
	end
end

-- Bridge URL interceptor for webview button clicks
hs.urlevent.bind("metricsAppsAction", function(eventName, params)
	local action = params.action
	if action == "edit" then
		local app_name = hs.http.urlDecode(params.app)
		local cat = hs.http.urlDecode(params.cat)
		local score = tonumber(params.score) or 0
		M.prompt_category(app_name, cat, score)
	elseif action == "pick" then
		
		-- Failsafe native app chooser if external module is missing
		local function launch_fallback_chooser()
			local apps = hs.application.runningApplications()
			local choices = {}
			local seen = {}
			for _, app in ipairs(apps) do
				local title = app:title()
				if title and title ~= "" and not seen[title] then
					seen[title] = true
					table.insert(choices, { text = title, subText = app:bundleID() })
				end
			end
			table.sort(choices, function(a,b) return a.text < b.text end)
			local chooser = hs.chooser.new(function(choice)
				if choice then
					local cats = load_categories()
					local current = cats[choice.text] or { type = "Général", score = 0 }
					M.prompt_category(choice.text, current.type, current.score)
				end
			end)
			chooser:choices(choices)
			chooser:show()
		end

		local ok, app_picker = pcall(require, "lib.app_picker")
		if ok and type(app_picker.show) == "function" then
			app_picker.show(function(app)
				local app_name = type(app) == "table" and (app.name or app.title) or tostring(app)
				if app_name and app_name ~= "" then
					local cats = load_categories()
					local current = cats[app_name] or { type = "Général", score = 0 }
					M.prompt_category(app_name, current.type, current.score)
				end
			end)
		else
			launch_fallback_chooser()
		end
	end
end)





-- ===============================
-- ===============================
-- ======= 3/ UI Injection =======
-- ===============================
-- ===============================

--- Shows the webview for the apps time dashboard.
--- @param log_dir string Path to the logging directory.
--- Aggressively raises the dashboard window above any compositing menu.
--- Same rationale as metrics_typing.raise_now — see that module for details.
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

--- Performs the slow disk I/O (today rebuild, manifest read, DB decrypt) and
--- injects the resulting manifest into the already-visible webview.  Decoupling
--- this from M.show() lets the window appear instantly: the user sees the empty
--- shell first and the data fills in once decrypt completes.
--- @param log_dir string Path to the logging directory.
local function load_and_inject(log_dir)
	if not M._wv then return end

	local log_manager = require("modules.keylogger.log_manager")
	pcall(log_manager.rebuild_today_from_raw_log)

	local today_str = os.date("%Y-%m-%d")

	-- Invalidate historical cache on day boundary.
	if M._cache_date ~= today_str then
		M._cache_date          = today_str
		M._hist_manifest_cache = nil
		Logger.info(LOG, "New day or first open — flushing apps manifest cache.")
	end

	local manifest = {}
	local enc_path = log_dir .. "/metrics.sqlite.enc"
	local pwd      = log_manager.get_mac_serial():gsub("\"", "\\\"")

	if M._hist_manifest_cache then
		Logger.done(LOG, "Historical manifest cache hit — skipping DB decrypt.")
		for date_str, day_data in pairs(M._hist_manifest_cache) do
			manifest[date_str] = manifest[date_str] or {}
			for app_name, stats in pairs(day_data) do
				manifest[date_str][app_name] = stats
			end
		end
	elseif fs.attributes(enc_path) then
		Logger.trace(LOG, "Historical manifest cache miss — decrypting DB…")
		M._hist_manifest_cache = {}
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
					M._hist_manifest_cache[row.date]             = M._hist_manifest_cache[row.date] or {}
					M._hist_manifest_cache[row.date][row.app_name] = parsed
					manifest[row.date]                           = manifest[row.date] or {}
					manifest[row.date][row.app_name]             = parsed
				end
			end
			db:close()
		end
		os.remove(tmp_path)
		Logger.done(LOG, "Historical manifest decrypted and cached.")
	end

	if not M._wv then return end

	-- Today's live manifest (cheap plaintext read).
	local manifest_file = log_dir .. "/manifest.json"
	local mf = io.open(manifest_file, "r")
	if mf then
		local ok, m_data = pcall(json.decode, mf:read("*a"))
		mf:close()
		if ok and type(m_data) == "table" then
			for date_key, date_data in pairs(m_data) do
				manifest[date_key] = date_data
			end
		end
	end

	local user_cats      = load_categories()
	local manifest_json  = json.encode(manifest)
	local user_cats_json = json.encode(user_cats)

	-- Retry injection loop — robust against slow CDN loads.
	local function try_inject(remaining)
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.bootstrapMetricsAppsData", function(t)
			if t == "function" then
				local js = string.format("window.bootstrapMetricsAppsData(%s,%s);", manifest_json, user_cats_json)
				pcall(function() M._wv:evaluateJavaScript(js) end)
				Logger.success(LOG, "Apps dashboard manifest injected.")
			elseif t == "undefined" then
				M._wv:evaluateJavaScript("typeof window.initDashboard", function(t2)
					if t2 == "function" then
						local js = string.format("window.ManifestData=%s;window.UserCategories=%s;window.initDashboard();", manifest_json, user_cats_json)
						pcall(function() M._wv:evaluateJavaScript(js) end)
						Logger.success(LOG, "Apps dashboard manifest injected (legacy path).")
					elseif remaining > 0 then
						hs.timer.doAfter(0.15, function() try_inject(remaining - 1) end)
					else
						Logger.error(LOG, "load_and_inject(): bootstrapMetricsAppsData not available.")
					end
				end)
			elseif remaining > 0 then
				hs.timer.doAfter(0.15, function() try_inject(remaining - 1) end)
			else
				Logger.error(LOG, "load_and_inject(): apps dashboard JS not available.")
			end
		end)
	end
	try_inject(60)
end

function M.show(log_dir)
	if M._wv then
		Logger.debug(LOG, "Dashboard already open, bringing to front…")
		ui_builder.force_focus(M._wv)
		return
	end

	Logger.start(LOG, "Opening apps time dashboard…")

	-- Create webview FIRST with zero disk I/O so the window appears instantly.
	-- All migration / decrypt / SQL work is deferred to load_and_inject() once
	-- the window is on screen and the raise sequence has settled.
	local sf    = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = "Temps sur les applications",
		style_masks = 15,
		assets_dir  = hs.configdir .. "/ui/metrics_apps/",
		on_close    = function()
			M._wv = nil
			-- Keep hist_manifest_cache: it is valid for the rest of the day.
			Logger.info(LOG, "Apps time dashboard closed.")
		end
	})

	raise_now(M._wv, true)
	hs.timer.doAfter(0.05, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.15, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.35, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.70, function() raise_now(M._wv, false) end)

	-- Defer all data work so the empty shell appears before openssl blocks.
	hs.timer.doAfter(0.10, function() load_and_inject(log_dir) end)

	Logger.success(LOG, "Apps time dashboard window opened (data loading…).")
end

--- Broadcasts real-time manifest events to the webview UI.
--- @param live_manifest table The live manifest state.
function M.push_live_update(live_manifest)
	if M._wv then
		local js = string.format("if(window.receive_live_update) window.receive_live_update(%s);", json.encode(live_manifest))
		pcall(function() M._wv:evaluateJavaScript(js) end)
	end
end

return M
