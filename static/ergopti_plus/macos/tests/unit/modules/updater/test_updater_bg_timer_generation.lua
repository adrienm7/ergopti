--- tests/unit/modules/updater/test_updater_bg_timer_generation.lua

--- Regression test for lib-update-02: updater.lua background_tick() had no
--- generation guard on its asyncGet callback. Switching channels mid-flight
--- allowed a stale response from the old channel to overwrite _cached_release
--- and _update_state with data from the wrong channel.
---
--- Fix: the timer closure captures the start generation and passes it into
--- background_tick; both the timer entry and HTTP completion reject it after a
--- stop/channel switch.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/updater/init.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("function M.unwrap_first_prerelease_json")
helpers.assert_true(src ~= nil, "modules/updater/init.lua source must be locatable")

-- Test 1: _poll_generation state variable must be declared.
local has_gen_var = src:find("local _poll_generation", 1, true) ~= nil
helpers.assert_true(
	has_gen_var,
	"updater.lua must declare _poll_generation counter (lib-update-02)"
)

-- Test 2: background_tick must receive the timer's captured generation.
local tick_pos = src:find("local function background_tick(", 1, true)
helpers.assert_true(tick_pos ~= nil, "updater.lua must define background_tick (lib-update-02)")
local async_pos = src:find("asyncGet", tick_pos, true)
helpers.assert_true(async_pos ~= nil, "background_tick must call asyncGet (lib-update-02)")
local tick_body = src:sub(tick_pos, async_pos - 1)
local has_entry_guard = tick_body:find("generation ~= _poll_generation", 1, true) ~= nil
helpers.assert_true(
	has_entry_guard,
	"background_tick must reject a stale timer generation before asyncGet (lib-update-02)"
)

-- Test 3: the asyncGet callback must guard on generation mismatch too.
local cb_body = src:sub(async_pos, async_pos + 500)
local has_gen_check = cb_body:find("generation ~= _poll_generation", 1, true) ~= nil
helpers.assert_true(
	has_gen_check,
	"asyncGet callback must check generation ~= _poll_generation (lib-update-02)"
)

-- Test 4: stop_background_checks must bump the generation.
local stop_pos = src:find("function M.stop_background_checks()", 1, true)
helpers.assert_true(stop_pos ~= nil, "updater.lua must define M.stop_background_checks (lib-update-02)")
local stop_body = src:sub(stop_pos, stop_pos + 300)
local has_stop_bump = stop_body:find("_poll_generation = _poll_generation + 1", 1, true) ~= nil
helpers.assert_true(
	has_stop_bump,
	"M.stop_background_checks must increment _poll_generation (lib-update-02)"
)

print("[PASS] test_updater_bg_timer_generation")
