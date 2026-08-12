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
			repl = "ok", plain_repl = "ok", is_word = false, match_mode = "exact",
		}
		local plain, typed, _repl, is_noop = E.would_fire(m, "ok")

		helpers.assert_eq(plain, nil,
			"a no-op mapping must report no expansion — that is what makes it a no-op")
		helpers.assert_eq(typed, "ok",
			"but it still reports the typed text, which is truthy. Gating a preview row on THIS "
				.. "value builds a row whose text is nil")
		helpers.assert_eq(is_noop, true, "and it flags the outcome explicitly")
	end)

	helpers.it("the prospective resolver gates candidates on the expansion, not the input", function()
		local src = helpers.read_driver_source("function M.resolve_magic_action")
		helpers.assert_true(src ~= nil and src ~= "", "prospective resolver must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("function M.resolve_magic_action", 1, true)
		local body = code:sub(at, at + 9000)
		local _, display_gate_count = body:gsub(
			"if action%.reachable and action%.eff_plain then", "")
		helpers.assert_true(display_gate_count >= 2,
			"both auto and end-character candidate ledgers must be gated on the resolved expansion")
		helpers.assert_true(body:find("if action.typed then", 1, true) == nil,
			"typed text is truthy for a no-op and must never admit a nil-text row")
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
	helpers.it("every preview-disable path crosses the transactional hide fence", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		-- Each setter that turns a preview OFF must cross the same transactional
		-- fence. It forces the native hide when a visible owner exists and refuses
		-- the semantic toggle if those pixels cannot be revoked.
		local setters = {
			"function M.set_preview_star_enabled",
			"function M.set_preview_autocorrect_enabled",
			"function M.set_preview_enabled",
		}

		for _, name in ipairs(setters) do
			local at = code:find(name, 1, true)
			helpers.assert_true(at ~= nil, name .. " must exist")

			local body = code:sub(at, at + 600)
			local fence_at = body:find("M.invalidate_hotstring_preview()", 1, true)
			local mutation_at = body:find("is_star_preview_enabled =", 1, true)
				or body:find("is_autocorrect_preview_enabled =", 1, true)
			helpers.assert_true(fence_at ~= nil and mutation_at ~= nil and fence_at < mutation_at,
				name .. " must revoke the visible promise before publishing the disabled state")
		end

		local fence_at = code:find("function M.invalidate_hotstring_preview", 1, true)
		helpers.assert_true(fence_at ~= nil, "the shared preview invalidation fence must exist")
		local fence_body = code:sub(fence_at, fence_at + 1200)
		helpers.assert_true(fence_body:find(
			"tooltip.hide_forced_silent or tooltip.hide_forced", 1, true) ~= nil,
			"the shared fence must bypass dequeue guards with an authoritative hide")
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 4/ The preview describes what the ENGINE will do ========
-- =================================================================
-- =================================================================

--- Three divergences shared one shape: the row builder answered a question the
--- engine answers differently, and the tooltip is only useful while the two agree.
helpers.describe("preview: the rows describe the outcome the engine will produce", function()

	local function builder_code()
		local src = helpers.read_driver_source("_preview_render_generation")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the preview source must be readable or these invariants assert nothing")
		return src
	end

	helpers.it("resolves show_tooltip with the row's own section, not nil", function()
		local code = builder_code():gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("hotstrings_config%.resolve%(m%.group,%s*m%.section%)") ~= nil,
			"the config window keys its per-section \"hide the bubble\" override by section "
			.. "name, so resolving with nil consults only the group level and every "
			.. "per-section override the user set is silently ignored")
		helpers.assert_true(code:find("hotstrings_config%.resolve%(m%.group,%s*nil%)") == nil,
			"the nil-section resolve must be gone, not merely joined by a correct one")
	end)

	helpers.it("gates every alternative on the global engine winner", function()
		local code = builder_code():gsub("%-%-[^\n]*", "")
		local winner_gate = code:find("local winner_enabled%s*=%s*preview_enabled%(primary_match%)")
		local row_gate = code:find("local enabled%s*=%s*winner_enabled%s+and%s+preview_enabled%(m%)")
		helpers.assert_true(winner_gate ~= nil,
			"the row builder must resolve displayability of the engine winner")
		helpers.assert_true(row_gate ~= nil and winner_gate < row_gate,
			"every alternative must be suppressed when the real winner is hidden; promoting a "
			.. "runner-up presents an expansion the engine will not produce")
		helpers.assert_true(code:find("dimmed%s*=%s*not%s+m%.is_winner") ~= nil,
			"only the resolver-owned global winner may be rendered undimmed")
	end)

	helpers.it("labels a provider row with the magic key, not Enter", function()
		local code = builder_code():gsub("%-%-[^\n]*", "")
		local provider_at = code:find('type%s*=%s*"provider"')
		helpers.assert_true(provider_at ~= nil,
			"the provider match record must remain locatable")
		local provider_record = provider_at and code:sub(provider_at, provider_at + 700) or ""
		helpers.assert_true(provider_record:find('validation_key%s*=%s*"magic"') ~= nil,
			"a provider must declare the same magic validation action as its interceptor")
		helpers.assert_true(code:find(
			'trigger_label%s*=%s*validates_magic%s+and%s+magic_key%s+or%s+"↵"') ~= nil,
			"both shipped providers fire from the interceptor on the trigger character, so a "
				.. "row labelled with the terminator tells the user to press Enter — which destroys "
				.. "the pending expansion instead of firing it")
	end)

end)
