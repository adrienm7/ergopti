--- tests/unit/meta/test_clipboard_adapter.lua
---
--- Integration tests for the clipboard adapter.
--- (xclip/xsel/wl-paste stubs). Tests the full API surface
--- (read/write/save/restore) without requiring a real clipboard backend.
---
--- Real clipboard access requires:
---   xclip or xsel (X11) or wl-paste/wl-copy (Wayland)

local helpers   = require("tests.helpers")
local clipboard = helpers.load_module("adapters.clipboard")

helpers.describe("clipboard adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports read", function()
      helpers.assert_true(type(clipboard.read) == "function", "read is a function")
    end)
    helpers.it("exports write", function()
      helpers.assert_true(type(clipboard.write) == "function", "write is a function")
    end)
    helpers.it("exports save", function()
      helpers.assert_true(type(clipboard.save) == "function", "save is a function")
    end)
    helpers.it("exports restore", function()
      helpers.assert_true(type(clipboard.restore) == "function", "restore is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. read() — clipboard read
  -- ==========================================================================

  helpers.describe("read()", function()
    helpers.it("read returns nil or string, never crashes", function()
      local ok, result = pcall(function() return clipboard.read() end)
      helpers.assert_true(ok, "read does not crash")
      helpers.assert_true(result == nil or type(result) == "string",
        "read returns nil or string")
    end)

    helpers.it("read twice does not crash", function()
      local ok = pcall(function()
        clipboard.read()
        clipboard.read()
      end)
      helpers.assert_true(ok, "double read does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. write() — clipboard write
  -- ==========================================================================

  helpers.describe("write()", function()
    helpers.it("write plain text returns boolean, never crashes", function()
      local ok, result = pcall(function() return clipboard.write("test") end)
      helpers.assert_true(ok, "write does not crash")
      helpers.assert_true(type(result) == "boolean", "write returns boolean")
    end)

    helpers.it("write empty string does not crash", function()
      local ok = pcall(function() clipboard.write("") end)
      helpers.assert_true(ok, "write('') does not crash")
    end)

    helpers.it("write nil returns false gracefully", function()
      local ok, result = pcall(function() return clipboard.write(nil) end)
      helpers.assert_true(ok, "write(nil) does not crash")
      helpers.assert_eq(result, false, "write(nil) returns false")
    end)

    helpers.it("write number returns false gracefully", function()
      local ok, result = pcall(function() return clipboard.write(42) end)
      helpers.assert_true(ok, "write(42) does not crash")
      helpers.assert_eq(result, false, "write(42) returns false")
    end)

    helpers.it("write Unicode does not crash", function()
      local ok = pcall(function() clipboard.write("café résumé") end)
      helpers.assert_true(ok, "write Unicode does not crash")
    end)

    helpers.it("write large string does not crash", function()
      local long = string.rep("clipboard test ", 200)
      local ok = pcall(function() clipboard.write(long) end)
      helpers.assert_true(ok, "write large string does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. save() / restore() — clipboard save/restore cycle
  -- ==========================================================================

  helpers.describe("save/restore cycle", function()
    helpers.it("save returns nil or string, never crashes", function()
      local ok, result = pcall(function() return clipboard.save() end)
      helpers.assert_true(ok, "save does not crash")
      helpers.assert_true(result == nil or type(result) == "string",
        "save returns nil or string")
    end)

    helpers.it("restore with nil (clear) does not crash", function()
      local ok, result = pcall(function() return clipboard.restore(nil) end)
      helpers.assert_true(ok, "restore(nil) does not crash")
      helpers.assert_true(type(result) == "boolean", "restore returns boolean")
    end)

    helpers.it("restore with empty string does not crash", function()
      local ok = pcall(function() clipboard.restore("") end)
      helpers.assert_true(ok, "restore('') does not crash")
    end)

    helpers.it("restore with text does not crash", function()
      local ok = pcall(function() clipboard.restore("restored text") end)
      helpers.assert_true(ok, "restore with text does not crash")
    end)

    helpers.it("restore with number does not crash", function()
      local ok = pcall(function() clipboard.restore(123) end)
      helpers.assert_true(ok, "restore(123) does not crash")
    end)

    helpers.it("save → restore cycle does not crash", function()
      local ok = pcall(function()
        local saved = clipboard.save()
        clipboard.restore(saved)
      end)
      helpers.assert_true(ok, "save-restore cycle does not crash")
    end)
  end)

  -- ==========================================================================
  -- 5. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("many save calls in a row does not crash", function()
      local ok = pcall(function()
        for _ = 1, 10 do clipboard.save() end
      end)
      helpers.assert_true(ok, "10x save does not crash")
    end)

    helpers.it("interleaved read/write does not crash", function()
      local ok = pcall(function()
        clipboard.write("a")
        clipboard.read()
        clipboard.write("b")
        clipboard.read()
      end)
      helpers.assert_true(ok, "interleaved read/write does not crash")
    end)
  end)

end)
