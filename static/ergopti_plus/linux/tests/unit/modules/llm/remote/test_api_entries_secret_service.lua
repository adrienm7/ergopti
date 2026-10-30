--- tests/unit/modules/llm/remote/test_api_entries_secret_service.lua

--- ==============================================================================
--- MODULE: API Keys Live In The Secret Service
--- DESCRIPTION:
--- api_keys.json holds a reference per key, never the key: the key goes to the
--- desktop secret service, as it goes to the Keychain on macOS and under DPAPI
--- on Windows. Without a service a save is refused, not written in plaintext;
--- a key an earlier build wrote in plaintext moves to the service once; a
--- failed save never leaves the file naming a key it did not publish.
--- The real secret-tool calls are pinned against a stand-in tool at the end.
--- ==============================================================================

local helpers = require("tests.helpers")
local WinCompat = require("tests.win_compat")
local Fake = require("tests.support.secret_service_fake")

local DIR = os.tmpname()
os.remove(DIR)
local PATH = DIR .. "/api_keys.json"
local REFERENCE = "^secret%-service:"

--- Creates a new file, refusing an existing one as O_EXCL does (Windows).
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

--- The store on the test file, over the fake service.
--- @param keep boolean|nil Keep the file from the previous load.
--- @return table
local function fresh(keep)
	if not keep then os.execute("rm -rf '" .. DIR .. "'") end
	local entries = helpers.load_module("modules.llm.api_entries")
	entries._set_path_for_test(PATH)
	if WinCompat.is_windows() then entries._set_private_create_for_test(create_without_mode) end
	return entries
end

