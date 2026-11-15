--- _shared/layouts/engine/layers/editor.lua

--- ==============================================================================
--- MODULE: Layer File Validation and Save (Shared)
--- DESCRIPTION:
--- What the macOS and Linux drivers do with a layers.toml Ergopti Studio
--- compiled from a source's navigation layer (modules/keymap/nav_layer_save.lua):
--- the validation and the write, without any window. The Windows driver
--- implements the same contract in windows/platform/remap/nav_layer_save.ahk.
---
--- FEATURES & RATIONALE:
--- 1. A saved file must load without a single error on every OS: the save
---    refuses any text that one of the three loaders would reject or drop, so
---    it can never write a layers.toml another machine reads differently.
--- 2. Only a string of bounded size reaches a loader; any other payload is
---    refused first.
--- 3. The file is published atomically through the shared TOML writer (the
---    driver's own atomic adapter when it has one), against the content read
---    just before, and a refused save leaves the file untouched.
--- ==============================================================================

local M = {}

local Layers = require("layouts.engine.layers.layers")
local TomlWriter = require("core.text.engine.toml_codec.writer")
local Timings = require("core.timing.engine.timings")





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- The largest layers.toml a save accepts ([limits] layer_file_bytes).
M.MAX_TEXT_BYTES = Timings.count("limits", "layer_file_bytes")

-- The error codes this module adds to the loader's.
M.INVALID_PAYLOAD = "invalid_payload"
M.WRITE_FAILED = "write_failed"






-- ==========================
-- ==========================
-- ======= 2/ Helpers =======
-- ==========================
-- ==========================

--- @return table error One error record in the loaders' shape.
local function new_error(code, detail)
	return { code = code, detail = detail }
end

--- Loads a text on every OS and returns each distinct error once.
--- @param text string The layer file.
--- @param ctx table The loader context.
--- @param toml_decode function The TOML decoder.
--- @return table errors
local function errors_on_every_os(text, ctx, toml_decode)
	local out, seen = {}, {}
	for _, os_name in ipairs(ctx.platforms) do
		local result = Layers.load(text, os_name, ctx, toml_decode)
		for _, err in ipairs(result.errors) do
			local signature = Layers.error_signature(err)
			if not seen[signature] then
				seen[signature] = true
				out[#out + 1] = err
			end
		end
	end
	return out
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- The registry code of the key a driver names by one of its own identifiers.
--- @param ctx table The loader context.
--- @param identify function(entry) -> the driver's identifier of a registry key.
--- @param id any The identifier looked up.
--- @return string|nil code
function M.code_of(ctx, identify, id)
	for code, entry in pairs(ctx.registry.keys) do
		if identify(entry) == id then return code end
	end
	return nil
end

--- Validates the text of a layer file before it is saved.
--- @param text any The payload's text.
--- @param ctx table The loader context.
--- @param toml_decode function The TOML decoder.
--- @return boolean valid True when every OS loads it without an error.
--- @return table errors What is wrong, empty when valid.
function M.validate(text, ctx, toml_decode)
	if type(text) ~= "string" then
		return false, { new_error(M.INVALID_PAYLOAD, "the save carries no layer file text") }
	end
	if #text > M.MAX_TEXT_BYTES then
		return false, { new_error(M.INVALID_PAYLOAD,
			"the layer file is " .. #text .. " bytes, more than " .. M.MAX_TEXT_BYTES) }
	end
	local errors = errors_on_every_os(text, ctx, toml_decode)
	return #errors == 0, errors
end

--- Validates then publishes the user's layers.toml.
--- @param opts table { text, ctx, config_dir, toml_decode, file_adapter } where
---   file_adapter is the driver's atomic FileSystem adapter, or nil for the
---   shared writer's own same-directory stage and rename.
--- @return table result { saved = boolean, path = string, errors = table }
function M.save(opts)
	local path = Layers.user_file_path(opts.config_dir, opts.ctx)
	local valid, errors = M.validate(opts.text, opts.ctx, opts.toml_decode)
	if not valid then return { saved = false, path = path, errors = errors } end
	local current, status, detail = TomlWriter.read_classified(path, opts.file_adapter)
	if status ~= "ok" and status ~= "absent" then
		return { saved = false, path = path, errors = { new_error(M.WRITE_FAILED, tostring(detail or status)) } }
	end
	local written, write_err = TomlWriter.publish_if_unchanged(path, opts.text, opts.file_adapter,
		{ status = status, content = current })
	if not written then
		return { saved = false, path = path, errors = { new_error(M.WRITE_FAILED, tostring(write_err)) } }
	end
	return { saved = true, path = path, errors = {} }
end

--- Reads a file: its content, nil when it does not exist; raises otherwise.
--- @param path string
--- @return string|nil content
function M.read_file(path)
	local fh, err, code = io.open(path, "rb")
	if not fh then
		-- errno 2 (ENOENT): the file does not exist, which is no layer.
		if code == 2 then return nil end
		error(tostring(err), 0)
	end
	local content = fh:read("*a")
	fh:close()
	if content == nil then error("cannot read " .. path, 0) end
	return content
end

--- Reads a shipped file; raises when it is missing or unreadable.
--- @param path string
--- @return string content
function M.read_shipped(path)
	local content = M.read_file(path)
	if content == nil then error("layer file: shipped file missing: " .. path, 0) end
	return content
end

return M
