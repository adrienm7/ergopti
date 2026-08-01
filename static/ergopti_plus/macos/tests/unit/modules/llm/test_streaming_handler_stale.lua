--- tests/unit/modules/llm/test_streaming_handler_stale.lua

--- ==============================================================================
--- MODULE: streaming_handler stale-success failure-counter Tests
--- DESCRIPTION:
--- Regression tests for the D4 audit finding: on_success() previously reset
--- _consecutive_llm_failures unconditionally, even for stale callbacks whose
--- fetch_id no longer matched. A stale success from a cancelled request would
--- silently zero the failure counter, masking real failures counted since the
--- new request was dispatched. After the fix, the reset occurs only AFTER the
--- stale (fetch_id) guard.
---
--- FALSE-GREEN FIX (F-HIGH-13): the previous version of this test hand-wrote
--- its own make_handler() with a bespoke on_success(my_fetch_id, is_final,
--- is_streaming_multi, is_batch_progressive) signature — completely different
--- from the real closure. The real on_success in
--- modules/llm/streaming_handler.lua is
--- on_success(raw_predictions, elapsed_ms, is_final, is_batch_progressive);
--- my_fetch_id and is_streaming_multi are upvalues captured from ctx, not
--- parameters. The old test therefore only ever measured its own clone and
--- could never catch a regression in the shipped module.
---
--- This version loads the real module via helpers.load_with_stubs and drives
--- the real Handler.build_callbacks(ctx). _consecutive_llm_failures is
--- module-private state with no getter, so it is observed indirectly through
--- its one visible side effect: on the "mlx" backend, the counter reaching
--- CONSECUTIVE_FAIL_WARN_THRESHOLD (4) triggers exactly one hs.notify.new()
--- call and resets the counter. Driving on_fail()/on_success() through the
--- real closures and counting notifications proves the stale guard and the
--- reset ordering against production code, not a hand-rolled simulation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Stubs lib.timings so the module loads without the real TOML registry.
package.loaded["infra.timings"] = {
	sec = function(_section, _key) return 5.0 end,
	ms  = function(_section, _key) return 5000 end,
}

--- Stubs modules.llm.parser — the handler requires it at load time.
package.loaded["modules.llm.parser"] = {
	strip_thinking     = function(s) return s end,
	process_prediction = function(_, _, raw) return { to_type = raw, deletes = 0, chunks = {}, nw = raw } end,
}

-- Number of consecutive failures streaming_handler.lua requires before it
-- notifies the user on the mlx backend (CONSECUTIVE_FAIL_WARN_THRESHOLD).
-- Mirrored here (not imported) because the constant is module-private;
-- kept in sync by the source-invariant test in section 1 below.
local FAIL_WARN_THRESHOLD = 4


--- Builds the minimal tooltip stub needed by on_success/on_fail (show_predictions,
--- make_diff_styled, get_current_index, tint, mark_chain_complete, hide).
--- @return table stub
local function make_tooltip_stub()
	local stub = { show_predictions_calls = 0 }
	stub.show_predictions   = function(_preds, _idx, _ai, _info, _val, _indent, _nav, _tint, _loading, _slots)
		stub.show_predictions_calls = stub.show_predictions_calls + 1
	end
	stub.hide                = function() end
	stub.get_current_index   = function() return 1 end
	stub.make_diff_styled    = function(_chunks, _nw) return true end
	stub.tint                = function(_name) return {} end
	stub.mark_chain_complete = function() end
	return stub
end

--- Builds a minimal core_llm stub bound to a fixed backend name.
--- @param backend string Backend identifier returned by get_backend().
--- @return table stub
local function make_core_llm_stub(backend)
	return {
		get_active_profile   = function() return nil end,
		get_current_model    = function() return "test-model" end,
		get_backend          = function() return backend end,
		fetch_llm_prediction = function() end,
	}
end

--- Builds a minimal keylogger stub.
--- @return table stub
local function make_keylogger_stub()
	return {
		log_llm           = function() end,
		log_llm_suggested = function() end,
	}
end

--- Builds a minimal streaming context table for a given fetch_id, mirroring the
--- real ctx table assembled in modules/llm/prediction_engine.lua.
--- @param fetch_id number The fetch_id captured at request-dispatch time.
--- @param get_fetch_id_fn function Returns the live counter (simulates a closure over state).
--- @param is_streaming_multi boolean|nil Whether streaming-multi mode is on (default false).
--- @return table ctx
local function make_ctx(fetch_id, get_fetch_id_fn, is_streaming_multi)
	return {
		buffer                     = "test buffer",
		tail                       = "",
		my_fetch_id                = fetch_id,
		get_fetch_id               = get_fetch_id_fn,
		is_streaming_enabled       = false,
		is_streaming_multi_enabled = is_streaming_multi or false,
		num_predictions            = 3,
		show_info_bar              = false,
		streaming_info_bar         = nil,
		prediction_indent          = 0,
		validation_mods            = { "none" },
		navigation_mods            = {},
		model_to_use               = "test-model",
		llm_display_name           = "Test Model",
		profile_name               = nil,
		build_info_bar_text        = function() return nil end,
		resolve_backend_label      = function() return "mlx" end,
		is_noise_pred              = function(_) return false end,
		reset_llm_dismiss_timer    = function() end,
		pending_predictions_ref    = { value = {} },
		predictions_visible_ref    = { value = false },
		is_ai_preview_enabled      = false,
	}
