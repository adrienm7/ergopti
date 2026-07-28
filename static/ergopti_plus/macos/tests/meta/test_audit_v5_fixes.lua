--- tests/meta/test_audit_v5_fixes.lua

--- ==============================================================================
--- MODULE: Audit V5 Regression Guards
--- DESCRIPTION:
--- Static-source regression guards for the four bugs fixed from the expert audit
--- report RAPPORT_AUDIT_EXPERT_HAMMERSPOON.md (macOS/Hammerspoon side):
---   1. gestures/engine.lua: diagonal detection used `adx >= diagMin and ady >=
---      diagMin`, requiring ~2x the intended total distance. Fixed to `dist >= diagMin`.
---   2. modules/llm/api_mlx.lua: `_server_pgid_pending` stayed true forever if the
---      MLX server crashed before emitting its PID line. Fixed with a 15s timeout.
---   3. modules/keymap/init.lua: the `elseif dt < 0.02` branch in the synthetic
---      filter returned false without clearing `expected_synthetic_chars`, leaving
---      a stale buffer that absorbed the next matching real keystroke.
---   4. init.lua: `grep -c .` exit-code 1 on empty input is now silenced with
---      `|| true` to protect against future `set -e` shells.
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





-- ================================================================================
-- ===============================================================================
-- ======= 1/ gestures/engine.lua — diagonal uses dist (not and condition) =======
-- ===============================================================================
-- ================================================================================

helpers.describe("gestures/engine.lua: diagonal detection uses total distance (audit-v5)", function()

	-- computeDir() (which owns the diagonal-distance guard) was extracted from
	-- gestures/engine.lua into the self-contained gestures/geometry.lua. Read
	-- both so the guard assertions survive that move (move-resilient).
	local function read_geometry_src()
		return (read_source("modules/gestures/engine.lua") or "") ..
			"\n" .. (read_source("modules/gestures/geometry.lua") or "")
	end

	helpers.it("old `adx >= diagMin and ady >= diagMin` pattern is gone", function()
		local src = read_geometry_src()
		helpers.assert_true(
			not src:find("adx >= diagMin and ady >= diagMin", 1, true),
			"engine/geometry must not use `adx >= diagMin and ady >= diagMin` (requires 2x distance)")
	end)

	helpers.it("diagonal check uses `dist >= diagMin`", function()
		local src = read_geometry_src()
		helpers.assert_true(
			src:find("dist >= diagMin", 1, true) ~= nil,
			"engine/geometry diagonal check must use `dist >= diagMin` (Manhattan total distance)")
	end)

end)





-- =================================================================================
-- ================================================================================
-- ======= 2/ api_mlx.lua — reset_endpoints arms a 15s PGID-pending timeout =======
-- ================================================================================
-- =================================================================================

helpers.describe("modules/llm/api_mlx.lua: PGID-pending safety timeout (audit-v5)", function()

	helpers.it("declares _pgid_pending_timeout variable", function()
		local src = read_source("modules/llm/api_mlx.lua")
		helpers.assert_true(
			src:find("_pgid_pending_timeout", 1, true) ~= nil,
			"api_mlx.lua must declare _pgid_pending_timeout for the safety-timeout handle")
	end)

	helpers.it("reset_endpoints arms a TimerScheduler.after(15", function()
		local src = read_source("modules/llm/api_mlx.lua")
		-- Find the reset_endpoints function body
		local idx = src:find("function M%.reset_endpoints%(", 1, false)
		helpers.assert_true(idx ~= nil, "reset_endpoints must exist in api_mlx.lua")
		-- Extract up to the closing `end` of that function
		local rest = src:sub(idx)
		local _, stop = rest:find("\nend\n")
		local body = stop and rest:sub(1, stop) or rest
		helpers.assert_true(
			body:find("TimerScheduler%.after%(15", 1, false) ~= nil,
			"reset_endpoints must call TimerScheduler.after(15...) to arm the PGID-pending safety timeout")
	end)

	helpers.it("timeout callback clears _server_pgid_pending", function()
		local src = read_source("modules/llm/api_mlx.lua")
		local idx = src:find("function M%.reset_endpoints%(", 1, false)
		local rest = src:sub(idx)
		local _, stop = rest:find("\nend\n")
		local body = stop and rest:sub(1, stop) or rest
		helpers.assert_true(
			body:find("_server_pgid_pending%s*=%s*false", 1, false) ~= nil,
			"reset_endpoints timeout must set _server_pgid_pending = false on expiry")
	end)

end)




