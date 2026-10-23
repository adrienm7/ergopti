--- tests/unit/adapters/storage/test_crypto_text_hash_vectors.lua

--- ==============================================================================
--- MODULE: Crypto Text SHA-256 Vector Regression Tests
--- DESCRIPTION:
--- Replays the shared independent SHA-256 corpus through Crypto.sha256(). The
--- text digest used to interpolate its input into a /bin/sh command for
--- openssl. popen(3) stops at the first NUL, so every NUL-bearing vector came
--- back as "" on macOS while Windows and Linux returned the real digest
--- (crypto-text-nul-2026-10-21).
--- ==============================================================================

local helpers = require("tests.helpers")
local Vectors = require("tests.support.sha256_vector_doubles")


local function load_crypto(observed, hash_overrides)
	package.loaded["infra.logger"] = nil
	local Crypto = helpers.load_with_stubs("adapters.crypto", {
		execute = Vectors.shell_execute(observed),
		hash = hash_overrides or Vectors.native_hash(observed),
	})
	return Crypto
end


helpers.describe("adapters.crypto: text SHA-256 over the shared byte corpus (crypto-text-nul-2026-10-21)", function()
	helpers.it("returns the independent digest of every shared vector", function()
		local observed = {}
		local Crypto = load_crypto(observed)
		for _, vector in ipairs(Vectors.VECTORS) do
			helpers.assert_eq(Crypto.sha256(vector.input), vector.sha256,
				"Crypto.sha256 must hash the exact bytes of vector " .. vector.id)
		end
	end)

	helpers.it("never hands text to a shell command", function()
		local observed = {}
		local Crypto = load_crypto(observed)
		Crypto.sha256("it's $HOME `id`\0tail")
		helpers.assert_eq(#observed.commands, 0,
			"a C-string shell boundary cannot carry the digest input")
		helpers.assert_eq(observed.algorithms, { "SHA256" })
	end)

	helpers.it("logs a native digest refusal without its input bytes", function()
		local logs = {}
		local observed = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, template, ...) logs[#logs + 1] = string.format(template, ...) end
		helpers.with_fresh_modules({ "adapters.crypto", "infra.logger" }, function()
			package.loaded["infra.logger"] = logger
			local saved_hs = _G.hs
			_G.hs = {
				execute = Vectors.shell_execute(observed),
				hash = { new = function() error("native refusal near PRIVATE-SSID") end },
			}
			local ok, failure = pcall(function()
				local Crypto = require("adapters.crypto")
				helpers.assert_eq(Crypto.sha256("PRIVATE-SSID"), "")
			end)
			_G.hs = saved_hs
			if not ok then error(failure, 0) end
		end)
		helpers.assert_eq(#logs, 1, "the refusal must stay visible")
		helpers.assert_true(logs[1]:find("PRIVATE", 1, true) == nil,
			"the digest input must not reach the log: " .. logs[1])
		helpers.assert_eq(#observed.commands, 0, "a refusal must not fall back to the shell")
	end)
end)
