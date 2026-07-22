--- tests/unit/modules/llm/test_mlx_warmup_generation_guard.lua

--- ==============================================================================
--- MODULE: Regression — MLX warmup callback has a generation guard
--- DESCRIPTION:
--- Audit finding F-L4. An in-flight warmup POST had no generation guard, so a
--- model-A 200 response landing AFTER reset_endpoints() switched to model B flipped
--- _is_ready=true for the wrong (now-stale) server. Fix: a _warmup_gen counter bumped
--- in reset_endpoints() and mark_load_failed(); warmup() snapshots it and the callback
--- discards itself when the snapshot is stale. The warmup HTTP client is heavy to
--- drive in-test, so the guard is pinned at source.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src()
	local fh = assert(io.open(helpers.driver_root() .. "modules/llm/api_mlx.lua", "r"))
	local s = fh:read("*a"); fh:close()
	return s
end

helpers.describe("MLX warmup is generation-guarded against a stale callback", function()
	helpers.it("reset_endpoints and mark_load_failed bump _warmup_gen", function()
		local src = read_src()
		local reset = src:find("function M.reset_endpoints()", 1, true)
		local mark  = src:find("function M.mark_load_failed", 1, true)
		helpers.assert_true(reset and src:find("_warmup_gen%s*=%s*_warmup_gen%s*%+%s*1", reset) ~= nil,
			"reset_endpoints must bump _warmup_gen")
		helpers.assert_true(mark and src:find("_warmup_gen%s*=%s*_warmup_gen%s*%+%s*1", mark) ~= nil,
			"mark_load_failed must bump _warmup_gen")
	end)

	helpers.it("warmup snapshots the generation and the callback discards a stale one", function()
		local src = read_src()
		helpers.assert_true(src:find("local my_warmup_gen = _warmup_gen", 1, true) ~= nil,
			"warmup() must snapshot _warmup_gen before the POST")
		helpers.assert_true(src:find("if my_warmup_gen ~= _warmup_gen then", 1, true) ~= nil,
			"the warmup callback must discard itself when its captured generation is stale")
		-- The stale-guard must precede the _is_ready = true assignment so it can't flip it.
		local guard = src:find("if my_warmup_gen ~= _warmup_gen then", 1, true)
		local ready = src:find("_is_ready = true", 1, true)
		helpers.assert_true(guard ~= nil and ready ~= nil and guard < ready,
			"the generation guard must run before _is_ready = true")
	end)
end)
