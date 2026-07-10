--- tests/unit/meta/test_keylogger.lua
---
--- Tier 1.4 — Integration tests for full keylogger module.
--- Tests: init, on_keydown, per-app tracking, password detection,
--- JSON export, file flush, session lifecycle, edge cases.

local helpers   = require("tests.helpers")
local keylogger = helpers.load_module("modules.keylogger.keylogger")

helpers.describe("keylogger", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports init", function()
      helpers.assert_true(type(keylogger.init) == "function")
    end)
    helpers.it("exports on_keydown", function()
      helpers.assert_true(type(keylogger.on_keydown) == "function")
    end)
    helpers.it("exports get_wpm", function()
      helpers.assert_true(type(keylogger.get_wpm) == "function")
    end)
    helpers.it("exports export_session", function()
      helpers.assert_true(type(keylogger.export_session) == "function")
    end)
    helpers.it("exports export_json", function()
      helpers.assert_true(type(keylogger.export_json) == "function")
    end)
    helpers.it("exports flush", function()
      helpers.assert_true(type(keylogger.flush) == "function")
    end)
    helpers.it("exports suppress/unsuppress", function()
      helpers.assert_true(type(keylogger.suppress) == "function")
      helpers.assert_true(type(keylogger.unsuppress) == "function")
    end)
    helpers.it("exports is_password_app", function()
      helpers.assert_true(type(keylogger.is_password_app) == "function")
    end)
    helpers.it("exports reset_session + get_app_stats + record_app_key", function()
      helpers.assert_true(type(keylogger.reset_session) == "function")
      helpers.assert_true(type(keylogger.get_app_stats) == "function")
      helpers.assert_true(type(keylogger.record_app_key) == "function")
    end)
  end)

  -- ==========================================================================
  -- 2. init()
  -- ==========================================================================

  helpers.describe("init()", function()
    helpers.it("init with no opts does not crash", function()
      keylogger.init({})
      helpers.assert_true(true)
    end)
    helpers.it("init with nil does not crash", function()
      keylogger.init(nil)
      helpers.assert_true(true)
    end)
    helpers.it("init with custom log_dir does not crash", function()
      keylogger.init({ log_dir = "/tmp/ergopti_test_logs" })
      helpers.assert_true(true)
    end)
    helpers.it("init with custom password_apps does not crash", function()
      keylogger.init({ password_apps = { "custom-vault" } })
      helpers.assert_true(true)
    end)
  end)

  -- ==========================================================================
  -- 3. on_keydown()
  -- ==========================================================================

  helpers.describe("on_keydown()", function()
    helpers.it("valid input does not crash", function()
      keylogger.init({})
      keylogger.on_keydown("a", 1000, "firefox")
      helpers.assert_true(true)
    end)
    helpers.it("without app_id does not crash", function()
      keylogger.init({})
      keylogger.on_keydown("b", 2000)
      helpers.assert_true(true)
    end)
    helpers.it("many keystrokes do not crash", function()
      keylogger.init({})
      for i = 1, 500 do
        keylogger.on_keydown("x", i * 10, "app" .. (i % 5))
      end
      helpers.assert_true(true)
    end)
  end)

  -- ==========================================================================
  -- 4. Password detection
  -- ==========================================================================

  helpers.describe("password detection", function()
    helpers.it("detects known password apps", function()
      keylogger.init({})
      helpers.assert_true(keylogger.is_password_app("1password"))
      helpers.assert_true(keylogger.is_password_app("Bitwarden"))
      helpers.assert_true(keylogger.is_password_app("org.keepass.KeePass"))
    end)
    helpers.it("covers every privacy-critical app via substring match (coverage must never narrow)", function()
      -- Privacy invariant: each of these MUST suppress keystroke logging. The
      -- match is a broad, case-insensitive substring so credential managers,
      -- their variants (keepass -> keepassxc/keepass2) and auth helpers all
      -- qualify. A future refactor that delegates to an exact-match
      -- secure_field_detector would silently stop matching these and leak
      -- keystrokes — this guard makes that regression a hard test failure.
      keylogger.init({})
      local must_match = {
        "1password", "1Password.exe", "bitwarden", "Bitwarden",
        "keepass", "keepassxc", "keepass2", "org.keepassxc.KeePassXC",
        "lastpass", "gpg", "gpg-agent", "ssh-agent", "polkit",
        "polkit-gnome-authentication-agent-1", "sudo",
      }
      for _, app in ipairs(must_match) do
        helpers.assert_true(keylogger.is_password_app(app),
          "keystroke logging MUST be suppressed for the secure app: " .. app)
      end
    end)
    helpers.it("matches case-insensitively so casing cannot leak keystrokes", function()
      keylogger.init({})
      helpers.assert_true(keylogger.is_password_app("KEEPASSXC"), "upper-case must still match")
      helpers.assert_true(keylogger.is_password_app("KeePassXC"), "mixed-case must still match")
    end)
    helpers.it("returns false for normal apps", function()
      keylogger.init({})
      helpers.assert_eq(keylogger.is_password_app("firefox"), false)
      helpers.assert_eq(keylogger.is_password_app("code"), false)
      helpers.assert_eq(keylogger.is_password_app(""), false)
      helpers.assert_eq(keylogger.is_password_app(nil), false)
    end)
    helpers.it("suppress/unsuppress cycle works", function()
      keylogger.init({})
      keylogger.suppress()
      helpers.assert_true(keylogger.is_suppressed())
      keylogger.unsuppress()
      helpers.assert_eq(keylogger.is_suppressed(), false)
    end)
    helpers.it("on_keydown is suppressed when password mode active", function()
      keylogger.init({})
      keylogger.on_keydown("x", 5000, "firefox")
      local before = keylogger.get_session_stats().keystrokes
      keylogger.suppress()
      keylogger.on_keydown("y", 6000, "1password")
      local after = keylogger.get_session_stats().keystrokes
      helpers.assert_eq(after, before, "keystroke count unchanged when suppressed")
      keylogger.unsuppress()
    end)
  end)

  -- ==========================================================================
  -- 5. JSON export
  -- ==========================================================================

  helpers.describe("export", function()
    helpers.it("export_session returns expected fields", function()
      keylogger.init({})
      keylogger.on_keydown("t", 100, "test-app")
      local data = keylogger.export_session()
      helpers.assert_true(type(data) == "table")
      helpers.assert_true(type(data.keystrokes) == "number")
      helpers.assert_true(type(data.wpm) == "number")
      helpers.assert_true(type(data.apps) == "table")
      helpers.assert_true(data.session_started_ms ~= nil)
    end)
    helpers.it("export_json returns valid JSON string", function()
      keylogger.init({})
      local json = keylogger.export_json()
      helpers.assert_true(type(json) == "string")
      helpers.assert_true(#json > 10)
      helpers.assert_true(json:sub(1, 1) == "{")
    end)
  end)

  -- ==========================================================================
  -- 6. File flush
  -- ==========================================================================

  helpers.describe("flush()", function()
    helpers.it("flush with configured log_dir does not crash", function()
      keylogger.init({ log_dir = os.getenv("TEMP") or "/tmp" })
      keylogger.on_keydown("f", 1234, "flush-test")
      local ok = pcall(function() keylogger.flush() end)
      helpers.assert_true(ok)
    end)
  end)

  -- ==========================================================================
  -- 7. Session lifecycle
  -- ==========================================================================

  helpers.describe("session lifecycle", function()
    helpers.it("reset_session clears data", function()
      keylogger.init({})
      keylogger.on_keydown("r", 100, "test")
      keylogger.reset_session()
      helpers.assert_eq(keylogger.get_session_stats().keystrokes, 0)
    end)
    helpers.it("full lifecycle does not crash", function()
      keylogger.init({ log_dir = os.getenv("TEMP") or "/tmp" })
      keylogger.on_keydown("a", 100, "app1")
      keylogger.on_keydown("b", 200, "app2")
      keylogger.suppress()
      keylogger.on_keydown("s", 300, "1password")
      keylogger.unsuppress()
      local json = keylogger.export_json()
      keylogger.flush()
      keylogger.reset_session()
      helpers.assert_true(type(json) == "string")
    end)
  end)

  -- ==========================================================================
  -- 8. Per-app tracking
  -- ==========================================================================

  helpers.describe("per-app tracking", function()
    helpers.it("record_app_key accumulates per-app counts", function()
      keylogger.init({})
      keylogger.record_app_key("firefox", "a", 100)
      keylogger.record_app_key("firefox", "b", 200)
      keylogger.record_app_key("vscode", "c", 300)
      local apps = keylogger.get_app_stats()
      helpers.assert_true(apps["firefox"] ~= nil)
      helpers.assert_true(apps["vscode"] ~= nil)
      helpers.assert_eq(apps["firefox"].keystrokes, 2)
      helpers.assert_eq(apps["vscode"].keystrokes, 1)
    end)
    helpers.it("get_app_stats returns table when empty", function()
      keylogger.init({})
      helpers.assert_true(type(keylogger.get_app_stats()) == "table")
    end)
  end)

  -- ==========================================================================
  -- 9. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("on_keydown with nil app_id does not crash", function()
      keylogger.init({})
      keylogger.on_keydown("x", 100, nil)
      helpers.assert_true(true)
    end)
    helpers.it("rapid suppress/unsuppress does not crash", function()
      keylogger.init({})
      for _ = 1, 20 do keylogger.suppress(); keylogger.unsuppress() end
      helpers.assert_true(true)
    end)
  end)

end)
