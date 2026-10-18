--- ui/menu/magic_key_source_menu.lua

--- ==============================================================================
--- MODULE: Physical Magic Key Menu (macOS)
--- DESCRIPTION:
--- The `magic_key_source` list of the keyboard-layout menu: one row naming the
--- physical key that types the magic key, whose submenu captures the next key
--- pressed, restores the automatic key or lists every candidate. The rows are
--- the shared ones (_shared/lua/keymap/magic_key_source.lua), which Linux draws
--- too.
---
--- FEATURES & RATIONALE:
--- 1. Labels the user can read: each candidate shows what the active input
---    source types on that key, then its KeyboardEvent.code.
--- 2. Capture through a keyDown event tap of its own, alive for one press: the
---    key is identified by keycode, so the character it types does not matter.
---    Escape or the shared timeout (timings [ui] magic_key_capture_timeout_ms)
---    ends it with nothing changed. The tap and its timer are pinned until the
---    capture ends, and Ergopti's own synthetic output never answers it.
--- 3. Persisted before applied, and outside the tap: the choice is handed to
---    the next run-loop turn, and a refused save leaves both the file and the
---    running key as they were.
--- ==============================================================================

local M = {}

local hs              = hs
local Logger          = require("infra.logger")
local i18n            = require("infra.i18n")
local Keycodes        = require("infra.keycodes")
local Notifications   = require("infra.notifications")
local Timings         = require("infra.timings")
local Timer           = require("adapters.timer_scheduler")
local EventProvenance = require("adapters.event_provenance")
local Shared          = require("keymap.magic_key_source")
local ManifestMenu    = require("infra.manifest_menu")
local Source          = require("modules.keymap.magic_key_source")
local Geometry        = require("adapters.keyboard_geometry")

local LOG = "menu.magic_key_source"

-- The event-provenance consumer name of the capture tap.
local CONSUMER = "menu.magic_key_capture"

-- The live capture, pinned so neither its tap nor its timer is collected while
-- it waits: { tap, timer }. One at a time.
local _capture = nil





-- ===========================
-- ===========================
-- ======= 1/ Choosing =======
-- ===========================
-- ===========================

--- Persists, then applies one value.
--- @param ctx table { state, save_prefs, keymap, update_menu }
--- @param value string A candidate code or the automatic value.
--- @return boolean committed
function M.choose(ctx, value)
	local reason = Source.choice_reason(value)
	if reason ~= nil then
		Notifications.notify(i18n.get("dialog.magic_key_source.title"), i18n.get(reason), "warning")
		return false
	end
	local previous = ctx.state.magic_key_source
	ctx.state.magic_key_source = value
	if type(ctx.save_prefs) ~= "function" or ctx.save_prefs() ~= true then
		ctx.state.magic_key_source = previous
		Logger.error(LOG, "The physical magic key %s was not saved — nothing changed.", tostring(value))
		return false
	end
	ctx.keymap.set_magic_key_source(value)
	Logger.info(LOG, "Physical magic key chosen: %s.", tostring(value))
	if type(ctx.update_menu) == "function" then ctx.update_menu() end
	return true
end

--- What the active input source types on a keycode, nil when it cannot tell.
--- @param keycode number
--- @return string|nil
local function key_text(keycode)
	local map = hs and hs.keycodes and hs.keycodes.map
	local text = type(map) == "table" and map[keycode] or nil
	-- The map names the keys that type no character ("space", "f5"): only a
	-- single character is a label.
	if type(text) == "string" and utf8.len(text) == 1 then return text end
	return nil
end





-- ==========================
-- ==========================
-- ======= 2/ Capture =======
-- ==========================
-- ==========================

--- Retires one retained timer only after its native cancellation is acknowledged.
--- @param live table Capture owner.
--- @param member string Exact timer slot.
--- @return boolean settled
local function stop_capture_timer(live, member)
	local handle = live[member]
	if handle == nil then return true end
	local called, stopped = pcall(Timer.cancel, handle)
	if called and stopped == true then
		live[member] = nil
		return true
	end
	Logger.error(LOG, "The capture %s timer remains owned after cancellation refused: %s.",
		member, tostring(stopped))
	return false
