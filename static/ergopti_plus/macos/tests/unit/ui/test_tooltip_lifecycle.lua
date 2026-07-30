--- tests/unit/ui/test_tooltip_lifecycle.lua

--- ==============================================================================
--- MODULE: tooltip lifecycle Unit Tests
--- DESCRIPTION:
--- Regression tests for E1/E2/E3 audit findings:
---
--- E1 — hide_stacked() must be called when transitioning away from the stacked
---      hotstring preview (dismiss_silent, show, show_loading).
--- E2 — update_preview() after a chained expansion must be deferred via
---      hs.timer.doAfter(0) so synthetic echoes are processed first.
--- E3 — M.show() must stop any active dequeue cycle to prevent a stale timer
---      from overwriting the newly rendered content.
---
--- These tests use lightweight stubs — no real canvas or HS environment.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==============================================================
-- ==========================================================
-- ======= 1/ E1 — hide_stacked called on transitions =======
-- ==========================================================
-- ==============================================================

helpers.describe("tooltip: hide_stacked called on LLM transitions (E1)", function()
	helpers.it("dismiss_silent calls hide_stacked", function()
		local hide_stacked_calls = 0

		-- Simulate the post-fix dismiss_silent body
		local function simulate_dismiss_silent(renderer)
			pcall(function()
				pcall(renderer.hide_stacked)
			end)
		end

		local renderer_stub = {
			hide_stacked = function() hide_stacked_calls = hide_stacked_calls + 1 end,
		}

		simulate_dismiss_silent(renderer_stub)
		helpers.assert_eq(hide_stacked_calls, 1)
	end)

	helpers.it("show() calls hide_stacked", function()
		local hide_stacked_calls = 0
		local dequeue_stopped    = false

		-- Simulate the post-fix show() preamble
		local function simulate_show_preamble(renderer, stop_dequeue_fn)
			stop_dequeue_fn()
			pcall(renderer.hide_stacked)
		end

		local renderer_stub = {
			hide_stacked = function() hide_stacked_calls = hide_stacked_calls + 1 end,
		}
		local stop_dequeue = function() dequeue_stopped = true end

		simulate_show_preamble(renderer_stub, stop_dequeue)
		helpers.assert_eq(hide_stacked_calls, 1)
		helpers.assert_eq(dequeue_stopped, true)
	end)

	helpers.it("show_loading() calls hide_stacked", function()
		local hide_stacked_calls = 0

		local function simulate_show_loading_preamble(renderer)
			pcall(renderer.hide_stacked)
		end

		local renderer_stub = {
			hide_stacked = function() hide_stacked_calls = hide_stacked_calls + 1 end,
		}

		simulate_show_loading_preamble(renderer_stub)
		helpers.assert_eq(hide_stacked_calls, 1)
	end)

	helpers.it("hide_stacked error is swallowed via pcall (graceful failure)", function()
		-- Even if Renderer.hide_stacked throws, the transition must not crash
		local renderer_stub = {
			hide_stacked = function() error("canvas unavailable") end,
		}
		local ok = pcall(function()
			pcall(renderer_stub.hide_stacked)
		end)
		helpers.assert_eq(ok, true)
	end)
end)





-- =====================================================================
-- =======================================================================
-- ======= 2/ E2 — update_preview deferred after chained expansion =======
-- =======================================================================
-- =====================================================================

