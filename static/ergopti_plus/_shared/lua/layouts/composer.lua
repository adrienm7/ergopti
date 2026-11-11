--- _shared/lua/layouts/composer.lua

--- ==============================================================================
--- MODULE: Layout Composer Store (Shared)
--- DESCRIPTION:
--- The part of the per-layer layout composer (docs/design/layout-composer.md) that
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
--- 5. The page may save an Ergopti layout source (docs/design/layout-source-format.md)
---    in place of a composition: the TOML is stored, and the .keylayout the shared
---    source compiler built from it is installed and emulated the same way. One
---    composed layout exists at a time, so saving one form removes the other.
--- ==============================================================================

local Registry = require("layouts.registry")
local Keylayout = require("layouts.keylayout")
local TableUtil = require("table_util")

local M = {}

M.SCHEMA_VERSION = 1
M.SOURCE_FORMAT = "ergopti-layout"
M.SOURCE_VERSION = 1
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
--- @return table|nil settings { id, folder, declaration_file, max_declaration_bytes, source_file,
---   max_source_bytes, family }
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
	if type(composer.source_file) ~= "string" or not composer.source_file:match("^[A-Za-z0-9._-]+$")
		or composer.source_file == composer.declaration_file then
		return nil, "the composer source file is not a plain file name distinct from the declaration"
	end
	for _, field in ipairs({ "max_declaration_bytes", "max_source_bytes" }) do
		local bound = composer[field]
		if type(bound) ~= "number" or bound <= 0 or bound % 1 ~= 0 then
			return nil, "the composer " .. field .. " bound is not a positive integer"
		end
	end
	return {
		id = composer.id,
		folder = composer.folder,
		declaration_file = composer.declaration_file,
		max_declaration_bytes = composer.max_declaration_bytes,
		source_file = composer.source_file,
		max_source_bytes = composer.max_source_bytes,
		family = composer.family,
	}, nil
end





-- ===========================
-- ===========================
-- ======= 2/ Checking =======
-- ===========================
-- ===========================

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
	-- The one .keylayout reader: layouts.keylayout. It finds the default
	-- <layout first="0"> and refuses a file whose map set or modifier map is undefined.
	local parsed, parse_error = Keylayout.parse(keylayout)
	if parsed == nil then
		return refuse("the compiled layout is not a readable .keylayout: " .. tostring(parse_error))
	end
	if parsed.name ~= name then
		return refuse("the compiled layout is not named after the composition")
	end
	if parsed.map_set ~= settings.id then
		return refuse("the compiled layout is not a composer product")
	end
	return { name = name, convention = declaration.keycode_convention }, nil, nil
end

