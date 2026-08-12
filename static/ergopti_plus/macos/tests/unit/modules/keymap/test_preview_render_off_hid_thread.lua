--- tests/unit/modules/keymap/test_preview_render_off_hid_thread.lua

--- ==============================================================================
--- MODULE: Regression — the hotstring preview must not render on the HID thread
---         (preview-render-off-hid-thread)
--- DESCRIPTION:
--- The preview tooltip rendered synchronously inside the keyboard callback, on
--- every preview keystroke. Rendering is not cheap: resolving the anchor
--- performs cross-process accessibility IPC and creates and destroys eventtaps.
--- Against a beach-balling front app that IPC blocks until the AX timeout — long
--- enough for macOS to disable the whole keyboard tap for being unresponsive,
--- which takes the driver down with it. Every keystroke was paying a cost whose
--- worst case is losing the keyboard entirely.
---
--- ROOT CAUSE ENCODED: the LLM tooltip already defers its own re-renders for
--- exactly this reason and says so in its comments. The hotstring preview — the
--- one that fires on far more keystrokes — was never migrated.
---
--- WHY DEFERRING NEEDS A STAMP: one runloop tick is a window in which the
--- preview can be superseded by the next keystroke or dismissed outright. An
--- unstamped deferral resurrects a tooltip the user has already dismissed, which
--- would trade a latency bug for a ghost-tooltip bug. Each request is therefore
--- stamped and a superseded render drops itself.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =======================================================
-- =======================================================
-- ======= 1/ The render is deferred, then stamped =======
-- =======================================================
-- =======================================================

helpers.describe("llm_bridge: the preview render leaves the keyboard callback", function()
	helpers.it("shows the preview through a deferral, not inline", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		helpers.assert_true(src ~= nil and src ~= "",
			"llm_bridge must be locatable by its preview-render stamp")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("tooltip.show_stacked", 1, true)
		helpers.assert_true(at ~= nil, "the preview must still be rendered at some point")

		local callback_at = code:sub(1, at):match(".*()local function render_preview%(")
		local schedule_at = callback_at and code:find("TimerScheduler.after(0, render_preview)", at, true)
		helpers.assert_true(callback_at ~= nil and schedule_at ~= nil,
			"the render must be scheduled off the keyboard callback. Resolving the tooltip anchor "
				.. "performs cross-process AX IPC on every preview keystroke, and against a hung "
				.. "front app that blocks until the AX timeout — long enough for macOS to disable "
				.. "the keyboard tap for being unresponsive")
		local callback_body = callback_at and schedule_at and code:sub(callback_at, schedule_at) or ""
		helpers.assert_true(callback_body:find("_preview_render_generation", 1, true) ~= nil,
			"and it must be stamped, so a render superseded during its deferral drops itself "
				.. "instead of resurrecting a dismissed tooltip")
	end)

	helpers.it("the deferred body re-checks the stamp before rendering", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		local at = code:find("tooltip.show_stacked", 1, true)
		helpers.assert_true(at ~= nil, "the preview render must exist")

		-- Capturing a stamp is worthless without comparing it at fire time. The
		-- comparison must sit INSIDE the deferred body, between the schedule and
		-- the render — that is the whole mechanism.
		local callback_at = code:sub(1, at):match(".*()local function render_preview%(")
		helpers.assert_not_nil(callback_at, "the deferred render callback must remain locatable")
		local body = code:sub(callback_at or 1, at)
		helpers.assert_true(body:find("~= _preview_render_generation", 1, true) ~= nil,
			"the deferred body must compare its captured stamp against the current one and "
				.. "return early when superseded. Capturing without comparing protects nothing, "
				.. "and the render would repaint a tooltip that has since been dismissed")
	end)
end)




-- =====================================================
-- =====================================================
-- ======= 2/ Every dismissal invalidates ==============
-- =====================================================
-- =====================================================

