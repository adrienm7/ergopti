--- tests/unit/modules/keylogger/core/test_keylogger.lua
---
--- Tier 1.4 — Integration tests for full keylogger module.
--- Tests: init, on_keydown, per-app tracking, password detection,
--- JSON export, file flush, session lifecycle, edge cases.

local helpers   = require("tests.helpers")
local it = require("tests.support.metrics_preferences_fixture").it
local Fakes     = helpers.load_module("tests.fakes")
local keylogger = helpers.load_module("modules.keylogger.keylogger")

-- The default path is the real user's metrics store, and every case in this
-- file used it. Once flushes started succeeding, rows written by one case were
-- read back by the next: a dashboard projection counted a keystroke that an
-- earlier case had typed. Each init now starts from an empty database.
local TEST_SQLITE_PATH = (os.getenv("TMPDIR") or "/tmp") .. "/ergopti_test_keylogger.sqlite"
local function fresh_db()
  os.remove(TEST_SQLITE_PATH)
  return TEST_SQLITE_PATH
end

helpers.describe("keylogger", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    it("exports init", function()
      helpers.assert_true(type(keylogger.init) == "function")
    end)
    it("exports on_keydown", function()
      helpers.assert_true(type(keylogger.on_keydown) == "function")
    end)
    it("exports get_wpm", function()
      helpers.assert_true(type(keylogger.get_wpm) == "function")
    end)
    it("exports export_session", function()
      helpers.assert_true(type(keylogger.export_session) == "function")
    end)
    it("exports export_json", function()
      helpers.assert_true(type(keylogger.export_json) == "function")
    end)
    it("exports flush", function()
      helpers.assert_true(type(keylogger.flush) == "function")
    end)
    it("exports suppress/unsuppress", function()
      helpers.assert_true(type(keylogger.suppress) == "function")
      helpers.assert_true(type(keylogger.unsuppress) == "function")
    end)
    it("exports is_password_app", function()
      helpers.assert_true(type(keylogger.is_password_app) == "function")
    end)
    it("exports reset_session + app metrics helpers", function()
      helpers.assert_true(type(keylogger.reset_session) == "function")
      helpers.assert_true(type(keylogger.get_app_stats) == "function")
      helpers.assert_true(type(keylogger.record_app_key) == "function")
	  helpers.assert_true(type(keylogger.record_hotstring) == "function")
      helpers.assert_true(type(keylogger.on_app_focus) == "function")
      helpers.assert_true(type(keylogger.get_dashboard_payload) == "function")
    end)
  end)

  -- ==========================================================================
  -- 2. init()
  -- ==========================================================================

  -- Each of these four called init() and then asserted assert_true(true) — "it
  -- did not crash". init()'s job is to leave the module USABLE, so that is what
  -- is asserted now: after any of the four argument shapes, the module must
  -- accept a keystroke and count it. An init that silently failed halfway and
  -- left the collector dead passed every one of them before.
  helpers.describe("init()", function()
    --- Feeds one keystroke and returns how many the module counted for that app.
    local function keystrokes_for(app)
      keylogger.on_keydown("a", 1000, app)
      local stats = keylogger.get_app_stats()[app]
      return stats and stats.keystrokes or 0
    end

    it("init with no opts leaves the collector usable", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      helpers.assert_true(keystrokes_for("probe-empty-opts") > 0,
        "after init({}) a keystroke must be counted — init leaving the collector dead is the failure this covers")
    end)
    it("init with nil leaves the collector usable", function()
      keylogger.init(nil)
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      helpers.assert_true(keystrokes_for("probe-nil-opts") > 0,
        "init(nil) must behave like init({}), not disable collection")
    end)
    it("init with a custom log_dir leaves the collector usable", function()
      keylogger.init({ sqlite_path = fresh_db(), log_dir = "/tmp/ergopti_test_logs" })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      helpers.assert_true(keystrokes_for("probe-log-dir") > 0,
        "a custom log_dir must not stop keystrokes being counted")
    end)
    it("init with custom password_apps applies them", function()
      keylogger.init({ sqlite_path = fresh_db(), password_apps = { "custom-vault" } })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      helpers.assert_true(keylogger.is_password_app("custom-vault"),
        "a password app passed to init must be recognised — accepting the option and dropping it is the failure this covers")
    end)
  end)

  -- ==========================================================================
  -- 3. on_keydown()
  -- ==========================================================================

  -- Same treatment: these three fed the collector and asserted nothing about
  -- what it recorded, so a no-op on_keydown passed all three.
  helpers.describe("on_keydown()", function()
    it("a keystroke is counted against its app", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      local before = (keylogger.get_app_stats()["kd-firefox"] or {}).keystrokes or 0
      keylogger.on_keydown("a", 1000, "kd-firefox")
      local after = (keylogger.get_app_stats()["kd-firefox"] or {}).keystrokes or 0
      helpers.assert_eq(after, before + 1, "on_keydown must increment the app's keystroke count by exactly one")
    end)

    it("a keystroke with no app_id is still counted somewhere", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      local function total()
        local n = 0
        for _, s in pairs(keylogger.get_app_stats()) do n = n + (s.keystrokes or 0) end
        return n
      end
      local before = total()
      keylogger.on_keydown("b", 2000)
      helpers.assert_eq(total(), before + 1,
        "a keystroke with no app id must be attributed to a fallback bucket, not dropped")
    end)

    it("500 keystrokes across five apps are all counted", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      local before = {}
      for i = 0, 4 do
        before["vol-app" .. i] = (keylogger.get_app_stats()["vol-app" .. i] or {}).keystrokes or 0
      end
      for i = 1, 500 do
        keylogger.on_keydown("x", i * 10, "vol-app" .. (i % 5))
      end
      local counted = 0
      for i = 0, 4 do
        local now = (keylogger.get_app_stats()["vol-app" .. i] or {}).keystrokes or 0
        counted = counted + (now - before["vol-app" .. i])
      end
      helpers.assert_eq(counted, 500,
        "every keystroke must reach its app's counter — a batch that silently drops some is the failure this covers")
    end)
  end)

  -- ==========================================================================
  -- 4. Password detection
  -- ==========================================================================

  helpers.describe("password detection", function()
    it("detects known password apps", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      helpers.assert_true(keylogger.is_password_app("1password"))
      helpers.assert_true(keylogger.is_password_app("Bitwarden"))
      helpers.assert_true(keylogger.is_password_app("org.keepass.KeePass"))
    end)
    it("covers every privacy-critical app via substring match (coverage must never narrow)", function()
      -- Privacy invariant: each of these MUST suppress keystroke logging. The
      -- match is a broad, case-insensitive substring so credential managers,
      -- their variants (keepass -> keepassxc/keepass2) and auth helpers all
      -- qualify. A future refactor that delegates to an exact-match
      -- secure_field_detector would silently stop matching these and leak
      -- keystrokes — this guard makes that regression a hard test failure.
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
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
    it("matches case-insensitively so casing cannot leak keystrokes", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      helpers.assert_true(keylogger.is_password_app("KEEPASSXC"), "upper-case must still match")
      helpers.assert_true(keylogger.is_password_app("KeePassXC"), "mixed-case must still match")
    end)
    it("returns false for normal apps", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      helpers.assert_eq(keylogger.is_password_app("firefox"), false)
      helpers.assert_eq(keylogger.is_password_app("code"), false)
      helpers.assert_eq(keylogger.is_password_app(""), false)
      helpers.assert_eq(keylogger.is_password_app(nil), false)
    end)
    it("suppress/unsuppress cycle works", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.suppress()
      helpers.assert_true(keylogger.is_suppressed())
      keylogger.unsuppress()
      helpers.assert_eq(keylogger.is_suppressed(), false)
    end)
    it("on_keydown is suppressed when password mode active", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
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
    it("export_session returns expected fields", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.on_keydown("t", 100, "test-app")
      local data = keylogger.export_session()
      helpers.assert_true(type(data) == "table")
      helpers.assert_true(type(data.keystrokes) == "number")
      helpers.assert_true(type(data.wpm) == "number")
      helpers.assert_true(type(data.apps) == "table")
      helpers.assert_true(data.session_started_ms ~= nil)
    end)
    it("export_json returns valid JSON string", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
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
    it("flush with configured log_dir does not crash", function()
      keylogger.init({ sqlite_path = fresh_db(), log_dir = os.getenv("TEMP") or "/tmp" })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.on_keydown("f", 1234, "flush-test")
      -- Called directly. flush answers what it wrote, and the caller advances on it.
      local flushed = keylogger.flush()
      helpers.assert_true(flushed == nil or type(flushed) == "boolean" or type(flushed) == "number",
        "flush must answer something the caller can act on")
    end)

    it("flushes one canonical raw batch and never replays it", function()
      local calls = { typing = {}, hotstrings = {}, switches = {}, app_days = {}, ngrams = {} }
      local fake_writer = {
        open_db = function() return true end,
        register_device = function() return true end,
        read_open_walk = function() return nil, true end,
        upsert_open_walk = function() return true end,
        is_available = function() return true end,
        bump_rev = function() return true end,
        insert_typing_events = function(_, events, derived)
          calls.typing[#calls.typing + 1] = events
          for _, group in ipairs(derived and derived.ngrams or {}) do
            calls.ngrams[#calls.ngrams + 1] = group.ngrams
          end
          return true
        end,
        insert_hotstring_events = function(_, events)
          calls.hotstrings[#calls.hotstrings + 1] = events
          return true
        end,
        insert_app_switch_events = function(_, events)
          calls.switches[#calls.switches + 1] = events
          return true
        end,
        upsert_app_day = function(_, _, _, fields)
          calls.app_days[#calls.app_days + 1] = fields
          return true
        end,
        upsert_ngrams = function(_, _, _, entries)
          calls.ngrams[#calls.ngrams + 1] = entries
          return true
        end,
		upsert_scancodes = function(_, _, _, entries)
		  calls.scancodes = calls.scancodes or {}
		  calls.scancodes[#calls.scancodes + 1] = entries
		  return true
		end,
      }
      -- Layered over the shared double rather than replacing it: the overrides
      -- above are what this test asserts on, and everything else the writer
      -- exports is inherited. Written out by hand, this table went stale the
      -- moment the writer grew a method, and the failure surfaced as a nil call
      -- inside the code under test.
      setmetatable(fake_writer, { __index = Fakes.sqlite_writer() })
      require("tests.support.sqlite_flush_fake").attach(fake_writer)
      local writer_name = "modules.keylogger.sqlite_writer"
      local logger_name = "modules.keylogger.keylogger"
      local previous_writer = package.loaded[writer_name]
      local previous_logger = package.loaded[logger_name]
      package.loaded[writer_name] = fake_writer
      package.loaded[logger_name] = nil
      local ok, err = pcall(function()
        local isolated = require(logger_name)
        isolated.init({ sqlite_path = "/tmp/ergopti_keylogger_mock.sqlite" })
        require("tests.support.metrics_consent_fixture").enable(isolated)
        isolated.reset_session()
        isolated.on_app_focus("org.mozilla.firefox", 1000)
		isolated.record_physical_key("org.mozilla.firefox", 30, 1100)
        isolated.on_keydown("a", 1100, "org.mozilla.firefox", 30)
        isolated.on_keydown("b", 1200, "org.mozilla.firefox")
		isolated.record_hotstring("org.mozilla.firefox", "btw", "by the way", 1300, "test", 3)
		isolated.record_synthetic_output("org.mozilla.firefox", "ok", "llm", 1350, 0, 2)
        isolated.on_app_focus("code", 2000)
        isolated.flush()

        helpers.assert_eq(#calls.typing, 1)
        helpers.assert_eq(calls.typing[1][1].app, "org.mozilla.firefox")
        helpers.assert_eq(calls.typing[1][1].text, "ab")
		helpers.assert_true(calls.typing[1][1].events_json:find('"sk":30', 1, true) ~= nil,
		  "portable manual events must retain the physical evdev scancode")
		helpers.assert_true(calls.typing[1][1].events_json:find('"s":0', 1, true) == nil,
		  "manual events must omit s:0 because Lua would treat numeric zero as synthetic")
		helpers.assert_true(calls.typing[1][1].events_json:find('"st":"hotstring"', 1, true) ~= nil,
		  "hotstring output must be persisted as tagged synthetic events")
		helpers.assert_true(calls.typing[1][1].events_json:find('"st":"llm"', 1, true) ~= nil,
		  "completed LLM output must use the same synthetic event format")
        helpers.assert_eq(#calls.hotstrings, 1)
        helpers.assert_eq(calls.hotstrings[1][1].net_saved_chars, 7)
        helpers.assert_eq(#calls.switches, 1)
        helpers.assert_eq(calls.switches[1][1].duration_ms, 1000)
        helpers.assert_true(#calls.app_days > 0)
        helpers.assert_true(#calls.ngrams > 0)
		helpers.assert_eq(calls.scancodes[1][30], 1,
		  "physical evdev counts must be persisted independently of logical output")

        isolated.flush()
        helpers.assert_eq(#calls.typing, 1, "a second flush must not replay raw typing")
        helpers.assert_eq(#calls.hotstrings, 1, "a second flush must not replay hotstrings")
        helpers.assert_eq(#calls.switches, 1, "a second flush must not replay switches")
      end)
      package.loaded[writer_name] = previous_writer
      package.loaded[logger_name] = previous_logger
      if not ok then error(err, 0) end
    end)
  end)

  -- ==========================================================================
  -- 7. Session lifecycle
  -- ==========================================================================

  helpers.describe("session lifecycle", function()
    it("reset_session clears data", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.on_keydown("r", 100, "test")
      keylogger.reset_session()
      helpers.assert_eq(keylogger.get_session_stats().keystrokes, 0)
    end)
    it("full lifecycle does not crash", function()
      keylogger.init({ sqlite_path = fresh_db(), log_dir = os.getenv("TEMP") or "/tmp" })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
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
    it("record_app_key accumulates per-app counts", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.record_app_key("firefox", "a", 100)
      keylogger.record_app_key("firefox", "b", 200)
      keylogger.record_app_key("vscode", "c", 300)
      local apps = keylogger.get_app_stats()
      helpers.assert_true(apps["firefox"] ~= nil)
      helpers.assert_true(apps["vscode"] ~= nil)
      helpers.assert_eq(apps["firefox"].keystrokes, 2)
      helpers.assert_eq(apps["vscode"].keystrokes, 1)
    end)
    it("get_app_stats returns table when empty", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.reset_session()
      helpers.assert_true(type(keylogger.get_app_stats()) == "table")
    end)

    it("credits a completed foreground interval without requiring a keystroke", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.reset_session()
      keylogger.on_app_focus("firefox", 1000)
      keylogger.on_app_focus("code", 5000)

      local apps = keylogger.get_app_stats()
      helpers.assert_eq(apps.firefox.focus_time_ms, 4000,
        "foreground time must be measured from focus transitions, not typing activity")
    end)

    it("projects per-app foreground and typing time in the shared dashboard contract", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.reset_session()
      keylogger.on_app_focus("firefox", 1000)
      keylogger.record_app_key("firefox", "a", 1100)
      keylogger.record_app_key("firefox", "b", 1300)
      keylogger.on_app_focus("code", 5000)

      local payload = keylogger.get_dashboard_payload()
      local day = payload.metrics_manifest[os.date("%Y-%m-%d")]
      helpers.assert_true(type(day) == "table", "payload must contain today")
      helpers.assert_eq(day.firefox.chars, 2)
      helpers.assert_eq(day.firefox.time, 200)
      helpers.assert_eq(day.firefox.app_time_ms, 4000)
      helpers.assert_true(type(payload.app_icons) == "table")
    end)

    it("records hotstring output and its physical trigger separately", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.reset_session()
      keylogger.record_hotstring("firefox", "btw", "by the way", 1000)

      local app = keylogger.get_app_stats().firefox
      helpers.assert_eq(app.hs_chars, 10)
      helpers.assert_eq(app.hs_input_chars, 3)
      helpers.assert_eq(app.hs_triggers, 1)
    end)

	it("projects physical scancodes and generated output into separate UI fields", function()
		keylogger.init({ sqlite_path = fresh_db() })
		require("tests.support.metrics_consent_fixture").enable(keylogger)
		keylogger.reset_session()
		keylogger.record_physical_key("firefox", 30, 1000)
		keylogger.on_keydown("a", 1000, "firefox", 30)
		keylogger.record_hotstring("firefox", "btw", "by", 1100, "test", 3)
		local range = keylogger.get_range_payload()
		local today = range.today.firefox
		helpers.assert_eq(today.sc_kb["30"].c, 1,
			"physical heatmap must count the actual evdev key exactly once")
		helpers.assert_eq(today.c.b.hs, 1,
			"logical hotstring output must retain its source for the output view")
		helpers.assert_eq(today.c.a.hs or 0, 0,
			"manual output must not be misclassified as synthetic")
	end)

    it("counts Unicode hotstrings by character rather than UTF-8 byte", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.reset_session()
      keylogger.record_hotstring("firefox", "é", "éclair", 1000)

      local app = keylogger.get_app_stats().firefox
      helpers.assert_eq(app.hs_chars, 6)
      helpers.assert_eq(app.hs_input_chars, 1)
      helpers.assert_eq(app.hs_triggers, 1)
    end)

    it("does not retain hotstring contents while password suppression is active", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.reset_session()
      keylogger.suppress()
      keylogger.record_hotstring("firefox", "secret", "sensitive replacement", 1000)
      keylogger.unsuppress()

      helpers.assert_eq(keylogger.get_app_stats().firefox, nil,
        "suppressed expansions must leave no per-app metric record")
    end)

    it("keeps raw hotstring and foreground transitions pending for canonical persistence", function()
      local previous_writer, previous_keylogger = package.loaded["modules.keylogger.sqlite_writer"], package.loaded["modules.keylogger.keylogger"]
      local writer = Fakes.sqlite_writer()
      package.loaded["modules.keylogger.sqlite_writer"], package.loaded["modules.keylogger.keylogger"] = writer, nil
      local ok, err = pcall(function()
        local collector = require("modules.keylogger.keylogger")
        collector.init({ sqlite_path = fresh_db() })
        require("tests.support.metrics_consent_fixture").enable(collector)
        collector.on_app_focus("before", 1000)
        collector.on_app_focus("after", 1100)
        collector.record_hotstring("after", "q", "replacement", 1200)
        helpers.assert_true(collector._pending_buffer_count_for_test() > 0)
        helpers.assert_true(collector.flush())
        helpers.assert_eq(writer.hotstrings[1].row.replacement, "replacement")
        helpers.assert_eq(writer.app_switches[1].row.prev_app, "before")
        helpers.assert_eq(writer.app_switches[1].row.next_app, "after")
        helpers.assert_eq(collector._pending_buffer_count_for_test(), 0)
      end)
      package.loaded["modules.keylogger.sqlite_writer"], package.loaded["modules.keylogger.keylogger"] = previous_writer, previous_keylogger
      if not ok then error(err, 0) end
    end)
  end)

  -- ==========================================================================
  -- 9. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    it("on_keydown with nil app_id still records the keystroke", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      local function total()
        local n = 0
        for _, s in pairs(keylogger.get_app_stats()) do n = n + (s.keystrokes or 0) end
        return n
      end
      local before = total()
      keylogger.on_keydown("x", 100, nil)
      helpers.assert_eq(total(), before + 1,
        "a nil app id must fall back to a bucket, not silently discard the keystroke")
    end)

    -- suppress()/unsuppress() are a COUNTER in every driver, not a boolean: a
    -- pair that leaves the module suppressed silently stops all collection,
    -- which is exactly what "does not crash" could never notice.
    it("balanced suppress/unsuppress leaves collection on", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      for _ = 1, 20 do keylogger.suppress(); keylogger.unsuppress() end
      helpers.assert_true(not keylogger.is_suppressed(),
        "20 balanced suppress/unsuppress pairs must leave the keylogger collecting")

      local before = (keylogger.get_app_stats()["suppress-probe"] or {}).keystrokes or 0
      keylogger.on_keydown("z", 4242, "suppress-probe")
      helpers.assert_eq((keylogger.get_app_stats()["suppress-probe"] or {}).keystrokes or 0, before + 1,
        "and a keystroke after them must still be counted")
    end)

    it("suppress actually stops collection until unsuppressed", function()
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.suppress()
      local before = (keylogger.get_app_stats()["suppressed-probe"] or {}).keystrokes or 0
      keylogger.on_keydown("z", 5252, "suppressed-probe")
      helpers.assert_eq((keylogger.get_app_stats()["suppressed-probe"] or {}).keystrokes or 0, before,
        "a suppressed keylogger must record nothing — without this the pair above passes on a suppress() that does nothing at all")
      keylogger.unsuppress()
    end)
  end)

end)

helpers.describe("keylogger events_json controls are escaped (json-controls)", function()
  it("json-controls: tab and CR travel escaped, never raw", function()
    -- Regression: the minimal encoder escaped only backslash, quote and
    -- newline, so a tab or carriage return typed or pasted into any app
    -- landed RAW inside the events_json string the flush persists — and a
    -- strict decoder on another driver rejects the row as not-JSON.
    local previous_writer = package.loaded["modules.keylogger.sqlite_writer"]
    local captured = {}
    package.loaded["modules.keylogger.sqlite_writer"] = setmetatable({
      insert_typing_events = function(_, events)
        captured[#captured + 1] = events
        return true
      end,
    }, { __index = function() return function() return true end end })
    require("tests.support.sqlite_flush_fake").attach(package.loaded["modules.keylogger.sqlite_writer"])
    local ok, err = pcall(function()
      package.loaded["adapters.storage"] = Fakes.storage()
      package.loaded["modules.keylogger.keylogger"] = nil
      local kl = require("modules.keylogger.keylogger")
      kl.init({})
      require("tests.support.metrics_consent_fixture").enable(kl)
      kl.on_keydown("\t", 1000, "code")
      kl.on_keydown("a\rb", 1100, "code")
      kl.flush()
      helpers.assert_true(#captured >= 1 and #(captured[1] or {}) >= 1,
        "the typed events must reach the writer")
      local payload = captured[1][1].events_json
      helpers.assert_true(type(payload) == "string" and #payload > 0,
        "each row must carry its encoded keystroke stream")
      helpers.assert_true(payload:find("\t", 1, true) == nil,
        "no raw tab may reach the persisted stream")
      helpers.assert_true(payload:find("\r", 1, true) == nil,
        "no raw carriage return may reach the persisted stream")
      helpers.assert_true(payload:find("\\t", 1, true) ~= nil,
        "a tab must travel as an escape")
      helpers.assert_true(payload:find("\\r", 1, true) ~= nil,
        "a carriage return must travel as an escape")
    end)
    package.loaded["modules.keylogger.sqlite_writer"] = previous_writer
    if not ok then error(err, 0) end
  end)
end)

helpers.describe("manual-marker-chars", function()
  it("manual-marker-chars: public corrections preserve literal typed-character counts", function()
    keylogger.init({ sqlite_path = fresh_db() })
    require("tests.support.metrics_consent_fixture").enable(keylogger)
    keylogger.on_keydown("a", 1000, "owned-manual")
    keylogger.on_keydown("[BS]", 1100, "owned-manual")
    keylogger.on_keydown("b", 1200, "owned-manual")
    helpers.assert_eq(keylogger.get_app_stats()["owned-manual"].keystrokes, 2)
    local today = os.date("%Y-%m-%d")
    local entry = keylogger.get_dashboard_payload({ include_prefetch = false }).metrics_manifest[today]["owned-manual"]
    helpers.assert_eq(entry.chars, 2)
    helpers.assert_eq(entry.time, 200, "correction timing remains part of the existing elapsed-time policy")
  end)
  it("manual-marker-chars: correction-only software input contributes zero characters", function()
    keylogger.init({ sqlite_path = fresh_db() })
    require("tests.support.metrics_consent_fixture").enable(keylogger)
    keylogger.on_keydown("[BS]", 1000, "owned-correction")
    keylogger.on_keydown("[BS]", 1100, "owned-correction")
    helpers.assert_eq(keylogger.get_app_stats()["owned-correction"].keystrokes, 0)
    local today = os.date("%Y-%m-%d")
    helpers.assert_eq(keylogger.get_dashboard_payload({ include_prefetch = false }).metrics_manifest[today]["owned-correction"].chars, 0)
  end)
  it("manual-marker-chars: healthy Unicode and whitespace characters remain admitted", function()
    keylogger.init({ sqlite_path = fresh_db() })
    require("tests.support.metrics_consent_fixture").enable(keylogger)
    keylogger.on_keydown("é", 1000, "owned-healthy")
    keylogger.on_keydown(" ", 1100, "owned-healthy")
    keylogger.on_keydown("\n", 1200, "owned-healthy")
    helpers.assert_eq(keylogger.get_app_stats()["owned-healthy"].keystrokes, 3)
    helpers.assert_eq(keylogger.get_app_stats()["owned-healthy"].typing_time_ms, 200)
  end)
  it("manual-marker-chars: direct app recording excludes only the exact correction marker", function()
    keylogger.init({ sqlite_path = fresh_db() })
    require("tests.support.metrics_consent_fixture").enable(keylogger)
    keylogger.record_app_key("owned-direct", "[BS]", 1000)
    keylogger.record_app_key("owned-direct", "[BS]x", 1100)
    keylogger.record_app_key("owned-direct", "x", 1200)
    helpers.assert_eq(keylogger.get_app_stats()["owned-direct"].keystrokes, 2)
    helpers.assert_eq(keylogger.get_app_stats()["owned-direct"].typing_time_ms, 200)
  end)
end)

-- The hook reports a physical Backspace through its control callback, never
-- as text, and the daemon fed the keylogger nothing for it: every error count,
-- hourly correction and backspace n-gram saw only a hotstring's own deletions.
helpers.describe("physical-backspace-corrections", function()
  it("physical-backspace-corrections: a press joins the stream as one manual correction", function()
    local previous_writer = package.loaded["modules.keylogger.sqlite_writer"]
    local captured = {}
    package.loaded["modules.keylogger.sqlite_writer"] = setmetatable({
      insert_typing_events = function(_, events)
        captured[#captured + 1] = events
        return true
      end,
    }, { __index = function() return function() return true end end })
    require("tests.support.sqlite_flush_fake").attach(package.loaded["modules.keylogger.sqlite_writer"])
    local ok, err = pcall(function()
      package.loaded["adapters.storage"] = Fakes.storage()
      package.loaded["modules.keylogger.keylogger"] = nil
      local kl = require("modules.keylogger.keylogger")
      kl.init({})
      require("tests.support.metrics_consent_fixture").enable(kl)
      helpers.assert_true(type(kl.record_correction) == "function",
        "the daemon's Backspace path needs an entry point into the keylogger")
      kl.on_keydown("a", 1000, "owned-physical", 30)
      kl.record_correction("owned-physical", 1100)
      kl.on_keydown("b", 1200, "owned-physical", 48)
      helpers.assert_eq(kl.get_app_stats()["owned-physical"].keystrokes, 2,
        "a correction types no character")
      local live = kl.get_range_payload().today["owned-physical"].c["[BS]"]
      helpers.assert_true(live ~= nil and live.c == 1, "the live projection counts the correction once")
      kl.flush()
      local row = captured[1] and captured[1][1]
      helpers.assert_true(row ~= nil, "the typed events must reach the writer")
      local events = require("json").decode(row.events_json)
      helpers.assert_eq(#events, 3)
      helpers.assert_eq(events[2][1], "[BS]")
      helpers.assert_eq(events[2][2], 100, "the correction keeps its own inter-key delay")
      helpers.assert_eq(events[2][3].sk, 14, "the physical source key is Backspace")
      helpers.assert_nil(events[2][3].s, "a physical correction is manual, never synthetic")
    end)
    package.loaded["modules.keylogger.sqlite_writer"] = previous_writer
    package.loaded["modules.keylogger.keylogger"] = nil
    keylogger = helpers.load_module("modules.keylogger.keylogger")
    if not ok then error(err, 0) end
  end)
  it("physical-backspace-corrections: corrections leave the live speed unchanged", function()
    local function live_wpm(stream)
      keylogger.init({ sqlite_path = fresh_db() })
      require("tests.support.metrics_consent_fixture").enable(keylogger)
      keylogger.reset_session()
      for _, key in ipairs(stream) do keylogger.on_keydown(key[1], key[2], "owned-speed") end
      return keylogger.get_live_stats(2000).wpm
    end
    local typed = { { "a", 1000 }, { "b", 1150 }, { "c", 1300 } }
    local corrected = { { "a", 1000 }, { "[BS]", 1050 }, { "[BS]", 1100 }, { "[BS]", 1120 },
      { "b", 1150 }, { "[BS]", 1200 }, { "c", 1300 } }
    local expected = live_wpm(typed)
    helpers.assert_true(expected > 0, "the healthy control produces a speed")
    helpers.assert_eq(live_wpm(corrected), expected,
      "a held Backspace must not read as a burst of fast typing")
  end)
  it("physical-backspace-corrections: corrections leave the session speed and n-grams unchanged", function()
    keylogger.init({ sqlite_path = fresh_db() })
    require("tests.support.metrics_consent_fixture").enable(keylogger)
    keylogger.reset_session()
    local before = keylogger.get_session_stats().keystrokes
    helpers.assert_true(type(before) == "number", "the session collector reports a keystroke count")
    keylogger.on_keydown("a", 1000, "owned-session")
    keylogger.on_keydown("[BS]", 1100, "owned-session")
    keylogger.on_keydown("[BS]", 1150, "owned-session")
    helpers.assert_eq(keylogger.get_session_stats().keystrokes - before, 1,
      "only the typed character is a session keystroke")
    for _, gram in ipairs(keylogger.get_ngrams(10) or {}) do
      local token = type(gram) == "table" and (gram.gram or gram[1]) or gram
      helpers.assert_true(type(token) ~= "string" or not token:find("[BS]", 1, true),
        "the session n-grams never contain the correction marker")
    end
  end)
end)

-- The flush walked each buffer on its own and credited everything still open
-- at its end: on the flush cadence every few seconds of typing was a session,
-- a word cut by a flush was two words, and the first key of a flush read as
-- typed zero milliseconds after the previous one.
helpers.describe("linux-cross-flush-walk", function()
  it("linux-cross-flush-walk: the flushes carry one session, one word and the pair across the cut", function()
    local Monotonic = require("infra.monotonic")
    local previous_writer = package.loaded["modules.keylogger.sqlite_writer"]
    local previous_now = Monotonic.now_ms
    local now = 10000
    local sessions, words, bigrams, typing = {}, {}, {}, {}
    local refuse_next = false
    local writer = setmetatable({
      insert_typing_events = function(_, events)
        for _, row in ipairs(events) do typing[#typing + 1] = row end
        return true
      end,
      upsert_session = function(_, row) sessions[#sessions + 1] = row; return true end,
      upsert_ngrams = function(_, _, _, ngrams, table_name)
        local target = (table_name == "ngram_words" and words) or (table_name == "ngram_bigrams" and bigrams) or nil
        if target then
          for token, value in pairs(ngrams) do target[token] = (target[token] or 0) + value.c end
        end
        return true
      end,
    }, { __index = function() return function() return true end end })
    require("tests.support.sqlite_flush_fake").attach(writer)
    local start_flush = writer.start_flush
    writer.start_flush = function(...)
      if refuse_next then refuse_next = false; return nil end
      return start_flush(...)
    end
    package.loaded["modules.keylogger.sqlite_writer"] = writer
    local ok, err = pcall(function()
      Monotonic.now_ms = function() return now end
      package.loaded["adapters.storage"] = Fakes.storage()
      package.loaded["modules.keylogger.keylogger"] = nil
      local kl = require("modules.keylogger.keylogger")
      kl.init({})
      require("tests.support.metrics_consent_fixture").enable(kl)
      local function type_text(text, at)
        for index = 1, #text do kl.on_keydown(text:sub(index, index), at + (index - 1) * 100, "owned-cross") end
        return at + (#text - 1) * 100
      end
      local last = type_text("hel", 10000)
      now = last + 50
      helpers.assert_true(kl.flush(), "the first flush commits")
      last = type_text("lo ", last + 100)
      now = last + 50
      refuse_next = true
      helpers.assert_eq(kl.flush(), false, "a refused flush restores its events")
      helpers.assert_true(kl.flush(), "the retry commits")
      helpers.assert_eq(#sessions, 0, "a session still open is credited when it ends, not at each flush")
      helpers.assert_eq(words.hello, 1, "the word cut by the flush is one word")
      helpers.assert_nil(words.hel)
      helpers.assert_nil(words.lo, "the refused snapshot's context was never adopted")
      helpers.assert_eq(bigrams.ll, 1, "the pair across the cut is counted once")
      helpers.assert_eq(require("json").decode(typing[2].events_json)[1][2], 100,
        "the first key of a flush keeps its delay after the previous flush's last key")
      now = last + 300001
      helpers.assert_true(kl.flush(), "the settled session commits")
      helpers.assert_eq(#sessions, 1)
      helpers.assert_eq(sessions[1].count_total, 1, "six keys across three flushes are one session")
      helpers.assert_eq(sessions[1].longest_chars, 6)
      helpers.assert_true(kl.flush())
      helpers.assert_eq(#sessions, 1, "a credited session is never credited again")
    end)
    Monotonic.now_ms = previous_now
    package.loaded["modules.keylogger.sqlite_writer"] = previous_writer
    package.loaded["modules.keylogger.keylogger"] = nil
    keylogger = helpers.load_module("modules.keylogger.keylogger")
    if not ok then error(err, 0) end
  end)
  it("linux-cross-flush-walk: shutdown credits the session still open", function()
    local previous_writer = package.loaded["modules.keylogger.sqlite_writer"]
    local sessions = {}
    local writer = setmetatable({
      upsert_session = function(_, row) sessions[#sessions + 1] = row; return true end,
    }, { __index = function() return function() return true end end })
    require("tests.support.sqlite_flush_fake").attach(writer)
    package.loaded["modules.keylogger.sqlite_writer"] = writer
    local ok, err = pcall(function()
      package.loaded["adapters.storage"] = Fakes.storage()
      package.loaded["modules.keylogger.keylogger"] = nil
      local kl = require("modules.keylogger.keylogger")
      kl.init({})
      require("tests.support.metrics_consent_fixture").enable(kl)
      local Monotonic = require("infra.monotonic")
      local at = math.floor(Monotonic.now_ms())
      kl.on_keydown("a", at, "owned-stop")
      kl.on_keydown("b", at + 100, "owned-stop")
      helpers.assert_true(kl.flush())
      helpers.assert_eq(#sessions, 0, "the session is still open")
      helpers.assert_true(kl.stop(), "shutdown settles")
      helpers.assert_eq(#sessions, 1, "the open session is credited at shutdown")
      helpers.assert_eq(sessions[1].longest_chars, 2)
    end)
    package.loaded["modules.keylogger.sqlite_writer"] = previous_writer
    package.loaded["modules.keylogger.keylogger"] = nil
    keylogger = helpers.load_module("modules.keylogger.keylogger")
    if not ok then error(err, 0) end
  end)
end)

helpers.describe("live-source-projection", function()
	local function fresh_live()
		keylogger.init({ sqlite_path = fresh_db() })
		require("tests.support.metrics_consent_fixture").enable(keylogger)
		keylogger.reset_session()
	end
	local function assert_tuple(payload, app, count, hs, llm, other)
		local item = payload.today[app].c.a
		helpers.assert_eq(item.c, count, "literal logical character count")
		helpers.assert_eq(item.hs, hs, "dedicated hotstring source count")
		helpers.assert_eq(item.llm, llm, "dedicated LLM source count")
		helpers.assert_eq(item.o, other, "additional synthetic source count")
	end
	local vectors = {
		{ name = "clipboard", label = "clipboard", hs = 0, llm = 0, other = 2 },
		{ name = "action", label = "action", hs = 0, llm = 0, other = 2 },
		{ name = "empty string", label = "", hs = 0, llm = 0, other = 2 },
		{ name = "case-sensitive label", label = "None", hs = 0, llm = 0, other = 2 },
		{ name = "hotstring", label = "hotstring", hs = 2, llm = 0, other = 0 },
		{ name = "llm", label = "llm", hs = 0, llm = 2, other = 0 },
		{ name = "other", label = "other", hs = 0, llm = 0, other = 2 },
		{ name = "manual marker", label = "none", hs = 0, llm = 0, other = 0 },
	}
	for _, vector in ipairs(vectors) do
		it("live-source-projection: public pending " .. vector.name, function()
			fresh_live()
			keylogger.record_synthetic_output("owned-live", "aa", vector.label, 1000)
			assert_tuple(keylogger.get_range_payload(), "owned-live", 2, vector.hs, vector.llm, vector.other)
		end)
	end
	it("live-source-projection: software manual input keeps all generated buckets zero", function()
		fresh_live()
		keylogger.on_keydown("a", 1000, "owned-live")
		keylogger.on_keydown("a", 1100, "owned-live")
		assert_tuple(keylogger.get_range_payload(), "owned-live", 2, 0, 0, 0)
	end)
	it("live-source-projection: repeated projections do not consume or duplicate pending labels", function()
		fresh_live()
		keylogger.record_synthetic_output("owned-live", "aa", "clipboard", 1000)
		keylogger.record_synthetic_output("owned-live", "aaa", "action", 1100)
		keylogger.record_synthetic_output("owned-live", "a", "hotstring", 1200)
		keylogger.record_synthetic_output("owned-live", "a", "llm", 1300)
		for _ = 1, 3 do assert_tuple(keylogger.get_range_payload(), "owned-live", 7, 1, 1, 5) end
	end)
	it("live-source-projection: dashboard prefetch uses the same additional label policy", function()
		fresh_live()
		keylogger.record_synthetic_output("owned-live", "aa", "clipboard", 1000)
		local dashboard = keylogger.get_dashboard_payload()
		helpers.assert_eq(dashboard.driver_meta.os, "linux")
		assert_tuple(dashboard._prefetch_data, "owned-live", 2, 0, 0, 2)
	end)
	it("live-source-projection: flushed other snapshot is not included in the pending source delta", function()
		fresh_live()
		keylogger.record_synthetic_output("owned-live", "aa", "other", 1000)
		keylogger.flush()
		assert_tuple(keylogger.get_range_payload(), "owned-live", 2, 0, 0, 2)
		keylogger.record_synthetic_output("owned-live", "aa", "other", 1100)
		keylogger.record_synthetic_output("owned-live", "aaa", "action", 1200)
		for _ = 1, 3 do assert_tuple(keylogger.get_range_payload(), "owned-live", 7, 0, 0, 7) end
	end)
end)
