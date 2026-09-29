--- _shared/lua/layouts/extension.lua

--- ==============================================================================
--- MODULE: Layout Extension Content
--- DESCRIPTION:
--- Validates and stages existing-format extension files. Content generations are
--- immutable; only the atomically published installed-layout record makes a
--- generation discoverable by the existing extension scanners. No enable state
--- is read or written here. Network, digest and filesystem operations are injected.
--- ==============================================================================

local M = {}
local Registry = require("layouts.registry")

--- Whether a checksum is the lowercase SHA-256 format used by the index builder.
--- @param value any
--- @return boolean
local function checksum(value)
	return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

--- Accepts only existing extension paths, never traversal or arbitrary code files.
--- @param path any
--- @param id string Layout id.
--- @return boolean
local function supported_path(path, id)
	if type(path) ~= "string" then return false end
	return path == "manifest.toml" or path == id .. ".keylayout"
		or path:match("^hotstrings/[a-z][a-z0-9_-]*%.toml$") ~= nil
		or path == "shortcuts/menu.lua" or path == "shortcuts/menu.ahk"
		or path:match("^[A-Z][A-Z0-9_-]*$") ~= nil
		or path:match("^[A-Z][A-Z0-9_-]*%.txt$") ~= nil
end

--- Validates a complete extension inventory before network or disk effects.
--- @param entry table Layout registry entry.
--- @param max_bytes number|nil Optional aggregate download bound.
--- @return boolean
--- @return string|nil
function M.validate(entry, max_bytes)
	if type(entry) ~= "table" or not Registry.is_valid_id(entry.id) then return false, "invalid layout id" end
	local extension = entry.extension
	if type(extension) ~= "table" or type(extension.id) ~= "string"
		or not extension.id:match("^[a-z][a-z0-9_-]*$") or not checksum(extension.sha256)
		or type(extension.files) ~= "table" or type(extension.name) ~= "string" or extension.name == "" then
		return false, "invalid layout extension inventory"
	end
	local seen, total = {}, 0
	for _, file in ipairs(extension.files) do
		if type(file) ~= "table" or not supported_path(file.path, entry.id)
			or (file.file ~= entry.id .. "/" .. file.path and file.file ~= extension.id .. "/" .. file.path) or seen[file.path]
			or type(file.size) ~= "number" or file.size < 0 or file.size % 1 ~= 0 or not checksum(file.sha256) then
			return false, "invalid or duplicate layout extension file"
		end
		seen[file.path] = true
		total = total + file.size
	end
	if not seen["manifest.toml"] or not seen[entry.id .. ".keylayout"] then
		return false, "layout extension is missing its manifest or keylayout"
	end
	if max_bytes and total > max_bytes then return false, "layout extension exceeds the download bound" end
	return true
end

--- A generation root contains one ordinary extension directory.
--- @param local_dir string Layout state directory, ending in a separator.
--- @param entry table Validated registry entry.
--- @return string
function M.generation_root(local_dir, entry)
	return local_dir .. "extensions/" .. entry.id .. "/" .. entry.extension.sha256
end

