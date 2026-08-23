--- tests/unit/modules/llm/test_mlx_superseded_requests.lua

--- ==============================================================================
--- MODULE: Regression — an abandoned MLX request must not damage its successor
---         (mlx-superseded-requests)
--- DESCRIPTION:
--- Two variants of the same mistake: state belonging to the request that is
--- LIVE, mutated by one that has already been abandoned.
---
--- ROOT CAUSE ENCODED:
---   1. Nothing cancels a non-streaming request's 8 s timeout when a newer
---      request supersedes it, so it still fired and called on_fail — and
---      on_fail is a retry path, which cancels streaming and tore down the
---      transport of the request that was actually running. The abandoned
---      request killed its successor.
---   2. The warmup POST timeout abandoned its request and scheduled a retry
---      WITHOUT bumping the warmup generation, so the late reply still matched
---      the generation check and flipped readiness on behalf of a request
---      nobody was waiting for. And the response handler cancelled whichever
---      timeout was currently stored rather than its own — after a retry that
---      is the NEW POST's timer, so a late reply disarmed the live request's
---      only hard timeout and warmup POSTs piled up unbounded.
---
--- WHY THEY WERE SILENT: both failure modes need a timeout to have fired
--- first — a slow model load, a stalled GPU stream — so they never appear in
--- normal operation, only in the situation that was already going wrong.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
-- ================================================================
-- ======= 1/ A superseded request's timeout stays quiet ==========
-- ================================================================
-- ================================================================

helpers.describe("MLX non-streaming: a superseded request does not report failure", function()
	helpers.it("the timeout checks it is still the newest request", function()
		local src = helpers.read_driver_source("NON_STREAM_TIMEOUT_SEC")
		helpers.assert_true(src ~= nil and src ~= "", "the inference module must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("TimerScheduler.after(NON_STREAM_TIMEOUT_SEC", 1, true)
		helpers.assert_true(at ~= nil, "the hard timeout must still be armed")

		local body = code:sub(at, at + 700)
		local guard_at = body:find("req_id ~= _req_counter", 1, true)
		local fail_at  = body:find("on_fail", 1, true)

		helpers.assert_true(guard_at ~= nil,
			"the timeout must verify this request is still the current one. Nothing cancels it "
				.. "when a newer request starts, so it fired anyway and called on_fail — a retry "
				.. "path that cancels streaming and tears down the LIVE request's transport")
		helpers.assert_true(fail_at ~= nil, "the timeout must still be able to report a real failure")
		helpers.assert_true(guard_at < fail_at,
			"and the identity check must come BEFORE the failure report — after it, the damage "
				.. "is already done")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 2/ The warmup retry retires its predecessor ============
-- ================================================================
-- ================================================================

helpers.describe("MLX warmup: an abandoned POST cannot speak for its retry", function()
	helpers.it("the timeout bumps the warmup generation before retrying", function()
		local src = helpers.read_driver_source("WARMUP_POST_TIMEOUT_SEC")
		helpers.assert_true(src ~= nil and src ~= "", "api_mlx must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("TimerScheduler.after(WARMUP_POST_TIMEOUT_SEC", 1, true)
		helpers.assert_true(at ~= nil, "the warmup hard timeout must still be armed")

		local body = code:sub(at, at + 800)
		local bump_at  = body:find("_warmup_gen = _warmup_gen + 1", 1, true)
		local retry_at = body:find("schedule_warmup_retry(model_name, profile)", 1, true)

		helpers.assert_true(bump_at ~= nil,
			"abandoning a POST does not stop the server answering it. Without retiring the "
				.. "generation the late reply still matched the check and flipped readiness on "
				.. "behalf of the retry that had taken its place")
		helpers.assert_true(retry_at ~= nil, "the timeout must still schedule the retry")
		helpers.assert_true(bump_at < retry_at,
			"and the generation must be retired BEFORE the retry is scheduled")
	end)

	helpers.it("the response cancels its own timeout, not whichever is current", function()
		local src = helpers.read_driver_source("WARMUP_POST_TIMEOUT_SEC")
		local code = src:gsub("%-%-[^\n]*", "")

		local handler_at = code:find("local function handle_warmup_response", 1, true)
		helpers.assert_true(handler_at ~= nil, "the warmup response handler must still exist")
		local post_at = code:find("_warmup_client.post", handler_at, true)
		helpers.assert_true(post_at ~= nil, "the warmup POST must still follow its response handler")

		local body = code:sub(handler_at, post_at - 1)
		local guard_at = body:find("_warmup_timeout == _wt_handle", 1, true)
		local cancel_at = body:find('cancel_warmup_timer("timeout")', 1, true)
		helpers.assert_true(guard_at ~= nil,
			"the response must cancel only ITS OWN timer. After a timeout-triggered retry the "
				.. "slot holds the NEW POST's timeout, so a late reply from the abandoned request "
				.. "disarmed the live request's only bound — and warmup POSTs piled up with "
				.. "nothing left to stop them")
		helpers.assert_true(cancel_at ~= nil and guard_at < cancel_at,
			"the exact-handle guard must precede timeout cancellation")
	end)
end)
