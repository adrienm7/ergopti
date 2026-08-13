--- tests/meta/test_fresh_regressions_2026_07_21.lua

--- ==============================================================================
--- MODULE: Regression — three defects introduced BY the 2026-07-21 fixes
---         (fresh-regressions-2026-07-21)
--- DESCRIPTION:
--- Each of these was created by a commit that was itself fixing something else.
--- That is the point of grouping them: the risk being guarded is not the three
--- individual bugs, it is that a fix can quietly install a worse one.
---
---   H2  THE ERROR REPORTER CRASHED THE PIPELINE. `_interceptor_error_logged`
---       was declared at the bottom of keymap/init.lua while onKeyDownRaw, some
---       four hundred lines above, indexes it. In Lua a local's scope begins
---       AFTER its declaration, so the closure bound the never-assigned GLOBAL
---       of that name. The first throwing interceptor therefore raised inside
---       the handler whose entire purpose is to REPORT a throwing interceptor,
---       aborting onKeyDownRaw before step 4 — no Escape handling, no backspace
---       handling, no buffer tracking, no expansions, on EVERY keystroke while
---       the interceptor kept throwing. The outer pcall then logged a
---       misdirecting "Keyboard interception failure", pointing at the tap.
---
---   H3  A GC'D TASK SILENTLY LOCKED PREDICTIONS. The MLX requirements probe
---       held its hs.task in a plain local, so the task became collectable the
---       moment the function returned while the python import probe still had
---       one to three seconds to run. A GC cycle in that window makes
---       Hammerspoon SIGTERM the subprocess; the completion callback never
---       fires, so neither do_check nor on_cancel runs — and on_cancel is what
---       releases the prediction lock. Predictions then stay locked with no
---       START-without-SUCCESS trail. Its sibling delete_task in the same file
---       does pin and release correctly, which is what proves the intent.
---
---   H8  THE FACTORY RESET RESET NOTHING. reset_all_defaults removed both
---       config files and then called save_prefs(), which rewrote config.toml
---       from the still-current in-memory state. The reload therefore found a
---       non-empty config, took the "not absent" path, and re-hydrated every
---       toggle the user had just asked to clear — while the notification
---       cheerfully reported success.
---
--- ROOT CAUSE ENCODED, common to all three: each fix was verified against the
--- thing it fixed, not against what it displaced. The guards below assert the
--- displaced property, not the original one.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================================
-- =========================================================================
-- ======= 1/ H2 — the latch is declared before the closure ================
-- =========================================================================
-- =========================================================================

