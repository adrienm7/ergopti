--- _shared/lua/layouts/composer.lua

--- ==============================================================================
--- MODULE: Layout Composer Store (Shared)
--- DESCRIPTION:
--- The part of the per-layer layout composer (docs/layout-composer.md) that
--- macOS and Linux do the same way: what the composer page may save, the
--- installed-layout record entry built from the compiled file, which layouts
--- the page may compose from, and the open, save and remove operations over
--- the driver's own install, uninstall and select ports. The Windows host does
--- the same in windows/ui/layout_manager/composer.ahk.
---
--- FEATURES & RATIONALE:
--- 1. The page is never trusted: the declaration and the compiled .keylayout
---    are size-bounded, the declaration is checked field by field, and the
---    layout must be the composer's own product (its keyboard name and map set).
---    The operating system's own reader (the system, or the XKB converter)
---    still has the last word on the file when it is installed.
--- 2. One installed-layout mechanism: the composition is recorded as the
---    layout of the reserved id `composed`, so the driver's picker, uninstall
---    and selection work on it unchanged.
--- 3. The declaration is stored first, then the layout installed: a failed
---    install leaves the composition editable.
--- 4. PURE Lua: every file, digest, record and install operation is injected.
--- ==============================================================================

local Registry = require("layouts.registry")

local M = {}

M.SCHEMA_VERSION = 1
M.MAX_NAME_LENGTH = 64
M.RECORD_VERSION = "1.0.0"

-- Failure codes the page words (layout_composer.failure_*).
M.FAILURE_INVALID = "invalid"
M.FAILURE_WRITE = "write_failed"
M.FAILURE_USE = "use_failed"

local CONVENTIONS = { iso = true, ansi = true }





-- ===========================
-- ===========================
-- ======= 1/ Settings =======
-- ===========================
-- ===========================

--- Validates the [composer] table of the shared layout defaults.
--- @param layout_defaults table Decoded _shared/modules/layouts/defaults.json.
--- @return table|nil settings { id, folder, declaration_file, max_declaration_bytes, family }
--- @return string|nil error
function M.settings(layout_defaults)
	local composer = type(layout_defaults) == "table" and layout_defaults.composer or nil
	if type(composer) ~= "table" then return nil, "the layout defaults have no composer table" end
	if not Registry.is_valid_id(composer.id) or not Registry.is_valid_id(composer.family) then
		return nil, "the composer id and family must be registry ids"
	end
	if type(composer.folder) ~= "string" or not composer.folder:match("^[A-Za-z0-9._-]+$") then
		return nil, "the composer folder is not a plain folder name"
	end
	if type(composer.declaration_file) ~= "string" or not composer.declaration_file:match("^[A-Za-z0-9._-]+$") then
		return nil, "the composer declaration file is not a plain file name"
	end
	if type(composer.max_declaration_bytes) ~= "number" or composer.max_declaration_bytes <= 0
		or composer.max_declaration_bytes % 1 ~= 0 then
		return nil, "the composer declaration bound is not a positive integer"
	end
	return {
		id = composer.id,
		folder = composer.folder,
		declaration_file = composer.declaration_file,
		max_declaration_bytes = composer.max_declaration_bytes,
		family = composer.family,
	}, nil
end





-- ===========================
-- ===========================
-- ======= 2/ Checking =======
-- ===========================
-- ===========================

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

--- Decodes the XML character references an attribute can hold.
--- @param value string
--- @return string
local function decode_attribute(value)
	return (value:gsub("&(#?x?%w+);", function(token)
		if ENTITIES[token] then return ENTITIES[token] end
		local hex = token:match("^#x(%x+)$")
		local dec = token:match("^#(%d+)$")
		local code = hex and tonumber(hex, 16) or dec and tonumber(dec, 10) or nil
		if code and code >= 0 and code < 0x110000 then
			if code < 0x80 then return string.char(code) end
			if code < 0x800 then return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40) end
			if code < 0x10000 then
				return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40,
					0x80 + code % 0x40)
			end
			return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
				0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
		end
		return nil
	end))
end

--- Counts the characters of a UTF-8 text.
--- @param text string
--- @return number
local function character_count(text)
	return select(2, text:gsub("[^\128-\191]", ""))
end

