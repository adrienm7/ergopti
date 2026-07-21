--- tests/unit/modules/keylogger/test_kc_bridge_discards_backlog.lua

--- ==============================================================================
--- MODULE: Regression — the KE bridge must not replay its off-window backlog
--- DESCRIPTION:
--- Toggling Metrics off, working for a while, then toggling it back on injected
--- the entire intervening period of physical keystrokes into the metrics store —
--- stamped with the CURRENT time and attributed to the CURRENTLY focused app.
---
--- ROOT CAUSE ENCODED:
--- M.stop() tears down both drain triggers (the path watcher and the poll timer),
--- so _file_offset cannot advance while the bridge is off. Karabiner keeps
--- appending to the kc log regardless — it is a separate process that knows
--- nothing about the toggle. M.start() re-armed the watchers without moving the
--- cursor, so the very next drain read everything appended during the off window
--- and replayed it as if it had just happened.
---
--- M.init() already does the right thing for the same reason, and says so: "Set
--- _file_offset to current end so we ignore stale lines from a prior session".
--- The restart path simply did not carry that step — the repo's usual shape, an
--- invariant applied at one of two entry points.
---
--- Discarding is the only correct choice. The user deliberately switched recording
--- off, and the real timestamps and focused-app context of those keys are gone, so
--- replaying them cannot produce true data — only plausible-looking false data,
--- which is worse.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==============================================
-- ==============================================
-- ======= 1/ The Restart Skips The Gap =========
-- ==============================================
-- ==============================================

helpers.describe("kc_bridge discards keystrokes appended while it was stopped", function()
	helpers.it("re-syncs the file offset to EOF on start()", function()
		local path = helpers.driver_root() .. "modules/keylogger/kc_bridge.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "kc_bridge.lua must be readable")
		local src = fh:read("*a") ; fh:close()

		local start_at = src:find("function M%.start%(%)")
		helpers.assert_true(start_at ~= nil, "M.start must be locatable")

		-- Bound the slice to M.start's body so init()'s own seek cannot satisfy this.
		local body_end = src:find("\n%-%-%-", start_at + 10) or #src
		local body = src:sub(start_at, body_end)

		helpers.assert_true(body:find('seek%("end"%)') ~= nil,
			"M.start() must re-sync _file_offset to EOF. stop() removes both drain "
			.. "triggers so the cursor cannot advance while the bridge is off, and "
			.. "Karabiner keeps appending — without the re-sync the next drain replays "
			.. "the whole off-window backlog with fabricated timestamps")
		helpers.assert_true(body:find("_file_offset = eof") ~= nil,
			"the re-synced end position must actually be assigned to _file_offset")
	end)

	helpers.it("still reports how much was skipped", function()
		-- Silently dropping data is its own problem: the skip must be visible in the
		-- log so an unexpected gap in the metrics is explainable afterwards.
		local path = helpers.driver_root() .. "modules/keylogger/kc_bridge.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "kc_bridge.lua must be readable")
		local src = fh:read("*a") ; fh:close()

		helpers.assert_true(src:find("Skipping ", 1, true) ~= nil,
			"the number of skipped bytes must be logged — a silent discard leaves an "
			.. "unexplained hole in the metrics")
	end)
end)
