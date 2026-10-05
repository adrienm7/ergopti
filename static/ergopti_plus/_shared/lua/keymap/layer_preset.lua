--- _shared/lua/keymap/layer_preset.lua

--- ==============================================================================
--- MODULE: Recommended Layer Import (Shared)
--- DESCRIPTION:
--- Puts Ergopti's recommended navigation layer (_shared/keymap/layers.recommended.toml)
--- into a configuration folder that has no layers.toml. The layer is data the
--- user owns: an absent file binds no key, so without this import the
--- recommended tap-hold key that enters the layer held an empty layer on a
--- fresh install. The first-run wizard's Tap-Holds import and the Tap-Holds
--- « Restore recommended values » call it; the Windows driver implements the
--- same contract in windows/platform/remap/layers_loader.ahk.
---
--- FEATURES & RATIONALE:
--- 1. Additive only: an existing layers.toml — edited, empty, or unreadable —
---    is the user's and is never replaced, merged into or removed.
--- 2. Exact: the file is created with the preset's bytes through the shared
---    writer's "must still be absent" precondition, and undo() removes it only
---    while it still holds those bytes, so a later edit always survives.
--- 3. Fail fast: a missing or malformed shipped file raises; a refused write is
---    returned as an error for the caller to report.
--- ==============================================================================

local M = {}

local TomlWriter = require("toml_codec.writer")





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- The shipped files, relative to the _shared root.
M.PRESET_FILE = "keymap/layers.recommended.toml"
M.VOCABULARY_FILE = "keymap/layer_actions.toml"

-- What import_if_absent() did.
M.IMPORTED = "imported"
M.KEPT = "kept"





-- ==========================
-- ==========================
-- ======= 2/ Helpers =======
-- ==========================
-- ==========================

--- Reads a whole shipped file; raises when it cannot.
--- @param path string
--- @return string content
local function read_shipped(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("layer_preset: cannot read " .. path .. ": " .. tostring(err), 0) end
	local content = fh:read("*a")
	fh:close()
	if type(content) ~= "string" or content == "" then error("layer_preset: " .. path .. " is empty", 0) end
	return content
end

--- The configuration folder without its trailing separator.
local function folder(config_dir)
	if type(config_dir) ~= "string" or config_dir == "" then
		error("layer_preset: the configuration folder is unknown", 3)
	end
	return (config_dir:gsub("[/\\]+$", ""))
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Reads the shipped preset and the name of the user's layer file.
--- @param shared_root string The _shared folder.
--- @param toml_decode function The TOML decoder.
--- @return table preset { text, user_file, layer_id }
function M.read(shared_root, toml_decode)
	if type(shared_root) ~= "string" or shared_root == "" then error("layer_preset: the _shared tree is unreachable", 2) end
	local root = shared_root:gsub("[/\\]+$", "")
	local vocabulary = toml_decode(read_shipped(root .. "/" .. M.VOCABULARY_FILE))
	local meta = type(vocabulary) == "table" and vocabulary._meta or nil
	if type(meta) ~= "table" or type(meta.user_file) ~= "string" or meta.user_file == "" then
		error("layer_preset: " .. M.VOCABULARY_FILE .. " names no [_meta].user_file", 2)
	end
	local text = read_shipped(root .. "/" .. M.PRESET_FILE)
	local decoded = toml_decode(text)
	local layers = type(decoded) == "table" and decoded.layers or nil
	local layer_id = type(layers) == "table" and next(layers) or nil
	if type(layer_id) ~= "string" or next(layers, layer_id) ~= nil then
		error("layer_preset: " .. M.PRESET_FILE .. " must define exactly one layer", 2)
	end
	return { text = text, user_file = meta.user_file, layer_id = layer_id }
end

--- Creates the user's layers.toml from the preset when the folder has none.
--- @param opts table { shared_root, config_dir, toml_decode, file_adapter|nil }
---   where file_adapter is the driver's atomic FileSystem adapter, or nil for
---   the shared writer's own same-directory stage and rename.
--- @return table|nil result { status = IMPORTED|KEPT, path, content, detail|nil }:
---   `detail` says why an existing file was kept without being read.
--- @return string|nil err Why the absent file could not be created.
function M.import_if_absent(opts)
	if type(opts) ~= "table" or type(opts.toml_decode) ~= "function" then
		error("layer_preset.import_if_absent needs the TOML decoder", 2)
	end
	local preset = M.read(opts.shared_root, opts.toml_decode)
	local path = folder(opts.config_dir) .. "/" .. preset.user_file
	local _, status, detail = TomlWriter.read_classified(path, opts.file_adapter)
	if status ~= "absent" then
		return { status = M.KEPT, path = path,
			detail = status ~= "ok" and tostring(detail or status) or nil }
	end
	local written, err = TomlWriter.publish_if_unchanged(path, preset.text, opts.file_adapter, { status = "absent" })
	if not written then return nil, path .. ": " .. tostring(err) end
	return { status = M.IMPORTED, path = path, content = preset.text }
end

--- Settles only the native removal lock retained by a previous undo attempt.
--- Participants call this before any absence shortcut or inverse publication;
--- a cleanup retry never removes or replaces content.
--- @param result table|nil Private import record.
--- @return boolean settled True only after exact native release acknowledgement.
--- @return string|nil err Why cleanup remains pending.
function M.retry_undo_cleanup(result)
	if type(result) ~= "table" or result.removal_cleanup == nil then return true end
	local call_ok, settled, detail = pcall(result.removal_cleanup)
	if not call_ok or settled ~= true then
		return false, tostring((call_ok and detail) or settled or "removal cleanup remains pending")
	end
	result.removal_cleanup = nil
	return true
end

--- Undoes an import: removes the file it created while that file still holds
--- exactly the preset's bytes. A kept file, or one edited since, stays.
--- @param result table|nil What import_if_absent() returned.
--- @param file_adapter table|nil The adapter the import wrote through.
--- @return boolean undone True when no file of the import's own is left.
--- @return string|nil err Why the created file could not be removed.
function M.undo(result, file_adapter)
	if type(result) ~= "table" or result.status ~= M.IMPORTED then return true end
	local settled, settle_err = M.retry_undo_cleanup(result)
	if settled ~= true then return false, settle_err end
	local current, status, detail = TomlWriter.read_classified(result.path, file_adapter)
	if status == "absent" then return true end
	if status ~= "ok" then return false, "the imported layer cannot be read: " .. tostring(detail or status) end
	if current ~= result.content then return true end
	local removed, remove_err, retry_cleanup = TomlWriter.remove_if_unchanged(
		result.path, file_adapter, { status = "ok", content = result.content })
	if type(retry_cleanup) == "function" then result.removal_cleanup = retry_cleanup end
	return removed, remove_err
end

return M
