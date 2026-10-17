--- modules/hotstrings/word_reset.lua

--- ==============================================================================
--- MODULE: Word Reset Settings
--- DESCRIPTION:
--- Owns the two config.toml leaves that decide when the hotstring buffer is
--- forgotten and the next key starts a new word: `hotstrings.idle_reset_seconds`
--- (a pause without typing, 0 = never) and `hotstrings.click_resets_word` (a
--- pointer click starts a word, rather than an unknown position).
---
--- FEATURES & RATIONALE:
--- 1. Before them the buffer kept the last word for as long as the user stayed
---    away, and a click did not touch it at all: the first key typed after a
---    pause or a click was read as the continuation of text elsewhere, so every
---    word-start hotstring stayed silent until a delimiter.
--- 2. The values are cached: the input path reads them on every keystroke and
---    never touches the disk. The pause rule itself is the shared engine's
---    `idle_resets_word`, which the other two drivers apply too.
--- 3. Setters publish a sparse canonical write before changing runtime state,
---    and the Hotstrings scope adopts and restores both leaves with the others.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Manifest = require("infra.manifest_reader")
local Paths = require("infra.config_paths")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Preferences = require("infra.hotstring_preferences")
local ConfigOutdated = require("config_outdated")
local Engine = require("modules.hotstrings.engine")
local Monotonic = require("infra.monotonic")

local LOG = "hotstrings.word_reset"

local IDLE_PATH = "hotstrings.idle_reset_seconds"
local CLICK_PATH = "hotstrings.click_resets_word"

-- Populated once; no preference IO on each keystroke.
local _settings = nil
-- Monotonic time of the last physical keystroke, nil before the first.
local _last_key_ms = nil




-- =========================================
-- =========================================
-- ======= 1/ The settings =================
-- =========================================
-- =========================================

--- Resolves exactly the two leaves consumed here. A value of another shape is
--- an outdated entry: warned once, read as the manifest default and left
--- unmarked for the cleanup.
--- @param document table Decoded canonical configuration.
--- @param mark function|nil Cleanup ownership visitor.
--- @return table settings `{ idle_seconds, click_resets_word }`.
local function resolve_settings(document, mark)
	local section = ConfigOutdated.settings_table(document.hotstrings, { "hotstrings" }, Logger)
	local idle = section and section.idle_reset_seconds
	if idle ~= nil and not Engine.valid_idle_reset_seconds(idle) then
		ConfigOutdated.report(IDLE_PATH, "the value is not a non-negative number of seconds", Logger)
		idle = nil
	end
	if idle == nil then idle = Manifest.default_for(IDLE_PATH)
	elseif mark then mark("hotstrings", "idle_reset_seconds") end
	assert(Engine.valid_idle_reset_seconds(idle), "the manifest default of idle_reset_seconds must be valid")

	local click = section and section.click_resets_word
	if click ~= nil and type(click) ~= "boolean" then
		ConfigOutdated.report(CLICK_PATH, "the value is not a boolean", Logger)
		click = nil
	end
	if click == nil then click = Manifest.default_for(CLICK_PATH)
	elseif mark then mark("hotstrings", "click_resets_word") end
	assert(type(click) == "boolean", "the manifest default of click_resets_word must be a boolean")
	return { idle_seconds = idle, click_resets_word = click }
end

--- Captures one validated source for a conditional sparse write.
--- @return table settings
--- @return table source
local function read_settings()
	local content, status, detail = Writer.read_classified(Paths.config("config.toml"))
	assert(status == "ok" or status == "absent", "word-reset configuration is unreadable: " .. tostring(detail))
	local decoded = Codec.decode(content or "")
	assert(type(decoded) == "table", "word-reset configuration is malformed")
	return resolve_settings(decoded), { status = status, content = content }
end

--- Marks the same canonical values used by initialization and setters.
--- @param document table Decoded configuration.
--- @param mark function Exact ownership visitor.
function M.mark_config_reads(document, mark)
	resolve_settings(document, mark)
end

--- Reloads the runtime values only after their canonical source is validated.
--- @return boolean acknowledged
function M.refresh()
	local called, value = pcall(read_settings)
	if not called then
		Logger.error(LOG, "Word-reset configuration refresh refused: %s.", tostring(value))
		return false
	end
	_settings = value
	return true
end

--- Makes a scope's validated candidate effective before its file is published.
--- @param document table Decoded configuration candidate.
--- @return boolean adopted
function M.adopt_configuration(document)
	local called, value = pcall(resolve_settings, document)
	if not called then
		Logger.error(LOG, "Candidate word-reset configuration refused: %s.", tostring(value))
		return false
	end
	_settings = value
	return true
