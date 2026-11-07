--- apps/encryptor_core.lua

--- ==============================================================================
--- MODULE: Encryptor Core (Linux)
--- DESCRIPTION:
--- The Linux Encryptor's conversion and its per-file flow, the port of the macOS
--- Encryptor.app (Scripts/main.applescript and encryptor_convert.sh). The file
--- container is _shared/data/encryptor/format.json, so a file encrypted here
--- opens on macOS and Windows and the other way round.
---
--- FEATURES & RATIONALE:
--- 1. The private runtime's openssl does the work (infra/owned_programs.lua),
---    with every format constant read from the shared format file rather than
---    repeated here.
--- 2. The password reaches OpenSSL through a file in a private folder
---    (`-pass file:`), never a command argument: arguments are readable by any
---    local process through the process table.
--- 3. OpenSSL writes into a stage next to the destination, which replaces it
---    only once the conversion succeeded, so a wrong password leaves an existing
---    destination (whose overwrite the user approved) byte for byte.
--- 4. The flow takes its dialogs and strings as ports, so the whole sequence the
---    user sees runs under test against the real openssl.
--- ==============================================================================

local M = {}

local Json = require("json")
local TextUtils = require("text_utils")

local quote = TextUtils.shell_quote




-- ==============================
-- ==============================
-- ======= 1/ Format ============
-- ==============================
-- ==============================

--- Reads the shared container format.
--- @param path string|nil Absolute path of format.json; the shared tree's by default.
--- @return table format
function M.load_format(path)
	path = path or require("infra.paths").shared("data/encryptor/format.json")
	assert(type(path) == "string", "the shared Encryptor format is unavailable")
	local file = assert(io.open(path, "rb"), "cannot read " .. path)
	local raw = file:read("*a")
	file:close()
	local format = Json.decode(raw)
	assert(type(format) == "table" and format.magic == "Salted__" and type(format.iterations) == "number"
		and type(format.cipher) == "string" and type(format.kdf_digest) == "string"
		and type(format.encrypted_extension) == "string" and type(format.decrypted_fallback_suffix) == "string",
		"the shared Encryptor format is malformed")
	return format
end

