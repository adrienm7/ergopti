--- _shared/layouts/engine/composer/studio_store.lua

--- ==============================================================================
--- MODULE: Ergopti Studio Layout Store
--- DESCRIPTION:
--- Keeps the personal layouts Ergopti Studio compares (the layouts the user
--- made or imported in its « Comparer » tab) in one JSON file of the layout
--- editor's folder, so they survive the window, a reload and a crash. Shared
--- by the macOS and Linux drivers through their layout registries; Windows'
--- studio_store.ahk applies the same rules. The page's contract is
--- LAYOUT_ANALYSIS_HOST.store (docs/design/layout-analysis.md).
---
--- FEATURES & RATIONALE:
--- 1. Stored as given: the page sends each layout as JSON text and receives
---    that exact text back. The host only reads the layout's id, so a value
---    the Lua JSON model cannot hold (null cells of a key row) is never
---    rewritten.
--- 2. Bounded: an id matches the shared pattern, a layout and the number of
---    layouts are bounded (_shared/layouts/data/defaults.json studio).
--- 3. Fail fast: an unreadable or malformed store refuses every operation
---    with a stable code, and is never replaced by a save, so a damaged file
---    cannot silently lose the user's other layouts.
--- 4. Corpus tables on request: the macOS and Linux hosts inline the page's
---    scripts, so the page cannot load a built-in corpus's generated tables
---    itself; corpus reads the one file of the chosen corpus, by an id that
---    can only name a file of the generated corpus folder, within its bound.
--- 5. One fingering profile per user (the Comparer's « Doigté »): stored as
---    the JSON text the page sent, in its own file, so a damaged profile never
---    touches the layouts; saving none restores the defaults.
--- 6. The editor's workspace (its tabs and their unsaved edits) the same way,
---    in a file of its own, so « Éditer » restores every tab after a reload or
---    a crash (layout_editor/workspace.js owns its content).
--- 7. PURE Lua: the driver injects its file ports.
--- ==============================================================================

local M = {}

local Json = require("core.text.engine.json")
local TableUtil = require("core.text.engine.table_util")

-- A failure code the page receives.
local CODE = "^[a-z_]+$"
-- The store file's schema version.
M.SCHEMA = 1





-- ===========================
-- ===========================
-- ======= 1/ Settings =======
-- ===========================
-- ===========================

--- Validates the studio table of the shared layout defaults.
--- @param layout_defaults table Decoded _shared/layouts/data/defaults.json.
--- @return table|nil settings { folder, file, id_pattern, id_max_length,
---   max_layouts, max_layout_bytes, corpus_folder, corpus_prefix,
---   corpus_id_pattern, max_corpus_bytes, profile_file, max_profile_bytes,
---   workspace_file, max_workspace_bytes, failures = { invalid, write, unreadable, corpus } }
--- @return string|nil error
function M.settings(layout_defaults)
	local source = type(layout_defaults) == "table" and layout_defaults.source or nil
	local studio = type(layout_defaults) == "table" and layout_defaults.studio or nil
	if type(source) ~= "table" or type(studio) ~= "table" then
		return nil, "the layout defaults have no source or studio table"
	end
	for _, value in ipairs({ source.folder, studio.file, studio.profile_file, studio.workspace_file }) do
		if type(value) ~= "string" or not value:match("^[A-Za-z0-9._-]+$") then
			return nil, "the studio folder or file is not a plain name"
		end
	end
	for _, field in ipairs({ "id_pattern", "corpus_id_pattern" }) do
		local pattern = studio[field]
		if type(pattern) ~= "string" or pattern:sub(1, 1) ~= "^" or pattern:sub(-1) ~= "$" then
			return nil, "the studio " .. field .. " is not an anchored pattern"
		end
	end
	if type(studio.corpus_folder) ~= "string" or not studio.corpus_folder:match("^[a-z0-9_]+[a-z0-9_/]*[a-z0-9_]$")
		or studio.corpus_folder:find("//", 1, true) then
		return nil, "the studio corpus_folder is not a plain relative folder"
	end
	if type(studio.corpus_prefix) ~= "string" or not studio.corpus_prefix:match("^[a-z0-9_]+$") then
		return nil, "the studio corpus_prefix is not a plain name"
	end
	for _, field in ipairs({ "id_max_length", "max_layouts", "max_layout_bytes", "max_corpus_bytes",
		"max_profile_bytes", "max_workspace_bytes" }) do
		local value = studio[field]
		if type(value) ~= "number" or value <= 0 or value % 1 ~= 0 then
			return nil, "the studio " .. field .. " is not a positive integer"
		end
	end
	local failures = studio.failures
	for _, code in ipairs({ "invalid", "write", "unreadable", "corpus" }) do
		if type(failures) ~= "table" or type(failures[code]) ~= "string" or not failures[code]:match(CODE) then
			return nil, "the studio failures name no " .. code .. " code"
		end
	end
	return {
		folder = source.folder,
		file = studio.file,
		id_pattern = studio.id_pattern,
		id_max_length = studio.id_max_length,
		max_layouts = studio.max_layouts,
		max_layout_bytes = studio.max_layout_bytes,
		corpus_folder = studio.corpus_folder,
		corpus_prefix = studio.corpus_prefix,
		corpus_id_pattern = studio.corpus_id_pattern,
		max_corpus_bytes = studio.max_corpus_bytes,
		profile_file = studio.profile_file,
		max_profile_bytes = studio.max_profile_bytes,
		workspace_file = studio.workspace_file,
		max_workspace_bytes = studio.max_workspace_bytes,
		failures = { invalid = failures.invalid, write = failures.write, unreadable = failures.unreadable,
			corpus = failures.corpus },
	}, nil
end

--- Whether an id is one the store keeps.
--- @param settings table From M.settings.
--- @param id any
--- @return boolean
function M.valid_id(settings, id)
	return type(id) == "string" and #id <= settings.id_max_length and id:match(settings.id_pattern) ~= nil
end

--- Checks one layout the page saves: its JSON text names the id it is saved under.
--- @param settings table From M.settings.
--- @param payload table { id, text }
--- @return boolean ok
--- @return string|nil detail Why it is refused.
function M.check(settings, payload)
	if type(payload) ~= "table" then return false, "the save request is not a table" end
	if not M.valid_id(settings, payload.id) then return false, "the layout id is not a personal layout id" end
	local text = payload.text
	if type(text) ~= "string" or text == "" then return false, "the layout is empty" end
	if #text > settings.max_layout_bytes then return false, "the layout is larger than its bound" end
	local ok, layout = pcall(Json.decode, text)
	if not ok or type(layout) ~= "table" then return false, "the layout is not a JSON object" end
	if layout.id ~= payload.id then return false, "the layout names another id" end
	return true, nil
end





-- =================================
-- =================================
-- ======= 2/ The store file =======
-- =================================
-- =================================

--- Decodes the store file.
--- @param settings table From M.settings.
--- @param text string The file's text.
--- @return table|nil layouts id -> JSON text.
--- @return string|nil detail Why the file is refused.
local function decode(settings, text)
	local ok, data = pcall(Json.decode, text)
	if not ok or type(data) ~= "table" or data.schema ~= M.SCHEMA or type(data.layouts) ~= "table" then
		return nil, "the store is not a schema " .. M.SCHEMA .. " layout store"
	end
	local layouts, count = {}, 0
	for id, layout_text in pairs(data.layouts) do
		if not M.valid_id(settings, id) or type(layout_text) ~= "string" then
			return nil, "the store holds an entry that is not a personal layout"
		end
		layouts[id], count = layout_text, count + 1
	end
	if count > settings.max_layouts then return nil, "the store holds more layouts than its bound" end
	return layouts, nil
end

--- The store file's text.
--- @param layouts table id -> JSON text.
--- @return string
local function encode(layouts)
	return Json.encode({ schema = M.SCHEMA, layouts = layouts }) .. "\n"
end

--- Creates the list, save and remove operations over a driver's ports.
--- env: settings (M.settings), config_dir and shared_dir (each with a trailing slash),
---   exists(path), read_bounded(path, max_bytes) -> text|nil, status, detail,
---   write(path, text) -> ok, err (atomic, creating the folder),
---   log(level, message, ...).
--- @param env table
--- @return table { list, save, remove, path, corpus, profile_load, profile_save, profile_path,
---   workspace_load, workspace_save, workspace_path }
function M.new(env)
	local settings = env.settings
	for _, port in ipairs({ "exists", "read_bounded", "write", "log" }) do
		if type(env[port]) ~= "function" then error("studio_store.new: env." .. port .. " is required", 2) end
	end
	for _, dir in ipairs({ "config_dir", "shared_dir" }) do
		if type(env[dir]) ~= "string" or env[dir]:sub(-1) ~= "/" then
			error("studio_store.new: env." .. dir .. " must be a folder with a trailing slash", 2)
		end
	end
	local operations = {}

	local function path()
		return env.config_dir .. settings.folder .. "/" .. settings.file
	end
	operations.path = path

	-- The stored layouts, or nil and the failure for an unreadable store. An
	-- absent store is an empty one.
	local function load()
		local file = path()
		if not env.exists(file) then return {}, nil end
		local bound = settings.max_layouts * (settings.max_layout_bytes * 2 + settings.id_max_length + 8) + 64
		local text, status, detail = env.read_bounded(file, bound)
		if type(text) ~= "string" or status ~= "ok" then
			return nil, string.format("%s could not be read (%s %s)", file, tostring(status), tostring(detail))
		end
		local layouts, refusal = decode(settings, text)
		if not layouts then return nil, string.format("%s: %s", file, refusal) end
		return layouts, nil
	end

	--- Every stored layout, sorted by id.
	--- @param on_done function on_done(ok, texts_or_code, detail)
	function operations.list(on_done)
		local layouts, failure = load()
		if not layouts then
			env.log("error", "The Ergopti Studio layouts are unreadable: %s.", failure)
			on_done(false, settings.failures.unreadable, failure)
			return
		end
		local texts = {}
		for index, id in ipairs(TableUtil.sorted_keys(layouts)) do texts[index] = layouts[id] end
		on_done(true, texts, nil)
	end

	--- Stores one layout, replacing the one with the same id.
	--- @param payload table { id, text }
	--- @param on_done function on_done(ok, code, detail)
	function operations.save(payload, on_done)
		local ok, refusal = M.check(settings, payload)
		if not ok then
			env.log("warn", "Refused an Ergopti Studio layout: %s.", refusal)
			on_done(false, settings.failures.invalid, refusal)
			return
		end
		local layouts, failure = load()
		if not layouts then
			env.log("error", "An Ergopti Studio layout was not saved over an unreadable store: %s.", failure)
			on_done(false, settings.failures.unreadable, failure)
			return
		end
		local count = 0
		for id in pairs(layouts) do if id ~= payload.id then count = count + 1 end end
		if count >= settings.max_layouts then
			on_done(false, settings.failures.invalid, "the store already holds its maximum number of layouts")
			return
		end
		layouts[payload.id] = payload.text
		local written, write_err = env.write(path(), encode(layouts))
		if not written then
			env.log("error", "The Ergopti Studio layouts could not be written: %s.", tostring(write_err))
			on_done(false, settings.failures.write, tostring(write_err))
			return
		end
		env.log("info", "Ergopti Studio layout saved: %s.", payload.id)
		on_done(true, nil, payload.id)
	end

	--- Removes one layout; an id the store does not hold is already removed.
	--- @param payload table { id }
	--- @param on_done function on_done(ok, code, detail)
	function operations.remove(payload, on_done)
		if type(payload) ~= "table" or not M.valid_id(settings, payload.id) then
			on_done(false, settings.failures.invalid, "the layout id is not a personal layout id")
			return
		end
		local layouts, failure = load()
		if not layouts then
			env.log("error", "An Ergopti Studio layout was not removed from an unreadable store: %s.", failure)
			on_done(false, settings.failures.unreadable, failure)
			return
		end
		if layouts[payload.id] == nil then
			on_done(true, nil, payload.id)
			return
		end
		layouts[payload.id] = nil
		local written, write_err = env.write(path(), encode(layouts))
		if not written then
			env.log("error", "The Ergopti Studio layouts could not be written: %s.", tostring(write_err))
			on_done(false, settings.failures.write, tostring(write_err))
			return
		end
		env.log("info", "Ergopti Studio layout removed: %s.", payload.id)
		on_done(true, nil, payload.id)
	end

	--- The generated tables of one built-in corpus, as the JavaScript the page runs.
	--- On success the third value is the code the page receives when the host
	--- cannot run that text, so every refusal code stays in the defaults.
	--- @param payload table { id }
	--- @param on_done function on_done(ok, text_or_code, detail_or_code)
	function operations.corpus(payload, on_done)
		local id = type(payload) == "table" and payload.id or nil
		if type(id) ~= "string" or #id > settings.id_max_length or not id:match(settings.corpus_id_pattern) then
			env.log("warn", "Refused an Ergopti Studio corpus request without a corpus id.")
			on_done(false, settings.failures.corpus, "the corpus id is not a built-in corpus id")
			return
		end
		local file = env.shared_dir .. settings.corpus_folder .. "/" .. settings.corpus_prefix .. id .. ".js"
		if not env.exists(file) then
			env.log("warn", "Ergopti Studio has no built-in corpus %s.", id)
			on_done(false, settings.failures.corpus, file .. " does not exist")
			return
		end
		local text, status, detail = env.read_bounded(file, settings.max_corpus_bytes)
		if type(text) ~= "string" or status ~= "ok" then
			local failure = string.format("%s could not be read (%s %s)", file, tostring(status), tostring(detail))
			env.log("error", "An Ergopti Studio corpus is unreadable: %s.", failure)
			on_done(false, settings.failures.corpus, failure)
			return
		end
		on_done(true, text, settings.failures.corpus)
	end

	--- Loads and saves one JSON object the page keeps as given in its own file
	--- of the source folder ({ schema, <field> = text }), so a damaged file
	--- never touches the layouts and is never replaced by a load.
	--- @param file string The file name.
	--- @param max_bytes number The bound of the page's text.
	--- @param field string The field of the file that holds the text.
	--- @param label string What the logs call it.
	--- @return function path, function load(on_done), function save(payload, on_done)
	local function json_document(file, max_bytes, field, label)
		local function document_path()
			return env.config_dir .. settings.folder .. "/" .. file
		end

		local function load(on_done)
			local target = document_path()
			if not env.exists(target) then
				on_done(true, nil, nil)
				return
			end
			-- The file holds the text JSON-encoded: each quote, backslash, newline or
			-- tab doubles, and the page sends JSON, whose text has no other control.
			local text, status, detail = env.read_bounded(target, max_bytes * 2 + 64)
			local failure
			if type(text) ~= "string" or status ~= "ok" then
				failure = string.format("%s could not be read (%s %s)", target, tostring(status), tostring(detail))
			else
				local ok, data = pcall(Json.decode, text)
				if not ok or type(data) ~= "table" or data.schema ~= M.SCHEMA
					or (data[field] ~= nil and type(data[field]) ~= "string") then
					failure = target .. " is not a schema " .. M.SCHEMA .. " " .. label
				else
					on_done(true, data[field], nil)
					return
				end
			end
			env.log("error", "The Ergopti Studio %s is unreadable: %s.", label, failure)
			on_done(false, settings.failures.unreadable, failure)
		end

		local function save(payload, on_done)
			local reset = type(payload) == "table" and payload.reset == true
			local text = (type(payload) == "table" and not reset) and payload.text or nil
			if not reset then
				local refusal
				if type(text) ~= "string" or text == "" then
					refusal = "the " .. label .. " is empty"
				elseif #text > max_bytes then
					refusal = "the " .. label .. " is larger than its bound"
				else
					-- Lua decodes an array to a table too: an object starts with « { ».
					local ok, decoded = pcall(Json.decode, text)
					if not ok or type(decoded) ~= "table" or not text:match("^%s*{") then
						refusal = "the " .. label .. " is not a JSON object"
					end
				end
				if refusal then
					env.log("warn", "Refused an Ergopti Studio %s: %s.", label, refusal)
					on_done(false, settings.failures.invalid, refusal)
					return
				end
			end
			local written, write_err = env.write(document_path(), Json.encode({ schema = M.SCHEMA, [field] = text }) .. "\n")
			if not written then
				env.log("error", "The Ergopti Studio %s could not be written: %s.", label, tostring(write_err))
				on_done(false, settings.failures.write, tostring(write_err))
				return
			end
			env.log("info", text and "Ergopti Studio %s saved." or "Ergopti Studio %s reset.", label)
			on_done(true, nil, nil)
		end

		return document_path, load, save
	end

	--- The user's fingering profile (the Comparer's « Doigté »): load(on_done)
	--- answers on_done(ok, text_or_code, detail), nil text for the defaults;
	--- save({ text } | { reset = true }, on_done) answers on_done(ok, code, detail).
	operations.profile_path, operations.profile_load, operations.profile_save =
		json_document(settings.profile_file, settings.max_profile_bytes, "profile", "fingering profile")

	--- The editor's open tabs and their unsaved edits (« Éditer »), saved as the
	--- page types so a reload or a crash restores them; same contract as the
	--- profile, nil text when nothing was saved yet.
	operations.workspace_path, operations.workspace_load, operations.workspace_save =
		json_document(settings.workspace_file, settings.max_workspace_bytes, "workspace", "editor workspace")

	return operations
end

-- The documents a registry offers: name -> the operations of M.new that load and save it.
local DOCUMENTS = { "profile", "workspace" }

--- Adds the registry entry points of the Studio's documents, the same on macOS
--- and Linux: registry.studio_<name>_load(on_done, deps) and
--- registry.studio_<name>_save(payload, on_done, deps) for the fingering
--- profile and the editor's workspace, each dispatched to the store's
--- <name>_load and <name>_save, or refused with failure_code when the store
--- is unusable.
--- @param registry table The driver's layout registry module.
--- @param with_studio function with_studio(deps, run(operations), refuse(detail)) -> dispatched.
--- @param failure_code string The code a refused call answers.
function M.document_entries(registry, with_studio, failure_code)
	for _, name in ipairs(DOCUMENTS) do
		registry["studio_" .. name .. "_load"] = function(on_done, deps)
			return with_studio(deps, function(operations) operations[name .. "_load"](on_done) end,
				function(detail) on_done(false, failure_code, detail) end)
		end
		registry["studio_" .. name .. "_save"] = function(payload, on_done, deps)
			return with_studio(deps, function(operations) operations[name .. "_save"](payload, on_done) end,
				function(detail) on_done(false, failure_code, detail) end)
		end
	end
end

return M
