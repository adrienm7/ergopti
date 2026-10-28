--- modules/keystats/aggregator.lua

--- ==============================================================================
--- MODULE: Keystats Aggregator — Coordinator
--- DESCRIPTION:
--- Thin public façade that assembles the four aggregator sub-modules into the
--- same API surface previously offered by the monolithic aggregator. Callers
--- require this file exactly as before; the split is purely internal.
---
--- SUB-MODULES:
---   aggregator/state.lua  — shared mutable singleton (Lua module-cache shared)
---   aggregator/core.lua   — constants, helpers, batch management, guards
---   aggregator/events.lua — walk_typing / walk_app_switch / walk_window_switch /
---                           walk_system_event
---   aggregator/sql.lua    — flush() (SQL UPSERT helpers, batch drain)
---
--- DEPENDENCIES:
--- - lib.logger (project-wide logger).
--- - hs.json, hs.sqlite3 (via sql.lua).
--- - modules.keystats.sqlite_writer (via sql.lua).
--- - modules.keystats.export (via sql.lua).
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local LOG    = "keystats.aggregator"

local S      = require("modules.keystats.aggregator.state")
local C      = require("modules.keystats.aggregator.core")
local Events = require("modules.keystats.aggregator.events")
local Sql    = require("modules.keystats.aggregator.sql")





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

M.reset_batch    = C.reset_batch
M.has_pending_batch = C.has_pending_batch
M.get_ngram_ctx  = C.get_ngram_ctx
M.set_ngram_ctx  = C.set_ngram_ctx
M.reset_ngram_ctx = C.reset_ngram_ctx
M.set_device_id  = C.set_device_id
M.get_device_id  = C.get_device_id

M.walk_typing       = Events.walk_typing
M.walk_app_switch   = Events.walk_app_switch
M.walk_window_switch = Events.walk_window_switch
M.walk_system_event = Events.walk_system_event

M.flush = Sql.flush





-- ==============================
-- ==============================
-- ======= 2/ Initializer =======
-- ==============================
-- ==============================

--- Initialize the aggregator with the device id.
--- @param deps table Must contain: device_id (string).
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table" or type(deps.device_id) ~= "string" then
		Logger.error(LOG, "M.init(): invalid deps — aggregator non-functional.")
		return
	end
	if S.initialized then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	S.device_id   = deps.device_id
	S.initialized = true
	C.reset_batch()
	Logger.success(LOG, "Initialized.")
end

return M
