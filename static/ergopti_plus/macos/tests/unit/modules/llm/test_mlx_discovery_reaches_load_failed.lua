--- tests/unit/modules/llm/test_mlx_discovery_reaches_load_failed.lua

--- ==============================================================================
--- MODULE: Regression — a model whose endpoints never appear must end in "failed"
--- DESCRIPTION:
--- `warmup()` has a give-up budget that turns an eternal orange "still loading"
--- dot into a red "failed" dot plus a notification. It is stamped AFTER the
--- discovery short-circuit, deliberately, so the discovery window does not eat
--- into the warmup budget — and the comment saying so is still there.
---
--- But discovery had no budget of its own. When the endpoints never resolve,
--- warmup returns at the discovery branch on every retry, `_warmup_started_at` is
--- never stamped, and the terminal transition is unreachable. The dot stayed
--- orange for the rest of the session, and the user was never told the model would
--- not load.
---
--- ROOT CAUSE ENCODED:
--- A terminal state gated behind a clock that the failing path never starts. The
--- assertions drive the real state machine and observe `is_load_failed()` plus the
--- notification, not the presence of a timer.
---
--- HARNESS NOTE: the discovery stub CAPTURES its callback instead of invoking it.
--- Invoking it makes warmup re-enter itself with nothing changed — the in-flight
--- flag is set far below the discovery branch — so the obvious stub recurses until
--- Lua reports a stack overflow, which is a traceback rather than a discriminating
--- failure. The test drives the cycles explicitly instead.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODEL = "some-model"


--- Loads api_mlx with a controllable clock and a discovery module that never
--- succeeds, capturing rather than invoking the retry callback.
--- @return table ApiMlx, table ctl {advance = fn, notifications = {}, pending = fn}
local function load_api_mlx()
	for _, m in ipairs({
		"modules.llm.api_mlx", "modules.llm.api_mlx_discovery",
		"adapters.timer_scheduler", "infra.logger",
	}) do package.loaded[m] = nil end
	_ = helpers.load_with_stubs("infra.logger")

	local ctl = { now = 0, notifications = {}, pending = nil }

	package.loaded["adapters.timer_scheduler"] = {
		now   = function() return ctl.now end,
		after = function(_d, _fn) return { stop = function() end } end,
		cancel = function() end,
	}
	package.loaded["modules.llm.api_mlx_discovery"] = {
		-- Never discovered, and the callback is CAPTURED: calling it here would make
		-- warmup re-enter itself with no state changed and recurse without bound.
		-- api_mlx calls init() at require time, so the stub must expose it or the
		-- module fails to load and every assertion below reports a traceback instead.
		init                   = function() end,
		is_discovered          = function() return false end,
		discover               = function(cb) ctl.pending = cb end,
		set_expected_model_id  = function() end,
		reset_endpoints        = function() end,
		get_completions_endpoint = function() return nil end,
		get_chat_endpoint      = function() return nil end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(title, body, kind)
			table.insert(ctl.notifications, { title = title, body = body, kind = kind })
		end,
	}
	package.loaded["infra.i18n"] = { get = function(k) return k end }

	local ApiMlx = helpers.load_with_stubs("modules.llm.api_mlx")
	return ApiMlx, ctl
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ Discovery that never succeeds ends in failure =========
-- ==================================================================
-- ==================================================================

helpers.describe("MLX: endpoints that never appear reach the failed state", function()

	helpers.it("marks the model failed once the discovery budget is spent", function()
		local ApiMlx, ctl = load_api_mlx()
		helpers.assert_type(ApiMlx.warmup, "function", "api_mlx must expose warmup")
		helpers.assert_type(ApiMlx.is_load_failed, "function", "and is_load_failed")

		-- First attempt: arms the discovery clock and asks for discovery.
		pcall(ApiMlx.warmup, MODEL, nil)
		helpers.assert_true(not ApiMlx.is_load_failed(),
			"one failed attempt must NOT be terminal — a cold mlx_lm import plus a model "
			.. "load legitimately takes tens of seconds, and giving up on the first miss "
			.. "would make the feature unusable")

		-- Well past any plausible budget.
		ctl.now = ctl.now + 100000
		pcall(ApiMlx.warmup, MODEL, nil)

		helpers.assert_true(ApiMlx.is_load_failed(),
			"warmup's own give-up clock is stamped only AFTER discovery succeeds, so a "
			.. "server whose endpoints never resolve left no clock running at all: warmup "
			.. "returned at the discovery branch on every retry and the terminal state was "
			.. "unreachable. The dot stayed orange for the rest of the session")
	end)

	helpers.it("tells the user, once", function()
		local ApiMlx, ctl = load_api_mlx()

		pcall(ApiMlx.warmup, MODEL, nil)
		ctl.now = ctl.now + 100000
		pcall(ApiMlx.warmup, MODEL, nil)
		-- A further retry must not re-notify: the model is already known-failed and
		-- warmup short-circuits on that flag.
		pcall(ApiMlx.warmup, MODEL, nil)

		local errors = 0
		for _, n in ipairs(ctl.notifications) do
			if n.kind == "error" then errors = errors + 1 end
		end
		helpers.assert_eq(errors, 1,
			"exactly one error notification: without the terminal state the user got none, "
			.. "and re-notifying on every retry would be its own defect")
	end)

	helpers.it("a discovery that succeeds is not affected", function()
		-- Without this case the assertions above would pass against a warmup that
		-- fails every model unconditionally.
		local ApiMlx, ctl = load_api_mlx()
		package.loaded["modules.llm.api_mlx_discovery"].is_discovered = function() return true end

		pcall(ApiMlx.warmup, MODEL, nil)
		helpers.assert_true(not ApiMlx.is_load_failed(),
			"a model whose endpoints resolve immediately must not be marked failed")
	end)

end)
