--- tests/support/legacy_folder_migration_stub.lua

--- ==============================================================================
--- MODULE: Inert Legacy Folder Migration For Main Harnesses
--- DESCRIPTION:
--- Main runs settings/engine/migration/legacy_folder_migration.lua before the logger and the
--- bootstrap storage. The harnesses that load all of ergopti_hotstrings.lua
--- over controlled imports give it this double instead: it moves nothing,
--- touches no folder and logs nothing, so the account's XDG folders stay
--- untouched. The migration itself is tested in
--- tests/unit/settings/migration/test_legacy_folder_migration.lua.
--- ==============================================================================

local M = {}

--- Returns an empty report, as a boot with no legacy folder would.
--- @return table report
function M.run()
	return { moved = {}, backed_up = {}, kept = {}, removed = {}, cache_ready = true }
end

--- Logs nothing: the report is empty.
function M.log() end

return M