--- Checks what the page saves.
--- @param settings table From M.settings.
--- @param max_file_bytes number The registry's bound for one layout file.
--- @param declaration_text any composition.json as the page wrote it.
--- @param keylayout any The compiled .keylayout.
--- @param decode_json function
--- @return table|nil checked { name, convention }
--- @return string|nil code M.FAILURE_INVALID
--- @return string|nil detail
function M.check(settings, max_file_bytes, declaration_text, keylayout, decode_json)
	local function refuse(why) return nil, M.FAILURE_INVALID, why end
	if type(declaration_text) ~= "string" or type(keylayout) ~= "string" then
		return refuse("the composition must be sent as text")
	end
	if #declaration_text > settings.max_declaration_bytes then
		return refuse("the composition is larger than " .. settings.max_declaration_bytes .. " bytes")
	end
	if #keylayout > max_file_bytes then
		return refuse("the compiled layout is larger than " .. max_file_bytes .. " bytes")
	end
	local ok, declaration = pcall(decode_json, declaration_text)
	if not ok or type(declaration) ~= "table" then return refuse("the composition is not valid JSON") end
	if declaration.schema_version ~= M.SCHEMA_VERSION then
		return refuse("the composition has an unknown schema version")
	end
	local name = declaration.name
	if type(name) ~= "string" or not name:match("%S") or character_count(name) > M.MAX_NAME_LENGTH
		or name:find("[%z\1-\31\127]") then
		return refuse("the layout name is empty, too long or holds control characters")
	end
	if not CONVENTIONS[declaration.keycode_convention] then
		return refuse("the keycode convention is neither iso nor ansi")
	end
	if not keylayout:match("^<%?xml") or keylayout:find("<!ENTITY", 1, true) then
		return refuse("the compiled layout is not a plain .keylayout")
	end
	local keyboard_name = keylayout:match('<keyboard[^>]-%sname="([^"]*)"')
	if keyboard_name == nil or decode_attribute(keyboard_name) ~= name then
		return refuse("the compiled layout is not named after the composition")
	end
	local map_set = keylayout:match('<layout%s[^>]-mapSet="([^"]*)"')
	if map_set ~= settings.id or not keylayout:find('<layout%s[^>]-first="0"') then
		return refuse("the compiled layout is not a composer product")
	end
	return { name = name, convention = declaration.keycode_convention }, nil, nil
end

--- The installed record's entry of a composition.
--- @param settings table
--- @param checked table From M.check.
--- @param keylayout string
--- @param digest string The file's SHA-256, lowercase hex.
--- @param platform string "macos" or "linux".
--- @return table
function M.entry(settings, checked, keylayout, digest, platform)
	return {
		id = settings.id,
		name = checked.name,
		family = settings.family,
		keyboard_name = checked.name,
		version = M.RECORD_VERSION,
		file = settings.id .. "/" .. settings.id .. ".keylayout",
		sha256 = digest,
		size = #keylayout,
		keycode_convention = checked.convention,
		licence = "",
		author = "",
		homepage = "",
		languages = {},
		platforms = { platform },
	}
end





-- ==========================
-- ==========================
-- ======= 3/ Sources =======
-- ==========================
-- ==========================

