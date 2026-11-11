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
--- 6. A source can also be stored for the layout emulation alone (store): the
---    source, its compiled .keylayout (keylayout_file) and its emulation table
---    are written to the composer folder and nothing is installed in the
---    system, so emulating needs no admin and no input source; the emulation
---    reads that copy (read_composed) while the composed layout is not installed.
--- ==============================================================================

local Registry = require("layouts.registry")
local Keylayout = require("layouts.keylayout")
local TableUtil = require("table_util")
local SourceEmulation = require("layouts.source_emulation")

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
---   max_source_bytes, emulation_file, max_emulation_bytes, keylayout_file, family }
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
	if type(composer.emulation_file) ~= "string" or not composer.emulation_file:match("^[A-Za-z0-9._-]+$")
		or composer.emulation_file == composer.declaration_file or composer.emulation_file == composer.source_file then
		return nil, "the composer emulation file is not a plain file name distinct from the other two"
	end
	local named = { [composer.declaration_file] = true, [composer.source_file] = true, [composer.emulation_file] = true }
	if type(composer.keylayout_file) ~= "string" or not composer.keylayout_file:match("^[A-Za-z0-9._-]+%.keylayout$")
		or named[composer.keylayout_file] then
		return nil, "the composer keylayout file is not a plain .keylayout file name distinct from the other three"
	end
	for _, field in ipairs({ "max_declaration_bytes", "max_source_bytes", "max_emulation_bytes" }) do
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
		emulation_file = composer.emulation_file,
		max_emulation_bytes = composer.max_emulation_bytes,
		keylayout_file = composer.keylayout_file,
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

--- Checks the emulation table the page sends beside a source: the shared
--- compiler's table of that layout for this platform, which the engine compiles.
--- @param settings table From M.settings.
--- @param emulation_text any The table's JSON as the page wrote it.
--- @param source_text string The source it was compiled from (already checked).
--- @param platform string "macos" or "linux".
--- @param decode_json function
--- @param decode_toml function
--- @return boolean|nil ok
--- @return string|nil code M.FAILURE_INVALID
--- @return string|nil detail
function M.check_emulation(settings, emulation_text, source_text, platform, decode_json, decode_toml)
	local function refuse(why) return nil, M.FAILURE_INVALID, why end
	if type(emulation_text) ~= "string" then return refuse("the emulation table must be sent as text") end
	if #emulation_text > settings.max_emulation_bytes then
		return refuse("the emulation table is larger than " .. settings.max_emulation_bytes .. " bytes")
	end
	local ok, table_ = pcall(decode_json, emulation_text)
	if not ok or type(table_) ~= "table" then return refuse("the emulation table is not valid JSON") end
	local compiled, compile_err = pcall(SourceEmulation.compile, table_)
	if not compiled then return refuse("the emulation table cannot be performed: " .. tostring(compile_err)) end
	local source = decode_toml(source_text)
	if table_.layout ~= source.layout.id then return refuse("the emulation table is not the source's") end
	if table_.platform ~= platform then return refuse("the emulation table is not compiled for " .. platform) end
	return true, nil, nil
end

--- The emulation table stored beside the composed layout's source, decoded.
--- @param settings table From M.settings.
--- @param config_dir string The configuration folder, with a trailing slash.
--- @param ports table { exists(path), read(path), decode_json(text) }
--- @return table|nil table_ nil when none is stored.
--- @return string|nil error Why a stored table cannot be read.
function M.read_emulation(settings, config_dir, ports)
	local path = config_dir .. settings.folder .. "/" .. settings.emulation_file
	if not ports.exists(path) then return nil, nil end
	local text = ports.read(path)
	if type(text) ~= "string" or #text > settings.max_emulation_bytes then
		return nil, "the stored emulation table " .. path .. " is unreadable or larger than its bound"
	end
	local ok, table_ = pcall(ports.decode_json, text)
	if not ok or type(table_) ~= "table" then return nil, "the stored emulation table " .. path .. " is not JSON" end
	return table_, nil
end

--- The composed layout stored for the emulation alone (operations.store): the
--- stored source's compiled .keylayout and its keycode convention, checked again
--- as a save checks them, since the files may have been edited by hand.
--- @param settings table From M.settings.
--- @param config_dir string The configuration folder, with a trailing slash.
--- @param max_file_bytes number The registry's bound of one layout file.
--- @param ports table { exists(path), read(path), decode_toml(text) }
--- @return table|nil composed { text, convention } nil when none is stored.
--- @return string|nil error Why a stored copy cannot be read.
function M.read_composed(settings, config_dir, max_file_bytes, ports)
	local folder = config_dir .. settings.folder .. "/"
	local keylayout_path, source_path = folder .. settings.keylayout_file, folder .. settings.source_file
	if not ports.exists(keylayout_path) then return nil, nil end
	local text, source = ports.read(keylayout_path), ports.exists(source_path) and ports.read(source_path) or nil
	if type(text) ~= "string" or type(source) ~= "string" then
		return nil, "the stored composed layout " .. keylayout_path .. " or its source is unreadable"
	end
	local checked, _, detail = M.check_source(settings, max_file_bytes, source, text, ports.decode_toml)
	if not checked then return nil, "the stored composed layout is refused: " .. tostring(detail) end
	return { text = text, convention = checked.convention }, nil
