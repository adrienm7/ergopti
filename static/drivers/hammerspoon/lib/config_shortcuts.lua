--- lib/config_shortcuts.lua

--- ==============================================================================
--- MODULE: Config Shortcuts (TOML section)
--- DESCRIPTION:
--- HS-specific UI-shortcut store. Reads / writes the ``[shortcuts]``
--- section of ``<config_dir>/hammerspoon/config.toml``. The schema is
--- identical to the AHK driver's ``<config_dir>/ahk/config.toml`` but the
--- file itself is driver-specific because what feels right on macOS
--- (Cmd-based shortcuts) and on Windows (Ctrl-based) is not
--- interchangeable. Each driver owns its own file under its own
--- subfolder so a shared config directory can hold both side by side
--- without any value bleeding.
---
--- SECTION LAYOUT (hammerspoon/config.toml):
---
---   [shortcuts]
---   metrics_enabled                 = true
---   metrics_shortcut_typing         = "cmd+alt+m"
---   metrics_shortcut_apps           = "cmd+alt+t"
---   metrics_filter_private_browsing = true
---   metrics_filter_system_auth      = true
---   metrics_disabled_apps           = ["com.google.Chrome", ...]   # bundle IDs
---
--- FEATURES & RATIONALE:
--- 1. Per-driver subfolder: ``<config_dir>/hammerspoon/`` is auto-created
---    on first save. Disjoint from ``<config_dir>/ahk/`` so the two
---    drivers never touch the same file.
--- 2. Section-preserving writer: replaces only the [shortcuts] block,
---    leaving every other section untouched.
--- 3. Defensive parser: handles strings, booleans, integers, and arrays
---    of strings. Comments and blank lines are skipped.
--- 4. Stateless API: the caller passes a state table on read and gets
---    the persisted values folded back into it; on write the caller
---    hands over the canonical values.
--- ==============================================================================

local M = {}




-- ===================================
-- ===================================
-- ======= 1/ Path resolution =======
-- ===================================
-- ===================================

--- Returns the absolute path to <config_dir>/hammerspoon/config.toml.
local function toml_path()
	local ok, MenuPaths = pcall(require, "ui.menu.menu_paths")
	if ok and type(MenuPaths.is_initialized) == "function" and MenuPaths.is_initialized() then
		local p = MenuPaths.get("ConfigTomlPath")
		if type(p) == "string" and p ~= "" then return p end
	end
	-- Defensive fallback: MenuPaths not yet ready (early bootstrap).
	local home = os.getenv("HOME") or ""
	return home .. "/.config/ergopti_plus/hammerspoon/config.toml"
end




-- ===================================
-- ===================================
-- ======= 2/ Tiny TOML parser =======
-- ===================================
-- ===================================

local function trim(s)
	return (s:match("^%s*(.-)%s*$") or s)
end

--- Coerce a raw RHS into a Lua value (string / boolean / integer / array).
local function coerce(raw)
	raw = trim(raw)
	if raw == "" then return "" end
	local lower = raw:lower()
	if lower == "true"  then return true  end
	if lower == "false" then return false end
	-- Quoted string.
	if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' then
		local inner = raw:sub(2, -2)
		inner = inner:gsub('\\"', '"'):gsub("\\\\", "\\")
		           :gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "\r")
		return inner
	end
	-- Array of strings.
	if raw:sub(1, 1) == "[" and raw:sub(-1) == "]" then
		local body = trim(raw:sub(2, -2))
		local out = {}
		if body == "" then return out end
		for piece in body:gmatch("[^,]+") do
			local v = coerce(trim(piece))
			if type(v) == "string" then table.insert(out, v) end
		end
		return out
	end
	-- Integer.
	if raw:match("^%-?%d+$") then return tonumber(raw) end
	return raw
end

