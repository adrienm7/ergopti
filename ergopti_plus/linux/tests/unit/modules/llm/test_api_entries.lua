--- tests/unit/modules/llm/test_api_entries.lua

--- ==============================================================================
--- MODULE: Where The API Keys Live
--- DESCRIPTION:
--- The keys a user adds are stored in one file only its owner can read, kept
--- apart from the configuration folder (which may be synced), and a crash or
--- a malformed file never silently loses or exposes them.
--- ==============================================================================

local helpers = require("tests.helpers")
local WinCompat = require("tests.win_compat")

local DIR = os.tmpname()
os.remove(DIR)
local PATH = DIR .. "/api_keys.json"

-- A Windows checkout has no POSIX permission bits and no open(2) with a mode
-- to set them: the store's logic runs there on a primitive that creates the
-- file with the same refusal of an existing path, and only the mode test is
-- deferred. On Linux the store keeps its libc primitive, and a missing FFI or
-- stat(1) is a failure.
local ON_WINDOWS = WinCompat.is_windows()

--- Creates a new file, refusing an existing one as O_EXCL does.
--- @param path string
--- @param text string
--- @return boolean ok, string|nil err
local function create_without_mode(path, text)
	local existing = io.open(path, "rb")
	if existing then
		existing:close()
		return false, "cannot create " .. path
	end
	local fh, open_error = io.open(path, "wb")
	if not fh then return false, tostring(open_error) end
	fh:write(text)
	fh:close()
	return true
end

--- A fresh store on the test file.
--- @param keep boolean|nil Keep the file from the previous load.
--- @return table
local function fresh(keep)
	if not keep then os.execute("rm -rf '" .. DIR .. "'") end
	local entries = helpers.load_module("modules.llm.api_entries")
	entries._set_path_for_test(PATH)
	if ON_WINDOWS then entries._set_private_create_for_test(create_without_mode) end
	return entries
end

--- The octal permission bits of a file.
--- @param path string
--- @return string
local function mode_of(path)
	local pipe = io.popen("stat -c %a '" .. path .. "'")
	local mode = pipe:read("*l")
	pipe:close()
	return mode
end

