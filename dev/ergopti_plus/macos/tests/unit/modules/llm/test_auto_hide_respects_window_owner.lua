--- tests/unit/modules/llm/test_auto_hide_respects_window_owner.lua

--- ==============================================================================
--- MODULE: Regression — a deferred hide must not close someone else's window
--- DESCRIPTION:
--- Finishing the MLX bootstrap could tear down an unrelated model download's
--- progress window a second and a half later, leaving that download running with
--- nothing on screen.
---
--- ROOT CAUSE ENCODED:
--- ui.download_window is a shared, single-instance surface. On a successful sync
--- the MLX deps checker armed hs.timer.doAfter(SUCCESS_AUTO_HIDE_SEC, hide) — an
--- uncancellable timer holding no notion of WHICH window it meant to close. If a
--- model download or the Ollama bootstrap claimed the window during that delay,
--- the timer hid theirs.
---
--- WHY IT WAS SILENT:
--- Hiding a window is not an error. The download kept running and completed
--- normally; only its UI vanished, which reads as "the window closed itself"
--- rather than as another subsystem reaching across and closing it.
---
--- THE FIX:
--- download_window now exposes a monotonic session_id(), bumped by every show().
--- The deferred hide captures it and re-checks before firing, so it can only ever
--- close the window it was armed for.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==================================================
-- ==================================================
-- ======= 1/ The Window Identifies Its Owner =======
-- ==================================================
-- ==================================================

helpers.describe("download_window identifies which operation owns it", function()
	--- Loads the shared progress window with the webview machinery stubbed out.
	--- @return table
	local function load_window()
		package.loaded["ui.download_window"] = nil
		return helpers.load_with_stubs("ui.download_window")
	end

	helpers.it("exposes a session id", function()
		local W = load_window()
		helpers.assert_eq(type(W.session_id), "function",
			"a shared single-instance window must let callers identify its current occupant, "
			.. "otherwise a deferred action cannot tell whether it still applies")
	end)

	helpers.it("bumps the session id on every show", function()
		local W = load_window()
		local before = W.session_id()
		pcall(W.show, { kind = "mlx_install" })
		local after = W.session_id()

		helpers.assert_true(after ~= before, string.format(
			"show() must invalidate the previous occupant's identity (%s -> %s). Without a "
			.. "change here, a hide armed by the previous operation still matches and fires "
			.. "against the new one", tostring(before), tostring(after)))
	end)

	helpers.it("keeps the session id stable while the same operation owns it", function()
		local W = load_window()
		pcall(W.show, { kind = "mlx_install" })
		local sid = W.session_id()
		pcall(W.set_step, "step")
		pcall(W.set_progress, 50)

		helpers.assert_eq(W.session_id(), sid,
			"progress updates must NOT bump the session — only a new show() does. Bumping on "
			.. "every update would make a legitimate deferred hide never fire")
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 2/ The Deferred Hide Checks The Owner =======
-- =====================================================
-- =====================================================

helpers.describe("the MLX auto-hide only closes the window it armed for", function()
	helpers.it("re-checks the session before hiding", function()
		-- Selected by a declaration unique to modules/llm/mlx_deps_checker.lua
		-- rather than by path, so moving the module cannot turn this into a path
		-- error. The bootstrap needs a real uv sync to observe behaviourally; what
		-- is decidable is that the deferred hide is guarded by the owner check.
		local src = helpers.read_driver_source("SUCCESS_AUTO_HIDE_SEC")
		helpers.assert_true(src ~= nil, "mlx_deps_checker source must be locatable")
		if not src then return end

		local arm_at = src:find("doAfter%(SUCCESS_AUTO_HIDE_SEC")
		helpers.assert_true(arm_at ~= nil, "the deferred auto-hide must be locatable")
		if not arm_at then return end

		-- Look just before and inside the timer body for the ownership check.
		local window = src:sub(math.max(1, arm_at - 400), arm_at + 600)
		helpers.assert_true(window:find("session_id", 1, true) ~= nil,
			"the deferred hide must capture and re-check download_window.session_id(). "
			.. "Unguarded, it closes whatever operation owns the shared window when the "
			.. "timer fires — a model download loses its UI while still downloading")
	end)

	helpers.it("degrades safely when the window exposes no session id", function()
		local src = helpers.read_driver_source("SUCCESS_AUTO_HIDE_SEC")
		if not src then return end

		local arm_at = src:find("doAfter%(SUCCESS_AUTO_HIDE_SEC")
		if not arm_at then return end
		local window = src:sub(math.max(1, arm_at - 400), arm_at + 600)

		-- The type guard has MOVED, not gone. The session is now captured when the
		-- window is CLAIMED rather than sampled at completion — sampling later
		-- reads whichever operation owns the surface by then, which is exactly
		-- the one that must not be touched — and the guard lives in the shared
		-- owned_session() helper that performs the capture. The invariant is
		-- unchanged: a build without the accessor must degrade to hiding as
		-- before, never raise inside a timer callback where the error is
		-- swallowed to the Console.
		local guard_src = helpers.read_driver_source("owned_session")
		helpers.assert_true(guard_src ~= nil and guard_src ~= "",
			"the ownership capture helper must exist")
		helpers.assert_true(guard_src:find('type%(llm_progress%.session_id%)') ~= nil,
			"the capture must be type-guarded so a download_window build without the accessor "
			.. "still hides as before rather than raising inside a timer callback, where the "
			.. "error would be swallowed to the Hammerspoon Console")
		helpers.assert_true(guard_src:find("pcall", 1, true) ~= nil,
			"and the accessor call itself must be pcall-wrapped for the same reason")
	end)
end)
