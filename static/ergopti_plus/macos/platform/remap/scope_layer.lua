--- platform/remap/scope_layer.lua

--- ==============================================================================
--- MODULE: Navigation Layer Scope Participant (macOS)
--- DESCRIPTION:
--- Keeps the navigation layer created by a recommended Tap-Hold scope in the
--- remap owner's reversible cohort. A parent's later refusal removes only the
--- exact acknowledged import before inverse regeneration; a failed parent
--- inverse can restore only the bytes it removed, while the path stays absent.
--- Imported path and bytes remain privately owned rather than borrowed from
--- the public receipt. Existing user files never join this mutation cohort.
--- ==============================================================================

local M = {}

-- Successful receipts are exact capabilities, retained only by their callers.
local receipts = setmetatable({}, { __mode = "k" })

--- Captures the source the native writer classifies at the imported path.
--- @param record table Private import identity.
--- @return string|nil, string, string|nil Classified native source.
local function read(record)
	return require("toml_codec.writer").read_classified(record.path, require("adapters.file_system"))
end

--- Removes only the acknowledged import. A changed or unreadable source
--- retains compensation debt and remains untouched for an explicit retry.
--- @param record table Private import identity.
--- @return boolean, string|nil, boolean Whether an owned file was removed.
local function remove(record)
	if record.status ~= require("keymap.layer_preset").IMPORTED then return true, nil, false end
	local settled, settle_err = require("keymap.layer_preset").retry_undo_cleanup(record)
	if settled ~= true then return false, settle_err, false end
	local content, status, detail = read(record)
	if status == "absent" then return true, nil, false end
	if status ~= "ok" then return false, "navigation-layer-source-unreadable: " .. tostring(detail or status) end
	if content ~= record.content then return false, "navigation-layer-source-changed" end
	local removed = require("platform.remap.nav_layer").undo_import(record, require("adapters.file_system"))
	local _, observed, observed_detail = read(record)
	if removed ~= true then
		-- A native refusal may follow a partial removal. Keep its possible
		-- effect in the parent inverse until a classified read can prove it.
		local changed = observed == "absent" or (observed ~= "ok")
		return false, "navigation-layer-removal-refused", changed
	end
	if observed ~= "absent" then
		return false, "navigation-layer-removal-unverified: " .. tostring(observed_detail or observed), true
	end
	return true, nil, true
end

--- Restores one owned removal without replacing any later external source.
--- @param record table Private import identity.
--- @return boolean, string|nil Native publication receipt.
local function replace(record)
	local settled, settle_err = require("keymap.layer_preset").retry_undo_cleanup(record)
	if settled ~= true then return false, settle_err end
	local content, status, detail = read(record)
	if status == "ok" and content == record.content then return true end
	if status ~= "absent" then
		return false, "navigation-layer-restore-conflict: " .. tostring(detail or status)
	end
	return require("toml_codec.writer").publish_if_unchanged(record.path, record.content,
		require("adapters.file_system"), { status = "absent" })
end

--- Makes a recommended import whose inverse belongs to the local bulk owner.
--- @return table sibling prepare(), restore(), settled(ok), receipt().
function M.import()
	local record, token = nil, nil
	local sibling = {}
	function sibling.prepare()
		local imported, detail = require("platform.remap.nav_layer").import_recommended()
		if not imported then return false, "nav-layer-import-failed" end
		record = { status = imported.status, path = imported.path, content = imported.content }
		token = { status = record.status, path = record.path, content = record.content }
		receipts[token] = record
		return true
	end
	function sibling.restore()
		if not record then return true end
		return remove(record)
	end
	function sibling.settled(ok)
		if not record or ok ~= true then return end
		record.committed = true
		if record.status == require("keymap.layer_preset").IMPORTED then
			require("platform.remap.nav_layer").reconcile_wheel("Remap scope")
		end
	end
	function sibling.receipt() return token end
	return sibling
end

--- Makes the parent inverse of one successfully acknowledged scope import.
--- Its own compensation restores a removed import before compiling the
--- pre-inverse settings. A missing, borrowed or consumed capability refuses.
--- @param token table Exact fourth receipt of a successful apply_scope.
--- @return table|nil sibling, string|nil refusal.
function M.inverse(token)
	local record = type(token) == "table" and receipts[token] or nil
	if not record or record.committed ~= true then return nil, "invalid-navigation-layer-receipt" end
	local removed = false
	local sibling = {}
	function sibling.prepare()
		local ready, detail, changed = remove(record)
		removed = removed or changed == true
		return ready, detail
	end
	function sibling.restore()
		local settled, settle_err = require("keymap.layer_preset").retry_undo_cleanup(record)
		if settled ~= true then return false, settle_err end
		if not removed then return true end
		return replace(record)
	end
	function sibling.settled(ok)
		if ok ~= true then return end
		record.committed = false
		if record.status == require("keymap.layer_preset").IMPORTED then
			require("platform.remap.nav_layer").reconcile_wheel("Remap scope inverse")
		end
	end
	function sibling.receipt() return nil end
	return sibling
end

return M
