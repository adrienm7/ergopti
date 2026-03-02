-- Personal information shortcuts for Hammerspoon.
--
-- Monitors typed characters and expands  @<letters><trigger>  into
-- tab-separated personal-information values.
--
-- Architecture: instead of a separate eventtap (which would compete with
-- keymap's tap for event ordering), this module registers an *interceptor*
-- directly inside keymap's single keyDown tap via keymap.register_interceptor().
-- The interceptor runs BEFORE backspace, escape, getCharacters(false) and all
-- hotstring matching — ensuring that Unicode trigger chars like ★ are caught
-- even when getCharacters(false) returns "".
--
-- Interceptor return values:
--   "consume"  → keymap returns true  (★ is consumed, suppresses apps + hotstrings)
--   "suppress" → keymap returns false (letter appears in field, hotstrings skipped)
--   nil        → normal keymap processing
--
-- Example (default config):
--   @np★  →  Nom [Tab] Prénom
--   @e★   →  prenom.nom@mail.fr
--   @npa★ →  Nom [Tab] Prénom [Tab] 1 Rue de la Paix

local M = {}

local eventtap = hs.eventtap
local timer    = hs.timer

-- ---------------------------------------------------------------------------
-- States
-- ---------------------------------------------------------------------------
local STATE_IDLE       = "idle"
local STATE_COLLECTING = "collecting"  -- after @ has been typed

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------
local _enabled   = false
local _replacing = false
local _state     = STATE_IDLE
local _combo     = ""   -- letters accumulated after @

-- Config (populated by start()).
local _trigger   = "★"
local _info      = {}
local _letters   = {}
local _base_dir  = ""

-- ---------------------------------------------------------------------------
-- Config loader
-- ---------------------------------------------------------------------------
local function load_config(base_dir)
	local path = base_dir .. "personal_info_config.lua"
	local ok, result = pcall(dofile, path)
	if ok and type(result) == "table" then return result end
	print("[personal_info] Cannot load config at " .. path .. ": " .. tostring(result))
	return nil
end

-- ---------------------------------------------------------------------------
-- Combo resolver
-- ---------------------------------------------------------------------------
local function resolve_combo(combo)
	local parts = {}
	for i = 1, #combo do
		local letter = combo:sub(i, i)
		local key    = _letters[letter]
		if key and _info[key] then
			table.insert(parts, _info[key])
		end
	end
	return parts
end

-- ---------------------------------------------------------------------------
-- Expansion (runs asynchronously so keymap's tap can return first)
-- ---------------------------------------------------------------------------
local function do_expand(combo)
	-- At expansion time, the field contains: ...@<combo>
	-- The ★ was consumed by the interceptor so it is NOT in the field.
	-- We delete: @ (1) + #combo ASCII letters.
	local n_back = 1 + #combo
	local parts  = resolve_combo(combo)

	_replacing = true

	for _ = 1, n_back do
		eventtap.keyStroke({}, "delete", 0)
	end
	for i, value in ipairs(parts) do
		eventtap.keyStrokes(value)
		if i < #parts then
			eventtap.keyStroke({}, "tab", 0)
		end
	end

	timer.doAfter(0.15, function()
		_replacing = false
	end)
end

-- ---------------------------------------------------------------------------
-- Interceptor (registered into keymap via keymap.register_interceptor)
-- Called for every keyDown event that passes the cmd/ctrl guard.
-- ---------------------------------------------------------------------------
local function interceptor(event, _km_buffer)
	-- While we are sending synthetic events, pass everything through.
	if _replacing then return nil end

	local flags = event:getFlags()
	if flags.cmd or flags.ctrl then
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	local kc = event:getKeyCode()

	-- Esc / Return / Enter / arrows → abort combo.
	if kc == 53 or kc == 36 or kc == 76
	or (kc >= 123 and kc <= 126) then
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	-- Backspace: pop last accumulated letter, or cancel @ if combo is empty.
	if kc == 51 then
		if _state == STATE_COLLECTING then
			if #_combo > 0 then
				_combo = _combo:sub(1, -2)
			else
				_state = STATE_IDLE
			end
		end
		return nil  -- keymap handles backspace normally
	end

	-- Use getCharacters(false) as primary source — this mirrors what keymap
	-- uses to build its buffer and correctly resolves Karabiner-remapped
	-- Unicode characters like ★ (where getCharacters(true) would return
	-- the underlying physical key name "j" instead of "★").
	local char = event:getCharacters(false) or ""
	if char == "" then return nil end

	-- ── IDLE: watch for @ ─────────────────────────────────────────────────
	if _state == STATE_IDLE then
		if char == "@" then
			_state = STATE_COLLECTING
			_combo = ""
		end
		return nil  -- let @ appear in the field normally
	end

	-- ── COLLECTING ────────────────────────────────────────────────────────
	if _state == STATE_COLLECTING then
		-- Trigger character → attempt expansion.
		if char == _trigger then
			if #_combo > 0 and #resolve_combo(_combo) > 0 then
				local combo = _combo
				_state = STATE_IDLE
				_combo = ""
				-- Defer so keymap's tap finishes returning "consume" first.
				timer.doAfter(0, function() do_expand(combo) end)
				return "consume"  -- swallow ★, prevent hotstring matching
			end
			-- No letters matched → let ★ pass and reset.
			_state = STATE_IDLE
			_combo = ""
			return nil
		end

		-- Lowercase ASCII letter → accumulate, suppress hotstring matching.
		if char:match("^[a-z]$") then
			_combo = _combo .. char
			return "suppress"  -- letter appears in field, hotstrings skipped
		end

		-- Anything else → abort combo, let char propagate normally.
		_state = STATE_IDLE
		_combo = ""
		return nil
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Start the module.
-- base_dir      : path to the Hammerspoon config directory (trailing slash).
-- keymap_module : the loaded keymap module; used to register the interceptor.
function M.start(base_dir, keymap_module)
	M.stop()

	if base_dir then _base_dir = base_dir end

	local config = load_config(_base_dir)
	if not config then
		print("[personal_info] Module disabled (config missing or invalid).")
		return
	end

	_trigger = config.trigger_char or "★"
	_info    = config.info    or {}
	_letters = config.letters or {}

	_state     = STATE_IDLE
	_combo     = ""
	_replacing = false

	-- Register interceptor inside keymap's single tap so ordering is guaranteed.
	if keymap_module and type(keymap_module.register_interceptor) == "function" then
		keymap_module.register_interceptor(interceptor)
		print("[personal_info] Interceptor registered in keymap.")
	else
		print("[personal_info] WARNING: keymap_module not provided or missing register_interceptor.")
	end

	_enabled = true

	local letter_count = 0
	for _ in pairs(_letters) do letter_count = letter_count + 1 end
	print(string.format("[personal_info] Started — trigger: %s, %d letter(s) mapped.",
		_trigger, letter_count))
end

function M.stop()
	-- Unregister from keymap if applicable (set interceptor to nil).
	-- We don't store a reference to keymap_module here, so the caller
	-- must register again when re-enabling via menu.
	_enabled   = false
	_state     = STATE_IDLE
	_combo     = ""
	_replacing = false
end

function M.is_enabled()
	return _enabled
end

return M
