--- ui/menu/menu_about.lua

--- ==============================================================================
--- MODULE: Menu About / Update
--- DESCRIPTION:
--- Builds the "About / Update" sub-menu for the macOS menubar and implements
--- one-click self-update: detects the running .app path, downloads the GitHub
--- release asset, unzips it into a temp directory, replaces the .app bundle
--- atomically, and calls hs.reload() to restart the driver.
---
--- FEATURES & RATIONALE:
--- 1. One-click update: a single dynamic menu item handles check → download →
---    replace → reload with no intermediate dialogs.
--- 2. State machine: the item label reflects the current state (idle /
---    checking / update available / installing) so the user always knows
---    what is happening.
--- 3. No background polling: all network requests are user-initiated so the
---    driver never makes unexpected outbound calls.
--- 4. Channel-aware: the user can switch between "main" (stable releases) and
---    "dev" (pre-releases) and the choice is persisted in config.toml.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local i18n   = require("lib.i18n")
local LOG    = "menu_about"

M.DEFAULT_STATE = {
	update_channel = "main",
}




-- =====================================
-- =====================================
-- ======= 1/ Constants & helpers =======
-- =====================================
-- =====================================

local GH_OWNER      = "adrienm7"
local GH_REPO       = "ergopti"
local ASSET_NAME    = "ErgoptiPlus.app.zip"
local BUNDLED_ID    = "com.ergopti.app"

-- Module-level state for the update flow.
-- Shared across build() calls so the label stays consistent across menu rebuilds.
local _update_state   = "idle"   -- "idle" | "checking" | "available" | "installing"
local _cached_release = nil      -- { tag, notes, zip_url } or nil


--- Returns true when running from a local Hammerspoon config directory
--- (not from inside a bundled Ergopti.app).
--- @return boolean
local function is_local_source()
	local info = hs.processInfo
	if not info then return true end
	local bid = info.bundleID or ""
	return bid ~= BUNDLED_ID
end

--- Returns the current app version string.
--- @return string
local function current_version()
	if is_local_source() then return "local" end
	local info = hs.processInfo
	if info and info.version and info.version ~= "" then
		return info.version
	end
	return "local"
end

--- Returns the absolute path to the running .app bundle, or nil.
--- Used as the replace target during self-update.
--- @return string|nil
local function app_bundle_path()
	local info = hs.processInfo
	if not info then return nil end
	-- bundlePath is the canonical path to ErgoptiPlus.app
	local p = info.bundlePath
	if p and p ~= "" then return p end
	return nil
end

--- Builds the GitHub Releases API URL for the active channel.
--- @param channel string "main" or "dev"
--- @return string
local function api_url(channel)
	local base = string.format("https://api.github.com/repos/%s/%s/releases", GH_OWNER, GH_REPO)
	if channel == "dev" then
		return base .. "?per_page=1"
	end
	return base .. "/latest"
end

local function releases_page_url()
	return string.format("https://github.com/%s/%s/releases", GH_OWNER, GH_REPO)
end

--- Parses the tag_name from a GitHub release JSON string.
--- @param body string Raw JSON
--- @return string tag or ""
local function parse_tag(body)
	if not body or body == "" then return "" end
	return body:match('"tag_name"%s*:%s*"([^"]+)"') or ""
end

--- Parses the release notes body from a GitHub release JSON string.
--- @param body string Raw JSON
--- @return string notes or ""
local function parse_notes(body)
	if not body or body == "" then return "" end
	local raw = body:match('"body"%s*:%s*"(.-[^\\])"')
	if not raw then return "" end
	raw = raw:gsub("\\n", "\n"):gsub("\\r", ""):gsub('\\"', '"'):gsub("\\\\", "\\")
	return raw
end

--- Parses the browser_download_url for ASSET_NAME from a GitHub release JSON.
--- @param body string Raw JSON
--- @return string url or ""
local function parse_asset_url(body)
	if not body or body == "" then return "" end
	-- Walk the assets array looking for the matching name field followed by
	-- browser_download_url in the same object. Using a simple sequential scan
	-- instead of full JSON parsing — assets objects are small and flat.
	for obj in body:gmatch("%b{}") do
		local name = obj:match('"name"%s*:%s*"([^"]+)"')
		if name == ASSET_NAME then
			local url = obj:match('"browser_download_url"%s*:%s*"([^"]+)"')
			if url then return url end
		end
	end
	return ""
end




