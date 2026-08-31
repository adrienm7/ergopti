--- modules/llm/settings.lua

--- ==============================================================================
--- MODULE: LLM Generation Settings (Linux)
--- DESCRIPTION:
--- The generation values a user can change, held here so the prediction engine
--- reads durable settings rather than constants.
---
--- WHY THIS EXISTS:
--- The manifest declares these values as features, which means they are
--- settings. Linux originally read their shared defaults without offering a
--- control, so they could not honestly be declared supported.
---
--- FEATURES & RATIONALE:
--- 1. The shipped answer comes from the shared manifest, never from a literal
---    here. A driver that writes its own default is not configurable, it is
---    coincidentally similar.
--- 2. Only a CHANGE is stored. Persisting the default too would freeze today's
---    default for anyone who had already run the driver: a later change to what
---    ships would reach new installs and nobody else.
--- 3. Every value is clamped to the range the manifest declares, and a value
---    outside it is refused rather than clipped silently. A temperature of 12
---    is not a user asking for more creativity, it is a caller with a bug, and
---    clipping it to the maximum hides that for ever.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Manifest = require("infra.manifest_reader")

local LOG = "modules.llm.settings"

-- Where the two choices live. One key each rather than one blob, so a corrupt
-- entry costs one setting instead of both.
local PREF_PREFIX = "llm.generation."

-- What each setting accepts. The bounds are the ones the menu offers and the
-- ones a hand-edited config is judged against — a single source, so the two
-- cannot disagree about what is valid.
--
-- Temperature above 1.3 stops being creativity and becomes noise; the shared
-- inference canon caps its own diversity ladder at exactly that, and a setting
-- that allowed more would let the menu ask for something the backend clamps.
local BOUNDS = {
	temperature = { min = 0.0, max = 1.3 },
	-- Below about eighty characters the model has less than a sentence to work
	-- from and predicts the language rather than the user. The upper bound is
	-- where a local model's prompt handling starts to cost more than the
	-- prediction saves.
	context_length = { min = 80, max = 4000 },
	min_words = { min = 1, max = 20, integer = true },
	max_words = { min = 0, max = 10000, integer = true },
}

-- The manifest paths behind each setting.
local FEATURE_PATH = {
	temperature = "llm.generation.temperature",
	context_length = "llm.generation.context_length",
	min_words = "llm.generation.min_words",
	max_words = "llm.generation.max_words",
	auto_raise_temp = "llm.generation.auto_raise_temp",
}

-- Resolved shipped answers, read once.
local _shipped = nil

-- The live values, nil until first read.
local _values = {}




-- =========================================
-- =========================================
-- ======= 1/ The shipped answers ==========
-- =========================================
-- =========================================

--- The manifest's answer for both settings.
--- @return table
local function shipped()
	if _shipped then return _shipped end
	_shipped = {}
	for name, path in pairs(FEATURE_PATH) do
		local ok, value = pcall(Manifest.default_for, path)
		if ok and (type(value) == "number" or type(value) == "boolean") then
			_shipped[name] = value
		else
			-- Loud, and then unusable: a setting with no shipped answer cannot be
			-- offered, because "reset to default" would have nothing to reset to.
			Logger.error(LOG, "No manifest default for '%s' — that setting is unavailable.", path)
		end
	end
	return _shipped
end

--- Whether a value is inside the range its setting declares.
--- @param name string
--- @param value any
--- @return boolean
local function in_bounds(name, value)
	if name == "auto_raise_temp" then return type(value) == "boolean" end
	local bounds = BOUNDS[name]
	if not bounds or type(value) ~= "number" then return false end
	return value >= bounds.min and value <= bounds.max
		and (bounds.integer ~= true or value == math.floor(value))
end




-- =========================================
-- =========================================
-- ======= 2/ Reading and writing ==========
-- =========================================
-- =========================================

--- The current value of one setting.
--- @param name string "temperature" or "context_length".
--- @return number|nil
function M.get(name)
	if _values[name] ~= nil then return _values[name] end
	local default = shipped()[name]
	if default == nil then return nil end

	local ok, Storage = pcall(require, "adapters.storage")
	if ok and Storage then
		local stored = Storage.get(PREF_PREFIX .. name, nil)
		-- A stored value outside the range is REFUSED, not clipped. It can only
		-- come from a hand-edited config or an older schema, and clipping would
		-- silently apply a setting the user never chose while the menu showed the
		-- clipped one as if they had.
		if in_bounds(name, stored) then
			_values[name] = stored
			return stored
		elseif stored ~= nil then
			Logger.warn(LOG, "Stored '%s' (%s) is outside the accepted range — using the shipped default.",
				name, tostring(stored))
		end
	end
	_values[name] = default
	return default
end

--- Changes one setting.
--- @param name string
--- @param value number
--- @return boolean Whether it was accepted.
function M.set(name, value)
	local default = shipped()[name]
	if default == nil then
		Logger.error(LOG, "set(): '%s' has no shipped default — refusing to store it.", tostring(name))
		return false
	end
	if not in_bounds(name, value) then
		local bounds = BOUNDS[name]
		local expectation = bounds and string.format("%s..%s", bounds.min, bounds.max) or "a boolean"
		Logger.error(LOG, "set(): %s = %s is invalid (expected %s) — refused.",
			name, tostring(value), expectation)
		return false
	end
	if name == "min_words" then
		local maximum = M.get("max_words")
		if maximum and maximum > 0 and value > maximum then
			Logger.error(LOG, "set(): min_words cannot exceed max_words — refused.")
			return false
		end
	elseif name == "max_words" then
		local minimum = M.get("min_words")
		if value > 0 and minimum and value < minimum then
			Logger.error(LOG, "set(): max_words cannot be lower than min_words — refused.")
			return false
		end
	end

	local ok, Storage = pcall(require, "adapters.storage")
	if not ok or not Storage then
		Logger.error(LOG, "No storage — '%s' was not changed.", name)
		return false
	end
	local persisted
	if value == default then
		-- Back to the default means back to no entry, so the shipped answer stays
		-- live for this user rather than being pinned at the moment they touched it.
		persisted = Storage.delete(PREF_PREFIX .. name)
	else
		persisted = Storage.set(PREF_PREFIX .. name, value)
	end
	if not persisted then
		Logger.error(LOG, "Could not persist '%s' — the active value was not changed.", name)
		return false
	end
	_values[name] = value
	Logger.info(LOG, "%s: %s.", name, tostring(value))
	return true
end

--- The values a menu offers for one setting, lowest first.
---
--- Presets rather than a free field: the tray has no text input, and a menu of
--- every representable number is not a menu. They span the declared range so
--- nothing offered is out of bounds.
--- @param name string
--- @return table Array of numbers.
function M.presets(name)
	if name == "temperature" then return { 0.0, 0.1, 0.3, 0.5, 0.8, 1.0, 1.3 } end
	if name == "context_length" then return { 100, 250, 500, 1000, 2000, 4000 } end
	if name == "min_words" then return { 1, 2, 3, 5, 10, 15, 20 } end
	if name == "max_words" then return { 0, 5, 10, 15, 20, 50, 100 } end
	return {}
end

--- The accepted range for one setting, for the tests and the diagnostics.
--- @param name string
--- @return table|nil { min, max }
function M.bounds(name)
	local bounds = BOUNDS[name]
	if not bounds then return nil end
	return { min = bounds.min, max = bounds.max }
end

--- Test seam: forgets what was read.
function M._reset()
	_values = {}
	_shipped = nil
end

return M
