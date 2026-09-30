--- ui/update_check/init.lua

--- ==============================================================================
--- MODULE: Update Check Window (macOS host)
--- DESCRIPTION:
--- Hosts the shared update-check page (_shared/ui/update_check) in a centered
--- WKWebView: the About menu's "Check for updates" row opens it, the Lua
--- driver checks the subscribed channel (modules/updater/auto_check.lua), and
--- the window shows "checking", then the answer and the other channels with a
--- newer release.
---
--- FEATURES & RATIONALE:
--- 1. Lua owns the check, Sparkle only installs: the Update button hands the
---    offered channel to the launcher (adapters/update_launcher.lua), whose
---    Sparkle controller verifies, downloads, installs and relaunches.
--- 2. The page's actions and phases are the shared session's
---    (_shared/lua/updater/check_session.lua), identical on Linux; this module
---    only creates the window, forwards messages and wires the driver's owners.
--- 3. Singleton: a second click focuses the open window and checks again, over
---    the owners of the menu session that asked. Only the exact window this
---    module created receives pushes, so a late callback of a closed window
---    never writes into its successor.
--- 4. Nothing here runs on the typing path; the check is asynchronous.
--- ==============================================================================

local M = {}

local hs             = hs
local Logger         = require("infra.logger")
local DeferredWork   = require("infra.deferred_work")
local i18n           = require("infra.i18n")
local Paths          = require("infra.paths")
local Json           = require("json")
local CheckSession   = require("updater.check_session")
local Updater        = require("modules.updater")
local UpdateLauncher = require("adapters.update_launcher")

local LOG = "update_check"

-- Name of the page's message handler (_shared/ui/host_bridge.js catalogue)
local BRIDGE_NAME = "update_check_bridge"

-- The exact window this module created, and its session.
local _webview = nil
local _session = nil





-- ================================
-- ================================
-- ======= 1/ Page plumbing =======
-- ================================
-- ================================

--- Evaluates window.receiveUpdateCheck(message) in the exact window.
--- @param view any The window the push is meant for.
--- @param message table
--- @return boolean pushed
local function push_to(view, message)
	if view == nil or view ~= _webview then return false end
	local ok, encoded = pcall(Json.encode, message)
	if not ok or type(encoded) ~= "string" then
		Logger.error(LOG, "An update-check message could not be encoded.")
		return false
	end
	local submitted, err = pcall(function()
		view:evaluateJavaScript("if(window.receiveUpdateCheck)window.receiveUpdateCheck(" .. encoded .. ")")
	end)
	if not submitted then Logger.error(LOG, "The update-check window refused a message: %s.", tostring(err)) end
	return submitted
end

--- Forgets the window's session: a late answer of its check shows nothing.
local function retire_session()
	if _session ~= nil then _session.retire() end
	_session = nil
end

--- Closes the window this module created.
local function close_window()
	local view = _webview
	retire_session()
	_webview = nil
	if view ~= nil then
		local ok, err = pcall(function() view:delete() end)
		if not ok then Logger.error(LOG, "The update-check window did not close: %s.", tostring(err)) end
		Logger.info(LOG, "Update-check window closed.")
	end
end

--- Opens today's log in the default application.
--- @return boolean opened
local function open_today_log()
	local ShellRunner = require("adapters.shell_runner")
	return require("ui.log_openers").open_today_log(function(target) return (ShellRunner.open(target)) end)
end

