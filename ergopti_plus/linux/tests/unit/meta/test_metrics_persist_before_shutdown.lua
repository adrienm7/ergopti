--- tests/unit/meta/test_metrics_persist_before_shutdown.lua

--- ==============================================================================
--- MODULE: Metrics Reach the Disk Before the Daemon Dies
--- DESCRIPTION:
--- That the keylogger is flushed periodically, and not only on the way out.
---
--- THE DEFECT THIS PINS:
--- `flush()` had exactly two call sites, both at shutdown: the SIGTERM handler
--- and the clean exit after the event loop returns. Every other way a daemon
--- ends — SIGKILL, an OOM kill, a power loss, an X server crash, a laptop lid
--- that never woke — discarded the whole session. A user typing for six hours
--- had six hours of metrics held in memory and nothing on disk.
---
--- It is also why a session spanning midnight was stamped end to end with the
--- shutdown date: both `date` and `ts` are computed AT FLUSH TIME, so a Tuesday
--- evening's typing was filed under Wednesday if the machine was shut down after
--- midnight. Flushing every few seconds does not fix that arithmetic, but it
--- bounds it to the flush interval instead of the session length.
---
--- WHY THE CADENCE IS NOT A LITERAL:
--- `_shared/modules/timings/constants.toml [keylogger] ingest_tick_ms` is what
--- Windows already uses as INGEST_TICK_MS and macOS as INGEST_TICK_SEC. A fourth
--- number written by hand here would be a fourth thing to drift, and the drift
--- would be invisible — three drivers persisting at three cadences look
--- identical until you compare two databases.
---
--- WHAT THIS CANNOT SEE:
--- Whether the write succeeds. That needs sqlite3 and a disk, and the failure
--- path is already covered by the writer's own tests.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The daemon's source, comments stripped.
--- @return string
local function daemon_source()
	local root = helpers.driver_root and helpers.driver_root() or "."
	local fh = io.open(root .. "/ergopti_hotstrings.lua", "r")
	if not fh then fh = io.open("ergopti_hotstrings.lua", "r") end
	helpers.assert_true(fh ~= nil, "the daemon source must be readable or this asserts nothing")
	local raw = fh:read("*a")
	fh:close()
	return (raw:gsub("%-%-[^\n]*", ""))
end




-- =================================================================
-- =================================================================
-- ======= 1/ It flushes while running =============================
-- =================================================================
-- =================================================================

helpers.describe("metrics persistence: not only at shutdown", function()

	helpers.it("flushes from the periodic callback", function()
		local code = daemon_source()
		local periodic = code:match("local on_periodic = function%(%).-\n\tend")
		helpers.assert_not_nil(periodic,
			"the periodic callback must be findable, or the assertion below is about "
				.. "the whole file rather than about that callback")
		helpers.assert_true(periodic:find("keylogger.flush", 1, true) ~= nil,
			"a daemon that persists only on the way out loses everything to a SIGKILL, "
				.. "an OOM kill or a power loss — and those are how a long-running user "
				.. "daemon usually ends")
	end)

	helpers.it("still flushes on the way out", function()
		local code = daemon_source()
		local flushes = 0
		for _ in code:gmatch("keylogger%.flush") do flushes = flushes + 1 end
		helpers.assert_true(flushes >= 3,
			"the periodic flush is in ADDITION to the two shutdown paths, not instead "
				.. "of them: the last few seconds before a clean exit are still worth "
				.. "keeping — found " .. flushes .. " call site(s)")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ The cadence comes from the canon =====================
-- =================================================================
-- =================================================================

helpers.describe("metrics persistence: the interval", function()

	helpers.it("derives the period from the shared timing canon", function()
		local code = daemon_source()
		helpers.assert_true(code:find('Timings.ms("keylogger", "ingest_tick_ms")', 1, true) ~= nil,
			"Windows reads the same key as INGEST_TICK_MS and macOS as "
				.. "INGEST_TICK_SEC; a literal here would be a fourth number to drift, "
				.. "and three drivers persisting at three cadences look identical until "
				.. "two databases are compared")
	end)

	helpers.it("flushes at least once a minute at the shipped values", function()
		local Timings = helpers.load_module("infra.timings")
		local ingest_ms = Timings.ms("keylogger", "ingest_tick_ms")
		helpers.assert_true(type(ingest_ms) == "number" and ingest_ms > 0,
			"the canon must actually carry the value")
		helpers.assert_true(ingest_ms <= 60000,
			"the bound this feature exists to establish is on how much a crash can "
				.. "cost. A cadence slower than a minute would leave more unwritten "
				.. "than the shutdown-only behaviour did on a short session.")
	end)

end)