end

--- A single well-formed raw prediction accepted by the noise/dedup filters.
--- @return table[] One-element raw prediction array.
local function make_raw_predictions()
	return { { to_type = "bonjour", deletes = 0, chunks = {}, nw = "bonjour" } }
end

--- Loads a fresh streaming_handler instance under the given backend and
--- captures every hs.notify.new() call so the private failure counter's one
--- observable side effect can be asserted on.
--- @param backend string Backend identifier ("mlx" enables the notify path).
--- @return table Handler, table tooltip, table[] notify_calls
local function load_fresh_handler(backend)
	local notify_calls = {}
	local hs_overrides = {
		notify = {
			new = function(_title, opts)
				table.insert(notify_calls, opts)
				return { send = function() end, release = function() end }
			end,
		},
		-- The shared hs stub's frontmostApplication() lacks a :title() method
		-- (only :name()/:bundleID()); on_success calls front:title() directly,
		-- mirroring the real hs.application object's API.
		application = {
			frontmostApplication = function()
				return { title = function() return "Test" end, bundleID = function() return "test.bundle" end }
			end,
		},
	}
	package.loaded["modules.llm.streaming_handler"] = nil
	local Handler = helpers.load_with_stubs("modules.llm.streaming_handler", hs_overrides)

	local tooltip   = make_tooltip_stub()
	local core_llm  = make_core_llm_stub(backend)
	local keylogger = make_keylogger_stub()
	Handler.init({ core_llm = core_llm, tooltip = tooltip, keylogger = keylogger })
	Handler.reset_failure_count()

	return Handler, tooltip, notify_calls
end




-- ====================================================================
-- ====================================================================
-- ======= 1/ Source invariant: reset happens after the stale guard ===
-- ====================================================================
-- ====================================================================

helpers.describe("streaming_handler.on_success: reset ordered after the stale guard (source)", function()

	helpers.it("_consecutive_llm_failures = 0 appears AFTER the fetch_id stale-guard return", function()
		-- Selected by a declaration unique to modules/llm/streaming_handler.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function build_dedup_key")
		helpers.assert_true(src ~= nil, "modules/llm/streaming_handler.lua source must be locatable")

		local success_start = src:find("local function on_success", 1, true)
		helpers.assert_true(success_start ~= nil, "on_success must be defined")

		local stale_guard_pos = src:find("get_fetch_id() ~= my_fetch_id", success_start, true)
		local reset_pos       = src:find("_consecutive_llm_failures = 0", success_start, true)

		helpers.assert_true(stale_guard_pos ~= nil, "on_success must check get_fetch_id() ~= my_fetch_id")
		helpers.assert_true(reset_pos ~= nil, "on_success must reset _consecutive_llm_failures")
		helpers.assert_true(reset_pos > stale_guard_pos,
			"the failure-counter reset must appear AFTER the stale-guard check (D4 fix)")
	end)
end)





-- =============================================================
-- =============================================================
-- ======= 2/ on_success stale-guard and failure-counter =======
-- =============================================================
-- =============================================================

