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

-- Key names hs.keycodes.map gives the modifier keys and Caps Lock. macOS reports
-- these keys only as flag changes, never as a key down, so a hotkey whose key is
-- one of them registers without complaint and can never fire. The chord grammar
-- already refuses the neutral modifier names; the lateral ones reach this set.
local MODIFIER_KEY_NAMES = {
	cmd = true, rightcmd = true, alt = true, rightalt = true,
	ctrl = true, rightctrl = true, shift = true, rightshift = true,
	fn = true, capslock = true,
}





-- =====================================
-- =====================================
-- ======= 1/ Handle Bookkeeping =======
-- =====================================
-- =====================================

-- Live bindings keyed by handle token. The token is what callers hold; the hs
-- object never leaves this file, so there is exactly one code path that can
-- delete a hotkey and exactly one place a leak could come from.
local _bindings = {}
local _physical_claims = {}
-- Only conditionals actually suspended by a claim transaction may be restored.
local _claim_suspensions = {}
local _claim_transaction = false
local set_enabled

-- Monotonic token source. Tokens are never reused, so a handle from a released
-- binding stays permanently unknown instead of silently addressing a later one.
local _next_token = 0

-- Process-wide delivery policy injected by the shortcuts lifecycle. Native
-- hotkeys can remain registered during pause (UI shortcuts are not owned by the
-- bindings subsystem), so every adapter-owned callback re-checks this live gate.
local _delivery_guard = function() return true end

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

--- Reports whether a chord key names a modifier key, which never fires a hotkey.
--- @param key any Chord key in any spelling.
--- @return boolean modifier
function M.key_is_modifier(key)
	return type(key) == "string" and MODIFIER_KEY_NAMES[key:lower()] == true
end

