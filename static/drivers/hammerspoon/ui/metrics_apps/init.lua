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
M._app_icon_cache      = {}    -- app_name → base64 data URL (or false when not found)

local MAX_ICON_LOOKUPS_PER_OPEN = 30

local CONFIG_DIR = hs.configdir .. "/data"
local CATEGORIES_FILE = CONFIG_DIR .. "/app_categories.json"

-- On-disk snapshot of the last successful render — used to pre-fill the
-- dashboard with last-known values within milliseconds of opening, even
-- after a Hammerspoon reload.  Stale values are acceptable per UX spec:
-- the background refresh overwrites them once the openssl decrypt finishes.
-- Lives in $TMPDIR (per-user macOS temp dir, falling back to /tmp) so the
-- cache stays outside the versioned ~/.hammerspoon tree.
local UI_TMP_DIR    = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/")
local UI_CACHE_FILE = UI_TMP_DIR .. "ergopti_metrics_apps_cache.json"





-- =============================================
-- =============================================
-- ======= 1/ App Icon Helpers =================
-- =============================================
-- =============================================

--- Extracts the app icon as a base64 data URL from the running app bundle.
--- Falls back to a path-based lookup for apps not currently running.
--- @param app_name string The application name as tracked in the manifest.
--- @return string|nil Base64 data URL, or nil when the icon cannot be found.
local function get_app_icon(app_name)
	local app = hs.application.find(app_name)
	if app and type(app.bundleID) == "function" then
		local bid = app:bundleID()
		if bid then
			local ok, img = pcall(hs.image.imageFromAppBundle, bid)
			if ok and img then
				pcall(function() img:setSize({ w = 64, h = 64 }) end)
				local ok2, encoded = pcall(function() return img:encodeAsURLString() end)
				if ok2 and encoded then return encoded end
			end
		end
	end
	return nil
end




-- =======================================
-- =======================================
-- ======= 3/ JSON Data Management =======
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
-- ======= 4/ User Interaction =======
-- ===================================
-- ===================================

--- Pushes the latest categories JSON to the WebView so the UI reflects changes.
local function push_categories_to_ui()
	if not M._wv then return end
	local cats = load_categories()
	Logger.debug(LOG, "Pushing updated JSON categories to Webview…")
	M._wv:evaluateJavaScript(string.format("window.updateUserCategories(%s);", json.encode(cats)))
end

--- Builds the sorted list of unique category names currently in use.
--- @return table List of category name strings, sorted alphabetically.
local function list_existing_categories()
	local cats   = load_categories()
	local seen   = { ["Général"] = true }
	local result = { "Général" }
	for _, entry in pairs(cats) do
		local t = type(entry) == "table" and entry.type or nil
		if type(t) == "string" and t ~= "" and not seen[t] then
			seen[t] = true
			table.insert(result, t)
		end
	end
	table.sort(result, function(a, b) return a:lower() < b:lower() end)
	return result
end

--- Prompts the user for a productivity score (-2..2) for the given app.
--- @param app_name string The application name being classified.
--- @param chosen_cat string The category name already chosen.
--- @param default_score number The default score to pre-fill.
local function prompt_score_then_save(app_name, chosen_cat, default_score)
	local btn, score_str = dialog.text_prompt(
		"Score",
		"Score de productivité pour " .. app_name .. "\n(-2 très distrayant à 2 très productif) :",
		tostring(default_score or 0), "OK", "Annuler"
	)
	if btn ~= "OK" then return end
	local score = tonumber(score_str)
	if not score or score < -2 or score > 2 then
		dialog.alert("Erreur", "Le score doit être compris entre -2 et 2.", "OK")
		return
	end
	local cats = load_categories()
	cats[app_name] = { type = chosen_cat, score = score }
	save_categories(cats)
	push_categories_to_ui()
end

