--- ui/update_check/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Update Check Window (Linux)
--- DESCRIPTION:
--- Opens the shared update-check window (_shared/ui/update_check) for the
--- About menu's "Check for updates" row and serves its actions. The check used
--- to answer with nothing but log lines, or a notification the user could not
--- act on.
--- Bridge name: "update_check_bridge"
---
--- FEATURES & RATIONALE:
--- 1. The phases and actions are the shared session's
---    (_shared/lua/updater/check_session.lua), identical on macOS: "checking",
---    then the answer of modules/updater/manager.lua's check, with every other
---    channel whose latest release is newer than the installed build.
--- 2. Update downloads and installs the offered release through the updater,
---    with its progress in the shared download window, and the daemon restarts
---    on the new version (the menu's on_update_finished).
--- 3. A switch goes through the updater's channel owner, refreshes the menu and
---    the Versions window, and checks the new channel at once.
--- 4. Pushes go through webview_manager.eval_js into this page only; a message
---    of a closed window finds no session and is refused.
--- 5. The updater refuses a check while busy: a click while the window's check
---    runs shows that window again, and a click while the updater is otherwise
---    busy starts nothing, rather than a check that could only fail.
--- ==============================================================================

local M = {}
M.bridge_name = "update_check_bridge"

local Json         = require("json")
local Logger       = require("logger.shim")
local CheckSession = require("updater.check_session")
local Installation = require("infra.installation")

local LOG = "bridge.update_check"

-- The window's app id (the _shared/ui directory)
local APP = "update_check"

-- The open window's session and the menu context it was opened with
local _session = nil
local _ctx = nil
local _offer_serial = 0





-- ==============================
-- ==============================
-- ======= 1/ The Ports =========
-- ==============================
-- ==============================

--- Calls one optional menu hook, logging a raise.
--- @param name string
--- @param ... any
local function hook(name, ...)
	local fn = _ctx and _ctx[name]
	if type(fn) ~= "function" then return end
	local ok, err = pcall(fn, ...)
	if not ok then Logger.error(LOG, "The menu hook '%s' raised: %s.", name, tostring(err)) end
end

--- Sends one message into the window.
--- @param message table
--- @return boolean pushed
local function push(message)
	local ok, json = pcall(Json.encode, message)
	if not ok or type(json) ~= "string" then
		Logger.error(LOG, "An update-check message could not be encoded: %s.", tostring(json))
		return false
	end
	return require("ui.webview_manager").eval_js(APP,
		"if(window.receiveUpdateCheck)window.receiveUpdateCheck(" .. json .. ")")
end

--- Downloads the exact consented offer for the dialog and the tray entrypoint.
--- @param updater table Native updater owner.
--- @param release table Exact cached authenticated release.
--- @param ctx table|nil Captured menu hooks and current pause owner.
--- @return boolean started
function M.download_offered(updater, release, ctx)
	if type(release) ~= "table" or updater.get_cached_release() ~= release
		or Installation.is_source_run() then return false end
	local state = updater.get_state()
	if state == "checking" or state == "downloading" or state == "installing" then return false end
	ctx = type(ctx) == "table" and ctx or {}
	_offer_serial = _offer_serial + 1
	local serial = _offer_serial
	local tag, url, checksum = release.tag, release.download_url, release.checksum_url
	local channel = updater.get_channel()
	local owner = { active = false, terminal = false, attempt = 0, failed_download = false }
	local session_id
	local I18n = require("infra.i18n")
	local DownloadWindow = require("ui.download_window.bridge")
	local function current()
		if serial ~= _offer_serial or owner.cancelled or owner.succeeded
			or updater.get_cached_release() ~= release or release.tag ~= tag
			or release.download_url ~= url or release.checksum_url ~= checksum
			or updater.get_channel() ~= channel or Installation.is_source_run() then return false end
		if type(ctx.is_paused) == "function" then
			local ok, paused = pcall(ctx.is_paused)
			if not ok or paused ~= false then return false end
		elseif ctx.paused == true then return false end
		-- A menu predicate may reenter the owner while checking current pause state.
		return serial == _offer_serial and not owner.cancelled and not owner.succeeded
			and updater.get_cached_release() == release and release.tag == tag
			and release.download_url == url and release.checksum_url == checksum
			and updater.get_channel() == channel
	end
	local function can_retry()
		if not current() or owner.active or not owner.failed_download then return false end
		local state = updater.get_state()
		return (state == "idle" or state == "available") and type(updater.download_release) == "function"
	end
	local function diagnostics_available()
		if not current() or type(ctx.on_open_today_log) ~= "function" then return false end
		local shell = require("adapters.shell_runner")
		if shell.has_command("xdg-open") ~= true then return false end
		local file = io.open(require("infra.logger_sink").main_log_path(), "rb")
		return file ~= nil and file:close() == true
	end
	local completion_hook = ctx.on_update_finished
	local function finished(installed, stage)
		if type(completion_hook) ~= "function" then return end
		local ok = pcall(completion_hook, installed, tag, stage)
		if not ok then Logger.error(LOG, "The bound update-completion hook raised.") end
	end
	local function dispatch(retry)
		if not current() or owner.active or (retry and not can_retry()) then return false end
		owner.attempt = owner.attempt + 1
		local attempt = owner.attempt
		owner.active, owner.terminal, owner.failed_download = true, false, false
		local completed = false
		local function finish_attempt(installed, archive, err, stage, failure_receipt)
			if completed or serial ~= _offer_serial or attempt ~= owner.attempt or owner.cancelled then return end
			completed = true
			owner.active, owner.terminal, owner.installing = false, true, false
			owner.succeeded = installed
			owner.failed_download = archive == nil and stage ~= "verify"
			if installed then Logger.success(LOG, "Update %s installed.", tag)
			else Logger.error(LOG, "Update %s failed at the %s: %s.", tag,
				archive and "install" or (stage or "download"), tostring(err)) end
			if session_id ~= nil then
				DownloadWindow.complete(session_id, installed, installed
					and I18n.get("updater.installed_restarting"):gsub("{1}", function() return tag end)
					or (stage == "verify"
						and I18n.get("changelog_window.install_error_verify"):gsub("{tag}", function() return tag end)
						or I18n.get(archive and "updater.install_error" or "updater.install_error_download")),
					archive == nil and stage ~= "verify" and failure_receipt or nil)
			end
			finished(installed, archive and "install" or (stage or "download"))
		end
		local function done(archive, err, stage, failure_receipt)
			if serial ~= _offer_serial or attempt ~= owner.attempt or owner.terminal or owner.cancelled then return end
			if not current() then
				owner.active, owner.terminal = false, true
				if session_id and type(DownloadWindow.retire) == "function" then DownloadWindow.retire(session_id) end
				return
			end
			if archive == nil then finish_attempt(false, archive, err, stage, failure_receipt); return end
			local native_install = updater.install_update_async
			if type(native_install) == "function" then
				owner.installing = true
				local window_admit = DownloadWindow.install_admission_current
				local function admit_install()
					if type(window_admit) ~= "function" or session_id == nil or not current()
						or serial ~= _offer_serial or attempt ~= owner.attempt or not owner.installing then return false end
					local checked, admitted = pcall(window_admit, session_id)
					return checked and admitted == true and current() and serial == _offer_serial
						and attempt == owner.attempt and owner.installing
						and package.loaded["ui.download_window.bridge"] == DownloadWindow
				end
				local constructing, admitted, seen, early = true, false, false, nil
				local function install_completed(installed, detail, receipt)
					if seen then return end
					seen = true
					if constructing then early = { installed, detail, receipt }
					elseif admitted then
						-- Accepted native completion retains this exact offer attempt.
						finish_attempt(installed == true, archive, detail, "install", receipt)
					end
				end
				local called, dispatched = pcall(native_install, archive, install_completed, admit_install)
				admitted = called and dispatched == true
				constructing = false
				if not admitted then
					finish_attempt(false, archive, called and "native install refused" or dispatched, "install")
				elseif early then
					finish_attempt(early[1] == true, archive, early[2], "install", early[3])
				end
			else
				-- Existing synchronous port shape; a declared native async refusal
				-- never falls back to this path.
				finish_attempt(updater.install_update(archive) == true, archive, err, stage, failure_receipt)
			end
		end
		local started
		if retry then started = updater.download_release(release, done)
		else started = updater.download_update(url, done) end
		if started ~= true and not owner.terminal then done(nil, "update dispatch refused", "download") end
		return started == true
	end
	session_id = DownloadWindow.show({
		kind = "app_update", label = "ErgoptiPlus " .. tag,
		is_current = current, can_retry = can_retry,
		classify_failure = function() return owner.failed_download end,
		on_retry = function() return dispatch(true) end,
		on_cancel = function()
			if not current() or not owner.active or owner.installing or updater.cancel_update() ~= true then return false end
			owner.cancelled, owner.active = true, false
			owner.attempt = owner.attempt + 1
			return true
		end,
		on_diagnostics = ctx.on_open_today_log, can_open_diagnostics = diagnostics_available,
	})
	if session_id == nil then Logger.warn(LOG, "The download window could not open; the update downloads without it.") end
	Logger.start(LOG, "Downloading the update %s…", tag)
	return dispatch(false)
end

--- The check page transfers its consent to one exact cached download owner.
local function install(updater, result)
	local release = updater.get_cached_release()
	if type(release) ~= "table" or release.tag ~= result.latest then
		Logger.error(LOG, "Refused to install %s: the updater no longer offers it.", tostring(result.latest))
		return false
	end
	return M.download_offered(updater, release, _ctx)
end

--- Builds the session of one window over the updater and the menu hooks.
--- @param updater table modules.updater.manager
--- @return table session
local function new_session(updater)
	local manager = require("ui.webview_manager")
	return CheckSession.new({
		push = push,
		check = function(channel, on_result)
			local dispatched = updater.check_for_updates(channel, function(_, _, _, result)
				on_result(result)
				hook("on_menu_changed")
			end)
			-- The menu greys its check row while the check runs
			if dispatched == true then hook("on_menu_changed") end
			return dispatched
		end,
		channel = updater.get_channel,
		current = updater.current_version,
		set_channel = function(id)
			if updater.set_channel(id) ~= true then return false end
			hook("on_menu_changed")
			-- An open Versions page follows, so its banner never offers the
			-- channel the user just chose here.
			local ok, Changelog = pcall(require, "ui.changelog.bridge")
			if ok then
				Changelog.push_subscribed_channel(id)
			else
				Logger.error(LOG, "The Versions page bridge is unavailable: %s.", tostring(Changelog))
			end
			return true
		end,
		install = function(result)
			local started = install(updater, result)
			if started then hook("on_menu_changed") end
			return started
		end,
		open_changelog = function() return manager.show("changelog") == true end,
		report = function(result)
			return require("ui.error_dialog.bridge").report({
				kind = "error",
				module = "updater",
				message = string.format("Update check failed on channel %s: %s", tostring(result.channel),
					tostring(result.detail)),
				time = os.date("%Y-%m-%d %H:%M:%S"),
			})
		end,
		-- The menu's own "today's log" opener: the path comes from the sink that
		-- writes it
		open_log = function()
			local open = _ctx and _ctx.on_open_today_log
			if type(open) ~= "function" then
				Logger.error(LOG, "The menu gave no opener for today's log.")
				return false
			end
			return open() == true
		end,
		close = function()
			if _session ~= nil then _session.retire() end
			_session = nil
			manager.hide(APP)
		end,
		log_path = function() return require("infra.logger_sink").main_log_path() end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
end





-- ==============================
-- ==============================
-- ======= 2/ Public API ========
-- ==============================
-- ==============================

--- Opens the update-check window and checks the subscribed channel, or checks
--- again in the window already open.
--- @param ctx table { updater, on_menu_changed?, on_update_finished?,
---   on_open_today_log? }: the updater and the menu's hooks.
--- @return boolean opened
function M.open(ctx)
	if type(ctx) ~= "table" or type(ctx.updater) ~= "table" then
		Logger.error(LOG, "The update-check window needs the updater.")
		return false
	end
	Logger.start(LOG, "Opening the update-check window…")
	-- While a check runs the updater refuses another one as busy: a click then
	-- shows the window still waiting for its answer, or does nothing when the
	-- updater is busy without it (a background check, a download), as on
	-- Windows. Starting a check would replace the pending answer with a failure
	if _session ~= nil and _session.result() == nil then
		_ctx = ctx
		if require("ui.webview_manager").show(APP) ~= true then
			Logger.error(LOG, "The update-check window could not be shown again.")
			return false
		end
		Logger.success(LOG, "Update-check window shown; its check is still running.")
		return true
	end
	local busy = ctx.updater.get_state()
	if busy == "checking" or busy == "downloading" or busy == "installing" then
		Logger.done(LOG, "Update-check window not opened: the updater is busy (%s).", busy)
		return true
	end
	_offer_serial = _offer_serial + 1
	-- A click while the window shows an answer checks again, over the updater
	-- and hooks of the menu that asked; the replaced session's late answer is
	-- ignored
	if _session ~= nil then _session.retire() end
	_ctx = ctx
	local session = new_session(ctx.updater)
	_session = session
	if require("ui.webview_manager").show(APP) ~= true then
		session.retire()
		_session = nil
		Logger.error(LOG, "The update-check window could not open.")
		return false
	end
	session.start()
	Logger.success(LOG, "Update-check window opened.")
	return true
end

--- Handles one message of the page.
--- @param payload any "ready", or { action, channel? } from host_bridge.js.
--- @return nil The session pushes its answers itself.
function M.on_message(payload)
	if _session == nil then
		Logger.warn(LOG, "An update-check message arrived for a window that is gone.")
		return nil
	end
	_session.on_message(payload)
	return nil
end

--- Forgets the session when the user closes the window with its close box.
function M.on_window_closed()
	if _session ~= nil then _session.retire() end
	_session = nil
end

--- Test seam: forgets the session and the context.
function M._reset()
	M.on_window_closed()
	_ctx = nil
	_offer_serial = 0
end

return M