--- Registers a system-wide chord against a callback.
--- @param chord string Canonical chord string, e.g. "Ctrl+Shift+S".
--- @param callback function Invoked with no arguments on each press.
--- @return string|nil handle An opaque handle, or nil when the chord was refused.
local function bind_native(chord, callback, native_key, conditional)
	if type(callback) ~= "function" then
		Logger.error(LOG, "bind(): callback must be a function, got %s.", type(callback))
		return nil
	end

	local parsed, err = Chord.parse(chord)
	if not parsed then
		Logger.error(LOG, "bind(): refusing '%s' — %s.", tostring(chord), tostring(err))
		return nil
	end
	if M.key_is_modifier(parsed.key) then
		Logger.error(LOG, "bind(): refusing '%s' — its key is a modifier key, which never fires a hotkey.",
			tostring(chord))
		return nil
	end

	-- Hammerspoon resolves key names to physical scancodes at bind time and
	-- expects the key in the spelling the OS uses, which is the lower-cased form
	-- the notation core already produces for multi-character names.
	local hs_key = native_key or parsed.key:lower()
	local identity = M.physical_identity(parsed.mods, hs_key)
	if conditional and (identity == nil or M.physical_claims()[identity] ~= nil) then
		return nil
	end
	local suspended = {}
	if not conditional and identity then
		for handle, owned in pairs(_bindings) do
			if owned.conditional and owned.identity == identity and owned.enabled then
				if M.setEnabled(handle, false) ~= true then return nil end
				suspended[#suspended + 1] = handle
			end
		end
	end
	-- Keep a Lua-side delivery fence in front of the native callback. Native
	-- :disable()/:delete() can raise during teardown; without this independent
	-- fence, a retained Hammerspoon hotkey could still execute an Ergopti action
	-- after the owning feature had reported itself disabled.
	local entry = {
		hotkey = nil,
		chord = type(hs_key) == "number" and ("native " .. identity) or Chord.format(parsed.mods, parsed.key),
		enabled = true,
		native_settled = true,
		identity = identity,
		conditional = conditional == true,
	}
	local function deliver_if_enabled(...)
		if entry.enabled ~= true then return nil end
		local guard_ok, allowed_or_err = xpcall(_delivery_guard, debug.traceback)
		if not guard_ok then
			Logger.error(LOG, "Delivery guard raised for %s — callback denied: %s.",
				entry.chord, tostring(allowed_or_err))
			return nil
		end
		if allowed_or_err ~= true then return nil end

		local args = table.pack(...)
		local callback_ok, result_or_err = xpcall(function()
			return callback(table.unpack(args, 1, args.n))
		end, debug.traceback)
		if not callback_ok then
			Logger.error(LOG, "Hotkey callback raised for %s: %s.",
				entry.chord, tostring(result_or_err))
			return nil
		end
		return result_or_err
	end

	local ok, hotkey = pcall(hs.hotkey.bind, parsed.mods, hs_key, deliver_if_enabled)
	if not ok or not hotkey then
		for _, handle in ipairs(suspended) do M.setEnabled(handle, true) end
		Logger.warn(LOG, "bind(): the OS refused '%s' — %s.", tostring(chord), tostring(hotkey))
		return nil
	end

	local handle = next_handle()
	entry.hotkey = hotkey
	_bindings[handle] = entry
	Logger.debug(LOG, "Bound %s → %s.", _bindings[handle].chord, handle)
	return handle
end

--- Resolves a modifier set and native key to one physical acquisition identity.
--- @param mods table Canonical modifier array.
--- @param key string|number Native key name or proven virtual keycode.
--- @return string|nil identity
function M.physical_identity(mods, key)
	local code = key
	if type(code) == "string" then code = hs.keycodes.map[code:lower()] end
	if type(code) ~= "number" or code % 1 ~= 0 or code < 0 or code > 127 then return nil end
	local parsed = Chord.parse(Chord.format(mods, "a"))
	if not parsed then return nil end
	return table.concat(parsed.mods, "+") .. ":" .. tostring(code)
end

--- Replaces one owner's explicit claims, including chords assigned to none.
--- @param owner string Stable assignment owner.
--- @param rows table[] Canonical chord, action and binding identifier records.
--- @return boolean committed
function M.replace_physical_claims(owner, rows)
	assert(type(owner) == "string" and owner ~= "", "physical claim owner is required")
	if _claim_transaction then return false end
	local claims = {}
	for _, row in ipairs(rows) do
		local mods, key
		if row.native_code ~= nil then
			assert(type(row.mods) == "table" and row.chord == nil, "physical native claim is invalid")
			mods, key = row.mods, row.native_code
		else
			local parsed = assert(Chord.parse(row.chord), "physical claim chord is invalid")
			mods, key = parsed.mods, parsed.key
		end
		local identity = M.physical_identity(mods, key)
		if identity then claims[identity] = { action = row.action, binding_id = row.binding_id } end
	end
	local previous = _physical_claims[owner]
	local suspended_before, touched = {}, {}
	for handle, claimant in pairs(_claim_suspensions) do suspended_before[handle] = claimant end
	_claim_transaction = true
	local function transition(handle, want)
		local entry = _bindings[handle]
		if touched[handle] == nil then
			touched[handle] = { enabled = entry.enabled, generation = entry.claim_generation or 0 }
		end
		local acknowledged = set_enabled(handle, want, true)
		return acknowledged == true and _bindings[handle] == entry
			and (entry.claim_generation or 0) == touched[handle].generation
	end
	local function refuse()
		_physical_claims[owner] = previous
		for handle, before in pairs(touched) do
			local entry = _bindings[handle]
			if entry and (entry.claim_generation or 0) == before.generation then
				if set_enabled(handle, before.enabled, true) ~= true and before.enabled then
					-- Failed compensation stays fenced and retains an exact retry receipt.
					suspended_before[handle] = owner
				end
			end
		end
		for handle in pairs(_claim_suspensions) do
			if touched[handle] then _claim_suspensions[handle] = nil end
		end
		for handle, claimant in pairs(suspended_before) do
			local entry = _bindings[handle]
			local before = touched[handle]
			if entry and (not before or (entry.claim_generation or 0) == before.generation) then
				_claim_suspensions[handle] = claimant
			end
		end
		_claim_transaction = false
		return false
	end
	for handle, entry in pairs(_bindings) do
		if entry.conditional and claims[entry.identity]
			and (entry.enabled or entry.native_settled ~= true) then
			if entry.enabled then _claim_suspensions[handle] = owner end
			if not transition(handle, false) then return refuse() end
		end
	end
	_physical_claims[owner] = claims
	local remaining = M.physical_claims()
	local restored = {}
	for handle in pairs(_claim_suspensions) do
		local entry = _bindings[handle]
		if not entry then restored[#restored + 1] = handle
		elseif remaining[entry.identity] == nil then
			if not transition(handle, true) then return refuse() end
			restored[#restored + 1] = handle
		end
	end
	for _, handle in ipairs(restored) do _claim_suspensions[handle] = nil end
	_claim_transaction = false
	return true
end

--- Checks every owner independently so merged-map order cannot hide a collision.
--- Only the caller's exact assignment is exempt; conditional recommendations yield.
function M.has_physical_conflict(mods, native_code, owner, binding_id)
	local identity = M.physical_identity(mods, native_code)
	if identity == nil then return true end
	for claimant, rows in pairs(_physical_claims) do
		local row = rows[identity]
		if row and (claimant ~= owner or row.binding_id ~= binding_id) then return true end
	end
	for _, entry in pairs(_bindings) do
		if entry.identity == identity and not entry.conditional then return true end
	end
	return false
end

--- Reads all explicit native claims independently from conditional bindings.
--- @return table claims Physical identity to explicit assignment metadata.
function M.physical_claims()
	local claims = {}
	for _, rows in pairs(_physical_claims) do
		for identity, row in pairs(rows) do claims[identity] = row end
	end
	for handle, entry in pairs(_bindings) do
		if entry.identity and not entry.conditional then
			claims[entry.identity] = { action = "explicit", binding_id = handle }
		end
	end
	return claims
end

--- Registers an ordinary named chord through the common native owner.
--- @param chord string Canonical chord.
--- @param callback function Delivery callback.
--- @return string|nil handle
function M.bind(chord, callback)
	return bind_native(chord, callback)
end

--- Acquires a proven numeric source without resolving its displayed glyph.
--- @param mods table Canonical modifiers.
--- @param code number Proven native virtual keycode.
--- @param callback function Delivery callback.
--- @return string|nil handle
function M.bind_conditional(mods, code, callback)
	if type(code) ~= "number" or M.physical_identity(mods, code) == nil then return nil end
	return bind_native(Chord.format(mods, "a"), callback, code, true)
end

--- Installs the live process-wide delivery predicate for adapter-owned hotkeys.
--- The default allows delivery so the port remains usable before lifecycle
--- wiring; production injects the canonical script-pause predicate at boot.
--- @param guard function Predicate returning true when callbacks may run.
--- @return boolean True when the guard was accepted.
function M.set_delivery_guard(guard)
	if type(guard) ~= "function" then
		Logger.error(LOG, "set_delivery_guard(): guard must be a function, got %s.", type(guard))
		return false
	end
	_delivery_guard = guard
	return true
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

	-- Close delivery before touching the native object. This assignment cannot
	-- fail, so even a double native failure remains a fail-closed no-op.
	_claim_suspensions[handle] = nil
	entry.claim_generation = (entry.claim_generation or 0) + 1
	entry.enabled = false
	local ok, err = pcall(function() entry.hotkey:delete() end)
	if not ok then
		-- Keep the opaque handle retryable. Forgetting it here leaves a globally
		-- captured chord with no remaining owner capable of deleting it. Disable is
		-- a fail-safe best effort so personal bindings are not intercepted while a
		-- later teardown retries the actual delete.
		local disabled_ok, disable_err = pcall(function() entry.hotkey:disable() end)
		entry.native_settled = disabled_ok
		Logger.error(LOG, "unbind(): %s failed to release — %s; retained for retry (disabled=%s%s).",
			entry.chord,
			tostring(err),
			tostring(disabled_ok),
			disabled_ok and "" or ", disable error=" .. tostring(disable_err))
		return false
	end

	_bindings[handle] = nil
	Logger.debug(LOG, "Released %s (%s).", entry.chord, tostring(handle))
	return true
end

--- Suspends or resumes a binding without releasing it.
--- @param handle string A handle previously returned by M.bind().
--- @param enabled boolean Desired state.
--- @return boolean true if the handle now holds the requested state.
set_enabled = function(handle, enabled, preserve_claim_suspension)
	local entry = _bindings[handle]
	if not entry then
		Logger.debug(LOG, "setEnabled(): no live binding for %s.", tostring(handle))
		return false
	end

	local want = enabled and true or false
	if not preserve_claim_suspension then
		entry.claim_generation = (entry.claim_generation or 0) + 1
		if not want then _claim_suspensions[handle] = nil end
	end
	if want and entry.conditional and M.physical_claims()[entry.identity] ~= nil then return false end
	if entry.enabled == want and entry.native_settled == true then return true end

	-- Disabling must become effective at the adapter boundary before the native
	-- call. If Hammerspoon raises, delivery stays fenced while native_settled=false
	-- keeps a later call retryable.
	if not want then entry.enabled = false end

	local ok, native_result = pcall(function()
		if want then return entry.hotkey:enable() end
		return entry.hotkey:disable()
	end)
	-- Hammerspoon returns the hotkey object on enable/disable. In particular,
	-- enable() returns nil when activation was refused; pcall success alone is
	-- therefore not evidence that the global shortcut became live.
	if not ok or native_result == nil or native_result == false then
		entry.native_settled = false
		Logger.error(LOG, "setEnabled(): %s failed to reach %s — %s.", entry.chord, tostring(want), tostring(native_result))
		return false
	end

	entry.enabled = want
	entry.native_settled = true
	Logger.debug(LOG, "%s enabled=%s.", entry.chord, tostring(want))
	return true
end

function M.setEnabled(handle, enabled)
	return set_enabled(handle, enabled, false)
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
