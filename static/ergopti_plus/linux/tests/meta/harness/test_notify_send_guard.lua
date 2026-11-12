--- tests/meta/harness/test_notify_send_guard.lua

--- ==============================================================================
--- MODULE: notify-send Spawn Guard
--- DESCRIPTION:
--- Proves the sentinel that keeps the suite from showing real notifications is
--- first on PATH, so no test can reach the real program, and answers a spawn
--- with a record and a failure. It fails when children would resolve the real
--- notify-send, when a case's require("adapters.notifier") is not the recording
--- seam, or when a notice that reaches the real notifier would not fail the run
--- with its test case named.
--- ==============================================================================

local helpers = require("tests.helpers")
local Guard = require("tests.support.notify_send_guard")
local NoticeRecorder = require("tests.support.notice_recorder")

-- How long the real notifier's sentinel child may take to write its record.
local SPAWN_WAIT_MS = 5000

--- Points the sentinel's record at `path` for the children started from now
--- on, or back at the run's own record when `path` is nil.
--- @param path string|nil
local function redirect_record(path)
	local ffi = require("ffi")
	pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite);")
	pcall(ffi.cdef, "int unsetenv(const char *name);")
	local status = path and ffi.C.setenv(Guard.LOG_VARIABLE, path, 1) or ffi.C.unsetenv(Guard.LOG_VARIABLE)
	assert(status == 0, "the sentinel record could not be redirected")
end

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

	helpers.it("fails the run and names the case whose notice reached the real notifier", function()
		if type(jit) ~= "table" then return end
		local loaded_luv, luv = pcall(require, "luv")
		if not loaded_luv then return end
		local record = os.tmpname()
		os.remove(record)
		-- The real adapter, loaded past the recorder: what a fixture that loads
		-- adapters.notifier itself, without the shell seams, would send through.
		local Notifier = helpers.fresh_module("adapters.notifier")
		helpers.assert_true(Notifier ~= NoticeRecorder.notifier(), "the fixture holds the real adapter")
		redirect_record(record)
		local sent_ok, sent = pcall(Notifier.send, "escaped body", { title = "escaped" })
		redirect_record(nil)
		helpers.assert_true(sent_ok, "the real adapter accepted the notice")
		helpers.assert_eq(sent, true, "the real adapter started notify-send")
		local deadline = luv.hrtime() + SPAWN_WAIT_MS * 1e6
		while Guard.spawned(record) == nil and luv.hrtime() < deadline do
			luv.run("nowait")
			luv.sleep(10)
		end
		luv.run("nowait")
		local offenders = Guard.offenders(record)
		local lines = {}
		local failed = Guard.report(function(line) lines[#lines + 1] = line end, record)
		os.remove(record)
		helpers.assert_eq(#offenders, 1, "the sentinel recorded the escaped notice once")
		helpers.assert_contains(offenders[1].case, "fails the run and names the case whose notice reached the real notifier",
			"the record names the case that sent it")
		helpers.assert_true(failed, "a notice that reached the sentinel fails the run")
		helpers.assert_contains(table.concat(lines), offenders[1].case, "the verdict names the offending case")
		helpers.assert_eq(Guard.report(function() error("an empty record reports nothing", 0) end, record), false,
			"a run whose notices all went through a seam passes")
	end)
end)