--- Opens a chooser listing existing categories with options to add a new one
--- or rename an existing one. Selecting a category proceeds to the score prompt.
--- @param app_name string The name of the application.
--- @param default_cat string The default category to pre-select.
--- @param default_score number The default score to pre-fill.
function M.prompt_category(app_name, default_cat, default_score)
	local existing = list_existing_categories()
	local choices  = {}

	table.insert(choices, {
		text    = "+ Nouvelle catégorie…",
		subText = "Créer une catégorie inédite",
		_kind   = "new",
	})
	table.insert(choices, {
		text    = "✎ Renommer une catégorie existante…",
		subText = "Toutes les apps de cette catégorie seront renommées",
		_kind   = "rename",
	})
	for _, cat in ipairs(existing) do
		local marker = (cat == default_cat) and "  ✓" or ""
		table.insert(choices, {
			text    = cat .. marker,
			subText = "Utiliser cette catégorie",
			_kind   = "pick",
			_value  = cat,
		})
	end

	local chooser
	chooser = hs.chooser.new(function(choice)
		if not choice then return end
		if choice._kind == "pick" then
			prompt_score_then_save(app_name, choice._value, default_score)
		elseif choice._kind == "new" then
			local btn, new_cat = dialog.text_prompt("Nouvelle catégorie", "Nom de la nouvelle catégorie pour " .. app_name .. " :", "", "OK", "Annuler")
			if btn == "OK" and new_cat and new_cat ~= "" then
				prompt_score_then_save(app_name, new_cat, default_score)
			end
		elseif choice._kind == "rename" then
			-- Sub-chooser to pick which category to rename
			local rename_choices = {}
			for _, cat in ipairs(existing) do
				table.insert(rename_choices, { text = cat, subText = "Renommer cette catégorie" })
			end
			local sub
			sub = hs.chooser.new(function(c2)
				if not c2 then return end
				local btn, new_name = dialog.text_prompt("Renommer", "Nouveau nom pour la catégorie « " .. c2.text .. " » :", c2.text, "OK", "Annuler")
				if btn == "OK" and new_name and new_name ~= "" and new_name ~= c2.text then
					local cats = load_categories()
					for app, entry in pairs(cats) do
						if type(entry) == "table" and entry.type == c2.text then
							entry.type = new_name
						end
					end
					save_categories(cats)
					push_categories_to_ui()
				end
			end)
			sub:placeholderText("Catégorie à renommer")
			sub:choices(rename_choices)
			sub:show()
		end
	end)
	chooser:placeholderText("Catégorie pour " .. app_name)
	chooser:choices(choices)
	chooser:show()
end

--- Opens a chooser listing all installed applications so the user can classify
--- any app, even ones that haven't been used yet.
local function prompt_pick_app()
	local ok_mod, app_picker = pcall(require, "lib.app_picker")
	if not ok_mod then
		Logger.error(LOG, "lib.app_picker module unavailable.")
		return
	end
	local choices = app_picker.discover_apps()
	if type(choices) ~= "table" or #choices == 0 then
		dialog.alert("Erreur", "Aucune application n'a pu être détectée.", "OK")
		return
	end
	local chooser
	chooser = hs.chooser.new(function(choice)
		if not choice then return end
		local cats    = load_categories()
		local current = cats[choice.text] or { type = "Général", score = 0 }
		M.prompt_category(choice.text, current.type, current.score)
	end)
	chooser:placeholderText("Choisir une application à classer…")
	chooser:choices(choices)
	chooser:searchSubText(true)
	chooser:show()
end

--- Handles JS bridge messages from the WebView (button clicks).
--- @param msg table The message object posted by the JS side.
local function handle_bridge_message(msg)
	if type(msg) ~= "table" then return end
	local body = msg.body
	if type(body) ~= "table" then return end

	local act = body.action
	if act == "edit" then
		local app_name = tostring(body.app or "")
		local cat      = tostring(body.cat or "Général")
		local score    = tonumber(body.score) or 0
		hs.timer.doAfter(0, function() M.prompt_category(app_name, cat, score) end)
	elseif act == "pick" then
		hs.timer.doAfter(0, prompt_pick_app)
	else
		Logger.warn(LOG, "Unknown bridge action received: %s", tostring(act))
	end
end





-- ===============================
-- ===============================
-- ======= 5/ UI Injection =======
-- ===============================
-- ===============================

--- Persists a snapshot of the data injected into the webview to disk so the
--- next open (even after HS reload) can render instantly from this cache.
--- @param payload table { manifest, user_cats } as JSON strings.
local function save_disk_cache(payload)
	-- TMPDIR always exists on macOS — no mkdir needed.
	local ok_enc, body = pcall(json.encode, payload)
	if not ok_enc then
		Logger.warn(LOG, "Failed to encode disk cache payload — skipping persist.")
		return
	end
	local f = io.open(UI_CACHE_FILE, "w")
	if f then
		f:write(body)
		f:close()
		Logger.debug(LOG, "Apps dashboard snapshot persisted to disk cache.")
	else
		Logger.warn(LOG, "Cannot open '%s' for writing — disk cache not persisted.", UI_CACHE_FILE)
	end
end

--- Reads the previously-saved disk cache snapshot.
--- @return table|nil Snapshot with manifest/user_cats JSON strings.
local function load_disk_cache()
	local f = io.open(UI_CACHE_FILE, "r")
	if not f then return nil end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(json.decode, content)
	if not ok or type(data) ~= "table" then return nil end
	return data