end

--- Fences one capture before attempting exact native retirement. Refused
--- handles keep the owner pinned and prevent a successor from being acquired.
--- @param live table The capture being ended.
--- @return boolean ended True only after all native resources retired.
local function stop_capture(live)
	if _capture ~= live then return false end
	live.active, live.retiring, live.answered = false, true, true
	local timers_stopped = stop_capture_timer(live, "answer_timer")
	timers_stopped = stop_capture_timer(live, "timer") and timers_stopped
	local tap_stopped = live.tap == nil
	if live.tap ~= nil then
		local called, stopped = pcall(function() return live.tap:stop() end)
		local observed, enabled = pcall(function() return live.tap:isEnabled() end)
		tap_stopped = called and stopped ~= nil and stopped ~= false and observed and enabled == false
		if tap_stopped then
			live.tap = nil
		else
			Logger.error(LOG, "The capture tap remains owned after retirement refused: %s.",
				tostring(not called and stopped or enabled))
		end
	end
	if not timers_stopped or not tap_stopped then return false end
	_capture = nil
	return true
end

--- Reads only the already-loaded script-control owner, never a menu snapshot.
--- @return table|nil owner Exact pause-state provider.
--- @return integer|nil epoch Settled active generation.
local function capture_pause_source()
	local owner = package.loaded["modules.shortcuts.script_control"]
	if type(owner) ~= "table" or type(owner.is_paused) ~= "function"
		or type(owner.is_pause_transition_pending) ~= "function" or type(owner.get_pause_epoch) ~= "function" then
		return nil
	end
	local observed, paused, pending, epoch = pcall(function()
		return owner.is_paused(), owner.is_pause_transition_pending(), owner.get_pause_epoch()
	end)
	if not observed or paused ~= false or pending ~= false or type(epoch) ~= "number"
		or epoch < 0 or epoch % 1 ~= 0 then return nil end
	return owner, epoch
end

--- Whether the original active generation still owns this captured choice.
--- @param live table Capture owner.
--- @return boolean current
local function capture_pause_current(live)
	local owner, epoch = capture_pause_source()
	return owner ~= nil and owner == live.pause_owner and epoch == live.pause_epoch
end

