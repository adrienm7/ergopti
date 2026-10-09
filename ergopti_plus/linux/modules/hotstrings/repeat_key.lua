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
local Manifest = require("infra.manifest_reader")
local Paths = require("infra.config_paths")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Preferences = require("infra.hotstring_preferences")
local ConfigOutdated = require("config_outdated")

local LOG = "hotstrings.repeat_key"

local FEATURE_PATH = "hotstrings.repeat_key_enabled"
local _enabled = nil -- populated once; no preference IO on each keystroke

-- One UTF-8 codepoint, as a byte pattern. LuaJIT is 5.1-based and has no `utf8`
-- library, so the buffer is walked with the same pattern the rest of this driver
-- uses rather than with utf8.offset.
local UTF8_CODEPOINT = "[%z\1-\127\194-\244][\128-\191]*"




-- =========================================
-- =========================================
-- ======= 1/ The setting ==================
-- =========================================
-- =========================================

--- Resolves exactly the leaf consumed by this runtime owner. A value another
--- build or a hand edit left in another shape is an outdated entry: warned
--- once, read as the neutral default and left unmarked for the cleanup.
--- @param document table Decoded canonical configuration.
--- @param mark function|nil Cleanup ownership visitor.
--- @return boolean enabled
local function resolve_setting(document, mark)
	local section = ConfigOutdated.settings_table(document.hotstrings, { "hotstrings" }, Logger)
	local value = section and section.repeat_key_enabled
	if value ~= nil and type(value) ~= "boolean" then
		ConfigOutdated.report(FEATURE_PATH, "the value is not a boolean", Logger)
		value = nil
	end
	if value == nil then value = Manifest.default_for(FEATURE_PATH)
	elseif mark then mark("hotstrings", "repeat_key_enabled") end
	assert(type(value) == "boolean", "the manifest default of repeat_key_enabled must be a boolean")
	return value
end

--- Captures one validated source for a conditional sparse write.
--- @return boolean enabled
--- @return table source
local function read_setting()
	local content, status, detail = Writer.read_classified(Paths.config("config.toml"))
	assert(status == "ok" or status == "absent", "repeat configuration is unreadable: " .. tostring(detail))
	local decoded = Codec.decode(content or "")
	assert(type(decoded) == "table", "repeat configuration is malformed")
	return resolve_setting(decoded), { status = status, content = content }
end

--- Marks the same canonical value used by initialization and setters.
--- @param document table Decoded configuration.
--- @param mark function Exact ownership visitor.
function M.mark_config_reads(document, mark)
	resolve_setting(document, mark)
end

--- Reloads the runtime value only after its canonical source is validated.
--- A terminal scope must call this owner when publishing an external candidate.
--- @return boolean acknowledged
function M.refresh()
	local called, value = pcall(read_setting)
	if not called then
		Logger.error(LOG, "Repeat configuration refresh refused: %s.", tostring(value))
		return false
	end
	_enabled = value
	return true
end

--- Makes a scope's validated candidate effective before its file is published.
--- @param document table Decoded configuration candidate.
--- @return boolean adopted
function M.adopt_configuration(document)
	local called, value = pcall(resolve_setting, document)
	if not called then
		Logger.error(LOG, "Candidate repeat configuration refused: %s.", tostring(value))
		return false
	end
	_enabled = value
	return true
end

--- Restores the exact runtime value a scope captured before a refused publication.
--- @param enabled boolean Captured value.
--- @return boolean restored
function M.restore_configuration(enabled)
	if type(enabled) ~= "boolean" then return false end
	_enabled = enabled
	return true
end

--- Whether repeat is active, with no repeated disk IO on the input path.
---
--- Called for every unmatched character, inside the keyboard hook's guarded
--- callback: a raise here emergency-stops the whole hook. A configuration that
--- cannot be read therefore leaves repeat on its neutral default until an
--- explicit refresh succeeds, and that fallback is cached so the typing path
--- never retries the disk on each keystroke.
--- @return boolean enabled
function M.is_enabled()
	if _enabled == nil and not M.refresh() then
		Logger.error(LOG, "Repeat configuration is unreadable; repeat stays neutral until a refresh succeeds.")
		_enabled = Manifest.default_for(FEATURE_PATH)
	end
	return _enabled
end

--- Publishes a sparse canonical preference before changing runtime state.
--- @param enabled boolean Desired state.
--- @return boolean committed
function M.set_enabled(enabled)
	if type(enabled) ~= "boolean" then return false end
	-- The hotstrings scope owns this leaf while it holds the preferences.
	if Preferences.is_acquired() then
		Logger.error(LOG, "Repeat configuration refused: a hotstring configuration scope is still pending.")
		return false
	end
	local called, committed, detail = pcall(function()
		local _, source = read_setting()
		return Writer.batch_write(Paths.config("config.toml"),
			{ Manifest.sparse_operation(FEATURE_PATH, enabled) }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Repeat configuration was not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	_enabled = enabled
	Logger.debug(LOG, "Magic-key repeat: %s.", enabled and "on" or "off")
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
