--- tests/meta/test_mlx_discovery_all_callbacks.lua

--- ==============================================================================
--- MODULE: MLX Discovery All Callbacks Meta Test
--- DESCRIPTION:
--- Static source guard for the "mlx-discovery-callbacks-loss" audit finding in
--- modules/llm/api_mlx_discovery.lua (the discovery probe was extracted there
--- from api_mlx.lua).
---
--- ROOT CAUSE ENCODED:
--- `finish_discovery` drained `_discovery_pending_callbacks` but only invoked
--- the LAST entry: `pcall(cbs[#cbs])`. Every warmup call that arrived while a
--- discovery probe was in flight enqueued its `on_done` callback, but only the
--- most-recently-enqueued one ever fired. Earlier callers received no notification,
--- so their warmup POST never ran — meaning the LLM engine silently stayed cold
--- even though warmup was requested multiple times.
---
--- The fix iterates all callbacks: `for _, cb in ipairs(cbs) do pcall(cb) end`.
--- All callers during a single probe are for the same model (a model switch calls
--- reset_endpoints() which clears the queue), so firing all is correct and
--- idempotent.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then
			out[#out + 1] = line
		end
	end
	return table.concat(out, "\n")
end


-- ============================================================
-- ============================================================
-- ======= 1/ All discovery callbacks are fired ===============
-- ============================================================
-- ============================================================

helpers.describe("llm/api_mlx.lua: all discovery callbacks fired (mlx-discovery-callbacks-loss)", function()

	helpers.it("finish_discovery iterates all callbacks with ipairs", function()
		local src = strip_comments(read_source("modules/llm/api_mlx_discovery.lua"))
		-- The fix uses: for _, cb in ipairs(cbs) do pcall(cb) end
		helpers.assert_true(
			src:match("for%s*_%s*,%s*cb%s+in%s+ipairs%(cbs%)") ~= nil,
			"finish_discovery must iterate all callbacks via ipairs(cbs) (mlx-discovery-callbacks-loss)")
	end)

	helpers.it("finish_discovery does NOT use only-last-callback pattern", function()
		local src = strip_comments(read_source("modules/llm/api_mlx_discovery.lua"))
		-- The old bug: pcall(cbs[#cbs])
		helpers.assert_true(
			src:match("pcall%(cbs%[#cbs%]%)") == nil,
			"finish_discovery must NOT call only cbs[#cbs] — all callbacks must be fired (mlx-discovery-callbacks-loss)")
	end)

end)
