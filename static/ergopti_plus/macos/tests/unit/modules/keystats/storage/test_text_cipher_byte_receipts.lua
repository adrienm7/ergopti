--- tests/unit/modules/keystats/storage/test_text_cipher_byte_receipts.lua

--- ==============================================================================
--- MODULE: At-Rest Cipher Byte and Receipt Regression Tests (macOS)
--- DESCRIPTION:
--- The macOS at-rest cipher runs openssl through hs.execute, which hands /bin/sh
--- a C string. It used to:
--- 1. place typed text in a heredoc, so a NUL truncated the command and openssl
---    encrypted only the prefix while a valid envelope was stored
---    (cipher-nul-transport-2026-10-21);
--- 2. ignore the exit status, so the partial stdout of a failed openssl (a bad
---    decrypt prints the blocks before the padding check) became the value
---    (cipher-exit-receipt-2026-10-21);
--- 3. trust only the last pipeline stage, so a producer that delivered part of
---    the payload and failed still yielded a stored envelope
---    (cipher-pipeline-receipt-2026-10-21);
--- 4. carry the typed text and the hardware UUID as a printf operand of the
---    `sh -c` command, which every local account can read in the process table
---    (cipher-plaintext-argv-2026-10-22).
--- ==============================================================================

local helpers = require("tests.helpers")
local Double = require("tests.support.keystats.cipher_shell_double")
local TextCrypto = require("keystats.text_crypto")

local MODULES = { "adapters.crypto", "adapters.shell_runner", "modules.keystats.text_cipher", "infra.logger" }

--- Runs a callback against a real cipher over the native shell double.
--- @param faults table|nil Faults forwarded to the double.
--- @param callback function Receives (cipher, seen, logs, native).
local function with_cipher(faults, callback)
	helpers.with_fresh_modules(MODULES, function()
		local execute, seen, native = Double.new(faults)
		helpers.load_with_stubs("adapters.shell_runner", { execute = execute, hash = Double.native_hash() })
		local logs = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, template, ...) logs[#logs + 1] = string.format(template, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.shell_runner"] = nil
		package.loaded["adapters.crypto"] = nil
		require("adapters.shell_runner")._set_private_stdin_native(native)
		local cipher = require("modules.keystats.text_cipher")
		cipher._set_machine_id_command("/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice")
		cipher.set_enabled(true)
		local ok, err = pcall(callback, cipher, seen, logs, native)
		require("adapters.shell_runner")._set_private_stdin_native(nil)
		if not ok then error(err, 0) end
	end)
end

--- Encrypts with a healthy double, returning the stored envelope.
--- @param plaintext string
--- @return string|nil
local function healthy_envelope(plaintext)
	local envelope
	with_cipher(nil, function(cipher) envelope = cipher.encrypt("mac", 7, plaintext) end)
	return envelope
end


helpers.describe("keystats.text_cipher: arbitrary bytes survive the shell (cipher-nul-transport-2026-10-21)", function()
	local all_bytes = {}
	for byte = 0, 255 do all_bytes[#all_bytes + 1] = string.char(byte) end
	local cases = {
		{ "embedded NUL", "a\0b" },
		{ "leading and trailing NUL", "\0abc\0" },
		{ "repeated NUL", "\0\0\0" },
		{ "NUL before digits", "\0" .. "777" },
		{ "literal escapes", "\\0 \\\\ \\c \\n %s %b %%" },
		{ "option-looking text", "-n -e --" },
		{ "quotes and expansions", "it's \"$HOME\" `id` $(id)" },
		{ "trailing newlines", "line\n\n" },
		{ "every byte value", table.concat(all_bytes) },
	}
	for _, case in ipairs(cases) do
		helpers.it("round-trips " .. case[1] .. " byte for byte", function()
			with_cipher(nil, function(cipher, seen)
				local envelope = cipher.encrypt("mac", 7, case[2])
				helpers.assert_true(TextCrypto.is_encrypted(envelope), "encryption must produce an envelope")
				helpers.assert_eq(cipher.decrypt(envelope), case[2],
					"the stored envelope must decrypt to the exact typed bytes")
				for _, command in ipairs(seen) do
					helpers.assert_true(command:find("\0", 1, true) == nil,
						"a command with NUL cannot cross the char * boundary")
				end
			end)
		end)
	end
end)


helpers.describe("keystats.text_cipher: openssl success requires its exit status (cipher-exit-receipt-2026-10-21)", function()
	helpers.it("returns no plaintext from a failed decryption that printed partial bytes", function()
		local envelope = healthy_envelope("secret words")
		with_cipher({ decrypt = { "secret wo", 1 } }, function(cipher, _, logs)
			helpers.assert_eq(cipher.decrypt(envelope), "",
				"partial output of a failed openssl must not become the stored value")
			helpers.assert_true(#logs > 0, "the refused decryption must be logged")
		end)
	end)

	helpers.it("refuses an envelope from a failed encryption that printed output", function()
		with_cipher({ encrypt = { "4142", 1 } }, function(cipher, _, logs)
			helpers.assert_eq(cipher.encrypt("mac", 7, "AB"), nil,
				"a failed encryption must refuse to store, not wrap its stdout")
			helpers.assert_true(#logs > 0, "the refused encryption must be logged")
		end)
	end)

	helpers.it("treats a failed key derivation as unavailable even when it printed a key", function()
		with_cipher({ derive = { "key=" .. Double.KEY .. "\n", 1 } }, function(cipher)
			helpers.assert_eq(cipher.is_available(), false,
				"a key from a failed derivation is not a key")
		end)
	end)
end)


helpers.describe("keystats.text_cipher: every pipeline stage is supervised (cipher-pipeline-receipt-2026-10-21)", function()
	helpers.it("refuses an envelope when the stdin producer failed after a partial delivery", function()
		with_cipher({ producer = 1 }, function(cipher)
			helpers.assert_eq(cipher.encrypt("mac", 7, "twenty-seven typed bytes!!"), nil,
				"a ciphertext of one delivered byte must not be stored for the whole value")
		end)
	end)
end)


helpers.describe("keystats.text_cipher: secrets never reach a command line (cipher-plaintext-argv-2026-10-22)", function()
	local SECRET = "my bank PIN is 4711"
	helpers.it("keeps the typed text and the hardware UUID out of every shell command", function()
		with_cipher(nil, function(cipher, seen, _, native)
			local envelope = cipher.encrypt("mac", 7, SECRET)
			helpers.assert_true(TextCrypto.is_encrypted(envelope), "encryption must produce an envelope")
			helpers.assert_eq(cipher.decrypt(envelope), SECRET, "the envelope must still round-trip")
			helpers.assert_true(#seen >= 3, "derivation, encryption and decryption must all run")
			for _, command in ipairs(seen) do
				helpers.assert_true(command:find(SECRET, 1, true) == nil,
					"typed text in an sh -c argument is readable by every local account")
				helpers.assert_true(command:find("0123456789ABCDEF", 1, true) == nil,
					"the hardware UUID is the key material and must not be an argument")
			end
			helpers.assert_eq(#native.leftover_files(), 0, "every private output file must be removed")
		end)
	end)

	helpers.it("refuses an envelope when standard input was only partly delivered", function()
		with_cipher({ producer = 1 }, function(cipher, _, _, native)
			helpers.assert_eq(cipher.encrypt("mac", 7, SECRET), nil,
				"openssl saw a prefix, so its ciphertext is not the typed value's")
			helpers.assert_eq(#native.leftover_files(), 0, "a refused call must remove its output file")
		end)
	end)
end)
