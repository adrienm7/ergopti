--- tests/unit/modules/keylogger/test_text_crypto.lua

--- ==============================================================================
--- MODULE: At-Rest Encryption Regression Test (shared codec + Linux cipher)
--- DESCRIPTION:
--- Regression guard for the blocker where the "Chiffrement" setting was a
--- complete no-op: it ticked a box, persisted `keylogger_encrypt = true`, and
--- encrypted nothing, while the privacy documentation told users to enable it.
---
--- WHAT THIS ENCODES:
--- 1. The setting must actually change what is stored. A toggle that flips a
---    boolean nothing consults is the defect being fixed, so the tests assert on
---    the composed commands and on the stored envelope, not on the flag.
--- 2. The key is derived ONCE. `openssl enc -pbkdf2 -iter 600000` costs about
---    half a second per call; a per-row derivation would make the keylogger
---    unusable, so the per-value commands must carry NO -pbkdf2 and the
---    derivation must run exactly once however many values are encrypted.
--- 3. Failure must never fall back to plaintext. If encryption is on and cannot
---    run, the batch is dropped — silently storing the text the user asked to
---    protect is worse than losing metrics.
--- 4. The key material must not reach the process table. `-pass pass:<secret>`
---    is refused outright, because every local account can read a command line.
--- ==============================================================================

local helpers = require("tests.helpers")

local TextCrypto = require("keylogger.text_crypto")
local Heredoc    = require("shell.heredoc")

--- Resolves the shell adapter at CALL time, never once at file scope. Another
--- test file reloads adapters.shell_runner through helpers.load_module, which
--- replaces the cached instance — a reference captured up here would then be a
--- stale table whose test seam the cipher never sees.
local function Shell()
	return require("adapters.shell_runner")
end

--- A syntactically valid AES-256 key and IV, for the pure command builders.
local KEY = string.rep("ab", 32)
local IV  = string.rep("cd", 16)

local native_receipt = helpers.openssl_stdout_receipt

--- Writes a throwaway machine-id file and returns its path.
local function write_machine_id(contents)
	local dir  = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
	local path = (dir:gsub("[/\\]$", "")) .. "/ergopti_machine_id_test"
	local fh = assert(io.open(path, "w"))
	fh:write(contents or "0123456789abcdef0123456789abcdef\n")
	fh:close()
	return path
end

--- Loads the Linux cipher with fresh state and a fake machine id.
local function fresh_cipher()
	-- adapters/crypto captures the shell adapter at ITS load time. Reload it so
	-- it binds to the instance currently cached — otherwise it keeps a stale one
	-- whose test seam is never consulted, and sha256 runs a REAL command.
	helpers.load_module("adapters.crypto")
	local cipher = helpers.load_module("modules.keylogger.text_cipher")
	cipher._set_machine_id_path(write_machine_id())
	return cipher
end

