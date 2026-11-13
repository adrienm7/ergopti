--- ai/engine/prediction/app_filter.lua

--- ==============================================================================
--- MODULE: LLM App Filter
--- DESCRIPTION:
--- Determines whether LLM predictions should be suppressed for the currently
--- focused application or text field. Centralises all accessibility (AX) queries
--- that detect URL bars, password fields, and user-configured exclusion lists so
--- prediction_engine can delegate this check with a single function call.
---
--- FEATURES & RATIONALE:
--- 1. URL-bar detection: three-layer AX strategy (AXSubrole, AXIdentifier, parent
---    toolbar) covers Safari, Chrome, Edge, Firefox, and Arc without false positives
---    in non-browser apps.
--- 2. Secure-field detection: guards password inputs across all applications, not
---    only browsers, so credentials are never leaked to the LLM backend.
--- 3. Focused-window preference: uses the window-owning app rather than
---    frontmostApplication so floating launchers (e.g. Raycast) inherit the correct
---    exclusion rules even when they are not the macOS frontmost app.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("core.logger.engine.logger")
local km_utils = require("modules.keymap.utils")
local TextUtils = require("core.text.engine.utils_core")
local SecureFieldDetector = require("platform.focus.secure_field_detector")

local LOG = "llm.app_filter"


--- =============================================
--- =============================================
--- ======= 1/ Module Constants =================
--- =============================================
--- =============================================

-- AXSubrole assigned by macOS to URL text fields in Safari and other native browser controls.
local AX_URL_SUBROLE = "AXURLField"

-- Lowercase substrings matched against AXIdentifier to detect Chrome/Brave/Opera omniboxes.
-- Edge does not reliably expose an identifier, so a parent-toolbar fallback is used instead.
local URL_BAR_ID_PATTERNS = { "address", "urlfield", "location", "omnibox", "url" }

-- Bundle IDs of browsers for which an AXTextField inside an AXToolbar is always the URL bar.
-- Used as a fallback when AXSubrole and AXIdentifier checks both come up empty.
local BROWSER_BUNDLE_IDS = {
	["com.apple.Safari"]                = true,
	["com.google.Chrome"]               = true,
	["com.google.Chrome.canary"]        = true,
	["com.microsoft.edgemac"]           = true,
	["com.microsoft.edgemac.Dev"]       = true,
	["com.microsoft.edgemac.Canary"]    = true,
	["org.mozilla.firefox"]             = true,
	["com.brave.Browser"]               = true,
	["com.brave.Browser.nightly"]       = true,
	["com.operasoftware.Opera"]         = true,
	["com.vivaldi.Vivaldi"]             = true,
	["company.thebrowser.Browser"]      = true,  -- Arc
}

--- Whether an application is one of the known browsers. The keymap reads it
--- for Cmd+L, which selects the whole address of the address bar.
--- @param bundle_id string|nil macOS bundle identifier.
--- @return boolean
function M.is_browser_bundle(bundle_id)
	return type(bundle_id) == "string" and BROWSER_BUNDLE_IDS[bundle_id] == true
end


--- =============================================
--- =============================================
--- ======= 2/ AX Element Helpers ===============
--- =============================================
--- =============================================

--- Returns the currently focused accessibility element.
--- hs.axuielement.focusedElement() does not exist — the canonical way is to query
--- AXFocusedUIElement from the application-level accessibility element.
--- @param front userdata The frontmost hs.application.
--- @return userdata|nil The focused AX element, or nil on failure.
--- @return boolean|nil read_failed True only for a failed focused-element read.
--- @return any error_detail Native focus-read refusal or Lua exception, if any.
local function get_focused_element(front)
	if not front then return nil end
	local ok_ax, ax = pcall(function() return hs.axuielement.applicationElementForPID(front:pid()) end)
	if not ok_ax then return nil, true, ax end
	if not ax then return nil, true, "Accessibility application element is unavailable" end
	local ok_fe, focused, focus_error = pcall(function() return ax:attributeValue("AXFocusedUIElement") end)
	if not ok_fe then return nil, true, focused end
	return focused, focused == nil and focus_error ~= nil, focus_error
end

--- Returns true when the currently focused element is a secure text field.
--- Works across all applications, not just browsers.
--- @param front userdata|nil The frontmost hs.application.
--- @return boolean True if a password/secure field has focus.
local function is_secure_field_focused(front, resolve_focused)
	if not front then return false end
	local focused = resolve_focused()
	if not focused then return false end
	return SecureFieldDetector.isElementSecure(focused)
end

