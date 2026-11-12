--- tests/meta/harness/test_notify_send_guard.lua

--- ==============================================================================
--- MODULE: notify-send Spawn Guard
--- DESCRIPTION:
--- Proves the sentinel that keeps the suite from showing real notifications is
--- first on PATH, so no test can reach the real program, and answers a spawn
--- with a record and a failure. It fails when children would resolve the real
--- notify-send, or when a case's require("adapters.notifier") is not the
--- recording seam.
--- ==============================================================================

local helpers = require("tests.helpers")
local Guard = require("tests.support.notify_send_guard")
local NoticeRecorder = require("tests.support.notice_recorder")

helpers.describe("notify-send spawn guard (nui-003-spawn-guard)", function()
	helpers.it("resolves notify-send to the sentinel and records a spawn", function()
		if type(jit) ~= "table" then return end
		local dir = assert(Guard.dir())
		-- A pure-Lua PATH walk: the first entry holding a readable notify-send is
		-- what children run. No program is probed by name.
		local resolved
		for entry in (os.getenv("PATH") or ""):gmatch("[^:]+") do
			local candidate = io.open(entry .. "/notify-send", "rb")
			if candidate then candidate:close(); resolved = entry .. "/notify-send"; break end
		end
		helpers.assert_eq(resolved, dir .. "/notify-send", "children resolve notify-send to the sentinel")
		local log = os.tmpname()
		os.remove(log)
		-- The sentinel itself, by its absolute path.
		local status = os.execute(Guard.LOG_VARIABLE .. "='" .. log .. "' '" .. resolved .. "' --urgency=low -- 'probe' 'body'")
		helpers.assert_true(status ~= true and status ~= 0, "the sentinel answers with a failure")
		local file = assert(io.open(log, "rb"))
		local recorded = file:read("*a")
		file:close()
		os.remove(log)
		helpers.assert_contains(recorded, "probe body", "the sentinel records what it was asked to show")
		helpers.assert_eq(Guard.spawned(), nil, "the probe wrote to its own file, not the run's record")
	end)

	helpers.it("resolves every case's notifier to the recording seam", function()
		local notifier = require("adapters.notifier")
		helpers.assert_true(notifier == NoticeRecorder.notifier(), "a case's notifier is the recorder")
		helpers.assert_eq(notifier.send("probe body", { title = "probe", level = "warning" }), true,
			"the recorder admits the notice as the real adapter would")
		local notices = helpers.recorded_notices()
		helpers.assert_eq(#notices, 1, "the notice was recorded instead of spawned")
		helpers.assert_eq(notices[1].title, "⚠ probe", "the real adapter composed the title")
		helpers.assert_eq(notices[1].message, "probe body", "the body is recorded verbatim")
		helpers.assert_eq(notices[1].urgency, "normal", "the level maps to its urgency")
	end)
end)