--- The file's bytes, or nil.
--- @return string|nil
local function file_text()
	local fh = io.open(PATH, "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- Writes the file as an earlier build left it.
--- @param text string
local function write_file(text)
	os.execute("rm -rf '" .. DIR .. "' && mkdir -p '" .. DIR .. "'")
	local fh = assert(io.open(PATH, "wb"))
	fh:write(text)
	fh:close()
end

--- The decoded file.
--- @return table
local function stored()
	return require("json").decode(assert(file_text(), "the file exists"))
end

local LEGACY = '{"version":1,"active_id":"cerebras-1","entries":[{"id":"cerebras-1","provider":"cerebras",'
	.. '"label":"cerebras/qwen","token":"csk-PLAINCANARY","model":"","base_url":""}]}'

helpers.describe("api_entries: keys live in the desktop secret service", function()

	helpers.it("writes a reference, never the key, and reads the key back from the service (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		local entry = fresh().add({ provider = "cerebras", token = "csk-SECRETCANARY", label = "Cerebras" })
		helpers.assert_not_nil(entry, "the entry is saved")
		local text = file_text()
		helpers.assert_eq(text:find("SECRETCANARY", 1, true), nil, "the key is not in the file")
		local reference = stored().entries[1].token
		helpers.assert_true(reference:match(REFERENCE) ~= nil, "the file names the key: " .. reference)
		helpers.assert_eq(Fake.count(fake), 1)
		local reloaded = fresh(true)
		helpers.assert_eq(reloaded.active().token, "csk-SECRETCANARY", "the key is read back")
		Fake.uninstall()
	end)

	helpers.it("refuses a save without a service, writes no plaintext and keeps the reason (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		fake.unavailable_reason = "secret-tool is not installed"
		local entries = fresh()
		helpers.assert_nil(entries.add({ provider = "cerebras", token = "csk-SECRETCANARY", label = "Cerebras" }))
		helpers.assert_eq(#entries.list(), 0, "nothing stays in memory")
		local text = file_text()
		helpers.assert_true(text == nil or not text:find("SECRETCANARY", 1, true), "no plaintext key on disk")
		helpers.assert_eq(entries.store_refusal(), "secret-tool is not installed")
		Fake.uninstall()
	end)

	helpers.it("refuses a save the service rejects and deletes nothing it did not store (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		fake.store_refusal = "Cannot create an item in a locked collection"
		local entries = fresh()
		helpers.assert_nil(entries.add({ provider = "cerebras", token = "csk-SECRETCANARY", label = "Cerebras" }))
		helpers.assert_eq(entries.store_refusal(), "Cannot create an item in a locked collection")
		helpers.assert_eq(file_text(), nil, "no file is written")
		Fake.uninstall()
	end)

	helpers.it("a load alone never rewrites a plaintext file (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		write_file(LEGACY)
		helpers.assert_eq(fresh(true).active().token, "csk-PLAINCANARY")
		helpers.assert_eq(file_text(), LEGACY)
		helpers.assert_eq(Fake.count(fake), 0)
		Fake.uninstall()
	end)

	helpers.it("the daemon migrates plaintext keys once at boot (linux-api-key-secret-service)", function()
		local fh = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = fh:read("*a")
		fh:close()
		helpers.assert_true(source:find("pcall(entries.migrate_plaintext)", 1, true) ~= nil,
			"the boot runs the migration, and a failure there never stops the boot")
	end)

	helpers.it("moves a plaintext key of an earlier build to the service once (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		write_file(LEGACY)
		local entries = fresh(true)
		helpers.assert_eq(entries.migrate_plaintext(), true)
		helpers.assert_eq(entries.active().token, "csk-PLAINCANARY", "the entry keeps working")
		helpers.assert_eq(file_text():find("PLAINCANARY", 1, true), nil, "the plaintext key left the file")
		helpers.assert_true(stored().entries[1].token:match(REFERENCE) ~= nil)
		helpers.assert_eq(stored().entries[1].label, "cerebras/qwen", "the other fields are kept")
		helpers.assert_eq(Fake.count(fake), 1)
		local calls = #fake.calls
		local again = fresh(true)
		helpers.assert_eq(again.migrate_plaintext(), true, "nothing is left to move")
		helpers.assert_eq(again.active().token, "csk-PLAINCANARY")
		for index = calls + 1, #fake.calls do
			helpers.assert_true(fake.calls[index]:match("^lookup ") ~= nil, "a second load stores nothing")
		end
		Fake.uninstall()
	end)

	helpers.it("leaves a plaintext file as it was when no service is available (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		fake.unavailable_reason = "secret-tool is not installed"
		write_file(LEGACY)
		local entries = fresh(true)
		helpers.assert_eq(entries.migrate_plaintext(), false)
		helpers.assert_eq(entries.active().token, "csk-PLAINCANARY", "the entry keeps working")
		helpers.assert_eq(file_text(), LEGACY, "the file is untouched: removing the key would lose it")
		helpers.assert_eq(entries.set_active("cerebras-1"), false, "no rewrite keeps the key in plaintext")
		helpers.assert_eq(file_text(), LEGACY)
		Fake.uninstall()
	end)

	helpers.it("deletes the key it stored when the file cannot be published (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		local entries = fresh()
		entries._set_private_create_for_test(function() return false, "disk full" end)
		helpers.assert_nil(entries.add({ provider = "cerebras", token = "csk-SECRETCANARY", label = "Cerebras" }))
		helpers.assert_eq(Fake.count(fake), 0, "no key is left behind for a file that names none")
		entries._set_private_create_for_test(nil)
		Fake.uninstall()
	end)

	helpers.it("deletes a removed entry's key once the file no longer names it (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		local entries = fresh()
		local kept = entries.add({ provider = "cerebras", token = "csk-KEEP", label = "Cerebras" })
		local gone = entries.add({ provider = "mistral", token = "msk-GONE", label = "Mistral" })
		helpers.assert_eq(Fake.count(fake), 2)
		helpers.assert_true(entries.remove(gone.id))
		helpers.assert_eq(Fake.count(fake), 1)
		helpers.assert_eq(fresh(true).get(kept.id).token, "csk-KEEP")
		Fake.uninstall()
	end)

	helpers.it("keeps an entry whose key cannot be read as written, and does not use it (linux-api-key-secret-service)", function()
		local fake = Fake.install()
		local entry = fresh().add({ provider = "cerebras", token = "csk-SECRETCANARY", label = "Cerebras" })
		local reference = stored().entries[1].token
		fake.lookup_refusal = "Cannot autolaunch D-Bus without X11 $DISPLAY"
		local entries = fresh(true)
		helpers.assert_nil(entries.get(entry.id), "an entry without its key is not offered")
		fake.lookup_refusal = nil
		helpers.assert_not_nil(entries.add({ provider = "mistral", token = "msk-OTHER", label = "Mistral" }))
		helpers.assert_eq(stored().entries[1].token, reference, "the unreadable row is written back unchanged")
		helpers.assert_eq(fake.items[reference:gsub(REFERENCE, "")], "csk-SECRETCANARY", "its key is kept")
		Fake.uninstall()
	end)
end)

helpers.describe("api_token_store: the secret-tool calls", function()
	if WinCompat.is_windows() then
		helpers.it("SKIP [CONF-LINUX-SECRET-TOOL] — a Windows host has no secret-tool or sh", function()
			helpers.assert_eq(package.config:sub(1, 1), "\\", "this deferral runs only on Windows")
		end)
		return
	end

	--- A stand-in secret-tool: records its arguments and stdin, answers as told.
	--- @param body string Shell lines run after recording.
	--- @return string tool, string dir
	local function stand_in(body)
		local dir = os.tmpname()
		os.remove(dir)
		os.execute("mkdir -p '" .. dir .. "'")
		local tool = dir .. "/secret-tool"
		local fh = assert(io.open(tool, "w"))
		fh:write("#!/bin/sh\nprintf '%s\\n' \"$@\" > '" .. dir .. "/args'\n"
			.. "[ \"$1\" = store ] && cat > '" .. dir .. "/stdin'\n" .. body .. "\n")
		fh:close()
		os.execute("chmod +x '" .. tool .. "'")
		return tool, dir
	end

	--- Reads a recorded file.
	local function recorded(dir, name)
		local fh = io.open(dir .. "/" .. name, "rb")
		if not fh then return nil end
		local text = fh:read("*a")
		fh:close()
		return text
	end

	helpers.it("hands the key on stdin, byte for byte, never in the arguments (linux-api-key-secret-service)", function()
		local tool, dir = stand_in("exit 0")
		local Store = helpers.load_module("modules.llm.api_token_store")
		Store._set_backend_for_test(nil)
		Store._set_tool_for_test(tool)
		local reference = Store.store("cerebras-1", "csk-'$(id)\n")
		helpers.assert_true(reference ~= nil and reference:match("^secret%-service:cerebras%-1#") ~= nil, tostring(reference))
		helpers.assert_eq(recorded(dir, "stdin"), "csk-'$(id)\n")
		local args = recorded(dir, "args")
		helpers.assert_eq(args:find("csk-", 1, true), nil, "the key is not an argument")
		helpers.assert_true(args:find("application\nErgoptiPlus\napi_key\n" .. reference:sub(16), 1, true) ~= nil, args)
		Store._set_tool_for_test(nil)
		Fake.uninstall()
		os.execute("rm -rf '" .. dir .. "'")
	end)

	helpers.it("reports the service's message when it refuses, and reads an absent key as absent (linux-api-key-secret-service)", function()
		local tool, dir = stand_in("echo 'secret-tool: Cannot autolaunch D-Bus' >&2; exit 1")
		local Store = helpers.load_module("modules.llm.api_token_store")
		Store._set_backend_for_test(nil)
		Store._set_tool_for_test(tool)
		local reference, reason = Store.store("cerebras-1", "csk")
		helpers.assert_nil(reference)
		helpers.assert_eq(reason, "secret-tool: Cannot autolaunch D-Bus")
		Store._set_tool_for_test(nil)
		Fake.uninstall()
		os.execute("rm -rf '" .. dir .. "'")

		tool, dir = stand_in("exit 1")
		Store._set_tool_for_test(tool)
		local _, reasons = Store.lookup_many({ "secret-service:cerebras-1#1-1" })
		helpers.assert_eq(reasons["secret-service:cerebras-1#1-1"], "absent")
		helpers.assert_eq(Store.clear("secret-service:cerebras-1#1-1"), true, "an absent key is already deleted")
		Store._set_tool_for_test(nil)
		Fake.uninstall()
		os.execute("rm -rf '" .. dir .. "'")
	end)

	helpers.it("reads a key exactly as the service prints it (linux-api-key-secret-service)", function()
		local tool, dir = stand_in("printf 'csk-VALUE'")
		local Store = helpers.load_module("modules.llm.api_token_store")
		Store._set_backend_for_test(nil)
		Store._set_tool_for_test(tool)
		local tokens = Store.lookup_many({ "secret-service:cerebras-1#1-1" })
		helpers.assert_eq(tokens["secret-service:cerebras-1#1-1"], "csk-VALUE")
		Store._set_tool_for_test(nil)
		Fake.uninstall()
		os.execute("rm -rf '" .. dir .. "'")
	end)

	helpers.it("refuses with the reason when secret-tool is not installed (linux-api-key-secret-service)", function()
		local Store = helpers.load_module("modules.llm.api_token_store")
		Store._set_backend_for_test(nil)
		Store._set_tool_for_test("/nonexistent/secret-tool")
		local reference, reason = Store.store("cerebras-1", "csk")
		helpers.assert_nil(reference)
		helpers.assert_true(reason:find("not installed", 1, true) ~= nil, reason)
		Store._set_tool_for_test(nil)
		Fake.uninstall()
	end)
end)
