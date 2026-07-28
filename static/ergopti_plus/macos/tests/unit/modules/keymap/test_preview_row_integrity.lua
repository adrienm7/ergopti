--- tests/unit/modules/keymap/test_preview_row_integrity.lua

--- ==============================================================================
--- MODULE: Regression — the preview must build valid rows and dismiss on demand
---         (preview-row-integrity)
--- DESCRIPTION:
--- Three defects in the hotstring preview, all of which the user sees as "the
--- suggestions stopped working".
---
--- ROOT CAUSE ENCODED:
---   1. The autocorrect bucket gated its row on would_fire's SECOND return
---      value. For a no-op mapping — one whose replacement equals what was
---      typed — would_fire returns (nil, typed, nil, true): a nil expansion and
---      a perfectly truthy typed string. The row was therefore built with nil
---      text, render_stacked threw on it, and the failure took the ENTIRE
---      preview stack with it. One no-op mapping silently erased every other
---      suggestion on screen. The star bucket next to it already gated on the
---      expansion, which is what "the preview treats a no-op exactly like no
---      match" means.
---   2. Star rows labelled the validation key with a hard-coded ★ while the
---      buffer they were matched against was built from CoreState.magic_key.
---      Anyone who customised that key was told to press a character their
---      layout no longer produces.
---   3. Turning a preview OFF called the dequeue-guarded tooltip.hide(), which
---      is a deliberate no-op while a multi-row dequeue is running — so the rows
---      the user had just disabled stayed on screen until they timed out.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =================================================================
-- =================================================================
-- ======= 1/ A no-op mapping produces no row ======================
-- =================================================================
-- =================================================================

helpers.describe("preview: a no-op mapping is treated exactly like no match", function()
	helpers.it("would_fire reports a no-op with a nil expansion and a truthy input", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		E.init({ buffer = "", start_is_word_boundary = function() return true end,
			suppress_rescan = function() end },
			{ is_terminator = function() return false end,
			  terminator_is_consumed = function() return false end,
			  mappings_for_tail = function() return {} end },
			{ update_preview = function() end, get_llm_enabled = function() return false end,
			  start_timer = function() end })

		local m = {
			trigger = "ok", trigger_bytes = 2, tlen = 2,
			repl = "ok", plain_repl = "ok", is_word = false, case_conform = false,
		}
		local plain, typed, _repl, is_noop = E.would_fire(m, "ok")

		helpers.assert_eq(plain, nil,
			"a no-op mapping must report no expansion — that is what makes it a no-op")
		helpers.assert_eq(typed, "ok",
			"but it still reports the typed text, which is truthy. Gating a preview row on THIS "
				.. "value builds a row whose text is nil")
		helpers.assert_eq(is_noop, true, "and it flags the outcome explicitly")
	end)

	helpers.it("the autocorrect bucket gates on the expansion, not the input", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		helpers.assert_true(src ~= nil and src ~= "", "llm_bridge must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("matched_plain, matched_input = expander.would_fire", 1, true)
		helpers.assert_true(at ~= nil, "the autocorrect bucket must still call would_fire")

		local body = code:sub(at, at + 400)
		helpers.assert_true(body:find("if matched_plain then", 1, true) ~= nil,
			"the row must be gated on the resolved expansion. Gating on matched_input admits the "
				.. "no-op case, whose expansion is nil — and a nil-text row makes render_stacked "
				.. "throw, which drops every other suggestion in the same stack")
		helpers.assert_true(body:find("if matched_input then", 1, true) == nil,
			"and it must not gate on the typed text, which is truthy for a no-op")
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 2/ The star label follows the configured key ============
-- =================================================================
-- =================================================================

helpers.describe("preview: star rows name the key the user actually presses", function()
	helpers.it("reads the magic key from CoreState rather than hard-coding it", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		local at = code:find("local magic_key", 1, true)
		helpers.assert_true(at ~= nil, "the row builder must resolve a magic key")

		local decl = code:sub(at, at + 260)
		helpers.assert_true(decl:find("_state.magic_key", 1, true) ~= nil,
			"the label must come from CoreState — the same source star_buf is built from. A "
				.. "hard-coded star tells anyone who customised the magic key to press a character "
				.. "their layout no longer produces")
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 3/ Disabling a preview dismisses it now =================
-- =================================================================
-- =================================================================

helpers.describe("preview: turning it off clears what is already on screen", function()
	helpers.it("every preview-disable path forces the hide", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		-- Each setter that turns a preview OFF must dismiss unconditionally.
		-- tooltip.hide() is a deliberate no-op during a dequeue cycle so a
		-- multi-row preview survives the first row's expiry — which is exactly
		-- wrong when the user has just switched the feature off.
		local setters = {
			"function M.set_preview_star_enabled",
			"function M.set_preview_autocorrect_enabled",
			"function M.set_preview_enabled",
		}

		for _, name in ipairs(setters) do
			local at = code:find(name, 1, true)
			helpers.assert_true(at ~= nil, name .. " must exist")

			local body = code:sub(at, at + 600)
			helpers.assert_true(body:find("hide_forced", 1, true) ~= nil,
				name .. " must force the hide. The dequeue-guarded hide() is ignored while a "
					.. "multi-row preview is cycling, so the rows the user just disabled stayed "
					.. "on screen until they timed out on their own")
		end
	end)
end)
