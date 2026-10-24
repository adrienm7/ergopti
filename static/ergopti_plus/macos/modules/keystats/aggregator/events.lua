--- modules/keystats/aggregator/events.lua

--- ==============================================================================
--- MODULE: Aggregator Events — Walk Functions
--- DESCRIPTION:
--- Implements the JSONL event walkers (walk_typing, walk_app_switch,
--- walk_window_switch, walk_system_event) that replay per-keystroke data into
--- the per-tick accumulator managed by aggregator/core.lua.
---
--- All mutable state is accessed through aggregator/state.lua (S) and all
--- helper utilities are delegated to aggregator/core.lua (C) so that each
--- sub-module owns a clearly-bounded responsibility.
---
--- The typing, app-switch and window-switch walks are the shared walker's
--- (_shared/lua/keystats/walker.lua); the system events below stay here
--- because their physical and media channels are macOS producers.
---
--- MIRRORS: windows/modules/keystats/keystats_walker_events.ahk
--- ==============================================================================

local M = {}

local S = require("modules.keystats.aggregator.state")
local C = require("modules.keystats.aggregator.core")
local Physical = require("modules.keystats.aggregator.physical")
local Walker = require("keystats.walker")





-- ================================
-- ================================
-- ======= 1/ Typing Walker =======
-- ================================
-- ================================

--- Replays a typing entry's per-keystroke array into S.agg_batch through the
--- shared walker (_shared/lua/keystats/walker.lua), the walk Linux runs too.
--- An entry without its own time of day bins to the moment it is walked, as
--- the Windows walker does.
--- @param entry table The decoded typing JSONL entry.
function M.walk_typing(entry)
	if not C.require_init("walk_typing") then return end
	C.ensure_batch()
	if type(entry.events) ~= "table" then return end
	local app = entry.app or "Unknown"
	local timestamp = type(entry.timestamp) == "string" and entry.timestamp or nil
	local slot = Walker.timestamp_slot(timestamp)
	if not slot then
		local hour, minute = os.date("%H"), tonumber(os.date("%M"))
		slot = { hour = hour, min5 = string.format("%s:%02d", hour, math.floor(minute / 5) * 5) }
	end
	C.walker.walk_typing(S.agg_batch, C.get_app_ctx(app), {
		app = app,
		date = timestamp and timestamp:sub(1, 10) or C.today(),
		events = entry.events,
		layout = entry.layout,
		title = entry.title,
	}, function() return slot end)
end





-- ===============================================
-- ===============================================
-- ======= 2/ Non-Typing Event Aggregation =======
-- ===============================================
-- ===============================================

--- Credits app_time_ms on app_switch events.
--- @param entry table Decoded app_switch JSONL entry.
function M.walk_app_switch(entry)
	if not C.require_init("walk_app_switch") then return end
	C.ensure_batch()
	C.walker.walk_app_switch(S.agg_batch, entry)
end

--- Credits agg_app_day_titles.ms on window_switch events.
--- @param entry table Decoded window_switch JSONL entry.
function M.walk_window_switch(entry)
	if not C.require_init("walk_window_switch") then return end
	C.ensure_batch()
	C.walker.walk_window_switch(S.agg_batch, entry)
end

-- Manifest stat names that LogManager.increment_manifest_stat() is allowed to
-- bump on agg_app_day. Whitelisted (rather than trusting entry.stat blindly)
-- so a future caller cannot inject an arbitrary column name into the batch —
-- see modules/keystats/init.lua log_hotstring_suggested / log_llm_suggested,
-- the only two current producers of the manifest_increment system_event.
local MANIFEST_STAT_FIELDS = {
	hs_suggested  = true,
	llm_suggested = true,
}

