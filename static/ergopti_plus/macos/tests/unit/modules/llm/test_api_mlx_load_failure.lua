--- tests/unit/modules/llm/test_api_mlx_load_failure.lua

--- ==============================================================================
--- MODULE: api_mlx — model-load-failure surface (no eternal orange dot)
--- DESCRIPTION:
--- Locks down the contract that a model which can NEVER load is surfaced to the
--- user instead of retrying warmup forever. Before this, warmup() retried on every
--- non-200 with no upper bound: a broken model (an architecture the installed
--- mlx-lm cannot load, a hung generate thread) kept the HTTP server up, so the
--- menu's status dot stayed stuck on the orange "still loading…" colour with no
--- error the user could see ("gemma ne print plus d'erreur, c'est rond orange").
---
--- The fix gives api_mlx a permanent load-failure state:
---   * mark_load_failed(model, notify) flips is_load_failed() true, kills readiness,
---     stops the warmup loop, and (when notify) fires ONE error notification.
---   * the menu paints the dot RED while is_load_failed() holds (overriding orange).
---   * reset_endpoints() clears it so a newly selected model gets a fresh verdict.
---
--- FEATURES & RATIONALE:
--- 1. Notification capture: stubs lib.notifications BEFORE the fresh api_mlx require
---    so we observe exactly how many error notifications fire — and restores it after
---    so downstream test modules see the real module.
--- 2. Asserts call COUNT + kind, not body text: i18n.get may return the raw key in
---    the headless harness (no locale files loaded), so the formatted body is not a
---    stable assertion target — the user-visible guarantee is "exactly one error
---    notification fired", which is what we check.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Capture notifications fired by api_mlx. Installed BEFORE requiring api_mlx so the
-- module captures this stub as its Notifications upvalue.
local notify_calls = {}
local _real_notifications = package.loaded["lib.notifications"]
package.loaded["lib.notifications"] = {
	notify = function(title, body, kind)
		notify_calls[#notify_calls + 1] = { title = title, body = body, kind = kind }
	end,
}

package.loaded["modules.llm.api_mlx"] = nil
local ApiMlx = require("modules.llm.api_mlx")




-- =========================================================
-- =========================================================
-- ======= 1/ Load-failure state + notification ============
-- =========================================================
-- =========================================================

helpers.describe("api_mlx — load-failure surface", function()
	helpers.it("exposes is_load_failed and mark_load_failed", function()
		helpers.assert_eq(type(ApiMlx.is_load_failed), "function")
		helpers.assert_eq(type(ApiMlx.mark_load_failed), "function")
	end)

	helpers.it("starts in a non-failed state after reset_endpoints", function()
		ApiMlx.reset_endpoints()
		helpers.assert_true(ApiMlx.is_load_failed() == false, "fresh state must not be failed")
	end)

	helpers.it("mark_load_failed(model, true) flips the flag, kills readiness, notifies exactly once", function()
		ApiMlx.reset_endpoints()
		notify_calls = {}
		ApiMlx.mark_load_failed("gemma-4-E4B-it", true)
		helpers.assert_true(ApiMlx.is_load_failed() == true, "model must be marked failed")
		helpers.assert_true(ApiMlx.is_ready() == false, "a failed model must not report ready")
		helpers.assert_eq(#notify_calls, 1)
		helpers.assert_eq(notify_calls[1].kind, "error")
		-- A second failure for the same model must NOT spam a second notification.
		ApiMlx.mark_load_failed("gemma-4-E4B-it", true)
		helpers.assert_eq(#notify_calls, 1)
	end)

	helpers.it("mark_load_failed(model, false) sets the flag WITHOUT notifying (crash detector already did)", function()
		ApiMlx.reset_endpoints()
		notify_calls = {}
		ApiMlx.mark_load_failed("broken-model", false)
		helpers.assert_true(ApiMlx.is_load_failed() == true)
		helpers.assert_eq(#notify_calls, 0)
	end)

	helpers.it("reset_endpoints clears the failure so a relaunched model gets a fresh verdict", function()
		ApiMlx.mark_load_failed("broken-model", false)
		helpers.assert_true(ApiMlx.is_load_failed() == true)
		ApiMlx.reset_endpoints()
		helpers.assert_true(ApiMlx.is_load_failed() == false, "reset must clear the failure")
	end)

	helpers.it("warmup() is a no-op once the model is marked failed (no retry storm, no readiness flip)", function()
		ApiMlx.reset_endpoints()
		ApiMlx.mark_load_failed("broken-model", false)
		-- Must not throw, must not flip readiness on, must stay failed.
		ApiMlx.warmup("broken-model", nil)
		helpers.assert_true(ApiMlx.is_ready() == false)
		helpers.assert_true(ApiMlx.is_load_failed() == true)
	end)
end)

-- Restore the real notifications module and drop our fresh api_mlx instance so
-- downstream test modules re-require the production wiring, not this stub.
package.loaded["lib.notifications"] = _real_notifications
package.loaded["modules.llm.api_mlx"] = nil
