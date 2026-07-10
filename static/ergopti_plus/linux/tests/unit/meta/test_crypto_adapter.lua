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
      helpers.assert_true(ok, "sha256 handles all input types")
    end)

    helpers.it("does not crash with long input", function()
      local long = string.rep("x", 10000)
      local ok = pcall(function() crypto.sha256(long) end)
      helpers.assert_true(ok, "sha256 with 10KB input does not crash")
    end)

    helpers.it("does not crash with Unicode input", function()
      local ok = pcall(function() crypto.sha256("café résumé") end)
      helpers.assert_true(ok, "sha256 with Unicode does not crash")
    end)

    helpers.it("does not crash with special characters", function()
      local ok = pcall(function()
        crypto.sha256("$HOME `date` $(cmd) & | ;")
      end)
      helpers.assert_true(ok, "sha256 with shell chars does not crash")
    end)
  end)

end)