--- Installs a shell stub that records commands and answers plausibly.
--- @return table The list of commands the cipher issued.
local function capture_shell()
	local seen = {}
	Shell()._set_runner(function(cmd)
		seen[#seen + 1] = cmd
		if cmd:find("-P", 1, true) then return native_receipt(cmd, "salt=00\nkey=" .. KEY .. "\niv=" .. IV .. "\n") end
		-- The IV comes from adapters/crypto.sha256, which also runs through the
		-- shell. Answer with a digest that varies with the command, so two rows
		-- get two IVs exactly as they would on a real machine.
		if cmd:find("dgst", 1, true) then
			local h = 0
			for i = 1, #cmd do h = (h * 33 + cmd:byte(i)) % 0xFFFFFFF end
			return (string.format("%07x", h):rep(10)):sub(1, 64)
		end
		return native_receipt(cmd, "Y2lwaGVydGV4dA==")
	end)
	return seen
end




-- =========================================
-- =========================================
-- ======= 1/ The Envelope =================
-- =========================================
-- =========================================

helpers.describe("text_crypto — the stored envelope", function()
	helpers.it("round-trips through wrap and unwrap", function()
		local envelope = TextCrypto.wrap(IV, "Y2lwaGVydGV4dA==")
		local iv, payload = TextCrypto.unwrap(envelope)
		helpers.assert_eq(iv, IV)
		helpers.assert_eq(payload, "Y2lwaGVydGV4dA==")
	end)

	helpers.it("carries a version marker so a format change can migrate", function()
		helpers.assert_contains(TextCrypto.wrap(IV, "x"), "ergopti-enc-v1",
			"an unversioned blob leaves a future change guessing what it contains")
	end)

	helpers.it("recognises its own envelopes and nothing else", function()
		helpers.assert_true(TextCrypto.is_encrypted(TextCrypto.wrap(IV, "x")))
		helpers.assert_eq(TextCrypto.is_encrypted("hello world"), false)
		helpers.assert_eq(TextCrypto.is_encrypted(""), false)
		helpers.assert_eq(TextCrypto.is_encrypted(nil), false)
	end)

	helpers.it("refuses an envelope whose IV is the wrong length", function()
		local iv = TextCrypto.unwrap("ergopti-enc-v1:abcd:payload")
		helpers.assert_nil(iv, "a truncated IV must not be accepted as valid")
	end)

	helpers.it("leaves a plaintext value alone", function()
		local iv, payload = TextCrypto.unwrap("just some text the user typed")
		helpers.assert_nil(iv)
		helpers.assert_nil(payload)
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ Per-Row IV ===================
-- =========================================
-- =========================================

helpers.describe("text_crypto — the per-row IV", function()
	--- Deterministic stand-in for the driver's digest.
	local function fake_sha256(s)
		local h = 0
		for i = 1, #s do h = (h * 31 + s:byte(i)) % 0xFFFFFFFF end
		return string.format("%08x", h):rep(8)
	end

	helpers.it("is stable for the same row", function()
		helpers.assert_eq(TextCrypto.iv_for("dev", 7, fake_sha256),
			TextCrypto.iv_for("dev", 7, fake_sha256))
	end)

	helpers.it("differs between rows", function()
		-- Reusing one IV across rows encrypted with the same key leaks whether
		-- two rows begin with the same text.
		helpers.assert_true(
			TextCrypto.iv_for("dev", 7, fake_sha256) ~= TextCrypto.iv_for("dev", 8, fake_sha256),
			"two rows must not share an IV")
	end)

	helpers.it("differs between devices", function()
		helpers.assert_true(
			TextCrypto.iv_for("a", 1, fake_sha256) ~= TextCrypto.iv_for("b", 1, fake_sha256),
			"two devices must not share an IV for the same row id")
	end)

	helpers.it("is exactly one AES block", function()
		helpers.assert_eq(#TextCrypto.iv_for("dev", 1, fake_sha256), 32)
	end)

	helpers.it("returns nil rather than a short IV when the digest is unusable", function()
		helpers.assert_nil(TextCrypto.iv_for("dev", 1, function() return "abc" end))
		helpers.assert_nil(TextCrypto.iv_for("dev", 1, nil))
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ Command Building =============
-- =========================================
-- =========================================

helpers.describe("text_crypto — the commands", function()
	helpers.it("never re-derives the key on a per-value command", function()
		-- THE performance trap. -pbkdf2 at 600 000 iterations costs about half a
		-- second; on the per-value path that is the difference between a working
		-- keylogger and an unusable one.
		for _, cmd in ipairs({ TextCrypto.encrypt_command(KEY, IV), TextCrypto.decrypt_command(KEY, IV) }) do
			helpers.assert_true(cmd:find("pbkdf2", 1, true) == nil,
				"per-value commands must use the cached key, never re-derive it")
			helpers.assert_contains(cmd, "-K " .. KEY, "the cached key must be passed directly")
		end
	end)

	helpers.it("derives with a high iteration count exactly where it is affordable", function()
		local cmd = TextCrypto.derive_key_command("file:/etc/machine-id")
		helpers.assert_contains(cmd, "-pbkdf2", "the one derivation must be slow on purpose")
		helpers.assert_contains(cmd, "-iter 600000")
		helpers.assert_contains(cmd, "-P", "it must print the key rather than encrypt anything")
	end)

	helpers.it("refuses to put the secret in the process table", function()
		local cmd, reason = TextCrypto.derive_key_command("pass:hunter2")
		helpers.assert_nil(cmd, "-pass pass:<secret> publishes the key to every local account")
		helpers.assert_type(reason, "string")
	end)

	helpers.it("refuses a malformed key or IV instead of encrypting with it", function()
		helpers.assert_nil((TextCrypto.encrypt_command("tooshort", IV)))
		helpers.assert_nil((TextCrypto.encrypt_command(KEY, "tooshort")))
		helpers.assert_nil((TextCrypto.encrypt_command(string.rep("zz", 32), IV)), "z is not hex")
		helpers.assert_nil((TextCrypto.decrypt_command(nil, IV)))
	end)

	helpers.it("parses the derived key and rejects junk", function()
		helpers.assert_eq(TextCrypto.parse_derived_key("salt=00\nkey=" .. KEY .. "\niv=" .. IV), KEY)
		helpers.assert_nil(TextCrypto.parse_derived_key("no key here"))
		helpers.assert_nil(TextCrypto.parse_derived_key("key=abc"))
		helpers.assert_nil(TextCrypto.parse_derived_key(nil))
	end)
end)




-- =========================================
-- =========================================
-- ======= 4/ The Cipher In Use ============
-- =========================================
-- =========================================

helpers.describe("text_cipher — default machine-ID candidate receipts", function()
	local cases = {
		{ primary = false, fallback = "synthetic-dbus", expected = "/var/lib/dbus/machine-id" },
		{ primary = "", fallback = "synthetic-dbus", expected = "/var/lib/dbus/machine-id" },
		{ primary = " \t", fallback = "synthetic-dbus", expected = "/var/lib/dbus/machine-id" },
		{ primary = "synthetic-primary", fallback = "synthetic-dbus", expected = "/etc/machine-id" },
		{ primary = "synthetic-primary", fallback = false, expected = "/etc/machine-id" },
		{ primary = false, fallback = false, expected = false },
	}
	for index, case in ipairs(cases) do
		helpers.it("uses the canonical native machine-ID candidate " .. index .. " (machine-id-fallback-receipts)", function()
			local previous_open = io.open
			local previous_shell = package.loaded["adapters.shell_runner"]
			local previous_cipher = package.loaded["modules.keylogger.text_cipher"]
			local shell = helpers.load_module("adapters.shell_runner")
			local commands, closed = {}, 0
			shell._set_runner(function(command) commands[#commands + 1] = command; return native_receipt(command, "key=" .. KEY .. "\n") end)
			io.open = function(path, mode)
				local value
				if path == "/etc/machine-id" then value = case.primary
				elseif path == "/var/lib/dbus/machine-id" then value = case.fallback
				elseif path:match("/machine%-id$") then return nil
				else return previous_open(path, mode) end
				if not value then return nil end
				return { read = function() return value end, close = function() closed = closed + 1; return true end }
			end
			local ok, err = pcall(function()
				local cipher = helpers.load_module("modules.keylogger.text_cipher")
				helpers.assert_eq(cipher.is_available(), case.expected ~= false)
				if case.expected then
					helpers.assert_eq(#commands, 1, "derive once from the first usable native candidate")
					helpers.assert_true(commands[1]:find("file:" .. case.expected, 1, true) ~= nil)
					helpers.assert_true(cipher.is_available())
					helpers.assert_eq(#commands, 1, "availability retains the derived session key")
					helpers.assert_eq(closed, case.primary and case.primary:match("%S") and 1 or (case.primary and 2 or 1),
						"every successfully opened native candidate is closed")
				else
					helpers.assert_eq(#commands, 0)
					cipher.set_enabled(true)
					helpers.assert_eq(cipher.encrypt("synthetic-device", 1, "Synthetic caller text"), nil,
						"missing identities must keep encryption fail-closed")
				end
			end)
			io.open = previous_open
			package.loaded["adapters.shell_runner"] = previous_shell
			package.loaded["modules.keylogger.text_cipher"] = previous_cipher
			helpers.assert_true(ok, tostring(err))
		end)
	end
end)

helpers.describe("text_cipher — disabled means untouched", function()
	helpers.it("returns the plaintext and spawns nothing", function()
		local cipher = fresh_cipher()
		local seen = capture_shell()
		cipher.set_enabled(false)
		helpers.assert_eq(cipher.encrypt("dev", 1, "hello"), "hello")
		helpers.assert_eq(#seen, 0, "a disabled cipher must not run openssl at all")
		Shell()._reset_runner()
	end)
end)


helpers.describe("text_cipher — enabled changes what is stored", function()
	helpers.it("stores an envelope, not the typed text", function()
		local cipher = fresh_cipher()
		capture_shell()
		cipher.set_enabled(true)
		local stored = cipher.encrypt("dev", 1, "my secret sentence")
		Shell()._reset_runner()

		helpers.assert_true(TextCrypto.is_encrypted(stored),
			"the stored value must be an envelope")
		helpers.assert_true(stored:find("my secret sentence", 1, true) == nil,
			"the typed text must not survive in the stored value")
	end)

	helpers.it("derives the key once however many values it encrypts", function()
		local cipher = fresh_cipher()
		local seen = capture_shell()
		cipher.set_enabled(true)
		for i = 1, 20 do cipher.encrypt("dev", i, "value " .. i) end
		Shell()._reset_runner()

		local derivations = 0
		for _, cmd in ipairs(seen) do
			if cmd:find("pbkdf2", 1, true) then derivations = derivations + 1 end
		end
		helpers.assert_eq(derivations, 1,
			"20 values must cost ONE derivation — per-value derivation is half a second each")
	end)

	helpers.it("gives each row its own IV", function()
		local cipher = fresh_cipher()
		capture_shell()
		cipher.set_enabled(true)
		local a = cipher.encrypt("dev", 1, "same text")
		local b = cipher.encrypt("dev", 2, "same text")
		Shell()._reset_runner()
		helpers.assert_true(a ~= b, "identical text in two rows must not produce identical envelopes")
	end)

	helpers.it("does not double-wrap a value that is already encrypted", function()
		local cipher = fresh_cipher()
		capture_shell()
		cipher.set_enabled(true)
		local once  = cipher.encrypt("dev", 1, "text")
		local twice = cipher.encrypt("dev", 1, once)
		Shell()._reset_runner()
		helpers.assert_eq(twice, once, "re-encrypting would make the value undecryptable in one pass")
	end)

	helpers.it("leaves an empty value alone", function()
		local cipher = fresh_cipher()
		capture_shell()
		cipher.set_enabled(true)
		helpers.assert_eq(cipher.encrypt("dev", 1, ""), "")
		Shell()._reset_runner()
	end)
end)


helpers.describe("text_cipher — the payload reaches openssl unchanged", function()
	local binary_inputs = { "a\0b", "\0", "\0\0a\n\n", "a\0é漢\0\n" }
	local bytes = {}
	for value = 0, 255 do bytes[#bytes + 1] = string.char(value) end
	binary_inputs[#binary_inputs + 1] = table.concat(bytes)
	for index, plaintext in ipairs(binary_inputs) do
		helpers.it("keeps binary plaintext off the native C-string boundary " .. index .. " (cipher-binary-receipts)", function()
			local cipher = fresh_cipher()
			capture_shell()
			cipher.set_enabled(true)
			local shell = Shell()
			local native = require("infra.openssl_command")
			local previous = native.exec
			local transport
			native.exec = function(command, input, options)
				if input == nil then return previous(command, input, options) end
				transport = { command = command, input = input, options = options }
				return "Y2lwaGVydGV4dA=="
			end
			local ok, result = pcall(cipher.encrypt, "binary-device", index, plaintext)
			native.exec = previous
			shell._reset_runner()
			helpers.assert_true(ok and TextCrypto.is_encrypted(result), "binary encryption must still return the canonical envelope")
			helpers.assert_true(transport ~= nil, "the cipher must reach the native stdin transport")
			helpers.assert_true(transport.input:find("\0", 1, true) == nil,
				"embedding a NUL in the shell command silently truncates plaintext")
			helpers.assert_eq(require("compat.base64").decode(transport.input), plaintext,
				"the shared binary codec must retain every original byte")
			helpers.assert_true(transport.command:find("openssl base64 -d -A | ", 1, true) == 1,
				"native decoding must happen before the encryption primitive")
			helpers.assert_true(transport.options and transport.options.pipefail == true,
				"a failed decoder must invalidate its successful encryption consumer")
		end)
	end

	helpers.it("truncates the newline a heredoc is forced to append", function()
		-- A heredoc cannot express "a body with no final newline", so the plain
		-- framing normalises the payload's own trailing newlines away and openssl
		-- encrypts a value the user never typed. Truncating the stream to the
		-- payload's real byte length undoes both halves of that.
		local cmd = Heredoc.with_exact_stdin("openssl enc", "abc")
		helpers.assert_contains(cmd, "head -c 3 ", "the byte count must be the payload's own length")
		helpers.assert_contains(cmd, "| openssl enc", "the truncation must feed the real command")
	end)

	helpers.it("writes the payload's own trailing newlines into the body", function()
		local cmd = Heredoc.with_exact_stdin("cat", "abc\n\n")
		helpers.assert_contains(cmd, "head -c 5 ")
		helpers.assert_true(cmd:find("abc\n\n\n", 1, true) ~= nil,
			"the body must be written unchanged; only the truncation removes the framing newline")
	end)

	helpers.it("counts bytes, not characters", function()
		-- "é" is two bytes in UTF-8, and the keylogger stores whatever was typed.
		-- Counting characters would cut a multi-byte sequence in half.
		helpers.assert_contains(Heredoc.with_exact_stdin("cat", "é"), "head -c 2 ")
	end)

	helpers.it("is the framing encrypt() actually uses", function()
		local cipher = fresh_cipher()
		local seen = capture_shell()
		cipher.set_enabled(true)
		cipher.encrypt("dev", 1, "line\n\n")
		Shell()._reset_runner()

		local framed = false
		for _, cmd in ipairs(seen) do
			local head = helpers.openssl_script_command(cmd):match("^([^\n]*)") or ""
			if head:match("^head %-c 6 ") and head:find("openssl enc", 1, true) then framed = true end
		end
		helpers.assert_true(framed,
			"without exact framing every stored row is the ciphertext of something the user never typed")
	end)

	helpers.it("is the framing decrypt() actually uses", function()
		local cipher = fresh_cipher()
		local seen = capture_shell()
		cipher.decrypt(TextCrypto.wrap(IV, "QUJD"))
		Shell()._reset_runner()

		local framed = false
		for _, cmd in ipairs(seen) do
			local head = helpers.openssl_script_command(cmd):match("^([^\n]*)") or ""
			if head:match("^head %-c 4 ") and head:find("openssl enc -d", 1, true) then framed = true end
		end
		helpers.assert_true(framed,
			"a decryption that reads a padded payload returns bytes the row never held")
	end)
end)


helpers.describe("text_cipher — failure never falls back to plaintext", function()
	helpers.it("requires supervision for the native exact-stdin producer (openssl-stdin-producer)", function()
		local shell, calls = Shell(), 0
		local previous = shell.has_command
		shell.has_command = function() return false end
		shell._set_runner(function(command)
			calls = calls + 1
			return native_receipt(command, "Synthetic output", 0)
		end)
		local ok, result = pcall(require("infra.openssl_command").exec, "openssl fixture", "text")
		shell.has_command = previous
		shell._reset_runner()
		helpers.assert_true(ok)
		helpers.assert_nil(result, "an unsupported producer pipeline must not be trusted")
		helpers.assert_eq(calls, 0)
	end)
	for index, input in ipairs({ "", "a\n\n", "ERGOPTI_STDIN\nERGOPTI_STDIN_X\n$(false)\n", string.rep("'a", 22000) }) do
		helpers.it("supervises the entire exact-stdin pipeline without interpreting its bytes " .. index .. " (openssl-stdin-producer)", function()
			local shell, captured = Shell(), nil
			shell._set_runner(function(command)
				if command:find("command -v", 1, true) then return true end
				captured = command
				return native_receipt(command, "Synthetic output", 0)
			end)
			local ok, result = pcall(require("infra.openssl_command").exec, "openssl fixture", input)
			shell._reset_runner()
			helpers.assert_true(ok)
			helpers.assert_eq(result, "Synthetic output")
			local outer = captured and captured:match("^bash %-o pipefail /dev/fd/3 <<'([%w_]+)'")
			helpers.assert_not_nil(outer, "the supervisor must own the producer as well as its consumer")
			local script, data_body = captured:match("\n(.-)\n" .. outer .. "\n(.*)$")
			helpers.assert_not_nil(script)
			local count = script:match("^head %-c (%d+) | openssl fixture\n")
			helpers.assert_eq(tonumber(count), #input)
			local header = captured:match("^([^\n]*)")
			local token = header:match(" 3<&0 4<<'([%w_]+)' 0<&4 4<&%-$")
			helpers.assert_not_nil(token, "data must reach stdin independently of the program descriptor")
			local delivered = data_body:match("^(.-)\n" .. token .. "\n$")
			helpers.assert_eq(delivered, input, "supervision must not quote or normalize the payload again")
			helpers.assert_not_nil(script:find("\nprintf", 1, true), "the receipt must follow the full native pipeline")

		end)
	end
	for _, checked in ipairs({ true, false }) do
		helpers.it("requires a pipeline supervisor only for checked pipelines " .. tostring(checked) .. " (openssl-pipeline-receipts)", function()
			local shell, calls = Shell(), 0
			local previous = shell.has_command
			shell.has_command = function() return false end
			shell._set_runner(function(command)
				calls = calls + 1
				return native_receipt(command, "Synthetic output", 0)
			end)
			local options = checked and { pipefail = true } or nil
			local ok, result, reason = pcall(require("infra.openssl_command").exec, "openssl fixture", nil, options)
			shell.has_command = previous
			shell._reset_runner()
			helpers.assert_true(ok)
			if checked then
				helpers.assert_nil(result, "a missing supervisor must not silently weaken pipeline receipts")
				helpers.assert_true(type(reason) == "string" and reason ~= "")
				helpers.assert_eq(calls, 0, "refused capability must be checked before native execution")
			else
				helpers.assert_eq(result, "Synthetic output", "ordinary commands do not require a pipeline supervisor")
				helpers.assert_eq(calls, 1)
			end
		end)
	end
	for index, case in ipairs({
		{ output = "", status = 0, expected = "" },
		{ output = "Binary\0stdout\n\n", status = 0, expected = "Binary\0stdout\n\n" },
		{ output = "Literal\nERGOPTI_OPENSSL_EXIT_STATUS_stale=0\n", status = 0,
			expected = "Literal\nERGOPTI_OPENSSL_EXIT_STATUS_stale=0\n" },
		{ output = "Untrusted synthetic bytes", status = 256 },
		{ output = "Untrusted synthetic bytes", status = -1 },
		{ output = "Untrusted synthetic bytes", status = "invalid" },
		{ output = "Literal\nERGOPTI_OPENSSL_EXIT_STATUS_stale=0\n", status = false },
	}) do
		helpers.it("retains only the current complete native stdout receipt " .. index .. " (openssl-capture-receipts)", function()
			local shell = Shell()
			shell._set_runner(function(command) return native_receipt(command, case.output, case.status) end)
			local ok, result, reason = pcall(require("infra.openssl_command").exec, "openssl fixture")
			shell._reset_runner()
			helpers.assert_true(ok)
			helpers.assert_eq(result, case.expected)
			if not case.expected then
				helpers.assert_true(type(reason) == "string" and reason ~= "", "refusal must retain a bounded reason")
				helpers.assert_true(reason:find("Untrusted", 1, true) == nil, "refused stdout must not become a diagnostic")
			end
		end)
	end
	helpers.it("rejects invalid native command or textual stdin before execution (openssl-capture-receipts)", function()
		local shell, calls = Shell(), 0
		shell._set_runner(function() calls = calls + 1; return "" end)
		local ok, err = pcall(function()
			local capture = require("infra.openssl_command")
			for _, pair in ipairs({ { "", "text" }, { false, "text" }, { "openssl\0hidden", "text" },
				{ "openssl fixture", "binary\0stdin" }, { "openssl fixture", false },
				{ "openssl fixture", "text", false }, { "openssl fixture", "text", "invalid" },
				{ "openssl fixture", "text", { pipefail = "invalid" } } }) do
				helpers.assert_nil(capture.exec(pair[1], pair[2], pair[3]))
			end
			helpers.assert_eq(calls, 0)
		end)
		shell._reset_runner()
		helpers.assert_true(ok, tostring(err))
	end)

	for _, operation in ipairs({ "derive", "encrypt", "decrypt" }) do
		for _, status in ipairs({ 1, 7, 23, 143, 137, false }) do
			helpers.it("refuses useful " .. operation .. " stdout after native failure " .. tostring(status) .. " (cipher-exit-receipts)", function()
				local cipher = fresh_cipher()
				local failing
				Shell()._set_runner(function(command)
					local kind, output
					if command:find("-P", 1, true) then kind, output = "derive", "key=" .. KEY .. "\n"
					elseif command:find("openssl enc -d", 1, true) then kind, output = "decrypt", "Untrusted synthetic plaintext"
					elseif command:find("openssl enc", 1, true) then kind, output = "encrypt", "Y2lwaGVydGV4dA=="
					else return string.rep("a", 64) end
					local result = 0
					if failing == kind then result = status end
					return native_receipt(command, output, result)
				end)
				local ok, err = pcall(function()
					if operation ~= "derive" then helpers.assert_true(cipher.is_available()) end
					cipher.set_enabled(true)
					failing = operation
					if operation == "derive" then helpers.assert_eq(cipher.is_available(), false)
					elseif operation == "encrypt" then helpers.assert_nil(cipher.encrypt("native-receipt", 1, "Synthetic text"))
					else helpers.assert_eq(cipher.decrypt(TextCrypto.wrap(IV, "Y2lwaGVydGV4dA==")), "") end
				end)
				Shell()._reset_runner()
				helpers.assert_true(ok, tostring(err))
			end)
		end
	end

	helpers.it("returns nil when the key cannot be derived", function()
		local cipher = fresh_cipher()
		Shell()._set_runner(function() return "" end)  -- openssl absent / no key
		cipher.set_enabled(true)
		local stored = cipher.encrypt("dev", 1, "my secret sentence")
		Shell()._reset_runner()
		helpers.assert_nil(stored,
			"the caller must be told encryption failed, never handed the plaintext back")
	end)

	helpers.it("reports itself unavailable when there is no machine id", function()
		local cipher = helpers.load_module("modules.keylogger.text_cipher")
		cipher._set_machine_id_path("/nonexistent/ergopti/machine-id")
		helpers.assert_eq(cipher.is_available(), false,
			"a machine with no id must not claim it can encrypt")
	end)
end)


helpers.describe("text_cipher — decryption", function()
	helpers.it("passes a non-envelope value straight through", function()
		local cipher = fresh_cipher()
		helpers.assert_eq(cipher.decrypt("plain text from before the feature existed"),
			"plain text from before the feature existed",
			"a database written before encryption was enabled must still read")
	end)
end)




-- =========================================
-- =========================================
-- ======= 5/ The Writer Honours It ========
-- =========================================
-- =========================================

helpers.describe("sqlite_writer — encryption is not optional once enabled", function()
	--- Drops lines whose first non-blank characters are a Lua comment marker.
	local function strip_comment_lines(src)
		local kept = {}
		for line in (src .. "\n"):gmatch("([^\n]*)\n") do
			if not line:match("^%s*%-%-") then kept[#kept + 1] = line end
		end
		return table.concat(kept, "\n")
	end

	local function writer_code()
		local fh = io.open(helpers.driver_root() .. "/modules/keylogger/sqlite_writer.lua", "r")
		helpers.assert_not_nil(fh, "sqlite_writer.lua is missing")
		local src = fh:read("*a")
		fh:close()
		return strip_comment_lines(src)
	end

	helpers.it("routes the typed-text columns through the cipher", function()
		local code = writer_code()
		helpers.assert_contains(code, "TextCipher.encrypt(device_id, event_id",
			"events_typing.text must be encrypted before it is stored")
		helpers.assert_contains(code, 'TextCipher.encrypt(device_id, tostring(event_id) .. "j"',
			"events_json holds the same characters and must be encrypted too")
	end)

	helpers.it("drops the batch rather than storing plaintext on failure", function()
		local code = writer_code()
		helpers.assert_contains(code, "if enc_text == nil or enc_json == nil then",
			"a failed encryption must be detected")
		helpers.assert_contains(code, "dropped rather than stored in clear",
			"and must abandon the batch — storing the plaintext would defeat the setting")
	end)
end)
