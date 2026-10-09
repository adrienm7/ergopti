--- tests/unit/meta/test_helper_assertions.lua
---
--- Smoke-tests the new assertion helpers (assert_contains, assert_throws,
--- assert_type, assert_not_nil, inspect) added in the test-suite refactor.
--- Each test validates both the passing path AND that the failure message
--- is readable (file:line prefix, pretty-printed values).

local helpers = require("tests.helpers")

helpers.describe("helper assertions (smoke)", function()

  -- ==========================================================================
  -- 1. assert_contains
  -- ==========================================================================

  helpers.describe("assert_contains", function()
    helpers.it("passes when needle found", function()
      helpers.assert_contains("hello world", "world")
    end)

    helpers.it("fails with readable message when needle absent", function()
      local ok, err = pcall(function()
        helpers.assert_contains("hello world", "xyz", "my check")
      end)
      helpers.assert_true(not ok, "assert_contains should fail for missing needle")
      helpers.assert_contains(err, "my check")
      helpers.assert_contains(err, "xyz")
    end)
  end)

  -- ==========================================================================
  -- 2. assert_throws
  -- ==========================================================================

  helpers.describe("assert_throws", function()
    helpers.it("passes when fn throws", function()
      local caught = helpers.assert_throws(function()
        error("EXPECTED BANG")
      end)
      helpers.assert_contains(caught, "EXPECTED BANG")
    end)

    helpers.it("fails when fn does not throw", function()
      local ok, err = pcall(function()
        helpers.assert_throws(function() return 42 end, "should throw")
      end)
      helpers.assert_true(not ok, "assert_throws should fail for non-throwing fn")
      helpers.assert_contains(err, "should throw")
    end)

    helpers.it("returns the thrown error for further inspection", function()
      local err_msg = helpers.assert_throws(function()
        error("code 500: server down")
      end)
      helpers.assert_contains(err_msg, "500")
    end)
  end)

  -- ==========================================================================
  -- 3. assert_type
  -- ==========================================================================

  helpers.describe("assert_type", function()
    helpers.it("passes when type matches", function()
      helpers.assert_type("hello", "string")
      helpers.assert_type(42, "number")
      helpers.assert_type({}, "table")
      helpers.assert_type(true, "boolean")
      helpers.assert_type(nil, "nil")
    end)

    helpers.it("fails with readable message on type mismatch", function()
      local ok, err = pcall(function()
        helpers.assert_type("hello", "number", "my type check")
      end)
      helpers.assert_true(not ok, "assert_type should fail for wrong type")
      helpers.assert_contains(err, "my type check")
      helpers.assert_contains(err, "expected number")
      helpers.assert_contains(err, "got string")
    end)
  end)

  -- ==========================================================================
  -- 4. assert_not_nil
  -- ==========================================================================

  helpers.describe("assert_not_nil", function()
    helpers.it("passes for non-nil values", function()
      helpers.assert_not_nil(0)
      helpers.assert_not_nil("")
      helpers.assert_not_nil(false)
      helpers.assert_not_nil({})
    end)

    helpers.it("fails for nil", function()
      local ok, err = pcall(function()
        helpers.assert_not_nil(nil, "value required")
      end)
      helpers.assert_true(not ok, "assert_not_nil should fail for nil")
      helpers.assert_contains(err, "value required")
    end)
  end)

  -- ==========================================================================
  -- 5. inspect — pretty-printing
  -- ==========================================================================

  helpers.describe("inspect", function()
    helpers.it("pretty-prints a table with named keys", function()
      local s = helpers.inspect({ name = "test", count = 5 })
      helpers.assert_contains(s, "name=")
      helpers.assert_contains(s, '"test"')
      helpers.assert_contains(s, "count=5")
    end)

    helpers.it("pretty-prints nested tables (depth-limited)", function()
      local s = helpers.inspect({ a = { b = { c = { d = 1 } } } })
      helpers.assert_contains(s, "a=")
      helpers.assert_contains(s, "{…}")
    end)

    helpers.it("detects cycles", function()
      local t = { name = "loop" }
      t.self = t
      local s = helpers.inspect(t)
      helpers.assert_contains(s, "[cyclic]")
    end)

    helpers.it("truncates long strings", function()
      local long = string.rep("x", 200)
      local s = helpers.inspect(long)
      helpers.assert_true(#s < 200, "long string should be truncated")
      helpers.assert_contains(s, "...")
    end)

    helpers.it("handles nil, boolean, function", function()
      helpers.assert_eq(helpers.inspect(nil), "nil")
      helpers.assert_eq(helpers.inspect(true), "true")
      helpers.assert_eq(helpers.inspect(false), "false")
      helpers.assert_contains(helpers.inspect(function() end), "<function>")
    end)
  end)

end)