--- The session of one window, bound to that exact window and the menu's owners.
--- @param view any The window.
--- @param ctx table { checks, channel_owner, on_change }
--- @return table session
local function session_for(view, ctx)
	local function changed()
		if type(ctx.on_change) ~= "function" then return end
		local ok, err = pcall(ctx.on_change)
		if not ok then Logger.error(LOG, "The menu refresh after an update check raised: %s.", tostring(err)) end
	end
	return CheckSession.new({
		push = function(message) return push_to(view, message) end,
		check = function(channel, on_result)
			if type(ctx.checks) ~= "table" or type(ctx.checks.check_now) ~= "function" then
				Logger.error(LOG, "No automatic-check owner: the update check cannot run.")
				return false
			end
			return ctx.checks.check_now(channel, function(result)
				on_result(result)
				changed()
			end)
		end,
		channel = function() return ctx.channel_owner.get() end,
		current = Updater.current_version,
		set_channel = function(id)
			local committed = ctx.channel_owner.set(id) == true
			if committed then changed() end
			return committed
		end,
		-- Sparkle reads the same channel's feed and shows its own install dialog.
		install = function(result) return UpdateLauncher.request_check(result.channel) end,
		open_changelog = function(channel)
			require("ui.changelog").open({ channel = channel, channel_owner = ctx.channel_owner })
			return true
		end,
		report = function(result)
			return require("ui.error_dialog").report({
				kind = "error",
				module = "updater",
				message = string.format("Update check failed on channel %s: %s", tostring(result.channel),
					tostring(result.detail)),
				time = os.date("%Y-%m-%d %H:%M:%S"),
			})
		end,
		open_log = open_today_log,
		close = function() if view == _webview then close_window() end end,
		log_path = Logger.today_log_path,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Opens the update-check window and checks the subscribed channel, or checks
--- again in the window already open.
--- @param ctx table { checks, channel_owner, on_change }: the menu session's
---   automatic-check owner and channel owner, and the menu refresh.
--- @return boolean opened
function M.open(ctx)
	if type(ctx) ~= "table" or type(ctx.channel_owner) ~= "table" then
		Logger.error(LOG, "The update-check window needs the menu session's channel owner.")
		return false
	end
	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui then
		Logger.error(LOG, "The update-check window cannot open: ui_builder is unavailable.")
		return false
	end
	if _webview ~= nil and _session ~= nil then
		ui_builder.force_focus(_webview, false)
		retire_session()
		_session = session_for(_webview, ctx)
		_session.start()
		return true
	end
	Logger.start(LOG, "Opening the update-check window…")
	local geo = ui_builder.get_app_geometry("update_check")
	if not geo then
		Logger.error(LOG, "No geometry for 'update_check' in apps.manifest.json; the window cannot open.")
		return false
	end
	local ok_uc, uc = pcall(hs.webview.usercontent.new, BRIDGE_NAME)
	if not ok_uc or not uc then
		Logger.error(LOG, "The update-check message channel could not be created.")
		return false
	end
	local candidate = nil
	uc:setCallback(function(message)
		if candidate == nil or candidate ~= _webview or _session == nil then return end
		_session.on_message(type(message) == "table" and message.body or nil)
	end)
	local masks = hs.webview.windowMasks
	local view = ui_builder.show_webview({
		frame = ui_builder.get_centered_frame(geo.width, geo.height),
		title = i18n.get("update_check.window_title"),
		style_masks = (masks["titled"] or 1) + (masks["closable"] or 2),
		usercontent = uc,
		allow_new_windows = false,
		assets_dir = (Paths.shared("ui/update_check") or "") .. "/",
		on_close = function()
			if candidate ~= nil and candidate == _webview then
				retire_session()
				_webview = nil
			end
		end,
		on_webview_created = function(owned)
			if _webview ~= nil then return false end
			candidate = owned
			_webview = owned
			_session = session_for(owned, ctx)
			return true
		end,
		schedule_after = function(delay, callback, label)
			return DeferredWork.after(delay, callback, label or "update_check.webview")
		end,
		is_current = function() return candidate ~= nil and candidate == _webview end,
	})
	if view == nil or view ~= candidate or _session == nil then
		retire_session()
		_webview = nil
		Logger.error(LOG, "The update-check window could not be created.")
		return false
	end
	_session.start()
	Logger.success(LOG, "Update-check window opened.")
	return true
end

-- Test seams: the session factory, the exact-window push and the open window.
M._session_for = session_for
M._push_to = push_to
function M._set_window(view, session) _webview, _session = view, session end
function M._session() return _session end

return M
