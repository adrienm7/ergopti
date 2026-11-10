--- _shared/lua/test/clipboard_events_contract.lua

--- ==============================================================================
--- MODULE: Clipboard Copy/Paste Burst Contract
--- DESCRIPTION:
--- Replays keystats.clipboard_events on both Lua drivers: the Windows paste
--- chords, the Windows burst rule and the copy provenance a paste carries, the
--- Windows kinds and burst threshold read from keystats_clipboard.ahk and
--- keystats_sql.ahk, and the INSERT's columns against the shared schema.
--- ==============================================================================

local M = {}

local function read(path)
	local handle = assert(io.open(path, "rb"), "cannot open " .. path)
	local text = handle:read("*a")
	handle:close()
	return text
end

--- Registers the clipboard checks in a driver's existing owner.
--- @param helpers table The driver's describe/it/assertion functions.
function M.register(helpers)
	local ClipboardEvents = require("keystats.clipboard_events")
	local Paths = require("infra.paths")
	local WINDOW_MS = 10000

	helpers.describe("clipboard copy/paste bursts (clipboard-events)", function()
		helpers.it("clipboard-chords: the Windows paste pair, copy keys, nothing under another modifier", function()
			local cases = {
				{ "v", { primary = true }, "paste" },
				{ "insert", { shift = true }, "paste" },
				{ "c", { primary = true }, "copy" },
				{ "x", { primary = true }, "copy" },
				{ "insert", { primary = true }, "copy" },
				{ "v", { primary = true, shift = true }, nil },
				{ "v", { primary = true, alt = true }, nil },
				{ "v", { primary = true, other = true }, nil },
				{ "insert", { primary = true, shift = true }, nil },
				{ "v", {}, nil },
				{ "s", { primary = true }, nil },
			}
			for _, case in ipairs(cases) do
				helpers.assert_eq(ClipboardEvents.classify_chord(case[1], case[2]), case[3], case[1])
			end
		end)

		helpers.it("clipboard-burst: the fifth paste within the window is a burst and empties the ring", function()
			local tracker = ClipboardEvents.new({ window_ms = WINDOW_MS })
			for index = 1, 4 do
				helpers.assert_eq(#tracker.paste(index * 1000, "kate"), 1, "paste " .. index .. " alone")
			end
			local rows = tracker.paste(5000, "kate")
			helpers.assert_eq(rows[2], { kind = "paste_burst", meta = { count = 5, window_ms = WINDOW_MS } })
			helpers.assert_eq(#tracker.paste(5100, "kate"), 1, "the ring restarts after a burst")
		end)

		helpers.it("clipboard-burst-window: a paste older than the window leaves the ring, the edge stays", function()
			local tracker = ClipboardEvents.new({ window_ms = WINDOW_MS })
			tracker.paste(0, "kate")
			for at = 20000, 23000, 1000 do tracker.paste(at, "kate") end
			helpers.assert_eq(#tracker.paste(30000, "kate"), 2, "20000 is exactly one window before 30000")
			local stale = ClipboardEvents.new({ window_ms = WINDOW_MS })
			for at = 0, 3000, 1000 do stale.paste(at, "kate") end
			helpers.assert_eq(#stale.paste(10001, "kate"), 1, "0 is past the window")
		end)

		helpers.it("clipboard-provenance: a paste carries the last copy, a refused copy clears it", function()
			local tracker = ClipboardEvents.new({ window_ms = WINDOW_MS })
			helpers.assert_eq(tracker.paste(100, "kate")[1].meta, { copy_lag_ms = -1, source_app = "" })
			helpers.assert_eq(tracker.copy(1000, "firefox"),
				{ { kind = "clipboard_copy", meta = { content_type = ClipboardEvents.CONTENT_UNKNOWN } } })
			helpers.assert_eq(tracker.paste(2200, "kate")[1],
				{ kind = "clipboard_paste", meta = { copy_lag_ms = 1200, source_app = "firefox" } })
			tracker.invalidate()
			helpers.assert_eq(tracker.paste(3000, "kate")[1].meta, { copy_lag_ms = -1, source_app = "" })
		end)

		helpers.it("clipboard-windows-parity: the AHK kinds and threshold are this module's", function()
			local windows = Paths.shared("") .. "/../windows/modules/keystats/"
			local clip = read(windows .. "keystats_clipboard.ahk")
			local threshold = clip:match("PASTE_BURST_THRESHOLD%s*:=%s*(%d+)")
			helpers.assert_eq(tonumber(threshold), ClipboardEvents.PASTE_BURST_THRESHOLD)
			local sql = read(windows .. "keystats_sql.ahk")
			local dispatch = sql:match('case ("clipboard_copy"[^:]-):%s*return %[KL_BuildInsertClipboardEvent')
			helpers.assert_true(dispatch ~= nil, "keystats_sql.ahk routes the clipboard kinds")
			local kinds = {}
			for kind in dispatch:gmatch('"([%w_]+)"') do kinds[kind] = true end
			local ours = {}
			for kind in pairs(ClipboardEvents.KINDS) do ours[kind] = true end
			helpers.assert_eq(ours, kinds)
		end)

		helpers.it("clipboard-insert: the INSERT names exactly the schema's events_clipboard columns", function()
			local schema = read(Paths.shared("data/db/schema.sql"))
			local body = assert(schema:match("CREATE TABLE IF NOT EXISTS events_clipboard %((.-)\n%);"))
			local columns = {}
			for line in body:gmatch("[^\n]+") do
				local name = line:match("^%s*([%w_]+)%s+[A-Z]")
				if name and name ~= "PRIMARY" then columns[#columns + 1] = name end
			end
			helpers.assert_eq(ClipboardEvents.COLUMNS, columns)
			local sql = ClipboardEvents.insert_sql({ device_id = "d", id = 7, ts = "2026-11-10 10:00:00.000",
				date = "2026-11-10", kind = "paste_burst", app = "l'app", meta_json = "{}" })
			helpers.assert_eq(sql, "INSERT OR IGNORE INTO events_clipboard (device_id, id, ts, date, kind, app, meta_json)"
				.. " VALUES ('d', 7, '2026-11-10 10:00:00.000', '2026-11-10', 'paste_burst', 'l''app', '{}');")
			helpers.assert_true(not pcall(ClipboardEvents.insert_sql, { kind = "clipboard_cut", id = 1 }),
				"an unknown kind is refused")
		end)
	end)
end

return M
