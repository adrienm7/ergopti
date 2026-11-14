--- adapters/secure_field_detector.lua

--- ==============================================================================
--- MODULE: SecureFieldDetector Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the SecureFieldDetector port contract defined in
--- static/ergopti_plus/_shared/core/ports/SecureFieldDetector.spec.js. Wraps hs.axuielement
--- and the shared list of known password-manager app names
--- (_shared/data/secure_apps.json) to detect whether the
--- user is currently focused on a secure text field or a security-sensitive app.
---
--- FEATURES & RATIONALE:
--- 1. AX role detection: macOS exposes AXSecureTextField for password inputs via
---    the Accessibility API; this is the most reliable signal available without
---    reading the actual field content. Both AXRole and AXSubrole are consulted
---    because native AppKit controls carry the marker on the role while
---    WebKit/Blink browsers carry it on the subrole of a plain AXTextField.
--- 2. Known-app guard: some security apps never expose a secure role (e.g. vault
---    unlock screens rendered in WebKit); the shared list, read once and
---    common to the three drivers, provides a second line of defence for those
---    cases: the whole application is secure.
--- 3. Fail-safe returns: an incomplete AX classification is treated as secure so
---    neither local metrics nor LLM requests can capture credentials while a
---    browser replaces its focused element.
--- ==============================================================================

local M = {}

local hs               = hs
local Logger           = require("core.logger.engine.logger")
local AXResponsiveness = require("adapters.accessibility_permission")
local SecureApps       = require("apps.engine.secure_apps")

local LOG = "adapters.secure_field_detector"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- The AX value that marks a password input. Native AppKit controls expose it as
-- the element's AXRole, while WebKit/Blink expose it as the AXSubrole of a plain
-- AXTextField — so both attributes must be tested (see M.isSecureField).
local SECURE_ROLE = "AXSecureTextField"





-- =================================
-- =================================
-- ======= 2/ Internal State =======
-- =================================
-- =================================

-- Cached secure-field verdict for the focused element, populated by refresh().
local _cached_secure = false


--- Resolves a process identifier without letting a native application method
--- escape into an event owner.
--- @param application_or_pid table|userdata|number Application object or PID.
--- @return number|nil pid
local function resolve_pid(application_or_pid)
	if type(application_or_pid) == "number" then return application_or_pid end
	if application_or_pid == nil then return nil end
	local ok, pid = pcall(function() return application_or_pid:pid() end)
	if not ok or type(pid) ~= "number" then return nil end
	return pid
end

--- Reads one attribute of an element; a read the application left unanswered
--- ("Messaging failed", as the tooltip anchor reads it) puts it in the
--- unanswered cooldown. After a wake, loginwindow left both classification
--- reads unanswered (1045 ms), then the AXValueChanged setup and the post-wake
--- focused-window read waited again (1005 ms, field run 2026-11-03): the
--- callers that check the cooldown now skip it instead.
--- @param element userdata|table Accessibility element.
--- @param attribute string Attribute name.
--- @return boolean ok False when the read raised.
--- @return any value Attribute value, or the raised error.
--- @return any detail Native error returned with a nil value.
local function read_attribute(element, attribute)
	local ok, value, detail = pcall(function() return element:attributeValue(attribute) end)
	if ok and value == nil and type(detail) == "string"
		and detail:find(AXResponsiveness.UNANSWERED_ERROR, 1, true)
	then
		local ok_pid, pid = pcall(function() return element:pid() end)
		if ok_pid then AXResponsiveness.mark_unanswered(pid) end
	end
	return ok, value, detail
end





-- ==================================
-- ==================================
-- ======= 3/ Adapter Methods =======
-- ==================================
-- ==================================

