--- modules/keylogger/aggregator/state.lua

--- ==============================================================================
--- MODULE: Aggregator Shared State
--- DESCRIPTION:
--- Single mutable state singleton shared across the aggregator sub-modules
--- (core, events, sql). Lua's module cache guarantees that every sub-module
--- that requires this file receives the same table reference, so mutations
--- (e.g. setting agg_batch after a reset) are visible everywhere with no
--- explicit injection needed.
---
--- FIELDS:
---   agg_batch   — per-tick UPSERT accumulator, nil until first ensure_batch()
---   ngram_ctx   — per-app n-gram / burst / session context, survives ticks
---   initialized — true after M.init() completes
---   device_id   — injected by M.init(); used as the partition key in SQL
--- ==============================================================================

return {
	agg_batch   = nil,
	ngram_ctx   = nil,
	initialized = false,
	device_id   = nil,
}