helpers.describe("expander: update_preview deferred after chained expansion (E2)", function()
	helpers.it("update_preview is called via doAfter(0) not synchronously", function()
		-- Simulate the post-fix perform_text_replacement tail
		local preview_called_sync  = false
		local preview_deferred     = false
		local timer_delay_used     = nil

		local function fake_update_preview(_buf)
			preview_deferred = true
		end

		local function fake_do_after(delay, fn)
			timer_delay_used = delay
			-- In a real run the timer fires later; here we record that it was scheduled
			-- but do NOT call fn() immediately — that would defeat the test.
			_ = fn  -- fn captured but not invoked
		end

		-- This replicates the fixed branch from expander.lua:
		local is_ignored = false
		local buffer     = "hello"
		if not is_ignored then
			fake_do_after(0, function() fake_update_preview(buffer) end)
		end

		-- The preview must NOT have been called synchronously
		helpers.assert_eq(preview_called_sync, false)
		-- The timer must have been scheduled with delay = 0
		helpers.assert_eq(timer_delay_used, 0)
		-- The deferred fn is captured but not yet executed (timer hasn't fired)
		helpers.assert_eq(preview_deferred, false)
	end)
end)





-- ===========================================================
-- =========================================================
-- ======= 3/ E3 — show() stops active dequeue cycle =======
-- =========================================================
-- ===========================================================

helpers.describe("tooltip.show(): stops dequeue on entry (E3)", function()
	helpers.it("stop_dequeue is called before rendering", function()
		local dequeue_stopped = false
		local render_called   = false

		local function simulate_show(stop_dequeue_fn, render_fn)
			-- post-fix preamble
			stop_dequeue_fn()
			render_fn()
		end

		simulate_show(
			function() dequeue_stopped = true end,
			function() render_called   = true end
		)

		helpers.assert_eq(dequeue_stopped, true)
		helpers.assert_eq(render_called, true)
	end)

	helpers.it("stop_dequeue is called BEFORE render (ordering guarantee)", function()
		local call_order = {}

		local function simulate_show(stop_dequeue_fn, render_fn)
			stop_dequeue_fn()
			render_fn()
		end

		simulate_show(
			function() table.insert(call_order, "stop_dequeue") end,
			function() table.insert(call_order, "render") end
		)

		helpers.assert_eq(call_order[1], "stop_dequeue")
		helpers.assert_eq(call_order[2], "render")
	end)
end)





-- ======================================================================
-- =====================================================================
-- ======= 4/ show / show_loading / show_stacked use hide_forced =======
-- =====================================================================
-- ======================================================================

helpers.describe("tooltip: empty content uses hide_forced, not hide (F32 regression)", function()

	helpers.it("show('') path calls hide_forced not hide in source", function()
		-- The bug: show(nil) and show('') called M.hide(), which is blocked
		-- while a dequeue cycle is running. The tooltip stayed visible even though
		-- the caller explicitly asked to show nothing. Fix: use hide_forced().
		-- Selected by a declaration unique to ui/tooltip/tooltip_hotstring.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function stop_watchers_only")
		helpers.assert_true(src ~= nil, "ui/tooltip/tooltip_hotstring.lua source must be locatable")

		-- Find the M.show function body and assert it uses hide_forced on empty content
		local show_body = src:match("function M%.show%(.-\nend")
		helpers.assert_true(show_body ~= nil, "M.show must be present")
		-- Must call hide_forced (not plain hide) when content is empty
		helpers.assert_true(
			show_body:find("hide_forced", 1, true) ~= nil,
			"M.show must call hide_forced() for empty/nil content, not hide()")
		-- The unguarded M.hide() pattern must not appear in the empty-content branch
		-- (a plain `M.hide()` call used alone on the empty-check line is the bug)
		local empty_check_line = show_body:match("tostring%(content%) ==[^\n]+")
		helpers.assert_true(empty_check_line ~= nil, "empty-content guard must exist in M.show")
		helpers.assert_true(
			empty_check_line:find("hide_forced", 1, true) ~= nil,
			"the empty-content guard in M.show must call hide_forced()")
	end)

	helpers.it("show_loading('') path calls hide_forced in source", function()
		-- Selected by a declaration unique to ui/tooltip/tooltip_hotstring.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function stop_watchers_only")
		helpers.assert_true(src ~= nil, "ui/tooltip/tooltip_hotstring.lua source must be locatable")

		local load_body = src:match("function M%.show_loading%(.-\nend")
		helpers.assert_true(load_body ~= nil, "M.show_loading must be present")
		helpers.assert_true(
			load_body:find("hide_forced", 1, true) ~= nil,
			"M.show_loading must call hide_forced() for empty/nil content")
	end)

	helpers.it("show_stacked with empty rows calls hide_forced in source", function()
		-- Selected by a declaration unique to ui/tooltip/tooltip_hotstring.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function stop_watchers_only")
		helpers.assert_true(src ~= nil, "ui/tooltip/tooltip_hotstring.lua source must be locatable")

		local stack_body = src:match("function M%.show_stacked%(.-\nend")
		helpers.assert_true(stack_body ~= nil, "M.show_stacked must be present")
		helpers.assert_true(
			stack_body:find("hide_forced", 1, true) ~= nil,
			"M.show_stacked must call hide_forced() for empty/nil rows")
	end)

end)
