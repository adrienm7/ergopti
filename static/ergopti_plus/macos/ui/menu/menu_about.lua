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
--- 3. Background polling: optional periodic silent check (_shared/modules/updater/
---    constants.toml interval presets), surfaces a notification on new releases.
--- 4. Channel-aware: the user can switch between "main" (stable releases) and
---    "dev" (pre-releases) and the choice is persisted in config.toml.
--- ==============================================================================

local M = {}
local hs        = hs
local Logger    = require("infra.logger")
local text_utils = require("infra.text_utils")
local i18n      = require("infra.i18n")
local dialog    = require("infra.dialog_util")
local changelog = require("ui.changelog")
local Updater   = require("modules.updater")
local ManifestMenu = require("infra.manifest_menu")
local TaskLifecycle = require("adapters.task_lifecycle")
local Crypto    = require("adapters.crypto")
local LOG       = "menu_about"

-- GC-root table: every live hs.task is pinned here so Lua's garbage collector
-- cannot SIGTERM it mid-run (Hammerspoon GC pitfall: hs.task held only in a
-- local variable is collected once the enclosing function returns).
M._active_tasks = {}

-- Detect source vs bundled at module load time so DEFAULT_STATE carries the
-- right channel seed before preferences.lua hydrates the shared state table.
local _BUNDLED_ID = "com.ergopti.app"
local _is_local   = (function()
	local info = hs and hs.processInfo
	if not info then return true end
	return (info.bundleID or "") ~= _BUNDLED_ID
end)()

M.DEFAULT_STATE = {
	-- "dev" from source (all releases are pre-releases), "main" from bundled app.
	update_channel = _is_local and "dev" or "main",
	update_check_interval_seconds = Updater.get_check_interval(),
}





-- ======================================
-- ======================================
-- ======= 1/ Constants & helpers =======
-- ======================================
-- ======================================

local GH_OWNER      = "adrienm7"
local GH_REPO       = "ergopti"
local ASSET_NAME    = "ErgoptiPlus.app.zip"
local BUNDLED_ID    = "com.ergopti.app"

local function is_local_source()
	return Updater.is_local_source()
end

local function current_version()
	return Updater.current_version()
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

local function api_url(channel)
	return Updater.release_api_url(channel)
end

local function releases_page_url()
	return Updater.releases_page_url()
end

-- parse_tag, parse_notes, and parse_asset_url were previously duplicated
-- here as local functions. They are now delegated to the shared
-- release_parser module via Updater.parse_tag / Updater.parse_notes /
-- Updater.parse_asset_url — see _shared/lua/updater/release_parser.lua




-- ================================
-- ================================
-- ======= 2/ Update flow ==========
-- ================================
-- ================================


--- Returns the localised label for the one-click update menu item.
--- @param update_menu_fn function Callback to rebuild the menubar item after state change.
--- @return string
local function get_update_menu_label()
	return Updater.get_update_menu_label()
end

