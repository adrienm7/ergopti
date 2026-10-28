--- modules/llm/context.lua

--- ==============================================================================
--- MODULE: AI Typing Context (Linux)
--- DESCRIPTION:
--- The text the prediction engine completes, kept apart from the hotstring
--- engine's word buffer as macOS keeps `llm_buffer` apart from `buffer`. The
--- hotstring engine reports each edit it applies (typed text, Backspace, an
--- expansion, a reset, a navigation) to this observer, which mirrors the edits
--- into the shared rolling window (_shared/lua/llm/context_buffer.lua).
---
--- FEATURES & RATIONALE:
--- 1. Independent lifetime: the hotstring buffer forgets a word on a pause,
---    an arrow, a click or a shortcut so that no trigger fires against text the
---    caret left. The AI context survives all of those, and is cleared by a
---    navigation or Escape only while `llm.generation.reset_on_nav` is on (the
---    same leaf and default as the other two drivers).
--- 2. The text actually in the field: an expansion replaces its trigger with
---    what was produced, a cascade with its net edit, and a prediction that
---    was accepted with the accepted words, as macOS does. A private
---    expansion forgets the context instead, because its text is a secret
---    that must never reach a model prompt.
--- 3. Unknown edits forget: a focus change, a pause, an uncommitted output, a
---    paste, an undo, a word deletion or a lost key leave a context that no
---    longer describes the field, so every reset the engine reports without
---    saying it was a navigation clears it.
--- 4. Off means off: while the AI is disabled nothing is retained, so text
---    typed meanwhile never waits in memory for the day it is switched on.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ContextBuffer = require("llm.context_buffer")
local Settings = require("modules.llm.settings")
local ConfigKeys = require("config_keys")

local LOG = "modules.llm.context"
local RESET_ON_NAV = ConfigKeys.LEAF.RESET_ON_NAV

--- Creates the typing context of one hotstring engine.
--- @param ports table { is_active = function() -> boolean }: whether the AI is on.
--- @return table context Observer for the engine plus text(), replace_tail(), clear().
function M.new(ports)
	if type(ports) ~= "table" or type(ports.is_active) ~= "function" then
		error("llm context needs an is_active port", 2)
	end
	local buffer = ContextBuffer.new()
	local context = {}

	--- Whether the AI is on; forgets everything while it is not.
	--- @return boolean
	local function active()
		if ports.is_active() == true then return true end
		if buffer:length() > 0 then
			buffer:clear()
			Logger.debug(LOG, "AI off — typing context forgotten.")
		end
		return false
	end

	--- The text a prediction completes; empty while the AI is off.
	--- @return string
	function context:text()
		if not active() then return "" end
		return buffer:text()
	end

	--- Text typed through the hotstring engine.
	--- @param text string
	function context:typed(text)
		if active() then buffer:append(text) end
	end

	--- A Backspace the hotstring engine mirrored.
	function context:backspaced()
		if active() then buffer:backspace() end
	end

	--- Text that replaced the tail of the field: an expansion or an accepted
	--- prediction.
	--- @param deletes integer Codepoints erased from the field.
	--- @param text string What the application received instead.
	--- @param is_private boolean|nil True when the text is a secret.
	function context:replaced(deletes, text, is_private)
		if not active() then return end
		if is_private == true then
			buffer:clear()
			Logger.debug(LOG, "Private expansion — typing context forgotten.")
			return
		end
		buffer:replace_tail(deletes, text)
	end

	--- The field changed in a way nothing describes (focus, pause, failed output,
	--- paste, undo): the context is forgotten.
	function context:reset()
		buffer:clear()
	end

	--- An arrow, Enter, Escape, a click or a shortcut moved the caret.
	function context:navigated()
		if not active() then return end
		local reset_on_nav = Settings.get(RESET_ON_NAV)
		if buffer:navigated(reset_on_nav) then Logger.debug(LOG, "AI typing context cleared on navigation.") end
	end

	return context
end

return M