-- ================================
-- ================================
-- ======= 2/ Update flow ==========
-- ================================
-- ================================


--- Returns the localised label for the one-click update menu item.
--- @param update_menu_fn function Callback to rebuild the menubar item after state change.
--- @return string
local function get_update_menu_label()
	if _update_state == "checking" then
		return i18n.get("menu.about.update_checking")
	end
	if _update_state == "installing" then
		return i18n.get("menu.about.update_installing")
	end
	if _update_state == "available" and _cached_release then
		return i18n.get("menu.about.update_now"):gsub("{tag}", _cached_release.tag)
	end
	return i18n.get("menu.about.check_for_updates")
end

--- Downloads a URL to a local file path using hs.http.asyncGet.
--- Calls cb(ok, err_msg) when done.
--- @param url string
--- @param dest string Absolute file path
--- @param cb function
local function download_to_file(url, dest, cb)
	Logger.trace(LOG, "Downloading %s → %s…", url, dest)
	hs.http.asyncGet(url, { ["User-Agent"] = "ErgoptiPlus-Updater/1.0" }, function(status, body, _)
		if status ~= 200 or not body or #body == 0 then
			Logger.error(LOG, "Download failed: HTTP %d for %s.", status, url)
			cb(false, i18n.get("menu.about.update.network_error"))
			return
		end
		-- hs.http returns the body as a string; write it as raw bytes via hs.fs.
		local ok, err = hs.fs.mkdir(hs.fs.pathComponent(dest, "parentDirectory") or "/tmp")
		if not ok and err ~= "File exists" then
			Logger.warn(LOG, "mkdir failed (non-fatal): %s", tostring(err))
		end
		-- Write binary via io.open in "wb" mode — safe for .zip payloads.
		local fh, ferr = io.open(dest, "wb")
		if not fh then
			Logger.error(LOG, "Cannot open %s for writing: %s.", dest, tostring(ferr))
			cb(false, i18n.get("menu.about.update.install_error"))
			return
		end
		fh:write(body)
		fh:close()
		Logger.done(LOG, "Downloaded %d bytes to %s.", #body, dest)
		cb(true, nil)
	end)
end

--- Replaces the running .app bundle with the newly downloaded one.
--- Steps: unzip into temp dir, validate, move old aside, move new in place, reload.
--- All filesystem operations run in a coroutine-friendly hs.task so the event
--- loop is not blocked during the copy.
--- @param zip_path string Path to the downloaded ErgoptiPlus.app.zip
--- @param update_menu_fn function Rebuild callback
local function replace_and_reload(zip_path, update_menu_fn)
	local target = app_bundle_path()
	if not target then
		Logger.error(LOG, "Cannot determine .app bundle path — aborting install.")
		hs.dialog.alert(nil, i18n.get("menu.about.update.install_error"), "OK", "Warning")
		_update_state = "idle"
		update_menu_fn()
		return
	end

	local tmp_dir    = os.tmpname():gsub("[^/]+$", "ergopti_update_" .. os.time())
	local new_app    = tmp_dir .. "/" .. "ErgoptiPlus.app"
	local backup_app = target .. ".bak"

	Logger.start(LOG, "Installing update: unzip %s → %s…", zip_path, tmp_dir)

	-- Unzip is a blocking shell call; run it via hs.task so we don't freeze the
	-- menubar. The callback fires on the main thread when the task exits.
	local task = hs.task.new("/usr/bin/unzip", function(exit_code, _, stderr)
		if exit_code ~= 0 then
			Logger.error(LOG, "unzip failed (exit %d): %s.", exit_code, stderr or "")
			hs.dialog.alert(nil, i18n.get("menu.about.update.install_error"), "OK", "Warning")
			_update_state = "idle"
			update_menu_fn()
			return
		end

		-- Validate: the expected .app must exist in the unzip destination.
		local ok_attr = hs.fs.attributes(new_app)
		if not ok_attr then
			Logger.error(LOG, "Unzipped archive does not contain ErgoptiPlus.app at %s.", new_app)
			hs.dialog.alert(nil, i18n.get("menu.about.update.install_error"), "OK", "Warning")
			_update_state = "idle"
			update_menu_fn()
			return
		end

		-- Atomic swap: rename current → .bak, rename new → current location.
		-- On APFS (same volume) rename is atomic. Cross-volume falls back to copy.
		local ok_bak = os.rename(target, backup_app)
		if not ok_bak then
			Logger.error(LOG, "Could not move current .app to backup at %s.", backup_app)
			hs.dialog.alert(nil, i18n.get("menu.about.update.install_error"), "OK", "Warning")
			_update_state = "idle"
			update_menu_fn()
			return
		end
		local ok_mv = os.rename(new_app, target)
		if not ok_mv then
			-- Attempt to restore from backup before bailing.
			os.rename(backup_app, target)
			Logger.error(LOG, "Could not move new .app to %s — restored backup.", target)
			hs.dialog.alert(nil, i18n.get("menu.about.update.install_error"), "OK", "Warning")
			_update_state = "idle"
			update_menu_fn()
			return
		end

		-- Remove the now-redundant backup and temp files (best-effort).
		os.remove(zip_path)
		hs.task.new("/bin/rm", nil, { "-rf", backup_app, tmp_dir }):start()

		Logger.success(LOG, "Update installed at %s — reloading.", target)
		_update_state = "idle"
		_cached_release = nil
		-- Short delay lets the log flush before hs.reload tears everything down.
		hs.timer.doAfter(0.3, function() hs.reload() end)
	end, { "-o", zip_path, "-d", tmp_dir })

	task:start()
end

--- One-click update entry point.
--- idle      → check GitHub, cache if newer, then install
--- available → install from cache immediately
--- checking/installing → no-op (item is disabled in the menu)
--- @param channel string
--- @param update_menu_fn function Rebuild callback to refresh the label
local function one_click_update(channel, update_menu_fn)
	if is_local_source() then return end
	if _update_state == "checking" or _update_state == "installing" then return end

	-- Fast path: update already cached.
	if _update_state == "available" and _cached_release then
		_update_state = "installing"
		update_menu_fn()
		Logger.start(LOG, "Installing cached update %s…", _cached_release.tag)
		local zip_path = os.tmpname() .. "_ErgoptiPlus.app.zip"
		download_to_file(_cached_release.zip_url, zip_path, function(ok, err)
			if not ok then
				hs.dialog.alert(nil, err, "OK", "Warning")
				_update_state = "available"
				update_menu_fn()
				return
			end
			replace_and_reload(zip_path, update_menu_fn)
		end)
		return
	end

	-- Slow path: check first.
	_update_state = "checking"
	update_menu_fn()
	local current = current_version()
	Logger.start(LOG, "One-click update check (channel: %s, current: %s)…", channel, current)

	hs.http.asyncGet(api_url(channel), { ["User-Agent"] = "ErgoptiPlus-Updater/1.0" }, function(status, body, _)
		if status ~= 200 or not body then
			Logger.warn(LOG, "One-click check: network unreachable (HTTP %d).", status)
			_update_state = "idle"
			update_menu_fn()
			hs.dialog.alert(nil, i18n.get("menu.about.update.network_error"), "OK", "Warning")
			return
		end
		local latest = parse_tag(body)
		if latest == "" then
			Logger.warn(LOG, "One-click check: tag parse failed.")
			_update_state = "idle"
			update_menu_fn()
			hs.dialog.alert(nil, i18n.get("menu.about.update.parse_error"), "OK", "Warning")
			return
		end
		if latest == current then
			Logger.info(LOG, "One-click check: already up to date (%s).", current)
			_update_state = "idle"
			update_menu_fn()
			local msg = i18n.get("menu.about.update.up_to_date"):gsub("{version}", current)
			hs.dialog.alert(nil, msg, "OK", "Informational")
			return
		end

		local zip_url = parse_asset_url(body)
		if zip_url == "" then
			Logger.error(LOG, "One-click check: asset '%s' not found in release %s.", ASSET_NAME, latest)
			_update_state = "idle"
			update_menu_fn()
			hs.dialog.alert(nil, i18n.get("menu.about.update.no_asset"), "OK", "Warning")
			return
		end

		Logger.success(LOG, "New version %s found, starting install…", latest)
		_cached_release = { tag = latest, notes = parse_notes(body), zip_url = zip_url }
		_update_state = "installing"
		update_menu_fn()

		local zip_path = os.tmpname() .. "_ErgoptiPlus.app.zip"
		download_to_file(zip_url, zip_path, function(ok, err)
			if not ok then
				hs.dialog.alert(nil, err, "OK", "Warning")
				_update_state = "available"
				update_menu_fn()
				return
			end
			replace_and_reload(zip_path, update_menu_fn)
		end)
	end)
end

--- Fetches and shows the release notes for the latest release on the active channel.
--- @param channel string "main" or "dev"
local function show_changelog(channel)
	local url = api_url(channel)
	hs.http.asyncGet(url, { ["User-Agent"] = "ErgoptiPlus-Updater/1.0" }, function(status, body, _)
		if status ~= 200 or not body then
			hs.dialog.alert(nil, i18n.get("menu.about.update.network_error"), "OK", "Warning")
			return
		end
		local tag   = parse_tag(body)
		local notes = parse_notes(body)
		if tag == "" then
			hs.dialog.alert(nil, i18n.get("menu.about.update.changelog_error"), "OK", "Warning")
			return
		end
		if notes == "" then notes = "(No release notes available for this version.)" end
		if #notes > 2000 then notes = notes:sub(1, 2000) .. "\n…(truncated)" end
		local msg = i18n.get("menu.about.update.changelog_header")
			:gsub("{tag}",   tag)
			:gsub("{notes}", notes)
		local open_label = i18n.get("menu.about.open_releases_page")
		local btn = hs.dialog.alert(nil, msg, open_label, "Dismiss", "Informational")
		if btn == open_label then
			hs.urlevent.openURL(releases_page_url())
		end
	end)
end




-- ================================
-- ================================
-- ======= 3/ Menu builder =========
-- ================================
-- ================================

--- Builds the About / Update sub-menu item.
--- @param ctx table Menu context (must contain ctx.state.update_channel and ctx.save_prefs).
--- @return table Menu item table for insertion into the parent menu.
function M.build(ctx)
	local state   = ctx and ctx.state or {}
	local channel = (type(state.update_channel) == "string" and state.update_channel ~= "")
		and state.update_channel or "main"
	local ver     = current_version()
	local ver_label = i18n.get("menu.about.title")

	local function set_channel(c)
		state.update_channel = c
		if type(ctx.save_prefs) == "function" then ctx.save_prefs() end
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	-- Callback passed to the update flow so it can trigger a menu rebuild when
	-- the state machine transitions (checking → available → installing → idle).
	local function update_menu_fn()
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	local local_src = is_local_source()
	-- Channel items: shown and selectable only for release builds.
	-- In local-source mode the version label already signals "local", so no extra channel item is needed.
	local channel_items
	local channel_display
	if local_src then
		channel_items   = {}
		channel_display = nil
	else
		channel_display = (channel == "dev")
			and i18n.get("menu.about.channel_dev")
			or  i18n.get("menu.about.channel_main")
		channel_items = {
			{
				title   = i18n.get("menu.about.channel_main"),
				checked = (channel == "main") or nil,
				fn      = function() set_channel("main") end,
			},
			{
				title   = i18n.get("menu.about.channel_dev"),
				checked = (channel == "dev") or nil,
				fn      = function() set_channel("dev") end,
			},
		}
	end

	-- Changelog uses "main" when running from source (no installed version).
	local effective_channel = local_src and "main" or channel

	local menu_items = {}
	table.insert(menu_items, { title = ver_label, disabled = true })
	if #channel_items > 0 then
		table.insert(menu_items, { title = "-" })
		-- Show the active channel value in the submenu title so the user can see
		-- the current setting without having to open it — mirrors AHK behaviour.
		local channel_title = i18n.get("menu.about.channel_menu") .. ": " .. (channel_display or "")
		table.insert(menu_items, { title = channel_title, menu = channel_items })
	end

	if not local_src then
		-- Dynamic one-click update item: label and enabled state reflect _update_state.
		-- Kept in the same group as the channel selector (no separator between them)
		-- so all update-related controls are visually grouped.
		local is_busy = (_update_state == "checking" or _update_state == "installing")
		table.insert(menu_items, {
			title    = get_update_menu_label(),
			disabled = is_busy or nil,
			fn       = not is_busy and function()
				Logger.info(LOG, "User triggered one-click update (channel: %s).", effective_channel)
				one_click_update(effective_channel, update_menu_fn)
			end or nil,
		})
	end
	table.insert(menu_items, { title = "-" })

	table.insert(menu_items, {
		title = i18n.get("menu.about.changelog"),
		fn    = function()
			Logger.info(LOG, "User opened changelog (channel: %s).", effective_channel)
			show_changelog(effective_channel)
		end,
	})
	table.insert(menu_items, {
		title = i18n.get("menu.about.open_releases_page"),
		fn    = function() hs.urlevent.openURL(releases_page_url()) end,
	})

	return { title = ver_label, menu = menu_items }
end

return M
