--- _shared/lua/sqlite/event_id_policy.lua
--- ==============================================================================
--- MODULE: SQLite Event ID Numeric Policy
--- DESCRIPTION:
--- Bounds event cursors transported through Lua number scalars and batch-ID
--- arithmetic. IEEE-754 doubles represent every integer only through 2^53 - 1;
--- SQLite's wider native integer range does not make those Lua operations exact.
--- This bound applies to Lua adapters, not native integer-capable drivers.
--- ==============================================================================

local M = {}

-- The next cursor must remain exactly representable after reserving a range,
-- otherwise a later allocation can round onto an already acknowledged ID.
M.MAX_EXACT_LUA_CURSOR = 2 ^ 53 - 1

return M
