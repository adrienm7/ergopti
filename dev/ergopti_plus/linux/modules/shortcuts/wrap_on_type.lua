--- modules/shortcuts/wrap_on_type.lua

--- ==============================================================================
--- MODULE: Wrap The Selection When A Wrap Symbol Is Typed (Linux)
--- DESCRIPTION:
--- With text selected, typing an opening or closing symbol of a wrap pair
--- (`(` `[` `{` `«` `"`…) replaces the selection with left + selection + right
--- instead of the symbol. With nothing selected the symbol types normally. The
--- Windows driver does this with a hotkey per symbol, macOS from its event tap;
--- this driver decides in the keyboard hook's consumption callback, which runs
--- before a grabbed key is given back to the application.
---
--- FEATURES & RATIONALE:
--- 1. Nothing on the typing path. A symbol key costs two table lookups unless a
---    selection can exist: only a pointer press, a Shift+navigation key or
---    Ctrl+A can create one, and any other key ends it. The selection is read
---    only in that window, and only for a wrap symbol.
--- 2. PRIMARY, never Ctrl+C. The application publishes the selection itself,
---    so the probe sends no key to it; a Ctrl+C probe interrupts the program
---    running in a terminal. The clipboard is never touched.
--- 3. A stale PRIMARY is not a selection. Applications keep publishing the
---    last selection after it has been cleared by a click, so PRIMARY is read
---    when the selection window opens and a wrap needs it to have CHANGED since
---    — a deselecting click leaves it equal and the symbol types normally.
---    Re-selecting the very same text is therefore not wrapped: a missed wrap
---    types the symbol, a wrong one would type text that is no longer selected.
--- 4. Fail safe. Any failure — no reader, an unreadable PRIMARY, an injection
---    that could not start — lets the key through, so it is typed exactly once.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local EvdevCodes = require("infra.evdev_codes")

local LOG = "modules.shortcuts.wrap_on_type"

-- The keys that extend a selection when Shift is held.
local NAVIGATION = {
	up = true, down = true, left = true, right = true,
	home = true, ["end"] = true, pageup = true, pagedown = true,
}

--- Validates the injected dependencies.
--- @param opts table
local function check_opts(opts)
	if type(opts) ~= "table" then error("wrap-on-type options must be a table") end
	for _, name in ipairs({ "is_active", "get_pair", "read_primary", "type_text" }) do
		if type(opts[name]) ~= "function" then
			error("wrap-on-type requires a " .. name .. " function")
		end
	end
end

--- Builds the wrap-on-type decision for the running daemon.
--- @param opts table {
---   is_active    fn() -> boolean  feature on, shortcuts on, script not paused.
---   get_pair     fn(char) -> { left, right }|nil  the shared wrap-pair lookup.
---   read_primary fn() -> ok, text  the PRIMARY selection.
---   type_text    fn(text) -> boolean  types over the live selection. }
--- @return table controller { on_key, on_pointer_down, selection_window_open }
function M.new(opts)
	check_opts(opts)

	-- nil while no selection can exist; otherwise the PRIMARY content read when
	-- the window opened ("" when nothing, or nothing readable, was published).
	local baseline = nil

	--- Opens the selection window, remembering what PRIMARY held before it.
	local function open_window()
		local ok, text = opts.read_primary()
		baseline = (ok and type(text) == "string") and text or ""
	end

	local controller = {}

	--- Whether a selection can currently exist (test and diagnostics seam).
	--- @return boolean
	function controller.selection_window_open()
		return baseline ~= nil
	end

	--- A pointer button went down: it may start a drag or a multi-click
	--- selection, or clear one. The baseline is taken on EVERY press, so a
	--- deselecting click makes the old selection the baseline.
	function controller.on_pointer_down()
		if not opts.is_active() then baseline = nil return end
		open_window()
	end

	--- Decides one key press from the keyboard hook's consumption callback.
	--- @param detail table { char, code, mods } as the hook reports it.
	--- @return boolean consumed True when the selection was wrapped and the key
	---   must not reach the application.
	function controller.on_key(detail)
		if type(detail) ~= "table" then return false end
		local mods = type(detail.mods) == "table" and detail.mods or {}
		local control = EvdevCodes.CONTROL_NAME_OF[detail.code]

		-- The keys that make or extend a selection keep the window open.
		if control and NAVIGATION[control] and mods.shift and not mods.alt and not mods.meta then
			if baseline == nil and opts.is_active() then open_window() end
			return false
		end
		local char = type(detail.char) == "string" and detail.char or ""
		if mods.ctrl and not mods.alt and not mods.meta and char:lower() == "a" then
			if opts.is_active() then open_window() else baseline = nil end
			return false
		end

		local window = baseline
		-- Every other key ends the window: typing replaces a selection, plain
		-- navigation and Escape clear it.
		baseline = nil
		if window == nil then return false end
		if mods.ctrl or mods.alt or mods.meta then return false end
		local pair = opts.get_pair(char)
		if type(pair) ~= "table" then return false end
		if not opts.is_active() then return false end

		local ok, selected = opts.read_primary()
		if not ok or type(selected) ~= "string" or selected == "" then return false end
		if selected == window then
			Logger.debug(LOG, "PRIMARY unchanged since the selection window opened — typing '%s'.", char)
			return false
		end

		Logger.debug(LOG, "Wrapping a %d-byte selection in %s…%s.", #selected, pair.left, pair.right)
		local typed_ok, typed = pcall(opts.type_text, pair.left .. selected .. pair.right)
		if not typed_ok then
			Logger.error(LOG, "Selection wrap raised before typing: %s — the symbol is typed instead.",
				tostring(typed))
			return false
		end
		if typed ~= true then
			Logger.error(LOG, "Selection wrap was refused — the symbol is typed instead.")
			return false
		end
		return true
	end

	return controller
end

return M
