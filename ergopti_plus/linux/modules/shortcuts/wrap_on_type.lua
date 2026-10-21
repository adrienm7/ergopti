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
--- 1. No native probe unless a selection can exist. The optional context
---    revision is checked in memory; only a pointer press, a Shift+navigation key or
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
	if opts.context_epoch ~= nil and type(opts.context_epoch) ~= "function" then
		error("wrap-on-type context_epoch must be a function")
	end
end

--- Builds the wrap-on-type decision for the running daemon.
--- @param opts table {
---   is_active    fn() -> boolean  feature on, shortcuts on, script not paused.
---   get_pair     fn(char) -> { left, right }|nil  the shared wrap-pair lookup.
---   read_primary fn() -> ok, text  the PRIMARY selection.
---   type_text    fn(text, owner) -> boolean  types over the retained selection;
---     owner.current() checks activity and ownership, owner.cached() only RAM.
---   context_epoch fn() -> integer|nil  optional pure-memory ownership revision;
---     a missing or invalid result refuses selection reads and replacement. }
--- @return table controller { on_key, on_pointer_down, end_selection_window,
---   selection_window_open }
function M.new(opts)
	check_opts(opts)

	-- nil while no selection can exist; otherwise the PRIMARY content read when
	-- the window opened ("" when nothing, or nothing readable, was published).
	local baseline, baseline_epoch = nil, nil
	local context_epoch = opts.context_epoch
	-- Native reads and policy callbacks may reenter a selection event. Only its
	-- current generation may publish a baseline or authorize replacement text.
	local generation = 0

	local function valid_epoch(epoch)
		return type(epoch) == "number" and epoch >= 0 and epoch % 1 == 0
	end

	-- The context getter may itself reenter an input event. Check the local
	-- owner again after it returns, before authorizing any later side effect.
	local function current(owner, epoch)
		if owner ~= generation then return false end
		if not context_epoch then return true end
		if not valid_epoch(epoch) then return false end
		local actual = context_epoch()
		return owner == generation and actual == epoch
	end

	--- Opens the selection window, remembering what PRIMARY held before it.
	local function open_window(owner, epoch)
		local ok, text = opts.read_primary()
		if not current(owner, epoch) then return end
		local active = opts.is_active()
		if not current(owner, epoch) or not active then return end
		baseline = (ok and type(text) == "string") and text or ""
		baseline_epoch = epoch
	end

	local controller = {}

	--- Whether a selection can currently exist (test and diagnostics seam).
	--- @return boolean
	function controller.selection_window_open()
		return baseline ~= nil
	end

	--- A key typed by an earlier consumer of the hook (the physical magic key)
	--- replaced any selection, as a key reaching on_key would: the window ends,
	--- or a later wrap symbol would type the deleted text back from PRIMARY.
	function controller.end_selection_window()
		generation = generation + 1
		baseline, baseline_epoch = nil, nil
	end

	--- A pointer button went down: it may start a drag or a multi-click
	--- selection, or clear one. The baseline is taken on EVERY press, so a
	--- deselecting click makes the old selection the baseline.
	function controller.on_pointer_down()
		generation = generation + 1
		local owner = generation
		baseline, baseline_epoch = nil, nil
		local epoch = context_epoch and context_epoch()
		if owner ~= generation or (context_epoch and not valid_epoch(epoch)) then return end
		local active = opts.is_active()
		if not current(owner, epoch) or not active then return end
		open_window(owner, epoch)
	end

	--- Decides one key press from the keyboard hook's consumption callback.
	--- @param detail table { char, code, mods } as the hook reports it.
	--- @return boolean consumed True when the selection was wrapped and the key
	---   must not reach the application.
	function controller.on_key(detail)
		if type(detail) ~= "table" then return false end
		generation = generation + 1
		local owner = generation
		local epoch = context_epoch and context_epoch()
		if owner ~= generation then return false end
		if context_epoch and not valid_epoch(epoch) then
			baseline, baseline_epoch = nil, nil
			return false
		end
		if baseline_epoch ~= epoch then baseline, baseline_epoch = nil, nil end
		local mods = type(detail.mods) == "table" and detail.mods or {}
		local control = EvdevCodes.CONTROL_NAME_OF[detail.code]

		-- The keys that make or extend a selection keep the window open.
		if control and NAVIGATION[control] and mods.shift and not mods.alt and not mods.meta then
			if baseline == nil then
				local active = opts.is_active()
				if current(owner, epoch) and active then open_window(owner, epoch) end
			end
			return false
		end
		local char = type(detail.char) == "string" and detail.char or ""
		if mods.ctrl and not mods.alt and not mods.meta and char:lower() == "a" then
			baseline, baseline_epoch = nil, nil
			local active = opts.is_active()
			if current(owner, epoch) and active then open_window(owner, epoch) end
			return false
		end

		local window = baseline
		-- Every other key ends the window: typing replaces a selection, plain
		-- navigation and Escape clear it.
		baseline, baseline_epoch = nil, nil
		if window == nil then return false end
		if mods.ctrl or mods.alt or mods.meta then return false end
		local pair = opts.get_pair(char)
		if not current(owner, epoch) or type(pair) ~= "table" then return false end
		local left, right = pair.left, pair.right
		local active = opts.is_active()
		if not current(owner, epoch) or not active then return false end

		local ok, selected = opts.read_primary()
		if not current(owner, epoch) or not ok or type(selected) ~= "string" or selected == "" then return false end
		if selected == window then
			Logger.debug(LOG, "PRIMARY unchanged since the selection window opened — typing '%s'.", char)
			return false
		end

		Logger.debug(LOG, "Wrapping a %d-byte selection in %s…%s.", #selected, left, right)
		active = opts.is_active()
		if not current(owner, epoch) or not active then return false end
		local publication = {
			current = function()
				if not current(owner, epoch) then return false end
				local enabled = opts.is_active()
				return current(owner, epoch) and enabled == true
			end,
			-- The context epoch is explicitly a pure-memory revision. Never run
			-- native focus or PRIMARY reads for individual key-down admissions.
			cached = function() return current(owner, epoch) end,
		}
		local typed_ok, typed = pcall(opts.type_text, left .. selected .. right, publication)
		if not typed_ok then
			Logger.error(LOG, "Selection wrap raised before typing: %s — the symbol is typed instead.",
				tostring(typed))
			return false
		end
		if typed ~= true then
			Logger.warn(LOG, "Selection wrap was refused — the symbol is typed instead.")
			return false
		end
		return true
	end

	return controller
end

return M
