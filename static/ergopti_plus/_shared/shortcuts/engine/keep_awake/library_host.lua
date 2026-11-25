--- _shared/shortcuts/engine/keep_awake/library_host.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Library Window Host (Shared)
--- DESCRIPTION:
--- The macOS and Linux answer to the « Bibliothèque anti-veille… » window
--- (_shared/ui/keep_awake_library, bridge hsKeepAwake): its first data, every
--- edit of the presets document through the shared store, « Ajouter un
--- bouton… » (a region the user draws, kept as a library image), the import
--- of an image file of any common format, and the export and import of one
--- preset with its images. The Windows driver runs a twin of this protocol.
---
--- FEATURES & RATIONALE:
--- 1. Every edit goes through the library store (keep_awake_library.lua), so
---    the window can never save a document the drivers would refuse; only the
---    store's own edits are accepted from the page.
--- 2. A library image is a PNG named by its target id in the library's image
---    folder; the page sees it as base64 for its thumbnail only.
--- 3. A preset file carries its images as base64 PNG; on import a taken id or
---    image name gets a fresh one, so an import never overwrites a preset.
--- 4. The driver owns the window, its dialogs, the region selection, the
---    image conversion and the file I/O (ports).
--- ==============================================================================

local Json = require("core.text.engine.json")
local Logger = require("core.logger.engine.shim")
local Presets = require("shortcuts.engine.keep_awake.presets")
local Base64 = require("core.lifecycle.engine.compat.base64")

local M = {}

local LOG = "keep_awake.library_window"

--- The window's app id in apps.manifest.json and its bridge name.
M.APP_ID = "keep_awake_library"
M.BRIDGE = "hsKeepAwake"

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

