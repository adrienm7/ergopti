--- tests/support/repeat_collapsing_replay.lua

--- ==============================================================================
--- MODULE: Repeat Collapsing Replay
--- DESCRIPTION:
--- Replays logger calls captured by a module test through a private instance of
--- the shared logger core with repeat collapsing armed, inside one window. A
--- module test that stubs the logger sees every call; this shows which of those
--- calls the production log actually keeps once collapsing folds info and debug
--- lines by their unformatted template.
--- ==============================================================================

local M = {}

--- Fixed clock face: every replayed call lands inside one window of one day, so
--- neither window expiry nor a date change can close a streak by accident.
local STAMP = "2026-01-15 10:00:00:000"

--- Delivers each captured call through a fresh, armed shared core.
--- @param calls table Array of { variant, module, msg, args } where args is a
---   table.pack() of the format arguments (may be nil for none).
--- @return table delivered Every line the core delivered, in order.
function M.delivered(calls)
	assert(type(calls) == "table" and #calls > 0,
		"repeat replay needs at least one captured call, or it proves nothing")
	local path = assert(package.searchpath("logger", package.path),
		"the shared logger core is not on package.path")
	-- dofile rather than require: a private instance, so neither the process
	-- singleton nor another test's streaks can influence the outcome.
	local core = dofile(path)
	local delivered = {}
	core.clock_fn = function() return 0 end
	core.timestamp_fn = function() return STAMP end
	core.set_sink(function(line) delivered[#delivered + 1] = line end)
	core.enable_repeat_collapsing()
	for _, call in ipairs(calls) do
		local emit = core[call.variant]
		assert(type(emit) == "function", "unknown logger variant: " .. tostring(call.variant))
		local args = call.args or { n = 0 }
		emit(call.module, call.msg, table.unpack(args, 1, args.n or #args))
	end
	return delivered
end

return M