--- Classifies one focused accessibility element.
--- AXRole and AXSubrole are one privacy decision: WebKit/Blink expose the secure
--- marker only through AXSubrole, so either read failing leaves the classification
--- uncertain and must fail closed.
--- @param element userdata|table|nil Focused accessibility element.
--- @param observe function|nil Optional completeness callback from these exact reads.
--- @return boolean True for a secure or incompletely classified element.
function M.isElementSecure(element, observe)
	if not element then
		if observe then observe(false) end
		return false
	end
	local ok_role, role = read_attribute(element, "AXRole")
	local ok_sub, subrole, subrole_error = read_attribute(element, "AXSubrole")
	-- Native AX failures return nil plus an error without raising a Lua exception.
	-- Optional nil-only subroles remain valid; a transport refusal is unknown.
	local role_read = ok_role and type(role) == "string" and role ~= ""
	local subrole_read = ok_sub and (type(subrole) == "string" or (subrole == nil and subrole_error == nil))
	if observe then
		local confirmed_secure = (role_read and role == SECURE_ROLE) or (subrole_read and subrole == SECURE_ROLE)
		observe(confirmed_secure or (role_read and subrole_read and type(role) == "string" and role ~= ""
			and (subrole == nil or type(subrole) == "string")))
	end
	if (role_read and role == SECURE_ROLE) or (subrole_read and subrole == SECURE_ROLE) then
		return true
	end
	if not role_read or not subrole_read then
		Logger.debug(LOG,
			"AX secure-field classification incomplete (role_read=%s, subrole_read=%s); suppressing input.",
			tostring(role_read), tostring(subrole_read))
		return true
	end
	return false
end


--- Shares exact inspection reads while retaining confirmed native refusal for refresh.
--- @param application_or_pid table|userdata|number Application object or PID.
--- @param observe function|nil Optional callback receiving completeness and inspected PID.
--- @return boolean|nil secure
--- @return any error_detail
--- @return boolean|nil focus_refused True only for AXFocusedUIElement nil plus error.
local function inspect_focused_element(application_or_pid, observe)
	local pid = resolve_pid(application_or_pid)
	if pid == nil then return nil, "application PID is unavailable" end
	if not (hs.axuielement and hs.axuielement.applicationElementForPID) then
		return nil, "Accessibility element API is unavailable"
	end

	local ok, result, focus_refused, focused_element = pcall(function()
		local app_element = hs.axuielement.applicationElementForPID(pid)
		if not app_element then return nil end
		local focused, focused_error = app_element:attributeValue("AXFocusedUIElement")
		if not focused then return nil, focused == nil and focused_error ~= nil end
		local secure = M.isElementSecure(focused, observe and function(complete) observe(complete, pid) end)
		return secure, nil, focused
	end)
	if not ok then return nil, result end
	if type(result) ~= "boolean" then
		return nil, "focused Accessibility element is unavailable", focus_refused == true
	end
	return result, nil, nil, focused_element
end

--- Classifies the focused element for one exact application.
--- Unlike refresh(), this does not consult frontmostApplication(), so a focused
--- floating panel cannot accidentally inherit the previous application's answer.
--- @param application_or_pid table|userdata|number Application object or PID.
--- @param observe function|nil Optional callback receiving completeness and inspected PID.
--- @return boolean|nil secure Nil means the focused element could not be read.
--- @return any error_detail
--- The private refusal bit never changes this public two-return contract.
function M.inspectFocusedElement(application_or_pid, observe)
	local secure, detail = inspect_focused_element(application_or_pid, observe)
	return secure, detail
end


--- Classifies and returns the exact same focused element for a destination receipt.
--- @param application_or_pid table|userdata|number Application object or PID.
--- @return boolean|nil secure
--- @return any error_detail
--- @return userdata|table|nil element The element that was classified.
function M.inspectFocusedElementWithReceipt(application_or_pid)
	local secure, detail, _, element = inspect_focused_element(application_or_pid)
	return secure, detail, element
end


