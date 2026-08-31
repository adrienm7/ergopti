--- infra/notifications.lua

--- ==============================================================================
--- MODULE: Notifications & Logging
--- DESCRIPTION:
--- Provides robust, fail-safe wrappers around Hammerspoon’s native
--- notification system and console logging. Automatically resolves paths
--- to load the application logo.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("infra.logger")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "notifications"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

M.DEBUG = false

local _logo_path  = ""
local _logo_image = nil

-- Hammerspoon's native notification default is five seconds. Retain each
-- clickable userdata for that same bounded window so its completion callback
-- cannot be collected before the user acts, then release it whether or not the
-- callback ran.
local NOTIFICATION_RETENTION_SEC = 5
local _notification_owners = {}
local _next_notification_id = 0

-- Safely resolve the absolute path to the favicon based on this file’s location
pcall(function()
	local _src  = debug.getinfo(1, "S").source
	local _base = (_src:sub(1,1) == "@" and _src:sub(2) or _src):match("^(.*[/\\])") or "./"
	_logo_path  = _base .. "../../../img/logo/logo_simple.png"
end)





-- ===================================
-- ===================================
-- ======= 2/ Internal Helpers =======
-- ===================================
-- ===================================

--- Safely loads and caches the Ergopti+ logo image for notifications.
--- @return userdata|nil The hs.image object, or nil if loading fails.
local function _get_logo()
	if not _logo_image and _logo_path ~= "" then
		local ok, img = pcall(hs.image.imageFromPath, _logo_path)
		if ok and img then 
			_logo_image = img 
		end
	end
	return _logo_image
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Emoji prefix for each notification type.
local TYPE_PREFIX = {
	success = "✅",
	error   = "❌",
	warning = "⚠️",
	info    = "ℹ️",
}

--- Runs one notification-click focus step without letting an async native
--- callback escape only to the Hammerspoon console.
--- @param label string Stable non-private operation label.
--- @param operation function Native focus operation.
local function run_click_step(label, operation)
	local ok, result_or_err = xpcall(operation, debug.traceback)
	if not ok or result_or_err == false then
		Logger.warn(LOG, "Notification click %s failed: %s.",
			label, tostring(result_or_err))
		return false
	end
	return true
end

--- Releases one notification and fences its pending retention deadline.
--- @param owner_id integer Notification owner identity.
local function release_notification(owner_id)
	local owner = _notification_owners[owner_id]
	if not owner then return end
	_notification_owners[owner_id] = nil
	if owner.cleanup_timer then
		local ok, settled_or_err = xpcall(function()
			return TimerScheduler.cancel(owner.cleanup_timer)
		end, debug.traceback)
		if not ok or settled_or_err ~= true then
			Logger.warn(LOG, "Notification cleanup timer retained for retry: %s.",
				tostring(settled_or_err))
		end
	end
end

--- Sends a system notification with the Ergopti+ branding.
--- An optional `kind` parameter ("success", "error", "warning", "info") prepends
--- the matching emoji to the title so notifications are scannable at a glance.
--- @param title_or_msg string Main title when body is provided, or message when body is omitted.
--- @param body string|nil Optional detail body.
--- @param kind string|nil Optional type: "success" | "error" | "warning" | "info".
--- @return boolean dispatched True only when the native notification accepted send().
--- @return string|nil error_message Exact native refusal detail.
function M.notify(title_or_msg, body, kind)
	if title_or_msg == nil then return false, "notification title is required" end
	local title_text = "Ergopti+"
	local info_text = tostring(title_or_msg)

	if body ~= nil then
		title_text = tostring(title_or_msg)
		info_text = tostring(body)
	end

	local prefix = kind and TYPE_PREFIX[kind]
	if prefix then title_text = prefix .. " " .. title_text end

	local owner_id = nil
	local created, notification_or_err = xpcall(function()
		return hs.notify.new(function()
			if owner_id then release_notification(owner_id) end
			if type(hs.focus) == "function" then
				run_click_step("global focus", hs.focus)
			end
			if hs.application and type(hs.application.get) == "function" then
				run_click_step("application activation", function()
					local app = hs.application.get("com.ergoptiplus.app")
						or hs.application.get("Hammerspoon")
					if app and type(app.activate) == "function" then
						return app:activate(true)
					end
					return true
				end)
			end
		end, {
			title           = title_text,
			informativeText = info_text,
			contentImage    = _get_logo(),
			withdrawAfter   = NOTIFICATION_RETENTION_SEC,
		})
	end, debug.traceback)
	if not created or notification_or_err == nil or notification_or_err == false then
		local detail = "Notification construction failed: " .. tostring(notification_or_err)
		-- ERROR would request another notification and recurse through this exact
		-- failing boundary. The caller escalates false through the runtime fail-safe;
		-- this WARNING preserves a direct-call diagnostic without creating a loop.
		Logger.warn(LOG, "%s.", detail)
		return false, detail
	end

	local notification = notification_or_err
	if type(notification.send) ~= "function" then
		local detail = "Notification object has no send capability"
		Logger.warn(LOG, "%s.", detail)
		return false, detail
	end

	_next_notification_id = _next_notification_id + 1
	owner_id = _next_notification_id
	_notification_owners[owner_id] = { notification = notification }
	local cleanup_timer, cleanup_committed = TimerScheduler.after(
		NOTIFICATION_RETENTION_SEC,
		function() _notification_owners[owner_id] = nil end
	)
	if cleanup_committed ~= true then
		_notification_owners[owner_id] = nil
		local detail = "Notification retention deadline did not commit"
		Logger.warn(LOG, "%s.", detail)
		return false, detail
	end
	_notification_owners[owner_id].cleanup_timer = cleanup_timer

	local sent, sent_or_err = xpcall(function()
		return notification:send()
	end, debug.traceback)
	if not sent or sent_or_err ~= notification then
		local detail = "Notification send failed: " .. tostring(sent_or_err)
		Logger.warn(LOG, "%s.", detail)
		return false, detail
	end

	Logger.info(LOG, "Notification dispatched (%s): %s — %s.",
		tostring(kind or "default"), title_text, info_text)
	return true
end

--- Prints styled debug information to the Hammerspoon console if DEBUG is enabled.
--- @param ... any Variadic arguments to print.
function M.debugLog(...)
	if not M.DEBUG then return end
	
	local args = {...}
	local parts = {}
	
	for i = 1, select("#", ...) do
		table.insert(parts, tostring(args[i]))
	end
	
	local msg = table.concat(parts, " ")
	
	local ok, err = xpcall(function()
		return hs.console.printStyledtext("[Ergopti+] " .. os.date("%H:%M:%S") .. " " .. msg)
	end, debug.traceback)
	if not ok then
		Logger.warn(LOG, "Styled debug console output failed: %s.", tostring(err))
	end
end

return M
