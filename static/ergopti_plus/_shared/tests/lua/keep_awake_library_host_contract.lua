--- _shared/tests/lua/keep_awake_library_host_contract.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Library Window Host Contract
--- DESCRIPTION:
--- Drives _shared/shortcuts/engine/keep_awake/library_host.lua with the real
--- library store over an in-memory file system: the first data names every
--- page string, an edit the store refuses or the page may not ask for changes
--- nothing, « Ajouter un bouton… » keeps a PNG under a fresh id, and a preset
--- exported with its image imports as a new preset. The macOS suite runs it on
--- Lua 5.4 and the Linux suite on LuaJIT.
--- ==============================================================================

local M = {}

local Json = require("core.text.engine.json")
local Library = require("shortcuts.engine.keep_awake.library")
local Host = require("shortcuts.engine.keep_awake.library_host")

local function read_json(shared, relative)
	local handle = assert(io.open(shared(relative), "rb"))
	local text = handle:read("*a")
	handle:close()
	return assert(Json.decode(text))
end

local PNG = "\137PNG\r\n\26\n" .. "fake image body"

--- A host over an in-memory configuration folder.
--- @param shared function Resolves a path under _shared/.
--- @return table world { host, files, pushes, last(fn_name), next_pick }
local function world(shared)
	local files, pushes = {}, {}
	local w = { files = files, pushes = pushes, next_pick = nil, saved_to = nil }
	local function read_shared(relative)
		local handle = assert(io.open(shared(relative), "rb"))
		local text = handle:read("*a")
		handle:close()
		return assert(Json.decode(text))
	end
	local library = Library.new({
		os_name = "linux", separator = "/", read_shared = read_shared,
		config_dir = function() return "/cfg" end,
		exists = function(path) return files[path] ~= nil end,
		read = function(path) return files[path] end,
		ensure_dirs = function() return true end,
		write_atomic = function(path, text) files[path] = text; return true end,
		encode = Json.encode, decode = Json.decode,
		text = function(key) return key end,
		log = function() end,
		unavailable_reason = function() return nil end,
		problems = function() return {} end,
		clicks = function() return 0 end,
	})
	w.library = library
	w.host = Host.new({
		library = library, os_name = "linux", separator = "/",
		push = function(name, payload) pushes[#pushes + 1] = { name = name, payload = payload } end,
		translate = function(key) return "<" .. key .. ">" end,
		capture_region = function(callback) callback(w.next_pick, w.next_pick and nil or "cancelled") end,
		convert_image = function(callback) callback(w.next_pick, w.next_pick and nil or "import_failed") end,
		save_path = function(name) w.saved_to = "/out/" .. name; return w.saved_to end,
		open_path = function() return w.saved_to end,
		read_file = function(path) return files[path] end,
		write_file = function(path, bytes) files[path] = bytes; return true end,
		remove_file = function(path) files[path] = nil end,
		close = function() w.closed = true end,
	})
	function w.last(name)
		for index = #pushes, 1, -1 do
			if pushes[index].name == name then return pushes[index].payload end
		end
		return nil
	end
	return w
end

--- Registers the contract.
--- @param helpers table The suite's test helpers.
--- @param shared function Resolves a path under _shared/.
function M.register(helpers, shared)
	helpers.describe("anti-sleep library window host", function()
		helpers.it("library window: the first data names every page string and the document", function()
			local w = world(shared)
			w.host.on_message({ action = "ready" })
			local init = w.last("initData")
			helpers.assert_not_nil(init, "initData is pushed")
			for _, key in ipairs(Host.string_keys(read_json(shared, "shortcuts/data/keep_awake_library.json"),
				read_json(shared, "shortcuts/data/keep_awake_presets.json"))) do
				helpers.assert_eq(init.strings[key], "<" .. key .. ">", key .. " is translated")
			end
			helpers.assert_eq(init.doc.active, "simple", "the starters are the first document")
			helpers.assert_eq(init.os, "linux", "the page knows which apps list to edit")
		end)

		helpers.it("library window: only the store's own edits are accepted", function()
			local w = world(shared)
			w.host.on_message({ action = "edit", op = "set_active", args = { "vscode" } })
			helpers.assert_eq(w.last("onDoc").ok, true, "a valid edit is saved")
			helpers.assert_eq(w.last("onDoc").doc.active, "vscode", "and shown")
			w.host.on_message({ action = "edit", op = "set_active", args = { "nope" } })
			helpers.assert_eq(w.last("onDoc").reason, "preset_unknown", "the store's refusal reaches the page")
			w.host.on_message({ action = "edit", op = "load", args = { {} } })
			helpers.assert_eq(w.last("onDoc").reason, "invalid_request", "an op outside the edits is refused")
			helpers.assert_eq(w.library.document().active, "vscode", "a refusal changes nothing")
		end)

		helpers.it("library window: a drawn button is kept under a fresh id", function()
			local w = world(shared)
			w.files["/tmp/a.png"] = PNG
			w.next_pick = "/tmp/a.png"
			w.host.on_message({ action = "add_image", preset = "simple", source = "capture" })
			helpers.assert_eq(w.last("onImage").id, "button", "the first capture is « button »")
			helpers.assert_eq(w.files["/cfg/auto_click/images/button.png"], PNG, "the PNG is in the library")
			helpers.assert_nil(w.files["/tmp/a.png"], "the temporary capture is removed")
			w.files["/tmp/a.png"] = PNG
			w.host.on_message({ action = "add_image", preset = "simple", source = "capture" })
			helpers.assert_eq(w.last("onImage").id, "button_2", "a second capture gets its own id")
			local images = w.library.document().presets[1].images
			helpers.assert_eq(#images, 2, "both are targets of the preset")
			helpers.assert_true(w.last("onDoc").thumbnails["button.png"] ~= nil, "the page gets the thumbnails")
			w.next_pick = nil
			w.host.on_message({ action = "add_image", preset = "simple", source = "capture" })
			helpers.assert_eq(w.last("onImage").reason, "cancelled", "Escape adds nothing")
			w.files["/tmp/b.png"] = "GIF89a"
			w.next_pick = "/tmp/b.png"
			w.host.on_message({ action = "add_image", preset = "simple", source = "import" })
			helpers.assert_eq(w.last("onImage").reason, "import_failed", "a file that is not a PNG is refused")
		end)

		helpers.it("library window: an exported preset imports as a new one with its image", function()
			local w = world(shared)
			w.files["/tmp/a.png"] = PNG
			w.next_pick = "/tmp/a.png"
			w.host.on_message({ action = "add_image", preset = "vscode", source = "capture" })
			w.host.on_message({ action = "export", preset = "vscode" })
			helpers.assert_eq(w.last("onExported").ok, true, "the export is written")
			helpers.assert_eq(w.saved_to, "/out/vscode.json", "under the preset's id")
			w.host.on_message({ action = "import" })
			local imported = w.last("onImported")
			helpers.assert_eq(imported.ok, true, "the file imports")
			helpers.assert_eq(imported.id, "vscode_2", "a taken id gets a fresh one")
			local preset = w.library.document().presets[4]
			helpers.assert_eq(preset.id, "vscode_2", "the preset is added")
			helpers.assert_eq(w.files["/cfg/auto_click/images/" .. preset.images[1].file], PNG,
				"its image is copied into the library")
			w.files["/out/vscode.json"] = "{}"
			w.host.on_message({ action = "import" })
			helpers.assert_eq(w.last("onImported").reason, "presets_document_invalid", "another file is refused")
		end)
	end)
end

return M
