--- _shared/lua/keymap/layer_editor.lua

--- ==============================================================================
--- MODULE: Layer Editor Host Logic (Shared)
--- DESCRIPTION:
--- What the macOS and Linux hosts of the navigation layer editor
--- (_shared/ui/layer_editor) do with the page's messages, without any window:
--- the payload init() receives, the legends of the user's layout, and the
--- validation and write of a save. The Windows host implements the same
--- contract in windows/ui/layer_editor/init.ahk.
---
--- FEATURES & RATIONALE:
--- 1. A saved file must load without a single error on every OS. The page only
---    offers what exists on the OS it edits for; the host still refuses any
---    text that one of the three loaders would reject or drop, so the editor
---    can never write a layers.toml another machine reads differently.
--- 2. Only a string of bounded size reaches a loader; any other payload is
---    refused first.
--- 3. The file is published atomically through the shared TOML writer (the
---    driver's own atomic adapter when it has one), against the content read
---    just before, and a refused save leaves the file untouched.
--- 4. Legends: the page shows on each key that types a character (the
---    registry sends it by scan code, `ahk_send: null`) what the user's layout
---    types there, read by the host through its driver's own layout owner. A
---    key the layout leaves without a printable character is left out, the
---    page draws its registry code, and the host says why once
---    (_shared/tests/corpus/layer_editor/legends.json).
--- ==============================================================================

local M = {}

local Layers = require("keymap.layers")
local TomlWriter = require("toml_codec.writer")





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

-- The largest layers.toml the editor accepts. Every registry key bound in all
-- four sections is about 25 KB; anything larger is not a layer file.
M.MAX_TEXT_BYTES = 65536

-- The error codes this module adds to the loader's.
M.INVALID_PAYLOAD = "invalid_payload"
M.WRITE_FAILED = "write_failed"
M.FILE_UNREADABLE = "file_unreadable"

-- Where the legends were read: the layout the driver emulates, or the OS's.
M.LEGEND_SOURCE_EMULATION = "emulation"
M.LEGEND_SOURCE_OS = "os"

-- The spaces a legend made of nothing else would show as a blank key: ASCII
-- whitespace, the no-break space and the narrow no-break space.
local BLANKS = { "%s", "\194\160", "\226\128\175" }

-- The unresolved-legend reports already logged, by signature: a host says
-- once why keys show their code, not at every window it opens.
local _reported = {}





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





--- Whether a registry key types what the active layout puts on it: the
--- registry sends it by its scan code (json.lua reads the null of
--- `ahk_send` as a sentinel table, so only a name marks a named key).
--- @param entry table A registry key.
--- @return boolean
local function types_a_character(entry)
	return type(entry) == "table" and entry.kind == "key" and type(entry.ahk_send) ~= "string"
end





-- ===========================
-- ===========================
-- ======= 3/ Legends ========
-- ===========================
-- ===========================

--- The codes of the keys whose legend comes from the user's layout, sorted.
--- @param ctx table The loader context.
--- @return table codes
function M.character_codes(ctx)
	local codes = {}
	for code, entry in pairs(ctx.registry.keys) do
		if types_a_character(entry) then codes[#codes + 1] = code end
	end
	table.sort(codes)
	return codes
end

--- A layout's character as a key legend.
--- @param text any What the layout types on a key.
--- @return string|nil text The same text; nil when it is not a string, is
---   empty or blank, or holds a control character (C0, DEL or C1).
function M.legend_text(text)
	if type(text) ~= "string" or text == "" then return nil end
	if text:find("[%z\1-\31\127]") or text:find("\194[\128-\159]") then return nil end
	local rest = text
	for _, blank in ipairs(BLANKS) do rest = rest:gsub(blank, "") end
	if rest == "" then return nil end
	return text
end

--- The legends of every key that types a character.
--- @param opts table { ctx, source = M.LEGEND_SOURCE_*, character = function(code, entry) }
---   where character returns what the layout types on that registry key, or nil.
--- @return table legends { source, keys = { [code] = text } }, the page's `legends`.
--- @return table unresolved The sorted codes the layout gave no legend.
function M.legends(opts)
	if opts.source ~= M.LEGEND_SOURCE_EMULATION and opts.source ~= M.LEGEND_SOURCE_OS then
		error("layer_editor.legends: unknown legend source '" .. tostring(opts.source) .. "'", 2)
	end
	local keys, unresolved = {}, {}
	for _, code in ipairs(M.character_codes(opts.ctx)) do
		local text = M.legend_text(opts.character(code, opts.ctx.registry.keys[code]))
		if text then keys[code] = text else unresolved[#unresolved + 1] = code end
	end
	return { source = opts.source, keys = keys }, unresolved
end

--- Says once why keys show their registry code instead of a legend.
--- @param unresolved table The codes M.legends left out.
--- @param reason string Why the layout gave them none, for the log.
--- @param warn function Logs one line.
--- @return boolean reported True when this call logged.
function M.report_unresolved(unresolved, reason, warn)
	if #unresolved == 0 then return false end
	local signature = table.concat(unresolved, ",") .. "|" .. reason
	if _reported[signature] then return false end
	_reported[signature] = true
	warn(string.format("%d key(s) show their registry code, not a legend (%s): %s.",
		#unresolved, table.concat(unresolved, ", "), reason))
	return true
end

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





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Builds what the page's init() receives: the OS, the file's path and text,
--- every problem any OS's loader finds in it, the legends of the user's
--- layout and the keys whose hold enters the layer.
--- @param opts table { os, ctx, config_dir, read_file, toml_decode, legends,
---   layer_keys } where read_file(path) returns the content, nil when the file
---   does not exist, or raises when it exists and cannot be read; legends is
---   M.legends' first result; layer_keys the registry codes of the layer keys.
--- @return table payload { os, path, text|nil, errors, legends, layer_keys }
function M.init_payload(opts)
	if type(opts.legends) ~= "table" or type(opts.layer_keys) ~= "table" then
		error("layer_editor.init_payload needs the legends and the layer keys", 2)
	end
	local path = Layers.user_file_path(opts.config_dir, opts.ctx)
	local payload = { os = opts.os, path = path, legends = opts.legends, layer_keys = opts.layer_keys }
	local read_ok, text = pcall(opts.read_file, path)
	if not read_ok then
		payload.errors = { new_error(M.FILE_UNREADABLE, tostring(text)) }
		return payload
	end
	payload.text = text
	payload.errors = text ~= nil and errors_on_every_os(text, opts.ctx, opts.toml_decode) or {}
	return payload
end

--- Validates the text of a layer file the page asks to save.
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

--- Test seam: forgets the unresolved-legend reports already logged.
function M._reset_for_test()
	_reported = {}
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
	if content == nil then error("layer_editor: shipped file missing: " .. path, 0) end
	return content
end

return M