--- The conversion a source path gets and where its result goes, as
--- main.applescript decides it: a name ending in the extension (in any case)
--- is decrypted to the name without it; any other is encrypted to name + ext.
--- @param format table
--- @param source string
--- @return string mode "encrypt" or "decrypt"
--- @return string destination
function M.destination(format, source)
	local ext = format.encrypted_extension
	if source:sub(-#ext):lower() ~= ext:lower() then return "encrypt", source .. ext end
	local stripped = source:sub(1, -#ext - 1)
	if stripped == "" or stripped:sub(-1) == "/" then
		return "decrypt", source .. format.decrypted_fallback_suffix
	end
	return "decrypt", stripped
end

--- The openssl arguments of one conversion, before the program word.
--- @param format table
--- @param mode string "encrypt" or "decrypt"
--- @param input string
--- @param output string
--- @param password_file string
--- @return table words
function M.openssl_words(format, mode, input, output, password_file)
	assert(mode == "encrypt" or mode == "decrypt", "unknown Encryptor mode: " .. tostring(mode))
	return { "enc", mode == "encrypt" and "-e" or "-d", "-" .. format.cipher, "-" .. format.kdf,
		"-iter", string.format("%d", format.iterations), "-md", format.kdf_digest,
		"-in", input, "-out", output, "-pass", "file:" .. password_file }
end




-- ==============================
-- ==============================
-- ======= 2/ Conversion ========
-- ==============================
-- ==============================

--- The exit code of an os.execute result on LuaJIT and Lua 5.2+.
local function exit_code(status, how, code)
	return require("ui.native_dialog").exit_code(status, how, code)
end

--- Runs a command and returns whether it exited 0.
local function succeeded(command)
	local code = exit_code(os.execute(command))
	return code == 0
end

--- Reads the single line one command prints.
local function read_line(command)
	local pipe = io.popen(command, "r")
	if not pipe then return nil end
	local line = pipe:read("*l")
	pipe:close()
	return line
end

--- Converts one file.
--- @param format table
--- @param mode string "encrypt" or "decrypt"
--- @param input string Source path.
--- @param output string Destination path; replaced only on success.
--- @param password string
--- @param openssl string The openssl program to run.
--- @return boolean ok
--- @return string|nil reason Why the conversion failed: password_line_break, private_folder_not_created,
---   open_failed (the stage), command_exited_nonzero (openssl), unreadable (the umask) or rename_failed; an error's text otherwise.
function M.convert(format, mode, input, output, password, openssl)
	assert(type(password) == "string" and password ~= "", "an Encryptor password is required")
	-- OpenSSL's -pass file: reads the first line only; a line break would make
	-- the key differ from the Windows driver's, which reads the whole password.
	if password:find("[\r\n]") then return false, "password_line_break" end
	local private = read_line("umask 077; mktemp -d 2>/dev/null")
	if not private or private:sub(1, 1) ~= "/" then return false, "private_folder_not_created" end
	local password_file = private .. "/password"
	local ok, reason = false, nil
	local stage
	local success, err = pcall(function()
		local previous = read_line("umask")
		local file = assert(io.open(password_file, "wb"), "cannot write the password file")
		file:write(password)
		file:close()
		local folder = output:match("^(.*)/[^/]*$") or "."
		local base = output:match("([^/]*)$")
		stage = read_line("mktemp " .. quote((folder == "" and "/" or folder) .. "/." .. base .. ".XXXXXX") .. " 2>/dev/null")
		if not stage or stage == "" then reason = "open_failed" return end
		local line = quote(openssl)
		for _, word in ipairs(M.openssl_words(format, mode, input, stage, password_file)) do line = line .. " " .. quote(word) end
		if not succeeded(line .. " 2>/dev/null") then reason = "command_exited_nonzero" return end
		-- mktemp creates the stage 0600; give the output the mode a new file gets.
		-- 0666 & ~umask, spelt arithmetically: LuaJIT has no bitwise operators.
		local mask = tonumber(previous or "", 8)
		if not mask then reason = "unreadable" return end
		local bits = 0
		for bit = 8, 0, -1 do
			local value = 2 ^ bit
			if math.floor(438 / value) % 2 == 1 and math.floor(mask / value) % 2 == 0 then bits = bits + value end
		end
		if not succeeded("chmod " .. string.format("%o", bits) .. " " .. quote(stage))
			or not succeeded("mv -f " .. quote(stage) .. " " .. quote(output)) then
			reason = "rename_failed"
			return
		end
		stage = nil
		ok = true
	end)
	if stage then os.remove(stage) end
	os.remove(password_file)
	os.remove(private)
	if not success then return false, tostring(err) end
	return ok, reason
end




-- ==============================
-- ==============================
-- ======= 3/ Flow ==============
-- ==============================
-- ==============================

--- Whether a path names an existing regular file.
local function is_file(path)
	return succeeded("test -f " .. quote(path))
end

--- Whether anything exists at a path.
local function exists(path)
	return succeeded("test -e " .. quote(path))
end

--- Processes one file the way main.applescript's process_file does.
--- @param path string Source file.
--- @param ports table { dialogs, t, format, openssl, reveal, is_file, exists }
--- @return string outcome "done", "cancelled" or "failed"
function M.process_file(path, ports)
	local dialogs, t, format = ports.dialogs, ports.t, ports.format
	local file_test, exists_test = ports.is_file or is_file, ports.exists or exists
	if not file_test(path) then
		dialogs.message("error", t("apps.encryptor.title_encrypt"), t("apps.encryptor.err_file_missing") .. "\n\n" .. path)
		return "failed"
	end
	local mode, destination = M.destination(format, path)
	local encrypting = mode == "encrypt"
	local title = t(encrypting and "apps.encryptor.title_encrypt" or "apps.encryptor.title_decrypt")
	if exists_test(destination) then
		if not dialogs.question(title, t("apps.encryptor.warn_overwrite") .. "\n\n" .. destination,
			t("apps.encryptor.btn_overwrite"), t("button.cancel")) then return "cancelled" end
	end
	local password
	while true do
		password = dialogs.entry(title, t("apps.encryptor.prompt_password"),
			{ hidden = true, ok = t(encrypting and "button.encrypt" or "button.decrypt"), cancel = t("button.cancel") })
		if password == nil then return "cancelled" end
		if password == "" then
			dialogs.message("warning", title, t("apps.encryptor.err_empty_password"))
		elseif encrypting then
			local confirmed = dialogs.entry(title, t("apps.encryptor.prompt_confirm"),
				{ hidden = true, ok = t("button.encrypt"), cancel = t("button.cancel") })
			if confirmed == nil then return "cancelled" end
			if confirmed == password then break end
			dialogs.message("warning", title, t("apps.encryptor.err_password_mismatch"))
		else
			break
		end
	end
	local ok = M.convert(format, mode, path, destination, password, ports.openssl)
	if not ok then
		dialogs.message("error", title,
			t(encrypting and "apps.encryptor.err_encrypt_failed" or "apps.encryptor.err_decrypt_failed"))
		return "failed"
	end
	local summary = t(encrypting and "apps.encryptor.success_encrypted" or "apps.encryptor.success_decrypted")
		.. "\n" .. destination
	if dialogs.question(title, summary, t("apps.encryptor.btn_reveal_folder"), t("common.close")) then
		ports.reveal(destination)
	end
	return "done"
end

--- Runs the app over dropped files, or asks for one when none was given.
--- @param files table Paths handed on the command line.
--- @param ports table As process_file, plus nothing else.
--- @return table outcomes One outcome per processed file.
function M.run(files, ports)
	local outcomes = {}
	if #files == 0 then
		local chosen = ports.dialogs.file(ports.t("apps.encryptor.lbl_file"))
		if not chosen then return outcomes end
		files = { chosen }
	end
	for _, path in ipairs(files) do outcomes[#outcomes + 1] = M.process_file(path, ports) end
	return outcomes
end

return M
