--- _shared/lua/keystats/clipboard_events.lua

--- ==============================================================================
--- MODULE: Clipboard Copy/Paste Bursts (Shared)
--- DESCRIPTION:
--- The rows of events_clipboard for the Lua drivers: clipboard_copy,
--- clipboard_paste and paste_burst, the kinds Windows writes from
--- keystats_clipboard.ahk. The paste-burst rule, the copy provenance a paste
--- carries and the single INSERT both drivers render live here once, free of
--- any clock or OS call, so a driver feeds it observed chords and a test moves
--- time by hand.
---
--- FEATURES & RATIONALE:
--- 1. Same burst rule as Windows (KL_Clip_OnPaste): the pastes of the last
---    timings [keystats] paste_burst_window_ms, this one included, reaching
---    PASTE_BURST_THRESHOLD emit one paste_burst row and empty the ring.
--- 2. A paste carries the copy it most likely pastes: copy_lag_ms since the
---    last accepted copy (-1 without one) and that copy's source_app, the
---    Windows clipboard_paste metadata. A copy the driver refuses (pause,
---    privacy filter, excluded application) clears that provenance, as the
---    Windows change handler does before its filters, so a later paste never
---    names an application whose copy was not recorded.
--- 3. Privacy: no clipboard content is read. The Lua drivers observe the
---    physical copy and paste chords, not the clipboard itself, so a copy's
---    content_type is "unknown" and no char_count is stored on either kind.
---    Windows reads the clipboard text length on each change; the Lua drivers
---    would need a clipboard read for it, which this module leaves out.
--- 4. The INSERT is spelled here, once, for both Lua drivers. It is not in the
---    named catalogue (_shared/data/db/queries.sql) because adding it there
---    regenerates the Windows _generated/keystats_queries.ahk; Windows writes
---    events_clipboard through its own keystats_sql.ahk builder.
--- ==============================================================================

local M = {}

local Literal = require("sqlite.literal")

--- The events_clipboard kinds and the metadata keys each carries on these drivers.
M.KINDS = {
	clipboard_copy = { "content_type" },
	clipboard_paste = { "copy_lag_ms", "source_app" },
	paste_burst = { "count", "window_ms" },
}

--- Pastes within the window that make a burst (KLClipConst.PASTE_BURST_THRESHOLD).
M.PASTE_BURST_THRESHOLD = 5

--- A copy observed from its chord: the content was never read.
M.CONTENT_UNKNOWN = "unknown"

--- events_clipboard columns, in schema order.
M.COLUMNS = { "device_id", "id", "ts", "date", "kind", "app", "meta_json", "utc_offset_min" }

--- Copy and paste keys under the platform's primary modifier (Ctrl, Cmd).
local COPY_KEYS = { c = true, x = true }




-- ===============================
-- ===============================
-- ======= 1/ Chords =============
-- ===============================
-- ===============================

--- Classifies one forwarded chord. Paste is the Windows pair: the primary
--- modifier with V, or Shift+Insert, each with no other modifier. Copy is the
--- primary modifier with C or X, or with Insert.
--- @param key string Lowercase key name ("v", "insert").
--- @param mods table { primary, shift, alt, other } booleans; `other` is any further modifier.
--- @return string|nil action "copy", "paste" or nil.
function M.classify_chord(key, mods)
	if type(key) ~= "string" or type(mods) ~= "table" then return nil end
	if mods.alt or mods.other then return nil end
	if key == "insert" then
		if mods.shift and not mods.primary then return "paste" end
		if mods.primary and not mods.shift then return "copy" end
		return nil
	end
	if not mods.primary or mods.shift then return nil end
	if key == "v" then return "paste" end
	if COPY_KEYS[key] then return "copy" end
	return nil
end




-- ===============================
-- ===============================
-- ======= 2/ Tracker ============
-- ===============================
-- ===============================

--- A fresh tracker.
--- @param opts table { window_ms } from timings [keystats] paste_burst_window_ms.
--- @return table tracker { copy(now_ms, app), paste(now_ms, app), invalidate() }
function M.new(opts)
	if type(opts) ~= "table" or type(opts.window_ms) ~= "number" or opts.window_ms <= 0 then
		error("clipboard_events.new requires a positive window_ms", 2)
	end
	local window_ms = opts.window_ms
	local last_copy_at, last_copy_app = nil, ""
	local paste_ticks = {}
	local tracker = {}

	--- Records one accepted copy.
	--- @param now_ms number Caller's monotonic time.
	--- @param app string Dashboard application name.
	--- @return table rows { { kind, meta } }
	function tracker.copy(now_ms, app)
		assert(type(now_ms) == "number" and type(app) == "string", "clipboard copy needs a time and an app")
		last_copy_at, last_copy_app = now_ms, app
		return { { kind = "clipboard_copy", meta = { content_type = M.CONTENT_UNKNOWN } } }
	end

	--- Records one accepted paste, then the burst it completes.
	--- @param now_ms number Caller's monotonic time.
	--- @param app string Dashboard application name.
	--- @return table rows { { kind, meta } }
	function tracker.paste(now_ms, app)
		assert(type(now_ms) == "number" and type(app) == "string", "clipboard paste needs a time and an app")
		local lag = last_copy_at and math.max(0, math.floor(now_ms - last_copy_at)) or -1
		local rows = { { kind = "clipboard_paste", meta = { copy_lag_ms = lag, source_app = last_copy_app } } }
		local fresh = {}
		for _, tick in ipairs(paste_ticks) do
			if now_ms - tick <= window_ms then fresh[#fresh + 1] = tick end
		end
		fresh[#fresh + 1] = now_ms
		if #fresh >= M.PASTE_BURST_THRESHOLD then
			rows[2] = { kind = "paste_burst", meta = { count = #fresh, window_ms = window_ms } }
			fresh = {}
		end
		paste_ticks = fresh
		return rows
	end

	--- Forgets the last copy: a refused copy must not lend its app to a paste.
	function tracker.invalidate()
		last_copy_at, last_copy_app = nil, ""
	end

	return tracker
end




-- ===============================
-- ===============================
-- ======= 3/ Storage ============
-- ===============================
-- ===============================

local function text(value)
	assert(type(value) == "string", "a clipboard row needs text columns")
	return "'" .. Literal.escape(value) .. "'"
end

--- Renders one events_clipboard row.
--- @param row table { device_id, id, ts, date, kind, app, meta_json, utc_offset_min? }; an
---   absent offset is a row recorded before the column existed (NULL).
--- @return string sql One INSERT OR IGNORE statement.
function M.insert_sql(row)
	assert(type(row) == "table" and M.KINDS[row.kind], "not an events_clipboard kind: " .. tostring(row and row.kind))
	assert(type(row.id) == "number" and row.id >= 0 and row.id % 1 == 0, "a clipboard row needs an integer id")
	local offset = row.utc_offset_min
	assert(offset == nil or (type(offset) == "number" and offset % 1 == 0), "a clipboard row's offset is whole minutes")
	return "INSERT OR IGNORE INTO events_clipboard (" .. table.concat(M.COLUMNS, ", ") .. ") VALUES ("
		.. text(row.device_id) .. ", " .. string.format("%d", row.id) .. ", " .. text(row.ts) .. ", "
		.. text(row.date) .. ", " .. text(row.kind) .. ", " .. text(row.app) .. ", " .. text(row.meta_json) .. ", "
		.. (offset == nil and "NULL" or string.format("%d", offset)) .. ");"
end

return M