--- Captures the next physical key pressed as the physical magic key.
--- @param ctx table The menu context of M.choose.
--- @return boolean started
function M.capture(ctx)
	if _capture ~= nil then
		if _capture.retiring ~= true or not stop_capture(_capture) then
			Logger.debug(LOG, "A capture is active or still owns native retirement debt.")
			return false
		end
	end
	local pause_owner, pause_epoch = capture_pause_source()
	if pause_owner == nil then
		Logger.error(LOG, "Physical magic key capture refused without a settled active script state.")
		return false
	end
	Source.resolver() -- Warm the registry before the event callback.
	local live = { answered = false, active = false, pause_owner = pause_owner, pause_epoch = pause_epoch }
	_capture = live -- Own every candidate before construction or activation.
	local function settle(keycode, keyboard_type)
		local current = capture_pause_current(live)
		if not stop_capture(live) then return end
		if keycode ~= nil and (not current or not capture_pause_current(live)) then
			Logger.info(LOG, "Physical magic key capture crossed a pause boundary: nothing changed.")
			return
		end
		if keycode == nil then
			Logger.info(LOG, "Physical magic key capture ended with no key: nothing changed.")
			return
		end
		local code = Source.code_for(keycode, keyboard_type)
		if code == nil then
			Logger.warn(LOG, "Keycode %s cannot type the magic key.", tostring(keycode))
			Notifications.notify(i18n.get("dialog.magic_key_source.title"),
				i18n.get("dialog.magic_key_source.not_a_candidate"), "warning")
			return
		end
		M.choose(ctx, code)
	end

	local constructed, tap = pcall(hs.eventtap.new, { hs.eventtap.event.types.keyDown }, function(event)
		local provenance, status, fence = EventProvenance.classify_with_fence(event, CONSUMER)
		local fence_events = fence and fence.events or nil
		if fence and fence.consume_original == true then return true, fence_events end
		if _capture ~= live or live.active ~= true then return false, fence_events end
		if not capture_pause_current(live) then
			stop_capture(live)
			return false, fence_events
		end
		if live.answered or provenance ~= nil or status == EventProvenance.STATUS_UNREADABLE then
			return false, fence_events
		end
		local keycode = event:getKeyCode()
		local keyboard_type = Geometry.event_type(event)
		local candidate = Source.code_for(keycode, keyboard_type)
		local premature, committed = false, false
		local called, handle, accepted = pcall(Timer.after, 0, function()
			if committed ~= true then premature = true return end
			if _capture ~= live or live.active ~= true then return end
			settle(keycode ~= Keycodes.ESCAPE and keycode or nil, keyboard_type)
		end)
		if type(handle) == "table" then live.answer_timer = handle end
		if not called or accepted ~= true or type(handle) ~= "table" or handle.fired == true or premature then
			Logger.error(LOG, "The captured key could not be scheduled — nothing changed.")
			if not stop_capture_timer(live, "answer_timer") then stop_capture(live) end
			return false, fence_events
		end
		if not capture_pause_current(live) then
			stop_capture(live)
			return false, fence_events
		end
		committed, live.answered = true, true
		-- Consumption belongs only to an acknowledged deferred selection.
		return keycode == Keycodes.ESCAPE or candidate ~= nil, fence_events
	end)
	if not constructed or (type(tap) ~= "table" and type(tap) ~= "userdata") then
		Logger.error(LOG, "The physical magic key capture tap could not be constructed.")
		stop_capture(live)
		return false
	end
	live.tap = tap
	local premature = false
	local timed, timer, admitted = pcall(Timer.after, Timings.sec("ui", "magic_key_capture_timeout_ms"), function()
		if live.active ~= true then premature = true return end
		settle(nil)
	end)
	if type(timer) == "table" then live.timer = timer end
	if not timed or admitted ~= true or type(timer) ~= "table" or timer.fired == true or premature then
		Logger.error(LOG, "The capture timeout could not be armed — no key is captured.")
		stop_capture(live)
		return false
	end
	local started, result = pcall(function() return tap:start() end)
	local observed, enabled = pcall(function() return tap:isEnabled() end)
	if not started or not result or not observed or enabled ~= true or premature or not capture_pause_current(live) then
		Logger.error(LOG, "The physical magic key capture tap could not be activated.")
		stop_capture(live)
		return false
	end
	live.active = true
	Notifications.notify(i18n.get("dialog.magic_key_source.title"),
		i18n.get("dialog.magic_key_source.prompt"), "info")
	Logger.info(LOG, "Waiting for the physical magic key…")
	return true
end

--- Whether a capture waits for a key (test and diagnostics seam).
--- @return boolean
function M.capturing()
	return _capture ~= nil
end





-- ============================
-- ============================
-- ======= 3/ Menu rows =======
-- ============================
-- ============================

--- The `magic_key_source` list rows.
--- @param ctx table { state, save_prefs, keymap, update_menu, paused }
--- @return table rows
function M.rows(ctx)
	local resolver = Source.resolver()
	return Shared.menu_rows(resolver, {
		manifest = ManifestMenu,
		t = i18n.get,
		current = Source.get(),
		reason = Source.choice_reason,
		key_text = function(code)
			local native = resolver.native(code)
			-- Without an originating model, a swapped glyph could name its neighbor.
			if Source.code_for(native, nil) ~= code then return nil end
			return key_text(native)
		end,
		choose = function(value) M.choose(ctx, value) end,
		capture = ctx.paused ~= true and function() M.capture(ctx) end or nil,
	})
end

return M
