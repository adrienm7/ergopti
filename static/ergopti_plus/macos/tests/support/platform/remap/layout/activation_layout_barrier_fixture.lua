--- tests/support/platform/remap/layout/activation_layout_barrier_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_activation_layout_barrier
--- DESCRIPTION:
--- Prelude shared by the test_activation_layout_barrier_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_remap = require("tests.support.activation_layout_fixture").with_remap

--- Returns whether a flat list contains one exact value.
--- @param values table Values to scan.
--- @param expected any Exact value to find.
--- @return boolean found
local function contains(values, expected)
	for _, value in ipairs(values) do
		if value == expected then return true end
	end
	return false
end


--- Counts exact occurrences in a flat list.
--- @param values table Values to scan.
--- @param expected any Exact value to count.
--- @return integer count
local function count_value(values, expected)
	local count = 0
	for _, value in ipairs(values) do
		if value == expected then count = count + 1 end
	end
	return count
end


--- Completes the fresh post-layout generation and proves one final result.
--- @param calls table Harness observations and drivers.
--- @param stale_token string Exact invalidated token.
--- @param expected_layout string Settled layout revision.
--- @param results table Public callback results.
--- @param expected_ok boolean Expected public result after recovery.
--- @return table replacement Fresh build descriptor.
local function complete_replacement(calls, stale_token, expected_layout, results, expected_ok)
	local built = calls.drain_until(function() return #calls.builds >= 2 end)
	helpers.assert_true(built,
		"the retained activation intent must rebuild automatically after TIS settles")
	local replacement = calls.builds[#calls.builds]
	helpers.assert_true(replacement.token ~= stale_token,
		"a layout-invalidated generation must never reuse its fenced token")
	helpers.assert_eq(replacement.layout, expected_layout,
		"the replacement must consume the post-TIS layout")

	if calls.phase == "starting" then
		helpers.assert_true(calls.deliver_ready(replacement.token),
			"the fresh worker must retain a READY callback")
	end
	helpers.assert_eq(count_value(calls.resume_tokens, replacement.token), 1,
		"the fresh token must receive exactly one RESUME")
	helpers.assert_true(calls.deliver_resumed(replacement.token),
		"the fresh token must retain its RESUMED callback")
	helpers.assert_eq(#results, 1, "the originating user intent must settle exactly once")
	helpers.assert_eq(results[1].ok, expected_ok)
	helpers.assert_eq(calls.phase, "active")
	helpers.assert_eq(calls.status_token, replacement.token)
	return replacement
end


--- Activates the fixture's initial generation and returns its exact token.
--- @param remap table Real remap orchestrator under test.
--- @param calls table Harness observations and drivers.
--- @return string token
local function activate_initial_generation(remap, calls)
	helpers.assert_true(remap.regenerate())
	helpers.assert_eq(calls.guardian_probe_calls, 1,
		"bundled regeneration must cross one fresh guardian-ready proof")
	local initial = calls.builds[#calls.builds]
	helpers.assert_type(initial, "table")
	helpers.assert_true(calls.deliver_all_ready(initial.token))
	helpers.assert_true(calls.deliver_resumed(initial.token))
	helpers.assert_eq(calls.phase, "active")
	return initial.token
end


--- Completes one background safety recovery with a fresh exact token.
--- @param calls table Harness observations and drivers.
--- @param stale_token string Token fenced by the failed maintenance attempt.
--- @param expected_layout string Layout that the replacement must consume.
--- @return table replacement Fresh build descriptor.
local function complete_failure_recovery(calls, stale_token, expected_layout)
	local started = calls.drain_until(function()
		return calls.phase == "starting" and calls.current_token ~= stale_token
	end)
	helpers.assert_true(started,
		"a proven failure fence must launch one bounded fresh-token recovery")
	local replacement = calls.builds[#calls.builds]
	helpers.assert_type(replacement, "table")
	helpers.assert_true(replacement.token ~= stale_token,
		"failure recovery must never reuse the fenced generation")
	helpers.assert_eq(replacement.layout, expected_layout,
		"failure recovery must build from the current settled layout")
	helpers.assert_true(calls.deliver_all_ready(replacement.token))
	helpers.assert_true(calls.deliver_resumed(replacement.token))
	helpers.assert_eq(calls.phase, "active")
	helpers.assert_eq(calls.status_token, replacement.token)
	local build_count = #calls.builds
	local token_index = calls.token_index
	for _ = 1, 20 do
		if not calls.fire_next_async_timer() then break end
	end
	calls.force_stale_successes()
	helpers.assert_eq(#calls.builds, build_count,
		"stale layout/fence callbacks must not launch a duplicate recovery")
	helpers.assert_eq(calls.token_index, token_index,
		"one proven fence must allocate exactly one replacement token")
	helpers.assert_eq(calls.phase, "active")
	return replacement
end


--- Drives an event arriving after build but before READY.
--- @param calls table Harness observations and drivers.
--- @param results table Public callback results.
--- @param expected_ok boolean Expected final public result.
--- @return table replacement Fresh build descriptor.
local function race_before_ready(calls, results, expected_ok)
	helpers.assert_true(#calls.builds >= 1, "the activation must build layout A before the race")
	local stale = calls.builds[#calls.builds]
	helpers.assert_eq(stale.layout, "layout-a")
	calls.change_layout("layout-b")

	-- A correct implementation may fence immediately at notification time or at
	-- READY. Drive READY only when the old worker still owns that boundary.
	if calls.phase == "starting" then
		helpers.assert_true(calls.deliver_ready(stale.token),
			"the stale worker must retain its READY callback until fenced")
	end
	helpers.assert_eq(count_value(calls.resume_tokens, stale.token), 0,
		"layout A must never receive RESUME after layout B was observed")
	helpers.assert_true(contains(calls.stop_exact_tokens, stale.token),
		"the exact layout-A token must be fenced before retry")
	helpers.assert_eq(#results, 0,
		"fencing an internal stale attempt must not fail the originating user intent")
	calls.force_stale_successes()
	helpers.assert_eq(#results, 0,
		"a forced late callback from token A must remain unable to settle the intent")
	return complete_replacement(calls, stale.token, "layout-b", results, expected_ok)
end

return {
	activate_initial_generation = activate_initial_generation,
	complete_failure_recovery = complete_failure_recovery,
	complete_replacement = complete_replacement,
	contains = contains,
	count_value = count_value,
	race_before_ready = race_before_ready,
	with_remap = with_remap,
}
