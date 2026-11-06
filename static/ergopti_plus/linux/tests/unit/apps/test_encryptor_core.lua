--- tests/unit/apps/test_encryptor_core.lua

--- ==============================================================================
--- MODULE: Linux Encryptor Tests
--- DESCRIPTION:
--- Runs the Linux Encryptor's conversion with the real openssl over the shared
--- vectors (_shared/tests/corpus/encryptor/vectors.json): every container the
--- other drivers write decrypts here, a file encrypted here decrypts back, the
--- destination names are the macOS ones, a wrong password leaves an approved
--- destination untouched and the password never enters a command line. The
--- flow the user sees runs with scripted dialogs.
--- ==============================================================================

local helpers = require("tests.helpers")
local Core = require("apps.encryptor_core")
local Json = require("json")
local Paths = require("infra.paths")
local quote = require("text_utils").shell_quote

local FORMAT = Core.load_format()
local VECTORS = (function()
	local file = assert(io.open(Paths.shared("tests/corpus/encryptor/vectors.json"), "rb"))
	local raw = file:read("*a")
	file:close()
	return Json.decode(raw)
end)()

local function from_hex(hex) return (hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)) end
local function to_hex(bytes) return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local function work_dir()
	local pipe = assert(io.popen("mktemp -d"))
	local dir = pipe:read("*l")
	pipe:close()
	return dir
end
local function write(path, bytes) local f = assert(io.open(path, "wb")); f:write(bytes); f:close() end
local function read(path) local f = io.open(path, "rb"); if not f then return nil end local b = f:read("*a"); f:close(); return b end
local function cleanup(dir) os.execute("rm -rf " .. quote(dir)) end

local function openssl_available()
	local status = os.execute("command -v openssl >/dev/null 2>&1")
	return status == true or status == 0
end

helpers.describe("Linux Encryptor (shared container)", function()
	helpers.it("encryptor: names destinations as the macOS Encryptor does", function()
		for _, case in ipairs(VECTORS.names) do
			if not case.source:find("\\", 1, true) then
				local mode, destination = Core.destination(FORMAT, case.source)
				helpers.assert_eq(mode, case.mode, case.source)
				helpers.assert_eq(destination, case.destination, case.source)
			end
		end
	end)

	helpers.it("encryptor: passes the shared cipher, KDF and iterations to openssl", function()
		local words = table.concat(Core.openssl_words(FORMAT, "encrypt", "in", "out", "/p"), " ")
		helpers.assert_contains(words, "-aes-256-cbc -pbkdf2 -iter 600000 -md sha256")
		helpers.assert_contains(words, "-pass file:/p")
	end)

	if not openssl_available() then return end

	helpers.it("encryptor: decrypts every shared container to its plaintext", function()
		local dir = work_dir()
		for _, vector in ipairs(VECTORS.containers) do
			write(dir .. "/v.enc", from_hex(vector.container_hex))
			local ok, reason = Core.convert(FORMAT, "decrypt", dir .. "/v.enc", dir .. "/v", vector.password, "openssl")
			helpers.assert_true(ok, vector.id .. ": " .. tostring(reason))
			helpers.assert_eq(to_hex(read(dir .. "/v")), vector.plaintext_hex, vector.id)
		end
		cleanup(dir)
	end)

	helpers.it("encryptor: writes a container that decrypts back and carries the shared header", function()
		local dir = work_dir()
		local plaintext = "Bonjour ✓\0binary\255"
		write(dir .. "/note.txt", plaintext)
		helpers.assert_true((Core.convert(FORMAT, "encrypt", dir .. "/note.txt", dir .. "/note.txt.enc", "pässwörd", "openssl")))
		local container = read(dir .. "/note.txt.enc")
		helpers.assert_eq(container:sub(1, 8), FORMAT.magic)
		helpers.assert_true((Core.convert(FORMAT, "decrypt", dir .. "/note.txt.enc", dir .. "/back", "pässwörd", "openssl")))
		helpers.assert_eq(read(dir .. "/back"), plaintext)
		cleanup(dir)
	end)

	helpers.it("encryptor: leaves an approved destination intact when the password is wrong", function()
		local dir = work_dir()
		local vector = VECTORS.containers[1]
		write(dir .. "/v.enc", from_hex(vector.container_hex))
		write(dir .. "/v", "previous bytes")
		local ok = Core.convert(FORMAT, "decrypt", dir .. "/v.enc", dir .. "/v", VECTORS.wrong_password, "openssl")
		helpers.assert_true(not ok)
		helpers.assert_eq(read(dir .. "/v"), "previous bytes")
		local pipe = io.popen("ls -A " .. quote(dir))
		local listing = pipe:read("*a")
		pipe:close()
		helpers.assert_eq(listing, "v\nv.enc\n")
		cleanup(dir)
	end)

	helpers.it("encryptor: never puts the password in a command line", function()
		local dir = work_dir()
		write(dir .. "/a", "x")
		local secret = "s3ntinel-'pw $HOME é"
		local seen = {}
		local execute, popen = os.execute, io.popen
		os.execute = function(command) seen[#seen + 1] = command; return execute(command) end
		io.popen = function(command, mode) seen[#seen + 1] = command; return popen(command, mode) end
		local ok, err = pcall(Core.convert, FORMAT, "encrypt", dir .. "/a", dir .. "/a.enc", secret, "openssl")
		os.execute, io.popen = execute, popen
		helpers.assert_true(ok and err, tostring(err))
		for _, command in ipairs(seen) do
			helpers.assert_true(not command:find("s3ntinel", 1, true), "password in: " .. command)
		end
		cleanup(dir)
	end)

	helpers.it("encryptor: runs the dialog sequence: confirm, mismatch retry, convert, reveal", function()
		local dir = work_dir()
		write(dir .. "/doc.pdf", "pdf bytes")
		local answers = { "one", "two", "pw", "pw" }
		local log = {}
		local dialogs = {
			entry = function(_, text) log[#log + 1] = "entry:" .. text; return table.remove(answers, 1) end,
			message = function(kind, _, text) log[#log + 1] = kind .. ":" .. text; return true end,
			question = function(_, text) log[#log + 1] = "question:" .. text; return true end,
			file = function() error("no picker expected") end,
		}
		local revealed
		local outcomes = Core.run({ dir .. "/doc.pdf" }, {
			dialogs = dialogs, t = function(key) return key end, format = FORMAT, openssl = "openssl",
			reveal = function(path) revealed = path end,
		})
		helpers.assert_eq(outcomes[1], "done")
		helpers.assert_eq(log[3], "warning:apps.encryptor.err_password_mismatch")
		helpers.assert_eq(revealed, dir .. "/doc.pdf.enc")
		helpers.assert_true((Core.convert(FORMAT, "decrypt", dir .. "/doc.pdf.enc", dir .. "/check", "pw", "openssl")))
		helpers.assert_eq(read(dir .. "/check"), "pdf bytes")
		cleanup(dir)
	end)

	helpers.it("encryptor: asks before overwriting and stops on cancel", function()
		local dir = work_dir()
		write(dir .. "/doc", "a")
		write(dir .. "/doc.enc", "keep")
		local asked = false
		local outcomes = Core.run({ dir .. "/doc" }, {
			dialogs = {
				question = function() asked = true; return false end,
				entry = function() error("no password after a refused overwrite") end,
			},
			t = function(key) return key end, format = FORMAT, openssl = "openssl", reveal = function() end,
		})
		helpers.assert_true(asked)
		helpers.assert_eq(outcomes[1], "cancelled")
		helpers.assert_eq(read(dir .. "/doc.enc"), "keep")
		cleanup(dir)
	end)
end)
