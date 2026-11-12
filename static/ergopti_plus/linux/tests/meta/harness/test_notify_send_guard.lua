--- tests/meta/harness/test_notify_send_guard.lua

--- ==============================================================================
--- MODULE: notify-send Spawn Guard
--- DESCRIPTION:
--- Proves the sentinel that keeps the suite from showing real notifications is
--- first on PATH, so no test can reach the real program, and answers a spawn
--- with a record and a failure. It fails when children would resolve the real
--- notify-send.
--- ==============================================================================

local helpers = require("tests.helpers")
local Guard = require("tests.support.notify_send_guard")

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
end)
