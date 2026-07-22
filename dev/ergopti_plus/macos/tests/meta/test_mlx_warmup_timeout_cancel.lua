--- tests/meta/test_mlx_warmup_timeout_cancel.lua

--- ==============================================================================
--- MODULE: Regression — api_mlx warmup timeout cancelled via TimerScheduler (M-2)
--- DESCRIPTION:
--- The TimerScheduler handle returned by TimerScheduler.after() is a plain table
--- {fired, id, timer} with no :stop() method. Two sites in api_mlx.lua previously
--- called pcall(function() _warmup_timeout:stop() end), which:
---   (a) raised "attempt to call a nil value (field 'stop')" (swallowed by pcall),
---   (b) left the underlying hs.timer running as an orphan,
---   (c) when the orphan fired it clobbered _warmup_timeout and flipped
---       _warmup_in_flight=false, corrupting a later warmup cycle.
---
--- Fix: both sites now use TimerScheduler.cancel(_warmup_timeout) — the only
--- correct cancellation API for a TimerScheduler handle.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("api_mlx: warmup timeout uses TimerScheduler.cancel not :stop() (M-2)", function()
	local function read_src()
		local path = helpers.driver_root() .. "modules/llm/api_mlx.lua"
		local fh = io.open(path, "r")
		helpers.assert_true(fh ~= nil, "modules/llm/api_mlx.lua must be readable")
		local src = fh:read("*a"); fh:close()
		return src
	end

	helpers.it("api_mlx.lua contains no _warmup_timeout:stop() call", function()
		local src = read_src()
		helpers.assert_true(
			src:find("_warmup_timeout:stop") == nil,
			"api_mlx.lua must NOT call _warmup_timeout:stop() — the handle has no :stop method; use TimerScheduler.cancel()"
		)
	end)

	helpers.it("api_mlx.lua uses TimerScheduler.cancel for warmup timeout teardown", function()
		local src = read_src()
		-- There must be at least one TimerScheduler.cancel(_warmup_timeout) call
		helpers.assert_true(
			src:find("TimerScheduler%.cancel%(_warmup_timeout%)") ~= nil,
			"api_mlx.lua must cancel _warmup_timeout via TimerScheduler.cancel(_warmup_timeout)"
		)
	end)
end)
