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
		if cmd:find("-P", 1, true) then return "salt=00\nkey=" .. KEY .. "\niv=" .. IV .. "\n" end
		-- The IV comes from adapters/crypto.sha256, which also runs through the
		-- shell. Answer with a digest that varies with the command, so two rows
		-- get two IVs exactly as they would on a real machine.
		if cmd:find("dgst", 1, true) then
			local h = 0
			for i = 1, #cmd do h = (h * 33 + cmd:byte(i)) % 0xFFFFFFF end
			return (string.format("%07x", h):rep(10)):sub(1, 64)
		end
		return "Y2lwaGVydGV4dA=="
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


helpers.describe("text_cipher — failure never falls back to plaintext", function()
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