--- Parse a flat-section TOML file into { section_name = { key = value } }.
local function parse(content)
	local out = {}
	local section
	for line in (content .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local trimmed = trim(line)
		if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
			local hdr = trimmed:match("^%[(.-)%]$")
			if hdr then
				section = trim(hdr)
				out[section] = out[section] or {}
			elseif section then
				local key, val = trimmed:match("^(%S+)%s*=%s*(.+)$")
				if key then out[section][key] = coerce(val) end
			end
		end
	end
	return out
end




-- ===================================
-- ===================================
-- ======= 3/ Tiny TOML writer =======
-- ===================================
-- ===================================

local function quote_str(s)
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
	     :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
	return '"' .. s .. '"'
end

local function render_value(v)
	if v == true  then return "true"  end
	if v == false then return "false" end
	if type(v) == "number" then return tostring(v) end
	if type(v) == "table" then
		local parts = {}
		for _, item in ipairs(v) do
			table.insert(parts, quote_str(tostring(item)))
		end
		return "[" .. table.concat(parts, ", ") .. "]"
	end
	return quote_str(tostring(v))
end

--- Render a single section as `[name]\nkey = value\n…`.
local function render_section(name, kv)
	local lines = { "[" .. name .. "]" }
	for k, v in pairs(kv) do
		table.insert(lines, k .. " = " .. render_value(v))
	end
	return table.concat(lines, "\n") .. "\n"
end

--- Replace the named section inside `body` (or append it). Other
--- sections are preserved verbatim, including blank-line spacing.
local function replace_section(body, section_name, replacement)
	if body == "" or body == nil then return replacement .. "\n" end

	local before, after, in_target, seen = {}, {}, false, false
	for line in (body .. "\n"):gmatch("([^\r\n]*)\r?\n") do
		local trimmed = trim(line)
		local hdr = trimmed:match("^%[(.-)%]$")
		if hdr then
			if trim(hdr) == section_name then
				in_target = true; seen = true
				goto continue
			elseif in_target then
				in_target = false  -- this header belongs to the « after » bucket
			end
		end
		if not in_target then
			if not seen then table.insert(before, line) else table.insert(after, line) end
		end
		::continue::
	end

	local head = table.concat(before, "\n")
	local tail = table.concat(after,  "\n")
	if head ~= "" and head:sub(-1) ~= "\n" then head = head .. "\n" end
	if tail == "" then return head .. replacement end
	return head .. replacement .. "\n" .. tail
end




-- ============================================
-- ============================================
-- ======= 4/ Public read / write API =======
-- ============================================
-- ============================================

--- Read the persisted [shortcuts] section. Returns a Lua table mirroring
--- the section's keys, or {} when the file or section is missing.
function M.read()
	local path = toml_path()
	local fh = io.open(path, "r")
	if not fh then return {} end
	local content = fh:read("*a"); fh:close()
	local parsed = parse(content)
	return parsed.shortcuts or {}
end

--- Apply persisted values onto the menu state table. Caller passes the
--- driver's shared `state` Map; we copy in only the keys that exist in
--- the file so unrelated state survives. Returns the keys that were
--- folded for diagnostics.
function M.apply_to_state(state)
	if type(state) ~= "table" then return {} end
	local kv = M.read()
	local applied = {}

	-- Metrics enabled flag.
	if kv.metrics_enabled ~= nil then
		state.keylogger_enabled = kv.metrics_enabled and true or false
		applied[#applied + 1] = "metrics_enabled"
	end

	-- UI hotkey strings → state.metrics_shortcut / state.apps_time_shortcut
	-- in the legacy { mods = {...}, key = "..." } shape consumed by
	-- ui/menu/menu_metrics.lua. Empty strings disable the binding.
	local function parse_combo(raw)
		if type(raw) ~= "string" or raw == "" then return false end
		local parts = {}
		for p in raw:lower():gmatch("[^+]+") do table.insert(parts, p) end
		if #parts < 1 then return false end
		local key  = parts[#parts]
		local mods = {}
		for i = 1, #parts - 1 do
			local m = parts[i]
			if m == "option" then m = "alt" end
			if m == "win"    then m = "cmd" end
			table.insert(mods, m)
		end
		if #mods == 0 then mods = { "ctrl" } end
		return { mods = mods, key = key }
	end

	if kv.metrics_shortcut_typing ~= nil then
		state.metrics_shortcut = parse_combo(kv.metrics_shortcut_typing)
		applied[#applied + 1] = "metrics_shortcut_typing"
	end
	if kv.metrics_shortcut_apps ~= nil then
		state.apps_time_shortcut = parse_combo(kv.metrics_shortcut_apps)
		applied[#applied + 1] = "metrics_shortcut_apps"
	end

	-- Privacy filters (HS-side) and disabled-apps list. Keys mirror the
	-- HS state names directly so menu_metrics's checkbox handlers stay
	-- unchanged.
	if kv.metrics_filter_private_browsing ~= nil then
		state.keylogger_private_filter_enabled = kv.metrics_filter_private_browsing and true or false
		applied[#applied + 1] = "metrics_filter_private_browsing"
	end
	if kv.metrics_filter_system_auth ~= nil then
		state.keylogger_system_auth_filter_enabled = kv.metrics_filter_system_auth and true or false
		applied[#applied + 1] = "metrics_filter_system_auth"
	end
	-- The disabled-apps list contains macOS bundle IDs on this driver and
	-- Windows process names on the AHK driver. Both write their own list
	-- and ignore the other's, so we still pull whatever is here — the
	-- menu UI reflects exactly what got persisted from this side.
	if type(kv.metrics_disabled_apps) == "table" then
		state.keylogger_disabled_apps = kv.metrics_disabled_apps
		applied[#applied + 1] = "metrics_disabled_apps"
	end
	return applied
end

--- Persist the menu state back to disk. Inverse of apply_to_state. Only
--- rewrites the [shortcuts] section; every other section in config.toml
--- stays put.
function M.save_from_state(state)
	if type(state) ~= "table" then return false end

	local function combo_to_str(c)
		if type(c) ~= "table" then return "" end
		local parts = {}
		for _, m in ipairs(c.mods or {}) do table.insert(parts, m) end
		table.insert(parts, c.key or "")
		return table.concat(parts, "+")
	end

	local kv = {
		metrics_enabled                 = state.keylogger_enabled and true or false,
		metrics_shortcut_typing         = combo_to_str(state.metrics_shortcut),
		metrics_shortcut_apps           = combo_to_str(state.apps_time_shortcut),
		metrics_filter_private_browsing = state.keylogger_private_filter_enabled ~= false,
		metrics_filter_system_auth      = state.keylogger_system_auth_filter_enabled ~= false,
		metrics_disabled_apps           = type(state.keylogger_disabled_apps) == "table"
			and state.keylogger_disabled_apps or {},
	}

	local path = toml_path()
	local body = ""
	local fh = io.open(path, "r")
	if fh then body = fh:read("*a"); fh:close() end

	local rendered = render_section("shortcuts", kv)
	local new_body = replace_section(body, "shortcuts", rendered)

	-- Atomic write via .tmp + rename.
	local tmp = path .. ".tmp"
	local fw, err = io.open(tmp, "w")
	if not fw then return false, err end
	fw:write(new_body); fw:close()
	os.rename(tmp, path)
	return true
end


return M
