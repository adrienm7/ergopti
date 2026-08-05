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
    helpers.it("exports reset_session + app metrics helpers", function()
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

    helpers.it("init with no opts leaves the collector usable", function()
      keylogger.init({})
      helpers.assert_true(keystrokes_for("probe-empty-opts") > 0,
        "after init({}) a keystroke must be counted — init leaving the collector dead is the failure this covers")
    end)
    helpers.it("init with nil leaves the collector usable", function()
      keylogger.init(nil)
      helpers.assert_true(keystrokes_for("probe-nil-opts") > 0,
        "init(nil) must behave like init({}), not disable collection")
    end)
    helpers.it("init with a custom log_dir leaves the collector usable", function()
      keylogger.init({ log_dir = "/tmp/ergopti_test_logs" })
      helpers.assert_true(keystrokes_for("probe-log-dir") > 0,
        "a custom log_dir must not stop keystrokes being counted")
    end)
    helpers.it("init with custom password_apps applies them", function()
      keylogger.init({ password_apps = { "custom-vault" } })
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
    helpers.it("a keystroke is counted against its app", function()
      keylogger.init({})
      local before = (keylogger.get_app_stats()["kd-firefox"] or {}).keystrokes or 0
      keylogger.on_keydown("a", 1000, "kd-firefox")
      local after = (keylogger.get_app_stats()["kd-firefox"] or {}).keystrokes or 0
      helpers.assert_eq(after, before + 1, "on_keydown must increment the app's keystroke count by exactly one")
    end)

    helpers.it("a keystroke with no app_id is still counted somewhere", function()
      keylogger.init({})
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

    helpers.it("500 keystrokes across five apps are all counted", function()
      keylogger.init({})
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
    helpers.it("detects known password apps", function()
      keylogger.init({})
      -- Temporary diagnostic: this fails on the Linux runner and passes on the
      -- development machine, and two plausible explanations have already been
      -- disproved. The message carries the state so the next CI run says which.
      local st = keylogger.get_privacy_state and keylogger.get_privacy_state() or {}
      helpers.assert_true(keylogger.is_password_app("1password"),
        string.format("DIAG secure_filter=%s sysauth_filter=%s enabled=%s",
          tostring(st.secure_filter_enabled), tostring(st.system_auth_filter_enabled),
          tostring(st.enabled)))
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
      -- Called directly. flush answers what it wrote, and the caller advances on it.
      local flushed = keylogger.flush()
      helpers.assert_true(flushed == nil or type(flushed) == "boolean" or type(flushed) == "number",
        "flush must answer something the caller can act on")
    end)

    helpers.it("flushes one canonical raw batch and never replays it", function()
      local calls = { typing = {}, hotstrings = {}, switches = {}, app_days = {}, ngrams = {} }
      local fake_writer = {
        open_db = function() return true end,
        register_device = function() return true end,
        is_available = function() return true end,
        bump_rev = function() return true end,
        insert_typing_events = function(_, events)
          calls.typing[#calls.typing + 1] = events
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
      local writer_name = "modules.keylogger.sqlite_writer"
      local logger_name = "modules.keylogger.keylogger"
      local previous_writer = package.loaded[writer_name]
      local previous_logger = package.loaded[logger_name]
      package.loaded[writer_name] = fake_writer
      package.loaded[logger_name] = nil
      local ok, err = pcall(function()
        local isolated = require(logger_name)
        isolated.init({ sqlite_path = "/tmp/ergopti_keylogger_mock.sqlite" })
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
      keylogger.reset_session()
      helpers.assert_true(type(keylogger.get_app_stats()) == "table")
    end)

    helpers.it("credits a completed foreground interval without requiring a keystroke", function()
      keylogger.init({})
      keylogger.reset_session()
      keylogger.on_app_focus("firefox", 1000)
      keylogger.on_app_focus("code", 5000)

      local apps = keylogger.get_app_stats()
      helpers.assert_eq(apps.firefox.focus_time_ms, 4000,
        "foreground time must be measured from focus transitions, not typing activity")
    end)

    helpers.it("projects per-app foreground and typing time in the shared dashboard contract", function()
      keylogger.init({})
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

    helpers.it("records hotstring output and its physical trigger separately", function()
      keylogger.init({})
      keylogger.reset_session()
      keylogger.record_hotstring("firefox", "btw", "by the way", 1000)

      local app = keylogger.get_app_stats().firefox
      helpers.assert_eq(app.hs_chars, 10)
      helpers.assert_eq(app.hs_input_chars, 3)
      helpers.assert_eq(app.hs_triggers, 1)
    end)

	helpers.it("projects physical scancodes and generated output into separate UI fields", function()
		keylogger.init({})
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

    helpers.it("counts Unicode hotstrings by character rather than UTF-8 byte", function()
      keylogger.init({})
      keylogger.reset_session()
      keylogger.record_hotstring("firefox", "é", "éclair", 1000)

      local app = keylogger.get_app_stats().firefox
      helpers.assert_eq(app.hs_chars, 6)
      helpers.assert_eq(app.hs_input_chars, 1)
      helpers.assert_eq(app.hs_triggers, 1)
    end)

    helpers.it("does not retain hotstring contents while password suppression is active", function()
      keylogger.init({})
      keylogger.reset_session()
      keylogger.suppress()
      keylogger.record_hotstring("firefox", "secret", "sensitive replacement", 1000)
      keylogger.unsuppress()

      helpers.assert_eq(keylogger.get_app_stats().firefox, nil,
        "suppressed expansions must leave no per-app metric record")
    end)

    helpers.it("keeps raw hotstring and foreground transitions pending for canonical persistence", function()
      local path = helpers.driver_root() .. "/modules/keylogger/keylogger.lua"
      local fh = assert(io.open(path, "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("_pending_hotstring_events", 1, true) ~= nil)
      helpers.assert_true(src:find("_pending_app_switch_events", 1, true) ~= nil)
      helpers.assert_true(src:find("insert_hotstring_events", 1, true) ~= nil)
      helpers.assert_true(src:find("insert_app_switch_events", 1, true) ~= nil)
    end)
  end)

  -- ==========================================================================
  -- 9. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("on_keydown with nil app_id still records the keystroke", function()
      keylogger.init({})
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
    helpers.it("balanced suppress/unsuppress leaves collection on", function()
      keylogger.init({})
      for _ = 1, 20 do keylogger.suppress(); keylogger.unsuppress() end
      helpers.assert_true(not keylogger.is_suppressed(),
        "20 balanced suppress/unsuppress pairs must leave the keylogger collecting")

      local before = (keylogger.get_app_stats()["suppress-probe"] or {}).keystrokes or 0
      keylogger.on_keydown("z", 4242, "suppress-probe")
      helpers.assert_eq((keylogger.get_app_stats()["suppress-probe"] or {}).keystrokes or 0, before + 1,
        "and a keystroke after them must still be counted")
    end)

    helpers.it("suppress actually stops collection until unsuppressed", function()
      keylogger.init({})
      keylogger.suppress()
      local before = (keylogger.get_app_stats()["suppressed-probe"] or {}).keystrokes or 0
      keylogger.on_keydown("z", 5252, "suppressed-probe")
      helpers.assert_eq((keylogger.get_app_stats()["suppressed-probe"] or {}).keystrokes or 0, before,
        "a suppressed keylogger must record nothing — without this the pair above passes on a suppress() that does nothing at all")
      keylogger.unsuppress()
    end)
  end)

end)
