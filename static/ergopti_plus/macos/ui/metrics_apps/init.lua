--- ui/metrics_apps/init.lua

--- ==============================================================================
--- MODULE: Apps Time Dashboard UI
--- DESCRIPTION:
--- Hosts the WebView for the per-app time dashboard. Reads from the new
--- `db.sqlite` cache via `modules.keylogger.sqlite_reader` and projects the
--- result into the JSON shape consumed by the (unchanged) frontend JS.
---
--- FEATURES & RATIONALE:
--- 1. SQLite-only data path: no openssl decrypt, no manifest.json, no
---    encrypted SQLite — every value originates from `db.sqlite`, which is
---    rebuildable from `data.sql` (canonical text source of truth).
--- 2. Cross-device aggregation: the projection sums by (date, app) across
---    every row in `devices`, so the UI shows a single global stat.
--- 3. Two-stage paint: the dashboard pre-fills from a disk-cached snapshot
---    within milliseconds; the SQLite read runs in the background and
---    overwrites the cache once ready.
--- 4. Format-stable: emits the legacy manifest shape so the frontend JS
---    keeps working without rewrite.
--- ==============================================================================

local M = {}

local hs         = hs
local fs         = require("hs.fs")
local json       = require("hs.json")
local ui_builder = require("ui.ui_builder")
local Logger     = require("lib.logger")
local dialog     = require("lib.dialog_util")
local i18n       = require("lib.i18n")

local LOG = "metrics_apps"

M._wv             = nil
M._app_icon_cache = {}

--- Cached projection — invalidated when the SQLite `meta.rev` advances.
M._manifest_cache  = nil
M._manifest_rev    = -1




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

local MAX_ICON_LOOKUPS_PER_OPEN = 30

local CONFIG_DIR      = hs.configdir .. "/data"
local CATEGORIES_FILE = CONFIG_DIR .. "/app_categories.json"

--- On-disk snapshot of the last successful render (instant pre-fill).
local UI_TMP_DIR    = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/")
local UI_CACHE_FILE = UI_TMP_DIR .. "ergopti_metrics_apps_cache.json"




-- ===============================
--- ============================
-- ======= 1/ App Icons =======
--- ============================
-- ===============================

--- Resolve a base64 data URL for an app's icon, or nil when unavailable.
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




-- ============================================
--- ==========================================
-- ======= 2/ User category overrides =======
--- ==========================================
-- ============================================

local function load_categories()
	local f = io.open(CATEGORIES_FILE, "r")
	if f then
		local content = f:read("*a"); f:close()
		local ok, data = pcall(json.decode, content)
		if ok and type(data) == "table" then return data end
	end
	return {}
end

local function save_categories(data)
	os.execute(string.format("mkdir -p %q", CONFIG_DIR))
	local f = io.open(CATEGORIES_FILE, "w")
	if f then f:write(json.encode(data)); f:close() end
end

local function push_categories_to_ui()
	if not M._wv then return end
	M._wv:evaluateJavaScript(string.format(
		"window.updateUserCategories(%s);", json.encode(load_categories())))
end

local function list_existing_categories()
	local cats = load_categories()
	local general = i18n.get("metrics_apps.general_category")
	local seen = { [general] = true }
	local result = { general }
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

local function prompt_score_then_save(app_name, chosen_cat, default_score)
	local btn, score_str = dialog.text_prompt(
		i18n.get("metrics_apps.score_title"),
		string.format(i18n.get("metrics_apps.score_prompt"), app_name),
		tostring(default_score or 0), i18n.get("button.ok"), i18n.get("common.cancel"))
	if btn ~= i18n.get("button.ok") then return end
	local score = tonumber(score_str)
	if not score or score < -2 or score > 2 then
		dialog.alert(i18n.get("common.warning"), i18n.get("metrics_apps.score_error"), i18n.get("button.ok"))
		return
	end
	local cats = load_categories()
	cats[app_name] = { type = chosen_cat, score = score }
	save_categories(cats)
	push_categories_to_ui()
end

