--- _shared/shortcuts/engine/keep_awake_library.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Library — Shared Lua Implementation
--- DESCRIPTION:
--- Owns the user's anti-sleep presets document for one Lua driver: where it
--- lives (auto_click/ in the configuration folder), reading it once, applying
--- an edit of the shared store and writing it after, the plan of the active
--- preset for the driver's OS, and the menu's row data. The macOS and Linux
--- drivers create one with their file and i18n ports.
---
--- FEATURES & RATIONALE:
--- 1. Persisted, never rebuilt: the document is read once and written
---    atomically after each accepted edit, so a crash never leaves half a
---    library and a Ctrl+M never resets it.
--- 2. A broken saved document is reported and left untouched on disk; the
---    starters run meanwhile, so a typo in a hand-edited file loses nothing.
--- 3. Every saved edit notifies the listeners (the menu redraws its rows).
--- ==============================================================================

local M = {}

local Presets = require("shortcuts.engine.keep_awake_presets")
local Rows = require("shortcuts.engine.keep_awake_menu")

--- Creates the library of one driver.
--- @param ports table {
---   os_name = "macos"|"linux", separator = "/",
---   read_shared(relative) -> table, config_dir() -> string,
---   exists(path) -> boolean, read(path) -> string|nil,
---   ensure_dirs(folder, images) -> boolean, write_atomic(path, text) -> boolean (no reader ever sees half),
---   encode(table) -> string, decode(string) -> table|nil, text(key) -> string,
---   log(level, message, ...), unavailable_reason() -> string|nil,
---   problems() -> { reason… }, clicks() -> integer }
--- @return table library
function M.new(ports)
	for _, name in ipairs({ "read_shared", "config_dir", "exists", "read", "ensure_dirs", "write_atomic",
		"encode", "decode", "text", "log", "unavailable_reason", "problems", "clicks" }) do
		assert(type(ports[name]) == "function", "the anti-sleep library needs the port " .. name)
	end
	local library = {}
	local doc, listeners = nil, {}

	--- The library folder, its image folder and its document.
	function library.paths()
		local defaults = ports.read_shared("shortcuts/data/auto_click_defaults.json")
		local folder = ports.config_dir() .. ports.separator .. defaults.library_folder
		return folder, folder .. ports.separator .. "images", folder .. ports.separator .. defaults.library_index
	end

	--- The presets document, read once.
	function library.document()
		if doc then return doc end
		local starters = ports.read_shared("shortcuts/data/keep_awake_presets.json")
		local _, _, index = library.paths()
		local saved = nil
		if ports.exists(index) then
			local raw = ports.read(index)
			saved = type(raw) == "string" and ports.decode(raw) or false
		end
		local loaded, reason = Presets.load(starters, saved or nil)
		if saved == false or not loaded then
			ports.log("error", "The presets document is invalid (%s); the starter presets run until it is fixed.",
				tostring(reason or "presets_document_invalid"))
			loaded = assert(Presets.load(starters, nil))
		end
		doc = loaded
		return doc
	end

	--- Applies one edit of the shared store and writes the document after it.
	--- @param op string The store function (set_active, set_switch, duplicate…).
	--- @return boolean ok, string|nil reason
	function library.edit(op, ...)
		assert(type(Presets[op]) == "function", "unknown preset edit " .. tostring(op))
		local current = library.document()
		local ok, reason = Presets[op](current, ...)
		if not ok then
			ports.log("warn", "Preset edit %s refused: reason=%s.", op, tostring(reason))
			return false, reason
		end
		local folder, images, index = library.paths()
		if not ports.ensure_dirs(folder, images) or not ports.write_atomic(index, ports.encode(current)) then
			ports.log("error", "The presets document could not be written.")
			return false, "presets_write_failed"
		end
		ports.log("info", "Preset edit %s saved.", op)
		library.changed()
		return true
	end

	--- Subscribes to every change of the library or of its counters.
	function library.on_change(fn)
		listeners[#listeners + 1] = fn
	end

	--- Tells every listener that the rows changed.
	function library.changed()
		for _, fn in ipairs(listeners) do
			local ok, err = pcall(fn)
			if not ok then ports.log("warn", "An anti-sleep listener raised: %s.", tostring(err)) end
		end
	end

	--- What the active preset runs on this OS.
	function library.active_plan()
		local _, images = library.paths()
		return Presets.plan(Presets.active(library.document()), ports.os_name, images, ports.separator,
			ports.read_shared("shortcuts/data/auto_click_defaults.json"))
	end

	--- The rows of the menu's presets list.
	function library.preset_rows()
		return Rows.preset_rows(library.document(), {
			text = ports.text, select = function(id) library.edit("set_active", id) end })
	end

	--- The rows of the menu's options list.
	function library.option_rows()
		local current = library.document()
		return Rows.option_rows(Presets.active(current), {
			text = ports.text,
			switch = function(name, value) library.edit("set_switch", current.active, name, value) end,
			auto_click_reason = ports.unavailable_reason(),
			problems = ports.problems(),
			clicks = ports.clicks(),
		})
	end

	--- Forgets the cached document and listeners (tests).
	function library.reset()
		doc, listeners = nil, {}
	end

	return library
end

return M