helpers.describe("api_entries: a private, durable store", function()

	if ON_WINDOWS then
		helpers.it("SKIP [CONF-LINUX-POSIX-FILE-MODE] — a Windows host has no POSIX mode bits for the 0600 key file", function()
			-- Deferred on Windows only: the branch must never be the one a
			-- Linux run takes, where the mode is the point of the file.
			helpers.assert_eq(package.config:sub(1, 1), "\\",
				"this deferral runs only on a host whose separator is Windows'")
		end)
	else
		helpers.it("creates the file readable by its owner only", function()
			local entries = fresh()
			helpers.assert_true(entries.add({ provider = "cerebras", token = "csk-secret", label = "Cerebras" }) ~= nil)
			helpers.assert_eq(mode_of(PATH), "600")
		end)
	end

	helpers.it("keeps the entries and the selection across a restart", function()
		local entries = fresh()
		entries.add({ provider = "cerebras", token = "a", label = "Cerebras" })
		local second = entries.add({ provider = "mistral", token = "b", label = "Mistral", model = "m" })
		local reloaded = fresh(true)
		helpers.assert_eq(#reloaded.list(), 2)
		helpers.assert_eq(reloaded.active().id, second.id, "the last added entry is selected")
		helpers.assert_eq(reloaded.active().model, "m")
	end)

	-- The tray names entries itself (api-entry-auto-name): the stored label is
	-- kept as written for older builds, never made unique by the store.
	helpers.it("stores the label it is given", function()
		local entries = fresh()
		entries.add({ provider = "cerebras", token = "a", label = "cerebras/qwen" })
		local second = entries.add({ provider = "cerebras", token = "b", label = "cerebras/qwen" })
		helpers.assert_eq(second.label, "cerebras/qwen")
	end)

	helpers.it("removing the selected entry leaves none selected", function()
		local entries = fresh()
		local entry = entries.add({ provider = "cerebras", token = "a", label = "Cerebras" })
		helpers.assert_true(entries.remove(entry.id))
		helpers.assert_nil(fresh(true).active())
		local fh = io.open(PATH, "r")
		local text = fh:read("*a")
		fh:close()
		helpers.assert_eq(text:find('"a"', 1, true), nil, "the removed key is gone from the file")
	end)

	helpers.it("refuses an entry without a key", function()
		local entries = fresh()
		helpers.assert_nil(entries.add({ provider = "cerebras", token = "", label = "Cerebras" }))
		helpers.assert_eq(#entries.list(), 0)
	end)

	helpers.it("loads without the FFI, which only its libc primitive needs", function()
		-- The FFI exists under LuaJIT alone. Required at load, it kept the whole
		-- store, its logic included, out of reach of every other interpreter.
		os.execute("rm -rf '" .. DIR .. "'")
		local saved_loaded, saved_preload = package.loaded.ffi, package.preload.ffi
		package.loaded.ffi = nil
		package.preload.ffi = function() error("no FFI on this interpreter") end
		local loaded, entries = pcall(helpers.load_module, "modules.llm.api_entries")
		package.preload.ffi = saved_preload
		package.loaded.ffi = saved_loaded
		helpers.assert_true(loaded, "the store must load without the FFI: " .. tostring(entries))
		entries._set_path_for_test(PATH)
		entries._set_private_create_for_test(create_without_mode)
		local entry = entries.add({ provider = "cerebras", token = "a", label = "Cerebras" })
		helpers.assert_eq(entry and entry.label, "Cerebras")
		helpers.assert_eq(fresh(true).active().id, entry.id, "the entry reached the file")
	end)

	helpers.it("keeps a malformed file aside instead of overwriting it", function()
		fresh()
		os.execute("mkdir -p '" .. DIR .. "' && printf 'not json' > '" .. PATH .. "'")
		local entries = fresh(true)
		helpers.assert_eq(#entries.list(), 0)
		local aside = io.open(PATH .. ".corrupt", "r")
		helpers.assert_true(aside ~= nil, "the unreadable file is preserved for the user")
		if aside then aside:close() end
		os.execute("rm -rf '" .. DIR .. "'")
	end)

	--- Writes api_keys.json as another build left it and captures the ERRORs.
	--- @param document table Decoded file.
	--- @param body function body(entries, errors, bytes)
	local function with_stored(document, body)
		fresh()
		local Json = require("json")
		os.execute("mkdir -p '" .. DIR .. "'")
		local bytes = Json.encode(document)
		local fh = assert(io.open(PATH, "w"))
		fh:write(bytes)
		fh:close()
		local Logger = require("logger.shim")
		local real_error, errors = Logger.error, {}
		Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		require("config_outdated").reset_for_tests()
		local ok, err = pcall(body, fresh(true), errors, bytes)
		Logger.error = real_error
		os.execute("rm -rf '" .. DIR .. "'")
		if not ok then error(err, 0) end
	end

	--- The file's current bytes.
	--- @return string
	local function stored_bytes()
		local fh = assert(io.open(PATH, "rb"))
		local text = fh:read("*a")
		fh:close()
		return text
	end

	for label, document in pairs({
		["entries keyed by id"] = { version = 1, active_id = "a",
			entries = { a = { id = "a", provider = "cerebras", label = "A", token = "csk-keyed" } } },
		["typed future selection"] = { version = 1, active_id = { future = true },
			entries = { { id = "a", provider = "cerebras", label = "A", token = "csk-selection" } } },
		["another version"] = { version = 2, active_id = "a",
			entries = { { id = "a", provider = "cerebras", label = "A", token = "csk-v2", scopes = { "chat" } } } },
	}) do
		helpers.it("never rewrites a file it cannot write back whole: " .. label .. " (config-outdated-api-keys-write)",
			function()
				-- The next add, selection or removal wrote `entries: []` over a
				-- keyed list, or a v1 file over a v2 one: every key lost.
				with_stored(document, function(entries, errors, bytes)
					helpers.assert_eq(entries.add({ provider = "cerebras", token = "csk-new", label = "New" }), nil)
					helpers.assert_eq(entries.remove("a"), false)
					helpers.assert_eq(stored_bytes(), bytes, "the file is left byte for byte")
					helpers.assert_true(#errors >= 1, "the refusal is an ERROR")
					for _, line in ipairs(errors) do helpers.assert_contains(line, PATH) end
				end)
			end)
	end

	helpers.it("writes back each entry's fields and a warned selection unchanged (config-outdated-api-keys-write)",
		function()
			with_stored({ version = 1, active_id = "gone", entries = {
				{ id = "a", provider = "cerebras", label = "A", token = "csk-a", note = "keep me" },
				{ id = "b", provider = "cerebras", label = "B", token = "csk-b" },
			} }, function(entries, errors)
				helpers.assert_true(entries.remove("b"))
				local stored = require("json").decode(stored_bytes())
				helpers.assert_eq(stored.entries[1].note, "keep me", "a field this build does not use is kept")
				helpers.assert_eq(stored.active_id, "gone", "a warned selection is not replaced by an unrelated write")
				helpers.assert_true(entries.set_active("a"))
				helpers.assert_eq(require("json").decode(stored_bytes()).active_id, "a", "the user's choice replaces it")
				helpers.assert_eq(errors, {})
			end)
		end)

	helpers.it("warns about an older build's entry and never deletes its key (config-outdated-api-keys)", function()
		fresh()
		local Json = require("json")
		os.execute("mkdir -p '" .. DIR .. "'")
		local fh = assert(io.open(PATH, "w"))
		fh:write(Json.encode({ version = 1, active_id = "gone", entries = {
			{ id = "old-1", provider = "openai", label = "Old", key = "sk-legacy-secret" },
			{ id = "new-1", provider = "cerebras", label = "Cerebras", token = "csk-live" },
		} }))
		fh:close()
		local Logger = require("logger.shim")
		local real_warn, real_error, warnings, errors = Logger.warn, Logger.error, {}, {}
		Logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
		Logger.error = function(_, fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
		require("config_outdated").reset_for_tests()
		local ok, err = pcall(function()
			local entries = fresh(true)
			helpers.assert_eq(#entries.list(), 1, "the usable entry still loads")
			helpers.assert_nil(entries.active(), "a dangling selection selects nothing")
			helpers.assert_eq(errors, {})
			local text = table.concat(warnings, "\n")
			helpers.assert_eq(#warnings, 2, text)
			helpers.assert_contains(text, "'entries[id=old-1]' in '" .. PATH .. "'")
			helpers.assert_contains(text, "'active_id' in '" .. PATH .. "'")
			helpers.assert_true(text:find("sk-legacy-secret", 1, true) == nil, "a key never reaches a log")
			helpers.assert_true(entries.set_active("new-1"))
			local stored = Json.decode(assert(io.open(PATH, "r")):read("*a"))
			helpers.assert_eq(#stored.entries, 2, "a save keeps the outdated entry")
			helpers.assert_eq(stored.entries[1].id, "old-1", "the foreign row retains its original position")
			helpers.assert_eq(stored.entries[2].id, "new-1", "the owned row retains its original position")
			helpers.assert_eq(stored.entries[1].key, "sk-legacy-secret", "its key is never deleted")
		end)
		Logger.warn, Logger.error = real_warn, real_error
		os.execute("rm -rf '" .. DIR .. "'")
		if not ok then error(err, 0) end
	end)

end)


helpers.describe("Local API optional authentication: durable identity (local-api-optional-auth) (local-api-optional-auth)", function()
	helpers.it("saves and reloads a keyless known local provider with its custom address (local-api-optional-auth)", function()
		local entries = fresh()
		local added = entries.add({ provider = "lmstudio", token = "", label = "lmstudio/fixture-model",
			model = "fixture-model", base_url = "http://127.0.0.1:19273/v1" })
		helpers.assert_true(added ~= nil, "known local provider accepts an explicitly empty key")
		local restarted = fresh(true)
		helpers.assert_eq(restarted.active().provider, "lmstudio")
		helpers.assert_eq(restarted.active().token, "")
		helpers.assert_eq(restarted.active().base_url, "http://127.0.0.1:19273/v1")
	end)

	helpers.it("keeps foreign rows and nested fields at their original positions during selection (local-api-optional-auth)", function()
		local entries = fresh()
		local first = assert(entries.add({ provider = "cerebras", token = "private-a", label = "first" }))
		local fh = assert(io.open(PATH, "wb"))
		fh:write(require("json").encode({ version = 1, active_id = first.id, entries = {
			{ id = first.id, provider = "cerebras", token = "private-a", label = "first", future = { flag = true } },
			{ id = "future-row", provider = "future-provider", token = { future = true }, label = "foreign", nested = { 7, 9 } },
			{ id = "local-row", provider = "lmstudio", token = "", label = "local", model = "fixture-model" },
			{ id = "last-row", provider = "mistral", token = "private-d", label = "last", future = { 2, 3 } },
		} }))
		fh:close()
		entries = fresh(true)
		helpers.assert_true(entries.set_active(first.id))
		fh = assert(io.open(PATH, "rb")); local saved = require("json").decode(fh:read("*a")); fh:close()
		helpers.assert_eq(saved.entries[1].id, first.id)
		helpers.assert_eq(saved.entries[2].id, "future-row")
		helpers.assert_eq(saved.entries[3].id, "local-row")
		helpers.assert_eq(saved.entries[4].id, "last-row")
		helpers.assert_eq(saved.entries[4].future[2], 3)
		helpers.assert_eq(saved.entries[1].future.flag, true)
		helpers.assert_eq(saved.entries[2].nested[2], 9)
	end)
end)


helpers.describe("Local API foreign JSON identities", function()
	helpers.it("keeps independent null, empty-array and empty-object fields (local-api-optional-auth)", function()
		fresh(); os.execute("mkdir -p '" .. DIR .. "'")
		local raw = '{"version":1,"active_id":"known","future":null,"empty_list":[],"empty_object":{},"entries":[{"id":"known","provider":"lmstudio","token":"","label":"Local","model":"m","future":null,"list":[],"object":{}}]}'
		local file = assert(io.open(PATH, "wb")); file:write(raw); file:close()
		local entries = fresh(true)
		local saved = entries.set_active("known")
		file = assert(io.open(PATH, "rb")); local json = require("json"); local decoded = json.decode_lossless(file:read("*a")); file:close()
		helpers.assert_eq(saved, true)
		helpers.assert_true(json.is_null(decoded.future), "unknown root null must remain explicit")
		helpers.assert_true(json.is_array(decoded.empty_list), "unknown root empty-array identity is retained")
		helpers.assert_eq(json.is_array(decoded.empty_object), false)
		helpers.assert_true(json.is_null(decoded.entries[1].future), "unknown row null must remain explicit")
		helpers.assert_true(json.is_array(decoded.entries[1].list))
		helpers.assert_eq(json.is_array(decoded.entries[1].object), false)
	end)

	helpers.it("keeps a future typed model row unowned and unchanged (local-api-optional-auth)", function()
		fresh(); os.execute("mkdir -p '" .. DIR .. "'")
		local raw = '{"version":1,"entries":[{"id":"known","provider":"lmstudio","token":"","label":"Local","model":"m"},{"id":"future","provider":"lmstudio","token":"","label":"Future","model":{"next":true},"base_url":[]}],"active_id":"known"}'
		local file = assert(io.open(PATH, "wb")); file:write(raw); file:close()
		local entries = fresh(true)
		local unowned = entries.get("future") == nil
		local saved = entries.set_active("known")
		file = assert(io.open(PATH, "rb")); local json = require("json"); local decoded = json.decode_lossless(file:read("*a")); file:close()
		helpers.assert_eq(unowned, true, "unsupported field types must not acquire a normalized ordinary owner")
		helpers.assert_eq(saved, true)
		helpers.assert_eq(decoded.entries[2].model.next, true)
		helpers.assert_true(json.is_array(decoded.entries[2].base_url))
	end)
end)


--- Writes independent physical source bytes as an external writer would.
local function external_api_source(bytes)
	local file = assert(io.open(PATH, "wb"))
	assert(file:write(bytes)); assert(file:close())
end

local function physical_api_source()
	local file = assert(io.open(PATH, "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return bytes
end

local FOREIGN_API_SOURCE = '{"version":1,"active_id":"external","future":{"keep":true},"entries":[{"id":"external","provider":"lmstudio","token":"","label":"External","model":"external-model","future":[]}]}'

helpers.describe("API entry source ownership for local discovery", function()
	helpers.it("refuses every cached mutation after an external replacement and rolls back RAM", function()
		for _, mutation in ipairs({ "add", "remove", "selection" }) do
			local entries = fresh()
			local first = assert(entries.add({ provider = "cerebras", token = "first-private", label = "First" }))
			local second = assert(entries.add({ provider = "lmstudio", token = "", label = "Local", model = "local-model" }))
			external_api_source(FOREIGN_API_SOURCE)
			local outcome
			if mutation == "add" then
				outcome = entries.add({ provider = "lmstudio", token = "", label = "New local", model = "new-model" })
			elseif mutation == "remove" then outcome = entries.remove(first.id)
			else outcome = entries.set_active(first.id) end
			if mutation == "add" then helpers.assert_eq(outcome, nil, mutation .. " must refuse stale source")
			else helpers.assert_eq(outcome, false, mutation .. " must refuse stale source") end
			helpers.assert_eq(physical_api_source(), FOREIGN_API_SOURCE, mutation .. " preserves exact external bytes")
			helpers.assert_eq(entries.active().id, second.id, mutation .. " preserves prior RAM selection")
			helpers.assert_eq(#entries.list(), 2, mutation .. " rolls back the cached list")
			local restarted = fresh(true)
			helpers.assert_eq(restarted.active().id, "external", mutation .. " restart reads actual external source")
		end
	end)

	helpers.it("does not treat a once-absent file as authority over a new external file", function()
		local entries = fresh()
		helpers.assert_eq(#entries.list(), 0)
		os.execute("mkdir -p '" .. DIR .. "'")
		external_api_source(FOREIGN_API_SOURCE)
		local added = entries.add({ provider = "lmstudio", token = "", label = "Local", model = "m" })
		helpers.assert_eq(added, nil)
		helpers.assert_eq(physical_api_source(), FOREIGN_API_SOURCE)
		helpers.assert_eq(#entries.list(), 0)
	end)

	helpers.it("rechecks exact source after private staging and never acknowledges the staged loser", function()
		local entries = fresh()
		local original = assert(entries.add({ provider = "lmstudio", token = "", label = "Local", model = "m" }))
		local stage_calls = 0
		entries._set_private_create_for_test(function(path, text)
			local written, reason = create_without_mode(path, text)
			if written then stage_calls = stage_calls + 1; external_api_source(FOREIGN_API_SOURCE) end
			return written, reason
		end)
		local selected = entries.set_active(original.id)
		-- All assertions follow the production publication callback's return.
		helpers.assert_eq(stage_calls, 1, "the external writer acts after a real stage was created")
		helpers.assert_eq(selected, false)
		helpers.assert_eq(physical_api_source(), FOREIGN_API_SOURCE)
		helpers.assert_eq(entries.active().id, original.id)
		local temporary = io.open(PATH .. ".tmp", "rb")
		local has_temporary = temporary ~= nil
		if temporary then temporary:close() end
		helpers.assert_eq(has_temporary, false, "the refused owned stage is retired")
	end)
end)


helpers.describe("API entry physical source refusals", function()
	helpers.it("an unreadable source never becomes a new empty writable store", function()
		local entries = fresh()
		assert(entries.add({ provider = "lmstudio", token = "", label = "Local", model = "m" }))
		local bytes = physical_api_source()
		entries = fresh(true)
		local original_open = io.open
		io.open = function(path, ...)
			if path == PATH then return nil, "controlled unreadable source", 13 end
			return original_open(path, ...)
		end
		local loaded, added
		local ok, err = pcall(function()
			loaded = #entries.list()
			-- Restore read access before mutation: load refusal must stay owned.
			io.open = original_open
			added = entries.add({ provider = "lmstudio", token = "", label = "Unexpected", model = "new" })
		end)
		io.open = original_open
		helpers.assert_eq(io.open, original_open)
		if not ok then error(err) end
		helpers.assert_eq(loaded, 0)
		helpers.assert_eq(added, nil)
		helpers.assert_eq(physical_api_source(), bytes)
	end)

	helpers.it("a reentrant selection cannot acquire the private publication owner", function()
		local entries = fresh()
		local first = assert(entries.add({ provider = "lmstudio", token = "", label = "First", model = "first" }))
		local second = assert(entries.add({ provider = "lmstudio", token = "", label = "Second", model = "second" }))
		local stage_calls, nested = 0, nil
		entries._set_private_create_for_test(function(path, text)
			local written, reason = create_without_mode(path, text)
			stage_calls = stage_calls + 1
			if stage_calls == 1 and written then nested = entries.set_active(second.id) end
			return written, reason
		end)
		local outer = entries.set_active(first.id)
		helpers.assert_eq(nested, false, "only the actual first publication owns this source")
		helpers.assert_eq(stage_calls, 1)
		helpers.assert_eq(outer, true)
		helpers.assert_eq(entries.active().id, first.id)
		helpers.assert_eq(fresh(true).active().id, first.id, "the one acknowledged owner reaches restart")
	end)
end)


helpers.describe("local model selections own their physical API source", function()
	helpers.it("updates a local entry in place and preserves foreign row order and fields across restart", function()
		fresh()
		os.execute("mkdir -p '" .. DIR .. "'")
		local original = [[{"version":1,"active_id":"local","future":{"items":[]},"entries":[{"id":"before","provider":"future","token":17},{"id":"local","provider":"lmstudio","label":"Historical","token":"private bytes ","model":"old","base_url":"http://localhost:4321/v1","future":{"items":[]}},{"id":"after","provider":"unknown","token":null}]}]]
		external_api_source(original)
		local entries = fresh(true)
		local source = entries.capture_source()
		helpers.assert_true(type(source) == "table")
		helpers.assert_eq(next(source), nil, "source bytes and credentials are not exposed in an opaque receipt")
		local selected = entries.upsert_local("lmstudio", { model = "new", token = "private bytes ", base_url = "http://localhost:4321/v1" }, source, function() return true end)
		helpers.assert_eq(selected and selected.id, "local")
		helpers.assert_eq(entries.source_is_current(source), false, "a successful publication retires the previous snapshot")
		local raw = require("json").decode_lossless(physical_api_source())
		helpers.assert_eq(raw.entries[1].id, "before")
		helpers.assert_eq(raw.entries[1].token, 17)
		helpers.assert_eq(raw.entries[2].id, "local")
		helpers.assert_true(require("json").is_array(raw.entries[2].future.items))
		helpers.assert_eq(raw.entries[3].id, "after")
		helpers.assert_true(require("json").is_array(raw.future.items))
		helpers.assert_eq(fresh(true).active().model, "new")
		helpers.assert_eq(fresh(true).active().token, "private bytes ")
	end)

	helpers.it("a held model choice refuses private-source drift and a forged receipt before staging", function()
		local entries = fresh()
		assert(entries.add({ provider = "lmstudio", token = "", label = "Local", model = "old" }))
		local source = entries.capture_source()
		external_api_source(FOREIGN_API_SOURCE)
		local staged = 0
		entries._set_private_create_for_test(function() staged = staged + 1; return false end)
		local selected = entries.upsert_local("lmstudio", { model = "new" }, source, function() return true end)
		helpers.assert_eq(selected, nil)
		helpers.assert_eq(entries.source_is_current(source), false)
		helpers.assert_eq(entries.source_is_current({}), false)
		helpers.assert_eq(staged, 0)
		helpers.assert_eq(physical_api_source(), FOREIGN_API_SOURCE)
		helpers.assert_eq(entries.active().model, "old")
	end)

	helpers.it("requires live admission both before publication and after the actual stage", function()
		for _, phase in ipairs({ "before", "after" }) do
			local entries = fresh()
			local original = assert(entries.add({ provider = "lmstudio", token = "", label = "Local", model = "old" }))
			local bytes, source = physical_api_source(), entries.capture_source()
			local admitted, staged = phase ~= "before", 0
			entries._set_private_create_for_test(function(path, text)
				local written, reason = create_without_mode(path, text)
				staged = staged + 1
				admitted = false
				return written, reason
			end)
			local selected = entries.upsert_local("lmstudio", { model = "new" }, source, function() return admitted end)
			helpers.assert_eq(selected, nil, phase)
			helpers.assert_eq(staged, phase == "before" and 0 or 1, phase)
			helpers.assert_eq(entries.active().id, original.id)
			helpers.assert_eq(entries.active().model, "old")
			helpers.assert_eq(physical_api_source(), bytes)
			helpers.assert_eq(fresh(true).active().model, "old")
		end
	end)

	helpers.it("creates only catalogue-owned typed local entries and preserves the selected model on refusal", function()
		local entries = fresh()
		local source = entries.capture_source()
		for _, fields in ipairs({ { model = "" }, { model = "m", token = false }, { model = "m", base_url = "file:///tmp/not-http" }, { model = "m", future = true } }) do
			helpers.assert_nil(entries.upsert_local("lmstudio", fields, source, function() return true end))
		end
		helpers.assert_nil(entries.upsert_local("openai", { model = "m", token = "" }, source, function() return true end))
		local selected = entries.upsert_local("lmstudio", { model = "m" }, source, function() return true end)
		helpers.assert_eq(selected and selected.provider, "lmstudio")
		helpers.assert_eq(selected and selected.token, "")
		helpers.assert_eq(fresh(true).active().model, "m")
	end)
end)


helpers.describe("local server configuration preserves the current prediction target", function()
	helpers.it("address and credential edits do not select a different saved local model", function()
		local entries = fresh()
		local local_entry = assert(entries.add({ provider = "lmstudio", token = "", label = "Local", model = "m" }))
		local cloud_entry = assert(entries.add({ provider = "cerebras", token = "cloud", label = "Cloud", model = "c" }))
		local saved = entries.upsert_local("lmstudio", { base_url = "http://localhost:6543/v1", token = "inert local" },
			entries.capture_source(), function() return true end, false)
		helpers.assert_eq(saved and saved.id, local_entry.id)
		helpers.assert_eq(saved and saved.model, "m")
		helpers.assert_eq(entries.active().id, cloud_entry.id)
		local restarted = fresh(true)
		helpers.assert_eq(restarted.active().id, cloud_entry.id)
		helpers.assert_eq(restarted.get(local_entry.id).base_url, "http://localhost:6543/v1")
		helpers.assert_eq(restarted.get(local_entry.id).token, "inert local")
	end)
end)


helpers.describe("final local API admission cannot borrow physical source authority", function()
	helpers.it("an admitted post-stage callback replacing disk bytes refuses before native rename", function()
		local entries = fresh()
		local original = assert(entries.add({ provider = "lmstudio", token = "", label = "Local", model = "original" }))
		local source = entries.capture_source()
		local staged, injected, admissions = false, 0, 0
		entries._set_private_create_for_test(function(path, text)
			local written, reason = create_without_mode(path, text)
			if written then staged = true end
			return written, reason
		end)
		local selected = entries.upsert_local("lmstudio", { model = "candidate" }, source, function()
			admissions = admissions + 1
			if staged then injected = injected + 1; external_api_source(FOREIGN_API_SOURCE) end
			return true
		end)
		-- Assertions follow the actual publisher/admission callback and read the
		-- independent external writer's physical bytes, never a derived golden.
		helpers.assert_eq(staged, true)
		helpers.assert_eq(injected, 1)
		helpers.assert_true(admissions >= 3)
		helpers.assert_true(physical_api_source() == FOREIGN_API_SOURCE,
			"an admitted callback cannot authorize replacing an independently changed source")
		helpers.assert_nil(selected, "foreign disk bytes withhold the actual publication ACK")
		helpers.assert_eq(entries.active().id, original.id)
		helpers.assert_eq(entries.active().model, "original")
		local reader = io.open(PATH .. ".tmp", "rb")
		local remaining = reader ~= nil
		if reader then reader:close() end
		helpers.assert_eq(remaining, false, "the refused candidate's owned stage is retired")
		helpers.assert_eq(fresh(true).active().id, "external", "restart uses the independent physical source")
	end)
end)


helpers.describe("malformed API source quarantine acknowledgement", function()
	helpers.it("a refused source-to-corrupt rename cannot authorize replacement of foreign bytes", function()
		fresh()
		os.execute("mkdir -p '" .. DIR .. "'")
		local malformed = '{"future": [ incomplete private source'
		external_api_source(malformed)
		local entries = fresh(true)
		local rename, rename_calls, stages = os.rename, 0, 0
		os.rename = function(from, to)
			if from == PATH and to == PATH .. ".corrupt" then
				rename_calls = rename_calls + 1
				return false, "owned quarantine refusal"
			end
			return rename(from, to)
		end
		entries._set_private_create_for_test(function(path, text)
			stages = stages + 1
			return create_without_mode(path, text)
		end)
		local called, added = pcall(entries.add, { provider = "lmstudio", token = "", label = "Local", model = "model" })
		os.rename = rename
		-- The actual failed quarantine is observed before any private publication,
		-- and assertions follow the owner's return and exact wrapper restoration.
		helpers.assert_eq(called, true)
		helpers.assert_true(physical_api_source() == malformed, "refused quarantine preserves the exact original foreign bytes")
		helpers.assert_nil(added)
		helpers.assert_eq(rename_calls, 1)
		helpers.assert_eq(stages, 0)
		helpers.assert_eq(physical_api_source(), malformed)
		helpers.assert_eq(#entries.list(), 0)
		helpers.assert_nil(entries.active())
		local staged = io.open(PATH .. ".tmp", "rb")
		local staging_exists = staged ~= nil
		if staged then staged:close() end
		helpers.assert_eq(staging_exists, false)
		helpers.assert_eq(os.rename, rename)
	end)
end)