helpers.describe("llm_bridge: dismissals cancel a pending render", function()
	helpers.it("every immediate hide path bumps the stamp", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		-- Count CALLS, not references. The quarantine path resolves
		-- `hide_forced_silent or hide_forced` into a local; treating both candidates
		-- as two calls made this guard report 10 hides when the code has only seven.
		local hides, guarded = 0, 0
		local pos = 1
		while true do
			local at, finish = code:find("tooltip%.hide[%w_]*%s*%(", pos)
			if not at then break end
			pos = finish + 1
			hides = hides + 1
			if code:sub(math.max(1, at - 160), at):find("invalidate_pending_preview", 1, true) then
				guarded = guarded + 1
			end
		end

		helpers.assert_eq(guarded, hides,
			"every immediate hide must first invalidate any pending render (" .. guarded .. "/" .. hides
				.. "). One that does not lets a render armed a tick earlier put the tooltip back "
				.. "on screen after the user dismissed it")

		-- The three guarded/delayed paths call a local selected from two tooltip
		-- methods. Two are immediate Escape dismissals and need a nearby stamp bump;
		-- the third lives in the coalesced quarantine callback and is deliberately
		-- covered by the ordering assertion below.
		local quarantine_at = code:find("local function schedule_quarantine_surface_hide", 1, true)
		local reset_impl_at = quarantine_at and code:find("local function reset_predictions_impl", quarantine_at, true)
		local dynamic, immediate, immediate_guarded, deferred = 0, 0, 0, 0
		pos = 1
		while true do
			local at = code:find("local hide = tooltip.hide_forced_silent or tooltip.hide_forced", pos, true)
			if not at then break end
			pos = at + 1
			dynamic = dynamic + 1
			if quarantine_at and reset_impl_at and at > quarantine_at and at < reset_impl_at then
				deferred = deferred + 1
			else
				immediate = immediate + 1
				if code:sub(math.max(1, at - 160), at):find("invalidate_pending_preview", 1, true) then
					immediate_guarded = immediate_guarded + 1
				end
			end
		end
		helpers.assert_true(dynamic >= 3,
			"the scan must reach the dynamic hide sites (found " .. dynamic .. ")")
		helpers.assert_true(hides + dynamic >= 3,
			"the scan must reach the real immediate/dynamic hide class")
		helpers.assert_eq(deferred, 1,
			"exactly the coalesced quarantine hide may rely on reset-time invalidation")
		helpers.assert_eq(immediate_guarded, immediate,
			"every dynamically resolved immediate hide must invalidate first ("
				.. immediate_guarded .. "/" .. immediate .. ")")
	end)

	helpers.it("the deferred quarantine hide is reached only after invalidation", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")
		local impl_at = code:find("local function reset_predictions_impl", 1, true)
		local invalidate_at = impl_at and code:find("invalidate_pending_preview()", impl_at, true)
		local schedule_at = impl_at and code:find("schedule_quarantine_surface_hide()", impl_at, true)
		helpers.assert_true(impl_at ~= nil and invalidate_at ~= nil and schedule_at ~= nil,
			"the reset implementation and quarantine hide path must remain reachable")
		helpers.assert_true(invalidate_at < schedule_at,
			"the pending render must be invalidated before the quarantine hide is queued. "
				.. "Invalidating inside that later callback would wrongly cancel a newer "
				.. "hotstring preview scheduled after the reset")

		local public_at = code:find("function M.reset_predictions", schedule_at, true)
		local delegate_at = public_at and code:find("reset_predictions_impl(keep_hotstring_log, false)", public_at, true)
		helpers.assert_true(public_at ~= nil and delegate_at ~= nil,
			"the public reset must delegate to the invalidating implementation")
	end)

	helpers.it("reset_predictions drops a render already queued for the next tick", function()
		local dependency_names = {
			"adapters.synthetic_input",
			"adapters.timer_scheduler",
			"modules.keymap.utils",
			"modules.llm",
			"modules.llm.prediction_engine",
			"modules.keylogger",
			"ui.tooltip",
			"modules.keymap.llm_bridge",
		}
		local previous = {}
		for _, name in ipairs(dependency_names) do previous[name] = package.loaded[name] end

		local scheduled = {}
		local shown = 0
		local reset_count = 0
		local action_epoch = {}
		package.loaded["adapters.synthetic_input"] = {
			current_action_epoch = function() return action_epoch end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, fn)
				local handle = { timer = {}, delay = delay, fn = fn }
				scheduled[#scheduled + 1] = handle
				return handle, true
			end,
		}
		package.loaded["modules.keymap.utils"] = {
			tokens_from_repl = function(value) return value end,
			plain_text = function(value) return value end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		}
		package.loaded["modules.llm.prediction_engine"] = {
			set_runtime_guard = function() end,
			init = function() end,
			get_llm_enabled = function() return false end,
			reset = function() reset_count = reset_count + 1; return true end,
		}
		package.loaded["modules.keylogger"] = {}
		package.loaded["ui.tooltip"] = {
			set_runtime_guard = function() end,
			set_accept_callback = function() end,
			set_cancel_callback = function() end,
			set_on_show_callback = function() end,
			set_timeout = function() end,
			tint = function() return {} end,
			show_stacked = function() shown = shown + 1; return true end,
		}

		local ok, err = pcall(function()
			local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
			local state = {
				buffer = "abc",
				mappings = {},
				groups = {},
				magic_key = "★",
				no_rescan_until = 0,
				DELAYS = { dynamichotstrings = 1 },
				preview_providers = { function() return "replacement" end },
				is_repeat_feature_enabled = function() return false end,
			}
			Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })

			Bridge.update_preview(state.buffer)
			helpers.assert_eq(#scheduled, 1,
				"the preview must genuinely queue one render or the reset assertion is vacuous")
			local stale_render = scheduled[1].fn
			Bridge.reset_predictions()
			stale_render()
			helpers.assert_eq(shown, 0,
				"a render queued before reset must not resurrect the dismissed tooltip")
			helpers.assert_true(reset_count >= 2,
				"both preview replacement and the public reset must reach the engine reset")

			Bridge.update_preview(state.buffer)
			helpers.assert_eq(#scheduled, 2,
				"a later preview must queue a fresh render after the reset")
			scheduled[2].fn()
			helpers.assert_eq(shown, 1,
				"the fresh render must still run, proving the stale callback was not a no-op")
		end)

		for _, name in ipairs(dependency_names) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end)
end)
