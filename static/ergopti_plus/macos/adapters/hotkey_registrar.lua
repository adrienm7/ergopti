--- adapters/hotkey_registrar.lua

--- ==============================================================================
--- MODULE: Hotkey Registrar Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the HotkeyRegistrar port contract defined in
--- static/ergopti_plus/_shared/core/ports/HotkeyRegistrar.spec.js. Wraps
--- hs.hotkey.bind so that "register a system-wide chord" is one call the caller
--- can make without knowing that Hammerspoon wants a modifier ARRAY and a
--- separate key, or that its handle is an object carrying :enable/:disable/:delete.
---
--- Before this adapter existed, three modules called hs.hotkey.bind directly and
--- each rebuilt its own idea of what a chord looks like. The OS call now happens
--- in exactly one file, which is the whole point of the adapters layer.
---
--- FEATURES & RATIONALE:
--- 1. Canonical chords only: every chord is parsed by the shared notation core
---    before it reaches Hammerspoon, so "shift+ctrl+s" and "Ctrl+Shift+S" produce
---    ONE registration rather than two live bindings that both fire.
--- 2. Handles are opaque tokens, not hs objects: the port promises the caller
---    nothing about the handle's shape, and returning the hs object would invite
---    callers to reach past the adapter for :delete(). A token also lets unbind()
---    answer honestly for a handle it has already released.
--- 3. Refusal is a return value: an unparseable chord never reaches the OS, and a
---    chord Hammerspoon rejects yields nil. A hotkey the user's other software has
---    already claimed is an ordinary fact the menu must be able to display.
--- ==============================================================================

local M = {}

local hs     = hs
local Chord  = require("chord")
local Logger = require("infra.logger")

local LOG = "adapters.hotkey_registrar"





-- =====================================
-- =====================================
-- ======= 1/ Handle Bookkeeping =======
-- =====================================
-- =====================================

-- Live bindings keyed by handle token. The token is what callers hold; the hs
-- object never leaves this file, so there is exactly one code path that can
-- delete a hotkey and exactly one place a leak could come from.
local _bindings = {}

-- Monotonic token source. Tokens are never reused, so a handle from a released
-- binding stays permanently unknown instead of silently addressing a later one.
local _next_token = 0

--- Issues the next handle token.
--- @return string A token unique for the lifetime of this Lua state.
local function next_handle()
	_next_token = _next_token + 1
	return "hotkey#" .. tostring(_next_token)
end





-- ==================================
-- ==================================
-- ======= 2/ Adapter Methods =======
-- ==================================
-- ==================================

--- Registers a system-wide chord against a callback.
--- @param chord string Canonical chord string, e.g. "Ctrl+Shift+S".
--- @param callback function Invoked with no arguments on each press.
--- @return string|nil handle An opaque handle, or nil when the chord was refused.
function M.bind(chord, callback)
	if type(callback) ~= "function" then
		Logger.error(LOG, "bind(): callback must be a function, got %s.", type(callback))
		return nil
	end

	local parsed, err = Chord.parse(chord)
	if not parsed then
		Logger.error(LOG, "bind(): refusing '%s' — %s.", tostring(chord), tostring(err))
		return nil
	end

	-- Hammerspoon resolves key names to physical scancodes at bind time and
	-- expects the key in the spelling the OS uses, which is the lower-cased form
	-- the notation core already produces for multi-character names.
	local hs_key = parsed.key:lower()

	local ok, hotkey = pcall(hs.hotkey.bind, parsed.mods, hs_key, callback)
	if not ok or not hotkey then
		Logger.warn(LOG, "bind(): the OS refused '%s' — %s.", tostring(chord), tostring(hotkey))
		return nil
	end

	local handle = next_handle()
	_bindings[handle] = { hotkey = hotkey, chord = Chord.format(parsed.mods, parsed.key), enabled = true }
	Logger.debug(LOG, "Bound %s → %s.", _bindings[handle].chord, handle)
	return handle
end

--- Releases a binding.
--- @param handle string A handle previously returned by M.bind().
--- @return boolean true if a live binding was released, false otherwise.
function M.unbind(handle)
	local entry = _bindings[handle]
	if not entry then
		-- Not an error: teardown paths unbind defensively and a second call must
		-- report "nothing to do" rather than raise mid-reload.
		Logger.debug(LOG, "unbind(): no live binding for %s.", tostring(handle))
		return false
	end

	_bindings[handle] = nil
	local ok, err = pcall(function() entry.hotkey:delete() end)
	if not ok then
		Logger.error(LOG, "unbind(): %s failed to release — %s.", entry.chord, tostring(err))
		return false
	end

	Logger.debug(LOG, "Released %s (%s).", entry.chord, tostring(handle))
	return true
end

--- Suspends or resumes a binding without releasing it.
--- @param handle string A handle previously returned by M.bind().
--- @param enabled boolean Desired state.
--- @return boolean true if the handle now holds the requested state.
function M.setEnabled(handle, enabled)
	local entry = _bindings[handle]
	if not entry then
		Logger.debug(LOG, "setEnabled(): no live binding for %s.", tostring(handle))
		return false
	end

	local want = enabled and true or false
	if entry.enabled == want then return true end

	local ok, err = pcall(function()
		if want then entry.hotkey:enable() else entry.hotkey:disable() end
	end)
	if not ok then
		Logger.error(LOG, "setEnabled(): %s failed to reach %s — %s.", entry.chord, tostring(want), tostring(err))
		return false
	end

	entry.enabled = want
	Logger.debug(LOG, "%s enabled=%s.", entry.chord, tostring(want))
	return true
end





-- ================================
-- ================================
-- ======= 3/ Introspection =======
-- ================================
-- ================================

--- Reports the canonical chord a handle is bound to.
--- Exists so the menu can label a binding without holding the chord string it
--- passed in, which may have been in any accepted spelling.
--- @param handle string
--- @return string|nil The canonical chord, or nil when the handle is unknown.
function M.chord_of(handle)
	local entry = _bindings[handle]
	return entry and entry.chord or nil
end

--- Reports how many bindings this adapter currently holds.
--- A leak here is invisible in the UI — the hotkeys keep firing — so the count is
--- exposed for the suite to assert against after a stop/start cycle.
--- @return number
function M.live_count()
	local n = 0
	for _ in pairs(_bindings) do n = n + 1 end
	return n
end

return M