end

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

	local user_cats = load_categories()

	-- Collect app icons (base64 data URLs) for apps that appear in the manifest.
	-- Capped to avoid slow startup when many apps are present.
	local app_icons    = {}
	local icon_lookups = 0
	local seen_apps    = {}
	for _, day_data in pairs(manifest) do
		for app_name, _ in pairs(day_data) do
			if not seen_apps[app_name] then
				seen_apps[app_name] = true
				local cached = M._app_icon_cache[app_name]
				if cached ~= nil then
					app_icons[app_name] = cached or nil
				elseif icon_lookups < MAX_ICON_LOOKUPS_PER_OPEN then
					local icon = get_app_icon(app_name)
					M._app_icon_cache[app_name] = icon or false
					if icon then app_icons[app_name] = icon end
					icon_lookups = icon_lookups + 1
				end
			end
		end
	end
	local icon_count = 0
	for _ in pairs(app_icons) do icon_count = icon_count + 1 end
	Logger.debug(LOG, "App icons collected: %d icon(s), %d lookup(s).", icon_count, icon_lookups)

	local manifest_json   = json.encode(manifest)
	local user_cats_json  = json.encode(user_cats)
	local app_icons_json  = json.encode(app_icons)

	-- Persist the freshly-built snapshot so the next open (even after HS
	-- reload) renders instantly from disk.
	save_disk_cache({ manifest = manifest_json, user_cats = user_cats_json, app_icons = app_icons_json })

	-- Retry injection loop — robust against slow CDN loads.
	local function try_inject(remaining)
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.bootstrapMetricsAppsData", function(t)
			if t == "function" then
				local js = string.format("window.bootstrapMetricsAppsData(%s,%s,%s);", manifest_json, user_cats_json, app_icons_json)
				pcall(function() M._wv:evaluateJavaScript(js) end)
				Logger.success(LOG, "Apps dashboard manifest injected.")
			elseif t == "undefined" then
				M._wv:evaluateJavaScript("typeof window.initDashboard", function(t2)
					if t2 == "function" then
						local js = string.format("window.ManifestData=%s;window.UserCategories=%s;window.AppIcons=%s;window.initDashboard();", manifest_json, user_cats_json, app_icons_json)
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

--- Pre-fills the dashboard with the on-disk snapshot from the previous run
--- so the user sees populated values within milliseconds of opening.  The
--- caller delays the background refresh slightly so JS finishes parsing
--- the cached payload before the fresh values overwrite it.
--- @return boolean True if a cache existed and pre-fill was scheduled.
local function prefill_from_disk_cache()
	if not M._wv then return false end
	local cached = load_disk_cache()
	if not cached or type(cached.manifest) ~= "string" then
		Logger.debug(LOG, "No disk cache available — UI will fill from fresh decrypt.")
		return false
	end
	local icons_json = cached.app_icons or "{}"
	local function try_inject_cache(remaining)
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.bootstrapMetricsAppsData", function(t)
			if t == "function" then
				local js = string.format(
					"window.bootstrapMetricsAppsData(%s,%s,%s);",
					cached.manifest, cached.user_cats or "{}", icons_json
				)
				pcall(function() M._wv:evaluateJavaScript(js) end)
				Logger.success(LOG, "Apps dashboard pre-filled from disk cache.")
			elseif t == "undefined" then
				M._wv:evaluateJavaScript("typeof window.initDashboard", function(t2)
					if t2 == "function" then
						local js = string.format(
							"window.ManifestData=%s;window.UserCategories=%s;window.AppIcons=%s;window.initDashboard();",
							cached.manifest, cached.user_cats or "{}", icons_json
						)
						pcall(function() M._wv:evaluateJavaScript(js) end)
						Logger.success(LOG, "Apps dashboard pre-filled from disk cache (legacy).")
					elseif remaining > 0 then
						hs.timer.doAfter(0.10, function() try_inject_cache(remaining - 1) end)
					end
				end)
			elseif remaining > 0 then
				hs.timer.doAfter(0.10, function() try_inject_cache(remaining - 1) end)
			end
		end)
	end
	try_inject_cache(50)
	return true
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

	-- JS↔Lua bridge: usercontent message handler is the only reliable way to
	-- dispatch UI actions (custom URL schemes navigate the WebView away).
	local ucc = hs.webview.usercontent.new("metrics_apps_bridge")
	ucc:setCallback(handle_bridge_message)

	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = "Temps sur les applications",
		style_masks = 15,
		assets_dir  = hs.configdir .. "/ui/metrics_apps/",
		usercontent = ucc,
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

	-- Two-stage data fill (see metrics_typing for full rationale):
	--   1. Pre-fill from on-disk snapshot — populated values appear within a frame.
	--   2. Refresh from fresh decrypt+SQL in the background and overwrite.
	hs.timer.doAfter(0.05, function()
		local had_cache = prefill_from_disk_cache()
		local refresh_delay = had_cache and 0.40 or 0.05
		hs.timer.doAfter(refresh_delay, function() load_and_inject(log_dir) end)
	end)

	Logger.success(LOG, "Apps time dashboard window opened (cache pre-fill + background refresh).")
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
