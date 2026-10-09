--- tests/meta/test_karabiner_capsword_lock_release.lua

--- ==============================================================================
--- MODULE: Karabiner CapsWord Lock Release Meta Test
--- DESCRIPTION:
--- Static source guard for the "karabiner-capsword-lock-leak" audit finding in
--- platform/remap/watchers.lua.
---
--- ROOT CAUSE ENCODED:
--- The `deactivate_capsword` function set `_capsword_check_pending = true` and
--- then immediately called `hs.task.new(...):start()` via method chaining. If
--- `task:start()` returned false (e.g., the karabiner-cli binary was missing or
--- permissions changed), the callback that resets `_capsword_check_pending = false`
--- would never fire — leaving the guard permanently true and silently blocking all
--- future CapsWord deactivation for the entire session.
---
--- The fix splits task creation from start, checks the return value, and releases
--- the lock immediately when start fails.
---
--- This test also verifies the inputSourceChanged single-owner fix: Hammerspoon's
--- setter unsets its predecessor and has no getter, so every consumer must use
--- the process-wide broker.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then
			out[#out + 1] = line
		end
	end
	return table.concat(out, "\n")
end


-- ============================================================
-- ============================================================
-- ======= 1/ CapsWord lock released on task:start() failure ==
-- ============================================================
-- ============================================================

helpers.describe("karabiner/watchers.lua: CapsWord lock release (karabiner-capsword-lock-leak)", function()

	helpers.it("task construction is protected and stored before calling :start()", function()
		local src = strip_comments(read_source("local function parse_layout_name"))
		helpers.assert_true(src:match("local task%s*\n") ~= nil,
			"the callback must forward-declare its GC-pinned task handle")
		helpers.assert_true(src:find("TaskLifecycle.native", 1, true) ~= nil,
			"native task construction and callbacks must be protected before the lock is released")
		helpers.assert_true(src:find("task = task_or_err", 1, true) ~= nil,
			"the protected constructor result must become the exact retained handle")
	end)

	helpers.it("_capsword_check_pending is released when task:start() returns false", function()
		local src = strip_comments(read_source("local function parse_layout_name"))
		helpers.assert_true(src:find("TaskLifecycle.start(task, \"CapsWord variable probe\")", 1, true) ~= nil,
			"task:start() can raise as well as return false and must be protected")
		helpers.assert_true(src:find("abandon_probe(task,", 1, true) ~= nil,
			"both start failure modes must invalidate the generation and release the lock")
	end)

	-- F-L6: hs.task fires its callback only on process EXIT, so a started-but-hung
	-- karabiner_cli would leave _capsword_check_pending true forever. A watchdog timer
	-- must force-release the lock after a timeout (and the callback must cancel it).
	--
	-- The watchdog is scheduled via the TimerScheduler adapter (not raw hs.timer.doAfter)
	-- per PF-1 — routing this OS call through adapters/ keeps the hs.* purity ratchet
	-- meta-test (test_port_adapter_coverage.lua) from re-flagging it as a violation.
	helpers.it("a watchdog releases the lock if the started task never completes (F-L6)", function()
		local src = strip_comments(read_source("local function parse_layout_name"))
		helpers.assert_true(src:find("_capsword_probe_watchdog", 1, true) ~= nil,
			"deactivate_capsword must arm a watchdog timer (_capsword_probe_watchdog)")
		helpers.assert_true(src:find("CAPSWORD_PROBE_TIMEOUT_SEC", 1, true) ~= nil,
			"the watchdog must use a named timeout constant, not a magic number")
		local watchdog_arm = src:find(
			"pcall%s*%(%s*TimerScheduler%.after,%s*CAPSWORD_PROBE_TIMEOUT_SEC"
		)
		helpers.assert_true(watchdog_arm ~= nil,
			"the watchdog must be scheduled via the TimerScheduler adapter, not raw hs.timer.doAfter (PF-1)")
		-- The timeout callback routes through the one abandonment helper that both
		-- releases the lock and retires the task generation. Merely finding an
		-- unrelated assignment later in the file was a false-green.
		local watchdog_body = src:sub(watchdog_arm, watchdog_arm + 900)
		helpers.assert_true(watchdog_body:find("abandon_probe(task, nil)", 1, true) ~= nil,
			"the watchdog callback must abandon the exact in-flight probe")
		local abandon_at = src:find("local function abandon_probe", 1, true)
		helpers.assert_true(abandon_at ~= nil
			and src:sub(abandon_at, abandon_at + 900):find("_capsword_check_pending = false", 1, true) ~= nil,
			"the shared abandonment path must release _capsword_check_pending")
	end)

end)


-- ======================================================================
-- ======================================================================
-- ======= 2/ inputSourceChanged single native broker ====================
-- ======================================================================
-- ======================================================================

helpers.describe("karabiner/watchers.lua: inputSourceChanged broker ownership", function()

	helpers.it("watchers subscribe through the process-wide broker", function()
		local src = strip_comments(read_source("local function parse_layout_name"))
		helpers.assert_true(src:find("InputSourceBroker.subscribe", 1, true) ~= nil,
			"the Karabiner watcher must not replace the setter-only global callback")
		helpers.assert_true(src:find("hs.keycodes.inputSourceChanged", 1, true) == nil,
			"only the adapter broker may call the native global setter")
	end)

	helpers.it("watcher teardown removes only its named broker subscriber", function()
		local src = strip_comments(read_source("local function parse_layout_name"))
		helpers.assert_true(src:find("InputSourceBroker.unsubscribe", 1, true) ~= nil,
			"Karabiner teardown must preserve every sibling subscriber")
	end)

end)