--- Reads one optional AX attribute without mistaking a transport refusal for absence.
--- Hammerspoon returns nil plus this exact error for an unsupported attribute.
local function read_optional_attribute(element, attribute)
	local ok, value, detail = pcall(function() return element:attributeValue(attribute) end)
	if not ok then return nil, false end
	if value == nil and detail ~= nil and detail ~= "Attribute is not supported by target" then
		return nil, false
	end
	return value, true
end

--- Returns true when the currently focused element is a browser URL bar.
---
--- Detection strategy (three layers, each more expensive than the last):
---   1. AXSubrole == "AXURLField" — Safari and native WebKit controls; definitive.
---   2. AXIdentifier pattern match — Chrome, Brave, Opera; reliable when id is set.
---   3. Ancestor toolbar check — Edge, Firefox, Arc; no identifier exposed, but a
---      text field directly inside an AXToolbar in a known browser is always the URL bar.
---
--- @param front userdata|nil The frontmost hs.application.
--- @return boolean True if a URL-bar-type element has input focus.
local function is_url_bar_focused(front, resolve_focused)
	if not front then return false end
	local ok_bid, bid = pcall(function() return front:bundleID() end)
	if not ok_bid or (bid ~= nil and type(bid) ~= "string") then return true end
	if not BROWSER_BUNDLE_IDS[bid or ""] then return false end

	local focused = resolve_focused()
	if not focused then return false end

	local ok_role, role = pcall(function() return focused:attributeValue("AXRole") end)
	-- A missing or malformed role cannot prove that this is not a URL field.
	if not ok_role or type(role) ~= "string" or role == "" then return true end
	if role ~= "AXTextField" then return false end

	-- Layer 1 — Safari / WebKit: AXSubrole is explicitly "AXURLField"
	local subrole, ok_sub = read_optional_attribute(focused, "AXSubrole")
	if not ok_sub then return true end
	if subrole == AX_URL_SUBROLE then return true end

	-- Layer 2 — Chrome / Brave / Opera: AXIdentifier contains a recognisable pattern
	local identifier, ok_id = read_optional_attribute(focused, "AXIdentifier")
	if not ok_id then return true end
	if type(identifier) == "string" and identifier ~= "" then
		local id_lower = identifier:lower()
		for _, pattern in ipairs(URL_BAR_ID_PATTERNS) do
			if id_lower:find(pattern, 1, true) then return true end
		end
	end

	-- Layer 3 — Edge / Firefox / Arc: no usable identifier; check the parent hierarchy.
	-- Walk up two levels: input may be directly in the toolbar (Firefox) or wrapped in
	-- an AXGroup inside the toolbar (Chromium / Edge omnibox structure).
	local parent, ok_p = read_optional_attribute(focused, "AXParent")
	if not ok_p then return true end
	if parent then
		local parent_role, ok_pr = read_optional_attribute(parent, "AXRole")
		if not ok_pr or type(parent_role) ~= "string" or parent_role == "" then return true end
		if parent_role == "AXToolbar" then return true end
		local grandparent, ok_gp = read_optional_attribute(parent, "AXParent")
		if not ok_gp then return true end
		if grandparent then
			local gp_role, ok_gr = read_optional_attribute(grandparent, "AXRole")
			if not ok_gr or type(gp_role) ~= "string" or gp_role == "" then return true end
			if gp_role == "AXToolbar" then return true end
		end
	end

	return false
end

--- Returns the application that currently has keyboard focus.
--- Prefers the app owning the focused window because floating-panel launchers
--- (e.g. Raycast) accept keyboard input without becoming the macOS frontmost
--- application — using frontmostApplication() would return the previously
--- active app and incorrectly inherit its exclusion rules.
--- @return userdata|nil hs.application object, or nil on failure.
local function get_focused_app()
	local ok_fw, fw = pcall(hs.window.focusedWindow)
	if not ok_fw then return nil, true end
	if fw then
		local ok_app, app = pcall(function() return fw:application() end)
		if not ok_app or not app then return nil, true end
		return app, false
	end
	local ok_front, front = pcall(hs.application.frontmostApplication)
	if not ok_front then return nil, true end
	return front, false
end


--- The identifier of the application that has keyboard focus: its bundle identifier.
--- This is the key the per-application profile overrides are stored under.
--- @return string|nil bundle_id Nil when no application or no bundle identifier is available.
function M.focused_app_id()
	local front = get_focused_app()
	if not front then return nil end
	local ok, bundle_id = pcall(function() return front:bundleID() end)
	if ok and type(bundle_id) == "string" and bundle_id ~= "" then return bundle_id end
	return nil
end


--- =============================================
--- =============================================
--- ======= 3/ Public Filter ===================
--- =============================================
--- =============================================