--- Checks an Ergopti layout source and the .keylayout the page compiled from it.
--- The page owns the schema (source_model.js) and the compiler; the host checks
--- what it relies on: the bounds, the format and version, the display name, and
--- that the layout is the one the source names (its internal name).
--- @param settings table From M.settings.
--- @param max_file_bytes number
--- @param source_text any The TOML source as the page wrote it.
--- @param keylayout any The compiled (or, for a preserved import, the imported) .keylayout.
--- @param decode_toml function
--- @return table|nil checked { name, keyboard_name, convention }
--- @return string|nil code M.FAILURE_INVALID
--- @return string|nil detail
function M.check_source(settings, max_file_bytes, source_text, keylayout, decode_toml)
	local function refuse(why) return nil, M.FAILURE_INVALID, why end
	if type(source_text) ~= "string" or type(keylayout) ~= "string" then
		return refuse("the layout source must be sent as text")
	end
	if #source_text > settings.max_source_bytes then
		return refuse("the layout source is larger than " .. settings.max_source_bytes .. " bytes")
	end
	if #keylayout > max_file_bytes then
		return refuse("the compiled layout is larger than " .. max_file_bytes .. " bytes")
	end
	local ok, source = pcall(decode_toml, source_text)
	if not ok or type(source) ~= "table" then return refuse("the layout source is not valid TOML") end
	if source.format ~= M.SOURCE_FORMAT or source.version ~= M.SOURCE_VERSION then
		return refuse("the layout source has an unknown format or version")
	end
	local layout = type(source.layout) == "table" and source.layout or {}
	local name = layout.name
	if type(name) ~= "string" or not name:match("%S") or character_count(name) > M.MAX_NAME_LENGTH
		or name:find("[%z\1-\31\127]") then
		return refuse("the layout name is empty, too long or holds control characters")
	end
	if not Registry.is_valid_id(layout.id) then return refuse("the layout id is not a source identifier") end
	if not keylayout:match("^<%?xml") or keylayout:find("<!ENTITY", 1, true) then
		return refuse("the compiled layout is not a plain .keylayout")
	end
	local parsed, parse_error = Keylayout.parse(keylayout)
	if parsed == nil then
		return refuse("the compiled layout is not a readable .keylayout: " .. tostring(parse_error))
	end
	-- A preserved import is its own .keylayout; a structured source compiles to ISO
	-- under its internal name (exports.macos.internal_name, else the layout id).
	local imported = type(source.imported_keylayout) == "table" and source.imported_keylayout or nil
	local convention, expected = "iso", layout.id
	local macos = type(source.exports) == "table" and type(source.exports.macos) == "table" and source.exports.macos or {}
	if imported then
		if imported.text ~= keylayout then return refuse("the layout is not the source's imported .keylayout") end
		convention, expected = imported.convention, parsed.name
	elseif type(macos.internal_name) == "string" then
		expected = macos.internal_name
	end
	if not CONVENTIONS[convention] then return refuse("the keycode convention is neither iso nor ansi") end
	if parsed.name ~= expected then return refuse("the compiled layout is not named after the source") end
	return { name = name, keyboard_name = parsed.name, convention = convention }, nil, nil
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
		keyboard_name = checked.keyboard_name or checked.name,
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
	for _, id in ipairs(TableUtil.sorted_keys(env.installed or {})) do
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
---   installed() -> table of installed entries, log(level, message, ...); and,
---   for a driver whose install can report pending_activation (macOS),
---   select_after_login(id) -> recorded.
--- @param env table
--- @return table { open, save, remove }
function M.new(env)
	local settings = env.settings
	local operations = {}

	local function declaration_path()
		return env.config_dir .. settings.folder .. "/" .. settings.declaration_file
	end

	local function source_path()
		return env.config_dir .. settings.folder .. "/" .. settings.source_file
	end

	--- A stored file within its bound, "unreadable" when it is not, nil when absent.
	local function stored(path, bound, what)
		if not env.exists(path) then return nil end
		local text = env.read(path)
		if type(text) ~= "string" or #text > bound then
			env.log("error", "The stored %s %s is unreadable or larger than its bound.", what, path)
			return "unreadable"
		end
		return text
	end

	--- Sends the page what it needs to compose.
	--- @param on_done function on_done(data)
	function operations.open(on_done)
		local text = stored(declaration_path(), settings.max_declaration_bytes, "composition")
		local source = stored(source_path(), settings.max_source_bytes, "layout source")
		M.sources(env.sources_env(), function(sources)
			on_done({
				platform = env.platform,
				sources = sources,
				declaration = text,
				source = source,
				active = env.active_id() == settings.id,
				shortcuts = env.shortcuts,
			})
		end)
	end

	--- Stores a composition or a layout source and installs its layout.
	--- @param payload table { declaration | source, keylayout, use }
	--- @param on_done function on_done(ok, code, detail, used, installed): installed is what the
	---   driver's install reported (the macOS and Linux install results), for the Debug check.
	function operations.save(payload, on_done)
		local checked, code, detail
		local stored_path, stored_text, other_path
		if payload.source ~= nil and payload.declaration ~= nil then
			checked, code, detail = nil, M.FAILURE_INVALID, "a save carries a composition or a source, not both"
		elseif payload.source ~= nil then
			checked, code, detail = M.check_source(settings, env.max_file_bytes, payload.source, payload.keylayout,
				env.decode_toml)
			stored_path, stored_text, other_path = source_path(), payload.source, declaration_path()
		else
			checked, code, detail = M.check(settings, env.max_file_bytes, payload.declaration, payload.keylayout,
				env.decode_json)
			stored_path, stored_text, other_path = declaration_path(), payload.declaration, source_path()
		end
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
			local written, write_err = env.write(stored_path, stored_text)
			if not written then
				env.log("error", "The composition could not be stored: %s.", tostring(write_err))
				on_done(false, M.FAILURE_WRITE, tostring(write_err), false)
				return
			end
			-- The layout now comes from the form just stored; the other one would reopen stale.
			if env.exists(other_path) and not env.delete(other_path) then
				env.log("error", "The replaced composition %s could not be deleted.", other_path)
				on_done(false, M.FAILURE_WRITE, "cannot delete " .. other_path, false)
				return
			end
			local entry = M.entry(settings, checked, payload.keylayout, digest, env.platform)
			env.install(entry, payload.keylayout, function(installed, install_code, install_detail)
				if not installed then
					on_done(false, install_code, install_detail, false)
					return
				end
				if payload.use ~= true and env.active_id() ~= settings.id then
					on_done(true, nil, nil, false, install_code)
					return
				end
				-- macOS lists the layout but turns it on only at the next login:
				-- selecting it now is refused, so the driver selects it then.
				if type(install_code) == "table" and install_code.pending_activation == true then
					if type(env.select_after_login) ~= "function" or not env.select_after_login(settings.id) then
						env.log("error", "The composed layout cannot be selected after the next login.")
						on_done(false, M.FAILURE_USE, "the selection after the next login cannot be recorded", false)
						return
					end
					on_done(true, nil, nil, false, install_code)
					return
				end
				env.select(settings.id, function(selected, select_code, select_detail)
					if not selected then
						on_done(false, M.FAILURE_USE, select_detail or select_code, false)
						return
					end
					on_done(true, nil, nil, true, install_code)
				end)
			end)
		end)
	end

	--- Removes the composition: the installed layout, then its declaration.
	--- @param on_done function on_done(ok, code, detail)
	function operations.remove(on_done)
		local function delete_declaration()
			for _, path in ipairs({ declaration_path(), source_path() }) do
				if env.exists(path) and not env.delete(path) then
					on_done(false, M.FAILURE_WRITE, "cannot delete " .. path)
					return
				end
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
