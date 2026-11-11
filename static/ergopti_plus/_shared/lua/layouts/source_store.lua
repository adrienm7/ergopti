--- _shared/lua/layouts/source_store.lua

--- ==============================================================================
--- MODULE: Layout Source Store
--- DESCRIPTION:
--- Keeps the files the unified layout editor saves from inside ErgoptiPlus:
--- the Ergopti layout source (TOML) and the exports the page produced from it
--- (.keylayout, layers.toml), in one folder of the configuration folder. The
--- page validates the source through the format owner before it saves; this
--- store bounds what reaches the disk (plain file name, allowed extension,
--- UTF-8 text, size) and reopens the last saved source. Shared by the macOS and
--- Linux drivers through their layout registries (manager_bridge.lua routes
--- the page's source_open and source_save messages here).
---
--- FEATURES & RATIONALE:
--- 1. No path from the page: a file name is one plain name of an allowed
---    extension, so the page cannot write outside the store's folder.
--- 2. Fail fast: a refused or failed write reports a stable code and detail;
---    nothing is truncated or rewritten silently.
--- 3. Saving never installs or activates anything: the editor's files are the
---    user's; installing a generated layout stays the layout manager's job.
--- ==============================================================================

local M = {}

local NativePath = require("native_path")

M.FAILURE_INVALID = "source_invalid_file"
M.FAILURE_WRITE   = "write_failed"

-- A plain lowercase name ending in one of the editor's file types.
local FILE_NAME = "^[a-z][a-z0-9_]*%.[a-z]+$"
local EXTENSIONS = { toml = true, keylayout = true }
-- The page names a source after its identifier; layers.toml is the navigation export.
local NAV_FILE = "layers.toml"





-- ===========================
-- ===========================
-- ======= 1/ Settings =======
-- ===========================
-- ===========================

--- Validates the [source] table of the shared layout defaults.
--- @param layout_defaults table Decoded _shared/modules/layouts/defaults.json.
--- @return table|nil settings { folder, last_file, max_file_bytes, max_name_length }
--- @return string|nil error
function M.settings(layout_defaults)
	local source = type(layout_defaults) == "table" and layout_defaults.source or nil
	if type(source) ~= "table" then return nil, "the layout defaults have no source table" end
	for _, field in ipairs({ "folder", "last_file" }) do
		if type(source[field]) ~= "string" or not source[field]:match("^[A-Za-z0-9._-]+$") then
			return nil, "the source " .. field .. " is not a plain name"
		end
	end
	for _, field in ipairs({ "max_file_bytes", "max_name_length" }) do
		local value = source[field]
		if type(value) ~= "number" or value <= 0 or value % 1 ~= 0 then
			return nil, "the source " .. field .. " is not a positive integer"
		end
	end
	return {
		folder = source.folder,
		last_file = source.last_file,
		max_file_bytes = source.max_file_bytes,
		max_name_length = source.max_name_length,
	}, nil
end





-- ===========================
-- ===========================
-- ======= 2/ Checking =======
-- ===========================
-- ===========================

--- Whether a text is well-formed UTF-8 (no overlong form, surrogate or value past U+10FFFF).
--- @param text string
--- @return boolean
function M.is_utf8(text)
	local i, n = 1, #text
	while i <= n do
		local c = text:byte(i)
		local length, low, high = 1, nil, nil
		if c < 0x80 then length = 1
		elseif c >= 0xC2 and c <= 0xDF then length = 2
		elseif c == 0xE0 then length, low = 3, 0xA0
		elseif c == 0xED then length, high = 3, 0x9F
		elseif c >= 0xE1 and c <= 0xEF then length = 3
		elseif c == 0xF0 then length, low = 4, 0x90
		elseif c >= 0xF1 and c <= 0xF3 then length = 4
		elseif c == 0xF4 then length, high = 4, 0x8F
		else return false end
		for k = 1, length - 1 do
			local b = text:byte(i + k)
			if not b then return false end
			local min = (k == 1 and low) or 0x80
			local max = (k == 1 and high) or 0xBF
			if b < min or b > max then return false end
		end
		i = i + length
	end
	return true
end

--- Checks one file the page wants to save.
--- @param settings table From M.settings.
--- @param payload any { filename, text }
--- @return boolean ok
--- @return string|nil detail Why the file is refused.
function M.check(settings, payload)
	if type(payload) ~= "table" then return false, "the save request is not a table" end
	local name, text = payload.filename, payload.text
	if type(name) ~= "string" or #name > settings.max_name_length or not name:match(FILE_NAME) then
		return false, "the file name is not a plain lowercase name"
	end
	if not EXTENSIONS[name:match("%.([a-z]+)$")] then
		return false, "the file type is not one the editor saves"
	end
	if type(text) ~= "string" or text == "" then return false, "the file is empty" end
	if #text > settings.max_file_bytes then return false, "the file is larger than its bound" end
	if not M.is_utf8(text) then return false, "the file is not UTF-8 text" end
	return true, nil
end

--- Reads a file the user picked in a native panel for the editor to open.
--- The name may be any the user chose; the type, size and encoding are bounded.
--- @param settings table From M.settings.
--- @param path string The chosen file.
--- @param read function read(path) -> text|nil.
--- @return table { filename, text } or { code, detail } when refused.
function M.read_picked(settings, path, read)
	local name = type(path) == "string" and NativePath.basename(path) or nil
	local extension = name and name:match("%.([A-Za-z]+)$")
	if not extension or not EXTENSIONS[extension:lower()] then
		return { code = M.FAILURE_INVALID, detail = "the file type is not one the editor opens" }
	end
	local text = read(path)
	if type(text) ~= "string" then return { code = M.FAILURE_INVALID, detail = "the file is unreadable" } end
	if #text > settings.max_file_bytes then
		return { code = M.FAILURE_INVALID, detail = "the file is larger than its bound" }
	end
	if not M.is_utf8(text) then return { code = M.FAILURE_INVALID, detail = "the file is not UTF-8 text" } end
	return { filename = name, text = text }
end

--- Whether a saved file is a layout source the editor reopens.
--- @param name string
--- @return boolean
function M.is_source(name)
	return name ~= NAV_FILE and name:match("%.toml$") ~= nil
end





-- ================================
-- ================================
-- ======= 3/ Operations ==========
-- ================================
-- ================================

--- Creates the open and save operations over a driver's ports.
--- env: settings (M.settings), config_dir (with a trailing slash), read(path),
---   write(path, text) -> ok, err (creating the folder), exists(path),
---   log(level, message, ...).
--- @param env table
--- @return table { open, save, folder }
function M.new(env)
	local settings = env.settings
	local operations = {}

	local function folder()
		return env.config_dir .. settings.folder .. "/"
	end
	operations.folder = folder

	--- Sends the page the last saved source, or none.
	--- @param on_done function on_done({ text, filename, folder })
	function operations.open(on_done)
		local data = { folder = folder() }
		local pointer = folder() .. settings.last_file
		if env.exists(pointer) then
			local name = env.read(pointer)
			name = type(name) == "string" and name:gsub("%s+$", "") or nil
			local ok = name and M.check(settings, { filename = name, text = "x" }) and M.is_source(name)
			local text = ok and env.exists(folder() .. name) and env.read(folder() .. name) or nil
			if type(text) == "string" and #text <= settings.max_file_bytes then
				data.text, data.filename = text, name
			else
				env.log("error", "The last layout source named by %s is unreadable.", pointer)
			end
		end
		on_done(data)
	end

	--- Stores one file of the editor.
	--- @param payload table { filename, text }
	--- @param on_done function on_done(ok, code, detail, filename)
	function operations.save(payload, on_done)
		local ok, detail = M.check(settings, payload)
		if not ok then
			env.log("warn", "Refused a layout editor file: %s.", detail)
			on_done(false, M.FAILURE_INVALID, detail, nil)
			return
		end
		local path = folder() .. payload.filename
		local written, write_err = env.write(path, payload.text)
		if not written then
			env.log("error", "The layout editor file %s could not be written: %s.", path, tostring(write_err))
			on_done(false, M.FAILURE_WRITE, tostring(write_err), payload.filename)
			return
		end
		if M.is_source(payload.filename) then
			local pointed, pointer_err = env.write(folder() .. settings.last_file, payload.filename .. "\n")
			if not pointed then
				env.log("error", "The last layout source could not be recorded: %s.", tostring(pointer_err))
				on_done(false, M.FAILURE_WRITE, tostring(pointer_err), payload.filename)
				return
			end
		end
		env.log("info", "Layout editor file saved: %s.", path)
		on_done(true, nil, path, payload.filename)
	end

	return operations
end

return M
