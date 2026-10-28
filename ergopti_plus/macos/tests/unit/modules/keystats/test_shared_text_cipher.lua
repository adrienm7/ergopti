--- tests/unit/modules/keystats/test_shared_text_cipher.lua

--- ==============================================================================
--- MODULE: Shared Typed-Text Cipher Policy Tests (macOS)
--- DESCRIPTION:
--- Pins the policy both drivers' text ciphers share
--- (_shared/lua/keystats/text_cipher.lua) with a scripted primitive: disabled
--- encryption spawns nothing, an envelope is never wrapped twice, an
--- encryption that cannot happen answers nil instead of plaintext, a failed
--- derivation is latched and not retried, an unreadable envelope reads as the
--- empty string, and a value that is not an envelope reads as itself.
--- ==============================================================================

local helpers = require("tests.helpers")
local Cipher = require("keystats.text_cipher")
local TextCrypto = require("keystats.text_crypto")

local KEY = string.rep("ab", 32)

local function build(overrides)
	local calls = { derive = 0, encrypt = 0, decrypt = 0 }
	local logger = {}
	for _, level in ipairs({ "start", "success", "info", "debug", "warn", "error" }) do logger[level] = function() end end
	local ports = {
		logger = logger, log = "test.cipher",
		sha256 = function(text) return string.rep("0", 56) .. string.format("%08x", #text) end,
		derive_key = function() calls.derive = calls.derive + 1; return KEY end,
		ready = function() return true end,
		encrypt = function(_, _, plaintext) calls.encrypt = calls.encrypt + 1; return "PAYLOAD:" .. plaintext end,
		decrypt = function(_, _, payload) calls.decrypt = calls.decrypt + 1; return (payload:gsub("^PAYLOAD:", "")) end,
	}
	for name, value in pairs(overrides or {}) do ports[name] = value end
	return Cipher.new(ports), calls
end

helpers.describe("shared typed-text cipher policy (macOS)", function()
	helpers.it("returns the plaintext untouched and starts nothing while disabled", function()
		local cipher, calls = build()
		helpers.assert_eq(cipher.encrypt("dev", 1, "secret"), "secret")
		helpers.assert_eq(calls.derive + calls.encrypt, 0)
	end)

	helpers.it("round-trips through the envelope once enabled", function()
		local cipher, calls = build()
		cipher.set_enabled(true)
		local envelope = cipher.encrypt("dev", 1, "secret")
		helpers.assert_true(TextCrypto.is_encrypted(envelope))
		helpers.assert_eq(cipher.decrypt(envelope), "secret")
		helpers.assert_eq(calls.derive, 1, "the key is derived once")
	end)

	helpers.it("does not wrap an envelope twice and leaves empty or non-string values alone", function()
		local cipher, calls = build()
		cipher.set_enabled(true)
		local envelope = cipher.encrypt("dev", 1, "secret")
		helpers.assert_eq(cipher.encrypt("dev", 2, envelope), envelope)
		helpers.assert_eq(cipher.encrypt("dev", 3, ""), "")
		helpers.assert_eq(cipher.encrypt("dev", 4, 7), 7)
		helpers.assert_eq(calls.encrypt, 1)
	end)

	helpers.it("fails closed: no key means nil, never the plaintext, and the failure is latched", function()
		local cipher, calls = build({ derive_key = function() return nil end })
		cipher.set_enabled(true)
		helpers.assert_eq(cipher.encrypt("dev", 1, "secret"), nil)
		helpers.assert_eq(cipher.is_available(), false)
		local counted = 0
		local latched = build({ derive_key = function() counted = counted + 1; return nil end })
		latched.set_enabled(true)
		latched.encrypt("dev", 1, "a"); latched.encrypt("dev", 2, "b"); latched.is_available()
		helpers.assert_eq(counted, 1, "a failed derivation is not retried")
		latched.reset_key()
		latched.encrypt("dev", 3, "c")
		helpers.assert_eq(counted, 2, "reset_key clears the latch")
		helpers.assert_eq(calls.encrypt, 0)
	end)

	helpers.it("answers nil when the primitive refuses to encrypt or is not ready", function()
		local refusing = build({ encrypt = function() return nil end })
		refusing.set_enabled(true)
		helpers.assert_eq(refusing.encrypt("dev", 1, "secret"), nil)
		local derived = 0
		local unready = build({ ready = function() return false end, derive_key = function() derived = derived + 1; return KEY end })
		unready.set_enabled(true)
		helpers.assert_eq(unready.encrypt("dev", 1, "secret"), nil)
		helpers.assert_eq(derived, 0, "readiness is checked before the key is derived")
	end)

	helpers.it("fails open on decryption: a plain value reads as itself, an unreadable envelope as empty", function()
		local cipher = build()
		cipher.set_enabled(true)
		local envelope = cipher.encrypt("dev", 1, "secret")
		helpers.assert_eq(cipher.decrypt("plain text"), "plain text")
		helpers.assert_eq(cipher.decrypt(nil), nil)
		helpers.assert_eq(build({ decrypt = function() return nil end }).decrypt(envelope), "")
		helpers.assert_eq(build({ derive_key = function() return nil end }).decrypt(envelope), "")
		helpers.assert_eq(build({ ready = function() return false end }).decrypt(envelope), "")
	end)

	helpers.it("refuses a cipher built without its ports", function()
		helpers.assert_contains(tostring(helpers.assert_throws(function() Cipher.new({}) end)), "needs a logger")
	end)
end)