function M.prompt_category(app_name, default_cat, default_score)
	local existing = list_existing_categories()
	local choices  = {}

	table.insert(choices, { text = i18n.get("metrics_apps.new_category_item"), subText = i18n.get("metrics_apps.new_category_create_subtext"), _kind = "new" })
	table.insert(choices, { text = i18n.get("metrics_apps.rename_item"), subText = i18n.get("metrics_apps.rename_subtext"), _kind = "rename" })
	for _, cat in ipairs(existing) do
		local marker = (cat == default_cat) and "  ✓" or ""
		table.insert(choices, { text = cat .. marker, subText = i18n.get("metrics_apps.use_category_subtext"), _kind = "pick", _value = cat })
	end

	local chooser
	chooser = hs.chooser.new(function(choice)
		if not choice then return end
		if choice._kind == "pick" then
			prompt_score_then_save(app_name, choice._value, default_score)
		elseif choice._kind == "new" then
			local btn, new_cat = dialog.text_prompt(i18n.get("metrics_apps.new_category_title"),
				string.format(i18n.get("metrics_apps.new_category_prompt"), app_name),
				"", i18n.get("button.ok"), i18n.get("common.cancel"))
			if btn == i18n.get("button.ok") and new_cat and new_cat ~= "" then
				prompt_score_then_save(app_name, new_cat, default_score)
			end
		elseif choice._kind == "rename" then
			local rename_choices = {}
			for _, cat in ipairs(existing) do
				table.insert(rename_choices, { text = cat, subText = i18n.get("metrics_apps.rename_title") })
			end
			local sub
			sub = hs.chooser.new(function(c2)
				if not c2 then return end
				local btn, new_name = dialog.text_prompt(i18n.get("metrics_apps.rename_title"),
					string.format(i18n.get("metrics_apps.rename_prompt"), c2.text),
					c2.text, i18n.get("button.ok"), i18n.get("common.cancel"))
				if btn == i18n.get("button.ok") and new_name and new_name ~= "" and new_name ~= c2.text then
					local cats = load_categories()
					for _, entry in pairs(cats) do
						if type(entry) == "table" and entry.type == c2.text then
							entry.type = new_name
						end
					end
					save_categories(cats)
					push_categories_to_ui()
				end
			end)
			sub:placeholderText(i18n.get("metrics_apps.rename_chooser_placeholder"))
			sub:choices(rename_choices)
			sub:show()
		end
	end)
	chooser:placeholderText(string.format(i18n.get("metrics_apps.chooser_placeholder"), app_name))
	chooser:choices(choices)
	chooser:show()
end

local function prompt_pick_app()
	local ok_mod, app_picker = pcall(require, "lib.app_picker")
	if not ok_mod then
		Logger.error(LOG, "lib.app_picker module unavailable.")
		return
	end
	local choices = app_picker.discover_apps()
	if type(choices) ~= "table" or #choices == 0 then
		dialog.alert(i18n.get("common.warning"), i18n.get("metrics_apps.no_app_detected"), i18n.get("button.ok"))
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
		Logger.warn(LOG, "Unknown bridge action received: %s.", tostring(act))
	end
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




-- =================================
--- ===============================
-- ======= 4/ Data refresh =======
--- ===============================
-- =================================