--- Returns true when LLM predictions should be suppressed for the current app.
--- Checks the keymap global window ignore list, secure-field detection, URL-bar
--- detection, and the user-configured per-app exclusion list.
---
--- @param state table Shared keymap core state (for ignored_window_* fields).
--- @param excluded_apps table Array of exclusion descriptors from the menu.
--- @param url_bar_filter_enabled boolean Whether to block URL bar fields.
--- @param secure_field_filter_enabled boolean Whether to block secure/password fields.
--- @return boolean True if the active window or app should be excluded.
function M.is_blocked(state, excluded_apps, url_bar_filter_enabled, secure_field_filter_enabled)
	if not state then return false end
	-- Nil is the fail-closed "focused window not classified yet" state. Treating
	-- it like false can launch an LLM request during the exact focus-transition
	-- window that the keymap has quarantined to avoid leaking private text.
	if km_utils.is_ignored_window(
		state.ignored_window_titles, state.ignored_window_patterns) ~= false
	then
		return true
	end

	local front, focus_failed = get_focused_app()
	if focus_failed then
		Logger.debug(LOG, "Focused application could not be established — LLM request skipped.")
		return true
	end

	-- Both filters used to resolve the focused AX element independently, so a
	-- browser with both enabled paid the cross-process round-trip TWICE per
	-- keystroke — and this runs inside the keyDown eventtap, where cumulative AX
	-- latency is what gets the tap disabled. Resolve at most once per call, and
	-- lazily, so the combinations that pay nothing today still pay nothing.
	local focused_cache, focused_failed, focused_error, focused_resolved = nil, false, nil, false
	local function resolve_focused()
		if not focused_resolved then
			focused_resolved = true
			focused_cache, focused_failed, focused_error = get_focused_element(front)
		end
		return focused_cache
	end

	if secure_field_filter_enabled and is_secure_field_focused(front, resolve_focused) then
		Logger.debug(LOG, "Secure field focused — LLM request skipped.")
		return true
	end
	if url_bar_filter_enabled and is_url_bar_focused(front, resolve_focused) then
		Logger.debug(LOG, "URL bar focused — LLM request skipped.")
		return true
	end
	-- A nil-only focus result remains a valid absence. A failed native read
	-- cannot establish that either requested AX exclusion permits this field.
	if focused_failed then
		Logger.debug(LOG, "Focused Accessibility read failed — LLM request skipped: %s.", tostring(focused_error))
		return true
	end
	if not front then return false end

	local metadata_ok, bid, path, name = pcall(function()
		return front:bundleID(), front:path(), front:name()
	end)
	if not metadata_ok or (bid ~= nil and type(bid) ~= "string")
		or (path ~= nil and type(path) ~= "string") or (name ~= nil and type(name) ~= "string") then
		Logger.debug(LOG, "Focused application metadata is unreadable — LLM request skipped.")
		return true
	end
	local path_known = type(path) == "string" and path ~= ""
	bid, path, name = bid or "", path or "", TextUtils.trig_fold(name or "")

	for _, app in ipairs(excluded_apps) do
		if type(app) ~= "string" and type(app) ~= "table" then
			Logger.warn(LOG, "Invalid application exclusion — LLM request skipped.")
			return true
		end
		-- Shared configuration also admits a plain application identifier.
		-- Keep structured entries' path / bundle priority unchanged.
		local item = type(app) == "table" and app or {}
		local plain = type(app) == "string" and app or ""
		local plain_path = plain ~= "" and plain:sub(1, 1) == "/"
		local has_path = type(item.appPath) == "string" and item.appPath ~= ""
		local has_bid  = type(item.bundleID) == "string" and item.bundleID ~= ""
		local configured_name = TextUtils.trig_fold(type(item.name) == "string" and item.name or plain)
		if (has_path or plain_path) and not path_known then
			Logger.debug(LOG, "Focused application path is unavailable — LLM request skipped.")
			return true
		end
		-- Guard: name must also be non-empty. Without this, an empty name (app
		-- whose hs:name() returns nil) causes ("slack"):find("", 1, true) = 1,
		-- so every name-only exclusion entry would match any nameless app.
		local same_name = (not has_path and not has_bid and not plain_path
			and configured_name ~= "" and name ~= ""
			and (configured_name == name or (plain == "" and
				(name:find(configured_name, 1, true)
				or configured_name:find(name, 1, true)))))
		local path_match = (has_path and item.appPath == path)
			or (plain_path and plain == path)
		local bid_match  = (not has_path and has_bid and item.bundleID == bid)
			or (plain ~= "" and not plain_path and bid ~= ""
				and TextUtils.trig_fold(plain) == TextUtils.trig_fold(bid))

		if path_match or bid_match or same_name then
			Logger.debug(LOG, "App excluded: '%s' — LLM request skipped.", front:name() or bid)
			return true
		end
	end
	return false
end

return M
