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

local LOG = "metrics_apps"

M._wv = nil
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
	local button, new_cat = hs.dialog.textPrompt("Catégorie", "Nouvelle catégorie pour " .. app_name .. " :", default_cat or "Général", "OK", "Annuler")
	if button == "OK" and new_cat ~= "" then
		local btn2, new_score_str = hs.dialog.textPrompt("Score", "Nouveau score pour " .. app_name .. " (de -2 à 2) :", tostring(default_score or 0), "OK", "Annuler")
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
				hs.dialog.alert("Erreur", "Le score doit être compris entre -2 et 2.", "OK")
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
			Logger.warn(LOG, "App picker module not found or unsupported.")
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
function M.show(log_dir)
	if M._wv then
		Logger.debug(LOG, "Dashboard already open, bringing to front…")
		ui_builder.force_focus(M._wv)
		return
	end

	Logger.debug(LOG, "Building apps time dashboard UI…")
	local sf = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	local manifest = {}
	local log_manager = require("modules.keylogger.log_manager")
	local enc_path = log_dir .. "/metrics.sqlite.enc"
	local pwd = log_manager.get_mac_serial():gsub("\"", "\\\"")

	-- Extract historical manifest data from encrypted database
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
	
	-- Merge any un-saved today manifest data gracefully
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

	-- Inject data files for synchronous JS loading
	local user_cats = load_categories()

	-- Build the full HTML with data injected inline — writing inside hs.configdir
	-- would trigger a Hammerspoon config reload and destroy the webview instantly
	local assets_dir = hs.configdir .. "/ui/metrics_apps/"
	local data_html  = ui_builder.build_injected_html(assets_dir)
	local data_script = string.format(
		"<script>window.ManifestData=%s;window.UserCategories=%s;</script>",
		json.encode(manifest),
		json.encode(user_cats)
	)
	-- Swap the external data.js reference with the inline version
	data_html = data_html:gsub('<script%s+src="data%.js"%s*></script>', data_script)

	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = "Temps sur les applications",
		style_masks = 15,
		html        = data_html,
		on_close    = function()
			M._wv = nil
			Logger.info(LOG, "Apps time dashboard closed.")
		end
	})
	Logger.info(LOG, "Apps time dashboard displayed successfully.")
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
