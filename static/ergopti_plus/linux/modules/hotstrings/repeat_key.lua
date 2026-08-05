--- modules/hotstrings/repeat_key.lua

--- ==============================================================================
--- MODULE: Magic-Key Repeat
--- DESCRIPTION:
--- Doubles the character before the magic key when nothing else matched: typing
--- `po★` gives `poo`, `a★` gives `aa`.
---
--- WHY IT IS HERE AND NOT ONLY ON THE OTHER TWO DRIVERS:
--- The manifest declared `hotstrings.repeat_key_enabled` and the `repeat_key`
--- menu row as `platforms = ["ahk"]`, and that was already wrong when it was
--- written: macOS ships both the engine (`modules/keymap/expander.lua`
--- try_repeat_feature) and the toggle. The restriction recorded who implemented
--- it first, not what the platforms can do — the same mistake already found and
--- corrected for `hotstring_extensions` and `magic_key_config`.
---
--- Nothing here touches an OS API. It is "if the character just typed is the
--- magic key, and nothing matched, replace it with the one before it", which is
--- as portable as the buffer it reads.
---
--- WHY IT RUNS ONLY WHEN NOTHING MATCHED:
--- The magic key is the trigger for the whole star catalogue. A real match must
--- always win; this is the fallback for the case where the user typed the key
--- after something the catalogue has no entry for, which is what makes it feel
--- like a repeat rather than a failed expansion.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Storage = require("adapters.storage")

local LOG = "hotstrings.repeat_key"

-- Where the user's choice lives. The manifest path doubles as the storage key,
-- as it does for the preview toggles: they name the same setting.
local STORAGE_KEY = "hotstrings.repeat_key_enabled"

-- Opt-out, not opt-in: both other drivers default it on, and a user who has
-- never touched the setting must get the same behaviour on all three.
local DEFAULT_ENABLED = true

-- One UTF-8 codepoint, as a byte pattern. LuaJIT is 5.1-based and has no `utf8`
-- library, so the buffer is walked with the same pattern the rest of this driver
-- uses rather than with utf8.offset.
local UTF8_CODEPOINT = "[%z\1-\127\194-\244][\128-\191]*"




-- =========================================
-- =========================================
-- ======= 1/ The setting ==================
-- =========================================
-- =========================================

--- Whether the repeat is active.
--- @return boolean
function M.is_enabled()
	local stored = Storage.get(STORAGE_KEY, nil)
	if type(stored) == "boolean" then return stored end
	return DEFAULT_ENABLED
end

--- Turns the repeat on or off, persisting the choice.
--- @param enabled boolean
--- @return boolean True when the choice was stored.
function M.set_enabled(enabled)
	local wanted = enabled and true or false
	if not Storage.set(STORAGE_KEY, wanted) then
		Logger.error(LOG, "Could not persist the repeat setting — it would be lost at restart.")
		return false
	end
	Logger.debug(LOG, "Magic-key repeat: %s.", wanted and "on" or "off")
	return true
end

--- Flips it.
--- @return boolean
function M.toggle()
	return M.set_enabled(not M.is_enabled())
end




-- =========================================
-- =========================================
-- ======= 2/ The rule =====================
-- =========================================
-- =========================================

--- The last codepoint of a string, or nil when there is none.
--- @param text string
--- @return string|nil
local function last_codepoint(text)
	local last = nil
	for char in text:gmatch(UTF8_CODEPOINT) do last = char end
	return last
end

--- Decides what a magic key typed after `buffer` should produce.
---
--- Pure, and separate from the daemon that calls it, so the rule can be asserted
--- without a keyboard, a display or an injector.
---
--- @param buffer string The typed buffer INCLUDING the magic key just typed.
--- @param magic_key string The character in effect.
--- @return table|nil { backspace_count, replacement } or nil when it must not fire.
function M.resolve(buffer, magic_key)
	if type(buffer) ~= "string" or type(magic_key) ~= "string" or magic_key == "" then
		return nil
	end

	-- The buffer must END with the magic key: this fires on the keystroke that
	-- typed it, and a magic key anywhere else is history the user has moved past.
	if buffer:sub(-#magic_key) ~= magic_key then return nil end

	local before = buffer:sub(1, #buffer - #magic_key)
	local previous = last_codepoint(before)
	if not previous then return nil end

	-- The magic key repeating itself is not a repeat, it is a second trigger, and
	-- doubling it would let a user type an unbounded run of them by holding one key.
	if previous == magic_key then return nil end

	return {
		-- Erase the magic key only; the character before it stays and is joined by
		-- its copy. Erasing both and retyping them would move the caret twice for
		-- no visible reason and widen the window the grab exists to close.
		backspace_count = 1,
		replacement     = previous,
	}
end

return M
