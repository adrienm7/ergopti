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
		local visited = {}
		for entry in (os.getenv("PATH") or ""):gmatch("[^:]+") do
			visited[#visited + 1] = entry
			local candidate = io.open(entry .. "/notify-send", "rb")
			if candidate then candidate:close(); resolved = entry .. "/notify-send"; break end
		end
		-- An empty walk or a PATH with no notify-send anywhere must not pass.
		helpers.assert_true(#visited > 0, "the PATH walk visited at least one entry")
		helpers.assert_true(resolved ~= nil, "the PATH walk found a notify-send")
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

	-- A fixture double that outlives its case (tests/support/document_fixture.lua)
	-- keeps the notifier until the fixture restores the recorder it saved; the
	-- value outside the cases must never become that double.
	local fixture_double = { send = function() return true end }
	local saved_recorder, restored = nil, false
	local before_fixture = package.loaded["adapters.notifier"]
	helpers.it("keeps a fixture's notifier double installed across cases", function()
		saved_recorder = package.loaded["adapters.notifier"]
		package.loaded["adapters.notifier"] = fixture_double
	end)
	helpers.it("lets the fixture restore the recorder it saved", function()
		if saved_recorder == nil then return end
		helpers.assert_true(package.loaded["adapters.notifier"] == fixture_double, "the fixture still owns the notifier")
		package.loaded["adapters.notifier"] = saved_recorder
		restored = true
	end)
	local outside = package.loaded["adapters.notifier"]
	-- A filtered run that skipped the fixture's restore still ends clean.
	if outside == fixture_double then package.loaded["adapters.notifier"] = before_fixture end
	helpers.it("puts back the notifier found outside the cases after the fixture restores", function()
		if not restored then return end
		helpers.assert_true(outside ~= fixture_double, "the fixture's double did not leak out of its cases")
		helpers.assert_true(outside ~= NoticeRecorder.notifier(), "the recorder is installed only inside a case")
	end)

	helpers.it("leaves native modules loaded when a child builds the recorder", function()
		if type(jit) ~= "table" then return end
		local quote = require("text_utils").shell_quote
		-- The recorder is built before luv is loaded, as in a fixture child that
		-- requires tests.helpers first; reopening luv crashed such a child.
		local child = [[
package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path
require("tests.helpers")
-- A second luv instance crashed once the collector closed the first one's loop.
collectgarbage("collect")
local uv = require("luv")
local fired = false
local timer = uv.new_timer()
timer:start(1, 0, function() fired = true; timer:close() end)
uv.run()
collectgarbage("collect")
assert(fired, "the child's event loop ran")
assert(package.loaded.luv == uv, "luv stays loaded once")
]]
		local status = os.execute("cd " .. quote(helpers.driver_root()) .. " && luajit -e " .. quote(child) .. " >/dev/null 2>&1")
		helpers.assert_true(status == true or status == 0, "a child that builds the recorder keeps a working luv")
	end)
end)
