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
local Source          = require("modules.keymap.magic_key_source")

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

--- Ends one capture: stops its tap and timer and releases the pin. A stale
--- timer or a second press of an ended capture changes nothing.
--- @param live table The capture being ended.
--- @return boolean ended True when `live` was the capture in progress.
local function stop_capture(live)
	if _capture ~= live then return false end
	_capture = nil
	if live.timer then Timer.cancel(live.timer) end
	if live.tap then
		local ok, err = pcall(function() live.tap:stop() end)
		if not ok then Logger.error(LOG, "The capture tap could not be stopped: %s.", tostring(err)) end
	end
	return true
end

--- Captures the next physical key pressed as the physical magic key.
--- @param ctx table The menu context of M.choose.
--- @return boolean started
function M.capture(ctx)
	if _capture then
		Logger.debug(LOG, "A capture is already waiting for a key.")
		return false
	end
	local resolver = Source.resolver()
	local live = { answered = false }
	local function settle(keycode)
		if not stop_capture(live) then return end
		if keycode == nil then
			Logger.info(LOG, "Physical magic key capture ended with no key: nothing changed.")
			return
		end
		local code = resolver.code_for(keycode)
		if code == nil then
			Logger.warn(LOG, "Keycode %s cannot type the magic key.", tostring(keycode))
			Notifications.notify(i18n.get("dialog.magic_key_source.title"),
				i18n.get("dialog.magic_key_source.not_a_candidate"), "warning")
			return
		end
		M.choose(ctx, code)
	end

	live.tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
		local provenance, status, fence = EventProvenance.classify_with_fence(event, CONSUMER)
		local fence_events = fence and fence.events or nil
		if fence and fence.consume_original == true then return true, fence_events end
		-- Ergopti's own output, an unreadable event and every key after the answer
		-- pass through untouched.
		if provenance ~= nil or status == EventProvenance.STATUS_UNREADABLE or live.answered then
			return false, fence_events
		end
		live.answered = true
		local keycode = event:getKeyCode()
		-- Decided on the next run-loop turn: saving the choice is file work, which
		-- must not run inside an event tap.
		Timer.after(0, function() settle(keycode ~= Keycodes.ESCAPE and keycode or nil) end)
		return true, fence_events
	end)
	live.timer = Timer.after(Timings.sec("ui", "magic_key_capture_timeout_ms"), function() settle(nil) end)
	_capture = live
	live.tap:start()
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
		t = i18n.get,
		current = Source.get(),
		reason = Source.choice_reason,
		key_text = function(code) return key_text(resolver.native(code)) end,
		choose = function(value) M.choose(ctx, value) end,
		capture = ctx.paused ~= true and function() M.capture(ctx) end or nil,
	})
end

return M
