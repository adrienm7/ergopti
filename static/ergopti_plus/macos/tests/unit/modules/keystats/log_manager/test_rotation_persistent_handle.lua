--- tests/unit/modules/keystats/log_manager/test_rotation_persistent_handle.lua

--- ==============================================================================
--- MODULE: rotation today.log persistent-handle guard
--- DESCRIPTION:
--- Regression guard for the keystats hot-path append file handle.
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

local TODAY   = "/tmp/ergopti_rotation_persistent_today.log"
local DATASQL = "/tmp/ergopti_rotation_persistent_data.sql"

--- A no-op file handle so the spy touches no real disk.
local function fake_handle(on_close)
	local handle = {}
	function handle:setvbuf(mode) return mode == "no" end
	function handle:write() return self end
	function handle:close() on_close(); return true end
	function handle:read() return nil end
	function handle:lines() return function() return nil end end
	return handle
end

helpers.describe("rotation — persistent today.log handle (no per-append open/close)", function()

	helpers.it("keeps a single open across N appends and reopens once after rollover", function()
		local opens_after_appends, opens_after_rollover
		helpers.with_stub_scope({
			"modules.keystats.rotation", "adapters.ledger_append", "infra.logger",
			"modules.keystats.timestamp", "adapters.timer_scheduler", "error_description", "number_policy",
		}, function()
			local real_open, real_remove, real_date = io.open, os.remove, os.date
			local today_opens, today_closes, owner_calls, reset_calls, removes = 0, 0, 0, 0, 0
			local function reset(next_date)
				helpers.assert_eq(next_date, "2024-06-02", "reset must acknowledge the captured rollover date")
				reset_calls = reset_calls + 1
				return true
			end
			local function origin(content)
				return content == ""
			end
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["adapters.ledger_append"] = {
				rollover = function(data_sql, today, offset, previous_date, next_date, checked_reset, passed_origin)
					owner_calls = owner_calls + 1
					helpers.assert_eq(data_sql, DATASQL, "owner must receive the canonical ledger path")
					helpers.assert_eq(today, TODAY, "owner must receive the consumed journal path")
					helpers.assert_eq(offset, 0, "owner must receive the committed journal offset")
					helpers.assert_eq(previous_date, "2024-06-01", "owner must receive the old journal date")
					helpers.assert_eq(next_date, "2024-06-02", "owner must receive the captured new date")
					helpers.assert_eq(type(checked_reset), "function", "owner requires a checked reset capability")
					helpers.assert_eq(passed_origin, origin, "owner must receive the exact origin capability")
					helpers.assert_eq(today_closes, 1, "the old append stream must close before durable ownership")
					helpers.assert_eq(today_opens, 1, "rollover must not reopen before owner acknowledgement")
					helpers.assert_eq(reset_calls, 0, "cache reset must wait for durable owner admission")
					helpers.assert_eq(os.remove(today), true, "the virtual owner must retire the consumed journal")
					local completion = {}
					helpers.assert_eq(checked_reset(next_date, completion), true,
						"the durable owner requires literal true from the checked reset")
					helpers.assert_eq(reset_calls, 1, "the checked reset must invoke the exact reset callback once")
					return true
				end,
			}
			local r = helpers.load_with_stubs("modules.keystats.rotation")
			local outcome = table.pack(xpcall(function()
				-- Every native path is virtual and remains inside this fixture.
				io.open = function(path, mode)
					helpers.assert_eq(path, TODAY, "only the owned today.log append stream may open")
					helpers.assert_eq(mode, "a", "the persistent stream must use native append mode")
					today_opens = today_opens + 1
					return fake_handle(function() today_closes = today_closes + 1 end)
				end
				os.remove = function(path)
					helpers.assert_eq(path, TODAY, "only the consumed virtual journal may retire")
					removes = removes + 1
					return true
				end
				os.date = function(format, timestamp)
					if format == "%Y-%m-%d" and timestamp == nil then return "2024-06-02" end
					return real_date(format, timestamp)
				end

				r.init({ paths = { today_log_path = TODAY }, state = {}, today_log_date = "2024-06-01" })

				-- N appends must NOT reopen the file — the init handle is reused.
				local N = 25
				for _i = 1, N do
					helpers.assert_eq(r.append_log({ type = "typing", timestamp = "2024-06-01 12:00:00.000", text = "x" }), true,
						"every hot-path append must report literal true while reusing the single stream")
				end
				opens_after_appends = today_opens

				-- Reopen only after the durable owner and reset both acknowledge.
				helpers.assert_eq(r.rollover(DATASQL, r.READ_STATUS_EOF, reset, origin), true,
					"rollover requires explicit durable-owner and reset acknowledgement")
				helpers.assert_eq(owner_calls, 1, "one rollover must have exactly one durable owner")
				helpers.assert_eq(reset_calls, 1, "one rollover must acknowledge exactly one reset")
				helpers.assert_eq(removes, 1, "the owner must retire the virtual journal exactly once")
				helpers.assert_eq(r.get_offset(), 0, "acknowledged rollover must publish offset zero")
				helpers.assert_eq(r.get_date(), "2024-06-02", "acknowledged rollover must publish the captured date")
				helpers.assert_eq(today_opens, 1, "the next append owns the single reopen")
				helpers.assert_eq(r.append_log({ type = "typing", timestamp = "2024-06-02 09:00:00.000", text = "y" }), true,
					"the first append after acknowledged rollover must report literal true")
				opens_after_rollover = today_opens
			end, debug.traceback))
			-- Restore native ports even when an assertion inside the owner throws.
			io.open, os.remove, os.date = real_open, real_remove, real_date
			if not outcome[1] then error(outcome[2], 0) end
		end)

		helpers.assert_eq(opens_after_appends, 1,
			"today.log must be opened once at init and reused across every append — not reopened per keystroke")
		helpers.assert_eq(opens_after_rollover, 2,
			"rollover must drop the handle so the next append reopens the fresh file exactly once")
	end)
end)
