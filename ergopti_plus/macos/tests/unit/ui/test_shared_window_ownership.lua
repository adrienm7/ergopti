--- tests/unit/ui/test_shared_window_ownership.lua

--- ==============================================================================
--- MODULE: Regression — deferred window operations must prove they still own the
---         window (shared-window-ownership)
--- DESCRIPTION:
--- The progress/download window is a SINGLE-INSTANCE surface. The model
--- download, the MLX bootstrap and the Ollama deps checker can each claim it,
--- and each arms deferred timers against it. A timer belonging to a finished
--- operation then tears down — or worse, writes into — whatever unrelated
--- operation happens to own the window when it fires, while that operation
--- keeps running with nothing on screen.
---
--- ROOT CAUSE ENCODED: the session identity exists for exactly this, and was
--- applied to ONE deferred-hide site. Two more auto-hide timers in the window
--- module never captured it, and the deps checker captured it at bootstrap
--- COMPLETION rather than when it claimed the window — so it recorded whoever
--- owned the surface by then, which is precisely the operation it must not
--- touch. `_wv ~= nil` and `is_active()` prove only that SOME window is open.
---
--- The audit calls this an un-migrated sibling class of the commit that
--- introduced the session guard: the mechanism was built and then applied at
--- one of the four sites that need it.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ Every deferred hide captures the session first ===============
-- =========================================================================
-- =========================================================================

helpers.describe("download_window: auto-hide timers are session-guarded", function()
	helpers.it("every deferred hide captures the session before arming", function()
		local src = helpers.read_driver_source("session_id")
		helpers.assert_true(src ~= nil and src ~= "",
			"the window module must be locatable by its session_id symbol")

		local code = src:gsub("%-%-[^\n]*", "")

		-- Each deferred hide must sample the session BEFORE the timer is armed.
		-- Sampling inside the callback reads the value at fire time, which is
		-- exactly the value that cannot distinguish owner from usurper.
		local checked = 0
		local pos = 1
		while true do
			local deferred_at = code:find("DeferredWork.after", pos, true)
			local native_at = code:find("doAfter", pos, true)
			local at = deferred_at
			if native_at and (not at or native_at < at) then at = native_at end
			if not at then break end
			pos = at + 1

			local window = code:sub(at, at + 500)
			-- Scope this class to the single-instance progress window. TooltipLLM has
			-- its own session_id and generation-fenced M.hide_silent() timer; treating
			-- that separate owner as this surface makes the scan fail for being safe.
			local hides_download_window = window:find("pcall(M.hide)", 1, true) ~= nil
			local hides_dependency_window = window:find("pcall(llm_progress.hide)", 1, true) ~= nil
			if hides_download_window or hides_dependency_window then
				checked = checked + 1
				local before = code:sub(math.max(1, at - 300), at)
				-- Either evidence is acceptable: the window module captures
				-- session_id() inline, while the deps checkers hold the
				-- claim-time value in _ui_session. Both prove the timer was armed
				-- against a KNOWN owner rather than against whoever is current.
				helpers.assert_true(
					before:find("session_id", 1, true) ~= nil
						or before:find("_ui_session", 1, true) ~= nil,
					"a deferred hide arms without first capturing the session. The window is shared, "
						.. "so this timer will close whichever operation owns it when it fires — not "
						.. "necessarily the one that armed it"
				)
			end
		end

		helpers.assert_true(checked >= 2,
			"the scan must reach the real auto-hide timers (found " .. checked .. ") — a scan that "
				.. "matches nothing cannot fail")
	end)

	helpers.it("the callbacks compare the captured session against the current one", function()
		local src = helpers.read_driver_source("session_id")
		local code = src:gsub("%-%-[^\n]*", "")
		local guarded = 0
		local pos = 1
		while true do
			local at = code:find("M.session_id() ~= sid", pos, true)
			if not at then break end
			guarded = guarded + 1
			pos = at + 1
		end
		helpers.assert_true(guarded >= 2,
			"each guarded timer must compare the captured session against the live one before "
				.. "hiding (found " .. guarded .. "). Capturing without comparing protects nothing")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ The deps checker claims, then verifies =======================
-- =========================================================================
-- =========================================================================

helpers.describe("ollama_deps_checker: ownership is captured at claim time", function()
	helpers.it("the session is recorded where the window is shown", function()
		local src = helpers.read_driver_source("make_streaming_handler")
		helpers.assert_true(src ~= nil and src ~= "",
			"the deps checker must be locatable by its make_streaming_handler symbol")

		local code = src:gsub("%-%-[^\n]*", "")
		local show_at = code:find("llm_progress.show", 1, true)
		helpers.assert_true(show_at ~= nil, "the checker must still show the progress window")

		local window = code:sub(show_at, show_at + 400)
		helpers.assert_true(window:find("_ui_session", 1, true) ~= nil,
			"the session must be recorded at the moment the window is CLAIMED. Sampled later, at "
				.. "bootstrap completion, it reads whoever owns the surface by then — which is "
				.. "exactly the operation this checker must not write into or hide")
	end)

	helpers.it("the completion path verifies ownership before writing", function()
		local src = helpers.read_driver_source("make_streaming_handler")
		local code = src:gsub("%-%-[^\n]*", "")

		-- Anchored on the Ollama checker's own readiness step. read_driver_source
		-- concatenates every file naming the symbol, and the MLX checker sorts
		-- first, so a generic anchor lands in the wrong module.
		-- Anchored on the WRITE, not the label. The first occurrence of the key is
		-- its entry in the PROGRESS_LABELS table, hundreds of lines above the
		-- completion path — a lookback from there finds no guard and reports a
		-- correctly-guarded file as broken.
		local at = code:find('set_step, i18n.get("ollama.deps_step_ready")', 1, true)
		helpers.assert_true(at ~= nil, "the completion path must still report readiness")

		local ownership_at = code:find(
			"local owns_active_window = active_ok and active == true and owns_window()", 1, true)
		helpers.assert_true(ownership_at ~= nil and ownership_at < at,
			"writing the ready step and 100%% must be gated on still owning the window. "
				.. "is_active() proves only that SOME window is open, so an ungated write "
				.. "overwrites another operation's live progress with this one's outcome")
		local guarded_path = code:sub(ownership_at, at)
		helpers.assert_true(guarded_path:find("if owns_active_window then", 1, true) ~= nil,
			"the exact claim-time ownership result must dominate the readiness write")
	end)

	helpers.it("the ownership state is declared before the closures that use it", function()
		local src = helpers.read_driver_source("make_streaming_handler")
		local code = src:gsub("%-%-[^\n]*", "")

		local decl = code:find("local _ui_session", 1, true)
		local handler = code:find("local function make_streaming_handler", 1, true)
		local completion = code:find("owns_window()", 1, true)

		helpers.assert_true(decl ~= nil, "the ownership state must exist")
		helpers.assert_true(handler ~= nil, "the streaming handler must exist")
		helpers.assert_true(decl < handler,
			"_ui_session must be declared ABOVE make_streaming_handler. The handler assigns it and "
				.. "the task completion callback reads it; a local declared inside "
				.. "check_and_install_deps is out of scope for the handler, which would then bind a "
				.. "nil global and lose the ownership record entirely — the same Lua scoping trap "
				.. "the interceptor error latch hit")
		helpers.assert_true(completion ~= nil, "the ownership predicate must be used")
	end)
end)