--- Downloads or reads every file, then verifies its bytes before yielding content.
--- @param settings table Registry settings.
--- @param entry table Registry entry.
--- @param deps table Injected read_bundled and transport collaborators.
--- @param on_done function Receives (ok, files_or_reason).
function M.acquire(settings, entry, deps, on_done)
	local valid, reason = M.validate(entry, settings.max_file_bytes)
	if not valid then on_done(false, reason) return end
	local output, position, finished = {}, 0, false
	local function finish(ok, detail)
		if finished then return end
		finished = true
		on_done(ok, detail)
	end
	local next_file
	next_file = function()
		position = position + 1
		local file = entry.extension.files[position]
		if not file then finish(true, output) return end
		local digest_started, accepted = false, false
		local function verify(text)
			if digest_started or finished then return end
			digest_started = true
			if type(text) ~= "string" or #text ~= file.size then finish(false, "extension file size mismatch") return end
			deps.transport.sha256(text, function(digest, err)
				if accepted or finished then return end
				accepted = true
				if digest ~= file.sha256 then finish(false, "extension checksum mismatch: " .. tostring(err or file.path)) return end
				output[file.path] = text
				next_file()
			end)
		end
		local function download()
			local received = false
			deps.transport.get(Registry.raw_url(settings, file.file), { ["User-Agent"] = Registry.USER_AGENT },
				settings.timeout_ms, function(status, body, err)
					if received or finished then return end
					received = true
					if tonumber(status) ~= 200 then finish(false, tostring(err or status)) else verify(body) end
				end)
		end
		local bundled = type(deps.read_bundled) == "function" and deps.read_bundled(file.file) or nil
		if type(bundled) == "string" and #bundled == file.size then
			-- Only a matching digest can accept a bundled file. A changed remote
			-- extension may share the same layout bytes but carry newer hotstrings.
			local checked = false
			deps.transport.sha256(bundled, function(digest)
				if checked or finished then return end
				checked = true
				if digest == file.sha256 then verify(bundled) else download() end
			end)
		else
			download()
		end
	end
	next_file()
end

--- Stages already verified content without changing its installed record.
--- Existing generations are immutable; conflicting bytes are a hard failure.
--- @param local_dir string Layout state directory.
--- @param entry table Registry entry.
--- @param content table Verified bytes keyed by relative extension path.
--- @param deps table Injected read(path) and atomic write(path, text) functions.
--- @return boolean
--- @return string|nil
function M.stage(local_dir, entry, content, deps)
	local valid, reason = M.validate(entry)
	if not valid then return false, reason end
	for _, file in ipairs(entry.extension.files) do
		if type(content[file.path]) ~= "string" or #content[file.path] ~= file.size then
			return false, "incomplete verified extension content"
		end
	end
	local directory = M.generation_root(local_dir, entry) .. "/" .. entry.extension.id .. "/"
	for _, file in ipairs(entry.extension.files) do
		local path, text = directory .. file.path, content[file.path]
		local existing = deps.read(path)
		if existing ~= nil and existing ~= text then return false, "immutable extension content changed" end
		if existing == nil then
			local ok, err = deps.write(path, text)
			if not ok then return false, err end
		end
	end
	return true
end

--- Supplies roots only for committed entries; staging directories remain invisible.
--- @param local_dir string Layout state directory.
--- @param record table Installed-layout record.
--- @return table Sorted extension roots, consumed by the existing scanner.
function M.roots(local_dir, record)
	local roots = {}
	for _, entry in pairs(record.layouts) do
		if entry.extension ~= nil then
			local valid, reason = M.validate(entry)
			if not valid then error(reason, 0) end
			roots[#roots + 1] = M.generation_root(local_dir, entry)
		end
	end
	table.sort(roots)
	return roots
end

--- The extension root of the layout family every driver ships built in.
---
--- Installed means discoverable: a layout manager installation commits a
--- generation root (M.roots), and the Ergopti family counts as installed wherever
--- the driver ships the registry folder, because its layouts work from that copy
--- without any download (Windows emulates them, macOS and Linux install them
--- offline) and machines already type on them without an installed record. Its
--- extension folder is named after the family: the family's layouts declare it
--- as their extension_source. Placed after the installed generations, so a
--- generation staged before this app version cannot hide the extension files
--- the app's own code expects; the user's folder still overrides it.
--- @param bundled_dir string|nil Shipped registry folder, ending in a separator.
--- @param settings table Registry settings (ergopti_family).
--- @param exists function exists(path) -> boolean
--- @return table|nil { pack = dir } scanner root; nil when no registry shipped.
function M.shipped_root(bundled_dir, settings, exists)
	if type(settings) ~= "table" or not Registry.is_valid_id(settings.ergopti_family)
		or type(exists) ~= "function" then
		error("shipped_root needs the registry settings and an exists function", 0)
	end
	if type(bundled_dir) ~= "string" or bundled_dir == "" then return nil end
	local dir = bundled_dir .. settings.ergopti_family
	if not exists(dir .. "/manifest.toml") then return nil end
	return { pack = dir }
end

return M
