--- _shared/lua/keycodes/evdev.lua

--- ==============================================================================
--- MODULE: evdev Keycode Loader
--- DESCRIPTION:
--- Loads Linux evdev kernel keycode → character maps from the shared JSON
--- (_shared/data/keycodes/evdev.json) and returns a LAYOUTS table indexed by
--- layout name (e.g. "qwerty", "azerty"), each containing {unshifted, shifted}
--- sub-tables keyed by integer keycode.
---
--- The caller injects a JSON decoder (e.g. hs.json.decode on macOS,
--- a pure-Lua JSON lib on Linux) and a file reader closure so this module stays
--- pure and driver-agnostic. Linux's input_reader calls load() with
--- require("json").decode and a custom io.open wrapper.
---
--- FEATURES & RATIONALE:
--- 1. Single source: the keycode maps live in _shared/data/keycodes/evdev.json,
---    not duplicated in every driver that needs evdev layout data.
--- 2. Pure module: no hard dependency on hs.* or any platform runtime — the
---    caller supplies the JSON decoder and file reader, so this module works
---    unchanged on macOS (test harness), Linux (daemon), and future hosts.
--- 3. Fail-fast: a missing or malformed JSON file returns nil + an error message
---    so the caller can degrade gracefully (e.g. fall back to inline maps).
--- ==============================================================================

local M = {}

--- Loads the evdev layout tables from the shared JSON file.
--- @param json_decode function A JSON string → Lua value decoder.
---   On Linux this is typically require("json").decode; on macOS it is hs.json.decode.
--- @param read_file function|nil Optional (path) → string|nil reader.
---   When nil, the default implementation uses io.open(path, "r"):read("*a").
--- @param shared_root function|nil Optional () → string returning the
---   absolute path to the _shared/ directory. When nil, the default walks up
---   from this file's own path (src = debug.getinfo) to locate _shared/.
--- @return table|nil The LAYOUTS table on success (see below), or nil on failure.
--- @return string|nil Error message when nil is returned.
---
--- Return shape on success:
---   {
---     qwerty = { unshifted = {[2]="1", [3]="2", …}, shifted = {[2]="!", …} },
---     azerty = { unshifted = {…}, shifted = {…} },
---   }
function M.load(json_decode, read_file, shared_root)
	if type(json_decode) ~= "function" then
		return nil, "json_decode must be a function"
	end

	-- Resolve shared root
	local root
	if type(shared_root) == "function" then
		local ok, r = pcall(shared_root)
		if ok and type(r) == "string" then root = r end
	end
	if not root then
		-- Walk up from this file's own directory: _shared/lua/keycodes/ →
		-- _shared/lua/ → _shared/. On standard Lua the source is a bare path;
		-- on LuaJIT it carries a leading '@' which must be stripped first.
		local src = debug and debug.getinfo and debug.getinfo(1, "S") and debug.getinfo(1, "S").source
		if src and type(src) == "string" then
			if src:sub(1, 1) == "@" then src = src:sub(2) end
			local dir = src:match("^(.*[/\\])") or ""
			-- dir is .../_shared/lua/keycodes/ — two levels up gives _shared/
			root = (dir:gsub("[\\\\/]$", ""):gsub("[/\\][^/\\]+[/\\][^/\\]+$", "") .. "/")
		end
	end
	if not root then
		return nil, "cannot resolve _shared/ root"
	end

	-- Read the JSON file
	local path = root .. "data/keycodes/evdev.json"
	local raw
	if type(read_file) == "function" then
		local ok, content = pcall(read_file, path)
		if ok and type(content) == "string" then raw = content end
	else
		local fh, err = io.open(path, "r")
		if fh then raw = fh:read("*a"); fh:close()
		else return nil, "cannot open " .. path .. ": " .. (err or "unknown error") end
	end
	if not raw or raw == "" then
		return nil, "empty or unreadable file: " .. path
	end

	-- Decode JSON
	local ok, data = pcall(json_decode, raw)
	if not ok or type(data) ~= "table" then
		return nil, "JSON decode failed for " .. path
	end

	-- Validate shape: data.layouts must be a table
	local layouts = data.layouts
	if type(layouts) ~= "table" then
		return nil, "missing 'layouts' key in evdev.json"
	end

	-- Convert string keys → integer keys for each layout
	local result = {}
	for layout_name, layout_data in pairs(layouts) do
		if type(layout_data) ~= "table" then goto next_layout end
		local entry = {}
		for _, mode in ipairs({"unshifted", "shifted"}) do
			local raw_map = layout_data[mode]
			if type(raw_map) ~= "table" then goto next_mode end
			local int_map = {}
			for k, v in pairs(raw_map) do
				local n = tonumber(k)
				if n and v then
					int_map[n] = v
				end
			end
			entry[mode] = int_map
			::next_mode::
		end
		if entry.unshifted then
			result[layout_name] = entry
		end
		::next_layout::
	end

	if next(result) == nil then
		return nil, "no valid layouts found in evdev.json"
	end

	return result
end

return M
