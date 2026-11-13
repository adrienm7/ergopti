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
	return require("core.text.engine.json").decode(assert(file_text(), "the file exists"))
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

	helpers.it("publishes the references the background move stored, and refuses a changed entry (linux-api-key-background-migration)", function()
		local fake = Fake.install()
		write_file(LEGACY)
		local entries = fresh(true)
		local keys = entries.plaintext_keys()
		helpers.assert_eq(#keys, 1)
		helpers.assert_eq(keys[1].id, "cerebras-1")
		local published, reason, uncertain = entries.publish_migrated({ ["cerebras-1"] = "secret-service:cerebras-1#a" },
			{ ["cerebras-1"] = "csk-OTHERKEY" })
		helpers.assert_eq(published, false, "a key that is not the entry's is never published")
		helpers.assert_true(tostring(reason):find("changed", 1, true) ~= nil, tostring(reason))
		helpers.assert_eq(uncertain, nil)
		helpers.assert_eq(file_text(), LEGACY)
		fake.items["cerebras-1#a"] = "csk-PLAINCANARY"
		helpers.assert_eq(entries.publish_migrated({ ["cerebras-1"] = "secret-service:cerebras-1#a" },
			{ ["cerebras-1"] = "csk-PLAINCANARY" }), true)
		helpers.assert_eq(Fake.count(fake), 1, "the publication stores nothing itself")
		helpers.assert_eq(stored().entries[1].token, "secret-service:cerebras-1#a")
		helpers.assert_eq(file_text():find("PLAINCANARY", 1, true), nil)
		helpers.assert_eq(#entries.plaintext_keys(), 0)
		helpers.assert_eq(fresh(true).active().token, "csk-PLAINCANARY", "the reference reads back")
		Fake.uninstall()
	end)

	helpers.it("lists an entry restored without its key as needing it again, and keeps its reference (linux-api-key-restored-missing)", function()
		-- A pre-install backup names a key its entry's deletion removed from the service.
		local fake = Fake.install()
		write_file('{"version":1,"active_id":"cerebras-1","entries":[{"id":"cerebras-1","provider":"cerebras",'
			.. '"label":"cerebras/qwen","token":"secret-service:cerebras-1#gone","model":"","base_url":""}]}')
		local entries = fresh(true)
		helpers.assert_eq(#entries.list(), 1, "the restored entry is listed, not left out as outdated")
		helpers.assert_eq(entries.key_missing("cerebras-1"), true, "it needs its key re-entered")
		helpers.assert_eq(entries.get("cerebras-1").token, "")
		helpers.assert_eq(entries.set_model("cerebras-1", "other-model"), true)
		helpers.assert_eq(stored().entries[1].token, "secret-service:cerebras-1#gone",
			"a save keeps the reference until a new key replaces it")
		helpers.assert_eq(Fake.count(fake), 0, "no empty key is stored")
		helpers.assert_eq(entries.set_token("cerebras-1", "csk-REENTERED"), true)
		helpers.assert_eq(entries.key_missing("cerebras-1"), false)
		local reference = stored().entries[1].token
		helpers.assert_true(reference:match(REFERENCE) ~= nil and reference ~= "secret-service:cerebras-1#gone", reference)
		helpers.assert_eq(file_text():find("REENTERED", 1, true), nil, "the new key is not in the file")
		helpers.assert_eq(fresh(true).active().token, "csk-REENTERED", "the new key reads back")
		helpers.assert_eq(entries.remove("cerebras-1"), true)
		helpers.assert_eq(Fake.count(fake), 0, "removing the entry still deletes its key")
		Fake.uninstall()
	end)

	helpers.it("a key the service cannot read for another reason is not taken for a missing one (linux-api-key-restored-missing)", function()
		local fake = Fake.install()
		fake.lookup_refusal = "the keyring is locked, or its unlock prompt was dismissed"
		write_file('{"version":1,"active_id":"cerebras-1","entries":[{"id":"cerebras-1","provider":"cerebras",'
			.. '"label":"cerebras/qwen","token":"secret-service:cerebras-1#locked","model":"","base_url":""}]}')
		local entries = fresh(true)
		helpers.assert_eq(#entries.list(), 0, "kept as written: the key is still in the service")
		helpers.assert_eq(entries.key_missing("cerebras-1"), false)
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

	helpers.it("secret-service-revision: restart in the same second cannot overwrite a published key", function()
		local saved_time, saved_module = os.time, package.loaded["modules.llm.api_token_store"]
		local records = {}
		local backend = { unavailable = function() end, store = function(name, token) records[name] = token; return true end }
		local ok, err = pcall(function()
			os.time = function() return 123456 end
			local first = helpers.load_module("modules.llm.api_token_store")
			first._set_backend_for_test(backend)
			local old = assert(first.store("provider", "old-key"))
			local restarted = helpers.load_module("modules.llm.api_token_store")
			restarted._set_backend_for_test(backend)
			local new = assert(restarted.store("provider", "new-key"))
			helpers.assert_true(old ~= new, "a new process must not reuse the published reference")
			helpers.assert_eq(records[old:sub(#first.REFERENCE_PREFIX + 1)], "old-key")
		end)
		os.time, package.loaded["modules.llm.api_token_store"] = saved_time, saved_module
		assert(ok, err)
	end)

	helpers.it("secret-service-revision: unavailable randomness refuses before storing", function()
		local previous_uv, previous_store = package.loaded["luv"], package.loaded["modules.llm.api_token_store"]
		local writes = 0
		local ok, err = pcall(function()
			package.loaded["luv"] = { random = function() return nil, "unavailable" end }
			local Store = helpers.load_module("modules.llm.api_token_store")
			Store._set_backend_for_test({ unavailable = function() end, store = function() writes = writes + 1; return true end })
			local reference, reason = Store.store("provider", "private-key")
			helpers.assert_nil(reference)
			helpers.assert_eq(reason, "secure random revision unavailable")
			helpers.assert_eq(writes, 0)
		end)
		package.loaded["luv"], package.loaded["modules.llm.api_token_store"] = previous_uv, previous_store
		assert(ok, err)
	end)

	helpers.it("linux-secret-tool-input-limit: an oversized token cannot publish a truncated key", function()
		local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
		local tool = dir .. "/secret-tool"
		local script = assert(io.open(tool, "w"))
		script:write("#!/bin/sh\ndd bs=8192 count=1 of='" .. dir .. "/stored' 2>/dev/null\nexit 0\n")
		script:close(); os.execute("chmod +x '" .. tool .. "'")
		local Store = helpers.load_module("modules.llm.api_token_store")
		Store._set_backend_for_test(nil)
		Store._set_tool_for_test(tool)
		local ok, err = pcall(function()
			local reference = Store.store("provider", string.rep("x", 8193))
			helpers.assert_nil(reference, "secret-tool cannot acknowledge a key longer than its input capacity")
			helpers.assert_nil(io.open(dir .. "/stored", "rb"), "refusal must happen before the service is changed")
			assert(Store.store("provider", string.rep("x", 8192)), "the full supported buffer must remain usable")
			local stored = assert(io.open(dir .. "/stored", "rb"))
			local bytes = stored:read("*a"); stored:close()
			helpers.assert_eq(#bytes, 8192)
		end)
		Store._set_tool_for_test(nil)
		Fake.uninstall()
		os.execute("rm -rf '" .. dir .. "'")
		assert(ok, err)
	end)

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

	local function substituted_diagnostic(replacement, expected_type)
		local tool, dir = stand_in('path=$(readlink /proc/self/fd/2)\nrm -- "$path"\n'
			.. replacement .. '\nprintf "%s" "$path" > "$(dirname "$0")/fifo-path"\nexit 1')
		local uv = require("luv")
		local code = string.format([[package.path = %q
local store = require("modules.llm.api_token_store")
store._set_tool_for_test(%q)
local _, reasons = store.lookup_many({ "secret-service:fixture#1" })
assert(reasons["secret-service:fixture#1"] ~= "absent", "unreadable diagnostics are not proof of absence")
]], package.path, tool)
		local exited, expired, status, signal = false, false, nil, nil
		local timer = assert(uv.new_timer())
		local child
		child = assert(uv.spawn(assert(arg[-1]), { args = { "-e", code } }, function(code, sig)
			exited, status, signal = true, code, sig
			uv.timer_stop(timer); uv.close(timer); uv.close(child)
		end))
		assert(require("infra.native_timer").start(uv, timer, 2000, 0, function()
			expired = true; child:kill("sigkill")
		end))
		while not exited do uv.run("once") end
		uv.run("nowait")
		local fifo = recorded(dir, "fifo-path")
		local info = fifo and uv.fs_lstat(fifo)
		if fifo then
			os.remove(fifo)
			uv.fs_rmdir(require("core.fs.engine.native_path").dirname(fifo))
		end
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_eq(expired, false, "secret-tool diagnostics must not block on a FIFO")
		helpers.assert_eq(status, 0)
		helpers.assert_eq(signal, 0)
		helpers.assert_eq(info and info.type, expected_type, "the substituted endpoint is not deleted")
	end

	helpers.it("refuses a substituted FIFO diagnostic without blocking or reporting absence", function()
		substituted_diagnostic('mkfifo -- "$path"', "fifo")
	end)

	helpers.it("refuses a substituted regular diagnostic without deleting it", function()
		substituted_diagnostic(': > "$path"', "file")
	end)

	helpers.it("uses a private result directory and retires it after secret-tool finishes", function()
		local tool, dir = stand_in('path=$(readlink /proc/self/fd/2)\n'
			.. 'printf "%s" "$path" > "$(dirname "$0")/result-path"\n'
			.. 'stat -c %a "$(dirname "$path")" > "$(dirname "$0")/result-mode"\nexit 0')
		local Store = helpers.load_module("modules.llm.api_token_store")
		Store._set_backend_for_test(nil)
		Store._set_tool_for_test(tool)
		local reference = Store.store("fixture", "private-token")
		local result_path, mode = recorded(dir, "result-path"), recorded(dir, "result-mode")
		Store._set_tool_for_test(nil)
		Fake.uninstall()
		local uv = require("luv")
		local result_dir = result_path and require("core.fs.engine.native_path").dirname(result_path)
		local file_left = result_path and uv.fs_lstat(result_path)
		local dir_left = result_dir and uv.fs_lstat(result_dir)
		os.execute("rm -rf '" .. dir .. "'")
		helpers.assert_true(reference ~= nil)
		helpers.assert_eq(mode, "700\n")
		helpers.assert_nil(file_left)
		helpers.assert_nil(dir_left)
	end)

	helpers.it("retires private result files if secret-tool dispatch raises", function()
		local tool, dir = stand_in("exit 0")
		local uv = require("luv")
		local mkdtemp, popen, result_dir = uv.fs_mkdtemp, io.popen, nil
		local Store = helpers.load_module("modules.llm.api_token_store")
		local ok, err = pcall(function()
			Store._set_backend_for_test(nil)
			Store._set_tool_for_test(tool)
			uv.fs_mkdtemp = function(template)
				result_dir = assert(mkdtemp(template))
				return result_dir
			end
			io.popen = function() error("injected dispatch refusal") end
			local reference = Store.store("fixture", "private-token")
			helpers.assert_nil(reference)
			helpers.assert_true(result_dir ~= nil, "dispatch was attempted after native reservation")
			helpers.assert_nil(uv.fs_lstat(result_dir), "failed dispatch must retire its exact files and directory")
		end)
		uv.fs_mkdtemp, io.popen = mkdtemp, popen
		Store._set_tool_for_test(nil)
		Fake.uninstall()
		if result_dir and uv.fs_lstat(result_dir) then
			os.remove(result_dir .. "/stderr"); os.remove(result_dir .. "/status"); uv.fs_rmdir(result_dir)
		end
		os.execute("rm -rf '" .. dir .. "'")
		if not ok then error(err, 0) end
	end)

	helpers.it("linux-secret-tool-write-refusal: a refused stdin write cannot publish a reference", function()
		-- LCR-002: secret-tool exits 0 after reading a short stdin, so its exit
		-- status alone is not proof that the whole key reached the service.
		local tool, dir = stand_in("exit 0")
		local Store = helpers.load_module("modules.llm.api_token_store")
		Store._set_backend_for_test(nil)
		Store._set_tool_for_test(tool)
		local popen = io.popen
		local ok, err = pcall(function()
			io.popen = function(command, mode)
				local pipe = popen(command, mode)
				if mode ~= "w" or not pipe then return pipe end
				return setmetatable({}, { __index = function(_, key)
					if key == "write" then
						return function(_, input)
							pipe:write(input:sub(1, 3))
							return nil, "controlled short write"
						end
					end
					local value = pipe[key]
					if type(value) ~= "function" then return value end
					return function(_, ...) return value(pipe, ...) end
				end })
			end
			local reference = Store.store("provider", "SYNTHETIC-KEY-0123456789abcd")
			io.popen = popen
			helpers.assert_eq(recorded(dir, "stdin"), "SYN", "the stand-in received only the short write")
			helpers.assert_nil(reference, "a refused write must not publish a secret-service reference")
		end)
		io.popen = popen
		Store._set_tool_for_test(nil)
		os.execute("rm -rf '" .. dir .. "'")
		assert(ok, err)
	end)

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

	-- Measured on a real gnome-keyring (tests/hardware/run_keyring_receipts.sh):
	-- a lookup whose unlock prompt is dismissed and a clear on a locked keyring
	-- both exit 1 with nothing on stderr, as an absent item does, and the clear
	-- removes nothing. `search` without --unlock prompts for nothing and still
	-- lists a locked item, so it tells the cases apart.
	helpers.it("secret-tool-locked-keyring: a locked item is neither absent nor cleared", function()
		local dir = os.tmpname(); os.remove(dir); assert(os.execute("mkdir -p '" .. dir .. "'"))
		local tool = dir .. "/secret-tool"
		local script = assert(io.open(tool, "w"))
		script:write("#!/bin/sh\ncase \"$1\" in\n"
			.. "  lookup|clear) exit 1 ;;\n"
			.. "  search) [ \"$5\" = present#r ] && printf '[/1]\\nlabel = key\\n'; exit 0 ;;\n"
			.. "esac\nexit 2\n")
		script:close(); os.execute("chmod +x '" .. tool .. "'")
		local Store = helpers.load_module("modules.llm.api_token_store")
		Store._set_backend_for_test(nil)
		Store._set_tool_for_test(tool)
		local ok, err = pcall(function()
			local present, gone = "secret-service:present#r", "secret-service:gone#r"
			local tokens, reasons = Store.lookup_many({ present, gone })
			helpers.assert_nil(tokens[present], "a locked item yields no key")
			helpers.assert_true(reasons[present] ~= "absent" and tostring(reasons[present]):find("locked", 1, true) ~= nil,
				"a locked or dismissed item is not reported absent: " .. tostring(reasons[present]))
			helpers.assert_eq(reasons[gone], "absent", "an item the service does not list stays absent")
			local cleared, why = Store.clear(present)
			helpers.assert_eq(cleared, false, "a clear that left the item in place is not a success")
			helpers.assert_true(tostring(why):find("locked", 1, true) ~= nil, tostring(why))
			helpers.assert_eq(Store.clear(gone), true, "clearing an absent item succeeds")
		end)
		Store._set_tool_for_test(nil)
		Fake.uninstall()
		os.execute("rm -rf '" .. dir .. "'")
		assert(ok, err)
	end)
end)