end

--- The runtime values, for a scope to restore after a refused publication.
--- @return table snapshot
function M.snapshot()
	local current = M.current()
	return { idle_seconds = current.idle_seconds, click_resets_word = current.click_resets_word }
end

--- Restores the exact runtime values a scope captured.
--- @param snapshot table Value returned by snapshot().
--- @return boolean restored
function M.restore_configuration(snapshot)
	if type(snapshot) ~= "table" or not Engine.valid_idle_reset_seconds(snapshot.idle_seconds)
		or type(snapshot.click_resets_word) ~= "boolean" then
		return false
	end
	_settings = { idle_seconds = snapshot.idle_seconds, click_resets_word = snapshot.click_resets_word }
	return true
end

--- The cached values, read once. A configuration that cannot be read leaves
--- both on their manifest defaults until an explicit refresh succeeds, and the
--- fallback is cached so the input path never retries the disk per keystroke.
--- @return table settings
function M.current()
	if _settings == nil and not M.refresh() then
		Logger.error(LOG, "Word-reset configuration is unreadable; the defaults apply until a refresh succeeds.")
		_settings = { idle_seconds = Manifest.default_for(IDLE_PATH),
			click_resets_word = Manifest.default_for(CLICK_PATH) }
	end
	return _settings
end

--- @return number seconds Pause after which a key starts a new word; 0 = never.
function M.idle_seconds()
	return M.current().idle_seconds
end

--- @return boolean Whether a click starts a new word.
function M.click_resets_word()
	return M.current().click_resets_word
end

--- Publishes one sparse leaf, then the runtime value.
--- @param path string Feature path.
--- @param key string Runtime field.
--- @param value any Validated value.
--- @return boolean committed
local function persist(path, key, value)
	-- The hotstrings scope owns these leaves while it holds the preferences.
	if Preferences.is_acquired() then
		Logger.error(LOG, "Word-reset change refused: a hotstring configuration scope is still pending.")
		return false
	end
	local called, committed, detail = pcall(function()
		local _, source = read_settings()
		return Writer.batch_write(Paths.config("config.toml"),
			{ Manifest.sparse_operation(path, value) }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Word-reset change was not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	local updated = M.snapshot()
	updated[key] = value
	_settings = updated
	Logger.info(LOG, "%s set to %s.", path, tostring(value))
	return true
end

--- Sets the pause after which a key starts a new word.
--- @param seconds number Non-negative seconds; 0 disables the reset.
--- @return boolean committed
function M.set_idle_seconds(seconds)
	if not Engine.valid_idle_reset_seconds(seconds) then
		Logger.warn(LOG, "Invalid idle delay '%s' refused.", tostring(seconds))
		return false
	end
	return persist(IDLE_PATH, "idle_seconds", seconds)
end

--- Sets whether a click starts a new word.
--- @param enabled boolean
--- @return boolean committed
function M.set_click_resets_word(enabled)
	if type(enabled) ~= "boolean" then return false end
	return persist(CLICK_PATH, "click_resets_word", enabled)
end

--- Flips the click setting.
--- @return boolean committed
function M.toggle_click_resets_word()
	return M.set_click_resets_word(not M.click_resets_word())
end

--- Parses a free entry typed in the menu prompt: a decimal point or comma,
--- surrounding blanks ignored.
--- @param text string|nil Raw prompt answer.
--- @return number|nil seconds Valid value, or nil when the text is not one.
function M.parse_seconds(text)
	if type(text) ~= "string" then return nil end
	local trimmed = text:match("^%s*(.-)%s*$"):gsub(",", ".", 1)
	if not trimmed:match("^%d+%.?%d*$") and not trimmed:match("^%.%d+$") then return nil end
	local value = tonumber(trimmed)
	if not Engine.valid_idle_reset_seconds(value) then return nil end
	return value
end




-- =========================================
-- =========================================
-- ======= 2/ The input path ===============
-- =========================================
-- =========================================

--- Stamps one physical keystroke and tells whether the pause before it starts
--- a new word. Called for every key the hotstring path observes, so a pause is
--- measured from the last key of any kind.
--- @param now_ms number Monotonic time of this keystroke.
--- @return boolean idle Whether the caller must reset its buffer at a word start.
function M.observe_key(now_ms)
	local previous = _last_key_ms
	_last_key_ms = now_ms
	return Engine.idle_resets_word(previous, now_ms, M.idle_seconds(), Monotonic.resolution_ms())
end

--- Forgets the last keystroke time (tests and a restarted input session).
function M.forget_last_key()
	_last_key_ms = nil
end

return M
