--- tests/unit/modules/llm/streaming/test_streaming_warn_fires_for_all_backends.lua

--- ==============================================================================
--- MODULE: streaming_handler — Backend-Agnostic Failure Warning Regression Test
--- DESCRIPTION:
--- Guard for M-14: the consecutive-failure warning of the streaming handler
--- fires for ALL backends, not just MLX.
---
--- Before the fix, the Logger.warn and the desktop notification were nested
--- inside an `if backend == "mlx"` guard, so Ollama and remote backends silently
--- absorbed repeated failures with no developer-visible warning. The test used to
--- find both calls in the source text and compare their positions; it now fails
--- real requests through the real engine and streaming handler and reads the log
--- and the notifier, so any spelling of the guard is judged by what it does.
--- ==============================================================================

local helpers = require("tests.helpers")
local load_pipeline = require("tests.support.prediction_pipeline").load




-- ===========================================================================
-- ===========================================================================
-- ======= 1/ Failure Driver =================================================
-- ===========================================================================
-- ===========================================================================

-- Enough failed requests to cross the handler's warning threshold, which is a
-- private constant: the counter resets after warning, so one extra round must
-- still produce exactly one warning.
local FAILED_REQUESTS = 5

--- Fails consecutive requests on one backend and records what surfaced.
--- @param backend string Backend name the core reports.
--- @return table outcome { warnings, notifications }
local function fail_requests(backend)
	local notifications = 0
	local saved_notifier = package.loaded["platform.focus.application_notifier"]
	package.loaded["platform.focus.application_notifier"] = {
		new = function()
			return { send = function() notifications = notifications + 1; return true end }
		end,
	}
	local ok, outcome = xpcall(function()
		local fixture = load_pipeline({ render_success = true })
		package.loaded["modules.llm"].get_backend = function() return backend end
		for attempt = 1, FAILED_REQUESTS do
			fixture.engine.perform_check(true)
			helpers.assert_eq(fixture.fetches, attempt, "attempt " .. attempt .. " must reach the backend")
			fixture.on_fail()
		end
		local warnings = {}
		for _, record in ipairs(fixture.logs) do
			if record.level == "warn" and record.message:find("Repeated LLM failures", 1, true) then
				warnings[#warnings + 1] = record.message
			end
		end
		return { warnings = warnings, notifications = notifications }
	end, debug.traceback)
	package.loaded["platform.focus.application_notifier"] = saved_notifier
	if not ok then error(outcome, 0) end
	return outcome
end




-- ===========================================================================
-- ===========================================================================
-- ======= 2/ Behaviour Assertions ===========================================
-- ===========================================================================
-- ===========================================================================

helpers.describe("streaming_handler — consecutive-failure warning is backend-agnostic", function()

	for _, backend in ipairs({ "ollama", "remote", "mlx" }) do
		helpers.it("warns once about repeated failures on " .. backend .. " (M-14)", function()
			local outcome = fail_requests(backend)
			helpers.assert_eq(#outcome.warnings, 1,
				"repeated failures on " .. backend .. " must produce one warning")
			helpers.assert_true(outcome.warnings[1]:find("'" .. backend .. "'", 1, true) ~= nil,
				"the warning must name the failing backend: " .. outcome.warnings[1])
		end)
	end


	helpers.it("keeps the desktop notification for MLX only", function()
		-- The notification text names MLX, so another backend must not show it.
		helpers.assert_eq(fail_requests("mlx").notifications, 1, "MLX failures must notify the user once")
		helpers.assert_eq(fail_requests("ollama").notifications, 0, "an Ollama failure must not claim to be MLX")
	end)

end)
