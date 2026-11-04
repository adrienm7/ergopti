--- tests/unit/adapters/storage/test_crypto_shell_quoting.lua

--- ==============================================================================
--- MODULE: Crypto adapter shell-quoting regression tests
--- DESCRIPTION:
--- Regression for adapters-io-1: crypto.sha256() and network_info sha256_hex()
--- used Lua %q (double-quote escaping) inside an openssl shell command, causing
--- wrong digests and potential shell injection when data contains $, backticks,
--- newlines or backslashes. The text digest now never builds a shell command:
--- these cases pin that the same adversarial text reaches the native hash
--- byte for byte (crypto-text-nul-2026-10-21).
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==============================================================
-- ==============================================================
-- ======= 1/ crypto.sha256 POSIX quoting (adapters-io-1) =======
-- ==============================================================
-- ==============================================================

helpers.describe("adapters.crypto — sha256 never interpolates data into a shell", function()
	local DIGEST = "deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb"

	--- Loads the adapter over a native hash double that records its exact input.
	--- @param observed table Receives execute calls and appended payloads.
	--- @param value string|nil Digest the native context reports.
	--- @return table Crypto
	local function load_crypto(observed, value)
		observed.execute_calls = 0
		observed.payloads = {}
		return helpers.load_with_stubs("adapters.crypto", {
			execute = function()
				observed.execute_calls = observed.execute_calls + 1
				return ""
			end,
			hash = {
				new = function()
					local context = {}
					function context:append(data)
						observed.payloads[#observed.payloads + 1] = data
						return self
					end
					function context:finish() return self end
					function context:value() return value or DIGEST end
					return context
				end,
			},
		})
	end

	for _, data in ipairs({ "hello", "it's a test", "price $HOME dollars", "`id` \\ \"q\"\n" }) do
		helpers.it("hashes " .. string.format("%q", data) .. " natively and byte for byte", function()
			local observed = {}
			local Crypto = load_crypto(observed)
			helpers.assert_eq(Crypto.sha256(data), DIGEST)
			helpers.assert_eq(observed.payloads, { data })
			helpers.assert_eq(observed.execute_calls, 0, "no shell may see the digest input")
		end)
	end

	helpers.it("returns '' when the native digest is not hex", function()
		local Crypto = load_crypto({}, "no hex here")
		helpers.assert_eq(Crypto.sha256("x"), "", "must return '' on a malformed digest")
	end)

	helpers.it("returns '' when the native digest is empty", function()
		local Crypto = load_crypto({}, "")
		helpers.assert_eq(Crypto.sha256("x"), "", "must return '' on an empty digest")
	end)

	helpers.it("returns the lowercase digest of an uppercase native value", function()
		local Crypto = load_crypto({}, DIGEST:upper())
		helpers.assert_eq(Crypto.sha256("x"), DIGEST)
	end)
end)





-- =========================================================================
-- =========================================================================
-- ======= 2/ network_info sha256_hex nil-safety (adapters-ui-sys-1) =======
-- =========================================================================
-- =========================================================================

helpers.describe("adapters.network_info — sha256_hex nil-safety", function()
local NI
	local function load_network_info(overrides)
		-- network_info captures Crypto at require time. Clear that dependency so
		-- every scenario uses its own hs.hash override instead of a prior test's.
		package.loaded["adapters.crypto"] = nil
		package.loaded["adapters.shell_runner"] = nil
		return helpers.load_with_stubs("adapters.network_info", overrides)
	end

	--- Returns an hs.hash double whose SHA-256 context reports `value`.
	--- @param value string Native digest value.
	--- @return table
	local function native_hash(value)
		return {
			new = function()
				local context = {}
				function context:append() return self end
				function context:finish() return self end
				function context:value() return value end
				return context
			end,
		}
	end

	helpers.it("returns '' when the native digest is empty (no nil-index crash)", function()
		NI = load_network_info({
			wifi = {
				currentNetwork = function() return "MySSID" end,
			},
			hash = native_hash(""),
		})
		local ok, result = pcall(function() return NI.getSsidHash() end)
		helpers.assert_true(ok, "getSsidHash() must not raise on an empty native digest")
		-- Result is nil (no SSID returned because sha256_hex returned "")
		-- The contract says nil when hash cannot be computed OR "" — both are acceptable
		helpers.assert_true(result == nil or result == "",
			"getSsidHash() must return nil or '' on an empty native digest, got: " .. tostring(result))
	end)

	helpers.it("returns '' when the native digest has no hex pattern", function()
		NI = load_network_info({
			wifi = { currentNetwork = function() return "TestNet" end },
			hash = native_hash("Error: digest unavailable ZZZ"),
		})
		local ok, result = pcall(function() return NI.getSsidHash() end)
		helpers.assert_true(ok, "getSsidHash() must not raise on a non-hex native digest")
		helpers.assert_true(result == nil or result == "",
			"getSsidHash() must return nil or '' when no hex digest found")
	end)

	helpers.it("returns the hash when the native digest succeeds", function()
		local hex = ("ab"):rep(32)  -- 64 hex chars
		NI = load_network_info({
			wifi = { currentNetwork = function() return "GoodNet" end },
			hash = native_hash(hex),
		})
		local result = NI.getSsidHash()
		helpers.assert_eq(result, hex, "getSsidHash() must return the hex digest")
	end)
end)
