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

	helpers.it("names a second entry of the same label apart", function()
		local entries = fresh()
		entries.add({ provider = "cerebras", token = "a", label = "Cerebras" })
		local second = entries.add({ provider = "cerebras", token = "b", label = "Cerebras" })
		helpers.assert_eq(second.label, "Cerebras (2)")
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
			helpers.assert_eq(stored.entries[2].key, "sk-legacy-secret", "its key is never deleted")
		end)
		Logger.warn, Logger.error = real_warn, real_error
		os.execute("rm -rf '" .. DIR .. "'")
		if not ok then error(err, 0) end
	end)

end)