helpers.describe("keymap: the interceptor error latch is in scope where it is used", function()
	helpers.it("is declared BEFORE onKeyDownRaw, not after it", function()
		local src = helpers.read_driver_source("onKeyDownRaw")
		helpers.assert_true(src ~= nil and src ~= "",
			"the keymap source must be locatable by its onKeyDownRaw symbol")

		local decl = src:find("local _interceptor_error_logged", 1, true)
		local closure = src:find("local function onKeyDownRaw", 1, true)

		helpers.assert_true(decl ~= nil, "the interceptor error latch must exist")
		helpers.assert_true(closure ~= nil, "onKeyDownRaw must exist")
		helpers.assert_true(
			decl < closure,
			"the latch must be declared ABOVE onKeyDownRaw. A Lua local's scope starts after its "
				.. "declaration, so a closure written earlier binds the nil GLOBAL of the same name — "
				.. "and indexing that nil raises inside the handler that exists to report a throwing "
				.. "interceptor, killing every keystroke's Escape, backspace, buffer and expansion "
				.. "handling for as long as the interceptor keeps throwing"
		)
	end)

	helpers.it("the trap itself is real in this Lua", function()
		-- The invariant above is only worth asserting because Lua really does
		-- behave this way. Demonstrate it rather than asserting it from memory.
		local chunk = load([[
			local function uses_it() return later[1] end
			local later = {}
			return pcall(uses_it)
		]])
		helpers.assert_true(chunk ~= nil, "the demonstration chunk must compile")
		local ok = chunk()
		helpers.assert_true(ok == false,
			"a closure that reads a local declared BELOW it must fail — if this ever stops being "
				.. "true, the ordering assertion above is guarding nothing")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ H3 — every hs.task is pinned at its own call site ============
-- =========================================================================
-- =========================================================================

helpers.describe("models_manager_mlx: every hs.task is GC-pinned", function()
	helpers.it("both tasks in the MLX manager are pinned before start", function()
		local src = helpers.read_driver_source("check_requirements")
		helpers.assert_true(src ~= nil and src ~= "",
			"the MLX models manager must be locatable by its check_requirements symbol")

		-- Scoped to the two tasks THIS file owns, by name. read_driver_source
		-- concatenates every file containing the symbol, and a blanket count over
		-- that would be measuring the whole-tree pin coverage — a separate
		-- finding, with its own scope and its own allowlist.
		for _, name in ipairs({ "check_task", "delete_task" }) do
			local at = src:find(name .. " = TaskLifecycle.native", 1, true)
			helpers.assert_true(at ~= nil,
				name .. " must be forward-declared and then assigned, so its own callback can "
					.. "release the pin")

			-- The pin must land between creation and start.
			local window = src:sub(at, at + 4000)
			local start_at = window:find("TaskLifecycle.start(" .. name, 1, true)
			helpers.assert_true(start_at ~= nil, name .. " must be started")
			local before_start = window:sub(1, start_at)

			helpers.assert_true(
				before_start:find("_active_tasks%[" .. name .. "%] = true") ~= nil,
				name .. " must be pinned into the GC root BEFORE it is started. Held only by a "
					.. "local, the task is collectable as soon as its creating function returns; "
					.. "Hammerspoon then SIGTERMs the subprocess and the completion callback never "
					.. "fires — silently, because a GC-death logs nothing. For the requirements "
					.. "probe that also means on_cancel never runs, and on_cancel is what releases "
					.. "the prediction lock"
			)
		end
	end)

	helpers.it("the probe releases its pin so the root does not grow forever", function()
		local src = helpers.read_driver_source("check_requirements")
		local at = src:find("check_task = TaskLifecycle.native", 1, true)
		helpers.assert_true(at ~= nil,
			"check_task must be forward-declared and then assigned, so its own callback can "
				.. "reference it to release the pin")

		local body = src:sub(at, at + 600)
		helpers.assert_true(body:find("_active_tasks%[check_task%] = nil") ~= nil,
			"the callback must release the pin as its first act, exactly as the sibling delete_task "
				.. "does — otherwise every probe leaks an entry into the GC root for the session")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 3/ H8 — the factory reset leaves no config behind ===============
-- =========================================================================
-- =========================================================================

helpers.describe("menu: reset_all_defaults really resets", function()
	helpers.it("does not re-save the current state after deleting the config", function()
		local src = helpers.read_driver_source("reset_all_defaults")
		helpers.assert_true(src ~= nil and src ~= "",
			"the menu source must be locatable by its reset_all_defaults symbol")

		local at = src:find("local function reset_all_defaults", 1, true)
		helpers.assert_true(at ~= nil, "reset_all_defaults must exist")

		-- Bound the body at the reload that ends it.
		local reload_at = src:find("hs.reload", at, true)
		helpers.assert_true(reload_at ~= nil, "reset_all_defaults must end in a reload")
		local body = src:sub(at, reload_at)

		-- Strip comments: the explanation of why save_prefs must NOT be here
		-- mentions it by name, and matching that would flag the fix as the bug.
		local code = body:gsub("%-%-[^\n]*", "")

		helpers.assert_true(
			code:find("save_prefs()", 1, true) == nil,
			"reset_all_defaults must not call save_prefs(). It rewrites config.toml from the "
				.. "still-current in-memory state — which restore_factory_bindings does not reset, "
				.. "it only resets bindings — so the reload finds a NON-empty config, skips the "
				.. "factory-seed branch, and re-hydrates every toggle the user asked to clear while "
				.. "the notification reports success"
		)
	end)

	helpers.it("still removes both persisted config files", function()
		local src = helpers.read_driver_source("reset_all_defaults")
		local at = src:find("local function reset_all_defaults", 1, true)
		local reload_at = src:find("hs.reload", at, true)
		local body = src:sub(at, reload_at)

		helpers.assert_true(body:find("ConfigTomlPath", 1, true) ~= nil,
			"the reset must still delete config.toml — that deletion is what makes the next boot "
				.. "take the config_absent path and seed factory defaults")
		helpers.assert_true(body:find("KarabinerConfigPath", 1, true) ~= nil,
			"the reset must still delete the karabiner config, which holds the tap/hold bindings")
		helpers.assert_true(body:find("restore_factory_bindings", 1, true) ~= nil,
			"and it must still restore the bindings held in the other stores (hs.settings), which "
				.. "no file deletion covers")
	end)
end)