end

--- read_composed over a driver's resolved registry collaborators, for the two
--- registries' composer_copy.
--- @param settings table|nil From M.settings (nil when the defaults are unreadable).
--- @param config_dir string
--- @param resolved table { settings = { max_file_bytes }, exists(path), read(path) }
--- @param decode_toml function
--- @return table|nil composed
--- @return string|nil error
function M.registry_copy(settings, config_dir, resolved, decode_toml)
	if settings == nil then return nil, "the composer settings are unreadable" end
	return M.read_composed(settings, config_dir, resolved.settings.max_file_bytes,
		{ exists = resolved.exists, read = resolved.read, decode_toml = decode_toml })
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

	local function emulation_path()
		return env.config_dir .. settings.folder .. "/" .. settings.emulation_file
	end

	local function keylayout_copy_path()
		return env.config_dir .. settings.folder .. "/" .. settings.keylayout_file
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

	--- Stores a composition or a layout source (with its emulation table, when
	--- the source has records no .keylayout holds) and installs its layout.
	--- @param payload table { declaration | source [, emulation], keylayout, use }
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
			if checked and payload.emulation ~= nil then
				local emulation_ok, emulation_code, emulation_detail = M.check_emulation(settings, payload.emulation,
					payload.source, env.platform, env.decode_json, env.decode_toml)
				if not emulation_ok then checked, code, detail = nil, emulation_code, emulation_detail end
			end
			stored_path, stored_text, other_path = source_path(), payload.source, declaration_path()
		elseif payload.emulation ~= nil then
			checked, code, detail = nil, M.FAILURE_INVALID, "an emulation table comes only with a source"
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
			-- The layout now comes from the form just stored; the other one would reopen
			-- stale, and an emulation table belongs to the source it was sent with.
			if payload.emulation ~= nil then
				local emulation_written, emulation_err = env.write(emulation_path(), payload.emulation)
				if not emulation_written then
					env.log("error", "The emulation table could not be stored: %s.", tostring(emulation_err))
					on_done(false, M.FAILURE_WRITE, tostring(emulation_err), false)
					return
				end
			end
			local stale = { other_path }
			if payload.emulation == nil then stale[#stale + 1] = emulation_path() end
			for _, path in ipairs(stale) do
				if env.exists(path) and not env.delete(path) then
					env.log("error", "The replaced composition %s could not be deleted.", path)
					on_done(false, M.FAILURE_WRITE, "cannot delete " .. path, false)
					return
				end
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

	--- Stores a layout source for the layout emulation alone: the source, its
	--- compiled .keylayout and its emulation table go to the composer folder and
	--- nothing is installed in the system (no admin, no input source). The
	--- emulation reads that copy while the composed layout is not installed.
	--- @param payload table { source, keylayout [, emulation] }
	--- @param on_done function on_done(ok, code, detail, id)
	function operations.store(payload, on_done)
		local checked, code, detail
		if payload.declaration ~= nil or payload.source == nil then
			checked, code, detail = nil, M.FAILURE_INVALID, "the emulation alone stores a layout source"
		else
			checked, code, detail = M.check_source(settings, env.max_file_bytes, payload.source, payload.keylayout,
				env.decode_toml)
			if checked and payload.emulation ~= nil then
				local emulation_ok, emulation_code, emulation_detail = M.check_emulation(settings, payload.emulation,
					payload.source, env.platform, env.decode_json, env.decode_toml)
				if not emulation_ok then checked, code, detail = nil, emulation_code, emulation_detail end
			end
		end
		if not checked then
			env.log("error", "The layout source to emulate was refused: %s.", tostring(detail))
			on_done(false, code, detail)
			return
		end
		local writes = { { source_path(), payload.source }, { keylayout_copy_path(), payload.keylayout } }
		if payload.emulation ~= nil then writes[#writes + 1] = { emulation_path(), payload.emulation } end
		for _, write in ipairs(writes) do
			local written, write_err = env.write(write[1], write[2])
			if not written then
				env.log("error", "The layout source to emulate could not be stored: %s.", tostring(write_err))
				on_done(false, M.FAILURE_WRITE, tostring(write_err))
				return
			end
		end
		local stale = { declaration_path() }
		if payload.emulation == nil then stale[#stale + 1] = emulation_path() end
		for _, path in ipairs(stale) do
			if env.exists(path) and not env.delete(path) then
				env.log("error", "The replaced composition %s could not be deleted.", path)
				on_done(false, M.FAILURE_WRITE, "cannot delete " .. path)
				return
			end
		end
		on_done(true, nil, nil, settings.id)
	end

	--- Removes the composition: the installed layout, then its declaration.
	--- @param on_done function on_done(ok, code, detail)
	function operations.remove(on_done)
		local function delete_declaration()
			for _, path in ipairs({ declaration_path(), source_path(), emulation_path(), keylayout_copy_path() }) do
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
