--- platform/remap/tap_hold_migration.lua

--- ==============================================================================
--- MODULE: Tap-Hold File Migration (Linux)
--- DESCRIPTION:
--- Binds the shared tap-hold migrator (_shared/lua/tap_hold/migrate.lua) to this
--- driver: the registry is _shared/tap_hold/migrations.toml, the table dialect
--- is tap_hold_shapes, and the retired delays are the Linux column of
--- ``[tap_hold.retired_delays]`` in the shared defaults.
---
--- FEATURES & RATIONALE:
--- 1. One migration for the loader, the writer and the first-run wizard. The
---    writer migrates the file on disk (boot, and before any change it
---    publishes); the loader applies the same step to the document it was
---    given, so a file the boot has not touched yet (the folder the wizard
---    inspects) is never read differently from one that was migrated.
--- 2. The registry is read once and validated; a defect raises, because a driver
---    that guessed a version would rewrite a user's file wrongly.
--- ==============================================================================

local M = {}

local Migrate = require("tap_hold.migrate")
local Shapes = require("platform.remap.tap_hold_shapes")
local Paths = require("infra.paths")

M.META_SECTION = Migrate.META_SECTION
M.VERSION_KEY = Migrate.VERSION_KEY

local _registry = nil

--- The validated shared registry, read once.
--- @return table registry See migrate.parse_registry.
function M.registry()
	if _registry == nil then _registry = Migrate.load_registry(Paths.shared("tap_hold/migrations.toml")) end
	return _registry
end

--- Migrates a decoded user document in place and stamps it.
--- @param document table Decoded user document, edited in place.
--- @param shapes table|nil Canonical shape receipt of the document.
--- @param retired table Driver key id -> the delay an earlier build shipped.
--- @return string outcome "migrated", "current", "newer" or "invalid".
--- @return number|string detail The version the document carried, or why its
---   stamp is invalid.
function M.read_as_current(document, shapes, retired)
	return Migrate.apply(document, M.registry(), retired, function(value) return Shapes.is_table(value, shapes) end)
end

--- Test seam: forgets the cached registry.
function M._reset_for_test()
	_registry = nil
end

return M