--- Handles kc_hold + per-day system stats on system_event entries.
--- @param entry table Decoded system_event JSONL entry.
function M.walk_system_event(entry)
	if not C.require_init("walk_system_event") then return end
	C.ensure_batch()
	if entry.action == "physical_media_press" then
		require("keystats.media_store").replay(C.media_policy(), S.agg_batch, { entry }, C.HOLD_THRESHOLD_MS)
		local ctx = C.get_app_ctx(entry.app)
		-- Break only the physical channel; logical text continuity is separate.
		if ctx.physical then Physical.advance_streak(nil, ctx.physical, nil) end
		return
	elseif entry.action == "physical_media_release" then
		require("keystats.media_store").replay(C.media_policy(), S.agg_batch, { entry }, C.HOLD_THRESHOLD_MS)
		return
	end
	if entry.action == "physical_press" then
		Physical.walk_press(entry, C, S)
		return
	end
	if entry.action == "physical_release" then
		Physical.walk_release(entry, C, S)
		return
	end
	local date_str = entry.timestamp:sub(1, 10)
	local action   = entry.action
	if action == "manifest_increment" and MANIFEST_STAT_FIELDS[entry.stat] then
		local app = entry.app or "Unknown"
		C.bump_app_day(date_str, app, entry.stat, tonumber(entry.amount) or 1)
	end
	if action == "focus_first_key" then
		-- F-MED-27: same shape as F-HIGH-26 — LogManager.log_focus_first_key()
		-- appends this event, but walk_system_event had no branch for it and the
		-- destination columns were absent from the agg_app_day_ergo UPSERT, so
		-- the latency metric was computed, logged, and then silently discarded.
		local app = entry.app or "Unknown"
		local eg = Physical.ergo_row(date_str, app, C, S)
		eg.focus_to_first_key_sum_ms = eg.focus_to_first_key_sum_ms + (tonumber(entry.latency_ms) or 0)
		eg.focus_to_first_key_count  = eg.focus_to_first_key_count + 1
	end
	-- A physical press reported by the Karabiner bridge feeds the keycode heatmap,
	-- exactly as a typed keystroke does in walk_typing. The walker had branches
	-- for manifest_increment, focus_first_key, modifier_hold and karabiner_release
	-- but none for karabiner_press, so those events were written to the log and
	-- then dropped on ingest — and with the shipped tap/hold defaults the keys the
	-- bridge owns (Return, Backspace, Tab, Delete among them) are suppressed on
	-- the typing path too. They vanished from the heatmap entirely.
	if action == "karabiner_press" and type(entry.keycode) == "number" then
		local app = entry.app or "Unknown"
		-- Keep the sentinel escaped in source: a literal control byte renders as an
		-- empty separator in audit output even though it is present at runtime.
		local kk  = date_str .. "\1" .. app .. "\1" .. tostring(entry.keycode)
		local row = C.gc(S.agg_batch.kc_ngram, kk,
			{ date = date_str, app = app, keycode = entry.keycode, count = 0 })
		row.count = row.count + 1
	end

	if action == "modifier_hold" or action == "karabiner_release" then
		local kc  = entry.keycode
		local app = entry.app or "Unknown"
		local hold = entry.hold_ms or 0
		if type(kc) == "number" then
			local key = date_str .. "\1" .. app .. "\1" .. tostring(kc)
			local r = C.gc(S.agg_batch.kc_hold, key, {
				date=date_str, app=app, keycode=kc,
				sum_ms=0, count=0, max_ms=0, tap_count=0, hold_count=0,
			})
			r.sum_ms = r.sum_ms + hold; r.count = r.count + 1
			if hold > r.max_ms then r.max_ms = hold end
			if hold <= C.HOLD_THRESHOLD_MS then r.tap_count = r.tap_count + 1
			else r.hold_count = r.hold_count + 1 end
		end
	end
	local s = C.gc(S.agg_batch.system_day, date_str, {
		date=date_str, wifi_changes=0, space_switches=0,
		audio_muted_ms=0, locked_ms=0, sleep_ms=0, awake_ms=0,
		passive_count=0, night_wake_count=0,
	})
	if action == "wifi_change" then s.wifi_changes = s.wifi_changes + 1
	elseif action == "space_change"    then s.space_switches = s.space_switches + 1
	elseif action == "passive_period"  then s.passive_count  = s.passive_count  + 1
	elseif action == "unlock" then s.locked_ms = s.locked_ms + (entry.duration_ms or 0)
	elseif action == "wake"   then s.sleep_ms  = s.sleep_ms  + (entry.duration_ms or 0)
	end
end

return M
