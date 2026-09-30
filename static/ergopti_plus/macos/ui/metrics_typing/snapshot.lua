--- ui/metrics_typing/snapshot.lua

--- ==============================================================================
--- MODULE: Typing Metrics Snapshot
--- DESCRIPTION:
--- Persists the last complete typing-dashboard publication so the next open
--- can paint it at once, before any aggregation runs. The payload is stored
--- as the exact JavaScript argument it was published with and is never
--- decoded in Lua; a one-line header carries the format version, the time it
--- was computed, and the payload length.
---
--- FEATURES & RATIONALE:
--- 1. Validated before display: a missing or unknown header, a legacy
---    unversioned cache, a length mismatch, or a payload that is not the
---    publication object is discarded with one warning and deleted; it is
---    never shown as data.
--- 2. Atomic replacement: the snapshot is written to a sibling file and
---    renamed over the previous one, so a crash never leaves a torn snapshot.
--- 3. Private diagnostics: warnings name the failing step only, never the
---    path or content, and repeat once per category until a success rearms it.
--- ==============================================================================

local M = {}

local FileSystem = require("adapters.file_system")
local Logger     = require("infra.logger")

local LOG = "metrics_typing.snapshot"





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- Current snapshot format. The unversioned JSON cache that preceded it is
--- format 1 and is rejected by the header check.
M.FORMAT_VERSION = 2

--- Header magic; the header line is `MAGIC version generated_at bytes`.
local MAGIC = "ERGOPTI_TYPING_METRICS_SNAPSHOT"

--- Prefix every publication payload starts with.
local PAYLOAD_PREFIX = '{"manifest":'

local ENOENT_ERROR_CODE = 2

local _cache_dir = (os.getenv("TMPDIR") or "/tmp/"):gsub("/?$", "/")

--- Snapshot location. It keeps the previous cache's name so a legacy file is
--- validated, discarded and replaced rather than left behind with user data.
M.PATH = _cache_dir .. "ergopti_metrics_typing_cache.json"

local PARTIAL_PATH = M.PATH .. ".partial"

local _read_failures = {}
local _save_failures = {}





-- ==========================
-- ==========================
-- ======= 2/ Helpers =======
-- ==========================
-- ==========================

local function report_snapshot_read_failure(category)
	if _read_failures[category] then return end
	_read_failures[category] = true
	Logger.warn(LOG, "Typing metrics snapshot read refused at %s; fresh data loading continues.", category)
end

local function report_snapshot_save_failure(category)
	if _save_failures[category] then return end
	_save_failures[category] = true
	Logger.warn(LOG, "Typing metrics snapshot save refused at %s; live publication continues.", category)
end

--- Removes one path; absence counts as removed.
--- @param path string File path.
--- @return boolean removed
local function remove_path(path)
	local ok, removed, _, error_code = pcall(os.remove, path)
	return ok and (removed == true or error_code == ENOENT_ERROR_CODE)
end

--- Parses and validates snapshot file content.
--- @param content string Raw file content.
--- @return table|nil snapshot { payload, generated_at }.
--- @return string|nil reason Rejection reason.
local function parse(content)
	local newline = content:find("\n", 1, true)
	if not newline then return nil, "missing header" end
	local magic, version, generated_at, length = content:sub(1, newline - 1):match("^(%S+) (%d+) (%d+) (%d+)$")
	if magic ~= MAGIC then return nil, "unknown or legacy format" end
	if tonumber(version) ~= M.FORMAT_VERSION then return nil, "format version " .. tostring(version) end
	local payload = content:sub(newline + 1)
	if #payload ~= tonumber(length) then return nil, "payload length mismatch" end
	if payload:sub(1, #PAYLOAD_PREFIX) ~= PAYLOAD_PREFIX or payload:sub(-1) ~= "}" then
		return nil, "payload is not a publication object"
	end
	local stamp = tonumber(generated_at)
	if not stamp or stamp <= 0 then return nil, "invalid timestamp" end
	return { payload = payload, generated_at = stamp }
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Loads the last snapshot. Invalid content is deleted and reported.
--- @return table|nil snapshot { payload = string, generated_at = epoch seconds }.
function M.load()
	local reported = false
	local read_ok, content, status = pcall(FileSystem.read_with_status, M.PATH, function(category)
		reported = true
		report_snapshot_read_failure(category)
	end)
	if read_ok and status == "absent" then return nil end
	if not read_ok or status ~= "ok" or type(content) ~= "string" then
		if not reported then report_snapshot_read_failure(read_ok and "read" or "dependency") end
		return nil
	end
	local snapshot, reason = parse(content)
	if not snapshot then
		local removed = remove_path(M.PATH)
		Logger.warn(LOG, "Typing metrics snapshot discarded (%s); removal committed=%s.", reason, tostring(removed))
		return nil
	end
	_read_failures = {}
	Logger.debug(LOG, "Typing metrics snapshot loaded (%d bytes).", #snapshot.payload)
	return snapshot
end

--- Replaces the snapshot atomically.
--- @param payload string Publication object text starting with {"manifest":.
--- @param generated_at number Epoch seconds when the data was read.
--- @return boolean saved
function M.save(payload, generated_at)
	if type(payload) ~= "string" or payload:sub(1, #PAYLOAD_PREFIX) ~= PAYLOAD_PREFIX
		or type(generated_at) ~= "number" or generated_at <= 0 then
		report_snapshot_save_failure("validation")
		return false
	end
	local header = string.format("%s %d %d %d\n", MAGIC, M.FORMAT_VERSION, math.floor(generated_at), #payload)
	local opened, file = pcall(io.open, PARTIAL_PATH, "w")
	if not opened or not file then report_snapshot_save_failure("open"); return false end
	local written, result = pcall(function() return file:write(header, payload) end)
	-- Cleanup is mandatory even when a write raises or returns an operational error
	local closed, close_result = pcall(function() return file:close() end)
	local write_failed = not written or result ~= file
	local close_failed = not closed or close_result ~= true
	if write_failed or close_failed then
		remove_path(PARTIAL_PATH)
		report_snapshot_save_failure(write_failed and (close_failed and "write and close" or "write") or "close")
		return false
	end
	local renamed, rename_result = pcall(os.rename, PARTIAL_PATH, M.PATH)
	if not renamed or rename_result ~= true then
		remove_path(PARTIAL_PATH)
		report_snapshot_save_failure("rename")
		return false
	end
	_save_failures = {}
	Logger.debug(LOG, "Typing metrics snapshot saved (%d bytes).", #payload)
	return true
end

--- Deletes the snapshot and any partial write left by an interrupted save.
--- The caller owns the user-facing diagnostic for a refusal.
--- @return boolean removed True when neither file remains.
function M.remove()
	local removed = remove_path(M.PATH)
	local partial_removed = remove_path(PARTIAL_PATH)
	Logger.debug(LOG, "Typing metrics snapshot removal committed=%s.", tostring(removed and partial_removed))
	return removed and partial_removed
end

return M