--- Every locale key the page reads.
--- @param data table keep_awake_library.json.
--- @param starters table keep_awake_presets.json (the starters' translated names).
--- @return table keys
function M.string_keys(data, starters)
	local keys = {}
	for index, name in ipairs(data.page_keys) do keys[index] = "keepawake.library." .. name end
	for _, preset in ipairs(starters.presets) do keys[#keys + 1] = preset.name_key end
	table.sort(keys)
	return keys
end

--- A fresh id from a base, unique among taken.
--- @param base string
--- @param taken function (id) -> boolean
--- @return string
function M.fresh_id(base, taken)
	local stem = (tostring(base):gsub("[^%w_%-]", "_")):sub(1, 48)
	if stem == "" then stem = "item" end
	if not taken(stem) then return stem end
	local n = 2
	while taken(stem .. "_" .. n) do n = n + 1 end
	return stem .. "_" .. n
end

--- Builds one window's host.
--- @param ports table {
---   library = the driver's library store (keep_awake_library.new),
---   os_name = "macos"|"windows"|"linux", separator = "/",
---   push = function(fn_name, payload): calls window[fn_name](payload) in the page,
---   translate = function(key) -> string,
---   capture_region = function(callback(path|nil, reason)): a PNG of a region the user draws,
---   convert_image = function(callback(path|nil, reason)): a PNG of an image file the user picks,
---   save_path = function(default_name) -> string|nil, open_path = function() -> string|nil (a preset file),
---   read_file = function(path) -> string|nil, write_file = function(path, bytes) -> boolean,
---   remove_file = function(path),
---   close = function() }
--- @return table host { on_message }
function M.new(ports)
	assert(type(ports) == "table" and type(ports.library) == "table", "a library window host needs the store")
	for _, name in ipairs({ "push", "translate", "capture_region", "convert_image", "save_path", "open_path",
		"read_file", "write_file", "remove_file", "close" }) do
		assert(type(ports[name]) == "function", "a library window host needs the port " .. name)
	end
	local host = {}
	local library = ports.library
	local data = library.read_shared("shortcuts/data/keep_awake_library.json")
	local sep = ports.separator or "/"

	local function images_dir()
		local _, images = library.paths()
		return images
	end

	-- Every library image of the document, as base64 PNG, for the thumbnails.
	local function thumbnails(doc)
		local out, seen = {}, {}
		for _, preset in ipairs(doc.presets) do
			for _, image in ipairs(preset.images) do
				if not seen[image.file] then
					seen[image.file] = true
					local bytes = ports.read_file(images_dir() .. sep .. image.file)
					if type(bytes) == "string" and bytes:sub(1, 8) == PNG_SIGNATURE then
						out[image.file] = Base64.encode(bytes)
					end
				end
			end
		end
		return out
	end

	local function push_doc(extra)
		local doc = library.document()
		local payload = { doc = doc, thumbnails = thumbnails(doc) }
		for key, value in pairs(extra or {}) do payload[key] = value end
		ports.push("onDoc", payload)
	end

	local function strings()
		local out = {}
		for _, key in ipairs(M.string_keys(data, library.read_shared("shortcuts/data/keep_awake_presets.json"))) do out[key] = ports.translate(key) end
		return out
	end

	local function ready()
		local defaults = library.defaults()
		ports.push("initData", { strings = strings(), os = ports.os_name, defaults = defaults,
			doc = library.document(), thumbnails = thumbnails(library.document()) })
	end

	local function edit(op, args)
		local count = data.edits[op]
		if not count or type(args) ~= "table" or #args ~= count then
			Logger.warn(LOG, "The library window asked for an edit it may not make: %s.", tostring(op))
			return push_doc({ ok = false, reason = "invalid_request" })
		end
		local ok, reason = library.edit(op, (table.unpack or unpack)(args))
		push_doc({ ok = ok == true, reason = reason })
	end

	-- Keeps a PNG as a new image target of a preset.
	local function keep_image(preset_id, path, base)
		local bytes = ports.read_file(path)
		ports.remove_file(path)
		if type(bytes) ~= "string" or bytes:sub(1, 8) ~= PNG_SIGNATURE then
			Logger.warn(LOG, "The new library image is not a PNG.")
			return ports.push("onImage", { ok = false, reason = "import_failed" })
		end
		local doc = library.document()
		local preset = Presets.get(doc, preset_id)
		if not preset then return ports.push("onImage", { ok = false, reason = "preset_unknown" }) end
		local used = {}
		for _, other in ipairs(doc.presets) do
			for _, kind in ipairs({ "images", "texts" }) do
				for _, target in ipairs(other[kind]) do used[target.id] = true end
			end
		end
		local id = M.fresh_id(base, function(candidate) return used[candidate] == true end)
		if not ports.write_file(images_dir() .. sep .. id .. ".png", bytes) then
			Logger.error(LOG, "The library image could not be written.")
			return ports.push("onImage", { ok = false, reason = "presets_write_failed" })
		end
		local ok, reason = library.edit("put_target", preset_id, "images", { id = id, file = id .. ".png", enabled = true })
		Logger.info(LOG, "Library image %s added to preset %s.", id, preset_id)
		ports.push("onImage", { ok = ok == true, reason = reason, id = id })
		push_doc()
	end

	local function add_image(preset_id, source)
		local run = source == "capture" and ports.capture_region or ports.convert_image
		run(function(path, reason)
			if not path then
				if reason ~= "cancelled" then Logger.warn(LOG, "No library image: reason=%s.", tostring(reason)) end
				return ports.push("onImage", { ok = false, reason = reason or "import_failed" })
			end
			keep_image(preset_id, path, source == "capture" and "button" or "image")
		end)
	end

	local function export(preset_id)
		local preset = Presets.get(library.document(), preset_id)
		if not preset then return ports.push("onExported", { ok = false, reason = "preset_unknown" }) end
		local images = {}
		for _, image in ipairs(preset.images) do
			local bytes = ports.read_file(images_dir() .. sep .. image.file)
			if type(bytes) == "string" then images[image.file] = Base64.encode(bytes) end
		end
		local path = ports.save_path(preset.id .. ".json")
		if not path then return end
		local text = Json.encode({ format = data.export_format, version = data.export_version, preset = preset,
			images = images })
		local ok = ports.write_file(path, text)
		if not ok then Logger.error(LOG, "The preset export could not be written.") end
		Logger.info(LOG, "Preset %s exported with %d image(s).", preset.id, #preset.images)
		ports.push("onExported", { ok = ok == true, reason = not ok and "presets_write_failed" or nil })
	end

	local function import()
		local path = ports.open_path()
		if not path then return end
		local ok, file = pcall(Json.decode, ports.read_file(path) or "")
		if not ok or type(file) ~= "table" or file.format ~= data.export_format or file.version ~= data.export_version
			or type(file.preset) ~= "table" or type(file.images) ~= "table" then
			Logger.warn(LOG, "The preset file is not an exported anti-sleep preset.")
			return ports.push("onImported", { ok = false, reason = "presets_document_invalid" })
		end
		local preset = file.preset
		local invalid = Presets.invalid(preset)
		if invalid then return ports.push("onImported", { ok = false, reason = invalid }) end
		local doc = library.document()
		preset.id = M.fresh_id(preset.id, function(id) return Presets.get(doc, id) ~= nil end)
		for _, image in ipairs(preset.images) do
			local encoded = file.images[image.file]
			local bytes = type(encoded) == "string" and Base64.decode(encoded) or nil
			if type(bytes) ~= "string" or bytes:sub(1, 8) ~= PNG_SIGNATURE then
				return ports.push("onImported", { ok = false, reason = "presets_document_invalid" })
			end
			local stem = M.fresh_id(preset.id .. "_" .. image.id, function(candidate)
				return ports.read_file(images_dir() .. sep .. candidate .. ".png") ~= nil
			end)
			if not ports.write_file(images_dir() .. sep .. stem .. ".png", bytes) then
				return ports.push("onImported", { ok = false, reason = "presets_write_failed" })
			end
			image.file = stem .. ".png"
		end
		local added, reason = library.edit("add", preset)
		Logger.info(LOG, "Preset file imported as %s: %s.", preset.id, tostring(added == true))
		ports.push("onImported", { ok = added == true, reason = reason, id = preset.id })
		push_doc()
	end

	--- Handles one message of the page.
	--- @param message table
	function host.on_message(message)
		if type(message) ~= "table" or type(message.action) ~= "string" then
			Logger.warn(LOG, "The library window sent a message without an action.")
			return
		end
		local action = message.action
		if action == "ready" then return ready() end
		if action == "edit" then return edit(message.op, message.args) end
		if action == "add_image" then return add_image(message.preset, message.source) end
		if action == "export" then return export(message.preset) end
		if action == "import" then return import() end
		if action == "close" then return ports.close() end
		Logger.warn(LOG, "The library window sent an unknown action '%s'.", action)
	end

	return host
end

return M
