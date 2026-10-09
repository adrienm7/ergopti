--- tests/unit/adapters/test_http_client_supersede_race.lua

--- ==============================================================================
--- MODULE: Regression — HttpClient generation guard discards superseded replies (F-HIGH-9)
--- DESCRIPTION:
--- A single HttpClient instance keeps exactly one slot each for _active_task /
--- _timeout_timer / _cancelled. post() cancels any in-flight request and resets
--- _cancelled unconditionally for the new one — but cancel() cannot GUARANTEE
--- the underlying hs.http.asyncPost/asyncGet has not already queued its OS-level
--- completion before cancel() runs. Two backends share exactly this pattern
--- (modules/llm/api_ollama.lua's warmup() and post_and_parse() both post()
--- through the same _infer_client instance) — a superseded warmup POST's stale
--- callback firing after a newer real-inference POST has reused the shared
--- slots would deliver a wrong/stale result to the wrong caller.
---
--- Fix: adapters/http_client.lua now stamps every post()/get() call with a
--- monotonic per-instance generation counter (mirroring modules/updater/init.lua's
--- _poll_generation). The wrapped callback captures its own generation and
--- discards itself if the instance's generation has moved on by the time the
--- OS-level completion arrives — regardless of callback firing order.
---
--- This test stubs hs.http so asyncPost captures (rather than immediately
--- fires) its completion callback, giving full control over callback-ordering:
--- it starts a first "warmup" POST, then starts a second "real" POST (which
--- calls cancel() on the first internally), then fires the FIRST request's
--- captured callback AFTER the second was started — simulating the OS
--- delivering the stale response late. Only the second (current) callback
--- must ever receive a result.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================================================
-- ======================================================================
-- ======= 1/ Behaviour: stale callback discarded after supersede =======
-- ======================================================================
-- ======================================================================

helpers.describe("HttpClient: superseded request's stale callback is discarded (F-HIGH-9)", function()

	helpers.it("does not deliver a stale warmup result after a newer real request superseded it", function()
		-- Capture each asyncPost's callback instead of firing it synchronously,
		-- so this test controls exactly when each "OS-level" response arrives.
		local captured_callbacks = {}
		local hs_overrides = {
			http = {
				asyncPost = function(url, _body, _headers, callback)
					table.insert(captured_callbacks, { url = url, callback = callback })
					-- Native settlement cannot retract an already-queued completion,
					-- so the generation fence remains the terminal ownership guard
					return { cancel = function() return true end }
				end,
				asyncGet = function(_url, _headers, _callback)
					return { cancel = function() return true end }
				end,
			},
			timer = {
				new = function(_delay, _fn)
					local timer = {}
					function timer:start() return self end
					function timer:stop() return self end
					return timer
				end,
			},
		}

		package.loaded["adapters.http_client"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		local HttpClient = helpers.load_with_stubs("adapters.http_client", hs_overrides)
		local client = HttpClient.new()

		local warmup_result = nil
		local real_result    = nil

		-- Request #1: the "warmup" POST — its OS-level completion has not arrived yet.
		client.post("http://x/warmup", {}, "{}", function(r) warmup_result = r end)
		helpers.assert_eq(#captured_callbacks, 1, "first post() must register exactly one asyncPost call")

		-- Request #2: the "real inference" POST supersedes request #1 (post()
		-- internally calls cancel() on the still-active first request, then
		-- issues its own asyncPost — mirrors api_ollama.lua's shared _infer_client
		-- between M.warmup() and post_and_parse()).
		client.post("http://x/real", {}, "{}", function(r) real_result = r end)
		helpers.assert_eq(#captured_callbacks, 2, "second post() must register a second asyncPost call")

		-- Simulate the STALE warmup response arriving late — AFTER the real
		-- request has already been dispatched and reused the shared slots.
		captured_callbacks[1].callback(200, '{"warmup":true}', {})

		helpers.assert_nil(warmup_result,
			"a superseded request's stale callback must be discarded, not delivered to its caller")
		helpers.assert_true(real_result == nil,
			"the stale warmup callback must not accidentally satisfy the real request's callback either")

		-- Now the REAL response arrives — it must be delivered normally.
		captured_callbacks[2].callback(200, '{"real":true}', {})

		helpers.assert_true(real_result ~= nil, "the current (non-superseded) request's callback must fire")
		helpers.assert_eq(real_result.status, 200, "the real request's result must carry its own response")
		helpers.assert_nil(warmup_result, "the warmup callback must remain undelivered even after the real one fires")
	end)

	helpers.it("delivers the result normally when there is no supersede race", function()
		local captured_callbacks = {}
		local hs_overrides = {
			http = {
				asyncPost = function(url, _body, _headers, callback)
					table.insert(captured_callbacks, { url = url, callback = callback })
					return { cancel = function() end }
				end,
			},
			timer = {
				new = function(_delay, _fn)
					local timer = {}
					function timer:start() return self end
					function timer:stop() return self end
					return timer
				end,
			},
		}

		package.loaded["adapters.http_client"] = nil
		package.loaded["adapters.timer_scheduler"] = nil
		local HttpClient = helpers.load_with_stubs("adapters.http_client", hs_overrides)
		local client = HttpClient.new()

		local result = nil
		client.post("http://x/solo", {}, "{}", function(r) result = r end)
		captured_callbacks[1].callback(200, '{"ok":true}', {})

		helpers.assert_true(result ~= nil, "a single non-superseded request must still deliver its result")
		helpers.assert_eq(result.status, 200, "the delivered result must carry the correct status")
	end)
end)
