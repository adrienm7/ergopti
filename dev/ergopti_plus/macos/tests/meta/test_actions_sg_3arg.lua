--- tests/meta/test_actions_sg_3arg.lua

--- ==============================================================================
--- MODULE: gestures.actions sg() 3-Arg Guard Meta Test
--- DESCRIPTION:
--- Static source guard for the "gestures-sg-3arg-label-bound-as-fn" audit
--- finding in modules/gestures/actions.lua.
---
--- ROOT CAUSE ENCODED:
--- The local sg() helper registered discrete single-fire actions with two
--- arguments (name, fn). Many callers legitimately pass three arguments
--- (name, label, fn) to attach a display label. Without a type-check guard
--- the 3-arg form silently bound the label STRING as the action function:
---   SG[name] = { fn = "Volume up" }   -- string, not callable
--- Calling execute_single(name) would then error at runtime — or worse, silently
--- no-op if the call-site wrapped it in pcall — making every modifier+letter
--- action registered with a label a permanent no-op.
---
--- The fix:
---   local fn = type(fn_arg) == "function" and fn_arg or label_or_fn
--- — picks fn_arg when it is actually a function (3-arg form), otherwise falls
--- back to label_or_fn (2-arg form). This test pins the guard so removing it
--- fails CI immediately.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =======================================================
-- =======================================================
-- ======= 1/ sg() 3-arg guard present in source =========
-- =======================================================
-- =======================================================

helpers.describe("gestures.actions: sg() 3-arg function-vs-label guard", function()
	helpers.it("actions.lua contains the type(fn_arg) == function guard in sg()", function()
		-- Read the source file relative to the driver root.
		local sep   = package.config:sub(1, 1)
		local self  = debug.getinfo(1, "S").source:gsub("^@", "")
		-- Navigate from tests/meta/ up to the driver root.
		local root  = self:match("^(.*)[/\\]tests[/\\]") or "."
		local path  = root .. sep .. "modules" .. sep .. "gestures" .. sep .. "actions.lua"

		local fh    = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "modules/gestures/actions.lua must be readable")
		if not fh then return end
		local src = fh:read("*a")
		fh:close()

		-- Strip full-line Lua comments to avoid matching commented-out old code.
		local stripped = src:gsub("%-%-[^\n]*", "")

		-- The guard must be present in the sg() function body.
		helpers.assert_true(
			stripped:find('type%(fn_arg%)%s*==%s*"function"', 1, false) ~= nil
			or stripped:find("type%(fn_arg%)%s*==%s*'function'", 1, false) ~= nil,
			"sg() in actions.lua must have a type(fn_arg) == \"function\" guard to handle the 3-arg (name, label, fn) call form (gestures-sg-3arg-label-bound-as-fn)"
		)

		-- The assignment that uses the guard must be present.
		helpers.assert_true(
			stripped:find("fn_arg or label_or_fn", 1, true) ~= nil
			or stripped:find("label_or_fn or fn_arg", 1, true) ~= nil,
			"sg() must assign fn from fn_arg-or-label_or_fn so the label string is never used as a callable (gestures-sg-3arg-label-bound-as-fn)"
		)
	end)
end)




-- ===========================================================
-- ===========================================================
-- ======= 2/ sg() 3-arg form: module-level smoke test ========
-- ===========================================================
-- ===========================================================

helpers.describe("gestures.actions: sg() 3-arg form does not crash on load", function()
	helpers.it("Actions module loads without error (sg() 3-arg form is exercised at load time)", function()
		package.loaded["lib.logger"] = nil
		local _ = helpers.load_with_stubs("lib.logger")
		-- If sg() misbound a label string as fn, the module-level calls to sg()
		-- with 3 args would store strings — no crash at load time, but this
		-- confirms the module at least loads successfully.
		local ok, Actions = pcall(helpers.load_with_stubs, "modules.gestures.actions")
		helpers.assert_true(ok, "modules.gestures.actions must load without error")
		helpers.assert_true(Actions ~= nil, "Actions module must be non-nil after load")

		-- SG_NAMES must be non-empty: if sg() silently dropped all 3-arg registrations
		-- the list would be empty or very short (only 2-arg entries).
		helpers.assert_true(type(Actions.SG_NAMES) == "table" and #Actions.SG_NAMES > 5,
			"SG_NAMES must have more than 5 entries — 3-arg sg() registrations must not be silently dropped")
	end)
end)