helpers.describe("streaming_handler.on_success: stale guard + failure counter (D4, real closure)", function()

	helpers.it("a stale on_success does NOT reset the failure counter (notification still fires at threshold)", function()
		local Handler, _tooltip, notify_calls = load_fresh_handler("mlx")

		-- Shared mutable "live" fetch-id counter, mirroring fetch_request_counter
		-- in prediction_engine.lua. The "current" request is dispatched at
		-- live id 2, so ITS on_fail() calls are non-stale and DO increment the
		-- shared _consecutive_llm_failures counter.
		local live = { id = 2 }
		local current_ctx = make_ctx(2, function() return live.id end)
		local _op1, _os1, on_fail = Handler.build_callbacks(current_ctx)

		for _ = 1, FAIL_WARN_THRESHOLD - 1 do on_fail() end
		helpers.assert_eq(#notify_calls, 0, "threshold must not be reached yet")

		-- An OLDER, already-superseded request (dispatched at fetch id 1, back
		-- when the live counter had not yet advanced to 2) has its on_success
		-- arrive late. If the bug were present (reset happens BEFORE the stale
		-- guard), this would silently zero the counter accumulated above. With
		-- the fix, the stale call must return immediately and leave it untouched.
		local stale_ctx = make_ctx(1, function() return live.id end)
		local _op2, stale_on_success, _of2 = Handler.build_callbacks(stale_ctx)
		stale_on_success(make_raw_predictions(), 42, true, false)

		-- One more failure on the CURRENT (still-live) request must now be
		-- enough to cross the threshold — proving the stale on_success did
		-- NOT reset the counter in between.
		on_fail()
		helpers.assert_eq(#notify_calls, 1,
			"the counter must still reach threshold after a stale on_success — a stale success must never reset it")
	end)

	helpers.it("a non-stale on_success DOES reset the failure counter", function()
		local Handler, _tooltip, notify_calls = load_fresh_handler("mlx")

		local live_fetch_id = 1
		local ctx = make_ctx(1, function() return live_fetch_id end)
		local _op, on_success, on_fail = Handler.build_callbacks(ctx)

		for _ = 1, FAIL_WARN_THRESHOLD - 1 do on_fail() end
		helpers.assert_eq(#notify_calls, 0, "threshold must not be reached yet")

		-- Non-stale final success: my_fetch_id (1) == live fetch_id (1).
		on_success(make_raw_predictions(), 42, true, false)

		-- The counter should now be back at 0; it takes a FULL new run of
		-- FAIL_WARN_THRESHOLD failures to notify again.
		for _ = 1, FAIL_WARN_THRESHOLD - 1 do on_fail() end
		helpers.assert_eq(#notify_calls, 0,
			"a non-stale on_success must have reset the counter — threshold must not be reached by only 1 more failure")

		on_fail()
		helpers.assert_eq(#notify_calls, 1, "one more failure after the reset must cross the threshold exactly once")
	end)

	helpers.it("does NOT reset for an intermediate batch when streaming-multi is off and not batch-progressive", function()
		local Handler, tooltip, _notify = load_fresh_handler("mlx")

		local live_fetch_id = 1
		local ctx = make_ctx(1, function() return live_fetch_id end, false)
		local _op, on_success, _of = Handler.build_callbacks(ctx)

		-- is_final=false, ctx.is_streaming_multi_enabled=false, is_batch_progressive=false -> early return
		on_success(make_raw_predictions(), 42, false, false)

		helpers.assert_eq(tooltip.show_predictions_calls, 0,
			"an intermediate batch must be suppressed when streaming-multi is off and not batch-progressive")
	end)

	helpers.it("proceeds for a streaming-multi intermediate batch (is_streaming_multi_enabled = true)", function()
		local Handler, tooltip, _notify = load_fresh_handler("mlx")

		local live_fetch_id = 1
		local ctx = make_ctx(1, function() return live_fetch_id end, true)
		local _op, on_success, _of = Handler.build_callbacks(ctx)

		-- is_final=false but ctx.is_streaming_multi_enabled=true -> passes the first guard
		on_success(make_raw_predictions(), 42, false, false)

		helpers.assert_true(tooltip.show_predictions_calls >= 1,
			"a streaming-multi intermediate batch must reach tooltip.show_predictions")
	end)
end)




-- ==========================================================================
-- ==========================================================================
-- ======= 3/ on_success tooltip side effects (real closure, non-stale) ====
-- ==========================================================================
-- ==========================================================================

helpers.describe("streaming_handler.on_success: real closure tooltip side effects", function()

	helpers.it("a stale on_success never touches tooltip or pending_predictions_ref", function()
		local Handler, tooltip, _notify = load_fresh_handler("mlx")

		local live_fetch_id = 2
		local ctx = make_ctx(1, function() return live_fetch_id end)
		local _op, on_success, _of = Handler.build_callbacks(ctx)

		on_success(make_raw_predictions(), 42, true, false)

		helpers.assert_eq(tooltip.show_predictions_calls, 0,
			"a stale on_success must return early and never call tooltip.show_predictions")
		helpers.assert_eq(#ctx.pending_predictions_ref.value, 0,
			"a stale on_success must never mutate pending_predictions_ref")
	end)

	helpers.it("a non-stale final on_success updates tooltip state and pending predictions", function()
		local Handler, tooltip, _notify = load_fresh_handler("mlx")

		local live_fetch_id = 1
		local ctx = make_ctx(1, function() return live_fetch_id end)
		local _op, on_success, _of = Handler.build_callbacks(ctx)

		on_success(make_raw_predictions(), 42, true, false)

		helpers.assert_true(tooltip.show_predictions_calls >= 1,
			"a non-stale final on_success must call tooltip.show_predictions")
		helpers.assert_true(#ctx.pending_predictions_ref.value >= 1,
			"a non-stale final on_success must populate pending_predictions_ref with the parsed result")
	end)
end)
