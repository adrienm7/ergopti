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

helpers.describe("crypto adapter", function()

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
