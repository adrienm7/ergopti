--- diagnostics/ui/field_check/field_report_window.lua

--- ==============================================================================
--- MODULE: Field Report Window (macOS host)
--- DESCRIPTION:
--- Hosts the shared field report progress page (_shared/ui/field_report/) in a
--- centered WKWebView for Débogage's « Lancer le field report (tous les
--- tests) »: the steps of the in-app run as they go, then the verdict, the
--- counts, the results folder and the buttons to open it in Finder, copy the
--- report or create a GitHub issue.
---
--- FEATURES & RATIONALE:
--- 1. The window is built by the shared factory (ui_builder.show_webview): its
---    canonical title, the chrome of every Ergopti window, the locale strings
---    and the tracking of the reading choices (core.ui.ui.reading_views).
--- 2. This module only creates the window and forwards messages: the run's
---    progress and the actions are field_report_progress.lua's.
--- 3. Only the exact window this module created receives pushes and sends
---    messages, so a late callback of a closed window never reaches its
---    successor. Its close box tells the controller, which cancels a run still
---    going on.
--- ==============================================================================

local M = {}

local Logger        = require("core.logger.engine.logger")
local DeferredWork  = require("core.timing.engine.deferred_work")
local Paths         = require("core.fs.engine.paths")
local Json          = require("core.text.engine.json")
local WebviewResult = require("core.ui.adapters.webview_result")
local Channel       = require("core.ui.adapters.webview_channel")

local LOG = "diagnostics.ui.field_check.field_report_window"

-- The exact window this module created, its message channel and its controller
local _webview = nil
local _usercontent = nil
local _owner = nil





-- ================================
-- ================================
-- ======= 1/ Page Plumbing =======
-- ================================
-- ================================

--- Evaluates window.receiveFieldReport(message) in the exact window.
--- @param view any The window the push is meant for.
--- @param message table
--- @return boolean pushed
local function push_to(view, message)
	if view == nil or view ~= _webview then return false end
	local ok, encoded = pcall(Json.encode, message)
	if not ok or type(encoded) ~= "string" then
		Logger.error(LOG, "A field report window message could not be encoded.")
		return false
	end
	local failed = false
	local submitted, result = pcall(function()
		return view:evaluateJavaScript("if(window.receiveFieldReport)window.receiveFieldReport(" .. encoded .. ")",
			function(_, script_error)
				if WebviewResult.is_error(script_error) and not failed then
					failed = true
					-- WebKit errors may include the evaluated payload; keep fixed text only
					Logger.error(LOG, "Field report window JavaScript execution failed.")
				end
			end)
	end)
	if not submitted or result ~= view then
		Logger.error(LOG, "A field report window script was refused.")
		return false
	end
	return view == _webview and not failed
end

--- Releases the window's message channel.
--- @param usercontent any
local function release_usercontent(usercontent)
	if usercontent == nil or usercontent ~= _usercontent then return end
	_usercontent = nil
	local ok, err = pcall(usercontent.setCallback, usercontent, nil)
	if not ok then Logger.error(LOG, "The field report window callback could not be released: %s.", tostring(err)) end
end

--- Closes the window this module created and tells its controller.
local function close_window()
	local view, usercontent, owner = _webview, _usercontent, _owner
	_webview, _owner = nil, nil
	if view ~= nil then
		local ok, err = pcall(function() view:delete() end)
		if not ok then Logger.error(LOG, "The field report window did not close: %s.", tostring(err)) end
	end
	release_usercontent(usercontent)
	if owner ~= nil then owner.on_closed() end
end

--- Routes one page message to the window's controller.
--- @param owner table The controller.
--- @param body any "ready" or { action }.
local function on_page_message(owner, body)
	if body == "ready" then
		owner.on_ready()
	elseif type(body) == "table" then
		owner.on_action(body.action)
	else
		Logger.warn(LOG, "Refused a field report window message that is not one of its actions.")
	end
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Opens the window of one run; a window left open by a finished run is
--- replaced.
--- @param owner table The run's progress (field_report_progress.new).
--- @return boolean opened
function M.open(owner)
	assert(type(owner) == "table" and type(owner.bind) == "function", "field report window: no controller")
	if _webview ~= nil then close_window() end
	Logger.start(LOG, "Opening the field report window…")
	local ui_builder = require("core.ui.ui.builder")
	local geo = ui_builder.get_app_geometry("field_report")
	if not geo then
		Logger.error(LOG, "No geometry for 'field_report' in apps.manifest.json; the window cannot open.")
		return false
	end
	-- The page's bridge is named after its apps.manifest.json id
	local usercontent, why = Channel.new("field_report")
	if not usercontent then
		Logger.error(LOG, "The field report window message channel could not be created: %s.", tostring(why))
		return false
	end
	_usercontent = usercontent
	local candidate = nil
	local bound, binding = pcall(usercontent.setCallback, usercontent, function(message)
		if candidate == nil or candidate ~= _webview or _owner ~= owner then return end
		on_page_message(owner, type(message) == "table" and message.body or nil)
	end)
	if not bound or binding ~= usercontent then
		release_usercontent(usercontent)
		Logger.error(LOG, "The field report window callback binding did not commit: %s.", tostring(binding))
		return false
	end
	local factory_ok, view = xpcall(function()
		return ui_builder.show_webview({
			app_id = "field_report",
			delete_on_close = true,
			frame = ui_builder.get_centered_frame(geo.width, geo.height),
			style_masks = Channel.resizable_style(),
			usercontent = usercontent,
			allow_new_windows = false,
			assets_dir = (Paths.shared("ui/field_report") or "") .. "/",
			on_close = function()
				-- The close box: the window is gone, the controller hears it once
				if candidate == nil or candidate ~= _webview then return end
				_webview, _owner = nil, nil
				release_usercontent(usercontent)
				owner.on_closed()
			end,
			on_webview_created = function(created)
				candidate = created
				_webview, _owner = created, owner
				owner.bind({
					push = function(message) return push_to(created, message) end,
					close = function() if created == _webview then close_window() end end,
				})
				return true
			end,
			schedule_after = function(delay, callback, label)
				return DeferredWork.after(delay, callback, label or "field_report.webview")
			end,
			is_current = function() return candidate ~= nil and candidate == _webview end,
		})
	end, debug.traceback)
	if not factory_ok or view == nil or view ~= candidate then
		if candidate ~= nil and candidate == _webview then close_window() else release_usercontent(usercontent) end
		Logger.error(LOG, "The field report window could not be created: %s.", tostring(view))
		return false
	end
	Logger.success(LOG, "Field report window opened.")
	return true
end

--- Brings the open window back in front, for a click on the row while it runs.
--- @return boolean shown False when no window is open.
function M.bring_to_front()
	local view = _webview
	if view == nil then return false end
	return require("core.ui.ui.builder").force_focus(view, false, {
		is_current = function() return rawequal(_webview, view) end,
	}) == true
end

--- Whether a field report window is open.
--- @return boolean
function M.is_open()
	return _webview ~= nil
end

--- Test seam: forgets the window without touching native objects.
function M._reset()
	_webview, _usercontent, _owner = nil, nil, nil
end

return M
