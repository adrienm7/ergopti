--- tests/unit/modules/gestures/test_engine_retap_reversal.lua

--- Regression tests for two gesture engine state machine bugs:
---
--- gestures-engine-retap: rapid re-tap detection (lifting → new touch) committed
--- the current gesture and restarted tracking, but did NOT reset gs.peakN,
--- gs.peakNFirstSeen, or gs.peakNFrames. A re-tap starting with fewer fingers
--- (e.g. 2 after a 4-finger gesture) would inherit peakN=4 from the committed
--- gesture and misfire the 4-finger action for the new 2-finger gesture.
---
--- gestures-engine-reversal: an incremental rebase triggered by direction reversal
--- sets gs.liveAxisSign = nil (to allow the new direction to fire). commitGesture
--- used `gs.liveAxisSign ~= nil` to detect whether any live fire had occurred.
--- After a reversal-rebase, liveAxisSign is nil even though a live fire DID happen,
--- so the tap guard (`if not had_live_fire and total_delta < TAP_MAX_DELTA`) failed
--- to suppress the spurious tap at lift-off.
---
--- Fix: added gs.hadLiveFire, a sticky boolean set on live fire and NOT cleared
--- on rebase, cleared only at gesture start and re-tap restart. commitGesture now
--- reads gs.hadLiveFire instead of gs.liveAxisSign ~= nil.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/gestures/engine.lua"
local fh = io.open(src_path, "r")
if not fh then error("modules/gestures/engine.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1 (gestures-engine-reversal): hadLiveFire is in the initial state table.
local has_initial = src:find("hadLiveFire    = false", 1, true) ~= nil
helpers.assert_true(
	has_initial,
	"engine.lua initial gesture state must include hadLiveFire = false (gestures-engine-reversal)"
)

-- Test 2 (gestures-engine-reversal): hadLiveFire is set at incremental live fire.
local incremental_fire = src:find("gs.hadLiveFire    = true", 1, true) ~= nil
helpers.assert_true(
	incremental_fire,
	"engine.lua incremental live fire must set gs.hadLiveFire = true (gestures-engine-reversal)"
)

-- Test 3 (gestures-engine-reversal): commitGesture uses gs.hadLiveFire, not liveAxisSign ~= nil.
-- Pre-fix: `local had_live_fire = (gs.liveAxisSign ~= nil)`
local old_check = src:find("had_live_fire = (gs.liveAxisSign ~= nil)", 1, true) ~= nil
helpers.assert_true(
	not old_check,
	"engine.lua commitGesture must not use `had_live_fire = (gs.liveAxisSign ~= nil)` — cleared by rebase (gestures-engine-reversal)"
)

local new_check = src:find("had_live_fire = gs.hadLiveFire", 1, true) ~= nil
helpers.assert_true(
	new_check,
	"engine.lua commitGesture must use `had_live_fire = gs.hadLiveFire` (sticky, not cleared by rebase) (gestures-engine-reversal)"
)

-- Test 4 (gestures-engine-retap): re-tap restart block resets peakN.
-- Find the rapid re-tap block by its commit-and-restart log message.
local retap_start = src:find("Rapid re-tap detected", 1, true)
helpers.assert_true(
	retap_start ~= nil,
	"engine.lua must have a rapid re-tap detection block (gestures-engine-retap)"
)

local after_retap = src:sub(retap_start)
-- Find the closing `return` of the re-tap block
local retap_end = after_retap:find("\n\t\t\t\treturn\n", 1, true)
local retap_block = retap_end and after_retap:sub(1, retap_end) or after_retap

local resets_peakN = retap_block:find("gs.peakN", 1, true) ~= nil
helpers.assert_true(
	resets_peakN,
	"engine.lua re-tap restart block must reset gs.peakN to prevent stale peak from prior gesture (gestures-engine-retap)"
)

local resets_peakNFirstSeen = retap_block:find("gs.peakNFirstSeen", 1, true) ~= nil
helpers.assert_true(
	resets_peakNFirstSeen,
	"engine.lua re-tap restart block must reset gs.peakNFirstSeen (gestures-engine-retap)"
)

-- Test 5 (gestures-engine-retap + reversal): re-tap block resets hadLiveFire.
local resets_hadLiveFire = retap_block:find("gs.hadLiveFire    = false", 1, true) ~= nil
helpers.assert_true(
	resets_hadLiveFire,
	"engine.lua re-tap restart block must reset gs.hadLiveFire = false (gestures-engine-reversal)"
)

print("[PASS] test_engine_retap_reversal")
