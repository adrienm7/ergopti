--- tests/unit/modules/keylogger/test_rotation_persistent_handle.lua

--- ==============================================================================
--- MODULE: rotation today.log persistent-handle guard
--- DESCRIPTION:
--- Regression guard for the keylogger hot-path append file handle.
---
--- ROOT CAUSE ENCODED:
--- append_log() runs on the active keystroke tap. It used to open()+write()+
--- close() today.log on every call, putting two syscalls per keystroke on the
--- input-delivery thread — a per-key disk round-trip that can stall the tap and
--- swallow keystrokes under disk contention. The fix opens a persistent append
--- handle once in M.init() and reuses it, dropping the handle only on rollover so
--- the next append reopens the fresh file.
---
--- This test spies io.open and asserts the today.log open count stays at 1 across
--- a burst of appends, then rises to exactly 2 after a rollover (one reopen).
--- ==============================================================================

local helpers = require("tests.helpers")

-- lib.logger must load first so every subsequent require can resolve it.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local TODAY   = "/tmp/ergopti_rotation_persistent_today.log"
local DATASQL = "/tmp/ergopti_rotation_persistent_data.sql"

--- A no-op file handle so the spy touches no real disk.
local function fake_handle()
	local handle = {}
	function handle:setvbuf(mode) return mode == "no" end
	function handle:write() return self end
	function handle:close() return true end
	function handle:read() return nil end
	function handle:lines() return function() return nil end end
	return handle
end

helpers.describe("rotation — persistent today.log handle (no per-append open/close)", function()

	helpers.it("keeps a single open across N appends and reopens once after rollover", function()
		local r = helpers.load_with_stubs("modules.keylogger.rotation")

		-- Count today.log opens; fake every handle so no real disk I/O happens.
		local real_open   = io.open
		local real_remove = os.remove
		local today_opens = 0
		io.open = function(path, _mode)
			if path == TODAY then today_opens = today_opens + 1 end
			return fake_handle()
		end
		os.remove = function(path)
			if path == TODAY then return true end
			return real_remove(path)
		end

		r.init({ paths = { today_log_path = TODAY }, state = {}, today_log_date = "2024-06-01" })

		-- N appends must NOT reopen the file — the init handle is reused.
		local N = 25
		for _i = 1, N do
			r.append_log({ type = "typing", timestamp = "2024-06-01 12:00:00.000", text = "x" })
		end
		local opens_after_appends = today_opens

		-- Rollover closes the handle; the next append must reopen exactly once.
		r.rollover(DATASQL, r.READ_STATUS_EOF)
		r.append_log({ type = "typing", timestamp = "2024-06-02 09:00:00.000", text = "y" })
		local opens_after_rollover = today_opens

		-- Restore BEFORE asserting so io.open never leaks into later test files.
		io.open = real_open
		os.remove = real_remove

		helpers.assert_eq(opens_after_appends, 1,
			"today.log must be opened once at init and reused across every append — not reopened per keystroke")
		helpers.assert_eq(opens_after_rollover, 2,
			"rollover must drop the handle so the next append reopens the fresh file exactly once")
	end)
end)
