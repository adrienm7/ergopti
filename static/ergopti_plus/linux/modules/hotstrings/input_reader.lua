--- modules/hotstrings/input_reader.lua

--- ==============================================================================
--- MODULE: Input Reader (Linux)
--- DESCRIPTION:
--- Translates kernel keycodes into the characters a layout produces. It is the
--- one place that owns _shared/data/keycodes/evdev.json, and every caller that
--- needs a character from a code goes through resolve_char().
---
--- WHAT IT NO LONGER DOES:
--- It used to also open the device and run a blocking read loop, in an M.new()
--- reader instance that no production code ever called. That instance carried a
--- second copy of shift handling, a second copy of the control-key list, and a
--- third copy of the struct layout — all hardcoded to a 24-byte struct with the
--- type field at offset 17, which is the 64-bit shape and only that. Reading the
--- descriptor now belongs to adapters/evdev_reader.lua and the struct to
--- infra/input_event.lua, where the size is measured rather than assumed.
---
--- FEATURES & RATIONALE:
--- 1. Single source for layout data: the keycode maps live in
---    _shared/data/keycodes/evdev.json and are loaded once at require time.
--- 2. Fail-fast: a missing or unreadable JSON is an assertion, not a fallback.
---    A silent inline copy is how the tables diverged the first time.
--- 3. No device access: this module reads no file descriptor and holds no state
---    beyond the loaded tables, so it is safe to require from anywhere.
--- ==============================================================================

local M = {}


-- =========================================
-- =========================================
-- ======= 1/ Logger Shim ==================
-- =========================================
-- =========================================

local Logger = require("logger.shim")

local LOG = "modules.hotstrings.input_reader"


-- =========================================
-- =========================================
-- ======= 2/ Constants ====================
-- =========================================
-- =========================================

-- Deliberately none. The struct layout lives in infra/input_event.lua and the
-- key identities in infra/evdev_codes.lua; both were duplicated here, and a
-- constant that exists in two files is a constant that will eventually differ
-- in two files.





-- ==========================================
-- ==========================================
-- ======= 3/ Keycode Tables (shared) =======
-- ==========================================
-- ==========================================

-- Load the evdev keycode maps from the shared JSON (LNX-1). The loader returns
-- the same LAYOUTS shape {qwerty={unshifted,shifted}, azerty=…}.
-- This is the SINGLE source of truth — no hardcoded fallback

local LAYOUTS = nil

local function _load_shared_layouts()
	local ok_evdev, evdev = pcall(require, "keycodes.evdev")
	if not ok_evdev or type(evdev) ~= "table" or type(evdev.load) ~= "function" then
		return nil, "keycodes.evdev module unavailable"
	end

	-- The Linux daemon uses a vendored pure-Lua JSON decoder.
	local ok_json, json_mod = pcall(require, "json")
	local decode = (ok_json and json_mod and json_mod.decode) or nil
	if not decode then
		-- Fall back to a minimal JSON parser if no json module is available.
		-- Uses load("return "..raw) which works for our trusted static data
		-- (keycodes are plain strings/numbers; booleans/null not yet needed).
		decode = function(raw)
			local ok, val = pcall(function()
				local f = assert(load("return " .. raw))
				return f()
			end)
			if ok then return val end
		end
	end
	if not decode then
		return nil, "no JSON decoder available"
	end

	-- Resolve the _shared/ root explicitly: walk up from this file's location
	-- (linux/modules/hotstrings/input_reader.lua) → three levels up gives the
	-- repo root, then _shared/.  Passed to evdev.load so it never falls back to
	-- the fragile debug.getinfo path (which breaks under LuaJIT).
	local function shared_root()
		local src = debug and debug.getinfo and debug.getinfo(1, "S")
		if src and src.source then
			local s = src.source
			if s:sub(1, 1) == "@" then s = s:sub(2) end
			local dir = s:match("^(.*[/\\])") or ""
			-- dir is .../linux/modules/hotstrings/ → walk up 3 levels
			local root = dir:gsub("[/\\]$", "")
			root = root:gsub("[/\\][^/\\]+[/\\][^/\\]+[/\\][^/\\]+$", "")
			if root and root ~= dir then
				return root .. "/_shared/"
			end
		end
		return nil
	end

	return evdev.load(decode, nil, shared_root)
end

-- Attempt the shared load once at module-init time. Fail-fast: no fallback.
local _shared_layouts, _shared_err = _load_shared_layouts()
if _shared_layouts then
	LAYOUTS = _shared_layouts
	Logger.info(LOG, "evdev keycode tables loaded from shared JSON.")
else
	Logger.error(LOG, "shared evdev load failed (%s) — keycode resolution will not work.", _shared_err or "unknown")
end

-- No hardcoded fallback keycode tables. The single source of truth is
-- _shared/data/keycodes/evdev.json, loaded at module-init time via
-- _load_shared_layouts(). If that load fails, the module errors out —
-- keycode data MUST come from the shared source, never re-declared here.
-- The inline tables used to be triplicates of evdev.json
assert(LAYOUTS ~= nil, "input_reader: evdev.json keycode tables failed to load — _shared/data/keycodes/evdev.json is the single source and must be readable")




-- =======================================
-- ===== 3.5) Public Layout Accessor =====
-- =======================================

--- Returns the loaded LAYOUTS table so other modules (e.g. keyboard_hook)
--- can resolve keycodes → characters without re-loading evdev.json or
--- re-declaring hardcoded layout maps.
--- @return table The LAYOUTS table: {qwerty={unshifted,shifted}, …}.
function M.get_layouts()
	return LAYOUTS
end

--- Resolves a keycode to a character using the given layout and shift state.
--- Returns nil for non-printable keycodes.
--- @param code    integer Kernel keycode (input-event-codes.h KEY_* value).
--- @param layout  string  Layout name ("qwerty" or "azerty").
--- @param shifted boolean True if Shift is held.
--- @return string|nil The resolved character, or nil.
function M.resolve_char(code, layout, shifted)
	local lt = LAYOUTS[layout] or LAYOUTS["qwerty"]
	if not lt then return nil end
	local table_to_use = shifted and lt.shifted or lt.unshifted
	return table_to_use and table_to_use[code] or nil
end


return M
