--- tests/unit/meta/test_crypto_adapter.lua
---
--- Integration tests for the crypto adapter.
--- (openssl sha256 stub). Tests the sha256 contract without requiring
--- openssl on the test machine.
---
--- Real SHA-256 hashing requires:
---   openssl (available on all Linux distros)

local helpers = require("tests.helpers")
local crypto  = helpers.load_module("adapters.crypto")

--- Loads one adapter against the native digest provider's actual interface.
local function fresh_crypto(provider)
	local previous_provider = package.loaded["infra.openssl_digest"]
	local previous_crypto = package.loaded["adapters.crypto"]
	package.loaded["infra.openssl_digest"] = provider
	package.loaded["adapters.crypto"] = nil
	local subject = require("adapters.crypto")
	package.loaded["infra.openssl_digest"] = previous_provider
	package.loaded["adapters.crypto"] = previous_crypto
	return subject
end

helpers.describe("crypto adapter", function()
	for _, data in ipairs({ "abc", "a\0b" }) do
		local kind = data:find("\0", 1, true) and "binary" or "text"
		for _, status in ipairs({ 1, 7, 23, 143, 137, false }) do
			helpers.it("linux-crypto-cli-exit-receipts: rejects useful " .. kind .. " digest after status " .. tostring(status), function()
				local subject = fresh_crypto({ available = false })
				local shell = require("adapters.shell_runner")
				shell._set_runner(function(command)
					if command:find("command -v", 1, true) then return true end
					return helpers.openssl_stdout_receipt(command, "SHA2-256(stdin)= " .. string.rep("a", 64) .. "\n", status)
				end)
				local ok, result = pcall(subject.sha256, data)
				shell._reset_runner()
				helpers.assert_true(ok)
				helpers.assert_eq(result, "", "failed or missing native receipt must never admit useful digest output")
			end)
		end
		helpers.it("linux-crypto-cli-exit-receipts: supervises " .. kind .. " input without quoting its payload twice", function()
			local subject = fresh_crypto({ available = false })
			local native = require("infra.openssl_command")
			local previous, transport = native.exec, nil
			native.exec = function(command, input, options)
				transport = { command = command, input = input, options = options }
				return "SHA2-256(stdin)= " .. string.rep("a", 64) .. "\n"
			end
			local shell = require("adapters.shell_runner")
			shell._set_runner(function() return "SHA2-256(stdin)= " .. string.rep("a", 64) .. "\n" end)
			local ok, result = pcall(subject.sha256, data)
			native.exec = previous
			shell._reset_runner()
			helpers.assert_true(ok)
			helpers.assert_eq(result, string.rep("a", 64))
			helpers.assert_not_nil(transport, "the CLI must execute through the checked native command owner")
			if kind == "binary" then
				helpers.assert_eq(require("compat.base64").decode(transport.input), data)
				helpers.assert_true(transport.options and transport.options.pipefail == true)
			else
				helpers.assert_contains(transport.command, shell.quote(data), "retain the existing inert POSIX input word")
				helpers.assert_nil(transport.input)
				helpers.assert_true(transport.options and transport.options.pipefail == true,
					"the printf producer and its digest consumer require one supervised receipt")
			end
		end)
	end
	for _, row in ipairs(require("tests.support.crypto_vectors")) do
		helpers.it("linux-crypto-byte-receipts: frames " .. row.id .. " without argv NUL", function()
			local subject = fresh_crypto({ available = false,
				sha256 = function() return nil, "native primitive unavailable" end })
			local Shell = require("adapters.shell_runner")
			local command, calls = nil, 0
			local probes = 0
			Shell._set_runner(function(value)
				if value:find("command -v", 1, true) then probes = probes + 1; return true end
				command, calls = value, calls + 1
				return helpers.openssl_stdout_receipt(value, "SHA2-256(stdin)= " .. row.sha256 .. "\n")
			end)
			local ok, digest = pcall(subject.sha256, row.input)
			Shell._reset_runner()
			helpers.assert_true(ok)
			helpers.assert_eq(digest, row.sha256)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(probes, 1, "every CLI fallback pipeline requires the installed supervisor probe")
			helpers.assert_true(type(command) == "string" and not command:find("\0", 1, true),
				"a command passed to exec cannot carry an embedded NUL")
		end)
	end
	for _, row in ipairs(require("tests.support.crypto_vectors")) do
		helpers.it("linux-crypto-native-receipts: delegates exact bytes for " .. row.id, function()
			local native_calls, shell_calls, received = 0, 0, nil
			local subject = fresh_crypto({ available = true, sha256 = function(data)
				native_calls, received = native_calls + 1, data
				return row.sha256, nil
			end })
			local Shell = require("adapters.shell_runner")
			Shell._set_runner(function() shell_calls = shell_calls + 1; error("native hashing must not shell out") end)
			local ok, result = pcall(subject.sha256, row.input)
			Shell._reset_runner()
			helpers.assert_true(ok)
			helpers.assert_eq(result, row.sha256)
			helpers.assert_eq(native_calls, 1)
			helpers.assert_eq(received, row.input, "native provider must receive all original bytes")
			helpers.assert_eq(shell_calls, 0)
		end)
	end
	helpers.it("linux-crypto-native-receipts: preserves native refusal without a CLI retry", function()
		local native_calls, shell_calls = 0, 0
		local subject = fresh_crypto({ available = true, sha256 = function()
			native_calls = native_calls + 1
			return nil, "native primitive refused"
		end })
		local Shell = require("adapters.shell_runner")
		Shell._set_runner(function() shell_calls = shell_calls + 1; return "" end)
		local ok, result = pcall(subject.sha256, "abc")
		Shell._reset_runner()
		helpers.assert_true(ok)
		helpers.assert_eq(result, "")
		helpers.assert_eq(native_calls, 1)
		helpers.assert_eq(shell_calls, 0, "a refused primitive cannot silently switch implementation")
	end)

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports sha256", function()
      helpers.assert_true(type(crypto.sha256) == "function", "sha256 is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. sha256() — contract compliance
  -- ==========================================================================

  helpers.describe("sha256()", function()
    helpers.it("returns a string, never nil", function()
      local digest = crypto.sha256("hello")
      helpers.assert_true(type(digest) == "string", "sha256 returns a string")
    end)

    helpers.it("returns empty string on failure (no openssl)", function()
      -- On Windows/macOS without openssl, should return ""
      -- If openssl IS available, will return 64-char hex string
      local digest = crypto.sha256("test")
      helpers.assert_true(digest == "" or #digest == 64,
        "returns '' or 64-char hex (got " .. #digest .. " chars)")
    end)

    helpers.it("returns empty string for nil input", function()
      local digest = crypto.sha256(nil)
      helpers.assert_eq(digest, "", "nil input returns ''")
    end)

    helpers.it("returns empty string for non-string input", function()
      local digest = crypto.sha256(42)
      helpers.assert_eq(digest, "", "number input returns ''")
    end)

    helpers.it("returns correct SHA-256 for empty string", function()
      local digest = crypto.sha256("")
      -- The SHA-256 of the empty string is a well-known constant.
      -- With openssl available (CI), returns the correct hash.
      -- Without openssl, returns "" (safe fallback).
      helpers.assert_true(digest == "" or digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "empty string returns '' or correct hash (got " .. tostring(digest) .. ")")
    end)

    helpers.it("does not crash on any input", function()
      local ok = pcall(function()
        crypto.sha256(nil)
        crypto.sha256("")
        crypto.sha256("hello")
        crypto.sha256(123)
        crypto.sha256({})
      end)
      -- The pcall stays: taking a table is genuinely about not raising. What it was
      -- missing is that a string input still produces a digest, so the same call
      -- path is not quietly returning "" for everything.
      helpers.assert_true(ok, "sha256 handles all input types")
      -- Digest LENGTH cannot be asserted here: this suite runs on hosts with no
      -- sha256sum, where the adapter legitimately answers "". What holds either way
      -- is that the answer is a string and is stable for the same input.
      helpers.assert_eq(type(crypto.sha256("hello")), "string",
        "sha256 must answer a string, never nil — the caller concatenates it")
      helpers.assert_eq(crypto.sha256("hello"), crypto.sha256("hello"),
        "and the same input must give the same answer")
    end)

    helpers.it("does not crash with long input", function()
      local long = string.rep("x", 10000)
      -- 10 KB is past any argv limit a shell-based digest would hit, and a silent
      -- truncation returns a digest of the WRONG data — which "did not crash"
      -- cannot see. Only asserted when a digest is produced at all: on a host with
      -- no sha256sum the adapter answers "" for everything, and comparing two
      -- empty strings would be the vacuous pass this file is being cured of.
      local d1 = crypto.sha256(long)
      helpers.assert_eq(type(d1), "string", "a 10 KB input must still answer a string")
      if d1 ~= "" then
        helpers.assert_eq(#d1, 64, "a produced digest is 64 chars however long the input")
        helpers.assert_true(d1 ~= crypto.sha256(long .. "x"),
          "and one more byte must change it — equal digests mean the input was truncated")
      end
    end)

    helpers.it("does not crash with Unicode input", function()
      local d = crypto.sha256("café résumé")
      helpers.assert_eq(type(d), "string", "multi-byte input must answer a string")
      if d ~= "" then
        helpers.assert_eq(#d, 64, "and hash as bytes, not be mangled into a short answer")
      end
    end)

    helpers.it("does not crash with special characters", function()
      -- Shell metacharacters are the injection surface of a shell-based digest.
      -- Two different command strings must hash differently: equal digests would
      -- mean the shell ate them both the same way.
      local a = crypto.sha256("$HOME `date` $(cmd) & | ;")
      local b = crypto.sha256("$HOME `date` $(cmd) & | ; x")
      helpers.assert_eq(type(a), "string", "shell metacharacters must answer a string")
      if a ~= "" then
        helpers.assert_eq(#a, 64, "and hash to 64 chars")
        helpers.assert_true(a ~= b, "and be hashed, not executed or dropped")
      end
    end)
  end)

end)
