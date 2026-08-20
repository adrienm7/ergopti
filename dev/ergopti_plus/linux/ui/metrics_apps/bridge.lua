--- ui/metrics_apps/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Metrics Apps Dashboard (per-app statistics)
--- Handles JS->Lua messages from _shared/ui/metrics_apps/.
--- Bridge name: "metrics_apps_bridge"
---
--- NOTE: This file replaces the formerly-named metrics_typing_bridge.lua
--- so that the module name matches the _shared/ui/ app directory convention
--- used by webview_manager._load_handler().
--- ==============================================================================

local M = {}
M.bridge_name = "metrics_apps_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.metrics_apps"

--- Builds the shared metrics payload expected by the browser dashboard.
--- @param state table Daemon state.
--- @return table
local function _build_initial_payload(state, include_prefetch)
	local keylogger = state.keylogger
	if keylogger and type(keylogger.get_dashboard_payload) == "function" then
		return keylogger.get_dashboard_payload({ include_prefetch = include_prefetch ~= false })
	end
	return {
		metrics_manifest = {},
		app_icons        = {},
		_prefetch_data   = { historical = {}, today = {} },
		driver_meta      = { os = "linux", heatmap_id = "kc" },
	}
end

--- Exposes the payload builder to the typing dashboard bridge.
--- @param state table Daemon state.
--- @return table Shared metrics payload.
function M.build_payload(state)
	return _build_initial_payload(state, true)
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) == "string" then
		if payload == "ready" then
			Logger.info(LOG, "Metrics apps UI ready.")
			return _build_initial_payload(state, true)
		end
		if payload == "refresh" then
			return _build_initial_payload(state, false)
		end
		return nil
	end

	if type(payload) ~= "table" then return nil end

	local action = payload.action
	if action == "ready" or action == "refresh" then
		return _build_initial_payload(state, action == "ready")
	end

	-- These four are not sent by the shared page today. They are kept because
	-- each calls a keylogger function that exists and does what its name says,
	-- and because the bridge is also the daemon's programmatic entry point —
	-- unlike `app_detail`, which was removed: it called `get_app_detail`, a
	-- function that has never existed on this driver, behind a
	-- `type(…) == "function"` guard that turned the missing function into a
	-- silent nil. The guard read as defensive while making the branch
	-- permanently unreachable and wrong.
	if action == "reset" then
		if state.keylogger and type(state.keylogger.reset_session) == "function" then
			pcall(state.keylogger.reset_session)
		end
		return _build_initial_payload(state, true)
	end

	if action == "export" then
		if state.keylogger and type(state.keylogger.export_json) == "function" then
			local ok, json = pcall(state.keylogger.export_json)
			return { exported = ok, json = ok and json or nil }
		end
		return { exported = false }
	end

	if action == "pause" then
		if state.keylogger and type(state.keylogger.suppress) == "function" then
			state.keylogger.suppress()
		end
		return { suppressed = true }
	end

	if action == "resume" then
		if state.keylogger and type(state.keylogger.unsuppress) == "function" then
			state.keylogger.unsuppress()
		end
		return { suppressed = false }
	end

	-- The category editor. This is the one control on the page that writes
	-- anything, and it was unhandled: the user picked a category, the modal
	-- closed, and the choice went nowhere. `category` is a real column on
	-- agg_app_day and the dashboard groups by it, so the effect was a control
	-- that looked like it worked and silently discarded its input.
	if action == "edit" then
		local app_name = tostring(payload.app or "")
		local category = tostring(payload.cat or "")
		if state.keylogger and type(state.keylogger.set_app_category) == "function" then
			local ok = state.keylogger.set_app_category(app_name, category, tonumber(payload.score) or 0)
			return { saved = ok, payload = _build_initial_payload(state, false) }
		end
		Logger.error(LOG, "Category edit for '%s' arrived but the keylogger cannot store it.", app_name)
		return { saved = false }
	end

	-- macOS answers this with a native chooser listing the known applications.
	-- Linux has no equivalent modal, and saying so is the honest answer: the
	-- page can fall back to its own list. Returning nil would be indistinguishable
	-- from a handler that crashed.
	if action == "pick" then
		Logger.info(LOG, "Application picker requested; this driver has no native chooser.")
		return { supported = false, apps = _build_initial_payload(state, false).metrics_manifest }
	end

	Logger.warn(LOG, "Unknown bridge action received: %s.", tostring(action))
	return nil
end

return M