--- Starts one application-scoped focused-element observer.
--- The returned native owner must be retained and stopped by the caller.
--- @param application_or_pid table|userdata|number Application object or PID.
--- @param on_change function Callback invoked after a focused-element change.
--- @return table|userdata|nil observer
--- @return any error_detail
--- @return boolean|nil committed False only when observer is cleanup debt.
function M.watchFocusedElementChanges(application_or_pid, on_change)
	if type(on_change) ~= "function" then return nil, "focus-change callback is required" end
	local pid = resolve_pid(application_or_pid)
	if pid == nil then return nil, "application PID is unavailable" end
	if not (hs.axuielement and hs.axuielement.observer
		and type(hs.axuielement.observer.new) == "function"
		and type(hs.axuielement.applicationElementForPID) == "function")
	then
		return nil, "Accessibility observer API is unavailable"
	end

	local observer = nil
	local committed = false
	local ok, result = xpcall(function()
		observer = hs.axuielement.observer.new(pid)
		if not observer then error("Accessibility observer construction returned nil", 0) end
		for _, method in ipairs({ "callback", "addWatcher", "start", "stop", "isRunning" }) do
			if type(observer[method]) ~= "function" then
				error("Accessibility observer does not implement " .. method, 0)
			end
		end
		local app_element = hs.axuielement.applicationElementForPID(pid)
		if not app_element then error("Accessibility application element is unavailable", 0) end
		observer:callback(function()
			if not committed then return end
			local callback_ok, callback_err = xpcall(on_change, debug.traceback)
			if not callback_ok then
				Logger.error(LOG, "Focused-element observer callback failed: %s.",
					tostring(callback_err))
			end
		end)
		observer:addWatcher(app_element, "AXFocusedUIElementChanged")
		observer:start()
		if type(observer.isRunning) ~= "function" or observer:isRunning() ~= true then
			error("Accessibility observer did not start", 0)
		end
		return observer
	end, debug.traceback)
	if not ok then
		if observer and type(observer.stop) == "function" then
			local stopped, stop_result = xpcall(function() return observer:stop() end, debug.traceback)
			if not stopped or stop_result == false then
				return observer,
					tostring(result) .. "; Accessibility observer cleanup failed: "
						.. tostring(stop_result),
					false
			end
		end
		return nil, result, false
	end
	committed = true
	return result, nil, true
end

--- Re-reads the focused element and caches its secure-field verdict.
--- Uses applicationElementForPID + AXFocusedUIElement, the stable Hammerspoon API
--- for reaching the focused accessibility element.
--- @param observe function|nil Optional completeness callback after the existing cache update.
function M.refresh(observe)
	assert(observe == nil or type(observe) == "function", "Invalid secure classification observer")
	local complete, inspected_pid = false, nil
	local function clear_cache()
		_cached_secure = false
	end

	local ok, err = pcall(function()
		local app = hs.application.frontmostApplication()
		if not app then clear_cache(); return end
		local secure, _, focus_refused = inspect_focused_element(app, observe and function(known, pid)
			complete, inspected_pid = known, pid
		end)
		if secure == nil then
			-- Native AX errors return nil plus an error; nil alone means no focus.
			_cached_secure = focus_refused == true
			return
		end
		_cached_secure = secure
	end)

	if not ok then
		Logger.debug(LOG, "refresh(): axuielement unavailable — %s", tostring(err))
		clear_cache()
		complete = false
	end
	-- Optional evidence follows the exact existing reads and cache assignment.
	-- The default path has no observer and retains its nil/void return contract.
	if observe then observe(complete, inspected_pid) end
end

--- Returns true if the currently focused element is a secure text field.
--- Both attributes are tested because the two UI toolkits disagree on where the
--- secure marker lives: native AppKit sets AXRole = AXSecureTextField, whereas
--- WebKit/Blink report AXRole = AXTextField and demote the marker to AXSubrole.
--- Testing the role alone therefore fails OPEN on every Chrome/Edge/Brave/Arc
--- login form, letting the keystats record the user's password characters.
--- @return boolean True when the cached element is secure or classification was incomplete.
function M.isSecureField()
	return _cached_secure
end

--- Returns true if the given app ID belongs to a known security-sensitive app.
--- @param appId string|nil The application name to check.
--- @return boolean True when appId is a macOS name of the shared list.
function M.isSecureApp(appId)
	if appId == nil or appId == "" then return false end
	return SecureApps.is_secure_app("macos", tostring(appId))
end

return M