--- The layouts the page can compose from: the registry layouts shipped with
--- the driver and the installed ones, each read through its checksum. One that
--- fails verification is logged and left out, never offered unverified.
--- @param env table Ports: platform, composer_id, bundled_index (table|nil),
---   bundled_dir, local_dir, installed (record layouts table), read(path),
---   sha256(text, callback), log(level, message, ...).
--- @param on_done function on_done(sources) with { id, name, convention, text }.
function M.sources(env, on_done)
	local candidates, seen = {}, {}
	local function supports(entry)
		for _, platform in ipairs(type(entry.platforms) == "table" and entry.platforms or {}) do
			if platform == env.platform then return true end
		end
		return false
	end
	if type(env.bundled_index) == "table" and type(env.bundled_index.layouts) == "table"
		and type(env.bundled_dir) == "string" then
		for _, entry in ipairs(env.bundled_index.layouts) do
			if entry.id ~= env.composer_id and supports(entry) then
				candidates[#candidates + 1] = { entry = entry, path = env.bundled_dir .. entry.file }
				seen[entry.id] = true
			end
		end
	end
	local ids = {}
	for id in pairs(env.installed or {}) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		if id ~= env.composer_id and not seen[id] then
			candidates[#candidates + 1] = { entry = env.installed[id], path = env.local_dir .. id .. ".keylayout" }
		end
	end
	local sources = {}
	local function step(position)
		local candidate = candidates[position]
		if candidate == nil then
			on_done(sources)
			return
		end
		local entry = candidate.entry
		local text = env.read(candidate.path)
		if type(text) ~= "string" then
			env.log("warn", "The '%s' layout is not offered as a source: %s is unreadable.", entry.id, candidate.path)
			step(position + 1)
			return
		end
		env.sha256(text, function(digest, err)
			local ok, reason = Registry.verify(entry, text, digest)
			if ok then
				sources[#sources + 1] = {
					id = entry.id,
					name = type(entry.name) == "string" and entry.name ~= "" and entry.name or entry.id,
					convention = entry.keycode_convention,
					text = text,
				}
			else
				env.log("warn", "The '%s' layout is not offered as a source: %s.", entry.id, tostring(reason or err))
			end
			step(position + 1)
		end)
	end
	step(1)
end





-- =============================
-- =============================
-- ======= 4/ Operations =======
-- =============================
-- =============================

--- Creates the open, save and remove operations over a driver's ports.
--- env: settings, max_file_bytes, platform, shortcuts ("full" | "single"),
---   config_dir (with a trailing slash), decode_json, read(path), write(path, text)
---   -> ok, err, exists(path), delete(path) -> ok, sha256(text, callback),
---   sources_env() -> the M.sources env, active_id() -> id of the current
---   layout or "", install(entry, text, on_done(ok, code, detail)),
---   uninstall(id, on_done(ok, code, detail)), select(id, on_done(ok, code, detail)),
---   installed() -> table of installed entries, log(level, message, ...).
--- @param env table
--- @return table { open, save, remove }
function M.new(env)
	local settings = env.settings
	local operations = {}

	local function declaration_path()
		return env.config_dir .. settings.folder .. "/" .. settings.declaration_file
	end

	--- Sends the page what it needs to compose.
	--- @param on_done function on_done(data)
	function operations.open(on_done)
		local text = nil
		if env.exists(declaration_path()) then
			text = env.read(declaration_path())
			if type(text) ~= "string" or #text > settings.max_declaration_bytes then
				env.log("error", "The stored composition %s is unreadable or larger than its bound.",
					declaration_path())
				text = "unreadable"
			end
		end
		M.sources(env.sources_env(), function(sources)
			on_done({
				platform = env.platform,
				sources = sources,
				declaration = text,
				active = env.active_id() == settings.id,
				shortcuts = env.shortcuts,
			})
		end)
	end

	--- Stores a composition and installs its layout.
	--- @param payload table { declaration, keylayout, use }
	--- @param on_done function on_done(ok, code, detail, used)
	function operations.save(payload, on_done)
		local checked, code, detail = M.check(settings, env.max_file_bytes, payload.declaration, payload.keylayout,
			env.decode_json)
		if not checked then
			env.log("error", "The composition was refused: %s.", tostring(detail))
			on_done(false, code, detail, false)
			return
		end
		env.sha256(payload.keylayout, function(digest, digest_err)
			if type(digest) ~= "string" then
				on_done(false, M.FAILURE_WRITE, "cannot digest the compiled layout: " .. tostring(digest_err), false)
				return
			end
			local written, write_err = env.write(declaration_path(), payload.declaration)
			if not written then
				env.log("error", "The composition could not be stored: %s.", tostring(write_err))
				on_done(false, M.FAILURE_WRITE, tostring(write_err), false)
				return
			end
			local entry = M.entry(settings, checked, payload.keylayout, digest, env.platform)
			env.install(entry, payload.keylayout, function(installed, install_code, install_detail)
				if not installed then
					on_done(false, install_code, install_detail, false)
					return
				end
				if payload.use ~= true and env.active_id() ~= settings.id then
					on_done(true, nil, nil, false)
					return
				end
				env.select(settings.id, function(selected, select_code, select_detail)
					if not selected then
						on_done(false, M.FAILURE_USE, select_detail or select_code, false)
						return
					end
					on_done(true, nil, nil, true)
				end)
			end)
		end)
	end

	--- Removes the composition: the installed layout, then its declaration.
	--- @param on_done function on_done(ok, code, detail)
	function operations.remove(on_done)
		local function delete_declaration()
			if env.exists(declaration_path()) and not env.delete(declaration_path()) then
				on_done(false, M.FAILURE_WRITE, "cannot delete " .. declaration_path())
				return
			end
			on_done(true)
		end
		if (env.installed() or {})[settings.id] == nil then
			delete_declaration()
			return
		end
		env.uninstall(settings.id, function(ok, code, detail)
			if not ok then
				on_done(false, code, detail)
				return
			end
			delete_declaration()
		end)
	end

	return operations
end

return M