--- Read the current manifest from db.sqlite and inject it into the WebView.
--- Cached on `meta.rev` so consecutive opens within the same revision skip
--- the SQL pass entirely.
local function load_and_inject()
	if not M._wv then return end

	local log_manager   = require("modules.keylogger.log_manager")
	local sqlite_reader = require("modules.keylogger.sqlite_reader")
	local sqlite_path   = log_manager.get_sqlite_path()
	if not sqlite_path or not fs.attributes(sqlite_path) then
		Logger.warn(LOG, "db.sqlite not available — dashboard will display empty.")
		return
	end

	local rev = log_manager.get_db_rev()
	local manifest
	if M._manifest_cache and M._manifest_rev == rev then
		Logger.done(LOG, "Manifest cache hit (rev %d).", rev)
		manifest = M._manifest_cache
	else
		Logger.trace(LOG, "Manifest cache miss (rev %d) — querying SQLite…", rev)
		manifest = sqlite_reader.read_manifest(sqlite_path)
		M._manifest_cache = manifest
		M._manifest_rev   = rev
		Logger.done(LOG, "Manifest cached (rev %d).", rev)
	end
	if not M._wv then return end

	local user_cats = load_categories()

	-- App icon collection (capped to keep first paint fast).
	local app_icons    = {}
	local icon_lookups = 0
	local seen_apps    = {}
	for _, day_data in pairs(manifest) do
		for app_name, _ in pairs(day_data) do
			if not seen_apps[app_name] then
				seen_apps[app_name] = true
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

	local manifest_json  = json.encode(manifest)
	local user_cats_json = json.encode(user_cats)
	local app_icons_json = json.encode(app_icons)

	save_disk_cache({ manifest = manifest_json, user_cats = user_cats_json, app_icons = app_icons_json })

	local function try_inject(remaining)
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.bootstrapMetricsAppsData", function(t)
			if t == "function" then
				local js = string.format("window.bootstrapMetricsAppsData(%s,%s,%s);",
					manifest_json, user_cats_json, app_icons_json)
				pcall(function() M._wv:evaluateJavaScript(js) end)
				Logger.success(LOG, "Apps dashboard manifest injected.")
			elseif t == "undefined" then
				M._wv:evaluateJavaScript("typeof window.initDashboard", function(t2)
					if t2 == "function" then
						local js = string.format(
							"window.ManifestData=%s;window.UserCategories=%s;window.AppIcons=%s;window.initDashboard();",
							manifest_json, user_cats_json, app_icons_json)
						pcall(function() M._wv:evaluateJavaScript(js) end)
						Logger.success(LOG, "Apps dashboard manifest injected (legacy path).")
					elseif remaining > 0 then
						hs.timer.doAfter(0.15, function() try_inject(remaining - 1) end)
					else
						Logger.error(LOG, "load_and_inject(): bootstrap not available.")
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

local function prefill_from_disk_cache()
	if not M._wv then return false end
	local cached = load_disk_cache()
	if not cached or type(cached.manifest) ~= "string" then return false end
	local icons_json = cached.app_icons or "{}"
	local function try_inject_cache(remaining)
		if not M._wv then return end
		M._wv:evaluateJavaScript("typeof window.bootstrapMetricsAppsData", function(t)
			if t == "function" then
				local js = string.format("window.bootstrapMetricsAppsData(%s,%s,%s);",
					cached.manifest, cached.user_cats or "{}", icons_json)
				pcall(function() M._wv:evaluateJavaScript(js) end)
				Logger.success(LOG, "Apps dashboard pre-filled from disk cache.")
			elseif t == "undefined" then
				M._wv:evaluateJavaScript("typeof window.initDashboard", function(t2)
					if t2 == "function" then
						local js = string.format(
							"window.ManifestData=%s;window.UserCategories=%s;window.AppIcons=%s;window.initDashboard();",
							cached.manifest, cached.user_cats or "{}", icons_json)
						pcall(function() M._wv:evaluateJavaScript(js) end)
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




-- =====================================
--- =============================
-- ======= 5/ Public API =======
--- =============================
-- =====================================

function M.show()
	if M._wv then
		Logger.debug(LOG, "Dashboard already open, bringing to front…")
		ui_builder.force_focus(M._wv)
		return
	end

	Logger.start(LOG, "Opening apps time dashboard…")

	local sf    = hs.screen.mainScreen():frame()
	local frame = { x = sf.x + 50, y = sf.y + 50, w = sf.w - 100, h = sf.h - 100 }

	local assets_dir = resolve_ui_assets_dir("metrics_apps")
	if not assets_dir then
		Logger.error(LOG, "Cannot open dashboard — shared UI assets not found.")
		return
	end

	local ucc = hs.webview.usercontent.new("metrics_apps_bridge")
	ucc:setCallback(handle_bridge_message)

	M._wv = ui_builder.show_webview({
		frame       = frame,
		title       = i18n.get("metrics_apps.window_title"),
		style_masks = 15,
		assets_dir  = assets_dir,
		usercontent = ucc,
		on_close    = function()
			M._wv = nil
			Logger.info(LOG, "Apps time dashboard closed.")
		end,
	})

	raise_now(M._wv, true)
	hs.timer.doAfter(0.05, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.15, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.35, function() raise_now(M._wv, true) end)
	hs.timer.doAfter(0.70, function() raise_now(M._wv, false) end)

	hs.timer.doAfter(0.05, function()
		local had_cache = prefill_from_disk_cache()
		local refresh_delay = had_cache and 0.40 or 0.05
		hs.timer.doAfter(refresh_delay, load_and_inject)
	end)

	Logger.success(LOG, "Apps time dashboard window opened.")
end

--- Live-refresh hook. Today's manifest entry is rebuilt on each ingest tick;
--- callers (kept for API compatibility) just trigger a fresh load.
function M.push_live_update(_unused)
	if M._wv then
		hs.timer.doAfter(0, load_and_inject)
	end
end

return M