--- Downloads a validated release asset and verifies its SHA-256 before writing.
--- Calls cb(ok, err_msg) when done.
--- @param release table Validated release metadata.
--- @param dest string Absolute file path
--- @param cb function
local function download_to_file(release, dest, cb)
	local valid, validation_error = Updater.validate_install_asset(release)
	if valid ~= true then
		Logger.error(LOG, "Update download refused before dispatch — %s.", tostring(validation_error))
		cb(false, i18n.get("menu.about.update.install_error"))
		return
	end
	local url = release.zip_url
	local expected_digest = release.sha256
	Logger.trace(LOG, "Downloading %s → %s…", url, dest)
	hs.http.asyncGet(url, { ["User-Agent"] = "ErgoptiPlus-Updater/1.0" }, function(status, body, _)
		if status ~= 200 or not body or #body == 0 then
			Logger.error(LOG, "Download failed: HTTP %s for %s.", tostring(status), url)
			cb(false, i18n.get("menu.about.update.network_error"))
			return
		end
		local actual_digest = Crypto.sha256_bytes(body)
		if actual_digest == "" then
			Logger.error(LOG, "Downloaded update archive could not be hashed.")
			cb(false, i18n.get("menu.about.update.install_error"))
			return
		end
		if actual_digest ~= expected_digest then
			Logger.error(LOG, "Downloaded update archive failed SHA-256 verification.")
			cb(false, i18n.get("menu.about.update.install_error"))
			return
		end
		-- Write binary via io.open in "wb" mode — safe for .zip payloads.
		-- hs.fs.pathComponent(dest, "parentDirectory") does not exist in Hammerspoon's
		-- hs.fs — calling it would throw inside the asyncGet callback (swallowed to
		-- the HS Console), cb would never fire, and the update state machine would
		-- stay stuck at "installing" forever. The dest path is always inside the
		-- system temp dir which exists by definition, so no mkdir is needed.
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
		dialog.block_alert(i18n.get("common.error_title"), i18n.get("menu.about.update.install_error"), i18n.get("button.ok"))
		Updater.set_update_state("idle")
		update_menu_fn()
		return
	end

	-- os.tmpname() creates an orphaned /tmp/lua_XXXXXX file as a side effect.
	-- Use hs.fs.temporaryDirectory() to build the path without leaving a stray file.
	local tmp_dir    = (hs.fs.temporaryDirectory() or "/tmp") .. "ergopti_update_" .. os.time()
	local new_app    = tmp_dir .. "/" .. "ErgoptiPlus.app"
	local backup_app = target .. ".bak"

	Logger.start(LOG, "Installing update: unzip %s → %s…", zip_path, tmp_dir)

	-- Unzip is a blocking shell call; run it via hs.task so we don't freeze the
	-- menubar. The callback fires on the main thread when the task exits.
	-- The task is pinned to M._active_tasks so the GC cannot SIGTERM it while
	-- it is still running (hs.task held only in a local is collected on return).
	-- Forward-declare the handle so the completion closure captures it as a real
	-- UPVALUE. `local task = hs.task.new(..., function() ... task ... end)` binds
	-- the NIL GLOBAL `task` inside the callback — Lua scopes the local only AFTER
	-- the full statement completes — so `M._active_tasks[task] = nil` raised
	-- "table index is nil" on the callback's first line, swallowed by
	-- Hammerspoon's hs.task pcall to the Console, wedging the update at
	-- "installing" forever (the project_lua_closure_before_local_nil_global class).
	local unzip_task
	unzip_task = TaskLifecycle.native("Update archive extraction", "/usr/bin/unzip", function(exit_code, _, stderr)
		if unzip_task then M._active_tasks[unzip_task] = nil end  -- guarded clear: never write a nil key
		if exit_code ~= 0 then
			Logger.error(LOG, "unzip failed (exit %d): %s.", exit_code, stderr or "")
			dialog.block_alert(i18n.get("common.error_title"), i18n.get("menu.about.update.install_error"), i18n.get("button.ok"))
			Updater.set_update_state("idle")
			update_menu_fn()
			return
		end

		-- Validate: the expected .app must exist in the unzip destination.
		local ok_attr = hs.fs.attributes(new_app)
		if not ok_attr then
			Logger.error(LOG, "Unzipped archive does not contain ErgoptiPlus.app at %s.", new_app)
			dialog.block_alert(i18n.get("common.error_title"), i18n.get("menu.about.update.install_error"), i18n.get("button.ok"))
			Updater.set_update_state("idle")
			update_menu_fn()
			return
		end

		-- Swap: rename current → .bak, rename new → current location. os.rename is
		-- rename(2): atomic on the SAME volume, but cross-volume it returns EXDEV
		-- with NO copy fallback. backup_app (target .. ".bak") lives in target's
		-- directory, so the restore below is always intra-volume; only new_app sits
		-- on the tmp volume, so only the new→target rename can fail cross-volume.
		local ok_bak = os.rename(target, backup_app)
		if not ok_bak then
			Logger.error(LOG, "Could not move current .app to backup at %s.", backup_app)
			dialog.block_alert(i18n.get("common.error_title"), i18n.get("menu.about.update.install_error"), i18n.get("button.ok"))
			Updater.set_update_state("idle")
			update_menu_fn()
			return
		end
		local ok_mv = os.rename(new_app, target)
		if not ok_mv then
			-- Restore from backup before bailing, and CHECK the result: an unchecked
			-- restore that silently failed would leave the running app only at .bak
			-- (target missing) while the log falsely claimed success.
			local ok_restore = os.rename(backup_app, target)
			if ok_restore then
				Logger.error(LOG, "Could not move new .app to %s — restored the previous version.", target)
			else
				Logger.error(LOG, "Could not move new .app to %s AND restore failed — the previous app is at %s.",
					target, backup_app)
			end
			dialog.block_alert(i18n.get("common.error_title"), i18n.get("menu.about.update.install_error"), i18n.get("button.ok"))
			Updater.set_update_state("idle")
			update_menu_fn()
			return
		end

		-- Remove the now-redundant backup and temp files (best-effort).
		-- hs.execute for synchronous cleanup: rm is fast and we are already
		-- inside an async callback, so blocking here is fine; no GC risk.
		os.remove(zip_path)
		pcall(hs.execute, "/bin/rm -rf " .. text_utils.shell_quote(backup_app)
			.. " " .. text_utils.shell_quote(tmp_dir))

		Logger.success(LOG, "Update installed at %s — reloading.", target)
		Updater.clear_cached_release()
		-- Short delay lets the log flush before hs.reload tears everything down.
		hs.timer.doAfter(0.3, function() hs.reload() end)
	end, { "-o", zip_path, "-d", tmp_dir })
	if not unzip_task then
		Updater.set_update_state("idle")
		update_menu_fn()
		return
	end

	M._active_tasks[unzip_task] = true
	if not TaskLifecycle.start(unzip_task, "Update archive extraction") then
		M._active_tasks[unzip_task] = nil
		Updater.set_update_state("idle")
		update_menu_fn()
	end
end

--- One-click update entry point.
--- idle      → check GitHub, cache if newer, then install
--- available → install from cache immediately
--- checking/installing → no-op (item is disabled in the menu)
--- @param channel string
--- @param update_menu_fn function Rebuild callback to refresh the label
local function one_click_update(channel, update_menu_fn)
	if is_local_source() then return end
	local state = Updater.get_update_state()
	if state == "checking" or state == "installing" then return end

	local cached = Updater.get_cached_release()
	if state == "available" and cached then
		Updater.set_update_state("installing")
		update_menu_fn()
		Logger.start(LOG, "Installing cached update %s…", cached.tag)
		local zip_path = (hs.fs.temporaryDirectory() or "/tmp") .. "ErgoptiPlus_" .. os.time() .. ".app.zip"
		download_to_file(cached, zip_path, function(ok, err)
			if not ok then
				dialog.block_alert(i18n.get("common.error_title"), err, i18n.get("button.ok"))
				Updater.set_update_state("available")
				update_menu_fn()
				return
			end
			replace_and_reload(zip_path, update_menu_fn)
		end)
		return
	end

	Updater.set_update_state("checking")
	update_menu_fn()
	local current = current_version()
	Logger.start(LOG, "One-click update check (channel: %s, current: %s)…", channel, current)

	hs.http.asyncGet(api_url(channel), { ["User-Agent"] = "ErgoptiPlus-Updater/1.0" }, function(status, body, _)
		if status ~= 200 or not body then
			Logger.warn(LOG, "One-click check: network unreachable (HTTP %d).", status)
			Updater.set_update_state("idle")
			update_menu_fn()
			dialog.block_alert(i18n.get("common.warning"), i18n.get("menu.about.update.network_error"), i18n.get("button.ok"))
			return
		end
		if channel == "dev" and body:match("^%s*%[") then
			body = Updater.pick_latest_prerelease_json(body)
		end
		local latest = Updater.parse_tag(body)
		if latest == "" then
			Logger.warn(LOG, "One-click check: tag parse failed.")
			Updater.set_update_state("idle")
			update_menu_fn()
			dialog.block_alert(i18n.get("common.warning"), i18n.get("menu.about.update.parse_error"), i18n.get("button.ok"))
			return
		end
		if not Updater.is_newer_version(latest, current) then
			Logger.info(LOG, "One-click check: already up to date (%s).", current)
			Updater.set_update_state("idle")
			update_menu_fn()
			local msg = i18n.get("menu.about.update.up_to_date"):gsub("{version}", text_utils.escape_gsub_replacement(current))
			dialog.block_alert(i18n.get("menu.about.changelog"), msg, i18n.get("button.ok"))
			return
		end

		local release, asset_error = Updater.parse_install_asset(body, latest)
		if not release then
			Logger.error(LOG, "One-click check: asset '%s' refused in release %s — %s.",
				ASSET_NAME, latest, tostring(asset_error))
			Updater.set_update_state("idle")
			update_menu_fn()
			dialog.block_alert(i18n.get("common.warning"), i18n.get("menu.about.update.no_asset"), i18n.get("button.ok"))
			return
		end

		Logger.success(LOG, "New version %s found, starting install…", latest)
		release.notes = Updater.parse_notes(body)
		if Updater.set_cached_release(release) ~= true then
			Logger.error(LOG, "One-click check: validated release could not be cached.")
			Updater.set_update_state("idle")
			update_menu_fn()
			dialog.block_alert(i18n.get("common.warning"), i18n.get("menu.about.update.no_asset"), i18n.get("button.ok"))
			return
		end
		Updater.set_update_state("installing")
		update_menu_fn()

		local zip_path = (hs.fs.temporaryDirectory() or "/tmp") .. "ErgoptiPlus_" .. os.time() .. ".app.zip"
		download_to_file(release, zip_path, function(ok, err)
			if not ok then
				dialog.block_alert(i18n.get("common.error_title"), err, i18n.get("button.ok"))
				Updater.set_update_state("available")
				update_menu_fn()
				return
			end
			replace_and_reload(zip_path, update_menu_fn)
		end)
	end)
end

--- Opens the dedicated changelog window for the given channel.
--- Delegates to ui.changelog which shows a webview with the full release list
--- and markdown-rendered notes instead of a plain text dialog.
--- @param channel string "main" or "dev"
local function show_changelog(channel)
	Logger.info(LOG, "Opening changelog window (channel=%s).", channel)
	changelog.open({ channel = channel })
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
		and state.update_channel or M.DEFAULT_STATE.update_channel
	local ver     = current_version()
	local ver_label = i18n.get("menu.about.title")

	local interval_sec = tonumber(state.update_check_interval_seconds) or Updater.get_check_interval()

	-- Forward-declared because set_channel and set_check_interval both reference it,
	-- but the definition appears below them. Without this the name resolves to a global
	-- nil at the call site and restart_background_checks receives nil as its callback.
	local update_menu_fn

	local function set_channel(c)
		state.update_channel = c
		if type(ctx.save_prefs) == "function" and ctx.save_prefs() ~= true then return false end
		Updater.restart_background_checks(
			c,
			tonumber(state.update_check_interval_seconds) or Updater.get_check_interval(),
			update_menu_fn
		)
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	local function set_check_interval(seconds)
		interval_sec = tonumber(seconds) or 0
		state.update_check_interval_seconds = interval_sec
		if type(ctx.save_prefs) == "function" and ctx.save_prefs() ~= true then return false end
		Updater.restart_background_checks(
			state.update_channel or channel,
			interval_sec,
			update_menu_fn
		)
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	-- Callback passed to the update flow so it can trigger a menu rebuild when
	-- the state machine transitions (checking → available → installing → idle).
	function update_menu_fn()
		if type(ctx.updateMenu) == "function" then ctx.updateMenu() end
	end

	local local_src = is_local_source()

	-- First disabled item mirrors AHK: "ErgoptiPlus <version>" with channel tag.
	-- e.g. "ErgoptiPlus v0.2.1-dev" or "ErgoptiPlus local"
	local ver_display
	if ver == "local" then
		ver_display = "ErgoptiPlus local"
	else
		local channel_tag = (channel == "dev") and "-dev" or ""
		ver_display = "ErgoptiPlus " .. ver .. channel_tag
	end

	-- Channel submenu — shown in both local and bundled modes.
	local channel_display = (channel == "dev")
		and i18n.get("menu.about.channel_dev")
		or  i18n.get("menu.about.channel_main")
	local channel_items = {
		{
			label   = i18n.get("menu.about.channel_main"),
			checked = (channel == "main") or nil,
			action      = function() set_channel("main") end,
		},
		{
			label   = i18n.get("menu.about.channel_dev"),
			checked = (channel == "dev") or nil,
			action      = function() set_channel("dev") end,
		},
	}

	local menu_items = {}

	-- Version header — always the first item, always disabled.
	--
	-- `label`, not `title`. This array is what the `about_updates` list provider
	-- returns, so the renderer reads it as provider DATA: a row keyed `title` has
	-- no label, and the renderer drops it with one warning. This row and the
	-- channel selector below were both invisible in the About submenu from the
	-- day the block became a provider until 2026-08-07.
	table.insert(menu_items, { label = ver_display, disabled = true })

	table.insert(menu_items, { separator = true })

	-- Channel selector submenu — always shown so the user can switch.
	local channel_title = i18n.get("menu.about.channel_menu") .. ": " .. channel_display
	table.insert(menu_items, { label = channel_title, items = channel_items })

	if not local_src then
		local freq_items = {}
		local current_freq_code = ""
		for _, preset in ipairs(Updater.INTERVAL_PRESETS) do
			local label = i18n.get("menu.about.frequency." .. preset.code)
			if preset.seconds == interval_sec then
				current_freq_code = preset.code
			end
			table.insert(freq_items, {
				label   = label,
				checked = (preset.seconds == interval_sec) or nil,
				action      = function() set_check_interval(preset.seconds) end,
			})
		end
		local freq_display = (current_freq_code ~= "") and current_freq_code or "?"
		table.insert(menu_items, {
			label = i18n.get("menu.about.frequency_menu") .. ": " .. freq_display,
			items  = freq_items,
		})

		-- Dynamic one-click update item — only meaningful for bundled builds.
		local upd_state = Updater.get_update_state()
		local is_busy = (upd_state == "checking" or upd_state == "installing")
		table.insert(menu_items, {
			label    = get_update_menu_label(),
			disabled = is_busy or nil,
			action       = not is_busy and function()
				Logger.info(LOG, "User triggered one-click update (channel: %s).", channel)
				one_click_update(channel, update_menu_fn)
			end or nil,
		})
	end

	-- The updater block above is the manifest's `about_updates` list; the two rows
	-- below it are `command` declarations. The separator between them is a `---`
	-- row. Until 2026-08-07 the whole submenu was assembled here and described
	-- nowhere, on all three drivers at once.
	local render_ctx = {}
	for key, value in pairs(ctx or {}) do render_ctx[key] = value end
	render_ctx.commands = {
		["about_changelog"] = function()
			Logger.info(LOG, "User opened changelog (channel: %s).", channel)
			show_changelog(channel)
		end,
		["about_releases_page"] = function() hs.urlevent.openURL(releases_page_url()) end,
	}

	local rendered = ManifestMenu.build("about_menu", "About", nil, nil, render_ctx, {
		["about_updates"] = function() return menu_items end,
	})

	-- The submenu title uses the generic i18n label (e.g. "Version / Mise à jour")
	-- so the menubar entry stays compact; the version detail is inside the submenu.
	return { label = ver_label, submenu = rendered }
end

return M
