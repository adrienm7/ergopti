--- modules/llm/app_filter.lua

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
local Logger = require("lib.logger")
local km_utils = require("modules.keymap.utils")

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
local function get_focused_element(front)
	if not front then return nil end
	local ok_ax, ax = pcall(hs.axuielement.applicationElementForPID, front:pid())
	if not ok_ax or not ax then return nil end
	local ok_fe, focused = pcall(function() return ax:attributeValue("AXFocusedUIElement") end)
	return (ok_fe and focused) or nil
end

--- Returns true when the currently focused element is a secure text field.
--- Works across all applications, not just browsers.
--- @param front userdata|nil The frontmost hs.application.
--- @return boolean True if a password/secure field has focus.
local function is_secure_field_focused(front)
	if not front then return false end
	local focused = get_focused_element(front)
	if not focused then return false end
	local ok_role, role    = pcall(function() return focused:attributeValue("AXRole") end)
	local ok_sub,  subrole = pcall(function() return focused:attributeValue("AXSubrole") end)
	return (ok_role and role    == "AXSecureTextField")
	    or (ok_sub  and subrole == "AXSecureTextField")
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
local function is_url_bar_focused(front)
	if not front then return false end
	local bid = front:bundleID() or ""
	if not BROWSER_BUNDLE_IDS[bid] then return false end

	local focused = get_focused_element(front)
	if not focused then return false end

	local ok_role, role = pcall(function() return focused:attributeValue("AXRole") end)
	if not ok_role or role ~= "AXTextField" then return false end

	-- Layer 1 — Safari / WebKit: AXSubrole is explicitly "AXURLField"
	local ok_sub, subrole = pcall(function() return focused:attributeValue("AXSubrole") end)
	if ok_sub and subrole == AX_URL_SUBROLE then return true end

	-- Layer 2 — Chrome / Brave / Opera: AXIdentifier contains a recognisable pattern
	local ok_id, identifier = pcall(function() return focused:attributeValue("AXIdentifier") end)
	if ok_id and type(identifier) == "string" and identifier ~= "" then
		local id_lower = identifier:lower()
		for _, pattern in ipairs(URL_BAR_ID_PATTERNS) do
			if id_lower:find(pattern, 1, true) then return true end
		end
	end

	-- Layer 3 — Edge / Firefox / Arc: no usable identifier; check the parent hierarchy.
	-- Walk up two levels: input may be directly in the toolbar (Firefox) or wrapped in
	-- an AXGroup inside the toolbar (Chromium / Edge omnibox structure).
	local ok_p, parent = pcall(function() return focused:attributeValue("AXParent") end)
	if ok_p and parent then
		local ok_pr, parent_role = pcall(function() return parent:attributeValue("AXRole") end)
		if ok_pr and parent_role == "AXToolbar" then return true end
		local ok_gp, grandparent = pcall(function() return parent:attributeValue("AXParent") end)
		if ok_gp and grandparent then
			local ok_gr, gp_role = pcall(function() return grandparent:attributeValue("AXRole") end)
			if ok_gr and gp_role == "AXToolbar" then return true end
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
	if ok_fw and fw then
		local ok_app, app = pcall(function() return fw:application() end)
		if ok_app and app then return app end
	end
	return hs.application.frontmostApplication()
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
	if km_utils.is_ignored_window(state.ignored_window_titles, state.ignored_window_patterns) then
		return true
	end

	local front = get_focused_app()

	if secure_field_filter_enabled and is_secure_field_focused(front) then
		Logger.debug(LOG, "Secure field focused — LLM request skipped.")
		return true
	end
	if url_bar_filter_enabled and is_url_bar_focused(front) then
		Logger.debug(LOG, "URL bar focused — LLM request skipped.")
		return true
	end
	if not front then return false end

	local bid  = front:bundleID() or ""
	local path = front:path() or ""
	local name = (front:name() or ""):lower()

	for _, app in ipairs(excluded_apps) do
		local has_path = type(app.appPath) == "string" and app.appPath ~= ""
		local has_bid  = type(app.bundleID) == "string" and app.bundleID ~= ""
		local configured_name = type(app.name) == "string" and app.name:lower() or ""
		local same_name = (not has_path and not has_bid and configured_name ~= ""
			and (configured_name == name
			or name:find(configured_name, 1, true)
			or configured_name:find(name, 1, true)))
		local path_match = has_path and (app.appPath == path)
		local bid_match  = (not has_path and has_bid and app.bundleID == bid)

		if path_match or bid_match or same_name then
			Logger.debug(LOG, "App excluded: '%s' — LLM request skipped.", front:name() or bid)
			return true
		end
	end
	return false
end

return M
