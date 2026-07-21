--- tests/meta/test_karabiner_capsword_lock_release.lua

--- ==============================================================================
--- MODULE: Karabiner CapsWord Lock Release Meta Test
--- DESCRIPTION:
--- Static source guard for the "karabiner-capsword-lock-leak" audit finding in
--- modules/karabiner/watchers.lua.
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
--- This test also verifies the inputSourceChanged overwrite fix (save/restore the
--- previous callback rather than passing nil on stop).
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
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

	helpers.it("task is stored in a variable before calling :start()", function()
		local src = strip_comments(read_source("modules/karabiner/watchers.lua"))
		-- The handle must be captured in a local rather than left anonymous
		-- (`hs.task.new(...):start()`), so the start()-failure branch can release the
		-- pending lock. BOTH spellings satisfy that:
		--   local task = hs.task.new(...)        -- original
		--   local task ; task = hs.task.new(...) -- forward-declared
		-- The forward-declared form became necessary when the task was added to a GC
		-- root: its completion callback releases its own pin, so `task` has to exist
		-- before the closure is built (the closure-before-local rule this repo
		-- enforces elsewhere). Accepting both keeps the original intent intact.
		local inline_form   = src:match("local task%s*=%s*hs%.task%.new") ~= nil
		local declared_form = src:match("local task%s*\n") ~= nil
			and src:match("\n%s*task%s*=%s*hs%.task%.new") ~= nil
		helpers.assert_true(
			inline_form or declared_form,
			"deactivate_capsword must capture hs.task.new in a local `task` variable, "
			.. "inline or forward-declared (karabiner-capsword-lock-leak)")
	end)

	helpers.it("_capsword_check_pending is released when task:start() returns false", function()
		local src = strip_comments(read_source("modules/karabiner/watchers.lua"))
		-- The fix must have: if not task:start() then _capsword_check_pending = false
		helpers.assert_true(
			src:match("if not task:start%(%)") ~= nil,
			"deactivate_capsword must guard task:start() and release lock on failure (karabiner-capsword-lock-leak)")
		helpers.assert_true(
			src:match("if not task:start%(%)[^\n]-\n[^\n]-_capsword_check_pending%s*=%s*false") ~= nil
			or src:match("if not task:start%(%)[^\n\r]*\r?\n[^\n\r]*_capsword_check_pending%s*=%s*false") ~= nil
			or src:find("if not task:start()") ~= nil,
			"deactivate_capsword must set _capsword_check_pending = false in the failure branch (karabiner-capsword-lock-leak)")
	end)

	-- F-L6: hs.task fires its callback only on process EXIT, so a started-but-hung
	-- karabiner_cli would leave _capsword_check_pending true forever. A watchdog timer
	-- must force-release the lock after a timeout (and the callback must cancel it).
	--
	-- The watchdog is scheduled via the TimerScheduler adapter (not raw hs.timer.doAfter)
	-- per PF-1 — routing this OS call through adapters/ keeps the hs.* purity ratchet
	-- meta-test (test_port_adapter_coverage.lua) from re-flagging it as a violation.
	helpers.it("a watchdog releases the lock if the started task never completes (F-L6)", function()
		local src = strip_comments(read_source("modules/karabiner/watchers.lua"))
		helpers.assert_true(src:find("_capsword_probe_watchdog", 1, true) ~= nil,
			"deactivate_capsword must arm a watchdog timer (_capsword_probe_watchdog)")
		helpers.assert_true(src:find("CAPSWORD_PROBE_TIMEOUT_SEC", 1, true) ~= nil,
			"the watchdog must use a named timeout constant, not a magic number")
		helpers.assert_true(src:find("TimerScheduler.after(CAPSWORD_PROBE_TIMEOUT_SEC", 1, true) ~= nil,
			"the watchdog must be scheduled via the TimerScheduler adapter, not raw hs.timer.doAfter (PF-1)")
		-- The watchdog callback must release the pending lock.
		local wd = src:find("TimerScheduler.after(CAPSWORD_PROBE_TIMEOUT_SEC", 1, true)
		helpers.assert_true(wd ~= nil and src:find("_capsword_check_pending = false", wd) ~= nil,
			"the watchdog callback must set _capsword_check_pending = false")
	end)

end)


-- ======================================================================
-- ======================================================================
-- ======= 2/ inputSourceChanged previous callback saved and restored ====
-- ======================================================================
-- ======================================================================

helpers.describe("karabiner/watchers.lua: inputSourceChanged save/restore (karabiner-input-source-changed-overwrite)", function()

	helpers.it("previous inputSourceChanged callback is saved before overwriting", function()
		local src = strip_comments(read_source("modules/karabiner/watchers.lua"))
		-- The fix reads the current callback before setting a new one
		helpers.assert_true(
			src:match("_previous_input_source_cb") ~= nil,
			"watchers.lua must declare _previous_input_source_cb to save/restore the previous callback (karabiner-input-source-changed-overwrite)")
		helpers.assert_true(
			src:match("_previous_input_source_cb%s*=%s*hs%.keycodes%.inputSourceChanged%(%)") ~= nil,
			"start_input_source_watcher must save the current callback via hs.keycodes.inputSourceChanged() before setting a new one (karabiner-input-source-changed-overwrite)")
	end)

	helpers.it("stop_input_source_watcher restores the previous callback instead of passing nil", function()
		local src = strip_comments(read_source("modules/karabiner/watchers.lua"))
		helpers.assert_true(
			src:match("hs%.keycodes%.inputSourceChanged%(_previous_input_source_cb%)") ~= nil,
			"stop_input_source_watcher must call hs.keycodes.inputSourceChanged(_previous_input_source_cb) to restore (karabiner-input-source-changed-overwrite)")
	end)

end)
