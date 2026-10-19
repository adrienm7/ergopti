--- ui/webview_close_owner.lua

--- ==============================================================================
--- MODULE: Deferred Native WebView Close Owner
--- DESCRIPTION:
--- Keeps automatic product close cleanup outside Cocoa's close notification.
--- The packaged native deleteOnClose flag recursively re-wraps userdata during
--- GC, so it stays false throughout construction, explicit delete and user close.
--- ==============================================================================

local M = {}
local LOG = "ui_builder"
--- Creates an isolated close registry for one factory instance.
--- @param DeferredWork table Retained deferred scheduling port.
--- @param Logger table Central diagnostic port.
--- @return table owner Exact factory close API.
function M.new(DeferredWork, Logger)
	local api = {}
	local pending = {}
	local notification_depth = 0

	--- Tests the exact public userdata-consumption signal without indexing it.
	--- @param owner table Exact native close owner.
	--- @return boolean consumed
	local function consumed(owner)
		return owner.metatable ~= nil and getmetatable(owner.webview) == nil
	end

	--- Disarms the native recursive policy before any destructive operation.
	--- @param view userdata|table Exact WebView.
	local function disarm(view)
		assert(view:deleteOnClose(false) == view, "native close policy was not acknowledged")
		assert(view:deleteOnClose() == false, "native recursive close policy remains enabled")
	end

	api.disarm = disarm

	--- Settles an observed close outside its native notification frame.
	--- @param owner table Exact retained close owner.
	--- @return boolean settled
	local function settle(owner)
		if pending[owner] ~= true then return true end
		if notification_depth > 0 or owner.releasing then return false end
		if consumed(owner) then pending[owner] = nil; return true end
		owner.releasing = true
		local ok, detail = xpcall(function()
			disarm(owner.webview)
			owner.webview:delete()
		end, debug.traceback)
		if consumed(owner) then pending[owner] = nil; owner.releasing = false; return true end
		pcall(Logger.error, LOG, "Closed WebView cleanup remains owned: %s.", tostring(ok and "userdata not consumed" or detail))
		owner.releasing = false
		return false
	end

	--- Acquires a retained timer before invoking any external close callback.
	--- @param owner table Exact retained close owner.
	local function schedule(owner)
		owner.scheduled = true
		local arming, delivered_early = true, false
		local ok, committed = xpcall(function()
			return DeferredWork.after(0, function()
				owner.scheduled = false
				if arming or notification_depth > 0 then
					delivered_early = true
					if not arming then
						pcall(Logger.error, LOG,
							"Closed WebView cleanup callback delivered inside a native close notification; exact owner retained.")
					end
					return
				end
				settle(owner)
			end, "ui_builder.closed_webview")
		end, debug.traceback)
		arming = false
		if ok ~= true or committed ~= true or delivered_early then
			owner.scheduled = false
			pcall(Logger.error, LOG, "Closed WebView deferred cleanup refused; exact owner retained: %s.",
				tostring(not ok and committed or (delivered_early and "callback delivered before commit" or committed)))
		end
	end

	--- Retries unscheduled close debt before another factory admission.
	--- Scheduled owners already have an exact retained continuation. A reentrant
	--- open may proceed without deleting its predecessor inside windowWillClose.
	--- @return boolean ready
	function api.retry_cleanup()
		local ready = true
		local snapshot = {}
		for owner in pairs(pending) do snapshot[#snapshot + 1] = owner end
		for _, owner in ipairs(snapshot) do
			if not owner.scheduled and settle(owner) ~= true then ready = false end
		end
		return ready
	end

	--- Binds automatic product cleanup without arming native automatic GC.
	--- @param view userdata|table Exact newly constructed WebView.
	--- @param callback function|nil Synchronous once-only product close observer.
	--- @return boolean bound
	function api.bind(view, callback)
		disarm(view)
		local owner = { webview = view, metatable = getmetatable(view) }
		assert(view:windowCallback(function(action)
			if (action ~= "closing" and action ~= "closed") or owner.notified then return end
			owner.notified = true
			pending[owner] = true
			notification_depth = notification_depth + 1
			schedule(owner)
			local ok, detail = xpcall(function()
				if type(callback) == "function" then callback() end
			end, debug.traceback)
			if not ok then pcall(Logger.error, LOG, "WebView close callback failed: %s.", tostring(detail)) end
			notification_depth = notification_depth - 1
		end) == view, "native close callback was not acknowledged")
		return true
	end
	return api
end

return M
