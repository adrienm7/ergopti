--- tests/unit/modules/keylogger/test_foreign_aggregate_rebuild.lua

--- ============================================================================
--- MODULE: Regression — foreign raw sync rebuilds dashboard aggregates
--- DESCRIPTION:
--- Foreign data.sql sync persists canonical events_* rows. The dashboards read
--- agg_* / ngram_* instead, so raw replay alone made cross-device metrics stay
--- stale forever. The raw watermark must only advance after the matching derived
--- partition was rebuilt, and an old cache must run the one-time repair too.
--- ============================================================================

local helpers = require("tests.helpers")

-- Two readers, because there are two trees. The driver half is converted below
-- to a SELECTOR so moving or splitting a keylogger module cannot turn these
-- invariants into path errors; the shared half is not under the driver root at
-- all, so it goes through the canonical shared-path helper. One reader serving
-- both is what kept this file out of the automated conversion — it would have
-- had to take a selector at three call sites and a path at the fourth.
local function read_shared(relative_path)
	local fh = assert(io.open(helpers.shared(relative_path), "r"))
	local source = fh:read("*a")
	fh:close()
	return source
end

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local source = helpers.read_driver_source(selector)
	return source
end

helpers.describe("keylogger: foreign sync rebuilds UI aggregate partitions", function()
	helpers.it("defers the foreign watermark until the derived callback succeeds", function()
		local source = read_source("function M._last_complete_batch_offset") -- modules/keylogger/export.lua
		local callback_pos = assert(source:find("pcall(on_applied, entry)", 1, true))
		local watermark_pos = assert(source:find("UPDATE devices SET imported_data_sql_size", callback_pos, true))
		helpers.assert_true(callback_pos < watermark_pos,
			"a failed aggregate rebuild must leave the raw import retryable")
		helpers.assert_true(source:find("return synced_devices", 1, true) ~= nil,
			"the caller must learn when a foreign dashboard update completed")
	end)

	helpers.it("skips an unidentifiable foreign folder instead of rebuilding it forever", function()
		local source = read_source("function M._last_complete_batch_offset") -- modules/keylogger/export.lua
		helpers.assert_true(source:find("local watermark, has_device_row = 0, false", 1, true) ~= nil,
			"sync must distinguish a zero watermark from a missing devices row")
		helpers.assert_true(source:find("not has_device_row", 1, true) ~= nil,
			"an invalid device folder must be skipped before raw replay")
	end)

	helpers.it("rebuilds only the imported device before invalidating UI snapshots", function()
		local source = read_source("local function _mark_aggregate_cache_rebuilt") -- modules/keylogger/log_manager.lua
		local callback_pos = assert(source:find("_sync_foreign_data_sql(function(device_id)", 1, true))
		local rebuild_pos = assert(source:find("_rebuild_aggregates_from_raw(db, { device_id })", callback_pos, true))
		local mark_pos = assert(source:find("_mark_aggregate_cache_rebuilt(db)", rebuild_pos, true))
		helpers.assert_true(callback_pos < rebuild_pos and rebuild_pos < mark_pos,
			"foreign rows must be rebuilt and invalidate the DB revision before their watermark advances")
		helpers.assert_true(source:find("DERIVED_DEVICE_TABLES", 1, true) ~= nil,
			"rebuild must clear the old additive aggregate partition before replaying raw rows")
	end)

	helpers.it("migrates existing aggregate caches, not only a brand-new tmp cache", function()
		local manager = read_source("local function _mark_aggregate_cache_rebuilt") -- modules/keylogger/log_manager.lua
		local writer = read_source("local function _read_schema_sql") -- modules/keylogger/sqlite_writer.lua
		local schema = read_shared("data/db/schema.sql")
		helpers.assert_true(manager:find("aggregate_cache_revision", 1, true) ~= nil,
			"log manager must gate rebuilds with a durable aggregate-cache revision")
		helpers.assert_true(writer:find('{ "aggregate_cache_revision", "0" }', 1, true) ~= nil,
			"upgraded SQLite caches must receive the aggregate-cache revision key")
		helpers.assert_true(schema:find("('aggregate_cache_revision',  '0')", 1, true) ~= nil,
			"fresh SQLite caches must seed the aggregate-cache revision key")
	end)
end)