-- ================================================================================
-- ================================================================================
-- ======= 3/ keymap/init.lua — stale expected_synthetic_chars is purged ==========
-- ================================================================================
-- ================================================================================

helpers.describe("modules/keymap/init.lua: stale synthetic buffer purged on miss (audit-v5)", function()

	helpers.it("else branch clears expected_synthetic_chars after missed match", function()
		local src = read_source("modules/keymap/init.lua")
		-- The fix adds an `else` after the `elseif dt < 0.02` tolerance window that
		-- sets CoreState.expected_synthetic_chars = "" when a real keystroke (dt >= 20ms)
		-- does not match the pending synthetic buffer.
		helpers.assert_true(
			src:find('CoreState%.expected_synthetic_chars%s*=%s*""', 1, false) ~= nil,
			'keymap/init.lua must clear expected_synthetic_chars to "" in the stale-miss else branch')
	end)

	-- The purge used to be pinned to its position after an `elseif dt < 0.02`
	-- tolerance window, which made the WINDOW part of the protected contract. The
	-- window was itself a defect: it classified any keystroke arriving within
	-- 20 ms of the previous one as our own echo and dropped it from the buffer,
	-- so a fast typist's real characters stayed on screen but stopped being
	-- tracked — and the next expansion sized its backspaces against a buffer
	-- shorter than the line, erasing text the user had typed. The invariant worth
	-- protecting was never "a 20 ms window exists"; it is "an unmatched keystroke
	-- is classified by PROVENANCE, and a stale expectation is purged". That is
	-- what these two now assert, and neither can pass against the old code.
	helpers.it("no timing window is allowed to decide whether a keystroke is ours", function()
		local src = read_source("modules/keymap/init.lua")
		helpers.assert_true(
			src:find("elseif dt < 0%.02 then", 1, false) == nil,
			"the dt < 0.02 tolerance window must NOT come back: typing speed is not evidence "
				.. "of provenance, and treating it as such silently drops the user's own "
				.. "keystrokes from the buffer")
	end)

	helpers.it("the synthetic filter branches on event provenance instead", function()
		local src = read_source("modules/keymap/init.lua")
		local filter_pos = src:find("CRUCIAL SYNTHETIC FILTER", 1, true)
		helpers.assert_true(filter_pos ~= nil,
			"the synthetic filter block must still exist — without it this test guards nothing")
		local tail = src:sub(filter_pos)
		local ours_pos  = tail:find("event_is_ours%(%)")
		local clear_pos = tail:find('CoreState%.expected_synthetic_chars%s*=%s*""')
		helpers.assert_true(ours_pos ~= nil,
			"the filter must consult event_is_ours() — the source-PID test is the only thing "
				.. "that actually distinguishes our echo from a human keystroke")
		helpers.assert_true(clear_pos ~= nil,
			"a stale expectation must still be purged, or it absorbs the keystrokes that follow")
	end)

end)




-- =========================================================================
-- =========================================================================
-- ======= 4/ init.lua — grep -c . uses || true for set -e safety ==========
-- =========================================================================
-- =========================================================================

helpers.describe("boot_cleanup.lua: grep -c . is guarded with || true (audit-v5)", function()

	helpers.it("grep -c . is followed by || true", function()
		-- The MLX boot kill_cmd was extracted from init.lua into the
		-- modules/llm/boot_cleanup.lua sibling; the set -e guard moved with it.
		local fh = io.open(DRIVER_ROOT .. "modules/llm/boot_cleanup.lua", "r")
		assert(fh, "cannot open boot_cleanup.lua")
		local src = fh:read("*a")
		fh:close()
		helpers.assert_true(
			src:find("grep -c . || true", 1, true) ~= nil,
			"boot_cleanup.lua kill_cmd must use `grep -c . || true` to survive set -e shells")
	end)

end)
